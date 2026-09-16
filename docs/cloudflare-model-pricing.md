# Cloudflare model pricing

Verified September 16, 2026. LayerRail charges published model rates plus **10%**. Prices below are USD per million tokens. The provider account’s free quota does not grant free LayerRail usage. Existing historical rate IDs and billing records are unchanged.

The catalog previously assigned all 78 Cloudflare models zero-price preview resources. Each now has its own resource family. Only models with verified positive prices and supported provider token counts are billable. Other models remain visible as unavailable; no estimated token counts or non-token units are charged as tokens.

Current model cards take precedence over the rounded [Workers AI pricing table](https://developers.cloudflare.com/workers-ai/platform/pricing/). Cached input is deducted from total prompt tokens and billed separately where a cache rate is published. Cloudflare documents that a cold request can omit cached counts in its [prompt caching guide](https://developers.cloudflare.com/workers-ai/features/prompt-caching/).

A bounded live Responses request for GPT OSS 20B returned input/output usage. GPT OSS 20B and 120B use `/v1/responses`. A BGE small embeddings request returned no usage; embeddings remain unavailable pending authoritative metering. Native schemas document usage for the other enabled models.

| Model | Input | Output | Cached input | Availability | Source |
|---|---:|---:|---:|---|---|
| `@cf/meta/llama-3.2-3b-instruct` | 0.05599 | 0.3685 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.2-3b-instruct/) |
| `@cf/openai/gpt-oss-20b` | 0.22 | 0.33 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/gpt-oss-20b/) |
| `@cf/openai/gpt-oss-120b` | 0.385 | 0.825 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/gpt-oss-120b/) |
| `@cf/pipecat-ai/smart-turn-v2` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/smart-turn-v2/) |
| `@cf/deepgram/flux` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/flux/) |
| `@cf/deepgram/nova-3` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/nova-3/) |
| `@cf/openai/whisper` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/whisper/) |
| `@cf/openai/whisper-large-v3-turbo` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/whisper-large-v3-turbo/) |
| `@cf/openai/whisper-tiny-en` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/whisper-tiny-en/index.md) |
| `@cf/microsoft/resnet-50` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/resnet-50/) |
| `@cf/llava-hf/llava-1.5-7b-hf` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/llava-1.5-7b-hf/index.md) |
| `@cf/baai/bge-reranker-base` | 0.003421 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/bge-reranker-base/) |
| `@cf/huggingface/distilbert-sst-2-int8` | 0.02893 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/distilbert-sst-2-int8/) |
| `@cf/baai/bge-base-en-v1.5` | 0.07326 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/bge-base-en-v1.5/) |
| `@cf/baai/bge-large-en-v1.5` | 0.2244 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/bge-large-en-v1.5/) |
| `@cf/baai/bge-m3` | 0.01298 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/bge-m3/) |
| `@cf/baai/bge-small-en-v1.5` | 0.02222 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/bge-small-en-v1.5/) |
| `@cf/google/embeddinggemma-300m` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/embeddinggemma-300m/index.md) |
| `@cf/pfnet/plamo-embedding-1b` | 0.02046 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/plamo-embedding-1b/) |
| `@cf/qwen/qwen3-embedding-0.6b` | 0.01298 | — | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/qwen3-embedding-0.6b/) |
| `@cf/aisingapore/gemma-sea-lion-v4-27b-it` | 0.3861 | 0.6105 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/gemma-sea-lion-v4-27b-it/) |
| `@cf/moonshotai/kimi-k2.5` | 0.66 | 3.3 | 0.11 | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/deepseek-ai/deepseek-r1-distill-qwen-32b` | 0.5467 | 5.3691 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/deepseek-r1-distill-qwen-32b/) |
| `@cf/google/gemma-2b-it-lora` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/gemma-2b-it-lora/index.md) |
| `@cf/google/gemma-4-26b-a4b-it` | 0.11 | 0.33 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/gemma-4-26b-a4b-it/) |
| `@cf/google/gemma-3-12b-it` | 0.3795 | 0.6116 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/google/gemma-7b-it-lora` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/gemma-7b-it-lora/index.md) |
| `@cf/ibm-granite/granite-4.0-h-micro` | 0.0187 | 0.1232 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/granite-4.0-h-micro/) |
| `@cf/meta-llama/llama-2-7b-chat-hf-lora` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/llama-2-7b-chat-hf-lora/index.md) |
| `@cf/meta/llama-2-7b-chat-fp16` | 0.6116 | 7.3337 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/meta/llama-2-7b-chat-int8` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/llama-2-7b-chat-int8/index.md) |
| `@cf/meta/llama-3-8b-instruct` | 0.3102 | 0.9097 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/google/gemma-7b-it` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/gemma-7b-it/index.md) |
| `@cf/meta/llama-3-8b-instruct-awq` | 0.1353 | 0.2926 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/meta/llama-3.1-8b-instruct` | 0.3102 | 0.9097 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/meta/llama-3.1-8b-instruct-awq` | 0.1353 | 0.2926 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/meta/llama-3.1-8b-instruct-fp8` | 0.1672 | 0.3157 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.1-8b-instruct-fp8/) |
| `@cf/meta/llama-3.1-8b-instruct-fast` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.1-8b-instruct-fast/index.md) |
| `@cf/meta/llama-3.1-70b-instruct` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.1-70b-instruct/index.md) |
| `@cf/meta/llama-3.2-11b-vision-instruct` | 0.05335 | 0.7436 | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.2-11b-vision-instruct/) |
| `@cf/meta/llama-3.2-1b-instruct` | 0.0297 | 0.2211 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.2-1b-instruct/) |
| `@cf/meta/llama-3.3-70b-instruct-fp8-fast` | 0.3223 | 2.4783 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-3.3-70b-instruct-fp8-fast/) |
| `@cf/meta/llama-4-scout-17b-16e-instruct` | 0.297 | 0.935 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-4-scout-17b-16e-instruct/) |
| `@cf/meta/llama-guard-3-8b` | 0.5324 | 0.033 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/llama-guard-3-8b/) |
| `@cf/microsoft/phi-2` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/phi-2/index.md) |
| `@cf/defog/sqlcoder-7b-2` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/sqlcoder-7b-2/index.md) |
| `@cf/mistral/mistral-7b-instruct-v0.2-lora` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/mistral-7b-instruct-v0.2-lora/index.md) |
| `@cf/mistral/mistral-7b-instruct-v0.1` | 0.121 | 0.209 | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/nousresearch/hermes-2-pro-mistral-7b` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/hermes-2-pro-mistral-7b/index.md) |
| `@cf/mistralai/mistral-small-3.1-24b-instruct` | 0.3861 | 0.6105 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/mistral-small-3.1-24b-instruct/) |
| `@cf/moonshotai/kimi-k2.6` | 1.045 | 4.4 | 0.176 | ready | [Source](https://developers.cloudflare.com/workers-ai/models/kimi-k2.6/) |
| `@cf/moonshotai/kimi-k2.7-code` | 1.045 | 4.4 | 0.209 | ready | [Source](https://developers.cloudflare.com/workers-ai/models/kimi-k2.7-code/) |
| `@cf/nvidia/nemotron-3-120b-a12b` | 0.55 | 1.65 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/nemotron-3-120b-a12b/) |
| `@cf/qwen/qwen2.5-coder-32b-instruct` | 0.726 | 1.1 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/qwen2.5-coder-32b-instruct/) |
| `@cf/qwen/qwen3-30b-a3b-fp8` | 0.05599 | 0.3685 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/qwen3-30b-a3b-fp8/) |
| `@cf/qwen/qwq-32b` | 0.726 | 1.1 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/qwq-32b/) |
| `@cf/zai-org/glm-4.7-flash` | 0.06655 | 0.44 | — | ready | [Source](https://developers.cloudflare.com/workers-ai/models/glm-4.7-flash/) |
| `@cf/zai-org/glm-5.2` | 1.54 | 4.84 | 0.286 | ready | [Source](https://developers.cloudflare.com/workers-ai/models/glm-5.2/) |
| `@cf/meta/bart-large-cnn` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/bart-large-cnn/index.md) |
| `@cf/meta/detr-resnet-50` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/detr-resnet-50/index.md) |
| `@cf/unum/uform-gen2-qwen-500m` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/uform-gen2-qwen-500m/index.md) |
| `@cf/black-forest-labs/flux-1-schnell` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/black-forest-labs/flux-2-dev` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/black-forest-labs/flux-2-klein-4b` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/black-forest-labs/flux-2-klein-9b` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/platform/pricing/) |
| `@cf/bytedance/stable-diffusion-xl-lightning` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/stable-diffusion-xl-lightning/) |
| `@cf/leonardo/lucid-origin` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/lucid-origin/) |
| `@cf/leonardo/phoenix-1.0` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/phoenix-1.0/) |
| `@cf/lykon/dreamshaper-8-lcm` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/dreamshaper-8-lcm/index.md) |
| `@cf/runwayml/stable-diffusion-v1-5-img2img` | — | — | — | unavailable | [Source](https://developers.cloudflare.com/workers-ai/models/stable-diffusion-v1-5-img2img/index.md) |
| `@cf/runwayml/stable-diffusion-v1-5-inpainting` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/stable-diffusion-v1-5-inpainting/) |
| `@cf/stabilityai/stable-diffusion-xl-base-1.0` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/stable-diffusion-xl-base-1.0/) |
| `@cf/deepgram/aura-1` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/aura-1/) |
| `@cf/deepgram/aura-2-en` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/aura-2-en/) |
| `@cf/deepgram/aura-2-es` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/aura-2-es/) |
| `@cf/myshell-ai/melotts` | — | — | — | unsupported_unit | [Source](https://developers.cloudflare.com/workers-ai/models/melotts/) |
| `@cf/ai4bharat/indictrans2-en-indic-1B` | 0.3762 | 0.3762 | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/indictrans2-en-indic-1B/) |
| `@cf/meta/m2m100-1.2b` | 0.3762 | 0.3762 | — | usage_unverified | [Source](https://developers.cloudflare.com/workers-ai/models/m2m100-1.2b/) |

## MiniMax M3

Cloudflare lists `minimax/m3` in its unified catalog with a 1M context window and chat-completions support. The configured model stays unavailable: the production account returned HTTP 402, code 2021, “Insufficient balance; add money to your gateway or use BYOK.” No credits were purchased.

The [MiniMax pay-as-you-go table](https://platform.minimax.io/docs/guides/pricing-paygo) publishes $0.30 input / $1.20 output / $0.06 cached input up to “512k”, doubling above it. Standard-context LayerRail rates are $0.33 / $1.32 / $0.066. Cloudflare [documents provider-price passthrough and a 5% credit purchase fee](https://developers.cloudflare.com/ai-gateway/features/unified-billing/); that account-funding fee is not added to this 10% model markup. Prices have not been verified in the authenticated Cloudflare catalog.

Before enabling M3: fund gateway credits or configure an authorized MiniMax BYOK key, verify the Cloudflare prices and exact long-context input boundary, implement the second input/output/cache tier, and perform a successful usage-reporting inference check. The public “512k” label does not specify an exact integer boundary. The model remains gated rather than charging an assumed tier.

## Non-token models

Image, audio, and other models may bill by minutes, characters, generated images, steps, or tiles. Their public unit prices do not make them compatible with LayerRail’s token meter. These models require a corresponding provider usage meter before enabling paid access. Unlisted models and published zero-price legacy entries also stay unavailable.
