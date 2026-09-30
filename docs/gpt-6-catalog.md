# GPT-6 models on LayerRail

Verified September 30, 2026 against official Azure/OpenAI documentation and
LayerRail's configured Azure endpoint.

| Catalog model | Azure model version | Deployment status | Context / maximum output |
| --- | --- | --- | --- |
| GPT-6.1 Sol (`gpt-6.1-sol`) | 2026-09-29 | Live; chat, Responses, and function calling verified | 1,050,000 / 128,000 |
| GPT-6 Astra (`gpt-6-astra`) | 2026-09-03 | Existing live deployment; Responses verified | 1,050,000 / 128,000 |
| GPT-6 Sol (`gpt-6-sol`) | 2026-09-22 | Catalog entry; deployment not yet available | 1,050,000 / 128,000 |
| GPT-6 Luna (`gpt-6-luna`) | 2026-09-22 | Catalog entry; deployment not yet available | 1,050,000 / 128,000 |

Input and output share the context budget. Azure states a 922,000 input limit
when reserving the full 128,000 output budget. Catalog-only entries remain
visible with an unavailable state; inference requests are rejected before
calling Azure or recording customer usage. Listing a model in Azure's public
`/openai/v1/models` response does not create an Azure deployment.

## LayerRail retail prices

USD per million tokens, billed from actual provider-reported input/output usage.
All premium Azure models now receive an automatic 50% discount from LayerRail's
standard retail rates. The standard baseline uses the existing 40% Azure markup;
the Cloudflare 10% markup is a separate pricing policy. The promotion applies to
new usage and has no scheduled expiry. Historical usage keeps its saved price.

| Model | Input | Output | Input above 272,000 tokens | Output on those requests |
| --- | ---: | ---: | ---: | ---: |
| GPT-6.1 Sol | $1.40 | $7.00 | $2.80 | $10.50 |
| GPT-6 Sol (unavailable) | $1.40 | $7.00 | $2.80 | $10.50 |
| GPT-6 Luna (unavailable) | $0.07 | $0.35 | $0.14 | $0.525 |
| GPT-6 Astra | $5.00 | $25.00 | $5.00 | $25.00 |

The larger-context rates apply to the **entire request** when actual input
exceeds 272,000 tokens, including requests with cached input. Exactly 272,000
uses the base rate. GPT-6 Astra retains a flat tariff for large requests; the
promotion halves its previous $10 input / $50 output rate. Original retail
prices remain in `tags.standard_pricing` for comparison. See
[premium model discount](premium-model-discount.md) for the billing cutover.

Sol and Luna's upstream baseline is Azure Global Standard pricing. Azure has
not yet published GPT-6.1 Sol on its pricing page; its provisional upstream
baseline is the official OpenAI model price. These are LayerRail customer
prices, not a claim that Azure's eventual price is confirmed. Azure deployment
type, regional prices, and billing statements should be checked when adjusting
the upstream baseline.

LayerRail bills all input at its stated input rate and does not advertise a
separate cached-input discount or cache-write charge for these entries. The
provider's cached/input totals are not billed twice. Output usage includes
reasoning tokens where the provider includes them in output totals.

## API compatibility

Use `https://api.console.layerrail.com/v1/chat/completions` for synchronous chat or
`https://api.console.layerrail.com/v1/responses` for synchronous Responses. Both use
LayerRail API keys and the normal paid-inference access checks.

- GPT-6.1 Sol and Astra tool calls require Responses. Sol and Luna chat function
  calls require `reasoning_effort: "none"`; use Responses for reasoning with tools.
- GPT-6.1 Sol and Astra support `low`, `medium`, `high`, `xhigh`, and `max`
  reasoning. Sol and Luna additionally support `none`. `minimal` is unsupported.
- Azure supports `max` reasoning through `/v1/responses`. Chat requests with
  `reasoning_effort: "max"` return a clear 400 directing callers to Responses.
- Reasoning requests discard unsupported sampling/log-probability parameters.
  Sol/Luna preserve those parameters when `none` is explicitly selected.
- Chat `max_tokens` is normalized to `max_completion_tokens`; Responses token
  aliases become `max_output_tokens`. Custom Azure deployment names are supported.
- Streaming and background execution remain unsupported by the Azure adapter;
  it rejects these requests with a clear 400 before calling Azure.

```json
{
  "model": "gpt-6.1-sol",
  "input": "Explain this deployment plan.",
  "reasoning": {"effort": "low"},
  "max_output_tokens": 1024,
  "store": false
}
```

Usage enters LayerRail's existing separate inference-usage invoices and Bachs
checkout flow. This addition does not create payment products or a new billing
provider.

## Verification and deployment

`bundle exec ruby bin/verify_azure_gpt6` checks every available configured GPT-6
entry using three small upstream requests: chat, Responses, and a strict
function call. It verifies the served model identity, result, and positive
token usage. These requests incur small Azure usage costs but do not create
customer billing records, invoices, or payments. Explicit model arguments can
be used when activating a newly created deployment.

The production endpoint already has GPT-6.1 Sol and Astra. The existing ARM
credentials do not expose the Foundry resource's Cognitive Services account,
so provisioning Sol/Luna requires management access to that resource. Create
deployments with the exact names/versions above, run the live checker, then
remove their unavailable metadata. Existing Foundry endpoint/key variables
remain suitable for GPT-6.1 Sol.

## Sources

- [Azure models](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure)
- [Azure region availability](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)
- [Azure pricing](https://azure.microsoft.com/en-us/pricing/details/cognitive-services/openai-service/)
- [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol)
- [GPT-6 request compatibility](https://developers.openai.com/api/docs/guides/latest-model)
