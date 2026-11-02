# Fjall Deploy Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/plugins) to deploy, destroy, or build [Fjall](https://fjall.io) applications on AWS.

This is a thin shim onto `fjall ci run` — it installs the CLI and delegates. The CLI owns command and flag validation, so an invalid combination (for example `mode` with `command: destroy`) fails with a directional error from `fjall` rather than being silently dropped.

The one exception is `supersede`, which the hook decides itself before it installs the CLI, and never forwards to it (see [Skipping a superseded deploy](#skipping-a-superseded-deploy)).

A tier `target` (`organisation`, `platform`, or `account`) routes to the noun-verb tier command — `fjall org deploy`, `fjall platform destroy`, and so on — and accepts only the flags that tier honours (`force`, `verbose`, and, for `organisation`, `no-cascade`). Any app or deploy-only property paired with a tier target is rejected at the plugin boundary rather than silently dropped.

## Quick Start

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          deploy-target: production-use1
```

If the deploy step sets `timeout_in_minutes`, or your pipeline sets a default timeout, make it at least 650, the timeout `fjall ci setup` writes: from fjall 40, a deploy waits out each database engine upgrade, which AWS has held for up to three hours, and that covers two upgrades of the slowest engine with their stacks' deploys. A pipeline's or organisation's Maximum Command Step Timeout lowers a longer step timeout to itself. When a plan's upgrades could wait longer than the step's timeout (`BUILDKITE_TIMEOUT`), the plan warns before anything is upgraded (`database-engine-ci-job-limit`). A job stopped mid-upgrade leaves the upgrade running in RDS, and re-running the deploy waits for it and resumes.

## Agent Architecture

Fjall builds ECS images for `linux/arm64`, the platform its tasks run on, and a container Lambda's image for its `architecture`. Run the deploy step on an agent queue of the architecture those images build for. For arm64 that is a Linux ARM queue on Buildkite-hosted agents, or Graviton instances on self-hosted ones. `fjall ci setup --provider buildkite --queue <name>` writes the queue into the step, and from fjall 40 the command prints the platform it read from the manifest a synth left in the app's `cdk.out`. It names `linux/amd64` only when that manifest lists only x86_64 images, and warns when the app builds both or `cdk.out` holds no current list.

An x86 agent can run an arm64 image's `RUN` steps only under emulation. The default BuildKit image behind Fjall's `fjall` builder ships an emulator (`buildkit-qemu-aarch64`, checked on BuildKit 0.33.1), and BuildKit documents that most builds need no manual QEMU setup. BuildKit also documents emulation as much slower than a native build, and advises against it for compiling. A `RUN` step can still fail when its container mixes binaries for several architectures. BuildKit's documented cure is to register QEMU on the agent, commonly with the `tonistiigi/binfmt` image.

## Authentication

Two credentials are involved: a Fjall deploy token (`FJALL_API_KEY`) and AWS credentials.

### Fjall API Key

The CLI authenticates to Fjall via `FJALL_API_KEY` — an app-scoped `fjall_dk_` deploy token. A deploy token is minted only in a signed in browser session of an owner or admin. Mint one on **Settings → CI/CD Tokens** in the [Fjall dashboard](https://fjall.io), the page whose URL `fjall ci setup` prints. Or, with CLI 40.0.0 or later, run `fjall ci token create --app <app> --target <target> --print` at a terminal. You approve its request in your own browser session, because only the person whose Fjall credential opened a request can approve it. Then the command prints the token there for you to store. Tokens expire after at most 90 days. To rotate, mint a new one the same way and update the secret. Store the token as a [Buildkite secret](https://buildkite.com/docs/pipelines/security/secrets) named `FJALL_API_KEY`. If the environment does not already export `FJALL_API_KEY`, the plugin fetches it from the secret store via `buildkite-agent secret get FJALL_API_KEY`, so you need only store the secret — no `env:` wiring required. Exporting it as an environment variable still works and takes precedence.

### AWS Credentials

When `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are both set in the step's
environment, the CLI uses them and never reaches the Fjall mint; otherwise it
mints a session from your deploy token. With fjall 39, an application deploy
on such keys runs in whatever account they belong to, whatever target
`deploy-target` or `environment` picks, and in `AWS_REGION` (else
`AWS_DEFAULT_REGION`, else `us-east-2`) unless `region` is set. From fjall 40,
the CLI first confirms they belong to that target's account and, when they do
not, refuses the deploy before it records or changes anything, naming both
accounts and the variables to unset; keys that belong to it deploy in the
target's own region unless `region` is set. Pick one path: an agent or pipeline
that exports AWS keys for other steps should not export them to the deploy
step unless they are the credentials the deploy should use.

#### Option 1: Fjall OIDC (recommended — no AWS setup)

Store `FJALL_API_KEY` and export no AWS credentials. The CLI exchanges your
deploy token with the Fjall API for a short-lived, Fjall-signed web-identity
token, then calls `sts:AssumeRoleWithWebIdentity` against the
`FjallDeploy<orgId>` role Fjall created when you connected your AWS account.
The deploy token _is_ the pipeline's AWS credential.

You need no IAM OIDC provider of your own, no deploy role and no AWS secrets.
An agent's EC2 instance profile plays no part either: the CLI does not read
it, so an agent on EC2 deploys this way like any other.

The session this path mints lasts one hour. From fjall 40, the CLI renews it
through the deploy token before it expires, so a deploy can run past the hour.
Fjall 39 and earlier renew no session on any path, so with them a deploy that
runs longer than an hour fails part-way on this path too.

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          deploy-target: production-use1
```

Every CI deploy token carries the `deploy:oidc:mint` scope in its base set, so
there is nothing extra to grant.

#### Option 2: AWS OIDC with Assume Role

Use the [aws-assume-role-with-web-identity](https://github.com/buildkite-plugins/aws-assume-role-with-web-identity-buildkite-plugin) plugin to assume a role you create and maintain. It puts the role session's keys in the step's environment, so the Fjall mint is not used:

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - aws-assume-role-with-web-identity#v1.0.0:
          role-arn: arn:aws:iam::123456789012:role/deploy
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          deploy-target: production-use1
```

The CLI cannot renew a session it reads from the environment, so a deploy that
runs longer than the role session (one that upgrades database engines, for
example) fails when the session expires.

#### Option 3: Environment Variables

Set credentials in your Buildkite agent environment or pipeline settings:

```yaml
steps:
  - label: ":rocket: Deploy"
    env:
      AWS_ACCESS_KEY_ID: "${AWS_ACCESS_KEY_ID}"
      AWS_SECRET_ACCESS_KEY: "${AWS_SECRET_ACCESS_KEY}"
      AWS_REGION: "us-east-1"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          deploy-target: production-use1
```

The CLI cannot renew keys it reads from the environment, so when these are
temporary session keys (they come with `AWS_SESSION_TOKEN`), a deploy that
runs longer than their session (one that upgrades database engines, for
example) fails when they expire.

## Configuration

| Property            | Required | Default  | Description                                                                                                                                                                                                                                                                                         |
| ------------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `command`           | no       | `deploy` | `deploy`, `destroy`, or `build`                                                                                                                                                                                                                                                                     |
| `target`            | **yes**  | —        | Application name, or a tier: `organisation`, `platform`, `account`. App targets run the app; tier targets route to the noun-verb tier command (`fjall org\|platform\|account deploy\|destroy`). `build` is app-only                                                                                 |
| `service`           | no       | —        | One service (deploy and build only), from fjall 40 by its whole name, ignoring case. Fjall 39 also selects every service whose name ends with it                                                                                                                                                    |
| `mode`              | no       | `full`   | `full`, `infra-only`, or `deploy-only` (deploy only)                                                                                                                                                                                                                                                |
| `environment`       | no       | —        | Target environment                                                                                                                                                                                                                                                                                  |
| `deploy-target`     | no       | —        | Deploy to a specific `fjall target list` target, e.g. `production-use1`; maps to `--target` (the credential where), distinct from `environment`. App targets only                                                                                                                                   |
| `verbose`           | no       | `false`  | Enable CloudFormation event logging                                                                                                                                                                                                                                                                 |
| `skip-build`        | no       | `false`  | Skip Docker build (reuse existing image)                                                                                                                                                                                                                                                            |
| `no-cascade`        | no       | `false`  | Skip the platform/account cascade around an `organisation` deploy or destroy (rejected for any other target)                                                                                                                                                                                        |
| `region`            | no       | —        | Deploy to a specific region within the target's account                                                                                                                                                                                                                                             |
| `image-tag`         | no       | —        | Roll forward/back to an existing image tag (implies deploy-only)                                                                                                                                                                                                                                    |
| `plan`              | no       | `false`  | Compute and print the change plan, then stop before any mutation                                                                                                                                                                                                                                    |
| `require-approval`  | no       | `false`  | Refuse to mutate unless the plan is approved                                                                                                                                                                                                                                                        |
| `auto-approve`      | no       | `false`  | Approve the computed plan without prompting                                                                                                                                                                                                                                                         |
| `approval-token`    | no       | —        | Resume an approved plan from a prior plan run                                                                                                                                                                                                                                                       |
| `build-args`        | no       | —        | Public build-time args, a list of `KEY=VALUE` strings                                                                                                                                                                                                                                               |
| `build-secrets`     | no       | —        | Build secret refs, a list of `id=ID,ssm=PATH` (or `env=VAR`) strings                                                                                                                                                                                                                                |
| `cli-version`       | no       | `39`     | Pin the `fjall` CLI version. Defaults to this plugin's compatible major (floats across `39`.x, never crossing into the next major); `auto` derives the major from the app's pinned `@fjall/components-infrastructure`; `latest` always installs the newest published release                        |
| `working-directory` | no       | `.`      | Folder that holds the project's `fjall/` folder, relative to the repository's checkout. `fjall` runs there                                                                                                                                                                                          |
| `force`             | no       | `false`  | Deploy: redeploy all stacks even when no changes are detected. Destroy: bypass the busy-stack guard and destroy while the target's stacks are mid-operation. App destroys skip destruction confirmation in CI regardless; a tier destroy still needs force to pass its non-interactive confirmation |
| `supersede`         | no       | —        | Skip this deploy when a newer `main` build of the same pipeline already carries its commit. An object of `after`, `token-secret` and an optional `barriers` list, valid only with `command: deploy` and an application target. See [Skipping a superseded deploy](#skipping-a-superseded-deploy)    |

A plan and the approval gate cover a full or `infra-only` deploy. `mode: deploy-only` and `image-tag` change no template, so they have no plan, and a run of either with `plan`, `require-approval` or `approval-token` is refused before anything is deployed. Through CLI 39.0.8 such a run went ahead without either.

## Outputs

After the run, the plugin records results as [build meta-data](https://buildkite.com/docs/pipelines/build-meta-data):

| Meta-data key                 | Value                                                                                                                            |
| ----------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `fjall-deploy:result`         | `success`, `plan-pending` (exit 2, no mutation) or `failure`. With `supersede` set, also `superseded` (exit 0, nothing deployed) |
| `fjall-deploy:superseded-by`  | Set only with `superseded`. The number of the newer build whose deploy covers this one                                           |
| `fjall-deploy:duration`       | Command duration in seconds                                                                                                      |
| `fjall-deploy:approval-token` | Token from a plan run with pending changes; feed back via `approval-token`                                                       |

A `superseded` build records no duration. It posts a warning annotation that names the newer build.

A `plan-pending` result also posts a warning annotation with re-run instructions, and the step exits `2` so downstream steps can gate on it.

## Verifying a Deploy

`fjall-deploy:result` answers "did the step succeed". To confirm what actually shipped, the CLI's read commands work anywhere the same `FJALL_API_KEY` is available (including a follow-up step):

- `fjall deployments list` — your organisation's active and recent deployments: who triggered each, from where, and its current state
- `fjall releases <app>` — the app's recorded releases with their image tags: what is live now, and what a rollback can target
- `fjall status <app>` — the deployed infrastructure's current health

## Serialising Deploys

Fjall serialises deployments that touch the same infrastructure (the deploy slot): an application's deploys queue behind an in-flight deploy of the same application, of its account's infrastructure, or of the organisation, while unrelated applications deploy in parallel. Give every deploy step for the same app a shared concurrency group — the same shape `fjall ci setup` scaffolds — so overlapping builds queue instead of contending for the slot:

```yaml
steps:
  - label: ":rocket: Deploy"
    concurrency_group: "fjall-deploy-my-app"
    concurrency: 1
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
```

Pair this with the pipeline settings **Skip Intermediate Builds: ON** (queued stale deploys collapse to the newest) and **Cancel Intermediate Builds: OFF** (never interrupt an in-flight CloudFormation update).

## Skipping a superseded deploy

Set `supersede` when your pipeline creates a deploy build for each green commit on `main`, so an older build that starts late would only repeat what a newer one deploys. A superseded build records `fjall-deploy:result` as `superseded`, posts a warning annotation naming the newer build, and exits `0` without installing the CLI.

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v29:
          target: my-app
          supersede:
            after: verify-ci-green
            token-secret: CI_GREEN_API_TOKEN
            barriers:
              - prisma/migrations/
```

`supersede` takes three properties.

- `after`, required. The key of a step that must have passed on the newer build before this one gives way to it, such as a step that checks the commit's CI.
- `token-secret`, required. The name of a [Buildkite secret](https://buildkite.com/docs/pipelines/security/secrets) that holds an API access token with the `read_builds` scope. The hook reads it with `buildkite-agent secret get` and hands it to the check on standard input, so the token itself is never a plugin property.
- `barriers`, optional. Paths relative to the repository root. A commit that changes a file at one of these paths, or anything under one that is a directory, is a barrier. Each path is read literally, so `*` and `:!` have no special meaning, and `prisma/mig` does not match `prisma/migrations/`. A path that starts with `-` or `/`, or has a `..` segment, is refused before any secret is read.

A build skips only when all of these hold.

- Its creator marked it, by sending `"meta_data": {"fjall-deploy:supersedable": "true"}` in the body of its [create build](https://buildkite.com/docs/apis/rest-api/builds#create-a-build) request. A build started from the dashboard carries no marker, so a hand rollback always deploys.
- It is a build of `main`, among the 20 newest `main` builds of its pipeline, and not a rebuild.
- The newest newer build that can still deploy, or has deployed, has passed its `after` step, and its commit has this build's commit in its first parent history. Such a build is running with `fjall-deploy:result` unset or `success`, or passed with `success`. A build that recorded anything else, `superseded` included, will not deploy its commit, so it is passed over.
- No commit on that newer build's first parent line, from this build's commit up to the newer build's own, is a barrier. A merge commit on that line is judged by its diff against its first parent, which holds the net change of every commit it merged.

Only that one newer build is judged. When it fails either of the last two checks, this build deploys rather than looking at an older one, so it never steps over a hand rollback.

A commit on the newer build's first parent line is also a barrier when a line of its message starts with `deploy-alone`. That holds whenever `supersede` is set, with or without a `barriers` list. Only the messages of commits on that line are read. So when a merge commit or a squash lands your change on `main`, put the `deploy-alone` line in the message of the commit on `main`, at the very start of a line. The same line in a merged topic commit is not read.

Any doubt deploys. The build deploys the commit it was given, as it would without `supersede`, when the secret cannot be read, a read of the builds list fails or runs past its bound (30 s a read, 120 s in all), git fails, or the clone is still shallow after `git fetch --unshallow`. The check prints one line that says whether it skipped and why. It runs without `FJALL_API_KEY` in its environment.

`supersede` needs a plugin release that ships it, so the example above uses the moving major tag. An exact pin of an earlier release runs a hook that ignores `supersede` and deploys every build, and nothing warns that it did.

An agent keeps the checkout it made for a plugin ref and does not fetch that ref again unless it sets `plugins-always-clone-fresh` (Buildkite's [agent configuration](https://buildkite.com/docs/agent/v3/configuration) docs). So an agent that cloned `v29` before `supersede` shipped runs the older hook, which ignores `supersede` and deploys every build. That is safe, and it ends when the agent next clones the plugin fresh.

## Examples

### Infrastructure Only

```yaml
steps:
  - label: ":construction: Infra"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          mode: infra-only
```

### Code Only

A code-only deploy (`mode: deploy-only`) builds and rolls only what the assembly a full deploy writes to `fjall/<app>/cdk.out` declares, so it needs that assembly in the step's checkout. `cdk.out` is not committed, and a step on another agent, an `infra-only` one included, leaves none behind, so a plugin step's checkout holds it only where a deploy in that checkout wrote it. Where it has none, a `mode: deploy-only` step is refused (through CLI 39.0.8 it rolled nothing and exited 0; an app with capacity-identity pins was refused instead). To ship code without a full deploy, roll an image already built with `image-tag`, which rolls the services the app's Compute stack exports with no assembly (an app with a container-image function in the roll needs the assembly for that too, so deploy such an app in full):

```yaml
steps:
  - label: ":package: Code"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          image-tag: "app-sha-4f9c2ab0d1e3"
```

### Destroy

```yaml
steps:
  - label: ":fire: Destroy"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          command: destroy
          target: my-app
          force: true
```

### Deploy Specific Service

`service` narrows an `image-tag` roll, or a code-only deploy, to one service. From fjall 40 it selects the service by its whole name, ignoring case, so `service: worker` rolls `worker`, never `scan-worker`, and a name that matches no service is refused, listing the services there are. Fjall 39 also selects every service whose name ends with the name given, so with it `service: worker` rolls `scan-worker` too. A code-only deploy needs the assembly a full deploy wrote in the step's checkout (Code Only, above):

```yaml
steps:
  - label: ":whale: API"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          service: api
          image-tag: "api-sha-4f9c2ab0d1e3"
```

### Deploy a Tier

A tier `target` routes to the noun-verb tier command. This runs `fjall org deploy --non-interactive --no-cascade` (the organisation root stack without its platform/account cascade):

```yaml
steps:
  - label: ":earth_africa: Organisation"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: organisation
          no-cascade: true
```

### Roll Back to a Previous Image

`image-tag` re-deploys an existing image without rebuilding (implies `deploy-only`):

```yaml
steps:
  - label: ":rewind: Roll back"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          image-tag: "sha-4f9c2ab"
```

Find valid tags with `fjall releases my-app` (each release records the image tags it shipped), from the original deploy's output, or from the app's ECR repository. An image-tag rollback re-pins application code only — it does not revert infrastructure changes or roll back database migrations.

### Pin CLI Version

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          cli-version: "39.0.0"
```

### Staging to Production Pipeline

```yaml
steps:
  - label: ":test_tube: Staging"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          environment: staging

  - wait

  - block: ":raised_hand: Deploy to Production?"

  - label: ":rocket: Production"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          environment: production
          skip-build: true
```

## Caching the CLI Install

The hook installs `cli-version` with `npm install -g` on every run. npm's cache spares the download, and it also decides what is installed: npm checks a package against the integrity its metadata names, reads that metadata from the same cache, and serves a cached copy without asking the registry while the copy's headers call it fresh. Measured on npm 11.17.0 (2026-10-15), metadata and a tarball planted in npm's cache made `npm install -g` install a version the registry never published and run its install script, which in this hook runs with `FJALL_API_KEY` exported. `--prefer-online` did not stop it: npm asked the registry, which answered the ETags the planted entries carried with 304 Not Modified, and npm kept the planted copies. Whoever can write the cache chooses the CLI your deploy runs, so share it only with builds you would trust to deploy:

- **Self-hosted agents** keep npm's default cache (`~/.npm`) between jobs, so a repeat install of the same version fetches no package again. Every pipeline on the agent shares that cache: an agent that runs untrusted builds should not run deploys, the same rule as for cluster secrets.
- **Buildkite-hosted agents** start each job with an empty home directory, so persist npm's cache with a cache volume. A volume is shared by every build of the pipeline, whatever its branch, and an unnamed volume is the pipeline's default, which every step that declares a cache without a name mounts (Buildkite's [cache volumes](https://buildkite.com/docs/agent/buildkite-hosted/cache-volumes) docs, read 2026-10-15). Mount one only on a deploy pipeline that builds `main` alone with pull-request builds off, as the header of the pipeline `fjall ci setup` writes requires, give it a name of its own, and mount it in the deploy step alone:

```yaml
steps:
  - label: ":rocket: Deploy"
    cache:
      name: fjall-deploy-npm
      paths:
        - "/var/cache/fjall-deploy-npm"
    env:
      NPM_CONFIG_CACHE: "/var/cache/fjall-deploy-npm"
    plugins:
      - fjall-tech/fjall-deploy#v29.0.0:
          target: my-app
          deploy-target: production-use1
```

Keep the path absolute and outside the checkout. A service with no `docker.context` builds from its Dockerfile's directory, which for a Dockerfile at the repository root is the whole checkout, and npm writes a new debug log into its cache on every run: a cache inside the checkout would go into every build's context and change it each time, so a `COPY . .` layer and every layer after it would rebuild on every deploy. Cache volumes are best-effort: a job that gets an empty one downloads as before.

## Versioning

Two pins interact, and they move together:

- **The plugin ref** — `fjall-tech/fjall-deploy#v29` is a moving major tag, repointed at the latest 29.x release on each plugin republish; `#v29.0.0` pins an exact release for maximum determinism.
- **`cli-version`** — the `fjall` CLI the plugin installs per run; it defaults to the plugin major's compatible CLI major.

Upgrade majors deliberately: a new plugin major defaults to a new CLI major, so bump the plugin ref and any explicit `cli-version` pin in the same change.

## Troubleshooting

### Blocked deploy slot

> Blocked: Jane has been deploying my-app from CI since 03/08/2026, 14:02:11 (deployment cmd0a1b2c…). View progress in the Fjall dashboard: …

Fjall serialises deployments that touch the same infrastructure. An application deploy or destroy that starts while a conflicting deployment is in flight — the same application, its account's infrastructure, or the organisation — first queues behind it: the step re-claims the slot every 30 seconds for up to 20 minutes, logging who holds it, and only then fails with the message above. Tier targets (`organisation`, `platform`, `account`) route to the noun-verb commands and are not queued: they fail immediately on a held slot. Wait for the active deployment to finish (or cancel it from the dashboard), then retry. `fjall deployments list` shows your organisation's active deployments. Prevent the contention with a concurrency group ([Serialising Deploys](#serialising-deploys)).

### "This deployment requires a newer fjall CLI"

The Fjall API refuses deploys from a CLI older than the app's engine floor. The refusal suggests `npm install -g fjall@latest` — correct for a workstation, wrong here: the plugin installs the CLI per run from `cli-version`, so upgrading the agent's global CLI changes nothing. Fix it in the pipeline instead:

- bump `cli-version` to the required major (or a newer exact version), or
- set `cli-version: auto` to derive the major from the app's pinned `@fjall/components-infrastructure`, or
- move to a newer plugin major (each plugin major defaults `cli-version` to its compatible CLI major).

### Authentication failures

Two different credentials can fail — the error tells you which:

- **Fjall API errors** (401/403 from the Fjall API) mean `FJALL_API_KEY` is missing, expired, or revoked. Deploy tokens live at most 90 days. Mint a replacement in the dashboard (**Settings → CI/CD Tokens**), or with `fjall ci token create --print`, and update the Buildkite secret.
- **AWS SDK errors** (`ExpiredToken`, `AccessDenied`, credential-chain failures naming AWS services) mean the build environment's AWS credentials are wrong — see [Authentication](#authentication).

### `docker: command not found`

Any deploy or build that produces a container image runs Docker on the agent. Install Docker on self-hosted agents; only `image-tag` and `skip-build` deploys avoid the image build.

## Requirements

- Node.js >= 22.12.0 — if the agent's node is below that floor (or absent), the plugin bootstraps a pinned Node build from nodejs.org, SHA-256-verified before use (a Linux agent with `curl` and `tar` is required for the bootstrap path)
- npm
- Docker — required for any deploy or build that produces a container image (`image-tag` / `skip-build` deploys excepted)
- A Fjall deploy token (`FJALL_API_KEY`), which is also the deploy's AWS credential unless the step's environment carries AWS keys — see [Authentication](#authentication)

## Running Tests

```bash
docker compose run --rm tests
```

## License

MIT
