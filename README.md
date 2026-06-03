# LayerRail

LayerRail is an open cloud control plane for teams that need infrastructure with
clear ownership, budget rails, and deployment evidence. It brings compute,
networking, managed services, billing context, and operational records into one
project-centered console.

LayerRail is built on the Ubicloud open source infrastructure foundation and
keeps the upstream AGPL-3.0 license and attribution intact. This repository is
the LayerRail product fork: LayerRail-specific workflows, provider integrations,
and product surfaces live here, while Ubicloud remains available as an upstream
source for selected infrastructure improvements.

## Why LayerRail

Modern teams can launch cloud resources quickly, but the evidence around those
resources often becomes scattered: who created them, where they run, what they
cost, which project owns them, and what proof is needed for finance, compliance,
or grant reporting.

LayerRail is designed for developers, research teams, sponsored builders, and
operators who need cloud infrastructure that stays explainable after it has been
deployed.

LayerRail focuses on:

- **Project-centered infrastructure**: resources are grouped around workspaces,
  projects, owners, regions, and runtime context.
- **Budget-aware operations**: usage and pricing records are kept close to the
  resources they describe.
- **Deployment evidence**: runtime, region, owner, provider, and resource state
  can be carried into review, finance, and reporting workflows.
- **Open control plane ownership**: the core control plane remains auditable,
  self-hostable, and source-available under AGPL-3.0 obligations.

## What LayerRail Provides

LayerRail is moving toward a practical PaaS/IaaS control plane with:

- Virtual machines
- Private networking
- Firewalls
- Load balancers
- Managed PostgreSQL
- Kubernetes
- GitHub runners
- AI inference routing surfaces
- Workspace budget controls
- Deployment passports and reporting-friendly infrastructure records

The control plane is a Ruby application backed by Postgres. It uses the same
general architectural model as Ubicloud: a control plane manages cloud resources
and worker processes perform long-running provisioning and reconciliation work.

## Quick Start

Clone the repository and start the local demo stack:

```sh
git clone git@github.com:mayowaoladosu/layerrail.git
cd layerrail

./demo/generate_env
docker compose -f demo/docker-compose.yml up
```

Open the local console:

```text
http://localhost:3000
```

The demo stack starts:

- `layerrail-postgres`: local control-plane database
- `layerrail-db-migrator`: database migration process
- `layerrail-app`: web process and background workers for the demo environment

For deeper development setup notes, see [DEVELOPERS.md](DEVELOPERS.md).

## Architecture

LayerRail has three main operating surfaces:

### Control Plane

The control plane stores state, serves the console, authenticates users, manages
projects and resources, and coordinates provider operations.

Core technologies include:

- Ruby
- Roda for HTTP routing
- Sequel for database access
- Rodauth for authentication
- Postgres for control-plane state
- RSpec for tests
- Tailwind CSS for server-rendered console views

### Workers

Provisioning is not handled by the web process alone. Long-running operations
are performed by worker processes that share the same database as the web
service.

Production deployments should run:

```sh
bundle exec puma -C puma_config.rb
bin/restarter bin/respirate
bin/monitor
```

If the worker processes are not running against the same production database as
the web service, resources can remain in `creating` and provider-side resources
may never be created.

### Provider Layer

LayerRail integrates with infrastructure providers to create the underlying
resources. The first public-cloud compute path is Linode.

With `COMPUTE_PROVIDER=linode`, LayerRail can provision VM-backed services using
the configured Linode account and service project settings.

## Production Deployment

LayerRail production deployments need:

- A Postgres database for control-plane state
- A web process running Puma
- Background worker processes for provisioning and monitoring
- Email delivery credentials
- Billing credentials
- Provider credentials for any enabled compute or managed service path
- Public DNS records for the console and generated service endpoints

Run production migrations with:

```sh
RACK_ENV=production bundle exec rake prod_up
```

On Render or any similar platform, create separate services from the same repo
and branch:

| Service | Command |
| --- | --- |
| Web | `bundle exec puma -C puma_config.rb` |
| Respirate worker | `bin/restarter bin/respirate` |
| Monitor worker | `bin/monitor` |

## Environment Configuration

Important environment groups include:

### Database

- `CLOVER_DATABASE_URL`

### Security

- `CLOVER_SESSION_SECRET`
- `CLOVER_COLUMN_ENCRYPTION_KEY`
- `CLOVER_RUNTIME_TOKEN_SECRET`

### Public URLs

- `BASE_URL`

### Email

- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`
- `RESEND_WEBHOOK_SECRET`

### Billing

- `POLAR_ACCESS_TOKEN`
- `POLAR_VERIFICATION_PRODUCT_ID`
- `POLAR_VERIFICATION_AMOUNT_CENTS` defaults to `100` for the one-time billing
  verification checkout

### Compute

- `COMPUTE_PROVIDER`
- `LINODE_ACCESS_TOKEN`
- `LINODE_API_BASE_URL`

### DNS Automation

- `CLOUDFLARE_DNS_API_TOKEN`
- `CLOUDFLARE_DNS_ZONE_ID`
- `CLOUDFLARE_DNS_PROXIED`

### AI Inference

- `AI_INFERENCE_ENABLED`
- `RUNPOD_API_KEY`
- `HUGGINGFACE_TOKEN`
- `INFERENCE_DNS_ZONE`
- `INFERENCE_ROUTER_ACCESS_TOKEN`

Provider-specific credentials are required for whichever infrastructure provider
is enabled in a given deployment.

## Linode Launch Profile

LayerRail currently supports Linode as the first public-cloud compute provider
for VM provisioning.

```sh
COMPUTE_PROVIDER=linode
LINODE_ACCESS_TOKEN=...
```

The launch catalog is intentionally narrow:

- Locations: Frankfurt, Newark, Los Angeles, and Seattle
- Images: Ubuntu 24.04, Debian 12, AlmaLinux 9, and Rocky Linux 9
- VM sizes: Linode shared 2GB/4GB, dedicated 4GB/8GB/16GB/32GB, and one RTX
  4000 Ada GPU plan
- Pricing: VM and GPU rates use a 30% LayerRail markup

Linode-included root storage and public IPv4 are shown as included rather than
billed separately.

When `POSTGRES_ENABLED=true` or `KUBERNETES_ENABLED=true`, the corresponding
LayerRail-managed services use VM-backed infrastructure under the hood. The
production worker processes must be running before these services can provision
real resources.

## DNS And Service Endpoints

LayerRail distinguishes between the console host and generated customer service
hostnames.

Example generated endpoint zones include:

- `lb.layerrail.com`
- `postgres.layerrail.com`
- `k8s.layerrail.com`

These are product DNS zones for generated customer endpoints. They are separate
from the console host, such as `console.layerrail.com`, and should be managed in
Cloudflare DNS rather than deployed as separate web applications.

## CLI Surface

The `/cli` page is the built-in LayerRail CLI web shell for project commands. It
is not a browser SSH terminal into customer virtual machines.

## Development

Common development commands:

```sh
bundle install
npm install
bundle exec rake
bundle exec rspec
```

The repository includes:

- `routes/`: web and API route handlers
- `model/`: domain models
- `migrate/`: database migrations
- `views/`: server-rendered console views
- `cli-commands/`: LayerRail CLI command handlers
- `spec/`: test suite
- `demo/`: local demo environment

## Upstream Strategy

LayerRail is intended to stand as its own product repository while keeping a
clean path to reuse selected Ubicloud changes.

Recommended remotes:

```text
origin   https://github.com/mayowaoladosu/layerrail.git
upstream https://github.com/ubicloud/ubicloud.git
```

Use `origin` for LayerRail product work. Use `upstream` to review, cherry-pick,
or merge Ubicloud infrastructure changes when they are useful to LayerRail.

## License And Attribution

LayerRail is based on Ubicloud and keeps the upstream AGPL-3.0 license. Keep the
original license and notices intact, and publish source for network-accessible
modifications as required by AGPL-3.0.

See [LAYERRAIL.md](LAYERRAIL.md) for fork notes and upstream remote guidance.
