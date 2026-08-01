#!/usr/bin/env bats

setup() {
  load "$BATS_PLUGIN_PATH/load.bash"

  # The hook fetches FJALL_API_KEY from Buildkite secrets only when the
  # environment lacks it; pre-set it so the default path never calls
  # `buildkite-agent secret get`. The dedicated secret-fetch test unsets it.
  export FJALL_API_KEY="fjall_dk_bats"

  # The hook bootstraps Node only when the agent's node is older than the CLI's
  # required major; report a compatible node so the default path skips the
  # curl/verify/extract bootstrap. The Node-bootstrap tests drain-and-replace
  # this with an old-node stub.
  stub node "--version : echo 'v22.14.0'"

  # Create a stub for npm. With no cli-version set, the hook defaults to
  # FJALL_CLI_DEFAULT_MAJOR (design § 5.2 version tie), so the default install
  # is `fjall@5`, not bare `fjall`.
  stub npm "install -g fjall@5 : echo 'installed fjall@5'"

  # Create a stub for fjall. The second plan line uses the `::` unconditional
  # form — a bare `*` pattern only matches single-argument invocations in
  # current bats-mock (extra arguments are rejected as unexpected).
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    ":: echo \"fjall \$@\""
}

teardown() {
  # Tolerant unstubs: early-exit tests (missing target, leading-dash rejection)
  # leave node/npm/fjall plans unconsumed, and the Node-bootstrap tests stub
  # uname/curl/sha256sum/tar that other tests never touch.
  unstub node || true
  unstub npm || true
  unstub fjall || true
  unstub buildkite-agent || true
  unstub uname || true
  unstub curl || true
  unstub sha256sum || true
  unstub tar || true
}

@test "Deploys with minimal config via ci run" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "Deploys with infra-only mode" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="infra-only"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --non-interactive --mode infra-only"
}

@test "Deploys with deploy-only mode" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="deploy-only"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --non-interactive --mode deploy-only"
}

@test "Deploys with verbose flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_VERBOSE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--verbose"
}

@test "Deploys with environment flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_ENVIRONMENT="staging"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--environment staging"
}

@test "Deploys with skip-build flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SKIP_BUILD="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--skip-build"
}

@test "Deploys with skip-migrations flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SKIP_MIGRATIONS="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--skip-migrations"
}

# T3: the tier words are noun-verb. A tier target routes to `fjall <noun>
# <verb>` — the app-only `ci run <cmd> <target>` surface rejects them — and
# only the flags a tier leaf honours (force, verbose, organisation-only
# no-cascade) may accompany it. Every other property is rejected at the plugin
# boundary rather than silently dropped, so a `plan: true` can never become an
# unpreviewed tier mutation.
@test "organisation target routes to the noun-verb org deploy, not ci run" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_VERBOSE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall org deploy --non-interactive --verbose"
  refute_output --partial "ci run"
}

@test "organisation no-cascade routes with --no-cascade on the org leaf" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_NO_CASCADE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall org deploy --non-interactive --no-cascade"
}

@test "platform target routes to the noun-verb platform deploy" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="platform"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall platform deploy --non-interactive"
  refute_output --partial "ci run"
}

@test "account destroy routes to the noun-verb account destroy with --force" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="account"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_FORCE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall account destroy --non-interactive --force"
}

@test "no-cascade with an app target is rejected (cascade is organisation-only)" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_NO_CASCADE="true"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "no-cascade is only valid with target: organisation"
}

@test "no-cascade with a non-organisation tier is rejected" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="platform"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_NO_CASCADE="true"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "only valid with target: organisation"
}

@test "an app/deploy-only property with a tier target is rejected, not dropped" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_PLAN="true"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "not valid with tier target 'organisation'"
  assert_output --partial "plan"
}

@test "build is application-only: a tier build target is rejected" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="build"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "application-only"
}

@test "Deploys with region and image-tag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REGION="eu-west-1"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_IMAGE_TAG="abc123"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--region eu-west-1"
  assert_output --partial "--image-tag abc123"
}

@test "Deploys with plan and approval flags" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_PLAN="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REQUIRE_APPROVAL="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_APPROVAL_TOKEN="tok-1"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--plan"
  assert_output --partial "--require-approval"
  assert_output --partial "--approval-token tok-1"
}

@test "Deploys with indexed build-args and build-secrets arrays" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0="A=1"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_1="B=2"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_SECRETS_0="id=x,ssm=/p"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "--build-arg A=1"
  assert_output --partial "--build-arg B=2"
  assert_output --partial "--build-secret id=x,ssm=/p"
}

@test "Deploys with specific service via --service" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SERVICE="api"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --service api --non-interactive"
}

@test "Destroys with force flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_FORCE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run destroy my-app --non-interactive --force"
}

@test "Build command routes through ci run" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="build"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run build my-app --non-interactive"
  refute_output --partial "--skip-confirmation"
}

@test "Installs pinned CLI version" {
  # setup()'s npm plan is unconsumed at this point, so unstub reports failure
  unstub npm || true
  stub npm "install -g fjall@1.0.0 : echo 'installed fjall@1.0.0'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="1.0.0"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "installed fjall@1.0.0"
}

# L0a (engine-version contract) — `cli-version: auto` resolves the engine major
# from the app's pinned @fjall/components-infrastructure and installs that major,
# so the deploy engine never skews across a major from the constructs it
# synthesises. The hook shells out to the sibling resolve-fjall-engine.mjs; its
# echoed spec (not the baked default) drives the install.
@test "cli-version auto installs the engine major the resolver echoes" {
  # Drain setup()'s single-line compatible-node plan, then re-stub node for BOTH
  # calls the auto path makes: the bootstrap `node --version` check, then the
  # `node <resolver> <workdir>` invocation. The second plan line uses the `::`
  # unconditional form so it matches the resolver's multi-arg invocation. Echo a
  # major (7) that is NOT the baked default (4) so the assertion proves the
  # resolver's output drove the install, not the fallback.
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v22.14.0'" \
    ":: echo 'fjall@7'"

  # setup()'s npm plan expects `install -g fjall@5`; the resolver echoed 7, so
  # drain and re-stub for the resolved spec.
  unstub npm || true
  stub npm "install -g fjall@7 : echo 'installed fjall@7'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "installed fjall@7"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

# The resolver fails loud (non-zero exit) when it cannot determine a single
# engine major — no pin, an unparseable range, or pins conflicting across a
# major. The hook MUST abort the step, never guessing a major, and never reach
# npm or fjall. setup()'s npm plan is left in place: if the hook wrongly
# proceeded past the failed resolver it would call npm with an empty spec, which
# does not match `install -g fjall@5`, turning the test red rather than passing.
@test "cli-version auto fails the step when the engine resolver cannot resolve a major" {
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v22.14.0'" \
    ":: exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Failed to resolve the fjall engine"
  refute_output --partial "ci run"
}

@test "Fails when target is missing" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET=""

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Error: 'target' is required"
}

@test "Mode is forwarded on destroy for CLI-side rejection" {
  # The shim no longer silently drops incompatible flags — the CLI owns
  # validation and rejects --mode for destroy with a directional error.
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="infra-only"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run destroy my-app --non-interactive --mode infra-only"
}

@test "Full deploy with all options" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SERVICE="api"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="deploy-only"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_ENVIRONMENT="production"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_VERBOSE="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SKIP_BUILD="true"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --service api --non-interactive --mode deploy-only --environment production --skip-build --verbose"
}

# H1a — argv injection safety. A value carrying spaces / extra --flags must reach
# the CLI as ONE argv element, never word-split into injected arguments. The stub
# prints each positional arg on its own `ARG:`-prefixed line so a word-split shows
# up as a standalone `ARG:--injected-flag` line (which the old `fjall ${ARGS}`
# form produced and the array form does not).
@test "argv is injection-safe: a spaced target is a single argument (no word-split)" {
  # bats-mock v2.2.0 verifies plan consumption at unstub, so drain setup()'s
  # 2-line fjall plan before replacing it with the per-argument printing stub.
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  # The 5-token pattern doubles as the injection assertion: a word-split target
  # would produce 6 argv elements, which bats-mock rejects as an extra argument.
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy * --non-interactive : printf 'ARG:%s\n' \"\$@\""

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app --injected-flag"

  run "$PWD/hooks/command"

  assert_success
  # The whole value arrives atomically…
  assert_output --partial "ARG:my-app --injected-flag"
  # …and never as its own injected flag argument.
  refute_output --partial "ARG:--injected-flag"
}

@test "argv is injection-safe: a spaced environment value is a single argument" {
  # Same drain-then-replace shape as the spaced-target test above.
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  # 7-token pattern: a word-split environment value would produce 8 argv
  # elements, which bats-mock rejects as an extra argument.
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive --environment * : printf 'ARG:%s\n' \"\$@\""

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_ENVIRONMENT="staging --force"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "ARG:staging --force"
  refute_output --partial "ARG:--force"
}

@test "propagates the CLI's non-zero exit status through the tee pipeline" {
  # Drain-then-replace shape (see the injection tests above).
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive : exit 5"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_failure 5
}

@test "exit 2 (plan pending) propagates and classifies as plan-pending with the captured token" {
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive --plan : echo 'Approval token: tok-123'; exit 2"
  stub buildkite-agent \
    "meta-data set fjall-deploy:result plan-pending : true" \
    "meta-data set fjall-deploy:duration * : true" \
    "meta-data set fjall-deploy:approval-token tok-123 : true" \
    "annotate --style warning * : true"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_PLAN="true"

  run "$PWD/hooks/command"

  # unstub asserts all four buildkite-agent calls happened with those args
  unstub buildkite-agent
  assert_failure 2
}

@test "a transient buildkite-agent failure does not overwrite a successful deploy" {
  stub buildkite-agent \
    "meta-data set fjall-deploy:result success : exit 1" \
    "meta-data set fjall-deploy:duration * : true"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
}

# L3 (design § 5.1) — deploy-target maps to `--target` (the precise credential
# where) on the app path, distinct from `environment` (the stage selector).
@test "deploy-target routes to --target on the app path" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_DEPLOY_TARGET="production-use1"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "fjall ci run deploy my-app --non-interactive --target production-use1"
}

# The tier path (org/platform/account) is noun-verb and has no --target; a
# deploy-target with a tier target is rejected rather than silently dropped —
# consistent with every other app-only property on the tier path.
@test "deploy-target with a tier target is rejected, not dropped" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_DEPLOY_TARGET="production-use1"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "not valid with tier target 'organisation'"
  assert_output --partial "deploy-target"
}

# L3 (design § 5.2) — the hook fetches FJALL_API_KEY from Buildkite's secret
# store when the environment lacks it, so a pipeline need only store the secret.
@test "fetches FJALL_API_KEY from Buildkite secrets when the environment lacks it" {
  unset FJALL_API_KEY
  stub buildkite-agent \
    "secret get FJALL_API_KEY : echo 'fjall_dk_fetched'" \
    "meta-data set fjall-deploy:result success : true" \
    "meta-data set fjall-deploy:duration * : true"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "Fetching FJALL_API_KEY from Buildkite secrets"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

# L3 (design § 5.2) — when the agent's node is older than the CLI's required
# major the hook bootstraps a pinned build, verified against its SHA-256 before
# extraction, and prepends it to PATH.
@test "bootstraps a pinned, SHA-verified Node when the agent node is too old" {
  # Drain setup()'s compatible-node plan, then replace with an old node so the
  # bootstrap path fires (mirrors the fjall drain-then-replace idiom above).
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub uname "-m : echo 'x86_64'"
  stub curl "-fsSL -o * * : true"
  stub sha256sum "-c - : true"
  stub tar "-xJf * -C * : true"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  # The pinned build was fetched, verified, and extracted before the CLI ran.
  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_output --partial "Bootstrapping Node 24.18.1"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

# The SHA-256 check is a gate, not a log line: a digest mismatch aborts under
# `set -e` before the tarball is extracted or the CLI runs.
@test "a Node tarball failing SHA-256 verification aborts before extraction" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub uname "-m : echo 'x86_64'"
  stub curl "-fsSL -o * * : true"
  stub sha256sum "-c - : exit 1"
  # Make extraction observable. A correct gate aborts under set -e before `tar`
  # runs, so this plan stays unconsumed (teardown's tolerant `unstub tar` covers
  # it) and EXTRACTED never prints. A neutralised gate (e.g. `sha256sum -c - ||
  # true`, or verification moved after extraction) would reach `tar`, print the
  # marker, and turn `refute_output EXTRACTED` red — pinning "before extraction".
  stub tar "-xJf * -C * : echo 'EXTRACTED'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub curl
  unstub sha256sum
  assert_failure
  assert_output --partial "Bootstrapping Node 24.18.1"
  refute_output --partial "EXTRACTED"
  refute_output --partial "ci run"
}

# Flag-shaped property values are rejected before fjall runs — a value beginning
# with '-' would be parsed by commander as a flag rather than a value.
@test "a flag-shaped property value is rejected before fjall runs" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SERVICE="--oops"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'service' must not begin with '-'"
  refute_output --partial "ci run"
}

# The guard also fires per-item inside the build-args / build-secrets loops.
@test "a flag-shaped build-arg is rejected per item" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0="--sneaky=1"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'build-args' must not begin with '-'"
}
