# Bachs automatic usage collection investigation

Reviewed on 2026-09-16 against the public documentation and OpenAPI schema, followed by the sandbox tests below. This candidate is not enabled in LayerRail billing. No live customer was charged during this investigation.

## Result

Bachs accepted a paid $10 sandbox subscription checkout, saved a payment method, and subsequently initiated a separate $10 off-session charge after an active-to-trial-to-active transition. **Initiation is verified; settlement is unverified.** The additional charge remained `processing`, with $0 paid, at the final observation on 2026-09-16 at 19:16:43.596 UTC, more than ten minutes after creation. The initial checkout payment succeeded, but it is not proof that the later refill settled.

The test subscription was canceled at 19:16:34.452462 UTC; subsequent retrieval confirmed `canceled` and `next_billed_at: null`. This cleared its future scheduled billing. The already-created cycle charge was still processing afterward, so cancellation is not evidence that the pending charge was cleared.

Replaying the exact trial-ending PATCH twice while the subscription remained active returned the same response and billing period, with no duplicate invoice observed. Replay after entering another trial was not tested because collection was still pending. Independently, finite trial deferral cannot guarantee usage-only charges during a LayerRail outage: Bachs retains a calendar billing date. Keep the existing hosted usage invoice implementation until settlement, replay safety, and control of scheduled charges are established.

| Approach | Publicly documented behavior | Fit for LayerRail |
| --- | --- | --- |
| Raw-amount checkout | Exact amount, no catalog product, customer completes checkout | Current separate usage invoice flow |
| Recurring AI credit purchase | Saved card charged on a fixed cadence | Can automate payments, but charges even without additional usage; a different billing model |
| Subscription upgrade | Charges the prorated difference immediately | Does not reliably collect an arbitrary $10 usage invoice; changes future recurring price and can create credits |
| End and restart trials | End a trial to charge a full cycle; an active subscription can enter another trial | Sandbox initiated a cycle charge; settlement, usage-only behavior, and replay after another deferral remain unverified |
| Direct off-session charge or metered invoice | No create-charge, meter, create-invoice, or pay-invoice operation in public schema | No documented integration to implement |

## Candidate: separate $10 AI credit refills

This would be a prepaid AI balance, separate from the normal LayerRail plan. It would require a new customer checkout explicitly authorizing automatic refills. Existing successful $1 billing-verification payments do not establish that authorization or provide a reusable card token.

1. Create one fixed $10 USD recurring product through `POST /v1/products`. No manual dashboard product creation is needed, but Bachs requires a recurring catalog product for this path.
2. Start its checkout with `POST /v1/checkout-sessions`, supplying that product and the customer, restricted to `USD_CARD`. The customer completes checkout. Store the actual subscription/customer IDs; do not convert a historical payment ID into a payment method ID.
3. Confirm the first payment and allocate exactly one $10 AI credit purchase to that provider invoice.
4. Set a future trial end on the active subscription to defer its next collection:

   ```http
   PATCH /v1/subscriptions/{subscription_id}
   Content-Type: application/json

   {"trial_end":"<future UTC timestamp>"}
   ```

   Bachs explicitly documents that this changes an active subscription to `trialing` and postpones billing. It is a finite deferral, not a permanent pause.

5. When another refill is authorized by the customer's chosen balance threshold and spending limit, end that trial:

   ```http
   PATCH /v1/subscriptions/{subscription_id}
   Content-Type: application/json

   {"trial_end":"<persisted UTC timestamp at or before the request time>"}
   ```

   While `trialing`, this starts a fresh billing cycle and initiates collection of its full fixed amount from the saved card. The sandbox returned `active` before the charge settled. The timestamp and request identity must be persisted before submission; a retry must not silently become a new operation.

6. Confirm a matching `invoice.paid`, allocate credits once, and defer the next cycle again. On failure, grant no new credits and preserve the provider invoice for recovery; do not create another trial-ending charge for the same refill.

The documented operations support this hypothesis. They do not prove that repeated trial cycling is a supported production auto-refill product. The trial feature is in beta and may require account enablement.

## Why this is not ready for customer accounts

- **Unwanted scheduled charges:** after collection, a regular renewal is scheduled. If the deferral fails, Bachs can charge by date without another $10 of usage. Even a successfully deferred trial eventually ends. A longer deferral or cadence does not eliminate this failure mode.
- **Conflicting idempotency documentation:** API Standards says POST and PATCH support `Idempotency-Key`; the dedicated guide scopes its 24-hour cache to POST. A delayed old trial-ending request becomes valid again after a subsequent deferral. Reading `trialing` before retrying is not sufficient to prevent a duplicate refill.
- **Customer-facing terms:** a hosted recurring checkout and portal can show a renewal date or trial. These must accurately represent the automatic-refill agreement. LayerRail cannot promise usage-only charges while Bachs independently schedules renewals.
- **Account access:** paid subscription creation and trial transitions succeeded in the LayerRail sandbox. Production enablement remains unverified; documented errors include `SUBSCRIPTIONS_NOT_ENABLED` and `TRIALS_NOT_ENABLED`.
- **Reconciliation:** subscription status alone is not proof of payment. Verify provider invoice ID, subscription, customer, currency, amount, and paid status; deduplicate by invoice as well as event. Missing events can be recovered through Bachs's webhook event APIs with the appropriate read permission. That is evidence of payment, not a way to stop an unwanted scheduled charge.
- **Cancellation:** immediate cancellation clears the next billing date but is terminal. Public subscription update fields do not include an uncancel operation or an indefinite billing pause. Canceling after every charge would require another subscription checkout.
- **Failed payments:** Bachs retries failed subscription invoices. Outstanding recovery must be reconciled before another refill is created; disabling refills must not leave an unnoticed scheduled charge or retry.

## Sandbox validation before implementation

The user approved creation and use of a restricted sandbox key. It was created with Payments Read/Write, Subscriptions Read/Write, and Webhooks Read, and kept only in private process memory. No key value or card security details are included in these files. The diagnostic helper hardcodes the sandbox API host, rejects live keys, and does not retry automatically. The observations below complete only part of this validation:

1. Complete one test subscription checkout and capture its invoice, saved payment method, customer, amount, and billing period. Inspect the actual checkout/portal wording.
2. Defer an active subscription, end the trial, and verify exactly one additional paid $10 invoice through both webhooks and provider event retrieval.
3. Repeat the same PATCH with the same key and body before and after deferring again. Test a lost response and duplicate workers; verify no second invoice. Establish with Bachs how retries are handled after the retention window and when the first response is non-2xx.
4. Simulate deferral failure, a stopped worker, delayed/out-of-order events, and reaching the deferred date with no new usage. A provider-enforced stop on collection without a new refill authorization is required to promise usage-only billing. Local retries alone cannot establish this guarantee.
5. Exercise declined payments, customer card updates, cancellation with an outstanding invoice, and disabling refills during an in-flight payment. Confirm no extra credit grant or unexpected collection.
6. Confirm separate AI purchase receipts, credit consumption, taxes, and normal plan billing remain consistent. Credits must be recorded in an AI-specific ledger and not counted as new revenue again when spent.

Mock tests can validate LayerRail's bookkeeping but cannot establish Bachs's actual collection semantics. Passing happy-path sandbox tests would still leave the unattended-renewal guarantee to resolve.

## Sandbox observations, 2026-09-16

The signed-in LayerRail account was switched into sandbox mode. An initial developer-menu switch failed with a network error; the organization switcher subsequently opened the sandbox successfully. The sandbox banner explicitly states that transactions are simulated and do not affect the live account.

The first attempt used `prod_07dc2a6879d140a18530` ($10 USD monthly, seven-day trial) and a fictional `example.com` customer. Its checkout remained on `Processing`; at 18:53 UTC there was no subscription and no paid invoice. This attempt remains unresolved. The setup screen described monthly future charges, not usage-triggered refills.

A separate product with payment due immediately established the saved-card baseline:

| Resource | Sandbox ID |
| --- | --- |
| Paid-start product | `prod_1c89b4347db14d579fff` |
| Paid-start checkout | `chk_VqVJXwTElrEYzlDn` |
| Subscription | `sub_f39e480f57aa4890b33e` |
| Saved payment method | `pm_cbb3aa3e89254dd4b0c2` |
| Initial paid invoice | `inv_b0c782d098e747a08b4c` |
| Additional cycle invoice | `inv_e4eabee92f864bf48f52` |
| Additional cycle charge | `ch_2fe7d57f55664fb7b26a78b62d1eb5c0` |

| Time (UTC) | Evidence |
| --- | --- |
| 19:04:04.219973 | Paid-start checkout created for $10 USD. |
| 19:04:59.343737 | Initial invoice paid for $10; subscription active with a saved payment method. |
| Before 19:06:32 | PATCH with `trial_end: "2026-09-23T19:06:11.523Z"` returned `trialing` and the same future `next_billed_at`. |
| 19:06:32.542310 | Ending the trial with the persisted timestamp `2026-09-16T19:06:31.272Z` returned `active`, starting a new period ending 2026-10-16 19:06:32.542310 UTC. |
| 19:06:32.603425 | Additional invoice created for $10. Its historical `invoice.created` payload was `draft`, with no charge or next payment attempt yet. |
| 19:06:32.864170 | Separate cycle charge created. Payment retrieval identifies `billing_reason: "subscription_cycle"`, the additional invoice and subscription, and `checkout_id: null`. |
| 19:10:20.968 | Charge still `processing`, amount paid $0, amount remaining $10. Two exact PATCH replays while active had returned the original period; no duplicate invoice was observed. |
| Approximately 19:13:30 | Payment still processing; dashboard invoice was Open. No additional paid or failed invoice event was observed. |
| 19:16:20.213 | Final pre-cancellation payment read still showed processing, $0 paid/$10 remaining. |
| 19:16:34.452462 | Immediate cancellation of the test subscription succeeded with HTTP 200, `status: canceled`, and `next_billed_at: null`. |
| 19:16:43.596 | Read-back confirmed cancellation and no future billing date. The fictional customer's only subscription was this canceled one. The cycle charge remained processing; event history added `customer.subscription.deleted` at 19:16:34.536566 but no additional `invoice.paid` or `invoice.payment_failed`. |

**Final test status: initiation verified, settlement unverified; test subscription cancellation verified.** The additional charge remains pending, not confirmed successful or failed. The original `invoice.created` event is a snapshot and cannot be used as a current invoice-status query. Replay after entering a second trial, lost responses, decline recovery, and stopped-worker behavior remain untested. Cancellation was exercised while collection was pending and removed future scheduled billing, but no terminal outcome for that existing charge was observed.

The scratch file named `refill-01-proof.json` contains the **initial** paid invoice `inv_b0c782d098e747a08b4c`; despite its name, it is not refill-settlement evidence. `refill-01-pending-charge.json`, `end-trial-01-second-replay.json`, and `refill-01-final-observation.json` identify the separate pending cycle charge. `subscription-cleanup-request.json`, `subscription-cleanup-response.json`, and `subscription-cleanup-verification.json` record the cancellation and final read-back. No production billing code or live Bachs products were changed.

## Prepared support report for Bachs (not sent)

**Subject:** Sandbox trial-ending cycle charge remains processing after successful paid-start subscription

We are testing customer-authorized $10 AI credit refills in sandbox only. The paid-start checkout `chk_VqVJXwTElrEYzlDn` for product `prod_1c89b4347db14d579fff` succeeded, producing subscription `sub_f39e480f57aa4890b33e` and paid invoice `inv_b0c782d098e747a08b4c` at 2026-09-16 19:04:59.343737 UTC.

We then sent these separate requests to `PATCH /v1/subscriptions/sub_f39e480f57aa4890b33e`:

1. Body `{"trial_end":"2026-09-23T19:06:11.523Z"}`, idempotency key `layerrail-sandbox-refill-20260916-park-01`. Response became `trialing`.
2. Body `{"trial_end":"2026-09-16T19:06:31.272Z"}`, idempotency key `layerrail-sandbox-refill-20260916-end-01`. Response became `active` and reset the period at 19:06:32.542310 UTC.

The second request created invoice `inv_e4eabee92f864bf48f52` and charge `ch_2fe7d57f55664fb7b26a78b62d1eb5c0` at 19:06:32.864170 UTC. Payment retrieval reports `subscription_cycle`, `checkout_id: null`, $10 USD, and `processing`. At 19:16:20.213 UTC it still showed $0 paid/$10 remaining; the dashboard invoice was Open, with no matching paid or failed event. Your trial guide says ending a trial charges the first cycle right away. Is this pending state expected in sandbox, or does its automatic collection worker need investigation? What terminal event and reconciliation path should we expect?

To prevent further scheduled test billing, we canceled this subscription immediately through the documented DELETE operation. HTTP 200 returned `canceled_at: "2026-09-16T19:16:34.452462Z"` and `next_billed_at: null`. Read-back at 19:16:43.596 UTC confirmed that state and a `customer.subscription.deleted` event, but the existing cycle charge was still processing with $0 paid. We are not treating cancellation as proof that the pending charge was canceled. Please clarify its expected remaining lifecycle.

Two exact replays while active returned the same response and period without another invoice observed. We have not replayed after another deferral or initiated another refill while this charge is pending. Please confirm PATCH idempotency scope/retention and its behavior after the subscription re-enters trial. Separately, is repeated trial cycling supported for refills, and is there a provider-enforced hold or direct off-session collection API that prevents calendar charges when our worker is unavailable? A finite trial alone cannot provide that guarantee.

An earlier seven-day free-trial setup for product `prod_07dc2a6879d140a18530` also remained on `Processing` without creating a subscription; the paid-start path above was a separate test. The final customer subscription list contained only the canceled paid-start subscription. No real funds or card details were used. Settlement remains unverified; this report has not been sent.

## Sources

- [Trials: active-to-trial and trial-ending collection](https://docs.bachs.io/guides/subscriptions/trials)
- [Managing subscriptions and cancellation](https://docs.bachs.io/guides/subscriptions/manage)
- [Proration and unsupported reset behavior](https://docs.bachs.io/guides/subscriptions/proration)
- [Payment recovery](https://docs.bachs.io/guides/subscriptions/failed-payments)
- [API Standards](https://docs.bachs.io/api-reference/api-standards)
- [Idempotency scope and retention](https://docs.bachs.io/guides/idempotency)
- [List webhook events](https://docs.bachs.io/api-reference/webhooks/list-webhook-events)
- [Retrieve a webhook event](https://docs.bachs.io/api-reference/webhooks/retrieve-a-webhook-event)
- [Paid invoice event](https://docs.bachs.io/guides/webhooks/events/invoice-paid)
- [Public OpenAPI schema](https://docs.bachs.io/docs/openapi/openapi.json)
