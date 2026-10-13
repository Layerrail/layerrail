# Getting started with LayerRail

Choose the hosted platform to manage resources, or run the control plane locally
to explore and contribute to the API and dashboard.

## Hosted dashboard

1. Open [console.layerrail.com](https://console.layerrail.com), create an account,
   and verify your email.
2. Create or select a project. Its resources, members, access tokens, and usage
   are managed together.
3. Complete the project's billing setup before creating paid resources or
   using paid inference.
4. Choose an available service, region, and configuration in the dashboard.

The available services and models depend on the deployment's configuration and
your project access. A model marked unavailable cannot serve inference requests.

## Infrastructure API

From your project, open **Personal Access Tokens** and choose **Create Token**.
The dashboard route is `/project/YOUR_PROJECT_ID/token`. Tokens are tied to your
account and project. Configure their access controls for the work they need to
perform; they cannot exceed your account's permissions.

Store the token in an environment variable and make a read-only request:

```sh
export LR_TOKEN="pat-YOUR_PERSONAL_ACCESS_TOKEN"
export PROJECT_ID="YOUR_PROJECT_ID"

curl --fail-with-body \
  "https://api.console.layerrail.com/project/${PROJECT_ID}/vm" \
  -H "Authorization: Bearer ${LR_TOKEN}"
```

The response is a paginated collection. VM entries include their ID, name,
state, location, size, storage, and address information. Useful read endpoints:

| Endpoint | Returns |
| --- | --- |
| `GET /project` | Projects visible to your account |
| `GET /project/{project_id}/vm` | Virtual machines in the project |
| `GET /project/{project_id}/postgres` | PostgreSQL databases |
| `GET /project/{project_id}/kubernetes-cluster` | Kubernetes clusters |
| `GET /project/{project_id}/load-balancer` | Load balancers |
| `GET /project/{project_id}/audit-log` | Project audit logs |

Use the hosted API origin `https://api.console.layerrail.com`. The
[OpenAPI specification](../openapi/openapi.yml) contains infrastructure schemas
and operation details. The [`lr` CLI](../cli/README.md) also uses `LR_TOKEN` for
authentication.

## AI API and playground

Inference uses a separate key from infrastructure automation. Create an
**Inference API Key** in your project's dashboard at
`/project/YOUR_PROJECT_ID/inference-api-key`.

```sh
export LAYERRAIL_AI_KEY="YOUR_INFERENCE_API_KEY"

curl --fail-with-body https://api.console.layerrail.com/v1/models \
  -H "Authorization: Bearer ${LAYERRAIL_AI_KEY}"
```

Check model availability in the dashboard catalog and use the playground to
try an enabled model. Request formats vary by model and adapter:

| Endpoint | Purpose |
| --- | --- |
| `POST /v1/chat/completions` | Supported chat-completion models |
| `POST /v1/responses` | Supported Responses models |
| `POST /v1/embeddings` | Supported embedding models |

For example, an enabled GPT-6.1 Sol deployment supports synchronous Responses:

```sh
curl --fail-with-body https://api.console.layerrail.com/v1/responses \
  -H "Authorization: Bearer ${LAYERRAIL_AI_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-6.1-sol",
    "input": "Explain what a cloud control plane does in one paragraph.",
    "reasoning": {"effort": "low"},
    "max_output_tokens": 1024,
    "store": false
  }'
```

All newly metered inference is paid. A verified payment method is required;
existing monetary project credits can cover usage. LayerRail generates separate
AI usage invoices and collects payment through Bachs checkout. Pending payment
can suspend additional inference.

Read [model compatibility notes](gpt-6-catalog.md),
[paid usage billing](paid-inference-billing.md), and
[Bachs checkout integration](bachs-usage-billing.md) for the full behavior.

## Local Docker demo

Prerequisites: Git, Docker with Compose, and a POSIX shell. On Windows, use WSL
or another POSIX shell. Ports **3000** and **5432** must be available.

```sh
git clone https://github.com/layerrail/layerrail.git
cd layerrail
./demo/generate_env
docker compose -f demo/docker-compose.yml up --build
```

The generator creates `demo/.env` with local database credentials and encryption
secrets. It refuses to overwrite an existing file; retain it for subsequent
starts.

| Service | What it runs |
| --- | --- |
| `layerrail-postgres` | PostgreSQL 17.6 for control-plane state |
| `layerrail-db-migrator` | `bundle exec rake dev_up` |
| `layerrail-app` | The `Procfile` web, respirate, and monitor processes |

Open [localhost:3000](http://localhost:3000) after the migrations finish. Account
verification is disabled by default in local development. If you enable it
without configuring an email provider, messages use the local logger. To inspect
application logs:

```sh
docker compose -f demo/docker-compose.yml logs -f app
```

Stop the stack while retaining the database volume:

```sh
docker compose -f demo/docker-compose.yml down
```

The demo does not include cloud accounts, resource capacity, or provider
credentials. Configure those prerequisites to provision real resources.
Production AI and paid resources also require the relevant service and billing
configuration.

## Deploying the control plane

The web service and workers must use the **same control-plane database**. Apply
migrations before running a compatible application release:

```sh
RACK_ENV=production bundle exec rake prod_up
```

Run these processes from the same revision:

| Process | Command |
| --- | --- |
| Web | `bundle exec puma -C puma_config.rb` |
| Provisioning worker | `bin/restarter bin/respirate` |
| Monitoring worker | `bin/monitor` |

Build dashboard assets with `npm ci` and `npm run prod`. The repository's
Dockerfile builds the frontend assets and Ruby dependencies into its runtime
image. The Docker demo uses development configuration; configure a production
deployment explicitly.

### Core configuration

See [`config.rb`](../config.rb) for the complete configuration and defaults.
Use your deployment's secret manager for credentials.

| Area | Configuration |
| --- | --- |
| Application and database | `RACK_ENV=production`, `CLOVER_DATABASE_URL` |
| Security | `CLOVER_SESSION_SECRET`, `CLOVER_COLUMN_ENCRYPTION_KEY`; configure `CLOVER_RUNTIME_TOKEN_SECRET` where required |
| Public origins | `BASE_URL` for the dashboard, `API_URL` for the API; route both domains to the application |
| Email | `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET` |
| Billing | `BACHS_API_KEY`, `BACHS_WEBHOOK_SECRET`, and the prerequisites in the [Bachs guide](bachs-usage-billing.md) |
| Compute | `COMPUTE_PROVIDER` and credentials for that provider |
| DNS automation | `CLOUDFLARE_DNS_API_TOKEN`, `CLOUDFLARE_DNS_ZONE_ID` |
| Optional services | `POSTGRES_ENABLED`, `KUBERNETES_ENABLED`, and their service prerequisites |
| AI inference | `AI_INFERENCE_ENABLED`, `AI_INFERENCE_PROVIDER`, and credentials for enabled providers |

The current compute configuration defaults to Azure. Its credentials are
`AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, and
`AZURE_CLIENT_SECRET`. Configure the matching provider and enabled locations
together. PostgreSQL and Kubernetes use VM-backed infrastructure managed by
LayerRail; they are separate from Azure Database for PostgreSQL and AKS.

Generated customer service hostnames, such as `lb.layerrail.com`,
`postgres.layerrail.com`, and `k8s.layerrail.com`, are distinct from the dashboard
and API origins. Configure the relevant DNS zones for your own deployment.

For inference provider setup, read the [Azure guide](gpt-6-astra.md) and
[Cloudflare catalog notes](cloudflare-model-pricing.md). A catalog entry alone
does not configure a provider deployment, quota, or functioning metering.

## Development and contribution

The version pins are in [`.tool-versions`](../.tool-versions). Follow
[DEVELOPERS.md](../DEVELOPERS.md) for database setup, development environment,
tests, and provider host configuration. Follow
[CONTRIBUTING.md](../CONTRIBUTING.md) for contribution scope and code style.
Report vulnerabilities through [SECURITY.md](../SECURITY.md).
