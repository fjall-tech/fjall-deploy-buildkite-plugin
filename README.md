# Fjall Deploy Buildkite Plugin

A [Buildkite plugin](https://buildkite.com/docs/plugins) to deploy, destroy, or build [Fjall](https://fjall.io) applications on AWS.

This is a thin shim onto `fjall ci run` — it installs the CLI and delegates. The CLI owns command and flag validation, so an invalid combination (for example `mode` with `command: destroy`) fails with a directional error from `fjall` rather than being silently dropped.

The one exception is `supersede`, which the hook decides itself before it installs the CLI, and never forwards to it (see [Skipping a superseded deploy](#skipping-a-superseded-deploy)).

A tier `target` (`organisation`, `platform`, or `account`) runs the tier's own command, such as `fjall org deploy` or `fjall platform deploy`, and accepts only the flags that tier honours (`force`, `verbose`, and, for `organisation`, `no-cascade`). From fjall 39.0.12, an `account` or `platform` destroy is refused, because it destroyed every stack in the organisation, and from fjall 40 it removes only that tier's stack. Any app property, or one only a deploy reads, paired with a tier target is refused at the plugin boundary rather than silently dropped.

## Quick Start

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
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

Either way the token is handed only to the `fjall` command: the Node bootstrap and the CLI's install, which runs no package's install scripts, never see it. The plugin leaves `FJALL_API_KEY` in the job's environment as it found it. A token the environment supplies is there for the hooks that run after the plugin, as it was for the hooks before it, however the run ends. A token the plugin fetches from the secret store is never exported, so no later hook sees it; a later hook that needs it can fetch it with `buildkite-agent secret get FJALL_API_KEY`.

### AWS Credentials

When `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are both set in the step's
environment, the CLI uses them and never reaches the Fjall mint; otherwise it
mints a session from your deploy token. With fjall 39, an application deploy or
destroy on such keys runs in whatever account they belong to, whatever target
`deploy-target` or `environment` picks. A deploy runs in `AWS_REGION` (else
`AWS_DEFAULT_REGION`, else `us-east-2`) unless `region` is set, and a destroy
runs there even when it is. A tier step doesn't check the keys first either. An
account deploy deploys in their account. It refuses only when that account is
the one registered with Fjall as the organisation's management or platform
account, or when Fjall's list of accounts can't be read. An organisation destroy
records its start and reads AWS Organizations in their account, creating an
organisation there if it has none, before it checks the account. An organisation
deploy goes further before that check. It sets up the organisation in their
account, creating member accounts and organisational units, and registers those
accounts with Fjall. A platform deploy refuses keys for another account, but
only after it has recorded its start. From fjall 40, the CLI first confirms they
belong to the account the step acts on. If they don't, fjall 40 refuses the step
before it records or changes anything, and names both accounts and the variables
to unset. If they do, fjall 40 runs an application step in the target's own
region unless `region` is set. Pick one path. An agent or pipeline that exports
AWS keys for other steps should not export them to the deploy step unless they
are the credentials the deploy should use.

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
      - fjall-tech/fjall-deploy#v30.0.0:
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
      - fjall-tech/fjall-deploy#v30.0.0:
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
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
```

The CLI cannot renew keys it reads from the environment, so when these are
temporary session keys (they come with `AWS_SESSION_TOKEN`), a deploy that
runs longer than their session (one that upgrades database engines, for
example) fails when they expire.

## Configuration

| Property            | Required | Default  | Description                                                                                                                                                                                                                                                                                                                                                    |
| ------------------- | -------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `command`           | no       | `deploy` | `deploy`, `destroy`, or `build`                                                                                                                                                                                                                                                                                                                                |
| `target`            | **yes**  | —        | Application name, or one of the tiers `organisation`, `platform` and `account`. App targets run the app, and tier targets run the tier's own command (`fjall org\|platform\|account deploy\|destroy`). From fjall 39.0.12 an `account` or `platform` destroy is refused, and from fjall 40 it removes only that tier's stack. `build` runs on app targets only |
| `service`           | no       | —        | One service (deploy and build only), from fjall 40 by its whole name, ignoring case. Fjall 39 also selects every service whose name ends with it. A deploy narrows to it only with `mode: deploy-only` or `image-tag`. Fjall 40 refuses it on any other deploy, and fjall 39 leaves it unread                                                                  |
| `mode`              | no       | `full`   | `full`, `infra-only`, or `deploy-only` (deploy only)                                                                                                                                                                                                                                                                                                           |
| `environment`       | no       | —        | Target environment                                                                                                                                                                                                                                                                                                                                             |
| `deploy-target`     | no       | —        | Deploy to a specific `fjall target list` target, e.g. `production-use1`; maps to `--target` (the credential where), distinct from `environment`. App targets only                                                                                                                                                                                              |
| `verbose`           | no       | `false`  | Enable CloudFormation event logging                                                                                                                                                                                                                                                                                                                            |
| `skip-build`        | no       | `false`  | Skip a static-site or OpenNext build command when its output is already built; never skips a Docker build                                                                                                                                                                                                                                                      |
| `no-cascade`        | no       | `false`  | Skip the platform/account cascade around an `organisation` deploy or destroy (rejected for any other target)                                                                                                                                                                                                                                                   |
| `region`            | no       | —        | Deploy to a specific region within the target's account                                                                                                                                                                                                                                                                                                        |
| `image-tag`         | no       | —        | Roll forward/back to an existing image tag (implies deploy-only)                                                                                                                                                                                                                                                                                               |
| `plan`              | no       | `false`  | Compute and print the change plan, then stop before any mutation; not with `mode: deploy-only` or `image-tag`, which change no template                                                                                                                                                                                                                        |
| `require-approval`  | no       | `false`  | Refuse to mutate unless the plan is approved; not with `mode: deploy-only` or `image-tag`, which change no template                                                                                                                                                                                                                                            |
| `auto-approve`      | no       | `false`  | Approve the computed plan without prompting                                                                                                                                                                                                                                                                                                                    |
| `approval-token`    | no       | —        | Resume an approved plan from a prior plan run; not with `mode: deploy-only` or `image-tag`, which change no template                                                                                                                                                                                                                                           |
| `build-args`        | no       | —        | Public build-time args, a list of `KEY=VALUE` strings                                                                                                                                                                                                                                                                                                          |
| `build-secrets`     | no       | —        | Build secret refs, a list of `id=ID,ssm=PATH` (or `env=VAR`) strings                                                                                                                                                                                                                                                                                           |
| `cli-version`       | no       | `39`     | Pin the `fjall` CLI version. Defaults to this plugin's compatible major (floats across `39`.x, never crossing into the next major); `auto` derives the major from the app's pinned `@fjall/components-infrastructure`; `latest` always installs the newest published release                                                                                   |
| `working-directory` | no       | `.`      | Folder that holds the project's `fjall/` folder, relative to the repository's checkout. `fjall` runs there                                                                                                                                                                                                                                                     |
| `force`             | no       | `false`  | Deploy: deploy every stack, including those with no detected changes (CloudFormation leaves an unchanged stack as it is). Destroy: bypass the busy-stack guard and destroy while the target's stacks are mid-operation. App destroys skip destruction confirmation in CI regardless; a tier destroy still needs force to pass its non-interactive confirmation |
| `supersede`         | no       | —        | Skip this deploy when a newer `main` build of the same pipeline already carries its commit. An object of `after`, `token-secret` and an optional `barriers` list, valid only with `command: deploy` and an application target. See [Skipping a superseded deploy](#skipping-a-superseded-deploy)                                                               |

Boolean properties take `true` or `false`; leave one out for its default, `false`. Any other value stops the step before anything is fetched or installed, with an error naming the property: a quoted spelling (`"yes"`, `'True'`, `"0"`), an unquoted number (`1`, `0`), a padded value, or an interpolation that resolves to anything else. An unquoted word reaches the plugin as the YAML parser that read the pipeline makes it. The YAML 1.2 parser that agent v3.138.0's pipeline upload uses turns unquoted `True` and `TRUE` into `true`, and keeps unquoted `yes`, `no`, `on` and `off` as strings, which stop the step. An older agent whose parser reads YAML 1.1 turns those four into booleans, which are accepted. Unquoted `true` and `false` work whatever parses the pipeline, Buildkite itself included for a step defined in its UI.

A property given an empty value stops the step the same way, whatever its type. The plugin cannot tell an interpolation whose variable is unset (`image-tag: "${ROLLBACK_TAG}"`) from a value left blank on purpose, and reading it as the property left out would turn that rollback into a build and deploy. Leave the property out, give it a value, or, for a property without a default, give it `-`, which means none: `service`, `environment`, `deploy-target`, `region`, `image-tag`, `approval-token` and `supersede` read `-` as left out, and `build-args` and `build-secrets` read a single `-` as no list. Every other property refuses `-`, `cli-version` and `working-directory` included. Pass `approval-token` the plan's token as it is, never with a `-` fallback: a plan cancelled before it finished leaves no token to interpolate, and the empty value stops the apply step. Handed `-`, the step runs with no token and could deploy with no reviewed plan, unless it sets `require-approval: true` without `auto-approve: true`. An interpolation supplies `-` when the variable is unset or empty:

```yaml
image-tag: "${ROLLBACK_TAG:--}"
```

The colon matters: without it, a variable set to an empty string stays empty, which stops the step. `"${ROLLBACK_TAG?}"` instead makes the pipeline upload itself fail while the variable is unset.

A `build-args` or `build-secrets` value that is not a YAML list of non-empty strings is refused too: a single string other than `-` (an empty one included), a list with an empty item, or a map. A `-` item inside a list is refused as flag-shaped.

A property written with no value at all (`image-tag:` with nothing after it) is a YAML null, which agent v3.138.0 cannot pass to a plugin. When a job reaches the agent with one, the agent warns `Error configuring plugin environment` and passes the plugin none of its properties, so the step stops for want of a `target`.

The plugin's hook runs itself as a child of the shell the agent sources it into, so it leaves the job's environment and working directory as it found them: the hooks after it, and the step's artifact upload, start in the job's own directory with the job's own environment, `working-directory` moves only the plugin's own run, and a Node the plugin bootstraps is on no later hook's `PATH`. A `BASH_ENV` the job sets is read twice for the hook, once by each of the two shells.

A plan and the approval gate cover a full or `infra-only` deploy. `mode: deploy-only` and `image-tag` change no template, so they have no plan, and a run of either with `plan`, `require-approval` or `approval-token` is refused before anything is deployed. Through CLI 39.0.8 such a run went ahead without either.

## Outputs

The plugin records these as [build metadata](https://buildkite.com/docs/pipelines/build-meta-data). With `supersede` set it writes `fjall-deploy:supersede-step` first and `fjall-deploy:started` just before the run, and the others once the check or the run has decided.

| Meta-data key                 | Value                                                                                                                                                                                                                                                                                                                                                |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fjall-deploy:result`         | `success`, `plan-pending` (exit 2: the run stopped without failing — a plan with changes pending approval, a plan refused at the approval gate, or a run cancelled before it completed, which can follow a partial change), or `failure`. With `supersede` set, also `superseded` (exit 0, nothing deployed)                                         |
| `fjall-deploy:superseded-by`  | Set only with `superseded`. The number of the newer build whose deploy covers this one                                                                                                                                                                                                                                                               |
| `fjall-deploy:held-by`        | Set only on a build held because the deploy before it did not succeed or has not ended. The number of that build. A held build records no `fjall-deploy:result`. A later retry that deploys leaves it set                                                                                                                                            |
| `fjall-deploy:started`        | Set only with `supersede`, to the job's `BUILDKITE_JOB_ID`, just before the CLI runs. A build whose last started attempt ends with no result of its own holds the next marked build ([Holding after a failed deploy](#holding-after-a-failed-deploy)). When it cannot be recorded, or the job has no id, the hook fails the step before the CLI runs |
| `fjall-deploy:result-job`     | Set only with `supersede`, to the job's `BUILDKITE_JOB_ID`, just after `fjall-deploy:result`. A result beside a result job that is not the started job was left by an earlier attempt. When a deploy that succeeded cannot record its result or its result job, the hook fails the step, and a retry deploys the commit again and records its result |
| `fjall-deploy:supersede-step` | Set only with `supersede`, before the check runs, to the build's `BUILDKITE_BUILD_ID` and the step's `BUILDKITE_STEP_ID` joined by `/`. A second step of the same build that sets `supersede`, or a step with parallelism, then fails before the check, deploying nothing ([Skipping a superseded deploy](#skipping-a-superseded-deploy))            |
| `fjall-deploy:duration`       | Command duration in seconds                                                                                                                                                                                                                                                                                                                          |
| `fjall-deploy:approval-token` | Token from a plan run with pending changes; feed back via `approval-token`                                                                                                                                                                                                                                                                           |

A `superseded` build records no duration. It posts a warning annotation that names the newer build. A held build records no duration either, and posts an error annotation ([Holding after a failed deploy](#holding-after-a-failed-deploy)).

A `plan-pending` result also posts a warning annotation (re-run instructions when the run printed an approval token, otherwise a note that the run stopped before it completed), and the step exits `2` so downstream steps can gate on it.

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
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
```

Pair this with the pipeline settings **Skip Intermediate Builds: ON** (queued stale deploys collapse to the newest) and **Cancel Intermediate Builds: OFF** (never interrupt an in-flight CloudFormation update).

## Skipping a superseded deploy

Set `supersede` when your pipeline creates a deploy build for each green commit on `main`, so an older build that starts late would only repeat what a newer one deploys. A superseded build records `fjall-deploy:result` as `superseded`, posts a warning annotation naming the newer build, and exits `0` without installing the CLI.

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v30:
          target: my-app
          deploy-target: production-use1
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

An empty `after`, `token-secret` or `barriers` item stops the step before anything is fetched, as an empty property does. So does `barriers` given as a single string, unless it is `-`, which means no barriers.

Set `supersede` on one deploy step per build, since the metadata it writes is the build's. A second step of the same build that sets it fails at its start and deploys nothing, so its result never writes over the first step's. A step with `parallelism` fails the same way, since its jobs can run at once and would each write over the others' result. A retry keeps its step's `BUILDKITE_STEP_ID`, so the first step can still be retried, and a claim that names another build, as a rebuild may carry, reads as unset. A rebuild reads and writes the claim too, so a failed read or write fails a rebuild's step, and a retry of that step runs it again. Two steps that start at the same moment are not caught, so give every deploy step one concurrency group ([Serialising Deploys](#serialising-deploys)). Buildkite documents no variable that tells the jobs of a `matrix` step apart, so the check cannot refuse a second job of one, and `supersede` must not be set on a matrix step.

A build skips only when all of these hold.

- Its creator marked it, by sending `"meta_data": {"fjall-deploy:supersedable": "true"}` in the body of its [create build](https://buildkite.com/docs/apis/rest-api/builds#create-a-build) request. A build started from the dashboard carries no marker, so a hand rollback always deploys.
- It is a build of `main`, among the 100 newest `main` builds of its pipeline, and not a rebuild.
- The newest newer build that can still deploy, or has deployed, has passed its `after` step, and its commit has this build's commit in its first parent history. Such a build is running with `fjall-deploy:result` unset or `success`, or passed with `success`. A result counts only when the attempt that last started a deploy recorded it, and a running build whose last started deploy ended with no result counts no more, since that deploy deployed nothing the check can see. Its `after` step is judged by the job the step last ran. A build that recorded anything else, `superseded` included, will not deploy its commit, so it is passed over.
- No commit on that newer build's first parent line, from this build's commit up to the newer build's own, is a barrier. A merge commit on that line is judged by its diff against its first parent, which holds the net change of every commit it merged.

Only that one newer build is judged. When it fails either of the last two checks, this build does not skip, rather than looking at an older one, so it never steps over a hand rollback. A build whose own `fjall-deploy:result` already records anything but `superseded` or `success` never skips either, so the retry of a failed deploy never writes `superseded` over the failure. Nor does a build whose own `fjall-deploy:started` is set, since an earlier attempt then started a deploy whose result may be lost.

A commit on the newer build's first parent line is also a barrier when a line of its message starts with `deploy-alone`. That holds whenever `supersede` is set, with or without a `barriers` list. Only the messages of commits on that line are read. So when a merge commit or a squash lands your change on `main`, put the `deploy-alone` line in the message of the commit on `main`, at the very start of a line. The same line in a merged topic commit is not read.

Any doubt about a newer build deploys. A build its creator did not mark deploys the commit it was given, as it would without `supersede`, when the secret cannot be read, a read of the builds list fails or runs past its bound (30 s a read, 120 s in all), git fails, or the clone is still shallow after `git fetch --unshallow`. A marked build that cannot read the secret or the builds list holds instead ([Holding after a failed deploy](#holding-after-a-failed-deploy)). The check prints one line that says whether it skipped, held or deployed, and why. It runs without `FJALL_API_KEY` in its environment.

`supersede` needs a plugin release that ships it, so the example above uses the moving major tag. An exact pin of an earlier release runs a hook that ignores `supersede` and deploys every build, and nothing warns that it did.

An agent keeps the checkout it made for a plugin ref and does not fetch that ref again unless it sets `plugins-always-clone-fresh` (Buildkite's [agent configuration](https://buildkite.com/docs/agent/v3/configuration) docs). So an agent that cloned `v29` before `supersede` shipped runs the older hook, which ignores `supersede` and deploys every build. That is safe, and it ends when the agent next clones the plugin fresh.

## Holding after a failed deploy

A build its creator marked `fjall-deploy:supersedable`, which `supersede` judges, holds when the deploy before it did not succeed. A held build fails its step without installing the CLI, so it deploys nothing over a deploy that failed or stopped partway. It records neither `fjall-deploy:result` nor `fjall-deploy:started`, sets `fjall-deploy:held-by` to the number of the build that held it and posts an error annotation naming that build.

The deploy before a build is the newest older `main` build on the same page of 100 that recorded a deploy. A build that started a deploy carries `fjall-deploy:started`, set to the job that started it. A build that started none deployed nothing when its `fjall-deploy:result` is unset or `superseded`, so the check passes over it, and so a build that held passes the hold on to the next one. A build holds when that deploy recorded anything but `success`, including `plan-pending`, unless the build carries the marker `fjall-deploy:red-cleared` set to that deploy's number, which its creator sends beside `fjall-deploy:supersedable`.

A started deploy's result counts only when `fjall-deploy:result-job` names the job in `fjall-deploy:started`. A retry is a new job, so a result an earlier attempt left never stands for a later one. A deploy whose result write was lost, or that a step timeout, a lost agent or a cancelled job ended first, records no result of its own. Once the job that started it has ended (`passed`, `failed`, `canceled` or `timed_out`), the check reads its result as `unrecorded`, which holds as `failure` does and which `fjall-deploy:red-cleared` can clear. The check reads the builds list with every retried job, so it finds that job after a retry too. When the list does not hold it, the build's own state decides instead, and the build has ended when it is `passed`, `failed`, `canceled`, `skipped` or `not_run`. Until then the deploy may still be running, so the check holds with the result `unfinished`, which names that build in `fjall-deploy:held-by` and which no marker clears.

```json
{
  "meta_data": {
    "fjall-deploy:supersedable": "true",
    "fjall-deploy:red-cleared": "528"
  }
}
```

A marked build that does not skip holds when a newer `main` build on the page has started a deploy or recorded the result of one, since this build's older commit would deploy over it. That newer build may have deployed and then failed a later step, so it is no build to skip for, or deployed past a barrier, or deployed while this build was held and before it was retried. The build posts an error annotation naming the newer build and records no `fjall-deploy:held-by`. To deploy this build's commit anyway, Rebuild it.

A creator sets `fjall-deploy:red-cleared` only once a person has judged that deploy safe to build on. A build with no deploy before it on a page shorter than 100 deploys, since that page holds the pipeline's whole history.

The check judges a skip first, because a skip deploys nothing. A marked build holds on any doubt, as an unmarked one deploys on it. That covers a secret or builds list it cannot read, a deploy before it that lies past the page, and a check that stops without a verdict. The hook reads the marker through `buildkite-agent meta-data get`, so it holds a marked build even when the builds list cannot be read. When that read fails, the build holds on any doubt, and once the builds list is read, the build's own entry there says whether it is marked, so a hand build still deploys.

A rebuild never holds, and a build started from the dashboard carries no marker. To clear a hold, retry the deploy step of the build named in `fjall-deploy:held-by` until it passes, then retry the held step. When the hold names an `unfinished` deploy, wait for that deploy to end, then retry the held step. When several builds hold on one deploy, retry them oldest first. A newer one that deploys first makes each older one skip, or hold as overtaken when a barrier lies between them. A retry that gets past the check removes the error annotation. To deploy over the failed deploy anyway, Rebuild the held build.

The check reads build metadata, a build's state, the state of the job that started a deploy and the state of a newer build's `after` job, never any other job's state. It does not wait for an older build that has not reached its deploy step, such as one stopped at a block step before it, so give every deploy step one concurrency group ([Serialising Deploys](#serialising-deploys)).

An agent that cloned the plugin before the hold shipped runs a hook that never holds, until it next clones the plugin fresh. A deploy run by a hook from before `fjall-deploy:started` shipped records no marker, so when it ended before recording its result, the check passes over it as it did then.

## Examples

### Infrastructure Only

```yaml
steps:
  - label: ":construction: Infra"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
          mode: infra-only
```

### Code Only

A code-only deploy (`mode: deploy-only`) builds and rolls only what the assembly a full deploy writes to `fjall/<app>/cdk.out` declares, so it needs that assembly in the step's checkout. `cdk.out` is not committed, and a step on another agent, an `infra-only` one included, leaves none behind, so a plugin step's checkout holds it only where a deploy in that checkout wrote it. Where it has none, a `mode: deploy-only` step is refused (through CLI 39.0.8 it rolled nothing and exited 0; an app with capacity-identity pins was refused instead). To ship code without a full deploy, roll an image already built with `image-tag`, which rolls the services the app's Compute stack exports with no assembly (an app with a container-image function in the roll needs the assembly for that too, so deploy such an app in full):

```yaml
steps:
  - label: ":package: Code"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
          image-tag: "app-sha-4f9c2ab0d1e3"
```

### Destroy

```yaml
steps:
  - label: ":fire: Destroy"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          command: destroy
          target: my-app
          deploy-target: production-use1
          force: true
```

### Deploy Specific Service

`service` narrows an `image-tag` roll, or a code-only deploy, to one service. From fjall 40 it selects the service by its whole name, ignoring case, so `service: worker` rolls `worker`, never `scan-worker`, and a name that matches no service is refused, listing the services there are. Fjall 39 also selects every service whose name ends with the name given, so with it `service: worker` rolls `scan-worker` too. A code-only deploy needs the assembly a full deploy wrote in the step's checkout (Code Only, above):

```yaml
steps:
  - label: ":whale: API"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
          service: api
          image-tag: "api-sha-4f9c2ab0d1e3"
```

### Deploy a Tier

A tier `target` routes to the noun-verb tier command. This runs `fjall org deploy --non-interactive --no-cascade` (the organisation root stack without its platform/account cascade):

```yaml
steps:
  - label: ":earth_africa: Organisation"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: organisation
          no-cascade: true
```

### Roll Back to a Previous Image

`image-tag` re-deploys an existing image without rebuilding (implies `deploy-only`):

```yaml
steps:
  - label: ":rewind: Roll back"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
          image-tag: "sha-4f9c2ab"
```

Find valid tags with `fjall releases my-app` (each release records the image tags it shipped), from the original deploy's output, or from the app's ECR repository. An image-tag rollback re-pins application code only — it does not revert infrastructure changes or roll back database migrations.

### Pin CLI Version

```yaml
steps:
  - label: ":rocket: Deploy"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
          cli-version: "39.0.0"
```

### Staging to Production Pipeline

```yaml
steps:
  - label: ":test_tube: Staging"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          environment: staging

  - wait

  - block: ":raised_hand: Deploy to Production?"

  - label: ":rocket: Production"
    plugins:
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          environment: production
```

The production step builds what it deploys. `skip-build` would not reuse what staging built: it skips only a static-site or OpenNext build command, never a Docker build.

## Installing Your Project's Dependencies

The plugin installs only the `fjall` CLI, and its `command` hook replaces the step's own command, so the step can't install anything before the deploy. When the deploy builds your app, as it does for a Payload or Next.js app that OpenNext builds, the build needs your project's dependencies installed. Install them from a repository `pre-command` hook (`.buildkite/hooks/pre-command`). That hook runs before every job of the pipeline, so limit it to the deploy step and run the install in the folder that holds the lockfile.

```bash
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BUILDKITE_STEP_KEY:-}" == "deploy" ]]; then
  cd path/to/project
  npm ci
fi
```

Use the install your lockfile calls for, such as `corepack enable && pnpm install --frozen-lockfile` or `corepack enable && yarn install --immutable`.

## Caching the CLI Install

The hook installs `cli-version` with `npm install -g` on every run. npm's cache spares the download, and it also decides what is installed: npm checks a package against the integrity its metadata names, reads that metadata from the same cache, and serves a cached copy without asking the registry while the copy's headers call it fresh. Measured on npm 11.17.0 (2026-10-15), metadata and a tarball planted in npm's cache made `npm install -g` install a version the registry never published and run its install script. This hook installs with `--ignore-scripts`, so no install script runs here, but the CLI a planted entry installs is the one the deploy then runs, with `FJALL_API_KEY` in its environment. `--prefer-online` did not stop it: npm asked the registry, which answered the ETags the planted entries carried with 304 Not Modified, and npm kept the planted copies. Whoever can write the cache chooses the CLI your deploy runs, so share it only with builds you would trust to deploy:

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
      - fjall-tech/fjall-deploy#v30.0.0:
          target: my-app
          deploy-target: production-use1
```

Keep the path absolute and outside the checkout. A service with no `docker.context` builds from its Dockerfile's directory, which for a Dockerfile at the repository root is the whole checkout, and npm writes a new debug log into its cache on every run: a cache inside the checkout would go into every build's context and change it each time, so a `COPY . .` layer and every layer after it would rebuild on every deploy. Cache volumes are best-effort: a job that gets an empty one downloads as before.

## Versioning

Two pins interact, and they move together:

- **The plugin ref** — `fjall-tech/fjall-deploy#v30` is a moving major tag, repointed at the latest 30.x release on each plugin republish; `#v30.0.0` pins an exact release for maximum determinism.
- **`cli-version`** — the `fjall` CLI the plugin installs per run; it defaults to the plugin major's compatible CLI major.

Upgrade majors deliberately. A new plugin major either defaults to a new CLI major, or changes the plugin's own contract on the same CLI major, as v30 did: read its entry under [Breaking changes](#breaking-changes) before moving the ref, and when the CLI major changes, move any explicit `cli-version` pin in the same change.

## Breaking changes

### v30.0.0

v30 is a new plugin major, so a pipeline pinned to `#v29` keeps the old behaviour until its owner moves the pin. A pipeline that names the plugin with no version, or `#main`, runs the plugin's `main` branch, which moved to v30 when v30 was published and moves to v31 with the fjall 40 release. v30 installs the same CLI major as v29, 39; v31 carries these changes with the CLI 40 default.

A property given an empty value, and a boolean that is not exactly `true` or `false`, now stops the step at its start, before anything is fetched or installed, with an error naming the property and never repeating the value. Before, an empty value read as the property left out, and a boolean spelled any other way took the false arm: a step asked to plan deployed, an approval gate was dropped, an organisation deploy or destroy cascaded. A property left out takes its default as before, and `-` means none for every property without a default.

- **An empty value of any property:** an interpolation whose variable is unset (`"${ROLLBACK_TAG}"`), or a value left blank on purpose, now stops the step. Leave the property out, give it a value, or, for a property without a default, write `"${ROLLBACK_TAG:--}"`, which a pipeline upload turns into `-` when the variable is unset or empty. Pass `approval-token` the plan's token as it is: with `-`, an apply after a cancelled plan runs with no token and could deploy with no reviewed plan, unless the step sets `require-approval: true` without `auto-approve: true`.
- **A false not written as `false`:** quoted `'False'`, `'no'` or `'0'`; unquoted `0`; a padded value; or an interpolation that resolves to one of these. Unquoted `no`, `off` and `n` too, wherever the pipeline is parsed as YAML 1.2, as agent v3.138.0's upload does; an agent that parses YAML 1.1 hands those three to the plugin as `false`, which it accepts. These read as false, and now stop the step. Write `false`, or leave the property out.
- **A true not written as `true`:** quoted `'True'` or `'yes'`; unquoted `1`; and unquoted `yes`, `on` and `y` where the pipeline is parsed as YAML 1.2. These ran the false arm before. Write `true`, and check what earlier runs did. Unquoted `True` and `TRUE` reach the plugin as `true`.
- **List properties:** `build-args` or `build-secrets` given as a single string other than `-`, including `""` (for example a templated `"${EXTRA}"`); a list with an empty item, including a trailing `- "${OPTIONAL}"` that is unset; or a map. Give a YAML list of non-empty strings, and leave optional items out; a single `-` means no list.
- **`-`:** the plugin refused `-` as flag-shaped. It now reads it as left out for `service`, `environment`, `deploy-target`, `region`, `image-tag` and `approval-token`, and as no list for `build-args` and `build-secrets`, as the GitHub Action does. Every other property refuses it at the start, `cli-version` and `working-directory` included, which handed it to npm as a version and to `cd` as the previous directory.
- **The deploy token in later hooks:** a token the plugin fetches from the secret store is no longer exported, so a post-command or pre-exit hook in the same job never sees it; after a run that succeeded, it used to. A later hook that needs it can fetch it with `buildkite-agent secret get FJALL_API_KEY`. A token the environment supplies is left as the pipeline set it.
- **Job variables in the CLI:** the CLI, and with it `infrastructure.ts` and the image build, saw the plugin's own value of any upper-case name but `PATH` and `FJALL_API_KEY` that the plugin set for itself before running the CLI (`REGION`, `ENVIRONMENT`, `IMAGE_TAG`, `TARGET` or `NODE_VERSION`, for example), when the job exported the same name, and its own `PATH` and `FJALL_API_KEY` whenever it set them; and, when the job exported `ARGS`, no `ARGS` at all, nor on a tier target `INCOMPATIBLE`. It now sees each of them but `PATH` and `FJALL_API_KEY`, which the plugin still sets for a Node it bootstraps and a token it fetches, as the job exported it: set the job's variable to the value the CLI should see. The plugin's own names are now lower-case, so a job variable that shares a name the plugin sets outside a function before running the CLI (`target`, `region` or `log_file`, for example) reaches the CLI with the plugin's value, or, for `args`, and on a tier target `incompatible`, not at all.
- **Later hooks and the artifact upload, after a run that succeeds:** they started in `working-directory`, with the Node the plugin bootstrapped, by then removed, first on `PATH`, and with the plugin's own values in any job variable that shares a name with one of the plugin's (`REGION`, `ENVIRONMENT`, `IMAGE_TAG` or `NODE_VERSION`, for example). They now start in the job's own directory with the job's own environment, as they did after a run that failed: the plugin's hook runs itself as a child of the shell the agent sources it into, which also reads a `BASH_ENV` the job sets a second time. Give `artifact_paths`, and any path a later hook reads, from the checkout directory.
- **The Node download:** on an agent whose Node is below the plugin's floor (see [Requirements](#requirements)), the plugin downloads Node from nodejs.org, and that download no longer waits however long it takes: an attempt is cut at ten minutes, or after a minute below 1 KB/s, and no new attempt starts after five minutes. The tarball is about 30 MB, so an agent that cannot fetch it at about 50 KB/s now fails the step, where v29 finished late. Install a Node at or above the floor on such an agent.
- **The CLI install:** the CLI now installs with `--ignore-scripts`. On an agent whose npm configuration omits optional dependencies (`omit=optional`), esbuild's install script used to fetch its binary; now the CLI fails the first time it needs esbuild. Let npm install optional dependencies.

Rollback: the pipeline's owner pins the previous major, `v29`, which keeps the old behaviour.

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

A deploy that builds a container image needs Docker, running, with the buildx plugin, and so does every `build`. With CLI 40 or later, a deploy checks for them once it knows it will build an image, before it changes a stack, and a deploy that builds none (a static site's, an OpenNext app's, an `image-tag` deploy, or a `mode: infra-only` deploy that does not deploy its Compute stack, because that stack did not change and `force` is not set) never checks. An image that CDK builds as an asset, whether the app's own CDK code declares it or hands it to a Fjall construct (a scheduled task's `image` given as `ContainerImage.fromAsset(...)`), is built by CDK when its stack deploys, and the check does not cover it. On the 39.x CLI, every application deploy checks for buildx before it starts, whatever the app builds, unless it sets `mode: infra-only` or `skip-build`. That check passes while Docker is stopped, and `skip-build` skips only a static-site or OpenNext build command, so on an agent that cannot build, a container app's full deploy that gets past the check fails at the image build, after the stacks before Compute have deployed. Install Docker with the buildx plugin on self-hosted agents that build images.

## Requirements

- Node.js >= 22.12.0 — if the agent's node is below that floor (or absent), the plugin bootstraps a pinned Node build from nodejs.org, SHA-256-verified before use (a Linux x64 or arm64 agent with `curl` and `tar` is required for the bootstrap path; a download that stalls is cut and retried, and fails rather than holding the step)
- npm
- Docker with buildx — every `build`, and every application deploy that builds a container image; on the 39.x CLI, every application deploy without `mode: infra-only` or `skip-build` checks for buildx before it starts, whatever the app builds (see [`docker: command not found`](#docker-command-not-found))
- A Fjall deploy token (`FJALL_API_KEY`), which is also the deploy's AWS credential unless the step's environment carries AWS keys — see [Authentication](#authentication)

## Running Tests

```bash
docker compose run --rm tests
```

## License

MIT
