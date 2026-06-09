# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "domain") do |r|
    raise CloverError.new(404, "NotFound", "Domains are not enabled") unless Config.domains_enabled

    r.get true do
      authorize("Project:view", @project)
      @domain_registrations = @project.domain_registrations_dataset.reverse(:created_at).all
      @domain_orders = @project.domain_orders_dataset.reverse(:created_at).all
      view "domain/index"
    end

    r.web do
      r.get "create" do
        authorize("Project:billing", @project)
        set_domain_create_defaults
        view "domain/create"
      end

      r.post "search" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/create")

        @domain = DomainRegistration.normalize_domain(typecast_params.nonempty_str!("domain"))
        @years = typecast_params.pos_int("years") || 1
        DomainRegistration.validate_domain!(@domain)
        raise_web_error("Choose between 1 and 10 years.") unless @years.between?(1, 10)

        @search_result = NameSiloClient.new.check_register_availability(@domain)
        @pricing = NameSiloClient.new.registration_pricing(@domain) if @search_result[:available]
        raise_web_error(".#{@domain.split(".").last} is not enabled for registration yet.") if @pricing && !@pricing[:tld_enabled]
        @contact_profiles = @project.domain_contact_profiles_dataset.order(:name).all
        view "domain/create"
      rescue NameSiloAPIError => ex
        raise_web_error(ex.message)
      end

      r.post "cart" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/create")

        domain = DomainRegistration.normalize_domain(typecast_params.nonempty_str!("domain"))
        years = typecast_params.pos_int("years") || 1
        contact_profile = domain_contact_profile_from_param
        nameservers = nameservers_from(typecast_params.str("nameservers"))
        DomainRegistration.validate_domain!(domain)
        raise_web_error("Choose between 1 and 10 years.") unless years.between?(1, 10)
        raise_web_error("NameSilo is not configured. Set NAMESILO_API_KEY.") unless NameSiloClient.configured?

        client = NameSiloClient.new
        availability = client.check_register_availability(domain)
        raise_web_error("#{domain} is not available to register.") unless availability[:available]

        pricing = client.registration_pricing(domain)
        raise_web_error(".#{domain.split(".").last} is not enabled for registration yet.") unless pricing[:tld_enabled]
        amount_cents = DomainRegistration.amount_for_years(pricing[:registration_price_cents], years)
        domain_registration = DomainRegistration.new_with_id(
          project_id: @project.id,
          contact_profile_id: contact_profile&.id,
          domain:,
          status: "cart",
          provider: Config.domains_provider,
          years:,
          currency: "usd",
          registration_price_cents: pricing[:registration_price_cents],
          renewal_price_cents: pricing[:renewal_price_cents],
          transfer_price_cents: pricing[:transfer_price_cents],
          discount_cents: pricing[:discount_cents],
          amount_cents:,
          nameservers:,
          contact_data: contact_profile&.values || {},
          provider_payload: {
            "availability" => availability[:raw],
            "pricing" => pricing[:raw],
            "admin_tld" => pricing[:admin_tld]
          }.compact
        )

        DB.transaction do
          domain_registration.save_changes
          audit_log(domain_registration, "create")
        end

        flash["notice"] = "#{domain} added to your domain cart."
        r.redirect "#{@project.path}/domain"
      rescue NameSiloAPIError => ex
        raise_web_error(ex.message)
      rescue Sequel::UniqueConstraintViolation
        raise_web_error("#{domain} is already in this project.")
      end

      r.get "transfer" do
        authorize("Project:billing", @project)
        @domain = ""
        @years = 1
        @contact_profiles = @project.domain_contact_profiles_dataset.order(:name).all
        view "domain/transfer"
      end

      r.post "transfer" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/transfer")

        domain = DomainRegistration.normalize_domain(typecast_params.nonempty_str!("domain"))
        years = typecast_params.pos_int("years") || 1
        auth_code = typecast_params.nonempty_str!("auth_code").strip
        contact_profile = domain_contact_profile_from_param
        DomainRegistration.validate_domain!(domain)
        raise_web_error("Choose between 1 and 10 years.") unless years.between?(1, 10)
        raise_web_error("NameSilo is not configured. Set NAMESILO_API_KEY.") unless NameSiloClient.configured?

        pricing = NameSiloClient.new.registration_pricing(domain)
        raise_web_error(".#{domain.split(".").last} is not enabled for transfers yet.") unless pricing[:tld_enabled]
        order = DomainOrder.new_with_id(
          project_id: @project.id,
          domain_contact_profile_id: contact_profile&.id,
          kind: "transfer",
          status: "cart",
          provider: "namesilo",
          domain:,
          years:,
          currency: "usd",
          amount_cents: pricing[:transfer_price_cents] * years,
          auth_code:,
          provider_payload: {"pricing" => pricing[:raw], "admin_tld" => pricing[:admin_tld]}.compact
        )

        DB.transaction do
          order.save_changes
          audit_log(order, "create")
        end

        flash["notice"] = "#{domain} transfer added to your cart."
        r.redirect "#{@project.path}/domain"
      rescue NameSiloAPIError => ex
        raise_web_error(ex.message)
      end

      r.on "contact-profile" do
        r.get true do
          authorize("Project:view", @project)
          @contact_profiles = @project.domain_contact_profiles_dataset.order(:name).all
          view "domain/contact_profiles"
        end

        r.get "new" do
          authorize("Project:billing", @project)
          @contact_profile = DomainContactProfile.new(provider: "namesilo")
          view "domain/contact_profile"
        end

        r.post true do
          authorize("Project:billing", @project)
          handle_validation_failure("domain/contact_profile")
          @contact_profile = DomainContactProfile.new_with_id(domain_contact_profile_params.merge(project_id: @project.id))
          DB.transaction do
            @contact_profile.save_changes
            audit_log(@contact_profile, "create")
          end
          flash["notice"] = "Domain contact profile created."
          r.redirect "#{@project.path}/domain/contact-profile"
        rescue Sequel::UniqueConstraintViolation
          raise_web_error("A contact profile with that name already exists in this project.")
        end

        r.on :ubid_uuid do |contact_profile_id|
          @contact_profile = @project.domain_contact_profiles_dataset.first(id: contact_profile_id)
          check_found_object(@contact_profile)

          r.get true do
            authorize("Project:view", @project)
            view "domain/contact_profile"
          end

          r.post true do
            authorize("Project:billing", @project)
            handle_validation_failure("domain/contact_profile")
            DB.transaction do
              @contact_profile.update(domain_contact_profile_params.merge(updated_at: Time.now))
              audit_log(@contact_profile, "update")
            end
            flash["notice"] = "Domain contact profile updated."
            r.redirect "#{@project.path}/domain/contact-profile"
          end
        end
      end

      r.post "checkout" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/index")
        raise_web_error("Polar domain checkout is not configured. Set POLAR_DOMAIN_PRODUCT_ID.") unless Config.polar_domain_product_id

        items = DomainCheckout.cart_items(@project)
        raise_web_error("Your domain cart is empty.") if items.empty?

        amount_cents = DomainCheckout.amount_cents(items)
        raise_web_error("Domain cart amount is invalid.") unless amount_cents.positive?

        checkout = PolarClient.create_checkout(
          {
            products: [Config.polar_domain_product_id],
            external_customer_id: @project.ubid,
            customer_name: current_account.name,
            customer_email: current_account.email,
            customer_metadata: {
              project_id: @project.ubid,
              account_id: current_account.ubid
            },
            metadata: {
              kind: "domain_checkout",
              project_id: @project.ubid,
              registration_count: items.count { it.is_a?(DomainRegistration) },
              order_count: items.count { it.is_a?(DomainOrder) },
              amount_cents:
            },
            require_billing_address: true,
            success_url: "#{Config.base_url}#{@project.path}/domain/success?checkout_id={CHECKOUT_ID}",
            return_url: "#{Config.base_url}#{@project.path}/domain"
          }.merge(amount: amount_cents, currency: "usd")
        )

        checkout_id = checkout["id"] || checkout["checkout_id"] || checkout["checkoutId"]
        raise_web_error("Polar did not return a checkout id.") unless checkout_id

        DomainCheckout.mark_pending!(items, checkout_id)
        items.each { audit_log(it, "checkout") }

        r.redirect checkout.fetch("url"), 303
      rescue PolarAPIError => ex
        raise_web_error(ex.message)
      end

      r.get "success" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/index")
        checkout_id = typecast_params.nonempty_str("checkout_id") || typecast_params.nonempty_str("session_id")
        raise_web_error("Missing Polar checkout id") unless checkout_id

        begin
          result = DomainCheckout.reconcile!(checkout_id, project: @project)
        rescue PolarAPIError => ex
          raise_web_error("We couldn't validate your Polar checkout. #{ex.message}")
        end

        raise_web_error("Domain checkout was not successful.") unless result[:status] == "processing"
        flash["notice"] = "Domain provisioning started."
        r.redirect "#{@project.path}/domain"
      end

      r.on "order", :ubid_uuid do |domain_order_id|
        @domain_order = @project.domain_orders_dataset.first(id: domain_order_id)
        check_found_object(@domain_order)

        r.get true do
          authorize("Project:view", @project)
          view "domain/order"
        end

        r.post "remove" do
          authorize("Project:billing", @project)
          raise_web_error("Only cart or pending-payment orders can be removed.") unless %w[cart pending_payment].include?(@domain_order.status)
          DB.transaction do
            @domain_order.update(status: "cancelled", updated_at: Time.now)
            audit_log(@domain_order, "destroy")
          end
          flash["notice"] = "#{@domain_order.display_kind.capitalize} removed from your cart."
          r.redirect "#{@project.path}/domain"
        end

        r.post "retry" do
          authorize("Project:billing", @project)
          raise_web_error("Only failed orders can be retried.") unless @domain_order.status == "failed"
          DB.transaction do
            @domain_order.update(status: "processing", failure_message: nil, updated_at: Time.now)
            Prog::Domain::DomainOrderNexus.assemble(@domain_order)
            audit_log(@domain_order, "retry")
          end
          flash["notice"] = "Domain order retry started."
          r.redirect path(@domain_order)
        end
      end

      r.on :ubid_uuid do |domain_registration_id|
        @domain_registration = @project.domain_registrations_dataset.first(id: domain_registration_id)
        check_found_object(@domain_registration)

        r.get true do
          authorize("Project:view", @project)
          view "domain/show"
        end

        r.post "renew" do
          authorize("Project:billing", @project)
          raise_web_error("Only active domains can be renewed.") unless @domain_registration.active?
          years = typecast_params.pos_int("years") || 1
          raise_web_error("Choose between 1 and 10 years.") unless years.between?(1, 10)

          order = DomainOrder.new_with_id(
            project_id: @project.id,
            domain_registration_id: @domain_registration.id,
            domain_contact_profile_id: @domain_registration.contact_profile_id,
            kind: "renewal",
            status: "cart",
            provider: "namesilo",
            domain: @domain_registration.domain,
            years:,
            currency: "usd",
            amount_cents: @domain_registration.renewal_price_cents.to_i * years
          )
          DB.transaction do
            order.save_changes
            audit_log(order, "create")
          end
          flash["notice"] = "#{@domain_registration.domain} renewal added to your cart."
          r.redirect "#{@project.path}/domain"
        end

        r.post "remove" do
          authorize("Project:billing", @project)
          raise_web_error("Only cart or pending-payment domains can be removed.") unless %w[cart pending_payment].include?(@domain_registration.status)

          DB.transaction do
            @domain_registration.update(status: "cancelled", updated_at: Time.now)
            audit_log(@domain_registration, "destroy")
          end

          flash["notice"] = "#{@domain_registration.domain} removed from your cart."
          r.redirect "#{@project.path}/domain"
        end

        r.post "retry" do
          authorize("Project:billing", @project)
          raise_web_error("Only failed domains can be retried.") unless @domain_registration.status == "failed"

          DB.transaction do
            @domain_registration.update(status: "registering", failure_message: nil, updated_at: Time.now)
            Prog::Domain::DomainRegistrationNexus.assemble(@domain_registration)
            audit_log(@domain_registration, "retry")
          end

          flash["notice"] = "Domain registration retry started."
          r.redirect path(@domain_registration)
        end
      end
    end
  end

  def set_domain_create_defaults
    @domain = ""
    @years = 1
    @search_result = nil
    @pricing = nil
    @contact_profiles = @project.domain_contact_profiles_dataset.order(:name).all
  end

  def domain_contact_profile_params
    {
      name: typecast_params.nonempty_str!("name").strip,
      first_name: typecast_params.nonempty_str!("first_name").strip,
      last_name: typecast_params.nonempty_str!("last_name").strip,
      organization: typecast_params.str("organization").to_s.strip.empty? ? nil : typecast_params.str("organization").to_s.strip,
      email: typecast_params.nonempty_str!("email").strip.downcase,
      phone: typecast_params.nonempty_str!("phone").strip,
      address1: typecast_params.nonempty_str!("address1").strip,
      address2: typecast_params.str("address2").to_s.strip.empty? ? nil : typecast_params.str("address2").to_s.strip,
      city: typecast_params.nonempty_str!("city").strip,
      state: typecast_params.nonempty_str!("state").strip,
      postal_code: typecast_params.nonempty_str!("postal_code").strip,
      country_code: typecast_params.nonempty_str!("country_code").strip.upcase,
      provider: "namesilo"
    }
  end

  def domain_contact_profile_from_param
    contact_profile_ubid = typecast_params.str("contact_profile_id")
    return nil if contact_profile_ubid.to_s.empty?

    contact_profile = @project.domain_contact_profiles_dataset.first(id: UBID.to_uuid(contact_profile_ubid))
    raise_web_error("Contact profile was not found.") unless contact_profile
    contact_profile
  end

  def nameservers_from(value)
    value.to_s.split(/[\s,]+/).map { it.strip.downcase.delete_suffix(".") }.reject(&:empty?).uniq.first(13)
  end
end
