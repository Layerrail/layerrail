# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe BachsBillingVerificationCheckout do
  let(:account) { Account.create(email: "owner@example.com", name: "Owner") }
  let(:project) { Project.create(name: "project-1") }
  let(:product_id) { "prod_verification_1" }

  before do
    allow(Config).to receive(:bachs_verification_product_id).and_return(product_id)
    allow(Config).to receive(:bachs_verification_amount_cents).and_return(100)
  end

  it "creates a one-time card checkout for billing verification" do
    allow(Time).to receive(:now).and_return(Time.utc(2026, 7, 18, 12, 34))
    expected_key = "layerrail-billing-verification-#{project.ubid}-202607181234"
    expect(BachsClient).to receive(:create_checkout).with(
      hash_including(
        product_cart: [{product_id:, quantity: 1}],
        customer: {name: account.name || account.email, email: account.email},
        allowed_payment_method_types: ["card"],
        success_url: "https://console.layerrail.com/billing/success/bachs",
        metadata: hash_including(
          kind: "project_billing_setup",
          project_id: project.ubid,
          account_id: account.ubid,
          amount_cents: 100
        ),
        reference: expected_key
      ),
      idempotency_key: expected_key
    ).and_return("checkout_id" => "checkout-1", "checkout_url" => "https://checkout.bachs.io/c/token")

    checkout = described_class.create!(
      project:,
      account:,
      success_url: "https://console.layerrail.com/billing/success/bachs",
      cancel_url: "https://console.layerrail.com/billing"
    )

    expect(checkout.fetch("checkout_url")).to eq("https://checkout.bachs.io/c/token")
  end

  it "connects billing and starts an idempotent refund after successful verification" do
    checkout_id = "808e9dc2-2af3-4a8b-9fc9-956f34fac3c2"
    checkout = {
      "checkout_id" => checkout_id,
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "1.00",
      "currency" => "USD",
      "customer" => {"id" => "cust_bachs_1", "email" => account.email, "name" => account.name},
      "products" => [{"product_id" => product_id}],
      "metadata" => {"kind" => "project_billing_setup", "project_id" => project.ubid, "product_id" => product_id},
      "charge" => {"payment_id" => "pay_bachs_1", "status" => "succeeded", "is_refundable" => true}
    }
    allow(BachsClient).to receive(:get_checkout).with(checkout_id).and_return(checkout)
    allow(PolarClient).to receive(:get_customer_by_external_id).with(project.ubid).and_raise(PolarAPIError.new(404, "not found"))
    expect(PolarClient).to receive(:create_customer).with(
      external_id: project.ubid,
      email: account.email,
      name: account.name,
      metadata: {project_id: project.ubid, billing_provider: "bachs"}
    ).and_return("id" => "polar_customer_1")
    refund_key = "layerrail-billing-verification-refund-#{checkout_id}"
    expect(BachsClient).to receive(:create_refund).with(
      {
        charge_id: "pay_bachs_1",
        reference: refund_key,
        reason: "Automatic LayerRail billing verification refund",
        idempotency_key: refund_key
      },
      idempotency_key: refund_key
    ).and_return("status" => "processing")

    result = described_class.reconcile!(checkout_id, project:)

    expect(result).to include(status: "verified", refund_status: "processing")
    billing_info = project.refresh.billing_info
    expect(billing_info.stripe_id).to eq("polar_customer_1")
    expect(billing_info.payment_methods.first).to have_attributes(
      stripe_id: "bachs:payment:pay_bachs_1",
      card_fingerprint: "bachs:cust_bachs_1"
    )
  end

  it "rejects a checkout with the wrong amount without connecting billing" do
    allow(BachsClient).to receive(:get_checkout).and_return(
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "2.00",
      "currency" => "USD",
      "customer" => {"email" => account.email},
      "products" => [{"product_id" => product_id}],
      "metadata" => {"kind" => "project_billing_setup", "project_id" => project.ubid, "product_id" => product_id}
    )
    expect(PolarClient).not_to receive(:get_customer_by_external_id)
    expect(BachsClient).not_to receive(:create_refund)

    result = described_class.reconcile!("checkout-wrong-amount", project:)

    expect(result[:status]).to eq("not_paid")
    expect(project.refresh.billing_info).to be_nil
  end

  it "reconciles a verification collection event" do
    checkout_id = "checkout-verification-event"
    event = {
      "type" => "collection.succeeded",
      "data" => {
        "checkout_id" => checkout_id,
        "metadata" => {"kind" => "project_billing_setup", "project_id" => project.ubid}
      }
    }
    expect(described_class).to receive(:reconcile!).with(checkout_id, project:).and_return(status: "verified")

    expect(described_class.reconcile_event!(event)).to eq(status: "verified")
  end

  it "does not connect billing when the automatic refund request fails" do
    checkout_id = "checkout-refund-failure"
    allow(BachsClient).to receive(:get_checkout).with(checkout_id).and_return(
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "1.00",
      "currency" => "USD",
      "customer" => {"id" => "cust_bachs_1", "email" => account.email},
      "products" => [{"product_id" => product_id}],
      "metadata" => {"kind" => "project_billing_setup", "project_id" => project.ubid, "product_id" => product_id},
      "charge" => {"payment_id" => "pay_bachs_1", "status" => "succeeded"}
    )
    allow(PolarClient).to receive(:get_customer_by_external_id).and_return("id" => "polar_customer_1")
    allow(BachsClient).to receive(:create_refund).and_raise(BachsAPIError.new(503, "temporarily unavailable"))

    expect { described_class.reconcile!(checkout_id, project:) }.to raise_error(BachsAPIError)
    expect(project.refresh.billing_info).to be_nil
  end

  it "does not connect billing when Bachs omits the refundable charge id" do
    checkout_id = "checkout-missing-charge"
    allow(BachsClient).to receive(:get_checkout).with(checkout_id).and_return(
      "status" => "COMPLETED",
      "payment_status" => "succeeded",
      "amount" => "1.00",
      "currency" => "USD",
      "customer" => {"id" => "cust_bachs_1", "email" => account.email},
      "products" => [{"product_id" => product_id}],
      "metadata" => {"kind" => "project_billing_setup", "project_id" => project.ubid, "product_id" => product_id},
      "charge" => {"status" => "succeeded"}
    )
    allow(PolarClient).to receive(:get_customer_by_external_id).and_return("id" => "polar_customer_1")

    expect { described_class.reconcile!(checkout_id, project:) }.to raise_error(
      BachsBillingVerificationCheckout::VerificationError,
      /refundable charge id/
    )
    expect(project.refresh.billing_info).to be_nil
  end
end
