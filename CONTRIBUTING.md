# Contributing to LayerRail

Thank you for helping improve LayerRail. This repository is the LayerRail
product fork built on the Ubicloud open source infrastructure foundation. We
welcome focused contributions that make the control plane clearer, safer, more
operable, and easier to deploy.

## Before You Start

Use GitHub issues for bugs, feature proposals, and documentation requests. For
larger changes, open an issue first so maintainers can confirm the scope before
you spend time on an implementation.

Please do not use public issues or pull requests for vulnerabilities, secrets,
customer data, provider credentials, or exploit details. Follow
[the security policy](.github/SECURITY.md) instead.

## Contribution Areas

Good contribution areas include:

- Control-plane reliability and observability.
- Provider integrations and provisioning workflows.
- Budget, usage, and deployment evidence flows.
- Documentation for operators and contributors.
- Tests that cover provisioning, billing, access control, and API behavior.
- Small product improvements that fit LayerRail's project-centered cloud model.

Changes that touch billing, authentication, access control, infrastructure
provisioning, encryption, network policy, or destructive resource operations
need especially clear tests and review notes.

## Development Setup

Clone the repository:

```sh
git clone git@github.com:mayowaoladosu/layerrail.git
cd layerrail
```

Install dependencies:

```sh
bundle install
```

Start the demo stack:

```sh
./demo/generate_env
docker compose -f demo/docker-compose.yml up
```

Open the console:

```text
http://localhost:3000
```

For deeper local setup notes, see [DEVELOPERS.md](DEVELOPERS.md).

## Code Style

LayerRail is a Ruby codebase using Roda, Sequel, Rodauth, Postgres, RSpec, and
RuboCop with Standard Ruby rules. Keep changes small, readable, and consistent
with nearby code.

Run formatting and lint checks where relevant:

```sh
BUNDLE_WITH=rubocop bundle exec rubocop
```

If an autocorrection is appropriate:

```sh
bundle exec rubocop -a
```

Use stronger autocorrection only when you have reviewed the diff carefully:

```sh
bundle exec rubocop -A
```

## Tests

Run the full Ruby test suite:

```sh
bundle exec rspec
```

Run a focused spec file or line while developing:

```sh
bundle exec rspec ./spec/model/strand_spec.rb
bundle exec rspec ./spec/model/strand_spec.rb:10
```

For documentation-only changes, tests may not be necessary. Say that clearly in
the pull request.

## Commit and Pull Request Expectations

Before opening a pull request:

- Keep the branch focused on one problem or feature.
- Include tests for behavior changes.
- Update documentation when the public behavior, setup, or operator workflow
  changes.
- Avoid unrelated formatting churn.
- Do not include credentials, generated secrets, local environment files, or
  private infrastructure details.
- Confirm that new dependencies are necessary and compatible with the
  AGPL-3.0 license.

Pull requests should explain:

- What changed.
- Why it changed.
- How it was tested.
- Any deployment, migration, provider, billing, or security impact.

## Review Process

Maintainers may ask for smaller commits, clearer tests, operational notes, or a
different implementation approach. Review is part of the project design process:
be ready to revise, simplify, or split work when it makes the codebase easier to
operate.

## License and Attribution

LayerRail is licensed under AGPL-3.0 and preserves attribution to the Ubicloud
open source foundation. By contributing, you agree that your contribution may be
distributed under the repository's license.
