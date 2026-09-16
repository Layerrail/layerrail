# Bachs usage billing

Verified against the public Bachs documentation and OpenAPI schema on 2026-09-16.

LayerRail uses Bachs hosted checkout for inference usage invoices. Creating the invoice and its payment link is automatic; paying that link requires the customer. This is the selected implementation while Bachs does not document an API for collecting arbitrary usage amounts from a saved card. LayerRail does not switch these invoices to Stripe.

## Checkout without products

`POST /v1/checkout-sessions` accepts exactly one pricing source: `product_cart` or `pricing`. For an exact usage invoice LayerRail sends:

```json
{
  "pricing": {"price_type": "fixed", "currency": "USD", "amount": "10.00"},
  "billing_currency": "USD",
  "customer": {"email": "customer@example.com", "name": "Customer"},
  "metadata": {"kind": "invoice_payment", "invoice": "<invoice UBID>", "project": "<project UBID>"},
  "reference": "<stable invoice attempt reference>",
  "success_url": "<invoice return URL>",
  "cancel_url": "<invoice URL>",
  "expires_in_minutes": 60
}
```

Amounts are decimal strings in dollars, not cents. The documented minimum for USD raw pricing is **$1.00**. New invoice checkouts create no products. Older product-backed invoice sessions remain payable and their product can still be archived after reconciliation.

Sources:

- [Checkout: charge a raw amount](https://docs.bachs.io/guides/checkout/checkout-sessions#charge-a-raw-amount)
- [Public OpenAPI schema](https://docs.bachs.io/docs/openapi/openapi.json): `CreateCheckoutSessionRequest`, `MerchantIntent`, and `CheckoutSessionApiResponse`.

## Saved cards and automatic collection

Bachs supports saving USD cards in its customer portal and automatically charging subscription renewals, immediate subscription upgrades, and the first cycle when a trial ends. It is inaccurate to say that Bachs cannot charge saved cards at all. These capabilities do not establish an API for arbitrary threshold charges:

- The public schema lists payment reads (`GET /v1/payments`, `GET /v1/payments/{payment_id}`), but no payment/collection creation or invoice creation/payment endpoint.
- Checkout creation has no `off_session`, saved `payment_method_id`, or automatic confirmation option.
- Subscription updates accept a plan change, trial-end change, payment-method change, or metadata. They are not an arbitrary-amount collection API. In the 2026-09-16 sandbox test, ending an added trial initiated a separate $10 automatic card charge without checkout. That charge remained `processing`; successful collection and safe repeated refills were not established. This alternative is not enabled in LayerRail. See [the automatic collection investigation](bachs-automatic-collection-investigation.md).
- `GET /v1/payment-methods` lists supported payment corridors, not a customer's stored cards.
- Existing `bachs:payment:<payment_id>` records represent successful billing verification. They are not reusable card tokens and must never be sent as such.

Reliable automatic collection of a threshold invoice needs authorization for the intended charges, idempotent collection, payment reconciliation, and failure/action-required handling. The public contract reviewed here does not establish all of these for usage-triggered collection without an independent calendar renewal. The trial-based alternative needs sandbox validation and clarification from Bachs before it can replace hosted invoice payments.

Sources:

- [Customer portal and saved cards](https://docs.bachs.io/guides/customer-portal/overview#payment-methods)
- [Subscription renewals](https://docs.bachs.io/guides/subscriptions/overview)
- [Subscription changes](https://docs.bachs.io/guides/subscriptions/manage)
- [Ending a trial charges the saved card](https://docs.bachs.io/guides/subscriptions/trials#adding-extending-or-ending-a-trial)
- [Public OpenAPI schema](https://docs.bachs.io/docs/openapi/openapi.json)

## Retry and reconciliation behavior

LayerRail persists the exact checkout request and its attempt key before contacting Bachs. A row lock serializes checkout creation for an invoice, including concurrent browser and billing-job requests. A failed or lost response retries the same body and key even when another billing administrator initiates the retry. Bachs documents a 24-hour idempotency cache and rejects a different body with the same key. The stable checkout reference also identifies the attempt; an unresolved attempt is never silently assigned a new key.

Checkout creation must run outside any surrounding database transaction so the reservation is committed before the provider request. Browser invoice checkout has no surrounding transaction. Strand workers invoke collection after their transaction commits. A concurrency regression test reads the reservation from a separate database connection while the provider call is in progress.

An expired local session is checked with Bachs before a replacement is created. A processing payment is left alone, and a completed payment is reconciled first. Only an expired or canceled provider session can be replaced. Payment reconciliation checks the provider's completed/succeeded state, exact amount, currency, invoice and project metadata, then locks the invoice before its single transition to paid. New and legacy sessions use the same reconciliation path. Webhook failures return a retryable HTTP status instead of acknowledging an invoice update that failed.

Provider idempotency protects retries within its documented retention window and API-key scope. After 24 hours, or after the API key/base URL changes, an unresolved request moves to `review_required` and further creation attempts are refused. Only a SHA-256 scope fingerprint is persisted, never the API key. The public schema has no checkout-list or checkout-search-by-reference operation: an operator must reconcile the stable reference with the provider before another attempt is authorized. LayerRail does not create another key to bypass this state. Receipt email and legacy product archival follow the committed paid transition; they are not a durable outbox.

- [Bachs idempotency](https://docs.bachs.io/guides/idempotency)
- [Collection success webhook](https://docs.bachs.io/guides/webhooks/events/collection-succeeded)

The existing billing verification checkout is explicitly restricted with the documented `payment_method_types: ["USD_CARD"]` field. It remains verification, not a promise of off-session collection.
