# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "game-vps") do |r|
    raise CloverError.new(404, "NotFound", "Game VPS is not enabled") unless Config.game_vps_enabled

    r.get true do
      @game_vpses = dataset_authorize(@project.game_vpses_dataset.reverse(:created_at), "Vm:view").all
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
        raise_web_error("Billing verification is required before creating a Game VPS.") unless @project.has_valid_payment_method?
        raise_web_error("IONOS credentials are not configured yet.") unless IonosClient.enabled?

        name = typecast_params.nonempty_str("name")
        plan_key = typecast_params.nonempty_str("plan")
        location_key = typecast_params.nonempty_str("location")
        image_alias = typecast_params.str("image_alias").to_s.strip
        image_alias = Config.ionos_windows_image_alias if image_alias.empty?

        Validation.validate_name(name)
        plan = GameVps.plans[plan_key] || raise_web_error("Invalid Game VPS plan.")
        raise_web_error("Invalid Game VPS location.") unless GameVps.locations.key?(location_key)

        game_vps = nil
        DB.transaction do
          game_vps = GameVps.create(
            project_id: @project.id,
            name:,
            provider: Config.game_vps_provider,
            status: "creating",
            plan: plan_key,
            location: location_key,
            image_alias:,
            cores: plan[:cores],
            ram_gib: plan[:ram_gib],
            disk_gib: plan[:disk_gib],
            monthly_price: BigDecimal(plan[:monthly_price]),
            rdp_username: "Administrator",
          )
          Prog::GameVpsNexus.assemble(game_vps)
          audit_log(game_vps, "create")
        end

        flash["notice"] = "Game VPS is being created"
        r.redirect game_vps
      end
    end

    r.on GAME_VPS_NAME_OR_UBID do |name, id|
      authorized_game_vpses = dataset_authorize(@project.game_vpses_dataset, "Vm:view")
      @game_vps = name ? authorized_game_vpses.first(name:) : authorized_game_vpses.first(id:)
      check_found_object(@game_vps)

      r.get true do
        view "game_vps/show"
      end

      r.post "delete" do
        authorize("Vm:delete", @game_vps)
        DB.transaction do
          Prog::GameVpsNexus.assemble_destroy(@game_vps)
          audit_log(@game_vps, "destroy")
        end
        flash["notice"] = "Game VPS deletion started"
        r.redirect "#{@project.path}/game-vps"
      end
    end
  end
end
