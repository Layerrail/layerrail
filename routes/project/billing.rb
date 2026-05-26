# frozen_string_literal: true

require "countries"

class Clover
  hash_branch(:project_prefix, "billing") do |r|
    r.web do
      unless PolarClient.configured_for_checkout?
        response.status = 501
        response.content_type = :text
        next "Billing is not enabled. Set POLAR_ACCESS_TOKEN and POLAR_VERIFICATION_PRODUCT_ID to enable Polar billing."
      end

      authorize("Project:billing", @project)

      polar_customer_id = @project.ubid
      polar_checkout = lambda do |kind, product_id, success_path, metadata = {}, checkout_options = {}|
        PolarClient.create_checkout({
          products: [product_id],
          external_customer_id: polar_customer_id,
          customer_name: current_account.name,
          customer_email: current_account.email,
          customer_metadata: {
            project_id: @project.ubid,
            account_id: current_account.ubid
          },
          metadata: {
            kind:,
            project_id: @project.ubid
          }.merge(metadata),
          require_billing_address: true,
          success_url: "#{Config.base_url}#{success_path}?checkout_id={CHECKOUT_ID}",
          return_url: "#{Config.base_url}#{billing_path}"
        }.merge(checkout_options))
      end

      r.get true do
        view "project/billing"
      end

      r.post true do
        if (billing_info = @project.billing_info)
          handle_validation_failure("project/billing")
          current_tax_id = billing_info.billing_data["tax_id"].to_s
          tp = typecast_params
          new_tax_id = tp.str("tax_id").gsub(/[^a-zA-Z0-9]/, "")

          # Sanitize email (strip any spaces)
          email_input = tp.str!("email").gsub(/\s+/, "")

          # Sanitize state to 2-letter abbreviation for countries like US
          country_code = tp.str!("country")
          state_input = tp.nonempty_str("state")
          state_sanitized = nil
          if state_input
            country = ISO3166::Country[country_code]
            if country && !country.subdivisions.empty?
              upcased = state_input.strip.upcase
              if country.subdivisions.key?(upcased)
                state_sanitized = upcased
              else
                state_sanitized = country.subdivisions.find { |k, v| v["name"].to_s.downcase == state_input.strip.downcase }&.first || state_input.strip
              end
            else
              state_sanitized = state_input.strip
            end
          end

          # Sanitize metadata (omit empty fields to avoid Polar API length constraint errors)
          metadata_payload = {
            company_name: tp.str("company_name").to_s.strip.empty? ? nil : tp.str("company_name").strip,
            note: tp.str("note").to_s.strip.empty? ? nil : tp.str("note").strip,
            project_id: @project.ubid
          }.compact

          begin
            PolarClient.update_customer_by_external_id(polar_customer_id, {
              name: tp.str!("name"),
              email: email_input,
              billing_address: {
                country: country_code,
                state: state_sanitized,
                city: tp.nonempty_str("city"),
                postal_code: tp.nonempty_str("postal_code"),
                line1: tp.str!("address"),
                line2: nil
              },
              tax_id: new_tax_id.empty? ? nil : new_tax_id,
              metadata: metadata_payload
            })
            if new_tax_id != current_tax_id
              DB.transaction do
                billing_info.update(valid_vat: nil)
                if !new_tax_id.empty? && billing_info.country&.in_eu_vat?
                  Strand.create(prog: "ValidateVat", label: "start", stack: [{subject_id: billing_info.id}])
                end
              end
            end
            audit_log(@project, "update_billing")
          rescue PolarAPIError => e
            if e.status == 404 || e.body.to_s.include?("Customer does not exist")
              DB.transaction do
                @project.update(billing_info_id: nil)
                billing_info.destroy
              end
              flash["notice"] = "Your billing details were not found on Polar. Please reconnect your billing."
              r.redirect billing_path
            else
              raise_web_error(e.message)
            end
          end

          flash["notice"] = "Billing info updated"
          r.redirect billing_path
        else
          no_audit_log
        end

        checkout = polar_checkout.call("project_billing_setup", PolarClient.verification_product_id, "#{@project.path}/billing/success")
        r.redirect checkout.fetch("url"), 303
      end

      r.get "success" do
        handle_validation_failure("project/billing")
        checkout_id = typecast_params.nonempty_str("checkout_id") || typecast_params.nonempty_str("session_id")
        raise_web_error("Missing Polar checkout id") unless checkout_id

        begin
          checkout_session = PolarClient.get_checkout(checkout_id)
        rescue PolarAPIError => e
          Clog.emit("invalid Polar checkout", {invalid_polar_checkout: {project_id: @project.id, checkout_id:, message: e.message}})
          raise_web_error("We couldn't validate your Polar checkout. If you think this is a mistake, please contact support@layerrail.com.")
        end

        metadata = checkout_session["metadata"] || {}
        unless checkout_session["status"] == "succeeded" &&
            checkout_session["external_customer_id"] == polar_customer_id &&
            metadata["project_id"] == @project.ubid
          Clog.emit("unsuccessful Polar checkout", {unsuccessful_polar_checkout: {project_id: @project.id, checkout_id:}})
          raise_web_error("Polar checkout was not successful")
        end

        DB.transaction do
          unless (billing_info = @project.billing_info)
            billing_info = BillingInfo.create(stripe_id: checkout_session["customer_id"] || "polar:#{polar_customer_id}")
            @project.update(billing_info_id: billing_info.id)
          end

          polar_payment_id = "polar:checkout:#{checkout_id}"
          unless billing_info.payment_methods_dataset[stripe_id: polar_payment_id]
            PaymentMethod.create(
              billing_info_id: billing_info.id,
              stripe_id: polar_payment_id,
              card_fingerprint: "polar:#{polar_customer_id}"
            )
          end
        end

        flash["notice"] = "Polar billing connected successfully."
        r.redirect billing_path
      end

      r.get "portal" do
        next unless @project.billing_info

        begin
          session = PolarClient.create_customer_session(
            polar_customer_id,
            return_url: "#{Config.base_url}#{billing_path}"
          )
          r.redirect session.fetch("customer_portal_url"), 303
        rescue PolarAPIError => e
          if e.status == 404 || e.body.to_s.include?("Customer does not exist")
            DB.transaction do
              billing_info = @project.billing_info
              @project.update(billing_info_id: nil)
              billing_info.destroy
            end
            flash["notice"] = "Your billing details were not found on Polar. Please reconnect your billing."
            r.redirect billing_path
          else
            raise_web_error(e.message)
          end
        end
      end

      r.on "payment-method" do
        r.get "create" do
          r.redirect "#{billing_path}/portal"
        end

        r.delete :ubid_uuid do |id|
          next unless (payment_method = @project.payment_methods_dataset.with_pk(id))

          unless payment_method.billing_info.payment_methods_dataset.count > 1
            response.status = 400
            next {error: {message: "You can't delete the last payment method of a project."}}
          end

          DB.transaction do
            payment_method.destroy
            audit_log(payment_method, "destroy")
          end

          flash["notice"] = "Payment method deleted"
          r.redirect @project, "/billing"
        end
      end

      r.on "invoice", ["current", :ubid_uuid] do |id|
        next unless (invoice = (id == "current") ? @project.current_invoice : @project.invoices_dataset.with_pk(id))

        r.get true do
          if invoice.status == "current"
            @invoice_data = Serializers::Invoice.serialize(invoice)
            view "project/invoice"
          else
            response.attachment invoice.filename, "inline"
            begin
              Invoice.blob_storage_client.get_object(bucket: Config.invoices_bucket_name, key: invoice.blob_key).body.read
            rescue Aws::S3::Errors::NoSuchKey
              Clog.emit("Could not find the invoice", {not_found_invoice: {invoice_ubid: invoice.ubid}})
              invoice.generate_pdf
            end
          end
        end

        r.post "pay" do
          no_audit_log
          handle_validation_failure("project/billing")
          raise_web_error("Invoice is not payable") unless invoice.payable?
          raise_web_error("Polar invoice checkout is not configured. Set POLAR_INVOICE_PRODUCT_ID.") unless Config.polar_invoice_product_id

          invoice_amount_cents = (invoice.cost.to_f * 100).round
          raise_web_error("Invoice amount is invalid") unless invoice_amount_cents.positive?

          checkout = polar_checkout.call(
            "invoice_payment",
            Config.polar_invoice_product_id,
            "#{path(invoice)}/success",
            {
              invoice: invoice.ubid,
              invoice_number: invoice.invoice_number,
              invoice_amount_cents:
            },
            {
              amount: invoice_amount_cents,
              currency: "usd"
            }
          )

          r.redirect checkout.fetch("url"), 303
        end

        r.get "success" do
          handle_validation_failure("project/billing")
          checkout_id = typecast_params.nonempty_str("checkout_id") || typecast_params.nonempty_str("session_id")
          raise_web_error("Missing Polar checkout id") unless checkout_id

          begin
            checkout_session = PolarClient.get_checkout(checkout_id)
          rescue PolarAPIError => e
            Clog.emit("invalid invoice payment", {unsuccessful_invoice_payment: {invoice_ubid: invoice.ubid, checkout_id:, message: e.message}})
            raise_web_error("We couldn't validate your payment. If you think this is a mistake, please contact support@layerrail.com")
          end

          metadata = checkout_session["metadata"] || {}
          expected_amount_cents = (invoice.cost.to_f * 100).round
          unless checkout_session["status"] == "succeeded" &&
              checkout_session["external_customer_id"] == polar_customer_id &&
              metadata["invoice"] == invoice.ubid &&
              checkout_session["amount"].to_i == expected_amount_cents
            Clog.emit("unsuccessful invoice payment", {unsuccessful_invoice_payment: {invoice_ubid: invoice.ubid, checkout_id:}})
            raise_web_error("Invoice payment was not successful")
          end

          invoice.update(status: "paid")
          invoice.send_success_email
          flash["notice"] = "Invoice #{invoice.invoice_number} paid successfully"

          r.redirect billing_path
        end
      end
    end
  end
end
