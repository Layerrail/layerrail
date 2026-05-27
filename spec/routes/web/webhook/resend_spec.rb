# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe Clover, "resend webhook" do
  let(:secret) { "whsec_#{Base64.strict_encode64("test-webhook-secret")}" }

  before do
    allow(Config).to receive(:resend_webhook_secret).and_return(secret)
  end

  it "fails if webhook secret is not configured" do
    allow(Config).to receive(:resend_webhook_secret).and_return(nil)

    page.driver.post("/webhook/resend", {}.to_json)

    expect(page.status_code).to eq(503)
  end

  it "fails if signature headers are missing" do
    page.driver.post("/webhook/resend", {}.to_json)

    expect(page.status_code).to eq(401)
  end

  it "fails if signature is invalid" do
    send_webhook({type: "email.delivered", data: {email_id: "email-123"}}, signature: "v1,invalid")

    expect(page.status_code).to eq(401)
  end

  it "fails if timestamp is too old" do
    send_webhook({type: "email.delivered", data: {email_id: "email-123"}}, timestamp: Time.now.to_i - 301)

    expect(page.status_code).to eq(401)
  end

  it "fails if body is invalid JSON" do
    send_raw_webhook("{bad-json")

    expect(page.status_code).to eq(400)
    expect(page.body).to eq({error: {message: "Invalid JSON"}}.to_json)
  end

  it "accepts a valid webhook and logs a safe summary" do
    expect(Clog).to receive(:emit).with("resend webhook received", hash_including(:resend_webhook)).and_call_original

    send_webhook({
      type: "email.delivered",
      created_at: "2026-05-27T08:00:00Z",
      data: {
        email_id: "email-123",
        to: ["user@example.com"]
      }
    })

    expect(page.status_code).to eq(200)
    expect(page.body).to eq({message: "Resend webhook received", event: "email.delivered"}.to_json)
  end

  def send_webhook(data, timestamp: Time.now.to_i, signature: nil)
    send_raw_webhook(data.to_json, timestamp:, signature:)
  end

  def send_raw_webhook(body, timestamp: Time.now.to_i, signature: nil)
    message_id = "msg_test_123"
    signature ||= "v1,#{resend_signature(message_id, timestamp, body)}"

    page.driver.post("/webhook/resend",
      body,
      {
        "Content-Type" => "application/json",
        "HTTP_SVIX_ID" => message_id,
        "HTTP_SVIX_TIMESTAMP" => timestamp.to_s,
        "HTTP_SVIX_SIGNATURE" => signature,
      })
  end

  def resend_signature(message_id, timestamp, body)
    key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
    Base64.strict_encode64(OpenSSL::HMAC.digest("sha256", key, "#{message_id}.#{timestamp}.#{body}"))
  end
end
