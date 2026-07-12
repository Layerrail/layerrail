# frozen_string_literal: true

class PremiumAiUsageMeter
  def self.record(api_key:, model:, token_kind:, resource_family:, tokens:, billing_rate:)
    new(api_key:, model:, token_kind:, resource_family:, tokens:, billing_rate:).record
  end

  # Azure AI Foundry models are premium (billed usage); Cloudflare models use
  # the free inference token quota. Tags can still force premium explicitly.
  def self.premium_model?(model)
    model.provider == "azure_foundry" || model.tags["tier"].to_s == "premium" || model.tags["premium"] == true
  end

  def self.current_month_premium_usage_cents(project)
    month_start = Time.utc(Time.now.utc.year, Time.now.utc.month, 1)
    month_end = (month_start.to_date >> 1).to_time

    BillingRecord
      .where(project_id: project.id)
      .where(Sequel.pg_jsonb_op(:resource_tags).contains({"premium_ai" => true}))
      .exclude(Sequel.pg_jsonb_op(:resource_tags).contains({"premium_ai_trial" => true}))
      .where { Sequel.pg_range(it.span).overlaps(Sequel.pg_range(month_start...month_end)) }
      .all
      .sum { |record| (record.amount.to_f * record.billing_rate["unit_price"].to_f * 100).ceil }
  end

  def initialize(api_key:, model:, token_kind:, resource_family:, tokens:, billing_rate:)
    @api_key = api_key
    @project = api_key.project
    @model = model
    @token_kind = token_kind
    @resource_family = resource_family
    @tokens = tokens.to_i
    @billing_rate = billing_rate
  end

  def record
    return unless Config.premium_ai_metering_enabled
    return unless @project && @tokens.positive?
    return unless premium?

    require_billing!
    ingest_polar_event
    enforce_spend_cap!
  rescue CloverError
    raise
  rescue => ex
    Clog.emit("Failed to meter premium AI usage", Util.exception_to_hash(ex, into: {
      project_id: @project&.id,
      model: @model.model_name,
      resource_family: @resource_family,
      tokens: @tokens
    }))
  end

  def premium?
    self.class.premium_model?(@model)
  end

  def unit_price
    @unit_price ||= begin
      price = @billing_rate&.[]("unit_price")
      price ||= @model.tags["pricing"]&.[](@token_kind == "input" ? "input" : "output").to_f / 1_000_000.0
      price.to_f
    end
  end

  def usage_cents
    (unit_price * @tokens * 100).ceil
  end

  def require_billing!
    return if polar_external_customer_id

    fail CloverError.new(
      402,
      "BillingRequired",
      "Premium AI models require billing to be connected before use."
    )
  end

  def ingest_polar_event
    return unless PolarClient.enabled?
    return unless usage_cents.positive?
    external_customer_id = polar_external_customer_id
    return unless external_customer_id

    PolarClient.ingest_events([
      {
        name: Config.premium_ai_polar_event_name,
        external_customer_id:,
        metadata: {
          project_id: @project.ubid,
          billing_info_id: @project.billing_info.ubid,
          api_key_id: @api_key.ubid,
          model: @model.model_name,
          provider: @model.provider,
          token_kind: @token_kind,
          resource_family: @resource_family,
          tokens: @tokens,
          amount_cents: usage_cents,
          unit_price: unit_price
        }
      }
    ])
  rescue PolarAPIError => ex
    Clog.emit("Failed to ingest premium AI usage into Polar", {
      polar_ai_usage_ingest_failed: {
        project_id: @project.id,
        model: @model.model_name,
        status: ex.status,
        body: ex.body
      }
    })
  end

  def polar_external_customer_id
    @polar_external_customer_id ||= @project.billing_info&.polar_external_customer_id
  end

  def enforce_spend_cap!
    cap = Config.premium_ai_monthly_spend_cap_cents.to_i
    return unless cap.positive?

    spend = self.class.current_month_premium_usage_cents(@project)
    if spend >= Config.premium_ai_charge_threshold_cents.to_i
      Clog.emit("Premium AI usage charge threshold reached", {
        premium_ai_threshold_reached: {
          project_id: @project.id,
          project_ubid: @project.ubid,
          spend_cents: spend,
          threshold_cents: Config.premium_ai_charge_threshold_cents
        }
      })
    end
    return if spend <= cap

    fail CloverError.new(
      402,
      "PremiumAISpendCapExceeded",
      "Premium AI usage is paused because this project reached its premium AI spend cap."
    )
  end

end
