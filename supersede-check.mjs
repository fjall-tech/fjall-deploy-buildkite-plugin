#!/usr/bin/env node
/**
 * Decide whether this deploy build may skip itself because a newer deploy
 * build of the same pipeline carries its commit (the plugin's `supersede`
 * property), and whether a build its creator marked must hold because the
 * deploy before it did not succeed. Only positive proof skips, and for a
 * marked build only positive proof deploys. Every failure, refusal or doubt
 * deploys an unmarked build, which is what the plugin did before `supersede`
 * existed, and holds a marked one.
 *
 *   node supersede-check.mjs <marked|unmarked|unknown> <after> [<barrier>...]
 *
 * The read token arrives on stdin. The first word is the hook's own read of
 * this build's `fjall-deploy:supersedable` marker. `unknown`, or any word but
 * the other two, means the hook could not read it. Then a doubt holds, and
 * once the builds list is read, this build's own entry there says whether it
 * is marked. It reads BUILDKITE_ORGANIZATION_SLUG,
 * BUILDKITE_PIPELINE_SLUG, BUILDKITE_BUILD_NUMBER and BUILDKITE_COMMIT, and
 * prints exactly one line, `supersede: skipped for #<n> at <sha>` with exit
 * code 10, `supersede: held by #<n>, whose deploy result is <word>` or
 * `supersede: holding, <reason>` or
 * `supersede: overtaken by #<n>, which is newer and started or recorded a
 * deploy` with exit code 11, or `supersede: deploying, <reason>` with exit
 * code 0. It never
 * prints a response body, the token or an environment value.
 *
 * This build X, at commit x, skips only when all of these hold.
 *
 * 1. One page of the pipeline's 100 newest `main` builds, read with the token
 *    and every retried job, is newest first, holds only `main` builds and
 *    reaches X, and X's own entry carries the creator's marker
 *    `fjall-deploy:supersedable` = `true`.
 * 2. Y, the newest build above X that is running with `fjall-deploy:result`
 *    unset or `success`, or passed with it `success`, exists. A result counts
 *    only when the attempt that last started a deploy recorded it, so one an
 *    earlier attempt left reads as unset. A running build whose last started
 *    attempt recorded nothing counts only until the job that started it ends,
 *    since a deploy that ended with no result deployed nothing this check can
 *    see. If Y then fails a check, X does not skip, and looks no further back
 *    for another Y.
 * 3. Y's commit y is a full sha, and Y has exactly one job keyed `<after>`
 *    that was not retried, which passed.
 * 4. x has a parent and is on y's first parent line, and no commit from y
 *    down to x, both included, is a barrier. A barrier's diff against its
 *    first parent touches a `<barrier>` path, read literally, or its message
 *    has a line starting `deploy-alone`.
 *
 * X never skips when its own `fjall-deploy:result` is already set to anything
 * but `superseded` or `success`, since only a retry of a deploy that did not
 * succeed carries one, and a skip would write over it the result that names
 * that deploy red. Nor does X skip once its own `fjall-deploy:started` is set,
 * since an earlier attempt then started a deploy whose result may be lost.
 *
 * The hook writes `fjall-deploy:started` as the job's id just before the CLI
 * runs, and `fjall-deploy:result-job` as the same id once it has recorded
 * `fjall-deploy:result`. A retry is a new job, so the two agree only when the
 * attempt that last started a deploy recorded its result.
 *
 * A marked X that does not skip holds as overtaken when a newer build on the
 * page started a deploy or recorded the result of one, since x would deploy
 * over it. That newer build may have deployed and then failed a later step,
 * so it is no Y, or deployed while X was held and before X was retried. A
 * rebuild of X, which never holds, deploys x anyway.
 *
 * A marked X that does not skip deploys only when P, the newest build below X
 * on the page that recorded a deploy, recorded `success`, or X's entry carries
 * the creator's marker `fjall-deploy:red-cleared` = P's number. A build
 * recorded a deploy when its last started attempt recorded a result that is
 * not `superseded`, or when that attempt recorded none. The second reads as
 * the result `unrecorded` once the job that started the deploy has ended, or,
 * when the page does not list that job, once the build has ended. Until
 * then X is held by it as `unfinished`, which no marker clears, since that
 * deploy may still be running. A build that started no deploy is read by its
 * `fjall-deploy:result` alone. One with no result, or `superseded`, deployed
 * nothing, so it is passed over, as webapp's deploy-decide.jq passes it over.
 * With no P, X deploys only when the page is shorter than its size, since
 * such a page is the pipeline's whole history.
 *
 * It stands alone like resolve-fjall-engine.mjs. The plugin ships with no
 * node_modules, so it imports only Node's own modules.
 */
import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const SKIP_EXIT_CODE = 10;
export const HOLD_EXIT_CODE = 11;
export const SUPERSEDABLE_KEY = "fjall-deploy:supersedable";
export const RED_CLEARED_KEY = "fjall-deploy:red-cleared";
export const RESULT_KEY = "fjall-deploy:result";
export const STARTED_KEY = "fjall-deploy:started";
export const RESULT_JOB_KEY = "fjall-deploy:result-job";
/** The result an ended build that started a deploy and recorded none reads as. */
export const UNRECORDED_RESULT = "unrecorded";
/** The result a build reads as while a deploy it started may still be running. */
export const UNFINISHED_RESULT = "unfinished";
export const PAGE_SIZE = 100;
const MAX_RANGE = 1000;
const DEFAULT_LIMITS = Object.freeze({
  readMs: 30_000,
  totalMs: 120_000,
});

const API_ORIGIN = "https://api.buildkite.com";
const SLUG = /^[a-z0-9][a-z0-9-]{0,99}$/;
const BUILD_NUMBER = /^[1-9][0-9]{0,9}$/;
const FULL_SHA = /^[0-9a-f]{40}$/;
const TOKEN = /^[\x21-\x7e]{1,1024}$/;
const MAX_PAGE_BYTES = 32 * 1024 * 1024;
const MAX_GIT_OUTPUT_BYTES = 4 * 1024 * 1024;
const SIGTERM_GRACE_MS = 2_000;
const DEPLOY_ALONE = /^deploy-alone/m;

/**
 * What each documented Buildkite build state means to the check. An unknown
 * state is absent, so it reads as not eligible and not ended.
 *
 * `eligibility` says whether a build in the state can be Y. A running build
 * has deployed nothing once it records any result but `success`. It may have
 * skipped itself, or soft failed its deploy, while later steps still run.
 *
 * `ended` says whether the build has finished, so a deploy it started and
 * recorded no result for will record none. It decides only when the page no
 * longer lists the job that started the deploy. The states that read as ended
 * are the ones webapp's deploy-decide.jq lists in `ended_empty`.
 */
const BUILD_STATES = Object.freeze({
  creating: { eligibility: "no", ended: false },
  scheduled: { eligibility: "no", ended: false },
  running: { eligibility: "unless-it-recorded-another-result", ended: false },
  failing: { eligibility: "no", ended: false },
  canceling: { eligibility: "no", ended: false },
  blocked: { eligibility: "no", ended: false },
  passed: { eligibility: "if-it-recorded-success", ended: true },
  failed: { eligibility: "no", ended: true },
  canceled: { eligibility: "no", ended: true },
  skipped: { eligibility: "no", ended: true },
  not_run: { eligibility: "no", ended: true },
});

function stateOf(build) {
  return Object.hasOwn(BUILD_STATES, build.state)
    ? BUILD_STATES[build.state]
    : { eligibility: "no", ended: false };
}

/**
 * The states of a job that ran and will run no more. Any other state, one
 * this check does not know included, reads as a job that may still deploy.
 */
const ENDED_JOB_STATES = new Set(["passed", "failed", "canceled", "timed_out"]);

/** A build's own meta-data value under `key`, or undefined when it has none. */
function metaValue(build, key) {
  return isRecord(build.meta_data) && Object.hasOwn(build.meta_data, key)
    ? build.meta_data[key]
    : undefined;
}

/** True for a result that records no deploy, as deploy-decide.jq reads one. */
function recordsNoDeploy(result) {
  return result === undefined || result === "" || result === "superseded";
}

function isEligible(build) {
  const { eligibility } = stateOf(build);
  if (eligibility === "no" || !isRecord(build.meta_data)) return false;
  const running = eligibility === "unless-it-recorded-another-result";
  if (startedUnrecorded(build)) return running && !startedDeployEnded(build);
  const result = metaValue(build, RESULT_KEY);
  return result === "success" || (running && result === undefined);
}

const deploy = (reason) => ({ kind: "deploy", reason });
const holding = (reason) => ({ kind: "holding", reason });

/**
 * What a doubt does. Only an explicit `false` deploys, so a caller that
 * passed no marker, or could not read it, holds rather than deploying a build
 * it never judged.
 */
function unproven(marked, reason) {
  return marked === false ? deploy(reason) : holding(reason);
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** A result as webapp's deploy-decide.jq names one, `?` unless a short word. */
function resultWord(value) {
  return typeof value === "string" && /^[a-z][a-z_-]{0,39}$/.test(value)
    ? value
    : "?";
}

function boundReason(limits) {
  return `the check ran past its ${Math.round(limits.totalMs / 1000)} s bound`;
}

/** Refuses an input the hook already refuses, so the module stands alone. */
function barrierProblem(barrier) {
  if (typeof barrier !== "string" || barrier === "") return "is empty";
  if (barrier.startsWith("-")) return "begins with '-'";
  if (barrier.startsWith("/")) return "is an absolute path";
  if (barrier.split("/").includes("..")) return "has a '..' segment";
  return undefined;
}

async function discardBody(response) {
  // The status has already decided this read. A body that errors while it
  // is discarded changes nothing, and the connection is released either way.
  await response.body?.cancel().catch(() => undefined);
}

async function readBoundedText(response) {
  const reader = response.body?.getReader();
  if (reader === undefined) return "";
  const chunks = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_PAGE_BYTES) {
      await reader.cancel().catch(() => undefined);
      throw new RangeError("the builds answer is larger than the check reads");
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function readBuildsPage({
  org,
  pipeline,
  token,
  fetchImpl,
  limits,
  deadline,
}) {
  const remaining = deadline - Date.now();
  if (remaining <= 0) return { ok: false, reason: boundReason(limits) };
  const url = `${API_ORIGIN}/v2/organizations/${org}/pipelines/${pipeline}/builds?branch=main&per_page=${PAGE_SIZE}&include_retried_jobs=true`;
  const signal = AbortSignal.timeout(Math.min(limits.readMs, remaining));
  let response;
  try {
    response = await fetchImpl(url, {
      headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
      redirect: "manual",
      signal,
    });
  } catch {
    return {
      ok: false,
      reason: signal.aborted
        ? "the builds read timed out"
        : "the builds read failed before Buildkite answered",
    };
  }
  if (response.status !== 200) {
    await discardBody(response);
    return {
      ok: false,
      reason: `the builds read answered HTTP ${response.status}`,
    };
  }
  let text;
  try {
    text = await readBoundedText(response);
  } catch (error) {
    return {
      ok: false,
      reason: signal.aborted
        ? "the builds read timed out"
        : error instanceof RangeError
          ? error.message
          : "the builds answer could not be read",
    };
  }
  try {
    return { ok: true, builds: JSON.parse(text) };
  } catch {
    return { ok: false, reason: "the builds answer was not JSON" };
  }
}

/** Rule 1's shape, over the page. Returns X's place or the doubt. */
function readPage(builds, number) {
  if (!Array.isArray(builds) || builds.length === 0) {
    return { ok: false, reason: "the builds answer was not a non-empty list" };
  }
  for (const build of builds) {
    if (
      !isRecord(build) ||
      !Number.isSafeInteger(build.number) ||
      typeof build.branch !== "string"
    ) {
      return {
        ok: false,
        reason: "a build on the page has no number or branch",
      };
    }
  }
  for (let i = 1; i < builds.length; i += 1) {
    if (builds[i].number >= builds[i - 1].number) {
      return { ok: false, reason: "the builds page is not newest first" };
    }
  }
  if (builds.some((build) => build.branch !== "main")) {
    return {
      ok: false,
      reason: "the builds page holds a build that is not on main",
    };
  }
  const ownIndex = builds.findIndex((build) => build.number === number);
  if (ownIndex === -1) {
    return {
      ok: false,
      reason:
        builds[builds.length - 1].number > number
          ? `the ${builds.length} newest main builds do not reach this build`
          : "this build is not on the page of main builds",
    };
  }
  return { ok: true, ownIndex };
}

function carriesMarker(build) {
  return (
    isRecord(build.meta_data) && build.meta_data[SUPERSEDABLE_KEY] === "true"
  );
}

/** The job id of the attempt that last started a deploy, or undefined. */
function startedBy(build) {
  const job = metaValue(build, STARTED_KEY);
  return typeof job === "string" && job !== "" ? job : undefined;
}

/**
 * True when an attempt of this build started a deploy and recorded no result
 * after it. The hook writes the started marker just before the CLI runs, then
 * the result and the result job once it exits, so only a lost write, or a job
 * stopped between the two, leaves them apart. A result beside a result job
 * that is not the started one was left by an earlier attempt.
 */
function startedUnrecorded(build) {
  const job = startedBy(build);
  if (job === undefined) return false;
  return (
    recordsNoDeploy(metaValue(build, RESULT_KEY)) ||
    metaValue(build, RESULT_JOB_KEY) !== job
  );
}

/**
 * Whether the deploy a build started has ended. The job that started it says,
 * when the page lists it, as a page read with every retried job does. When it
 * does not, the build's own state says instead.
 */
function startedDeployEnded(build) {
  const job = startedBy(build);
  const jobs = Array.isArray(build.jobs) ? build.jobs : [];
  const started = jobs.find((entry) => isRecord(entry) && entry.id === job);
  return started === undefined
    ? stateOf(build).ended
    : ENDED_JOB_STATES.has(started.state);
}

/** The red result a retry of this build carries, or undefined. */
function ownRedResult(own) {
  const result = metaValue(own, RESULT_KEY);
  return recordsNoDeploy(result) || result === "success"
    ? undefined
    : resultWord(result);
}

/**
 * For a marked build that did not skip, the newest newer build that started
 * a deploy or recorded the result of one, as an overtaken verdict, or
 * undefined when none did. A newer build whose metadata is not an object
 * holds, since it may have deployed.
 */
function overtakenBy(newerBuilds) {
  for (const build of newerBuilds) {
    if (build.meta_data === null || build.meta_data === undefined) continue;
    if (!isRecord(build.meta_data)) {
      return holding(`build #${build.number}'s meta-data is not an object`);
    }
    if (
      startedBy(build) !== undefined ||
      !recordsNoDeploy(metaValue(build, RESULT_KEY))
    ) {
      return { kind: "overtaken", number: build.number };
    }
  }
  return undefined;
}

/** The rest of rules 1 to 3. Returns Y or the reason not to skip. */
function judgeNewer(builds, ownIndex, { commit, after }) {
  const own = builds[ownIndex];
  if (!carriesMarker(own)) {
    return deploy(`this build carries no ${SUPERSEDABLE_KEY} marker`);
  }
  const red = ownRedResult(own);
  if (red !== undefined) {
    return deploy(
      `this build already recorded the deploy result ${red}, so its retry never skips`,
    );
  }
  if (startedBy(own) !== undefined) {
    return deploy(
      "this build already started a deploy, so its retry never skips",
    );
  }
  if (own.commit !== commit) {
    return deploy("this build's page entry names another commit");
  }

  const newer = builds.slice(0, ownIndex).find(isEligible);
  if (newer === undefined) {
    return deploy("no newer main build can still deploy or has deployed");
  }
  if (typeof newer.commit !== "string" || !FULL_SHA.test(newer.commit)) {
    return deploy(`newer build #${newer.number} does not name a full commit`);
  }
  if (!Array.isArray(newer.jobs)) {
    return deploy(`newer build #${newer.number} lists no jobs`);
  }
  const keyed = newer.jobs.filter(
    (job) => isRecord(job) && job.step_key === after && job.retried !== true,
  );
  if (keyed.length !== 1) {
    return deploy(
      `newer build #${newer.number} has ${keyed.length} jobs keyed by supersede.after, not 1`,
    );
  }
  if (keyed[0].state !== "passed") {
    return deploy(
      `newer build #${newer.number} has not passed its supersede.after job`,
    );
  }
  return { kind: "candidate", number: newer.number, commit: newer.commit };
}

/**
 * The deploy before a marked X, for a build that did not skip. `reason` is
 * why it did not skip, kept as the deploy line's reason.
 */
function judgeBefore(builds, ownIndex, reason) {
  const own = builds[ownIndex];
  for (const build of builds.slice(ownIndex + 1)) {
    if (build.meta_data === null || build.meta_data === undefined) continue;
    if (!isRecord(build.meta_data)) {
      return holding(`build #${build.number}'s meta-data is not an object`);
    }
    let word;
    if (startedUnrecorded(build)) {
      if (!startedDeployEnded(build)) {
        return {
          kind: "held",
          number: build.number,
          result: UNFINISHED_RESULT,
        };
      }
      word = UNRECORDED_RESULT;
    } else {
      const result = metaValue(build, RESULT_KEY);
      if (recordsNoDeploy(result)) continue;
      if (result === "success") return deploy(reason);
      word = resultWord(result);
    }
    if (metaValue(own, RED_CLEARED_KEY) === String(build.number)) {
      return deploy(
        `${reason}, and this build's ${RED_CLEARED_KEY} marker clears build #${build.number}'s ${word}`,
      );
    }
    return { kind: "held", number: build.number, result: word };
  }
  return builds.length < PAGE_SIZE
    ? deploy(reason)
    : holding(
        `no build below this one on the page of ${PAGE_SIZE} recorded a deploy result`,
      );
}

/**
 * Runs git with no shell, bounded by the check's deadline. It sends SIGTERM
 * first, so git removes its lock files, and SIGKILL if git has not exited
 * after a grace period.
 */
function runGit(args, { cwd, deadline }) {
  return new Promise((resolve) => {
    const remaining = deadline - Date.now();
    if (remaining <= 0) {
      resolve({ timedOut: true, status: null, stdout: "" });
      return;
    }
    let child;
    try {
      child = spawn("git", args, {
        cwd,
        shell: false,
        stdio: ["ignore", "pipe", "ignore"],
        env: { ...process.env, GIT_TERMINAL_PROMPT: "0" },
      });
    } catch {
      resolve({ timedOut: false, status: null, stdout: "" });
      return;
    }
    const chunks = [];
    let size = 0;
    let overflowed = false;
    let timedOut = false;
    let exited = false;
    let killTimer;
    const stop = () => {
      child.stdout?.destroy();
      child.kill("SIGTERM");
      killTimer = setTimeout(() => {
        if (!exited) child.kill("SIGKILL");
      }, SIGTERM_GRACE_MS);
    };
    const timer = setTimeout(() => {
      timedOut = true;
      stop();
    }, remaining);
    child.stdout?.on("data", (chunk) => {
      size += chunk.length;
      if (size > MAX_GIT_OUTPUT_BYTES) {
        if (!overflowed) {
          overflowed = true;
          stop();
        }
        return;
      }
      chunks.push(chunk);
    });
    child.once("exit", () => {
      exited = true;
    });
    child.once("error", () => {
      clearTimeout(timer);
      if (killTimer !== undefined) clearTimeout(killTimer);
      resolve({ timedOut, status: null, stdout: "" });
    });
    child.once("close", (code) => {
      clearTimeout(timer);
      if (killTimer !== undefined) clearTimeout(killTimer);
      resolve({
        timedOut,
        status: overflowed ? null : code,
        stdout: Buffer.concat(chunks).toString("utf8"),
      });
    });
  });
}

function gitFailure(verb, result, limits) {
  if (result.timedOut) return boundReason(limits);
  return result.status === null
    ? `git ${verb} did not run to an exit`
    : `git ${verb} exited ${result.status}`;
}

/** Rule 4, in the checkout at `cwd`. Returns the reason to deploy, or none. */
async function judgeHistory({ cwd, x, y, barriers, deadline, limits }) {
  const git = (args) => runGit(args, { cwd, deadline });

  const top = await git(["rev-parse", "--show-toplevel"]);
  if (top.status !== 0) return gitFailure("rev-parse", top, limits);
  const root = top.stdout.replace(/\n$/, "");
  const inRepo = (args) => runGit(args, { cwd: root, deadline });

  const head = await inRepo([
    "rev-parse",
    "--verify",
    "--quiet",
    "HEAD^{commit}",
  ]);
  if (head.status !== 0) return gitFailure("rev-parse", head, limits);
  if (head.stdout.trim() !== x) {
    return "the checkout's HEAD is not this build's commit";
  }

  const present = await inRepo(["cat-file", "-e", `${y}^{commit}`]);
  if (present.timedOut) return boundReason(limits);
  if (present.status !== 0) {
    const fetched = await inRepo([
      "fetch",
      "--quiet",
      "--no-tags",
      "--no-recurse-submodules",
      "--",
      "origin",
      y,
    ]);
    if (fetched.status !== 0) return gitFailure("fetch", fetched, limits);
    const again = await inRepo(["cat-file", "-e", `${y}^{commit}`]);
    if (again.status !== 0) {
      return again.timedOut
        ? boundReason(limits)
        : "the newer build's commit is not in this checkout after a fetch";
    }
  }

  const shallow = await inRepo(["rev-parse", "--is-shallow-repository"]);
  if (shallow.status !== 0) return gitFailure("rev-parse", shallow, limits);
  if (shallow.stdout.trim() === "true") {
    const unshallowed = await inRepo([
      "fetch",
      "--quiet",
      "--unshallow",
      "--no-tags",
      "--no-recurse-submodules",
      "--",
      "origin",
    ]);
    if (unshallowed.status !== 0) {
      return gitFailure("fetch --unshallow", unshallowed, limits);
    }
    const recheck = await inRepo(["rev-parse", "--is-shallow-repository"]);
    if (recheck.status !== 0) return gitFailure("rev-parse", recheck, limits);
    if (recheck.stdout.trim() !== "false") {
      return "this checkout is still shallow after git fetch --unshallow";
    }
  } else if (shallow.stdout.trim() !== "false") {
    return "git did not say whether this checkout is shallow";
  }

  // Read only once the clone is complete. A shallow boundary commit shows no
  // parents, so it would read as a root commit.
  const parents = await inRepo(["rev-list", "--max-count=1", "--parents", x]);
  if (parents.status !== 0) return gitFailure("rev-list", parents, limits);
  if (parents.stdout.trim().split(" ").length < 2) {
    return "this build's commit is a root commit";
  }

  const line = await inRepo([
    "rev-list",
    "--first-parent",
    `--max-count=${MAX_RANGE + 1}`,
    y,
  ]);
  if (line.status !== 0) return gitFailure("rev-list", line, limits);
  const firstParents = line.stdout.split("\n").filter((sha) => sha !== "");
  const at = firstParents.indexOf(x);
  if (at === -1) {
    return firstParents.length > MAX_RANGE
      ? `this build's commit is more than ${MAX_RANGE} first parent commits behind the newer build's`
      : "this build's commit is not on the newer build's first parent line";
  }

  for (const commit of firstParents.slice(0, at + 1)) {
    const raw = await inRepo(["cat-file", "commit", commit]);
    if (raw.status !== 0) return gitFailure("cat-file", raw, limits);
    const blank = raw.stdout.indexOf("\n\n");
    const message = blank === -1 ? "" : raw.stdout.slice(blank + 2);
    if (DEPLOY_ALONE.test(message)) {
      return `commit ${commit} carries a deploy-alone line`;
    }
    if (barriers.length === 0) continue;
    const diff = await inRepo([
      "--literal-pathspecs",
      "diff",
      "--quiet",
      "--no-renames",
      `${commit}^1`,
      commit,
      "--",
      ...barriers,
    ]);
    if (diff.status === 1) return `commit ${commit} changes a barrier path`;
    if (diff.status !== 0) return gitFailure("diff", diff, limits);
  }
  return undefined;
}

/**
 * The whole decision. `env` carries the four Buildkite names, `token` is the
 * read token, `marked` is the hook's read of this build's marker and `cwd` is
 * the checkout. Only `marked: false` lets a doubt deploy. With `marked` left
 * undefined, because the hook could not read it, a doubt holds and the page
 * entry's marker decides the rest. Resolves to
 * `{ kind: "skip", number, commit }`, `{ kind: "held", number, result }`,
 * `{ kind: "overtaken", number }`, `{ kind: "holding", reason }` or
 * `{ kind: "deploy", reason }`, and never rejects.
 */
export async function decide({
  env,
  token,
  marked,
  after,
  barriers,
  cwd,
  fetchImpl = globalThis.fetch,
  limits = DEFAULT_LIMITS,
}) {
  const deadline = Date.now() + limits.totalMs;
  const doubt = (reason) => unproven(marked, reason);
  if (typeof after !== "string" || after === "") {
    return doubt("supersede.after is empty");
  }
  for (const barrier of barriers) {
    const problem = barrierProblem(barrier);
    if (problem !== undefined) return doubt(`a barrier ${problem}`);
  }
  const org = env.BUILDKITE_ORGANIZATION_SLUG;
  const pipeline = env.BUILDKITE_PIPELINE_SLUG;
  if (
    typeof org !== "string" ||
    typeof pipeline !== "string" ||
    !SLUG.test(org) ||
    !SLUG.test(pipeline)
  ) {
    return doubt(
      "the organisation or pipeline slug is off Buildkite's grammar",
    );
  }
  const rawNumber = env.BUILDKITE_BUILD_NUMBER;
  if (typeof rawNumber !== "string" || !BUILD_NUMBER.test(rawNumber)) {
    return doubt("this build's number is not a build number");
  }
  const x = env.BUILDKITE_COMMIT;
  if (typeof x !== "string" || !FULL_SHA.test(x)) {
    return doubt("this build's commit is not a full sha");
  }
  if (typeof token !== "string" || !TOKEN.test(token)) {
    return doubt("the read token is empty or not one printable word");
  }

  const page = await readBuildsPage({
    org,
    pipeline,
    token,
    fetchImpl,
    limits,
    deadline,
  });
  if (!page.ok) return doubt(page.reason);
  const { builds } = page;
  const placed = readPage(builds, Number.parseInt(rawNumber, 10));
  if (!placed.ok) return doubt(placed.reason);
  const { ownIndex } = placed;

  // The skip comes first. It deploys nothing, so it needs no hold.
  const judged = judgeNewer(builds, ownIndex, { commit: x, after });
  let reason;
  if (judged.kind === "candidate") {
    const refusal = await judgeHistory({
      cwd,
      x,
      y: judged.commit,
      barriers,
      deadline,
      limits,
    });
    if (refusal === undefined) {
      return { kind: "skip", number: judged.number, commit: judged.commit };
    }
    reason = refusal;
  } else {
    reason = judged.reason;
  }
  const own = builds[ownIndex];
  if (marked !== true && !carriesMarker(own)) {
    return deploy(reason);
  }
  const overtaken = overtakenBy(builds.slice(0, ownIndex));
  if (overtaken !== undefined) return overtaken;
  return judgeBefore(builds, ownIndex, reason);
}

/**
 * The one line the hook reads, and the exit code it reads beside it. A kind
 * this does not know holds, so no verdict deploys by default.
 */
export function verdictLine(verdict) {
  switch (verdict.kind) {
    case "skip":
      return {
        line: `supersede: skipped for #${verdict.number} at ${verdict.commit}`,
        code: SKIP_EXIT_CODE,
      };
    case "held":
      return {
        line: `supersede: held by #${verdict.number}, whose deploy result is ${verdict.result}`,
        code: HOLD_EXIT_CODE,
      };
    case "overtaken":
      return {
        line: `supersede: overtaken by #${verdict.number}, which is newer and started or recorded a deploy`,
        code: HOLD_EXIT_CODE,
      };
    case "holding":
      return {
        line: `supersede: holding, ${verdict.reason}`,
        code: HOLD_EXIT_CODE,
      };
    case "deploy":
      return { line: `supersede: deploying, ${verdict.reason}`, code: 0 };
    default:
      return {
        line: "supersede: holding, the check reached no verdict",
        code: HOLD_EXIT_CODE,
      };
  }
}

/** Reads the token from stdin, bounded in size and time. */
function readStdin(stream, timeoutMs) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    let settled = false;
    let timeoutId;
    const finish = (value) => {
      if (settled) return;
      settled = true;
      if (timeoutId !== undefined) clearTimeout(timeoutId);
      stream.destroy();
      resolve(value);
    };
    timeoutId = setTimeout(() => finish(undefined), timeoutMs);
    stream.on("data", (chunk) => {
      size += chunk.length;
      if (size > 4096) {
        finish(undefined);
        return;
      }
      chunks.push(chunk);
    });
    stream.once("end", () => finish(Buffer.concat(chunks).toString("utf8")));
    stream.once("error", () => finish(undefined));
  });
}

/** The hook's first word, `true`, `false`, or undefined when it read nothing. */
function markerFromWord(word) {
  if (word === "marked") return true;
  if (word === "unmarked") return false;
  return undefined;
}

async function main(marked) {
  const [, after, ...barriers] = process.argv.slice(2);
  const token = await readStdin(process.stdin, DEFAULT_LIMITS.readMs);
  if (token === undefined) {
    return unproven(marked, "the read token did not arrive on stdin");
  }
  return decide({
    env: process.env,
    token: token.replace(/\r?\n$/, ""),
    marked,
    after,
    barriers,
    cwd: process.cwd(),
  });
}

/**
 * True only when node was started on THIS file, by realpath, as
 * resolve-fjall-engine.mjs decides it. The plugin ships standalone, so it
 * cannot import the repository's helper. Any failure to realpath either path
 * reads as not started, and the hook reads a run that printed no line as
 * deploying an unmarked build and holding a marked one.
 */
function isInvokedDirectly() {
  if (process.argv[1] === undefined) return false;
  try {
    return (
      realpathSync(process.argv[1]) ===
      realpathSync(fileURLToPath(import.meta.url))
    );
  } catch {
    return false;
  }
}

if (isInvokedDirectly()) {
  const marked = markerFromWord(process.argv[2]);
  let verdict;
  try {
    verdict = await main(marked);
  } catch (err) {
    verdict = unproven(
      marked,
      `the check stopped on ${err instanceof Error ? err.name : "a non-error"}`,
    );
  }
  const { line, code } = verdictLine(verdict);
  process.stdout.write(`${line}\n`, () => process.exit(code));
}
