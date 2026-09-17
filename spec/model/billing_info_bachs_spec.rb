# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe BillingInfo, "Bachs billing profiles" do
  subject(:billing_info) { described_class.create(stripe_id: "polar:legacy-project") }

  let(:account) { Account.create(email: "owner@example.com", name: "Owner", status_id: 2) }
  let(:customer) { {"customer_id" => "cust_existing", "email" => account.email, "name" => "Owner"} }

  before do
    allow(Config).to receive_messages(billing_checkout_provider: "bachs", polar_access_token: "old-polar-token")
    expect(PolarClient).not_to receive(:get_customer_by_external_id)
    expect(PolarClient).not_to receive(:create_customer)
  end

  it "renders unmapped legacy billing without consulting the previous provider" do
    expect(billing_info.billing_data).to eq({})
    expect(billing_info.polar_external_customer_id).to be_nil
    payment_method = PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "polar:checkout:old")
    expect(payment_method.billing_data).to eq("brand" => "Previous provider")
  end

  it "reads mapped details from Bachs while retaining the old billing id" do
    billing_info.update(bachs_customer_id: "cust_existing")
    expect(BachsClient).to receive(:get_customer).with("cust_existing").and_return(customer.merge(
      "billing_address" => {"line1" => "40 Yaba Road", "city" => "Lagos", "country" => "NG"},
      "metadata" => {"company_name" => "Example"}
    ))

    expect(billing_info.billing_data).to include("name" => "Owner", "email" => account.email, "address" => "40 Yaba Road", "city" => "Lagos", "company_name" => "Example")
    expect(billing_info.stripe_id).to eq("polar:legacy-project")
  end

  it "adopts a single customer from a verified Bachs receipt without creating another" do
    receipt = PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment:paid", card_fingerprint: "bachs:cust_receipt")
    expect(BachsClient).not_to receive(:list_customers)
    expect(BachsClient).not_to receive(:create_customer)

    expect(billing_info.ensure_bachs_customer!(account:)).to eq("cust_receipt")
    expect(billing_info.refresh[:bachs_customer_id]).to eq("cust_receipt")
    expect(receipt.refresh.card_fingerprint).to eq("bachs:cust_receipt")
    expect(billing_info.stripe_id).to eq("polar:legacy-project")
  end

  it "refuses ambiguous legacy receipt customers instead of mapping a third customer" do
    %w[cust_first cust_second].each do |id|
      PaymentMethod.create(billing_info_id: billing_info.id, stripe_id: "bachs:payment:#{id}", card_fingerprint: "bachs:#{id}")
    end
    expect(BachsClient).not_to receive(:list_customers)
    expect(BachsClient).not_to receive(:create_customer)

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BillingInfo::BachsCustomerError, /couldn't identify/)
    expect(billing_info.refresh[:bachs_customer_id]).to be_nil
  end

  it "maps only the authenticated verified email, with case-insensitive equality" do
    expect(BachsClient).to receive(:list_customers).with(search: account.email).and_return(
      "items" => [customer.merge("email" => "OWNER@example.com"), {"customer_id" => "cust_other", "email" => "not-owner@example.com"}],
      "pagination" => {"has_more" => false}
    )
    expect(BachsClient).not_to receive(:create_customer)

    expect(billing_info.ensure_bachs_customer!(account:)).to eq("cust_existing")
    expect(billing_info.refresh.stripe_id).to eq("polar:legacy-project")
  end

  it "does not search or create for an unverified account" do
    account.update(status_id: 1)
    expect(BachsClient).not_to receive(:list_customers)
    expect(BachsClient).not_to receive(:create_customer)

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BillingInfo::BachsCustomerError, /Verify your account email/)
  end

  it "refuses duplicate exact email matches" do
    expect(BachsClient).to receive(:list_customers).and_return(
      "items" => [customer, customer.merge("customer_id" => "cust_duplicate")], "pagination" => {"has_more" => false}
    )
    expect(BachsClient).not_to receive(:create_customer)

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BillingInfo::BachsCustomerError, /couldn't identify/)
  end

  it "refuses incomplete search results even when the first page has one match" do
    expect(BachsClient).to receive(:list_customers).and_return("items" => [customer], "pagination" => {"has_more" => true})
    expect(BachsClient).not_to receive(:create_customer)

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BillingInfo::BachsCustomerError, /couldn't identify/)
  end

  it "uses the same idempotency key after a lost customer creation response" do
    allow(BachsClient).to receive(:list_customers).and_return("items" => [], "pagination" => {"has_more" => false})
    attempts = 0
    expect(BachsClient).to receive(:create_customer).with(
      {email: account.email, name: account.name}, idempotency_key: "layerrail-billing-customer-#{billing_info.id}"
    ).twice do
      attempts += 1
      raise BachsAPIError.new(nil, "connection lost") if attempts == 1

      customer
    end

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BachsAPIError)
    expect(billing_info.refresh[:bachs_customer_id]).to be_nil
    expect(billing_info.ensure_bachs_customer!(account:)).to eq("cust_existing")
    expect(billing_info.refresh[:bachs_customer_id]).to eq("cust_existing")
  end

  it "does not persist a provider response with a different customer email" do
    allow(BachsClient).to receive(:list_customers).and_return("items" => [], "pagination" => {"has_more" => false})
    allow(BachsClient).to receive(:create_customer).and_return(customer.merge("email" => "someone-else@example.com"))

    expect { billing_info.ensure_bachs_customer!(account:) }.to raise_error(BillingInfo::BachsCustomerError, /couldn't verify/)
    expect(billing_info.refresh[:bachs_customer_id]).to be_nil
  end
end
