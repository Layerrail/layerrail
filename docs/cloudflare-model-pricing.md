# Cloudflare model catalog and pricing

Verified September 16, 2026. LayerRail quotes Cloudflare's published model prices plus **10%**. Quotes retain the published units and pricing conditions. They are not a promise that an unavailable model can run, and they are not substituted for the token rates used to calculate invoices.

The configuration contains **239 Cloudflare models**: all **220 current official catalog entries** (65 native Workers AI models and 155 provider-backed models), plus **19 preserved legacy models** that no longer appear in that snapshot. All 79 previously configured Cloudflare identifiers and all 34 non-Cloudflare configurations are preserved. The combined configuration contains 273 models.

**19 native models are available for paid inference on the current Workers Free account.** All 155 provider-backed models remain catalog-only, including MiniMax M3 at the owner's explicit request. Of the other 65 native or legacy models, 34 are unavailable, 19 use unsupported billing units, and 12 lack verified usage metering. Adding catalog entries does not enable their inference adapters or authorize estimated charges.

## Sources and exact quotes

The current catalog is frozen at Cloudflare documentation commit [`63a072c88b9c6927c3263ff01f2a4dc8767691bf`](https://github.com/cloudflare/cloudflare-docs/tree/63a072c88b9c6927c3263ff01f2a4dc8767691bf/src/content). The provider-backed files were retrieved at approximately 20:11 UTC and native files at approximately 20:13 UTC on September 16, 2026. Each source file's Git blob SHA was verified. Canonical identifiers, capitalization, context limits, task names, price labels, and provider-backed identifiers come from that snapshot.

- [Native Workers AI catalog](https://github.com/cloudflare/cloudflare-docs/tree/63a072c88b9c6927c3263ff01f2a4dc8767691bf/src/content/workers-ai-models)
- [Provider-backed catalog](https://github.com/cloudflare/cloudflare-docs/tree/63a072c88b9c6927c3263ff01f2a4dc8767691bf/src/content/catalog-models)
- [Workers AI pricing table](https://developers.cloudflare.com/workers-ai/platform/pricing/) for native entries lacking a price property and retained legacy quotes
- [Prompt caching guide](https://developers.cloudflare.com/workers-ai/features/prompt-caching/) for cached-token accounting

`config/cloudflare_catalog_pricing.json` contains the complete 239-model display-price mapping and **622 price rows**. Every positive provider price and its 10% markup are stored as exact decimal strings. Each row preserves its published label and unit text, source URL, and the applicable context, resolution, duration, cache, or other condition. The per-model metadata records the snapshot commit, retrieval time, USD currency, and 10% markup. Legacy pricing is explicitly identified as an earlier pricing-table audit; those models remain unavailable.

Three current native entries publish a zero-valued step price. Their quote has `provider_price: "0"`, `price: null`, and `note: "Pricing unavailable"`; zero is not displayed as free inference. Nineteen models have no supported price evidence and retain an empty quote list. A quoted per-minute, per-image, per-character, per-step, or per-second amount is never converted into a token billing rate. Fixed-duration quotes and context thresholds retain their published wording. No batch discount is inferred.

Native catalog prices take precedence over rounded prices in the central table. This matters, for example, for Llama 3.2 3B's published $0.0509 input price instead of the table's rounded $0.051. The 45 existing input/output/cache rates for previously available models exactly match the current source prices plus 10%. Their rate IDs and amounts are unchanged. The five newly supported native models add 15 rates with new IDs, effective September 16, 2026 at 00:00 UTC; existing historical rows and invoices are unchanged.

## Configured token rates

These are configured LayerRail prices in USD per million tokens. Rows marked “Workers Paid required” remain catalogued and priced but are unavailable on the current account. Actual invoice calculation uses the dated billing resources in `config/billing_rates/cloudflare.yml`; display quotes live separately in `config/cloudflare_catalog_pricing.json`.

| Model | Input | Output | Cached input | Current availability |
|---|---:|---:|---:|---|
| `@cf/meta/llama-3.2-3b-instruct` | 0.05599 | 0.3685 | — | Available |
| `@cf/openai/gpt-oss-20b` | 0.22 | 0.33 | — | Available |
| `@cf/openai/gpt-oss-120b` | 0.385 | 0.825 | — | Available |
| `@cf/aisingapore/gemma-sea-lion-v4-27b-it` | 0.3861 | 0.6105 | — | Available |
| `@cf/deepseek-ai/deepseek-r1-distill-qwen-32b` | 0.5467 | 5.3691 | — | Available |
| `@cf/google/gemma-4-26b-a4b-it` | 0.11 | 0.33 | — | Available |
| `@cf/ibm-granite/granite-4.0-h-micro` | 0.0187 | 0.1232 | — | Available |
| `@cf/meta/llama-3.1-8b-instruct-fp8` | 0.1672 | 0.3157 | — | Available |
| `@cf/meta/llama-3.2-1b-instruct` | 0.0297 | 0.2211 | — | Available |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | 0.3223 | 2.4783 | — | Available |
| `@cf/meta/llama-4-scout-17b-16e-instruct` | 0.297 | 0.935 | — | Available |
| `@cf/meta/llama-guard-3-8b` | 0.5324 | 0.033 | — | Available |
| `@cf/mistralai/mistral-small-3.1-24b-instruct` | 0.3861 | 0.6105 | — | Available |
| `@cf/moonshotai/kimi-k2.6` | 1.045 | 4.4 | 0.176 | Workers Paid required |
| `@cf/moonshotai/kimi-k2.7-code` | 1.045 | 4.4 | 0.209 | Workers Paid required |
| `@cf/nvidia/nemotron-3-120b-a12b` | 0.55 | 1.65 | — | Available |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | 0.726 | 1.1 | — | Available |
| `@cf/qwen/qwen3-30b-a3b-fp8` | 0.05599 | 0.3685 | — | Available |
| `@cf/qwen/qwq-32b` | 0.726 | 1.1 | — | Available |
| `@cf/zai-org/glm-4.7-flash` | 0.06655 | 0.44 | — | Available |
| `@cf/zai-org/glm-5.2` | 1.54 | 4.84 | 0.286 | Workers Paid required |
| `@cf/deepseek-ai/deepseek-v4-flash-0731` | 0.484 | 1.452 | 0.0154 | Workers Paid required |
| `@cf/deepseek-ai/deepseek-v4-pro-0813` | 1.452 | 4.356 | 0.0484 | Workers Paid required |
| `@cf/qwen/qwen3.8-27b` | 0.495 | 3.52 | 0.055 | Available |
| `@cf/zai-org/glm-5.3` | 1.54 | 4.84 | 0.286 | Workers Paid required |
| `@cf/zai-org/glm-5.3-flash` | 0.165 | 0.55 | 0.033 | Workers Paid required |

Cached input is included in the provider's prompt total. LayerRail subtracts the authoritative cached count before charging ordinary input and bills that count once at the separate cached rate. Invalid, contradictory, negative, fractional, or over-total counts are rejected. For native models using Cloudflare's documented cache contract, omitted cached counts mean zero on a cold request. The five new native models have provider schemas with prompt/completion/total usage and nested cached counts compatible with this meter.

GPT OSS 20B and 120B retain the Responses route; the five new native text models use the native run route. Existing routes are preserved. BGE embeddings and Moondream 3.1 remain unavailable because their checked outputs did not establish authoritative token usage. Model availability requires both a supported request/usage contract and a positive validated billing rate. The provider account's free quota does not make LayerRail inference free.

## Workers Paid account restriction

The production Cloudflare account uses Workers Free. The official native catalog marks seven models with `require_workers_paid: true`: Kimi K2.6, Kimi K2.7 Code, GLM 5.2, GLM 5.3, GLM 5.3 Flash, DeepSeek V4 Flash 0731, and DeepSeek V4 Pro 0813. A bounded Kimi K2.6 request on that account confirmed HTTP 403, Cloudflare error 5035, requiring Workers Paid.

These seven entries retain `enabled: true`, published quotes, billing resource names, and historical rates, but use `billing_status: unavailable`. Existing request validation rejects them before calling the provider, and catalog/API availability is false while price quotes remain visible. No paid-plan purchase or automatic upgrade is included. If the account plan changes, verify provider access before restoring their `ready` status.

## MiniMax M3

`minimax/m3` is retained with `billing_status: catalog_only`. It is listed and priced, but cannot be selected for billable inference. The catalog publishes a context limit of 1,000,000 tokens and a maximum output of 4,096 tokens. Its published price tiers are preserved verbatim; they are display metadata only.

| Published condition | Cloudflare USD per million | LayerRail USD per million (+10%) |
|---|---:|---:|
| Input <=512k (per 1M) | 0.3 | 0.33 |
| Output <=512k (per 1M) | 1.2 | 1.32 |
| Cached input <=512k (per 1M) | 0.06 | 0.066 |
| Input >512k (per 1M) | 1.2 | 1.32 |
| Output >512k (per 1M) | 4.8 | 5.28 |
| Cached input >512k (per 1M) | 0.24 | 0.264 |

[Cloudflare's MiniMax M3 source](https://github.com/cloudflare/cloudflare-docs/blob/63a072c88b9c6927c3263ff01f2a4dc8767691bf/src/content/catalog-models/minimax-m3.json) is authoritative for these Cloudflare quotes. The higher-context rates differ from MiniMax's direct-provider pricing. No tier boundary is guessed or used to charge requests, and no funding or activation flow is part of this catalog update.

## Verification

Data validation checks the 239-model union, 273 total configurations, unique model and billing-rate IDs, explicit availability for every Cloudflare model, 19 ready models, preserved existing identifiers/resources/routes, unchanged non-Cloudflare blocks, unchanged historical rates, and exact 10% quote arithmetic. The API exposes catalog quotes separately from actual billable token prices; unavailable models have no callable billing rate in that API response.
