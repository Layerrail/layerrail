# frozen_string_literal: true

require "base64"
require "excon"
require "json"
require "mail"

class ResendDeliveryError < StandardError
  attr_reader :status, :body

  def initialize(status, body)
    @status = status
    @body = self.class.safe_body(body)
    super("Resend email delivery failed with HTTP #{status}: #{@body}")
  end

  def self.safe_body(body)
    parsed = JSON.parse(body.to_s)
    return "[redacted]" unless parsed.is_a?(Hash)

    JSON.generate(parsed.slice("name", "type", "code", "statusCode"))
  rescue JSON::ParserError
    "[redacted]"
  end
end

module Mail
  class ResendDelivery
    API_BASE_URL = "https://api.resend.com"

    attr_reader :settings

    def initialize(settings)
      @settings = settings
      @api_key = settings.fetch(:api_key)
      @api_base_url = settings.fetch(:api_base_url, API_BASE_URL)
    end

    def deliver!(mail)
      response = Excon.post(
        "#{@api_base_url}/emails",
        headers: {
          "Accept" => "application/json",
          "Authorization" => "Bearer #{@api_key}",
          "Content-Type" => "application/json",
        },
        body: JSON.generate(payload_for(mail)),
        expects: [200, 201, 202],
      )
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue Excon::Error => ex
      response = ex.response
      raise ResendDeliveryError.new(response&.status, response&.body)
    end

    private

    def payload_for(mail)
      payload = {
        from: formatted_header(mail, :from),
        to: formatted_addresses(mail, :to),
        subject: mail.subject,
      }

      payload[:cc] = formatted_addresses(mail, :cc) if mail[:cc]
      payload[:bcc] = formatted_addresses(mail, :bcc) if mail[:bcc]
      payload[:reply_to] = formatted_addresses(mail, :reply_to) if mail[:reply_to]

      if (html = body_for(mail, :html))
        payload[:html] = html
      end
      if (text = body_for(mail, :text))
        payload[:text] = text
      end

      attachments = mail.attachments.map do |attachment|
        {
          filename: attachment.filename,
          content: Base64.strict_encode64(attachment.body.decoded),
        }
      end
      payload[:attachments] = attachments unless attachments.empty?

      payload
    end

    def body_for(mail, type)
      part = (type == :html) ? mail.html_part : mail.text_part
      return part.body.decoded if part

      if !mail.multipart? && (mail.mime_type == "text/#{type}" || (type == :text && mail.mime_type.nil?))
        mail.body.decoded
      end
    end

    def formatted_addresses(mail, field)
      mail[field].addrs.map(&:format)
    end

    def formatted_header(mail, field)
      mail[field].addrs.map(&:format).join(", ")
    end
  end
end

ResendDelivery = Mail::ResendDelivery
