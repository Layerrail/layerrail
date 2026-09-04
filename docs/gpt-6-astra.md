# GPT-6 Astra on Azure Foundry

LayerRail exposes `gpt-6-astra` in its model catalog, playground, and authenticated
`GET /v1/models` response when the Azure Foundry provider is enabled. The existing
default model and premium trial offer remain unchanged.

## Azure configuration

Deploy the Azure model `gpt-6-astra` (version `2026-09-03`) on the Foundry resource
used by LayerRail. Catalog availability alone does not create a deployment or
grant quota on a subscription. The configured deployment name is `gpt-6-astra`;
if your deployment has another name, update this model's `tags.deployment` in
`config/ai_models.yml`.

Set the application's existing configuration:

```text
AI_INFERENCE_ENABLED=true
AI_INFERENCE_PROVIDER=azure_foundry
AZURE_FOUNDRY_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com
AZURE_FOUNDRY_API_KEY=<set through your secret manager>
```

Include `azure_foundry` in the comma-separated provider list when using multiple
providers. The resource's `.openai.azure.com` endpoint is also supported. Restart
or redeploy the application after changing its environment or model catalog.

## Supported request paths

- `POST /v1/chat/completions`: standard chat, image inputs, and structured output.
  Legacy `max_tokens` is converted to `max_completion_tokens`. Astra does not
  accept `temperature` or `top_p`, so LayerRail removes those parameters,
  including the playground's defaults.
- `POST /v1/responses`: native Azure Responses requests and responses, preserving
  reasoning settings, tool calls and outputs, images, and JSON schemas. Use this
  path for reasoning with tools and the `max` reasoning effort.

Both paths use Azure's `/openai/v1/` API. Older models retain their existing
versioned endpoint and Responses adapter. Native Responses requests preserve
Azure errors and do not fall back to another model. Chat requests follow the
existing `PREMIUM_AI_RATE_LIMIT_FALLBACK_ENABLED` setting and identify the served
model in the `X-LayerRail-AI-Model` response header.

LayerRail's Azure adapter supports synchronous JSON responses. For Astra,
`stream: true` and `background: true` produce a clear HTTP 400 before any upstream
request, since LayerRail does not yet proxy Azure streaming or background polling.

The model has a 1,050,000-token context window, up to 922,000 input tokens and
128,000 output tokens, subject to the shared context budget. LayerRail's initial
retail rates are $10 per million input tokens and $50 per million output tokens.
Both the catalog and billing registry use these rates, including output reasoning
tokens reported by Azure. The existing flat-rate meter does not separately price
cached tokens or long-context requests. OpenAI documents higher upstream rates
above 272,000 input tokens; account for the Azure deployment's actual rates when
setting LayerRail's retail pricing.

## Verification

Run the application regression specs in the normal development/test environment:

```sh
bundle exec rspec spec/lib/azure_foundry_client_spec.rb spec/lib/clover_azure_foundry_inference_spec.rb spec/routes/api/v1/models_spec.rb spec/routes/web/inference_playground_spec.rb
```

With the Azure endpoint and key set, run the live deployment check:

```sh
bundle exec ruby bin/verify_azure_astra
```

This makes three small billable requests: Chat Completions, Responses, and a
Responses function call. It verifies the actual model identity, content, tool
arguments, and token usage, and exits unsuccessfully on an Azure error or a
different served model. It uses the deployment name from the same catalog as the
application. For this standalone check, the equivalent `AZURE_OPENAI_ENDPOINT`
and `AZURE_OPENAI_API_KEY` environment variables are also accepted. No keys are
printed or written to disk.

The live check verifies Azure connectivity and deployment availability; the
route and playground specs verify LayerRail's application integration.

## References

- [OpenAI GPT-6 Astra model documentation](https://developers.openai.com/api/docs/models/gpt-6-astra)
- [Microsoft Azure reasoning model APIs and parameter support](https://learn.microsoft.com/en-us/azure/foundry/openai/how-to/reasoning)
