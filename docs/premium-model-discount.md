# Premium model discount

All Azure Foundry models in LayerRail's premium catalog are 50% off their
standard LayerRail token prices, automatically applied to new usage. The
promotion has no scheduled expiry. No coupon or separate Bachs product is
required. Cloudflare Workers AI pricing remains published prices plus 10%.

The catalog stores `discount_percent: 50`, the original `standard_pricing`,
and discounted `pricing`. Base input/output prices and all configured
GPT-6 long-context prices receive the same discount. The catalog and
playground show the active prices. Existing availability restrictions stay
in place; a discount does not activate an unavailable Azure deployment.

USD per million tokens:

| Available model | Standard input / output | Discounted input / output |
| --- | --- | --- |
| GPT-6.1 Sol, up to 272,000 input tokens | $2.80 / $14.00 | $1.40 / $7.00 |
| GPT-6.1 Sol, above 272,000 input tokens | $5.60 / $21.00 | $2.80 / $10.50 |
| GPT-6 Sol, up to 272,000 input tokens | $2.80 / $14.00 | $1.40 / $7.00 |
| GPT-6 Sol, above 272,000 input tokens | $5.60 / $21.00 | $2.80 / $10.50 |
| GPT-6 Luna, up to 272,000 input tokens | $0.14 / $0.70 | $0.07 / $0.35 |
| GPT-6 Luna, above 272,000 input tokens | $0.28 / $1.05 | $0.14 / $0.525 |
| GPT-6 Astra | $10.00 / $50.00 | $5.00 / $25.00 |
| Claude Sonnet 5 | $4.20 / $21.00 | $2.10 / $10.50 |
| GPT-5 | $1.75 / $14.00 | $0.875 / $7.00 |

## Billing cutover

`config/billing_rates/ai.yml` appends 76 new rate versions effective
`2026-09-30T18:35:00Z`. The discount starts on each application process when
the release with these rates is deployed. Historical rate rows are unchanged,
including their UUIDs and prices. The original rate is selected at or before
the cutover timestamp; the new rate is selected afterwards.

The inference meter groups daily records by rate UUID and saved unit price,
so usage before and after the cutover creates separate records even for the
same model, project, API key, and day. Invoice settlement uses each record's
original price. Existing usage and invoices are not retroactively discounted.
The promotion does not apply a second discount during invoice generation.

Monetary credits, the $10 collection threshold, separate usage invoices,
Bachs checkout, payment confirmation, and pause/resume rules are unchanged.
Azure's upstream bill is unchanged; some discounted retail rates are below
LayerRail's provider cost.

## Verification

Run `bundle exec ruby bin/verify_premium_model_discount` to check all premium
rate versions, original rate IDs, catalog prices, long-context prices, and
Cloudflare exclusion. It is read-only and creates no usage or invoices.

Regression specs cover rate history, daily record splitting, invoice
settlement across the cutover, catalog serialization, playground display,
and actual GPT-6 token metering on both API paths.
