# frozen_string_literal: true

class Clover
  hash_branch(:project_prefix, "domain") do |r|
    raise CloverError.new(404, "NotFound", "Domains are not enabled") unless Config.domains_enabled

    r.get true do
      authorize("Project:view", @project)
      @domain_registrations = @project.domain_registrations_dataset.reverse(:created_at).all
      view "domain/index"
    end

    r.web do
      r.get "create" do
        authorize("Project:billing", @project)
        @domain = ""
        @years = 1
        @search_result = nil
        @pricing = nil
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
        view "domain/create"
      rescue NameSiloAPIError => ex
        raise_web_error(ex.message)
      end

      r.post "cart" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/create")

        domain = DomainRegistration.normalize_domain(typecast_params.nonempty_str!("domain"))
        years = typecast_params.pos_int("years") || 1
        DomainRegistration.validate_domain!(domain)
        raise_web_error("Choose between 1 and 10 years.") unless years.between?(1, 10)
        raise_web_error("NameSilo is not configured. Set NAMESILO_API_KEY.") unless NameSiloClient.configured?

        client = NameSiloClient.new
        availability = client.check_register_availability(domain)
        raise_web_error("#{domain} is not available to register.") unless availability[:available]

        pricing = client.registration_pricing(domain)
        amount_cents = DomainRegistration.amount_for_years(pricing[:registration_price_cents], years)
        domain_registration = DomainRegistration.new_with_id(
          project_id: @project.id,
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
          provider_payload: {
            "availability" => availability[:raw],
            "pricing" => pricing[:raw]
          }
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

      r.post "checkout" do
        authorize("Project:billing", @project)
        handle_validation_failure("domain/index")
        raise_web_error("Polar domain checkout is not configured. Set POLAR_DOMAIN_PRODUCT_ID.") unless Config.polar_domain_product_id

        cart = @project.domain_registrations_dataset.where(status: "cart").all
        raise_web_error("Your domain cart is empty.") if cart.empty?

        amount_cents = cart.sum(&:amount_cents)
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
              kind: "domain_registration",
              project_id: @project.ubid,
              domain_count: cart.length,
              amount_cents:
            },
            require_billing_address: true,
            success_url: "#{Config.base_url}#{@project.path}/domain/success?checkout_id={CHECKOUT_ID}",
            return_url: "#{Config.base_url}#{@project.path}/domain"
          }.merge(amount: amount_cents, currency: "usd")
        )

        checkout_id = checkout["id"] || checkout["checkout_id"] || checkout["checkoutId"]
        raise_web_error("Polar did not return a checkout id.") unless checkout_id

        DB.transaction do
          cart.each do |domain_registration|
            domain_registration.update(status: "pending_payment", checkout_id:, updated_at: Time.now)
            audit_log(domain_registration, "checkout")
          end
        end

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
          checkout_session = PolarClient.get_checkout(checkout_id)
        rescue PolarAPIError => ex
          raise_web_error("We couldn't validate your Polar checkout. #{ex.message}")
        end

        metadata = checkout_session["metadata"] || {}
        domains = @project.domain_registrations_dataset.where(status: "pending_payment", checkout_id:).all
        raise_web_error("No domains were found for this checkout.") if domains.empty?

        expected_amount_cents = domains.sum(&:amount_cents)
        checkout_amount = checkout_session["amount"].to_i
        unless checkout_session["status"] == "succeeded" &&
            checkout_session["external_customer_id"] == @project.ubid &&
            metadata["kind"] == "domain_registration" &&
            metadata["project_id"] == @project.ubid &&
            checkout_amount == expected_amount_cents
          raise_web_error("Domain checkout was not successful.")
        end

        DB.transaction do
          domains.each do |domain_registration|
            domain_registration.update(status: "registering", failure_message: nil, updated_at: Time.now)
            Prog::Domain::DomainRegistrationNexus.assemble(domain_registration)
          end
        end

        flash["notice"] = "Domain registration started."
        r.redirect "#{@project.path}/domain"
      end

      r.on :ubid_uuid do |domain_registration_id|
        @domain_registration = @project.domain_registrations_dataset.first(id: domain_registration_id)
        check_found_object(@domain_registration)

        r.get true do
          authorize("Project:view", @project)
          view "domain/show"
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
end
