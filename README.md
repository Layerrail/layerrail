# LayerRail

LayerRail is an open cloud control plane for developers, research teams, and grant-funded builders who need cloud resources with clearer budget rails, deployment evidence, and reproducible infrastructure records.

This repository is a LayerRail fork built on the Ubicloud open source infrastructure foundation. The upstream AGPL-3.0 license and attribution remain intact; LayerRail-specific product work lives in this fork.

## What LayerRail Is

LayerRail is moving toward a practical PaaS/IaaS control plane with:

- Virtual machines, private networking, firewalls, load balancers, managed PostgreSQL, Kubernetes, GitHub runners, and AI inference surfaces.
- Funding-aware workflows such as workspace budget controls, deployment passports, usage evidence, and reporting-friendly resource summaries.
- A self-hostable control plane that can be deployed with an external Postgres database and connected to cloud or bare-metal compute providers.

## Local Development

```sh
git clone git@github.com:mayowaoladosu/ubicloud.git
cd ubicloud

./demo/generate_env
docker compose -f demo/docker-compose.yml up
```

Open the console at:

```text
http://localhost:3000
```

The demo stack starts:

- `layerrail-postgres` for the local control-plane database.
- `layerrail-db-migrator` for database migrations.
- `layerrail-app` for the web process and background workers.

## Production Shape

LayerRail's production control plane needs:

- A Postgres database for control-plane state, such as Neon.
- A web process running `bundle exec puma -C puma_config.rb`.
- Background worker processes for `bin/restarter bin/respirate` and `bin/monitor`.
- Email delivery through Resend.
- Billing through Polar.
- At least one configured compute provider before customer VMs, Kubernetes, managed Postgres, load balancers, or inference routers can provision real resources.

Run production migrations with:

```sh
RACK_ENV=production bundle exec rake prod_up
```

## Key Environment Areas

- Database: `CLOVER_DATABASE_URL`
- Security: `CLOVER_SESSION_SECRET`, `CLOVER_COLUMN_ENCRYPTION_KEY`, `CLOVER_RUNTIME_TOKEN_SECRET`
- Email: `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `RESEND_WEBHOOK_SECRET`
- Billing: `POLAR_ACCESS_TOKEN`, `POLAR_VERIFICATION_PRODUCT_ID`
- Compute: `COMPUTE_PROVIDER=linode`, `LINODE_ACCESS_TOKEN`, `LINODE_API_BASE_URL`
- Public URL: `BASE_URL`
- AI inference: `AI_INFERENCE_ENABLED`, `RUNPOD_API_KEY`, `HUGGINGFACE_TOKEN`, `INFERENCE_DNS_ZONE`, `INFERENCE_ROUTER_ACCESS_TOKEN`

Provider-specific credentials are required separately for whichever compute provider LayerRail is configured to use.

## Linode Compute

LayerRail currently supports Linode as the first public-cloud compute provider for VM provisioning. Set:

```sh
COMPUTE_PROVIDER=linode
LINODE_ACCESS_TOKEN=...
```

The Linode catalog is intentionally narrow for launch:

- Locations: Frankfurt, Newark, Los Angeles, and Seattle.
- Images: Ubuntu 24.04, Debian 12, AlmaLinux 9, and Rocky Linux 9.
- VM sizes: Linode shared 2GB/4GB, dedicated 4GB/8GB/16GB/32GB, and one RTX 4000 Ada GPU plan.
- Pricing: VM and GPU rates use a 30% LayerRail markup. Linode-included root storage and public IPv4 are shown as included instead of billed separately.

With `COMPUTE_PROVIDER=linode`, PostgreSQL and Kubernetes are hidden unless explicitly enabled. The current PostgreSQL and Kubernetes code paths still expect LayerRail-managed infrastructure and backup/control-plane plumbing that is not fully mapped to Linode Object Storage or LKE yet.

The `/cli` page remains the built-in LayerRail CLI web shell for project commands. It is not a browser SSH terminal into customer VMs.

## License And Attribution

This fork is based on Ubicloud and keeps the upstream AGPL-3.0 license. Keep the original license and notices intact, and publish source for network-accessible modifications as required by AGPL-3.0.

See [LAYERRAIL.md](LAYERRAIL.md) for fork notes and upstream remote guidance.
