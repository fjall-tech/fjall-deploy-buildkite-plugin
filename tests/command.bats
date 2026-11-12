#!/usr/bin/env bats

# The hook's pins are READ here, never restated. A literal copy in this file
# rots silently — a hardcoded CLI major survived two majors before this suite
# first ran in CI — and the Node pins rot worse than the major did: a raised
# node_floor turns the "compatible agent" stub below into a below-floor one,
# so every default-path test starts down the bootstrap branch it was written
# to skip. An unreadable pin is a failure, not a default: an empty value would
# stub `v` as the agent's version and every assertion after it would be
# vacuous.
read_hook_pin() {
  local value
  value="$(sed -n "s/^$1=\"\([^\"]*\)\"\$/\1/p" "$PWD/hooks/command")"
  [ -n "$value" ] || {
    echo "could not read $1 from hooks/command" >&2
    return 1
  }
  printf '%s' "$value"
}

# The properties plugin.yml declares with one type, one name per line. The
# table tests walk these lists rather than a list of their own, so a property
# added to the manifest joins every test that covers its type. An empty list
# is a failure, not a pass over nothing.
properties_of_type() {
  local names
  names="$(awk -v type="$1" '
    /^    [a-z-]+:$/ { name = substr($1, 1, length($1) - 1) }
    /^      type: / && $2 == type { print name }
  ' "$PWD/plugin.yml")"
  [ -n "$names" ] || {
    echo "could not read any $1 property from plugin.yml" >&2
    return 1
  }
  printf '%s\n' "$names"
}

# The properties plugin.yml neither requires nor gives a default (`without`),
# or the ones it does (`with`), one name per line: `-` means none for the
# first, which have no value of their own, and for no other.
properties_by_own_value() {
  local names
  names="$(awk -v want="$1" '
    /^    [a-z-]+:$/ { name = substr($1, 1, length($1) - 1); order[++count] = name }
    /^      default: / { defaulted[name] = 1 }
    /^  required:$/ { in_required = 1; next }
    in_required && /^    - / { required[$2] = 1 }
    END {
      for (i = 1; i <= count; i++) {
        own = (order[i] in defaulted) || (order[i] in required)
        if (own == (want == "with")) print order[i]
      }
    }
  ' "$PWD/plugin.yml")"
  [ -n "$names" ] || {
    echo "could not read any property $1 a value of its own from plugin.yml" >&2
    return 1
  }
  printf '%s\n' "$names"
}

# The environment variable the hook reads a property from.
property_env() {
  printf 'BUILDKITE_PLUGIN_FJALL_DEPLOY_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# A stub's command that names each credential it was handed, never a value,
# as "<tool> holds <NAME>".
credential_report() {
  printf 'for name in FJALL_API_KEY BUILDKITE_AGENT_ACCESS_TOKEN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do if [ -n "${!name-}" ]; then echo "%s holds ${name}"; fi; done' "$1"
}

# The agent's node, npm and fjall, as one run of the hook calls them. npm and
# the version check say which credentials reached them, and the CLI whether it
# holds the deploy token the test expects (EXPECTED_DEPLOY_TOKEN); the CLI
# also leaves the environment it was given in cli-env.
stub_agent_tools() {
  stub node "--version : echo 'v${HOOK_NODE_VERSION}'"
  stub npm "install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR} : echo 'installed fjall@${FJALL_CLI_DEFAULT_MAJOR}'; $(credential_report npm)"

  # The second plan line uses the `::` unconditional form — a bare `*` pattern
  # only matches single-argument invocations in bats-mock v2.2.0, the release
  # docker-compose.yml's image carries (extra arguments are rejected as
  # unexpected). It prints the argv it was given behind a prefix the hook
  # never prints: the hook's own header line (`--- :rocket: fjall …`) carries
  # the same words, so an assertion on those words alone passes with the CLI
  # never called.
  stub fjall \
    "--version : echo 'fjall/0.88.3'; $(credential_report 'fjall --version')" \
    ":: echo \"cli received: \$*\"; if [ -n \"\${FJALL_API_KEY-}\" ] && [ \"\${FJALL_API_KEY}\" = \"\${EXPECTED_DEPLOY_TOKEN-}\" ]; then echo 'cli holds the deploy token'; fi; $(credential_report cli); env > '${BATS_TEST_TMPDIR}/cli-env'"
}

# The bootstrap's doubles for an agent whose `uname -m` reads $1 and whose
# tarballs nodejs.org names $2 (x64 or arm64): curl answers only the bounded
# download of the hook's version, sha256sum only the hook's digest for that
# architecture against that tarball, and tar unpacks a Node whose npm says it
# ran, so a test can tell the bootstrapped toolchain from the agent's.
stub_node_bootstrap() {
  local machine="$1" arch="$2" digest dist
  digest="$(read_hook_pin "node_sha256_${arch}")"
  dist="node-v${HOOK_NODE_VERSION}-linux-${arch}"
  printf '#!/usr/bin/env bash\necho "bootstrapped npm ran: $*"\n' > "$BATS_TEST_TMPDIR/bootstrapped-npm"
  chmod +x "$BATS_TEST_TMPDIR/bootstrapped-npm"
  stub uname "-s : echo 'Linux'" "-m : echo '${machine}'"
  stub curl "-fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --max-time 600 --retry 2 --retry-max-time 300 -o * https://nodejs.org/dist/v${HOOK_NODE_VERSION}/${dist}.tar.xz : true"
  stub sha256sum "-c - : read -r digest file; [ \"\${digest}\" = '${digest}' ] && [ \"\${file##*/}\" = '${dist}.tar.xz' ] && echo 'sha256sum checked the pinned ${arch} digest'"
  stub tar "-xJf * -C * : mkdir -p \"\$4/${dist}/bin\" && cp '$BATS_TEST_TMPDIR/bootstrapped-npm' \"\$4/${dist}/bin/npm\""
}

# Runs the hook through a copy of the wrapper agent v3.138.0 runs a shell
# hook in (internal/job/hook/wrapper.go): it dumps the environment, sources
# the hook, records the hook's exit status and working directory, and dumps
# the environment again. When the hook exits 0, the agent carries the
# difference, and that directory, into the rest of the job. The dumps are
# left in env-before and env-after, sorted, with `env` standing in for
# `buildkite-agent env dump`.
run_hook_through_agent_wrapper() {
  printf '%s\n' \
    'env | sort > "${HOOK_ENV_BEFORE}"' \
    '. "${HOOK_UNDER_TEST}"' \
    'export BUILDKITE_HOOK_EXIT_STATUS=$?' \
    'export BUILDKITE_HOOK_WORKING_DIR="${PWD}"' \
    'env | sort > "${HOOK_ENV_AFTER}"' \
    'exit "${BUILDKITE_HOOK_EXIT_STATUS}"' > "$BATS_TEST_TMPDIR/hook-wrapper"
  export HOOK_UNDER_TEST="$PWD/hooks/command"
  export HOOK_ENV_BEFORE="$BATS_TEST_TMPDIR/env-before"
  export HOOK_ENV_AFTER="$BATS_TEST_TMPDIR/env-after"
  run bash "$BATS_TEST_TMPDIR/hook-wrapper"
}

# Writes a shim into TOKEN_SHIMS for each command named, which says on
# stderr when a variable in its environment holds the deploy token the test
# expects (EXPECTED_DEPLOY_TOKEN itself aside), as "<command> <first
# argument> holds the deploy token", and then runs the command it stands in
# for. It reads its environment with builtins alone, and speaks only for a
# process the hook started itself: it marks what it runs, so the processes a
# stub starts for its own bookkeeping, inside the CLI's stub included, stay
# quiet. A test puts the shims first on PATH for its run of the hook alone
# (`PATH="${TOKEN_SHIMS}:${PATH}" run …`), so the commands bats runs after
# the test never meet them.
shim_reporting_the_token() {
  local shims="$BATS_TEST_TMPDIR/shims" command real
  TOKEN_SHIMS="$shims"
  mkdir -p "$shims"
  for command in "$@"; do
    real="$(command -v "$command")"
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'if [ -z "${STARTED_BY_A_SHIM-}" ]; then' \
      '  for name in $(compgen -e); do' \
      '    if [ "${name}" != EXPECTED_DEPLOY_TOKEN ] && [[ "${!name}" == *"${EXPECTED_DEPLOY_TOKEN}"* ]]; then' \
      "      echo \"${command} \${1-} holds the deploy token\" >&2" \
      '      break' \
      '    fi' \
      '  done' \
      'fi' \
      'export STARTED_BY_A_SHIM=1' \
      "exec '${real}' \"\$@\"" > "$shims/$command"
    chmod +x "$shims/$command"
  done
}

# Every name the hook once gave a variable of its own, in upper case, and
# DEPLOY_TOKEN, which it once held the token under: names a job may export
# for itself, NODE_VERSION among them in the official node images.
FORMER_HOOK_NAMES="COMMAND TARGET SERVICE MODE ENVIRONMENT DEPLOY_TARGET VERBOSE SKIP_BUILD NO_CASCADE REGION IMAGE_TAG PLAN REQUIRE_APPROVAL AUTO_APPROVE APPROVAL_TOKEN CLI_VERSION WORKING_DIR FORCE NOT_REPEATED TIER_NOUN INCOMPATIBLE ARGS PLUGIN_DIR RESOLVED_ENGINE_SPEC LOG_FILE START EXIT_CODE END DURATION TOKEN_LINE RESULT FJALL_CLI_DEFAULT_MAJOR NODE_FLOOR NODE_VERSION NODE_SHA256_X64 NODE_SHA256_ARM64 NODE_AGENT_VERSION NODE_SORTED NODE_LOWEST NODE_OS NODE_ARCH NODE_SHA256 NODE_DIST NODE_TARBALL NODE_TMP DEPLOY_TOKEN SUPERSEDE SUPERSEDE_AFTER SUPERSEDE_TOKEN_SECRET SUPERSEDE_BARRIERS SUPERSEDE_BARRIER_NAMES SUPERSEDE_TOKEN SUPERSEDE_LINE SUPERSEDE_STATUS SKIP_LINE_PATTERN NEWER_NUMBER NEWER_COMMIT NEWER_BUILD OWN_COMMIT"

# The job exports each of those names with a value of its own.
export_former_hook_names() {
  local name
  for name in ${FORMER_HOOK_NAMES}; do
    export "${name}=the job's ${name}"
  done
}

# The CLI was given each of those names with the job's value.
assert_cli_was_given_the_job_values() {
  local name
  for name in ${FORMER_HOOK_NAMES}; do
    run grep -Fx "${name}=the job's ${name}" "$BATS_TEST_TMPDIR/cli-env"
    assert_success
  done
}

# Every variable name a bash script sets, one per line, as its text shows
# them, in the forms this hook writes. A line whose first non-blank
# character is # is skipped, however it ends, unless it continues the line
# before; any other line that ends in an odd number of backslashes is joined
# to the next. Each line then gives: an assignment (NAME=, NAME+=, NAME[…]=), a
# command's prefix assignment included; the name given to printf -v; the
# names given to read while each option that takes an argument is a word of
# its own; the variable of a for … in loop; the names given to local,
# declare, typeset, readonly or export; and every word of every for list
# over a variable that printf -v is given as "${var}" or "$var".
#
# It reads text rather than parsing it. A name set in any other form goes
# unseen: ${NAME:=…}; an arithmetic assignment not spelled NAME= or NAME+=
# ((( NAME = 0 )), (( NAME++ )), let NAME++); mapfile and readarray; a read
# whose options are grouped before an option argument (read -rd '' NAME),
# or whose option argument holds a space; getopts, select and coproc; a for
# loop with no in list; a nameref's target; a name written in quotes, but
# printf -v's; a word a for list takes from an expansion; and a name made at
# run time other than through such a for list (export "${name}=…", eval,
# printf -v "$1"). The hook uses none of those forms. A word that only looks
# like a form it reads, in a string, a trailing comment, a heredoc or a
# declaration that only prints a name (declare -p NAME), can be read as a
# name, so an upper-case one there fails the test it feeds, never passes it.
variables_set_in() {
  awk '
    BEGIN { quote = sprintf("%c", 39) }
    held == "" && /^[[:space:]]*#/ { next }
    {
      line = held $0
      held = ""
      if (match(line, /\\+$/) && RLENGTH % 2 == 1) {
        held = substr(line, 1, length(line) - 1)
        next
      }
      rest = line
      while (match(rest, /(^|[^A-Za-z0-9_$-])[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?[+]?=/)) {
        name = substr(rest, RSTART, RLENGTH)
        sub(/^[^A-Za-z_]/, "", name)
        sub(/(\[[^]]*\])?[+]?=$/, "", name)
        print name
        rest = substr(rest, RSTART + RLENGTH)
      }
      count = split(line, word, /[[:space:];&|()]+/)
      for (i = 1; i <= count; i++) {
        if (word[i] == "printf" && word[i + 1] == "-v") {
          target = word[i + 2]
          gsub(/"/, "", target)
          gsub(quote, "", target)
          if (target ~ /^[$]/) {
            gsub(/[${}]/, "", target)
            indirect[target] = 1
          } else {
            print target
          }
        } else if (word[i] == "read") {
          for (j = i + 1; j <= count; j++) {
            if (word[j] == "-a") { print word[j + 1]; j++; continue }
            if (word[j] ~ /^-[dinNptu]$/) { j++; continue }
            if (word[j] ~ /^-/) continue
            if (word[j] ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print word[j]
            else break
          }
        } else if (word[i] == "for" && word[i + 2] == "in") {
          print word[i + 1]
          list = ""
          for (j = i + 3; j <= count && word[j] != "do"; j++) list = list " " word[j]
          loop[word[i + 1]] = loop[word[i + 1]] list
        } else if (word[i] ~ /^(local|declare|typeset|readonly|export)$/) {
          for (j = i + 1; j <= count; j++) {
            if (word[j] ~ /^[-+]/) continue
            target = word[j]
            sub(/=.*/, "", target)
            if (target ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print target
            else break
          }
        }
      }
    }
    END {
      for (target in indirect) {
        count = split(loop[target], word, " ")
        for (k = 1; k <= count; k++) print word[k]
      }
    }
  ' "$1"
}

# The deploy token left to the secret store, as on an agent whose
# environment does not export it: the hook then fetches it, and says so,
# so a walk that refutes the fetch fails if a check comes after it.
token_left_to_secret_store() {
  unset FJALL_API_KEY
  stub buildkite-agent "secret get FJALL_API_KEY : echo 'fjall_dk_fetched'"
}

# A plan answers one run of the hook, so a test that runs it again past its
# input guards puts the plans back first.
restub_agent_tools() {
  unstub node || true
  unstub npm || true
  unstub fjall || true
  stub_agent_tools
}

setup() {
  load "$BATS_PLUGIN_PATH/load.bash"

  # The hook fetches FJALL_API_KEY from Buildkite secrets only when the
  # environment lacks it; pre-set it so the default path never calls
  # `buildkite-agent secret get`. The secret-fetch tests unset it, and so do
  # the walks that refute a fetch (token_left_to_secret_store).
  export FJALL_API_KEY="fjall_dk_bats"

  # The hook bootstraps Node only when the agent's node is below node_floor;
  # report a compatible node so the default path skips the curl/verify/extract
  # bootstrap. The Node-bootstrap tests drain-and-replace this with a
  # below-floor stub.
  #
  # The version reported is the one the hook itself installs, which the
  # ci-plugin parity test proves clears node_floor — so "compatible" here is a
  # fact about the hook rather than a second literal to keep in step with it.
  # Plain assignments, deliberately: `export X="$(cmd)"` and `local X="$(cmd)"`
  # take the BUILTIN's exit status, so the reader's refusal would be swallowed
  # and setup would carry on with an empty pin. setup() and the test body share
  # a shell, so there is nothing to export for.
  HOOK_NODE_VERSION="$(read_hook_pin node_version)"
  HOOK_NODE_FLOOR="$(read_hook_pin node_floor)"

  # With no cli-version set, the hook defaults to fjall_cli_default_major
  # (design § 5.2 version tie), so the default install the npm stub answers
  # is `fjall@<that major>`, not bare `fjall`. Derived from the hook rather
  # than restated: a hardcoded major here silently rotted across two CLI
  # majors before this suite first ran in CI.
  FJALL_CLI_DEFAULT_MAJOR="$(read_hook_pin fjall_cli_default_major)"

  stub_agent_tools
}

teardown() {
  # Tolerant unstubs: early-exit tests (missing target, leading-dash rejection)
  # leave node/npm/fjall plans unconsumed, and the Node-bootstrap tests stub
  # uname/curl/sha256sum/tar that other tests never touch. The build summary
  # tests stub docker.
  unstub node || true
  unstub npm || true
  unstub fjall || true
  unstub buildkite-agent || true
  unstub uname || true
  unstub curl || true
  unstub sha256sum || true
  unstub tar || true
  unstub docker || true
}

@test "Deploys with minimal config via ci run" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  assert_line "installed fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  assert_line "cli received: ci run deploy my-app --non-interactive"
}

@test "Deploys with infra-only mode" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="infra-only"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --mode infra-only"
}

@test "Deploys with deploy-only mode" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_MODE="deploy-only"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --mode deploy-only"
}

@test "Deploys with verbose flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_VERBOSE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --verbose"
}

@test "Deploys with environment flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_ENVIRONMENT="staging"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --environment staging"
}

@test "Deploys with skip-build flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SKIP_BUILD="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --skip-build"
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
  assert_line "cli received: org deploy --non-interactive --verbose"
  refute_output --partial "ci run"
}

@test "organisation no-cascade routes with --no-cascade on the org leaf" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_NO_CASCADE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: org deploy --non-interactive --no-cascade"
}

@test "platform target routes to the noun-verb platform deploy" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="platform"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: platform deploy --non-interactive"
  refute_output --partial "ci run"
}

@test "account destroy routes to the noun-verb account destroy with --force" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="account"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_FORCE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: account destroy --non-interactive --force"
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

# The properties are plugin.yml's, less the ones a tier target takes: the two
# positionals, the flags a tier leaf honours, the two the hook consumes
# itself, and build-record, which is on by default and keeps nothing where no
# image is built. A property added to the manifest is therefore refused beside
# a tier target, or named here as one a tier honours. The refusal comes before
# the install, so no run consumes a plan.
@test "every application-only property is refused with a tier target, not dropped" {
  local type properties property env_name value
  for type in string boolean array; do
    properties="$(properties_of_type "${type}")"
    for property in ${properties}; do
      case "${property}" in
        command | target | force | verbose | no-cascade | cli-version | working-directory | build-record) continue ;;
      esac
      env_name="$(property_env "${property}")"
      case "${type}" in
        boolean) value="true" ;;
        array)
          env_name="${env_name}_0"
          value="item"
          ;;
        # A value `mode` does not read as its default.
        *) value="infra-only" ;;
      esac

      export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
      export "${env_name}=${value}"
      run "$PWD/hooks/command"
      unset "${env_name}"

      assert_failure
      assert_output --partial "not valid with tier target 'organisation': ${property}."
      refute_output --partial "Installing fjall"
    done
  done
}

@test "build is application-only: a tier build target is rejected" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="build"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "application-only"
}

# A refusal names the rule, never the value it refused.
@test "a command a tier target does not take is refused without repeating it" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="deplyo"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="platform"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "tier target 'platform' supports the commands deploy and destroy only"
  refute_output --partial "deplyo"
  refute_output --partial "cli received:"
}

@test "Deploys with region and image-tag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REGION="eu-west-1"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_IMAGE_TAG="abc123"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --region eu-west-1 --image-tag abc123"
}

@test "Deploys with plan and approval flags" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_PLAN="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REQUIRE_APPROVAL="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_APPROVAL_TOKEN="tok-1"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --plan --require-approval --approval-token tok-1"
}

@test "Deploys with auto-approve past the approval gate" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REQUIRE_APPROVAL="true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_AUTO_APPROVE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --require-approval --auto-approve"
}

@test "Deploys with indexed build-args and build-secrets arrays" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0="A=1"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_1="B=2"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_SECRETS_0="id=x,ssm=/p"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --build-arg A=1 --build-arg B=2 --build-secret id=x,ssm=/p"
}

@test "Deploys with specific service via --service" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SERVICE="api"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run deploy my-app --service api --non-interactive"
}

@test "Destroys with force flag" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_FORCE="true"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run destroy my-app --non-interactive --force"
}

@test "Build command routes through ci run" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="build"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: ci run build my-app --non-interactive"
  refute_output --partial "--skip-confirmation"
}

@test "Installs pinned CLI version" {
  # setup()'s npm plan is unconsumed at this point, so unstub reports failure
  unstub npm || true
  stub npm "install -g --ignore-scripts fjall@1.0.0 : echo 'installed fjall@1.0.0'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="1.0.0"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "installed fjall@1.0.0"
}

@test "cli-version latest installs the package with no version" {
  unstub npm || true
  stub npm "install -g --ignore-scripts fjall : echo 'installed fjall, unpinned'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="latest"

  run "$PWD/hooks/command"

  assert_success
  assert_line "installed fjall, unpinned"
}

# The CLI reads fjall-config.json from where it runs, so the stub reports
# where that was.
@test "runs the CLI in the working directory" {
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    ":: echo \"cli ran in \$PWD\""
  mkdir -p "$BATS_TEST_TMPDIR/app"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_WORKING_DIRECTORY="$BATS_TEST_TMPDIR/app"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli ran in $BATS_TEST_TMPDIR/app"
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
  # major (7) that differs from the hook's fjall_cli_default_major so the
  # assertion proves the resolver's output drove the install, not the fallback.
  # The resolver also says, on stderr (its stdout is the spec), which
  # credentials reached it: the job token and AWS keys the step carries must
  # not.
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    ":: echo 'fjall@7'; $(credential_report resolver) >&2"
  export BUILDKITE_AGENT_ACCESS_TOKEN="job-token"
  export AWS_ACCESS_KEY_ID="AKIAHOOKTEST"
  export AWS_SECRET_ACCESS_KEY="secret-key"
  export AWS_SESSION_TOKEN="session-token"

  # setup()'s npm plan expects the baked default major; the resolver echoed 7,
  # so drain and re-stub for the resolved spec.
  unstub npm || true
  stub npm "install -g --ignore-scripts fjall@7 : echo 'installed fjall@7'"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_success
  assert_output --partial "installed fjall@7"
  refute_output --partial "resolver holds"
  assert_line "cli received: ci run deploy my-app --non-interactive"
}

# The resolver fails loud (non-zero exit) when it cannot determine a single
# engine major — no pin, an unparseable range, or pins conflicting across a
# major. The hook MUST abort the step, never guessing a major, and never reach
# npm or fjall. setup()'s npm plan is left in place: if the hook wrongly
# proceeded past the failed resolver it would call npm with an empty spec, which
# does not match setup()'s plan, turning the test red rather than passing.
@test "cli-version auto fails the step when the engine resolver cannot resolve a major" {
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    ":: exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Failed to resolve the fjall engine"
  refute_output --partial "ci run"
}

# The other half of the same contract, and the one an exit-status check cannot
# see: the resolver exits 0 and prints NOTHING. Its own entry guard returns
# false when it cannot realpath the entry module, and a script that decides it
# was not the entry exits 0 having printed no spec — so a success status is not
# an answer. Without the emptiness refusal the hook reaches
# `npm install -g ""`, which is an install nobody chose on the one lane whose
# purpose is choosing. setup()'s npm plan is left in place deliberately: if the
# hook proceeded, npm would be called off-plan and the test would red anyway,
# so this asserts the refusal rather than merely the absence of the install.
@test "cli-version auto fails the step when the engine resolver names no engine" {
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    ":: exit 0"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "exited 0 without naming an engine"
  refute_output --partial "ci run"
}

@test "Fails when target is missing" {
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
  assert_line "cli received: ci run destroy my-app --non-interactive --mode infra-only"
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
  assert_line "cli received: ci run deploy my-app --service api --non-interactive --mode deploy-only --environment production --skip-build --verbose"
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
    "annotate --style warning * : echo \"annotation: \$4\""

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_PLAN="true"

  run "$PWD/hooks/command"

  # unstub asserts all four buildkite-agent calls happened with those args
  unstub buildkite-agent
  assert_failure 2
  assert_output --partial "annotation: Fjall plan for **my-app** has changes pending approval. Re-run with the"
}

# Exit 2 also ends a run the approval gate refused, or one cancelled before it
# completed, which can have applied part of its change. Neither prints an
# approval token, so neither is told to re-run with one.
@test "exit 2 without an approval token is not reported as a plan to re-run" {
  fjall --version >/dev/null
  fjall drain-remaining-plan-line >/dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run destroy my-app --non-interactive : echo 'Destruction of my-app was cancelled before completion.'; exit 2"
  stub buildkite-agent \
    "meta-data set fjall-deploy:result plan-pending : true" \
    "meta-data set fjall-deploy:duration * : true" \
    "annotate --style warning * : echo \"annotation: \$4\""

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  # unstub asserts the hook set no approval-token meta-data
  unstub buildkite-agent
  assert_failure 2
  assert_output --partial "annotation: Fjall stopped **my-app** before it completed"
  refute_output --partial "Re-run with the"
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
  assert_line "cli received: ci run deploy my-app --non-interactive --target production-use1"
}

# L3 (design § 5.2) — the hook fetches FJALL_API_KEY from Buildkite's secret
# store when the environment lacks it, so a pipeline need only store the secret.
# The fetched token reaches the CLI and nothing before it, and is never printed.
@test "fetches FJALL_API_KEY from Buildkite secrets when the environment lacks it" {
  unset FJALL_API_KEY
  export EXPECTED_DEPLOY_TOKEN="fjall_dk_fetched"
  stub buildkite-agent \
    "secret get FJALL_API_KEY : echo 'fjall_dk_fetched'" \
    "meta-data set fjall-deploy:result success : true" \
    "meta-data set fjall-deploy:duration * : true"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "Fetching FJALL_API_KEY from Buildkite secrets"
  assert_line "cli received: ci run deploy my-app --non-interactive"
  assert_line "cli holds the deploy token"
  refute_output --partial "npm holds"
  refute_output --partial "fjall --version holds"
  refute_output --partial "fjall_dk_fetched"
}

# A token the environment supplies is taken out of it too: the install, its
# dependency tree's scripts included, never sees the deploy token, the job
# token that could fetch it again, or the step's AWS keys. The CLI gets the
# deploy token.
@test "the deploy token reaches the CLI and nothing that runs before it" {
  export EXPECTED_DEPLOY_TOKEN="${FJALL_API_KEY}"
  export BUILDKITE_AGENT_ACCESS_TOKEN="job-token"
  export AWS_ACCESS_KEY_ID="AKIAHOOKTEST"
  export AWS_SECRET_ACCESS_KEY="secret-key"
  export AWS_SESSION_TOKEN="session-token"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  assert_line "installed fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  refute_output --partial "npm holds"
  refute_output --partial "fjall --version holds"
  assert_line "cli holds the deploy token"
  assert_line "cli holds BUILDKITE_AGENT_ACCESS_TOKEN"
  assert_line "cli holds AWS_ACCESS_KEY_ID"
  assert_line "cli holds AWS_SECRET_ACCESS_KEY"
  assert_line "cli holds AWS_SESSION_TOKEN"
  refute_output --partial "${EXPECTED_DEPLOY_TOKEN}"
}

# The token reaches one process the hook runs, the CLI. An
# environment-supplied one is out of the environment before the first
# property check starts a process, and the hook holds it under no second
# name: a job's own DEPLOY_TOKEN reaches the CLI as the job set it. Every
# command the hook runs on this path says whether it holds the token.
@test "no process the hook runs but the CLI holds an environment-supplied token" {
  export EXPECTED_DEPLOY_TOKEN="${FJALL_API_KEY}"
  export DEPLOY_TOKEN="the job's own value"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  shim_reporting_the_token tr sort mktemp date tee grep rm node npm fjall

  PATH="${TOKEN_SHIMS}:${PATH}" run "$PWD/hooks/command"

  assert_success
  assert_line "fjall ci holds the deploy token"
  refute_line --regexp '^(tr|sort|mktemp|date|tee|grep|rm|node|npm) .*holds the deploy token$'
  refute_line "fjall --version holds the deploy token"
  run grep -Fx "DEPLOY_TOKEN=the job's own value" "$BATS_TEST_TMPDIR/cli-env"
  assert_success
}

# A token fetched from the secret store is never in the environment either,
# even where the shell exports whatever it sets (allexport, here from
# BASH_ENV), and the job's own DEPLOY_TOKEN still reaches the CLI as the job
# set it.
@test "no process the hook runs but the CLI holds a fetched token, under allexport too" {
  unset FJALL_API_KEY
  export EXPECTED_DEPLOY_TOKEN="fjall_dk_fetched"
  export DEPLOY_TOKEN="the job's own value"
  stub buildkite-agent \
    "secret get FJALL_API_KEY : echo 'fjall_dk_fetched'" \
    "meta-data set fjall-deploy:result success : true" \
    "meta-data set fjall-deploy:duration * : true"
  printf 'set -a\n' > "$BATS_TEST_TMPDIR/allexport"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  shim_reporting_the_token tr sort mktemp date tee grep rm node npm fjall buildkite-agent

  BASH_ENV="$BATS_TEST_TMPDIR/allexport" PATH="${TOKEN_SHIMS}:${PATH}" run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_line "cli holds the deploy token"
  assert_line "fjall ci holds the deploy token"
  refute_line --regexp '^(tr|sort|mktemp|date|tee|grep|rm|node|npm|buildkite-agent) .*holds the deploy token$'
  refute_line "fjall --version holds the deploy token"
  run grep -Fx "DEPLOY_TOKEN=the job's own value" "$BATS_TEST_TMPDIR/cli-env"
  assert_success
}

# An xtrace the shell inherits, from BASH_ENV or from SHELLOPTS in the
# environment, would print each command the hook runs into the job log, the
# token's handover to the CLI among them. The hook turns it off before it
# reads the token. The tools here are POSIX sh scripts, which read neither,
# so the hook is the only shell that could trace the token.
@test "an inherited xtrace never prints the deploy token" {
  local tools="$BATS_TEST_TMPDIR/sh-tools" setting
  mkdir -p "$tools"
  printf '#!/bin/sh\necho "v%s"\n' "${HOOK_NODE_VERSION}" > "$tools/node"
  printf '#!/bin/sh\necho "installed $*"\n' > "$tools/npm"
  printf '%s\n' '#!/bin/sh' \
    'if [ "$1" = --version ]; then echo "fjall/0.88.3"; exit 0; fi' \
    'echo "cli received: $*"' \
    'if [ "${FJALL_API_KEY-}" = "${EXPECTED_DEPLOY_TOKEN}" ]; then echo "cli holds the deploy token"; fi' > "$tools/fjall"
  chmod +x "$tools/node" "$tools/npm" "$tools/fjall"
  printf 'set -x\n' > "$BATS_TEST_TMPDIR/xtrace"
  export EXPECTED_DEPLOY_TOKEN="${FJALL_API_KEY}"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  for setting in "BASH_ENV=$BATS_TEST_TMPDIR/xtrace" "SHELLOPTS=xtrace"; do
    PATH="${tools}:${PATH}" run env "${setting}" "$PWD/hooks/command"

    assert_success
    assert_line "+ set -euo pipefail"
    assert_line "cli received: ci run deploy my-app --non-interactive"
    assert_line "cli holds the deploy token"
    refute_output --partial "${EXPECTED_DEPLOY_TOKEN}"
  done
}

# The hook keeps an environment-supplied token from everything it runs but
# the CLI, and leaves it in the environment it hands the hooks after it, so
# they see it as the hooks before it did.
@test "an environment-supplied token is left for the hooks after a run that succeeds" {
  export EXPECTED_DEPLOY_TOKEN="${FJALL_API_KEY}"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run_hook_through_agent_wrapper

  assert_success
  assert_line "cli holds the deploy token"
  refute_output --partial "npm holds"
  run grep -Fx "FJALL_API_KEY=${EXPECTED_DEPLOY_TOKEN}" "$BATS_TEST_TMPDIR/env-after"
  assert_success
}

# A token fetched from the secret store reaches the CLI alone: it is in no
# line of the environment the hook leaves, so no hook after it sees it.
@test "a fetched token is never left for the hooks after the run" {
  unset FJALL_API_KEY
  export EXPECTED_DEPLOY_TOKEN="fjall_dk_fetched"
  stub buildkite-agent \
    "secret get FJALL_API_KEY : echo 'fjall_dk_fetched'" \
    "meta-data set fjall-deploy:result success : true" \
    "meta-data set fjall-deploy:duration * : true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run_hook_through_agent_wrapper

  unstub buildkite-agent
  assert_success
  assert_line "cli holds the deploy token"
  run grep -v '^EXPECTED_DEPLOY_TOKEN=' "$BATS_TEST_TMPDIR/env-after"
  assert_success
  refute_output --partial "fjall_dk_fetched"
}

# The agent carries what a hook that exits 0 leaves into the rest of the
# job: its environment, and its working directory, which the later hooks
# and the artifact upload start in. The hook leaves both as the job had them,
# on the path that changes the most: a Node bootstrapped onto PATH, a
# working-directory to move into, and job variables that share their names
# with the hook's own.
@test "a run that succeeds leaves the job's environment and working directory as it found them" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub_node_bootstrap x86_64 x64
  export REGION="eu-west-1" ENVIRONMENT="production" NODE_VERSION="22.0.0" DEPLOY_TOKEN="the job's own value"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_WORKING_DIRECTORY="tests"

  run_hook_through_agent_wrapper

  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_line "bootstrapped npm ran: install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  assert_line "cli received: ci run deploy my-app --non-interactive"
  run diff <(grep -v -e '^_=' "$BATS_TEST_TMPDIR/env-before") \
    <(grep -v -e '^_=' -e '^BUILDKITE_HOOK_EXIT_STATUS=' -e '^BUILDKITE_HOOK_WORKING_DIR=' "$BATS_TEST_TMPDIR/env-after")
  assert_success
  run grep -Fx "BUILDKITE_HOOK_WORKING_DIR=$PWD" "$BATS_TEST_TMPDIR/env-after"
  assert_success
}

# The hook's own variables are lower-case, so a variable the job exports
# reaches the CLI, and with it the job's infrastructure.ts and image builds,
# as the job set it, whatever name the hook once gave one of its own. A
# property the plugin is given still reaches the CLI as its flag. These three
# runs between them set every variable the hook has: the Node bootstrap's,
# the `auto` install's, and the tier path's, where an upper-case
# INCOMPATIBLE, made an array, was dropped.
@test "a job variable reaches the CLI as the job set it, under any name the hook once used, on the bootstrap path" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub_node_bootstrap x86_64 x64
  export_former_hook_names
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_REGION="eu-west-1"

  run "$PWD/hooks/command"

  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive --region eu-west-1"
  assert_cli_was_given_the_job_values
}

@test "a job variable reaches the CLI as the job set it, under any name the hook once used, on the auto install path" {
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    ":: echo 'fjall@7'"
  unstub npm || true
  stub npm "install -g --ignore-scripts fjall@7 : echo 'installed fjall@7'"
  export_former_hook_names
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_CLI_VERSION="auto"

  run "$PWD/hooks/command"

  assert_success
  assert_line "installed fjall@7"
  assert_line "cli received: ci run deploy my-app --non-interactive"
  assert_cli_was_given_the_job_values
}

@test "a job variable reaches the CLI as the job set it, under any name the hook once used, on a tier target" {
  export_former_hook_names
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"

  run "$PWD/hooks/command"

  assert_success
  assert_line "cli received: org deploy --non-interactive"
  assert_cli_was_given_the_job_values
}

# The class, for a variable added later: the hook sets no upper-case name
# but PATH, which hands the CLI a bootstrapped Node, and FJALL_API_KEY, the
# token's own name, in any form variables_set_in reads, which covers every
# form the hook uses. A name set in a form it does not read goes unseen, so
# a variable the hook sets in a new form needs the helper taught that form.
@test "the hook sets no upper-case variable but PATH and FJALL_API_KEY" {
  local names
  names="$(variables_set_in "$PWD/hooks/command" | sort -u)"
  [ -n "${names}" ]
  run grep -E '^[A-Z]' <<< "${names}"
  assert_output "FJALL_API_KEY
PATH"
}

# A secret the store cannot answer stops the step before anything is
# downloaded or installed, rather than leaving the CLI to fall back on
# whatever credentials a persistent agent has stored.
@test "a failed secret fetch stops the step before anything is installed" {
  unset FJALL_API_KEY
  stub buildkite-agent "secret get FJALL_API_KEY : echo 'secret not found' >&2; exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  refute_output --partial "Installing fjall"
  refute_output --partial "cli received:"
}

# L3 (design § 5.2) — when the agent's node is below node_floor the hook
# bootstraps a pinned build, verified against its SHA-256 before extraction,
# and prepends it to PATH: the install then runs the bootstrapped npm, not the
# agent's.
@test "bootstraps a pinned, SHA-verified Node when the agent node is too old" {
  # Drain setup()'s compatible-node plan, then replace with an old node so the
  # bootstrap path fires (mirrors the fjall drain-then-replace idiom above).
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub_node_bootstrap x86_64 x64

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  # The pinned build was fetched, verified, and extracted before the CLI ran.
  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_output --partial "Bootstrapping Node ${HOOK_NODE_VERSION}"
  assert_line "sha256sum checked the pinned x64 digest"
  assert_line "bootstrapped npm ran: install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  refute_line "installed fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  assert_line "cli received: ci run deploy my-app --non-interactive"
}

# The arm64 twin: its own tarball and its own digest.
@test "bootstraps the arm64 build, against the arm64 digest, on an aarch64 agent" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub_node_bootstrap aarch64 arm64

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_line "sha256sum checked the pinned arm64 digest"
  assert_line "bootstrapped npm ran: install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR}"
}

# An architecture with no pinned build is refused, before any download.
@test "a below-floor agent on an architecture with no pinned build is refused before any download" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub uname "-s : echo 'Linux'" "-m : echo 's390x'" "-m : echo 's390x'"
  stub curl ":: echo 'curl ran'; exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "unsupported architecture 's390x' for Node bootstrap"
  refute_output --partial "curl ran"
  refute_output --partial "Installing fjall"
}

# The floor is a full version, not a major. 22.3.0 is a Node 22 — it passed the
# hook's old `-lt 22` major test — and the published `fjall` package refuses it,
# so the agent must be bootstrapped rather than left to fail at `npm install`.
@test "bootstraps for a Node 22 agent below the full-version floor" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v22.3.0'"
  stub_node_bootstrap x86_64 x64

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub curl
  unstub sha256sum
  unstub tar
  assert_success
  assert_output --partial "Bootstrapping Node ${HOOK_NODE_VERSION}"
  assert_output --partial "agent node: 22.3.0"
  assert_line "bootstrapped npm ran: install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR}"
  assert_line "cli received: ci run deploy my-app --non-interactive"
}

# The other direction: an agent exactly AT the floor is compatible and is not
# sent through a 50 MB download. The curl plan is a tripwire — a gate that
# bootstraps here aborts on it rather than reaching the network.
@test "does not bootstrap when the agent node is exactly at the floor" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v${HOOK_NODE_FLOOR}'"
  stub curl ":: echo 'curl ran'; exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  assert_success
  refute_output --partial "Bootstrapping Node"
  assert_line "cli received: ci run deploy my-app --non-interactive"
}

# The pinned builds are Linux tarballs. A below-floor agent on any other OS is
# refused with the floor named, before anything is downloaded — `uname -m`
# reads arm64 on Apple Silicon too, so without the OS gate a macOS agent would
# be handed a Linux binary. The curl plan is a tripwire.
@test "a below-floor agent that is not Linux is refused before any download" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v22.3.0'"
  stub uname "-s : echo 'Darwin'"
  stub curl ":: echo 'curl ran'; exit 1"

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub uname
  assert_failure
  assert_output --partial "agent node 22.3.0 is below ${HOOK_NODE_FLOOR}"
  assert_output --partial "this agent runs Darwin"
  refute_output --partial "Bootstrapping Node"
  refute_output --partial "ci run"
}

# The derivation above is only worth having if it fails loudly. A pin this
# suite cannot find must stop the run: the silent alternative is an empty
# version stubbed as `v`, which the hook reads as below any floor, so every
# default-path test would take the bootstrap branch and the assertions that
# passed would be about a path nobody meant to exercise.
@test "a hook pin this suite cannot read fails rather than stubbing an empty version" {
  run read_hook_pin NOT_A_REAL_PIN
  assert_failure
  assert_output --partial "could not read NOT_A_REAL_PIN"
}

# The same for the manifest's property lists: a table test over a list this
# suite could not read would pass having run nothing.
@test "a property list this suite cannot read fails rather than passing over nothing" {
  run properties_of_type no-such-type
  assert_failure
  assert_output --partial "could not read any no-such-type property"
}

# The SHA-256 check is a gate, not a log line: a digest mismatch aborts under
# `set -e` before the tarball is extracted or the CLI runs.
@test "a Node tarball failing SHA-256 verification aborts before extraction" {
  node --version > /dev/null
  unstub node
  stub node "--version : echo 'v18.20.5'"
  stub uname "-s : echo 'Linux'" "-m : echo 'x86_64'"
  stub curl "-fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 --max-time 600 --retry 2 --retry-max-time 300 -o * * : true"
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
  assert_output --partial "Bootstrapping Node ${HOOK_NODE_VERSION}"
  refute_output --partial "EXTRACTED"
  refute_output --partial "ci run"
}

# Flag-shaped property values are rejected before fjall runs — a value beginning
# with '-' would be parsed by commander as a flag rather than a value. The
# properties are plugin.yml's strings, less the two the hook consumes itself
# and never passes to the CLI (`npm install -g "fjall@<cli-version>"` and
# `cd -- <working-directory>`), so a guard dropped from the hook, or a string
# property added without one, fails here.
@test "every string property that reaches the CLI's argv refuses a flag-shaped value" {
  local properties property env_name
  properties="$(properties_of_type string)"
  for property in ${properties}; do
    case "${property}" in
      cli-version | working-directory) continue ;;
    esac
    env_name="$(property_env "${property}")"

    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}=--oops"
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_failure
    assert_output --partial "'${property}' must not begin with '-'"
    refute_output --partial "--oops"
    refute_output --partial "Installing fjall"
  done
}

# The guard also fires per item for the array properties, and BEFORE any
# side-effecting phase — no install stubs here, so reaching the token fetch
# or Node bootstrap fails the test on their absence.
@test "a flag-shaped build-arg is rejected per item" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0="--sneaky=1"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'build-args' must not begin with '-'"
  refute_output --partial "sneaky"
  refute_output --partial "Installing fjall"
}

@test "a flag-shaped build-secret is rejected per item" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_SECRETS_0="--sneaky=id=x"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'build-secrets' must not begin with '-'"
  refute_output --partial "sneaky"
  refute_output --partial "Installing fjall"
}

# A single `-` reads as no list, but a `-` item inside one is a flag-shaped
# value like any other: an optional item written `- "${EXTRA:--}"` is
# refused, not dropped or handed to the CLI as `--build-arg -`.
@test "a - item inside a list property is refused as flag-shaped" {
  local property env_name
  for property in build-args build-secrets; do
    env_name="$(property_env "${property}")"
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}_0=A=1" "${env_name}_1=-"
    run "$PWD/hooks/command"
    unset "${env_name}_0" "${env_name}_1"

    assert_failure
    assert_output --partial "'${property}' must not begin with '-'. The value given is not repeated here."
    refute_output --partial "Installing fjall"
  done
}

# A boolean property is exactly true or false: what the agent hands the hook
# for a YAML boolean. Read as anything but `true`, these spellings once
# reached the false arm, which for plan, require-approval and no-cascade is
# the one that changes more. Each is refused before anything is fetched or
# installed, and the value is not repeated. The properties are plugin.yml's
# booleans, so one added to the manifest joins the test.
@test "every boolean property refuses a value that is not true or false, before anything runs" {
  local properties property env_name spelling
  token_left_to_secret_store
  properties="$(properties_of_type boolean)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    for spelling in True TRUE yes on 1 False no off 0 " true" "true " "false
"; do
      export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
      export "${env_name}=${spelling}"
      run "$PWD/hooks/command"
      unset "${env_name}"

      assert_failure
      assert_output --partial "'${property}' must be true or false. The value given is not repeated here."
      refute_output --partial "Installing fjall"
      refute_output --partial "Fetching FJALL_API_KEY"
    done
  done
}

# An empty value is something the pipeline wrote, most often an interpolation
# whose variable is unset (`plan: "${PLAN_ONLY}"`): the agent sets no variable
# for a property left out. Read as false it ran the arm that changes more, so
# it is refused, before anything is fetched or installed.
@test "every boolean property refuses an empty value, before anything runs" {
  local properties property env_name
  token_left_to_secret_store
  properties="$(properties_of_type boolean)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}="
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_failure
    assert_output --partial "'${property}' is empty: give true or false, or leave it out to take its default."
    refute_output --partial "Installing fjall"
    refute_output --partial "Fetching FJALL_API_KEY"
  done
}

# An empty string property was read as the property left out, so
# `image-tag: "${ROLLBACK_TAG}"` with the variable unset built and deployed
# rather than rolling back. Every one is refused, before anything is fetched
# or installed, and an empty target as a missing one. The properties are
# plugin.yml's strings.
@test "every string property refuses an empty value, before anything runs" {
  local properties property env_name
  token_left_to_secret_store
  properties="$(properties_of_type string)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}="
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_failure
    if [ "${property}" = target ]; then
      assert_output --partial "Error: 'target' is required"
    else
      assert_output --partial "'${property}' is empty: give it a value, or leave it out."
    fi
    refute_output --partial "Installing fjall"
    refute_output --partial "Fetching FJALL_API_KEY"
  done
}

# The other half: `false` reads as false, as a property left out does for
# every one but build-record, which never reaches the CLI. So every boolean
# property set to it deploys with none of the flags. A plan
# answers one run, so each run puts them back first.
@test "every boolean property reads false as false" {
  local properties property env_name
  properties="$(properties_of_type boolean)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    restub_agent_tools
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}=false"
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_success
    assert_line "cli received: ci run deploy my-app --non-interactive"
  done
}

# `-` is the spelling of "none" for a property with no value of its own, as
# in the GitHub Action: `image-tag: "${ROLLBACK_TAG:--}"` writes it when the
# variable is unset or empty, and the property reads as left out, on the app
# path and beside a tier target alike. A list property's single `-` reads the
# same way. The properties are plugin.yml's.
@test "every property with no value of its own reads - as left out" {
  local properties property env_name
  properties="$(properties_by_own_value without)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    restub_agent_tools
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}=-"
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_success
    assert_line "cli received: ci run deploy my-app --non-interactive"
  done

  restub_agent_tools
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"
  for property in ${properties}; do
    export "$(property_env "${property}")=-"
  done
  run "$PWD/hooks/command"
  assert_success
  assert_line "cli received: org deploy --non-interactive"
}

# The other half: `-` means none only for a property with no value of its
# own. Every other property refuses it, before anything is fetched or
# installed: one with a default, which would otherwise take it as a value
# (cli-version as a version for npm, working-directory as cd's previous
# directory), and target, which has no none. The properties are plugin.yml's.
@test "every property with a value of its own refuses -, before anything runs" {
  local properties property env_name
  token_left_to_secret_store
  properties="$(properties_by_own_value with)"
  for property in ${properties}; do
    env_name="$(property_env "${property}")"
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
    export "${env_name}=-"
    run "$PWD/hooks/command"
    unset "${env_name}"

    assert_failure
    assert_output --partial "Error: '${property}' "
    refute_output --partial "Installing fjall"
    refute_output --partial "Fetching FJALL_API_KEY"
  done
}

# A list property given as a single value arrives under the bare name, which
# the composition loops never read: the items were dropped without a word.
# An empty one (`build-args: "${EXTRA_ARGS}"`, the variable unset) is
# refused as empty, and says nothing of a value withheld, as there is none.
@test "a single value where a list property belongs is refused" {
  local property env_name
  for property in build-args build-secrets; do
    env_name="$(property_env "${property}")"
    export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

    export "${env_name}=A=1"
    run "$PWD/hooks/command"
    assert_failure
    assert_output --partial "'${property}' must be a list of strings, not a single value. The value given is not repeated here."
    refute_output --partial "A=1"
    refute_output --partial "Installing fjall"

    export "${env_name}="
    run "$PWD/hooks/command"
    unset "${env_name}"
    assert_failure
    assert_output --partial "'${property}' is empty: give it a list of strings, or leave it out."
    refute_output --partial "not repeated"
    refute_output --partial "Installing fjall"
  done
}

# An empty item ended the composition loop, dropping every item after it; a
# map, or a list of maps, arrives under names no loop read.
@test "a list property with an empty item, or a map in it, is refused" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0="A=1"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_1=""
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_2="C=3"
  run "$PWD/hooks/command"
  assert_failure
  assert_output --partial "'build-args' item 2 is empty."
  refute_output --partial "Installing fjall"
  unset BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0 BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_1 BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_2

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_SECRETS_GIT_SHA="abc"
  run "$PWD/hooks/command"
  assert_failure
  assert_output --partial "'build-secrets' must be a list of strings."
  unset BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_SECRETS_GIT_SHA

  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_ARGS_0_KEY="A"
  run "$PWD/hooks/command"
  assert_failure
  assert_output --partial "'build-args' must be a list of strings."
  refute_output --partial "Installing fjall"
}

# A deploy build skips itself when a newer deploy build carries its commit,
# and a build its creator marked holds while the deploy before it is red.
# supersede-check.mjs makes both decisions, under its own suite
# (supersedeCheck.test.ts in @fjall/cli). Node is stubbed here, so these tests
# pin only what the hook does around the decision. That is what it reads, what
# it hands the module and what it records.
SUPERSEDE_NEWER_COMMIT="0123456789abcdef0123456789abcdef01234567"
SUPERSEDE_JOB_ID="0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b"
SUPERSEDE_STEP_ID="0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a60"
SUPERSEDE_BUILD_ID="0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a70"

supersede_config() {
  unset BUILDKITE_PARALLEL_JOB_COUNT
  export BUILDKITE_JOB_ID="${SUPERSEDE_JOB_ID}"
  export BUILDKITE_STEP_ID="${SUPERSEDE_STEP_ID}"
  export BUILDKITE_BUILD_ID="${SUPERSEDE_BUILD_ID}"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_AFTER="verify-ci-green"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_TOKEN_SECRET="CI_GREEN_API_TOKEN"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_0="prisma/migrations/"
  export BUILDKITE_COMMIT="fedcba9876543210fedcba9876543210fedcba98"
  export BUILDKITE_BUILD_URL="https://buildkite.com/acme/webapp-deploy/builds/529"
}

# Drains setup()'s one-line node plan and replaces it with the version check
# and one start of the module, whose plan line runs $1. $2 is the marker word
# the hook must hand the module, marked unless given.
stub_supersede_module() {
  node --version > /dev/null
  unstub node
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    "* ${2:-marked} verify-ci-green prisma/migrations/ : $1"
}

# The token secret's read, which every test that reaches it answers. Named
# apart from the answer, so no line spells a token name beside a value.
SECRET_GET="secret get CI_GREEN_API_TOKEN"

# The hook's read of its own build's marker, which comes after the token's.
MARKED_READ="meta-data get fjall-deploy:supersedable --default false : echo true"
UNMARKED_READ="meta-data get fjall-deploy:supersedable --default false : echo false"
MARKER_READ_FAILS="meta-data get fjall-deploy:supersedable --default false : exit 1"

# The marker every deploy with supersede set writes just before the CLI runs,
# and the job it writes after the result once the CLI has exited.
STARTED_SET="meta-data set fjall-deploy:started ${SUPERSEDE_JOB_ID} : true"
RESULT_JOB_SET="meta-data set fjall-deploy:result-job ${SUPERSEDE_JOB_ID} : true"

# The claim every step with supersede set makes first, the build's id and the
# step's, which a retry of the step that holds it reads back as its own.
STEP_CLAIM="${SUPERSEDE_BUILD_ID}/${SUPERSEDE_STEP_ID}"
STEP_CLAIM_GET="meta-data get fjall-deploy:supersede-step --default ${STEP_CLAIM} : echo '${STEP_CLAIM}'"
STEP_CLAIM_SET="meta-data set fjall-deploy:supersede-step ${STEP_CLAIM} : true"

@test "supersede absent: the hook reads no token and starts no check" {
  # The buildkite-agent plan is exactly the deploy's two writes, and node's is
  # only the version check, so a token read or a module start fails unstub.
  stub buildkite-agent \
    "meta-data set fjall-deploy:result success : true" \
    "meta-data set fjall-deploy:duration * : true"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  refute_output --partial "supersede:"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede on a rebuild deploys without reading the marker or the token" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config
  export BUILDKITE_REBUILT_FROM_BUILD_NUMBER="150"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_output --partial "supersede: deploying, a rebuild never skips or holds"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede skip records superseded first, then superseded-by and an annotation, and installs nothing" {
  stub_supersede_module "echo 'supersede: skipped for #530 at ${SUPERSEDE_NEWER_COMMIT}'; exit 10"
  # bats-mock consumes a plan in order, so unstub pins the write order too.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:result superseded : echo 'RESULT_SET'" \
    "meta-data set fjall-deploy:superseded-by 530 : echo 'SUPERSEDED_BY_SET'" \
    "annotate --style warning --context fjall-deploy-superseded * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "supersede: skipped for #530 at ${SUPERSEDE_NEWER_COMMIT}"
  assert_output --partial "RESULT_SET"
  assert_output --partial "SUPERSEDED_BY_SET"
  assert_output --partial "ANNOTATION:This build deployed nothing. Build [#530](https://buildkite.com/acme/webapp-deploy/builds/530), at \`012345678\`"
  refute_output --partial "Installing fjall"
  refute_output --partial "ci run"
}

@test "supersede skip whose superseded result cannot be written holds, since its hold was never judged" {
  stub_supersede_module "echo 'supersede: skipped for #530 at ${SUPERSEDE_NEWER_COMMIT}'; exit 10"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:result superseded : exit 1" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the result superseded could not be recorded"
  refute_output --partial "Installing fjall"
  refute_output --partial "ci run"
}

@test "supersede skip still exits 0 when superseded-by and the annotation fail" {
  stub_supersede_module "echo 'supersede: skipped for #530 at ${SUPERSEDE_NEWER_COMMIT}'; exit 10"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:result superseded : true" \
    "meta-data set fjall-deploy:superseded-by 530 : exit 1" \
    "annotate --style warning --context fjall-deploy-superseded * : exit 1"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  refute_output --partial "Installing fjall"
  refute_output --partial "ci run"
}

@test "supersede starts the module without FJALL_API_KEY, with the token on stdin" {
  stub_supersede_module "if [ -n \"\${FJALL_API_KEY+set}\" ]; then echo 'KEY_PRESENT' >&2; else echo 'KEY_ABSENT' >&2; fi; IFS= read -r token || true; if [ \"\$token\" = 'bkua_bats' ]; then echo 'TOKEN_ON_STDIN' >&2; fi; echo \"MODULE:\${1##*/}\" >&2; echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "KEY_ABSENT"
  refute_output --partial "KEY_PRESENT"
  assert_output --partial "TOKEN_ON_STDIN"
  assert_output --partial "MODULE:supersede-check.mjs"
  assert_output --partial "supersede: deploying, no newer main build can still deploy or has deployed"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede hands an unmarked build's check the word unmarked" {
  stub_supersede_module "echo 'supersede: deploying, this build carries no fjall-deploy:supersedable marker'" unmarked
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${UNMARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "supersede: deploying, this build carries no fjall-deploy:supersedable marker"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede held by a red build records held-by and an error annotation, records no result and installs nothing" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is failure'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : echo 'HELD_BY_SET'" \
    "annotate --style error --context fjall-deploy-held * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: held by #528, whose deploy result is failure"
  assert_output --partial "HELD_BY_SET"
  assert_output --partial "ANNOTATION:This build deployed nothing. Build [#528](https://buildkite.com/acme/webapp-deploy/builds/528), the deploy before it, did not succeed"
  refute_output --partial "Installing fjall"
  refute_output --partial "ci run"
}

@test "supersede held by a build whose result is not a word reads the ? the check prints" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is ?'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : echo 'HELD_BY_SET'" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "HELD_BY_SET"
  refute_output --partial "Installing fjall"
}

@test "supersede held by a build whose deploy started and recorded no result says so in its annotation" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is unrecorded'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : echo 'HELD_BY_SET'" \
    "annotate --style error --context fjall-deploy-held * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "HELD_BY_SET"
  assert_output --partial "ANNOTATION:This build deployed nothing. Build [#528](https://buildkite.com/acme/webapp-deploy/builds/528), the deploy before it, started a deploy and ended before recording its result, so this one would deploy over it."
  refute_output --partial "Installing fjall"
}

@test "supersede held by a build whose deploy has not ended names it and says to wait" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is unfinished'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : echo 'HELD_BY_SET'" \
    "annotate --style error --context fjall-deploy-held * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "HELD_BY_SET"
  assert_output --partial "ANNOTATION:This build deployed nothing. Build [#528](https://buildkite.com/acme/webapp-deploy/builds/528), the deploy before it, started a deploy that has not ended, so this one would deploy over it. Wait for that deploy to end, then retry this one."
  refute_output --partial "Installing fjall"
}

@test "supersede records the job in fjall-deploy:started after the install and before the CLI runs, and in fjall-deploy:result-job after the result" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:started ${SUPERSEDE_JOB_ID} : echo 'STARTED_SET'" \
    "meta-data set fjall-deploy:result success : echo 'RESULT_SET'" \
    "meta-data set fjall-deploy:result-job ${SUPERSEDE_JOB_ID} : echo 'RESULT_JOB_SET'" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  [[ "${output}" == *"installed fjall@"*"STARTED_SET"*"cli received: ci run deploy my-app"*"RESULT_SET"*"RESULT_JOB_SET"* ]]
}

@test "supersede runs no CLI when fjall-deploy:started cannot be recorded" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  # The plan ends at the failed write, so a result write after it fails unstub.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET%% : *} : exit 1"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "Error: this build deployed nothing. The fjall-deploy:started marker could not be recorded"
  refute_output --partial "cli received:"
}

@test "supersede runs no CLI when the job has no id to record" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  # The plan ends at the marker read, so any started or result write fails unstub.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}"
  supersede_config
  export BUILDKITE_JOB_ID=""

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "Error: this build deployed nothing. The fjall-deploy:started marker could not be recorded"
  refute_output --partial "cli received:"
}

@test "supersede fails a deploy that succeeded when its result cannot be recorded" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  # A lost result skips the result job, which would otherwise fail unstub.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : exit 1" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "cli received: ci run deploy my-app"
  assert_output --partial "Error: the deploy succeeded, but its result could not be recorded, so the next marked build would hold on it. A retry of this step deploys this commit again and records its result."
}

@test "supersede fails a deploy that succeeded when its result job cannot be recorded" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET%% : *} : exit 1" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "Error: the deploy succeeded, but its result could not be recorded"
}

@test "supersede keeps a failed deploy's own exit status when its result cannot be recorded" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  # Drain-then-replace shape, as the exit status test above does it.
  fjall --version > /dev/null
  fjall drain-remaining-plan-line > /dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive : exit 3"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result failure : exit 1" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure 3
  refute_output --partial "Error: the deploy succeeded"
}

@test "supersede holding on doubt posts the annotation, sets no held-by and installs nothing" {
  stub_supersede_module "echo 'supersede: holding, the builds read timed out'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the builds read timed out"
  assert_output --partial "ANNOTATION:This build deployed nothing. The check could not prove that the deploy before it succeeded."
  refute_output --partial "Installing fjall"
}

@test "supersede holds an unmarked build its check holds, since the check read the marker on the page" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is failure'; exit 11" unmarked
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${UNMARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : true" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  refute_output --partial "Installing fjall"
}

@test "supersede holds a marked build whose check exits on an error" {
  stub_supersede_module "exit 1"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the check exited 1 with no verdict this hook reads"
  refute_output --partial "Installing fjall"
}

@test "supersede holds a marked build whose check exits 0 with no deploying line" {
  stub_supersede_module "true"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the check exited 0 with no verdict this hook reads"
  refute_output --partial "Installing fjall"
}

@test "supersede deploys an unmarked build whose check exits on an error" {
  stub_supersede_module "exit 1" unmarked
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${UNMARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "supersede: deploying, the check exited 1"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede deploys an unmarked build whose token secret cannot be read, and says why" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : exit 1" \
    "${UNMARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_output --partial "supersede: deploying, the supersede.token-secret secret could not be read"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede holds a marked build whose token secret cannot be read" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : exit 1" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_failure
  assert_output --partial "supersede: holding, the supersede.token-secret secret could not be read"
  refute_output --partial "Installing fjall"
}

@test "supersede hands the check the word unknown when this build's marker cannot be read, and deploys on its verdict" {
  stub_supersede_module "echo 'supersede: deploying, this build carries no fjall-deploy:supersedable marker'" unknown
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKER_READ_FAILS}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "supersede: this build's fjall-deploy:supersedable marker could not be read, so its entry in the builds list says whether it is marked"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede holds a build whose marker cannot be read when its check exits on an error" {
  stub_supersede_module "exit 1" unknown
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKER_READ_FAILS}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the check exited 1 with no verdict this hook reads"
  refute_output --partial "Installing fjall"
}

@test "supersede holds when neither this build's marker nor the token secret can be read" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : exit 1" \
    "${MARKER_READ_FAILS}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_failure
  assert_output --partial "supersede: holding, neither this build's fjall-deploy:supersedable marker nor the supersede.token-secret secret could be read"
  refute_output --partial "Installing fjall"
}

@test "supersede holds a marked build whose check exits 10 with a line that is not a skip" {
  stub_supersede_module "echo 'supersede: skipped for #530'; exit 10"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the check exited 10 with no verdict this hook reads"
  refute_output --partial "Installing fjall"
}

@test "supersede holds a marked build whose check exits 11 with a line that is not a hold" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: holding, the check exited 11 with no verdict this hook reads"
  refute_output --partial "Installing fjall"
}

@test "supersede retry that gets past the check removes the hold annotation an earlier attempt posted" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotation remove --context fjall-deploy-held : true" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config
  export BUILDKITE_RETRY_COUNT="1"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_success
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede hold still exits 1 when held-by and the annotation fail" {
  stub_supersede_module "echo 'supersede: held by #528, whose deploy result is failure'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "meta-data set fjall-deploy:held-by 528 : exit 1" \
    "annotate --style error --context fjall-deploy-held * : exit 1"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_equal "$status" 1
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a second step of the same build before it reads the token" {
  # The plan ends at the claim's read, so a claim write, a token read or a
  # module start fails unstub.
  stub buildkite-agent \
    "${STEP_CLAIM_GET%% : *} : echo '${SUPERSEDE_BUILD_ID}/0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a61'"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_failure
  assert_output --partial "Error: this build deployed nothing. Another step of this build already set supersede, and a second one would write over the deploy result the first one records. Set supersede on one deploy step per build."
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a step whose claim cannot be read" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET%% : *} : exit 1"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_failure
  assert_output --partial "Error: this build deployed nothing. The step holding supersede, fjall-deploy:supersede-step, could not be read."
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a step whose claim cannot be recorded" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET%% : *} : exit 1"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_failure
  assert_output --partial "Error: this build deployed nothing. The step holding supersede could not be recorded in fjall-deploy:supersede-step."
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a step with parallelism before it reads the claim" {
  # A claim read is the plan's only line, so a hook that reads the claim
  # first goes on to a write the plan refuses and prints that failure, not
  # this refusal.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}"
  supersede_config
  export BUILDKITE_PARALLEL_JOB_COUNT="2"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Error: this build deployed nothing. supersede is set on a step with parallelism, whose jobs would each write over the deploy result the others record. Set supersede on a deploy step with no parallelism."
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a job with no step id before it reads the claim" {
  # A claim read with another default matches no plan line, so a hook that
  # reads it prints the read failure, not this refusal.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}"
  supersede_config
  export BUILDKITE_STEP_ID=""

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Error: this build deployed nothing. The job has no BUILDKITE_BUILD_ID or BUILDKITE_STEP_ID, so it cannot record itself as the step holding supersede."
  refute_output --partial "Installing fjall"
}

@test "supersede refuses a job with no build id before it reads the claim" {
  # A claim read with another default matches no plan line, so a hook that
  # reads it prints the read failure, not this refusal.
  stub buildkite-agent \
    "${STEP_CLAIM_GET}"
  supersede_config
  export BUILDKITE_BUILD_ID=""

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "Error: this build deployed nothing. The job has no BUILDKITE_BUILD_ID or BUILDKITE_STEP_ID, so it cannot record itself as the step holding supersede."
  refute_output --partial "Installing fjall"
}

@test "supersede takes over a claim another build left, as a rebuild that carries its original's metadata does" {
  stub buildkite-agent \
    "${STEP_CLAIM_GET%% : *} : echo '0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a71/0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a61'" \
    "${STEP_CLAIM_SET}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result success : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config
  export BUILDKITE_REBUILT_FROM_BUILD_NUMBER="150"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_output --partial "supersede: deploying, a rebuild never skips or holds"
  assert_output --partial "fjall ci run deploy my-app --non-interactive"
}

@test "supersede overtaken by a newer build posts the annotation, sets no held-by and installs nothing" {
  stub_supersede_module "echo 'supersede: overtaken by #530, which is newer and started or recorded a deploy'; exit 11"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "annotate --style error --context fjall-deploy-held * : printf 'ANNOTATION:%s\n' \"\$6\""
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure
  assert_output --partial "supersede: overtaken by #530, which is newer and started or recorded a deploy"
  assert_output --partial "ANNOTATION:This build deployed nothing. Build [#530](https://buildkite.com/acme/webapp-deploy/builds/530), which is newer, has started or recorded a deploy, so this build's older commit would deploy over it. To deploy this commit anyway, Rebuild this build, which never holds."
  refute_output --partial "Installing fjall"
}

@test "supersede keeps a failed deploy's own exit status when only its result job cannot be recorded" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  fjall --version > /dev/null
  fjall drain-remaining-plan-line > /dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive : exit 3"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result failure : true" \
    "${RESULT_JOB_SET%% : *} : exit 1" \
    "meta-data set fjall-deploy:duration * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure 3
  refute_output --partial "Error: the deploy succeeded"
}

@test "supersede records plan-pending and then its result job after an exit 2" {
  stub_supersede_module "echo 'supersede: deploying, no newer main build can still deploy or has deployed'"
  fjall --version > /dev/null
  fjall drain-remaining-plan-line > /dev/null
  unstub fjall
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive : exit 2"
  stub buildkite-agent \
    "${STEP_CLAIM_GET}" \
    "${STEP_CLAIM_SET}" \
    "${SECRET_GET} : echo 'bkua_bats'" \
    "${MARKED_READ}" \
    "${STARTED_SET}" \
    "meta-data set fjall-deploy:result plan-pending : true" \
    "${RESULT_JOB_SET}" \
    "meta-data set fjall-deploy:duration * : true" \
    "annotate --style warning * : true"
  supersede_config

  run "$PWD/hooks/command"

  unstub buildkite-agent
  assert_failure 2
  refute_output --partial "Error: the deploy succeeded"
}


@test "supersede beside command: build is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="build"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede' is valid only with command: deploy (got 'build')"
  refute_output --partial "Installing fjall"
}

@test "supersede beside a tier target is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="organisation"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "not valid with tier target 'organisation': supersede"
  refute_output --partial "Installing fjall"
}

# Unset FJALL_API_KEY so the hook WOULD read a secret if it got that far. The
# stub's plan line answers that read, and the refusal must come first.
@test "a flag-shaped supersede barrier is refused before any secret is read" {
  unset FJALL_API_KEY
  stub buildkite-agent "secret get FJALL_API_KEY : echo 'SECRET_READ'"
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_1="--oops"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.barriers' must not begin with '-'"
  refute_output --partial "SECRET_READ"
  refute_output --partial "Installing fjall"
}

@test "a supersede barrier with a .. segment is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_0="prisma/../app"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.barriers' item 0 has a '..' segment"
}

@test "a scalar supersede is refused" {
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE="true"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede' must be an object with 'after' and 'token-secret', not a single value."
  refute_output --partial "Installing fjall"
}

@test "supersede without after is refused" {
  supersede_config
  unset BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_AFTER

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.after' is required."
  refute_output --partial "Installing fjall"
}

@test "supersede without token-secret is refused" {
  supersede_config
  unset BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_TOKEN_SECRET

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.token-secret' is required."
  refute_output --partial "Installing fjall"
}

# Item 1 is missing, so the hook cannot tell the list it was given from the
# list it read.
@test "a supersede barriers list with a gap is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_2="clickhouse-init/"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.barriers' has no item 1, so its items are not a list."
  refute_output --partial "Installing fjall"
}

@test "an empty supersede barrier is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_0=""

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.barriers' item 0 is empty."
  refute_output --partial "Installing fjall"
}

@test "an absolute supersede barrier is refused" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIERS_0="/prisma/migrations/"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede.barriers' item 0 is an absolute path."
  refute_output --partial "Installing fjall"
}

# A misspelt key would otherwise be a barrier nobody reads, which a skip
# would step over.
@test "a supersede key the hook does not read is refused, not ignored" {
  supersede_config
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIER_0="clickhouse-init/"

  run "$PWD/hooks/command"

  assert_failure
  assert_output --partial "'supersede' sets BUILDKITE_PLUGIN_FJALL_DEPLOY_SUPERSEDE_BARRIER_0"
  refute_output --partial "Installing fjall"
}

# The build summary runs once the CLI has ended and its result is recorded.
# These tests stub docker, which the hook only looks for, and give node a
# second plan line that stands in for build-summary.mjs. The module's double
# reads its argv by position, as the hook builds it.
SUMMARY_JOB_ID="0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a90"
SUMMARY_CONTEXT="fjall-build-summary-${SUMMARY_JOB_ID}"
SUMMARY_RECORD_NAME="fjall-build-record-0123abcd.dockerbuild"
SUMMARY_RECORD_ARGS=" --record-dir *"

# One job, whatever the environment the suite runs in carries.
summary_job() {
  export BUILDKITE_JOB_ID="${SUMMARY_JOB_ID}"
}

# One run of the hook whose CLI exits $1. npm's and fjall's plans are put
# back first, since a plan answers one run.
stub_cli_exiting() {
  unstub --allow-missing npm || true
  unstub --allow-missing fjall || true
  stub npm "install -g --ignore-scripts fjall@${FJALL_CLI_DEFAULT_MAJOR} : echo 'installed fjall@${FJALL_CLI_DEFAULT_MAJOR}'"
  stub fjall \
    "--version : echo 'fjall/0.88.3'" \
    "ci run deploy my-app --non-interactive : echo 'cli exits $1'; exit $1"
}

# node as one run of the hook calls it, with the version check first and
# then build-summary.mjs, given the argv the hook builds and $2 after it,
# which runs $1. $2 is the record directory the hook hands the module by
# default, and a test of a run that keeps no record passes it empty.
# `bats-mock` matches each word exactly, and a lone * matches any one, so the
# job's own directory is the only checkout this plan admits, and a
# --record-dir the test does not expect is an argument too many.
stub_summary_module() {
  unstub --allow-missing node || true
  stub node \
    "--version : echo 'v${HOOK_NODE_VERSION}'" \
    "$PWD/build-summary.mjs --ci buildkite --since * --checkout $PWD --summary-out * --outputs *${2-${SUMMARY_RECORD_ARGS}} : $1"
}

# The agent calls the hook makes to record the result of a CLI exit of $1,
# then each plan line given after it, for the build summary's own calls.
stub_agent_after_cli() {
  local code="$1" result
  shift
  case "${code}" in
    0) result="success" ;;
    2) result="plan-pending" ;;
    *) result="failure" ;;
  esac
  local plan=("meta-data set fjall-deploy:result ${result} : true" "meta-data set fjall-deploy:duration * : true")
  if [ "${code}" = 2 ]; then
    plan+=("annotate --style warning * : true")
  fi
  stub buildkite-agent "${plan[@]}" "$@"
}

# The module's double. It names each credential it was handed, says when its
# run began, keeps the path of the summary file it was given in
# `summary-file`, and appends $1 to that file.
summary_module_writing() {
  printf '%s' "$(credential_report module); echo \"module since \$5\"; printf '%s\n' \"\$9\" > '${BATS_TEST_TMPDIR}/summary-file'; printf '%s\n' '$1' >> \"\$9\""
}

# The module's double for a run with `build-record`. It writes the summary as
# above, keeps the record directory it was given in `record-dir`, and names
# $1 as the record it wrote. It writes a file of that name unless $2 is
# unwritten, so a name of the wrong shape is refused by its shape alone.
summary_module_recording() {
  local write="touch \"\${13}/$1\"; "
  if [ "${2-}" = "unwritten" ]; then
    write=""
  fi
  printf '%s' "$(summary_module_writing SUMMARY_TABLE); printf '%s\n' \"\${13}\" > '${BATS_TEST_TMPDIR}/record-dir'; ${write}printf 'record-path=%s\nrecord-name=%s\n' \"\${13}/$1\" '$1' >> \"\${11}\""
}

# The annotation's double, which prints the body it read on stdin.
SUMMARY_ANNOTATION="annotate --style info --context ${SUMMARY_CONTEXT} : echo \"annotation body: \$(cat)\""

# The summary file the module's double was given is gone, and so is the
# directory the hook made for it, the record directory included.
assert_summary_files_removed() {
  local summary_file
  summary_file="$(cat "$BATS_TEST_TMPDIR/summary-file")"
  run test -n "${summary_file}"
  assert_success
  run test -e "${summary_file}"
  assert_failure
  run test -e "${summary_file%/*}"
  assert_failure
}

# Every test before this section runs the hook on an agent with no docker,
# where the build summary prints one line and calls neither node nor the
# agent, so their exact plans hold. That rests on the tester image having no
# docker of its own.
@test "build summary tests run on a tester image with no docker" {
  run command -v docker
  assert_failure
}

@test "build summary is one line and no call on an agent without docker, whatever the CLI's exit status" {
  local code
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  for code in 0 1 2; do
    stub_cli_exiting "${code}"
    unstub --allow-missing node || true
    stub node "--version : echo 'v${HOOK_NODE_VERSION}'"
    stub_agent_after_cli "${code}"

    run "$PWD/hooks/command"

    unstub buildkite-agent
    unstub node
    assert_equal "${status}" "${code}"
    assert_equal "${lines[-2]}" "cli exits ${code}"
    assert_equal "${lines[-1]}" "No build summary, since docker is not on this agent's PATH."
  done
}

@test "build summary runs the module without the job token or AWS keys, and annotates its step with the table" {
  stub docker
  stub_summary_module "$(summary_module_writing SUMMARY_TABLE)"
  stub_agent_after_cli 0 "${SUMMARY_ANNOTATION}"
  summary_job
  export BUILDKITE_AGENT_ACCESS_TOKEN="job-token"
  export AWS_ACCESS_KEY_ID="AKIAHOOKTEST"
  export AWS_SECRET_ACCESS_KEY="secret-key"
  export AWS_SESSION_TOKEN="session-token"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  unstub docker
  assert_success
  assert_line "cli received: ci run deploy my-app --non-interactive"
  assert_line --regexp '^module since [0-9]+$'
  refute_output --partial "module holds"
  assert_line "annotation body: SUMMARY_TABLE"
  assert_summary_files_removed
}

@test "build summary leaves the CLI's exit status alone when the module and the annotation fail" {
  local code
  stub docker
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  for code in 0 1 2; do
    stub_cli_exiting "${code}"
    stub_summary_module "$(summary_module_writing SUMMARY_TABLE); exit 1"
    stub_agent_after_cli "${code}" "annotate --style info --context ${SUMMARY_CONTEXT} : echo 'annotation refused'; exit 1"

    run "$PWD/hooks/command"

    unstub buildkite-agent
    unstub node
    assert_equal "${status}" "${code}"
    assert_line "cli exits ${code}"
    assert_line "The build summary module exited 1, so the summary may be incomplete."
    assert_line "annotation refused"
    assert_summary_files_removed
  done
}

@test "build summary makes no annotation for a job with no job id, and leaves the exit status alone" {
  local code
  stub docker
  export BUILDKITE_JOB_ID=""
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  for code in 0 1 2; do
    stub_cli_exiting "${code}"
    stub_summary_module "$(summary_module_writing SUMMARY_TABLE)"
    stub_agent_after_cli "${code}"

    run "$PWD/hooks/command"

    unstub buildkite-agent
    unstub node
    assert_equal "${status}" "${code}"
    assert_line "The build summary is not annotated, since the job has no BUILDKITE_JOB_ID to name its annotation by."
    assert_summary_files_removed
  done
}

# The jobs of a step with parallelism or a matrix share its step id, and each
# builds its own images, so each job's summary is an annotation of its own.
@test "build summary names its annotation by the job, not the step it shares" {
  stub docker
  stub_summary_module "$(summary_module_writing SUMMARY_TABLE)"
  stub_agent_after_cli 0 "annotate --style info --context fjall-build-summary-0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a91 : echo \"annotation body: \$(cat)\""
  export BUILDKITE_STEP_ID="${SUMMARY_JOB_ID}"
  export BUILDKITE_JOB_ID="0190a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a91"
  export BUILDKITE_PARALLEL_JOB="3"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "annotation body: SUMMARY_TABLE"
}

# A tier deploy, or a run that built nothing, leaves the summary file empty.
@test "build summary makes no annotation when the module writes no table" {
  stub docker
  stub_summary_module "echo 'No image build found for this run.'"
  stub_agent_after_cli 0
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "No image build found for this run."
}

# The module keeps a build only when its context lies inside the checkout,
# so it is pointed at the job's own directory, never the one
# `working-directory` moves the CLI into. The plan admits no other checkout.
@test "build summary reads the builder from the checkout when the CLI runs in another directory" {
  stub docker
  stub_summary_module "echo \"module ran for checkout \$7\""
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_WORKING_DIRECTORY="tests"

  run "$PWD/hooks/command"

  unstub node
  assert_success
  assert_line "module ran for checkout $PWD"
  assert_line "The build summary is not annotated, since buildkite-agent is not on this agent's PATH."
}

@test "build summary with a build record uploads the record the module names, from the directory it was written to" {
  stub docker
  stub_summary_module "$(summary_module_recording "${SUMMARY_RECORD_NAME}")" "${SUMMARY_RECORD_ARGS}"
  stub_agent_after_cli 0 \
    "${SUMMARY_ANNOTATION}" \
    "artifact upload ${SUMMARY_RECORD_NAME} : echo \"uploaded from \$PWD\"; test -f '${SUMMARY_RECORD_NAME}' && echo 'the record is there'"
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="true"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "annotation body: SUMMARY_TABLE"
  assert_line "Uploading the build record ${SUMMARY_RECORD_NAME} as an artifact. It holds build arg values, each Dockerfile's source and each step's log, unmasked, and anyone who can read this build can download it."
  assert_line "uploaded from $(cat "$BATS_TEST_TMPDIR/record-dir")"
  assert_line "the record is there"
  assert_summary_files_removed
}

@test "build summary keeps the record by default, uploading the record the module names when build-record is left out" {
  stub docker
  stub_summary_module "$(summary_module_recording "${SUMMARY_RECORD_NAME}")"
  stub_agent_after_cli 0 \
    "${SUMMARY_ANNOTATION}" \
    "artifact upload ${SUMMARY_RECORD_NAME} : echo \"uploaded from \$PWD\"; test -f '${SUMMARY_RECORD_NAME}' && echo 'the record is there'"
  summary_job
  unset BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "Uploading the build record ${SUMMARY_RECORD_NAME} as an artifact. It holds build arg values, each Dockerfile's source and each step's log, unmasked, and anyone who can read this build can download it."
  assert_line "uploaded from $(cat "$BATS_TEST_TMPDIR/record-dir")"
  assert_line "the record is there"
  assert_summary_files_removed
}

@test "build summary with build-record false hands the module no record directory and uploads none" {
  stub docker
  stub_summary_module "$(summary_module_writing SUMMARY_TABLE)" ""
  stub_agent_after_cli 0 "${SUMMARY_ANNOTATION}"
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="false"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "annotation body: SUMMARY_TABLE"
  refute_output --partial "build record"
  assert_summary_files_removed
}

# A tier deploy builds no image, so it keeps no record whatever build-record
# says. The property is on by default, so it is never refused there. The
# module's plan admits no --record-dir, and the agent's admits no upload.
@test "a tier deploy keeps no record and uploads none, whether build-record is left out or true" {
  local target noun setting
  stub docker
  summary_job
  for target in organisation platform account; do
    case "${target}" in
      organisation) noun="org" ;;
      *) noun="${target}" ;;
    esac
    for setting in default true; do
      restub_agent_tools
      stub_summary_module "echo 'No image build found for this run.'" ""
      stub_agent_after_cli 0
      export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="${target}"
      if [ "${setting}" = "true" ]; then
        export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="true"
      else
        unset BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD
      fi

      run "$PWD/hooks/command"

      unstub buildkite-agent
      unstub node
      assert_success
      assert_line "cli received: ${noun} deploy --non-interactive"
      assert_line "No image build found for this run."
      refute_output --partial "build record"
      refute_output --partial "not valid with tier target"
    done
  done
}

# A destroy builds no image, so it keeps no record whatever build-record says,
# on an app target or a tier one. It reaches neither the module nor an upload.
@test "a destroy keeps no record and uploads none, whether build-record is left out or true" {
  local target argv setting
  stub docker
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  for target in my-app organisation; do
    case "${target}" in
      organisation) argv="org destroy --non-interactive" ;;
      *) argv="ci run destroy ${target} --non-interactive" ;;
    esac
    for setting in default true; do
      restub_agent_tools
      stub_agent_after_cli 0
      export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="${target}"
      if [ "${setting}" = "true" ]; then
        export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="true"
      else
        unset BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD
      fi

      run "$PWD/hooks/command"

      unstub buildkite-agent
      assert_success
      assert_line "cli received: ${argv}"
      assert_equal "${lines[-1]}" "No build summary, since a destroy builds no image."
      refute_output --partial "build record"
      refute_output --partial "build-record"
    done
  done
}

# The name comes from the module, so the hook uploads only the one shape the
# module writes, which can neither leave the record directory nor pick
# another file. Each name below is written, so only its shape refuses it.
@test "build summary uploads no record whose name is not the one shape the module writes" {
  local name
  stub docker
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="true"
  for name in fjall-build-record-0123ABCD.dockerbuild fjall-build-record-0123abcd.dockerbuild.sh ../fjall-build-record-0123abcd.dockerbuild; do
    stub_cli_exiting 0
    stub_summary_module "$(summary_module_recording "${name}")" "${SUMMARY_RECORD_ARGS}"
    stub_agent_after_cli 0 "${SUMMARY_ANNOTATION}"

    run "$PWD/hooks/command"

    unstub buildkite-agent
    unstub node
    assert_success
    assert_line "The build record is not uploaded, since its name is not one build-summary.mjs writes. The value given is not repeated here."
    refute_output --partial "${name}"
    refute_output --partial "Uploading the build record"
    assert_summary_files_removed
  done
}

@test "build summary uploads no record the module names but did not write" {
  stub docker
  stub_summary_module "$(summary_module_recording "${SUMMARY_RECORD_NAME}" unwritten)" "${SUMMARY_RECORD_ARGS}"
  stub_agent_after_cli 0 "${SUMMARY_ANNOTATION}"
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_BUILD_RECORD="true"

  run "$PWD/hooks/command"

  unstub buildkite-agent
  unstub node
  assert_success
  assert_line "The build record is not uploaded, since build-summary.mjs named a record it did not write."
  refute_output --partial "Uploading the build record"
}

@test "build summary is skipped for a destroy, which builds no image" {
  stub docker
  summary_job
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_COMMAND="destroy"
  export BUILDKITE_PLUGIN_FJALL_DEPLOY_TARGET="my-app"

  run "$PWD/hooks/command"

  unstub node
  unstub docker
  assert_success
  assert_line "cli received: ci run destroy my-app --non-interactive"
  assert_equal "${lines[-1]}" "No build summary, since a destroy builds no image."
}
