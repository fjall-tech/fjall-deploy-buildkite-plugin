# Fjall Deploy Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/plugins) to deploy, destroy, or build [Fjall](https://fjall.io) applications on AWS.

This is a thin shim onto `fjall ci run` — it installs the CLI and delegates. The CLI owns command and flag validation, so an invalid combination (for example `mode` with `command: destroy`) fails with a directional error from `fjall` rather than being silently dropped.

A tier `target` (`organisation`, `platform`, or `account`) routes to the noun-verb tier command — `fjall org deploy`, `fjall platform destroy`, and so on — and accepts only the flags that tier honours (`force`, `verbose`, and, for `organisation`, `no-cascade`). Any app or deploy-only property paired with a tier target is rejected at the plugin boundary rather than silently dropped.

## Quick Start

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
```

## Authentication

The CLI authenticates to Fjall via `FJALL_API_KEY` — mint an app-scoped deploy token with `fjall ci token create` (or `fjall ci setup`) and store it as a [Buildkite secret](https://buildkite.com/docs/pipelines/security/secrets) named `FJALL_API_KEY`. If the environment does not already export `FJALL_API_KEY`, the plugin fetches it from the secret store via `buildkite-agent secret get FJALL_API_KEY`, so you need only store the secret — no `env:` wiring required. Exporting it as an environment variable still works and takes precedence.

AWS credentials must also be available in the build environment before the plugin runs. Common approaches:

### IAM Instance Profile

Buildkite agents running on EC2 can use an instance profile with the necessary permissions. No extra configuration needed.

### Environment Variables

Set credentials in your Buildkite agent environment or pipeline settings:

```yaml
steps:
  - label: ":rocket: Deploy"
    env:
      AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
      AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
      AWS_REGION: "us-east-2"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
```

### AWS OIDC with Assume Role

Use the [aws-assume-role-with-web-identity](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin) plugin:

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - aws-assume-role-with-web-identity#v1.0.0:
          role-arn: arn:aws:iam::123456789012:role/deploy
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
```

## Configuration

| Property            | Required | Default  | Description                                                                                                                                                                                                                                                                 |
| ------------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `command`           | no       | `deploy` | `deploy`, `destroy`, or `build`                                                                                                                                                                                                                                             |
| `target`            | **yes**  | —        | Application name, or a tier: `organisation`, `platform`, `account`. App targets run the app; tier targets route to the noun-verb tier command (`fjall org\|platform\|account deploy\|destroy`). `build` is app-only                                                         |
| `service`           | no       | —        | Specific service name (deploy and build only)                                                                                                                                                                                                                               |
| `mode`              | no       | `full`   | `full`, `infra-only`, or `deploy-only` (deploy only)                                                                                                                                                                                                                        |
| `environment`       | no       | —        | Target environment                                                                                                                                                                                                                                                          |
| `deploy-target`     | no       | —        | Deploy to a specific `fjall target list` target, e.g. `production-use1`; maps to `--target` (the credential where), distinct from `environment`. App targets only                                                                                                           |
| `verbose`           | no       | `false`  | Enable CloudFormation event logging                                                                                                                                                                                                                                         |
| `skip-build`        | no       | `false`  | Skip Docker build (reuse existing image)                                                                                                                                                                                                                                    |
| `skip-migrations`   | no       | `false`  | Skip database migrations during this deployment                                                                                                                                                                                                                             |
| `no-cascade`        | no       | `false`  | Skip the platform/account cascade around an `organisation` deploy or destroy (rejected for any other target)                                                                                                                                                                |
| `region`            | no       | —        | Deploy to a specific region within the target's account                                                                                                                                                                                                                     |
| `image-tag`         | no       | —        | Roll forward/back to an existing image tag (implies deploy-only)                                                                                                                                                                                                            |
| `plan`              | no       | `false`  | Compute and print the change plan, then stop before any mutation                                                                                                                                                                                                            |
| `require-approval`  | no       | `false`  | Refuse to mutate unless the plan is approved                                                                                                                                                                                                                                |
| `auto-approve`      | no       | `false`  | Approve the computed plan without prompting                                                                                                                                                                                                                                 |
| `approval-token`    | no       | —        | Resume an approved plan from a prior plan run                                                                                                                                                                                                                               |
| `build-args`        | no       | —        | Public build-time args, a list of `KEY=VALUE` strings                                                                                                                                                                                                                       |
| `build-secrets`     | no       | —        | Build secret refs, a list of `id=ID,ssm=PATH` (or `env=VAR`) strings                                                                                                                                                                                                        |
| `cli-version`       | no       | `7`      | Pin the `fjall` CLI version. Defaults to this plugin's compatible major (floats across `7`.x, never crossing into the next major); `auto` derives the major from the app's pinned `@fjall/components-infrastructure`; `latest` always installs the newest published release |
| `working-directory` | no       | `.`      | Directory containing `fjall-config.json`                                                                                                                                                                                                                                    |
| `force`             | no       | `false`  | Deploy: redeploy unchanged stacks. Destroy: skip confirmation                                                                                                                                                                                                               |

## Outputs

After the run, the plugin records results as [build meta-data](https://buildkite.com/docs/pipelines/build-meta-data):

| Meta-data key                 | Value                                                                      |
| ----------------------------- | -------------------------------------------------------------------------- |
| `fjall-deploy:result`         | `success`, `plan-pending` (exit 2 — no mutation), or `failure`             |
| `fjall-deploy:duration`       | Command duration in seconds                                                |
| `fjall-deploy:approval-token` | Token from a plan run with pending changes; feed back via `approval-token` |

A `plan-pending` result also posts a warning annotation with re-run instructions, and the step exits `2` so downstream steps can gate on it.

## Examples

### Infrastructure Only

```yaml
steps:
  - label: ":construction: Infra"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          mode: infra-only
```

### Code Only

```yaml
steps:
  - label: ":package: Code"
    depends_on: infra
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          mode: deploy-only
```

### Destroy

```yaml
steps:
  - label: ":fire: Destroy"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          command: destroy
          target: my-app
          force: true
```

### Deploy Specific Service

```yaml
steps:
  - label: ":whale: API"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          service: api
          mode: deploy-only
```

### Deploy a Tier

A tier `target` routes to the noun-verb tier command. This runs `fjall org deploy --non-interactive --no-cascade` (the organisation root stack without its platform/account cascade):

```yaml
steps:
  - label: ":earth_africa: Organisation"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: organisation
          no-cascade: true
```

### Pin CLI Version

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          cli-version: "0.88.3"
```

### Staging to Production Pipeline

```yaml
steps:
  - label: ":test_tube: Staging"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          environment: staging

  - wait

  - block: ":raised_hand: Deploy to Production?"

  - label: ":rocket: Production"
    plugins:
      - fjall-tech/fjall-deploy#v3.0.0:
          target: my-app
          environment: production
          skip-build: true
```

## Requirements

- Node.js >= 22 — if the agent's node is older (or absent), the plugin bootstraps a pinned Node build from nodejs.org, SHA-256-verified before use (a Linux agent with `curl` and `tar` is required for the bootstrap path)
- npm
- AWS credentials available in the environment

## Running Tests

```bash
docker compose run --rm tests
```

## License

MIT
