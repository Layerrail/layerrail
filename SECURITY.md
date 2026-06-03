# Security Policy

LayerRail is an infrastructure control plane. Security reports are handled with
care because the project can manage cloud resources, provider credentials,
network policy, billing context, and deployment records.

## Supported Versions

LayerRail is in active product development. Security fixes are prioritized for
the repository's active default branch and any production branches explicitly
maintained by the LayerRail team.

Unsupported forks, private deployments, experimental branches, and local demo
environments may not receive direct security support. Operators should apply
security patches from the maintained branch as soon as practical.

## Reporting a Vulnerability

Please do not open a public issue for vulnerabilities.

Report suspected vulnerabilities using one of these private paths:

- GitHub private vulnerability reporting or a repository security advisory, if
  available.
- Email support@layerrail.com with the subject prefix `[security]`.

Include as much of the following as you safely can:

- A short summary of the issue.
- Affected components, routes, APIs, workers, providers, or CLI commands.
- Reproduction steps or proof-of-concept details.
- Impact, including whether credentials, customer data, resource ownership,
  billing data, or infrastructure state may be exposed or modified.
- Relevant versions, commits, deployment mode, and provider configuration.
- Any logs or screenshots with secrets and private data removed.

Do not send live credentials, private keys, customer data, or exploit material
that is not needed to validate the issue.

## Response Targets

We aim to:

- Acknowledge credible security reports within 3 business days.
- Triage severity and reproduction details within 10 business days.
- Coordinate a fix, mitigation, or disclosure plan based on severity and
  deployment impact.

Complex provider, billing, authentication, or infrastructure issues may require
more time to validate safely.

## Coordinated Disclosure

Please give maintainers reasonable time to investigate and prepare a fix before
publicly disclosing a vulnerability. We will work with reporters to understand
impact, credit the report when appropriate, and communicate mitigations without
exposing users to unnecessary risk.

## Scope

In scope:

- Authentication, authorization, and account security.
- Project, workspace, billing, and deployment evidence access controls.
- Provider credential handling.
- VM, network, firewall, load balancer, Kubernetes, PostgreSQL, GitHub runner,
  and AI inference provisioning paths.
- CLI and API behavior that can affect customer resources or data.

Out of scope:

- Denial-of-service claims without a demonstrated security impact.
- Social engineering, spam, or physical attacks.
- Reports against third-party services unless the issue is caused by LayerRail.
- Vulnerabilities requiring compromised local developer machines.
- Scanner output without a reproducible issue.
