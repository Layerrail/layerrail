# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe GameVpsCheckout do
  describe ".checkout_subscription_id" do
    it "reads the top-level subscription id returned by Polar checkout" do
      expect(described_class.checkout_subscription_id({"subscription_id" => "sub_123"})).to eq("sub_123")
    end

    it "falls back to nested subscription shapes" do
      expect(described_class.checkout_subscription_id({"subscription" => {"id" => "sub_nested"}})).to eq("sub_nested")
      expect(described_class.checkout_subscription_id({"order" => {"subscription_id" => "sub_order"}})).to eq("sub_order")
      expect(described_class.checkout_subscription_id({"order" => {"subscription" => {"id" => "sub_deep"}}})).to eq("sub_deep")
    end
  end
end
