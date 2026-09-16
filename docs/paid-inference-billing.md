# Paid inference usage

All newly metered inference uses paid, provider-reported token counts. Azure trials
and the monthly 100,000-token allowance no longer grant free requests. A verified,
non-fraudulent payment method is required; models without positive configured
rates are unavailable. Existing monetary project credits remain usable. Percentage
plan discounts do not apply to new inference usage.

Cloudflare SSE responses retain their event format, but are buffered until the
provider finishes and its final token counts are recorded. This delays the first
output and prevents a client disconnect from discarding billable usage. Responses
without authoritative token counts fail before any generated output is returned;
the application never substitutes estimated token counts for billing.

## Invoices and collection

- `INFERENCE_USAGE_CHARGE_THRESHOLD_CENTS` defaults to `1000` ($10); set it to `2000`
  for a $20 threshold. This threshold applies to unpaid usage after monetary credits.
  The existing respirate worker starts `CollectInferenceUsage`
  automatically and checks roughly every 30 seconds.
- Usage invoices have `billing_kind=inference_usage` and an `AI-` invoice number.
  They are separate from infrastructure invoices and subscription renewals.
- Bachs checkout uses an exact USD amount through its documented `pricing` field.
  No catalog product is required. Customers pay through the billing page. This is
  **hosted collection, not automatic charging of a saved card**; Bachs' public API
  has no arbitrary off-session collection endpoint. See [Bachs integration notes](bachs-usage-billing.md).
- Pending payment blocks more inference. Gateway access changes on its next poll;
  already-running requests can finish and add usage beyond the threshold.
- Prior-month balances are invoiced at $1 or more after monetary credits. Smaller
  balances and fractional cents carry forward rather than being forgiven. VAT is
  computed separately on the invoiced net amount under the existing tax rules.
- Provider failures retain the same invoice and retry after five minutes. Checkout
  creation persists its exact body and idempotency key before the provider call.
  An unresolved request beyond Bachs' idempotency window, or after credential
  rotation, requires reconciliation rather than creating another payable checkout.
- Signed webhooks and background provider-status checks confirm payment before
  resuming access. An HTTP success creating a checkout never marks an invoice paid.

## Accounting and rollout

Apply migration `2026091601_paid_inference_billing.rb` before deploying the new web
and respirate processes. Deploy both together: new usage requires the collector.
Keep Bachs credentials, billing details and the signed webhook configured as in
the existing billing integration. No production migration, deployment, email or
payment is performed by the test suite.

New records carry `paid_inference=true` and a price snapshot. Writers and settlement
lock the project; `inference_invoiced_amount` tracks the committed quantity already
allocated. Invoice creation, allocation, monetary-credit consumption and fractional
carry commit in one transaction. Standard invoices exclude these records completely.
Monthly spend limits include both standard usage and all paid inference, including
amounts already invoiced.

Historical untagged records and trial history retain their prior treatment. At
gateway cutover, access is withheld for one polling cycle and the pre-cutover sample
is drained before paid traffic is enabled. Existing gateway delta-counter semantics
are preserved; its upstream implementation is private and was not redefined.

Do not roll back to an old invoice generator after recording paid usage: it does
not recognize the new allocation boundary and could include those tokens again.
Keep the paid-record exclusion and allocation data when preparing a rollback.
