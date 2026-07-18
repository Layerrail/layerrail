# frozen_string_literal: true

require_relative "../../spec_helper"
require_relative "../../../lib/resend_delivery"

RSpec.describe Mail::ResendDelivery do
  it "sends rendered mail through Resend" do
    request = stub_request(:post, "https://api.resend.com/emails")
      .with(
        headers: {
          "Authorization" => "Bearer re_test",
          "Content-Type" => "application/json",
        },
        body: hash_including(
          from: "LayerRail <domains@example.com>",
          to: ["user@example.com"],
          subject: "Verify your account",
          text: "Verify",
          html: "<p>Verify</p>",
        ),
      )
      .to_return(status: 200, body: JSON.generate({id: "email_123"}))

    mail = Mail.new do
      from "LayerRail <domains@example.com>"
      to "user@example.com"
      self.subject = "Verify your account"
      text_part { body "Verify" }
      html_part do
        content_type "text/html; charset=UTF-8"
        body "<p>Verify</p>"
      end
    end

    expect(described_class.new(api_key: "re_test").deliver!(mail)).to eq({"id" => "email_123"})
    expect(request).to have_been_requested
  end

  it "raises a delivery error when Resend rejects the request" do
    stub_request(:post, "https://api.resend.com/emails")
      .to_return(status: 422, body: JSON.generate({message: "Invalid from"}))

    mail = Mail.new do
      from "LayerRail <domains@example.com>"
      to "user@example.com"
      self.subject = "Verify your account"
      body "Verify"
    end

    expect {
      described_class.new(api_key: "re_test").deliver!(mail)
    }.to raise_error(ResendDeliveryError, /HTTP 422/)
  end

  it "redacts sensitive response details from delivery errors" do
    body = JSON.generate({name: "validation_error", message: "user@example.com re_secret", token: "re_secret"})
    stub_request(:post, "https://api.resend.com/emails").to_return(status: 422, body:)
    mail = Mail.new do
      from "LayerRail <domains@example.com>"
      to "user@example.com"
      self.subject = "Verify your account"
      body "Verify"
    end

    expect {
      described_class.new(api_key: "re_test").deliver!(mail)
    }.to raise_error(ResendDeliveryError) { |error|
      expect(error.body).to eq(JSON.generate({name: "validation_error"}))
      expect(error.message).not_to include("user@example.com", "re_secret")
    }
  end

  it "redacts valid non-object JSON errors" do
    stub_request(:post, "https://api.resend.com/emails").to_return(status: 500, body: JSON.generate(["user@example.com", "re_secret"]))
    mail = Mail.new do
      from "LayerRail <domains@example.com>"
      to "user@example.com"
      self.subject = "Verify your account"
      body "Verify"
    end

    expect {
      described_class.new(api_key: "re_test").deliver!(mail)
    }.to raise_error(ResendDeliveryError) { |error|
      expect(error.body).to eq("[redacted]")
      expect(error.message).not_to include("user@example.com", "re_secret")
    }
  end
end
