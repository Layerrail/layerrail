# frozen_string_literal: true

require "bigdecimal"

class Clover
  def start_game_vps_checkout(game_vps)
    product_id = game_vps.polar_product_id
    checkout = PolarClient.create_checkout(
      {
        products: [product_id],
        external_customer_id: game_vps.polar_external_customer_id,
        customer_name: current_account.name || current_account.email,
        customer_email: current_account.email,
        customer_metadata: {
          project_id: @project.ubid,
          account_id: current_account.ubid,
          game_vps_id: game_vps.ubid
        },
        metadata: {
          kind: "game_vps_checkout",
          project_id: @project.ubid,
          game_vps_id: game_vps.ubid,
          external_customer_id: game_vps.polar_external_customer_id,
          plan: game_vps.plan,
          image_alias: game_vps.image_alias,
          product_id:,
          amount_cents: game_vps.amount_cents
        },
        require_billing_address: true,
        success_url: "#{Config.base_url}#{@project.path}/game-vps/success?checkout_id={CHECKOUT_ID}",
        return_url: "#{Config.base_url}#{@project.path}/game-vps"
      }
    )

    checkout_id = checkout["id"] || checkout["checkout_id"] || checkout["checkoutId"]
    raise "Polar did not return a checkout id." unless checkout_id

    checkout_url = checkout["url"] || checkout["checkout_url"] || checkout["checkoutUrl"]
    raise "Polar did not return a checkout URL." unless checkout_url

    GameVpsCheckout.mark_pending!(game_vps, checkout_id)
    checkout_url
  end

  def cleanup_unstarted_game_vps_checkout(game_vps, exception)
    return unless game_vps

    game_vps.reload
    if game_vps.status == "pending_payment" && !game_vps.values[:checkout_id] && !game_vps.values[:server_id]
      game_vps.destroy
    else
      game_vps.update(failure_message: exception.message.to_s.slice(0, 1000), updated_at: Time.now)
    end
  rescue Sequel::NoExistingObject
    nil
  end

  hash_branch(:project_prefix, "game-vps") do |r|
    raise CloverError.new(404, "NotFound", "Game VPS is not enabled") unless Config.game_vps_enabled

    r.get true do
      @game_vpses = dataset_authorize(@project.game_vpses_dataset.reverse(:created_at), "Vm:view")
        .exclude(status: ["pending_payment", "deleting", "deleted"])
        .all
      view "game_vps/index"
    end

    r.web do
      r.get "create" do
        authorize("Vm:create", @project)
        view "game_vps/create"
      end

      r.post true do
        handle_validation_failure("game_vps/create")
        authorize("Vm:create", @project)
        case Config.game_vps_provider
        when "azure"
          raise_web_error("Azure credentials are not configured yet.") unless AzureClient.enabled?
        when "ionos"
          raise_web_error("IONOS credentials are not configured yet.") unless IonosClient.enabled?
          raise_web_error("Billing verification is required before creating a Game VPS.") unless @project.has_valid_payment_method?
        else
          raise_web_error("Game VPS provider #{Config.game_vps_provider} is not supported.")
        end

        name = typecast_params.nonempty_str("name")
        plan_key = typecast_params.nonempty_str("plan")
        location_key = typecast_params.nonempty_str("location")
        image_alias = typecast_params.str("image_alias").to_s.strip
        image_alias = Config.game_vps_provider == "ionos" ? Config.ionos_windows_image_alias : "windows-server-2022" if image_alias.empty?
        rdp_username = typecast_params.str("rdp_username").to_s.strip
        rdp_username = Config.game_vps_provider == "ionos" ? "Administrator" : "layerrail" if rdp_username.empty?
        rdp_password = typecast_params.nonempty_str("rdp_password")

        Validation.validate_name(name)
        plan = GameVps.plans[plan_key] || raise_web_error("Invalid Game VPS plan.")
        raise_web_error("Invalid Game VPS location.") unless GameVps.locations.key?(location_key)
        GameVps.validate_windows_credentials(rdp_username, rdp_password, allow_reserved_admin: Config.game_vps_provider == "ionos")
        if Config.game_vps_provider == "azure"
          raise_web_error("Invalid Windows image.") unless GameVps.windows_images.key?(image_alias)
          begin
            GameVps.polar_product_id_for(plan_key)
          rescue RuntimeError => ex
            raise_web_error(ex.message)
          end
        end

        game_vps = nil
        DB.transaction do
          game_vps = GameVps.create(
            project_id: @project.id,
            name:,
            provider: Config.game_vps_provider,
            status: Config.game_vps_provider == "azure" ? "pending_payment" : "creating",
            plan: plan_key,
            location: location_key,
            image_alias:,
            cores: plan[:cores],
            ram_gib: plan[:ram_gib],
            disk_gib: plan[:disk_gib],
            monthly_price: BigDecimal(plan[:monthly_price]),
            rdp_username:,
            rdp_password:,
          )
          Prog::GameVpsNexus.assemble(game_vps) if Config.game_vps_provider == "ionos"
          audit_log(game_vps, "create")
        end

        if Config.game_vps_provider == "azure"
          begin
            r.redirect start_game_vps_checkout(game_vps), 303
          rescue PolarAPIError, Sequel::Error, RuntimeError => ex
            cleanup_unstarted_game_vps_checkout(game_vps, ex)
            Clog.emit("game vps checkout failed", Util.exception_to_hash(ex, into: {game_vps_checkout_failed: {game_vps_ubid: game_vps&.ubid, project_ubid: @project.ubid}}))
            raise_web_error("We couldn't start checkout. #{ex.message}")
          end
        end

        flash["notice"] = "Game VPS is being created"
        r.redirect game_vps
      end

      r.get "success" do
        authorize("Vm:create", @project)
        handle_validation_failure("game_vps/index")
        checkout_id = typecast_params.str("checkout_id").to_s.strip
        checkout_id = typecast_params.str("session_id").to_s.strip if checkout_id.empty?
        raise_web_error("Missing Polar checkout id") if checkout_id.empty?

        begin
          result = GameVpsCheckout.reconcile!(checkout_id, project: @project)
        rescue PolarAPIError => ex
          raise_web_error("We couldn't validate your Polar checkout. #{ex.message}")
        rescue => ex
          Clog.emit("game vps checkout success failed", Util.exception_to_hash(ex, into: {game_vps_checkout_success_failed: {checkout_id:, project_ubid: @project.ubid}}))
          raise_web_error("Payment was received, but provisioning did not start cleanly. Support has been notified.")
        end

        raise_web_error("Game VPS checkout was not successful.") unless ["provisioning", "already_processed"].include?(result[:status])
        flash["notice"] = "Game VPS payment received. Provisioning started."
        r.redirect "#{@project.path}/game-vps"
      end

      r.on GAME_VPS_NAME_OR_UBID do |name, id|
        authorized_game_vpses = dataset_authorize(@project.game_vpses_dataset, "Vm:view")
        matched_id = id || (UBID.to_uuid(name) if name)
        @game_vps = matched_id ? authorized_game_vpses.first(id: matched_id) : authorized_game_vpses.first(name:)
        check_found_object(@game_vps)

        r.get "rdp" do
          raise CloverError.new(404, "NotFound", "RDP config is not available until the server has an IP address.") unless @game_vps.primary_ip

          response.attachment "#{@game_vps.name.gsub(/[^A-Za-z0-9._-]/, "-")}.rdp"
          response.content_type = :text
          [
            "full address:s:#{@game_vps.primary_ip}:3389",
            "username:s:#{@game_vps.rdp_username}",
            "prompt for credentials:i:1",
            "authentication level:i:2",
            "enablecredsspsupport:i:1",
            "screen mode id:i:2",
            "desktopwidth:i:1920",
            "desktopheight:i:1080",
            "session bpp:i:32",
            "redirectclipboard:i:1"
          ].join("\r\n")
        end

        r.get true do
          authorize("Vm:view", @game_vps)
          r.redirect @game_vps, "/overview"
        end

        r.show_object(@game_vps, actions: %w[overview], perm: "Vm:view", template: "game_vps/show")

        r.post "checkout" do
          handle_validation_failure("game_vps/show") { @page = "overview" }
          authorize("Vm:create", @project)
          raise_web_error("This Game VPS has already been paid for.") unless @game_vps.status == "pending_payment"

          begin
            r.redirect start_game_vps_checkout(@game_vps), 303
          rescue PolarAPIError, Sequel::Error, RuntimeError => ex
            @game_vps.update(failure_message: ex.message.to_s.slice(0, 1000), updated_at: Time.now)
            Clog.emit("game vps checkout retry failed", Util.exception_to_hash(ex, into: {game_vps_checkout_retry_failed: {game_vps_ubid: @game_vps.ubid, project_ubid: @project.ubid}}))
            raise_web_error("We couldn't restart checkout. #{ex.message}")
          end
        end

        r.post "delete" do
          authorize("Vm:delete", @game_vps)
          DB.transaction do
            BillingRecord.finalize_active_for_resource(@game_vps) unless @game_vps.prepaid?
            Prog::GameVpsNexus.assemble_destroy(@game_vps)
            audit_log(@game_vps, "destroy")
          end
          flash["notice"] = "Game VPS deletion started"
          r.redirect "#{@project.path}/game-vps"
        end
      end
    end
  end
end
