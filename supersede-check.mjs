#!/usr/bin/env node
/**
 * Decide whether this deploy build may skip itself because a newer deploy
 * build of the same pipeline carries its commit (the plugin's `supersede`
 * property). Only positive proof skips. Every failure, refusal or doubt
 * deploys the commit this build was given, which is what the plugin did
 * before `supersede` existed.
 *
 *   node supersede-check.mjs <after> [<barrier>...]   (the read token on stdin)
 *
 * It reads BUILDKITE_ORGANIZATION_SLUG, BUILDKITE_PIPELINE_SLUG,
 * BUILDKITE_BUILD_NUMBER and BUILDKITE_COMMIT, and prints exactly one line,
 * either `supersede: skipped for #<n> at <sha>` with exit code 10, or
 * `supersede: deploying, <reason>` with exit code 0. It never prints a
 * response body, the token or an environment value.
 *
 * This build X, at commit x, skips only when all of these hold.
 *
 * 1. One page of the pipeline's 20 newest `main` builds, read with the token,
 *    is newest first, holds only `main` builds and reaches X, and X's own
 *    entry carries the creator's marker `fjall-deploy:supersedable` = `true`.
 * 2. Y, the newest build above X that is running with `fjall-deploy:result`
 *    unset or `success`, or passed with it `success`, exists. If Y then fails
 *    a check, X deploys without looking further back.
 * 3. Y's commit y is a full sha, and Y has exactly one job keyed `<after>`,
 *    which passed.
 * 4. x has a parent and is on y's first parent line, and no commit from y
 *    down to x, both included, is a barrier. A barrier's diff against its
 *    first parent touches a `<barrier>` path, read literally, or its message
 *    has a line starting `deploy-alone`.
 *
 * It stands alone like resolve-fjall-engine.mjs. The plugin ships with no
 * node_modules, so it imports only Node's own modules.
 */
import { spawn } from "node:child_process";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const SKIP_EXIT_CODE = 10;
export const SUPERSEDABLE_KEY = "fjall-deploy:supersedable";
export const RESULT_KEY = "fjall-deploy:result";
const PAGE_SIZE = 20;
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
 * Which Buildkite build states can be Y, over the documented state union. An
 * unknown state is absent, so it reads as not eligible. A running build has
 * deployed nothing once it records any result but `success`. It may have
 * skipped itself, or soft failed its deploy, while later steps still run.
 */
const STATE_ELIGIBILITY = Object.freeze({
  creating: "no",
  scheduled: "no",
  running: "unless-it-recorded-another-result",
  failing: "no",
  canceling: "no",
  blocked: "no",
  passed: "if-it-recorded-success",
  failed: "no",
  canceled: "no",
  skipped: "no",
  not_run: "no",
});

function isEligible(build) {
  const eligibility = Object.hasOwn(STATE_ELIGIBILITY, build.state)
    ? STATE_ELIGIBILITY[build.state]
    : "no";
  if (eligibility === "no" || !isRecord(build.meta_data)) return false;
  const result = Object.hasOwn(build.meta_data, RESULT_KEY)
    ? build.meta_data[RESULT_KEY]
    : undefined;
  if (result === "success") return true;
  return (
    eligibility === "unless-it-recorded-another-result" && result === undefined
  );
}

const deploy = (reason) => ({ kind: "deploy", reason });

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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
  const url = `${API_ORIGIN}/v2/organizations/${org}/pipelines/${pipeline}/builds?branch=main&per_page=${PAGE_SIZE}`;
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

/** Rules 1 to 3, over the page. Returns Y or the reason to deploy. */
function judgePage(builds, { number, commit, after }) {
  if (!Array.isArray(builds) || builds.length === 0) {
    return deploy("the builds answer was not a non-empty list");
  }
  for (const build of builds) {
    if (
      !isRecord(build) ||
      !Number.isSafeInteger(build.number) ||
      typeof build.branch !== "string"
    ) {
      return deploy("a build on the page has no number or branch");
    }
  }
  for (let i = 1; i < builds.length; i += 1) {
    if (builds[i].number >= builds[i - 1].number) {
      return deploy("the builds page is not newest first");
    }
  }
  if (builds.some((build) => build.branch !== "main")) {
    return deploy("the builds page holds a build that is not on main");
  }
  const ownIndex = builds.findIndex((build) => build.number === number);
  if (ownIndex === -1) {
    return deploy(
      builds[builds.length - 1].number > number
        ? `the ${builds.length} newest main builds do not reach this build`
        : "this build is not on the page of main builds",
    );
  }
  const own = builds[ownIndex];
  if (!isRecord(own.meta_data) || own.meta_data[SUPERSEDABLE_KEY] !== "true") {
    return deploy(`this build carries no ${SUPERSEDABLE_KEY} marker`);
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
    (job) => isRecord(job) && job.step_key === after,
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
 * read token and `cwd` is the checkout. Resolves to `{ kind: "skip", number,
 * commit }` or `{ kind: "deploy", reason }`, and never rejects.
 */
export async function decide({
  env,
  token,
  after,
  barriers,
  cwd,
  fetchImpl = globalThis.fetch,
  limits = DEFAULT_LIMITS,
}) {
  const deadline = Date.now() + limits.totalMs;
  if (typeof after !== "string" || after === "") {
    return deploy("supersede.after is empty");
  }
  for (const barrier of barriers) {
    const problem = barrierProblem(barrier);
    if (problem !== undefined) return deploy(`a barrier ${problem}`);
  }
  const org = env.BUILDKITE_ORGANIZATION_SLUG;
  const pipeline = env.BUILDKITE_PIPELINE_SLUG;
  if (
    typeof org !== "string" ||
    typeof pipeline !== "string" ||
    !SLUG.test(org) ||
    !SLUG.test(pipeline)
  ) {
    return deploy(
      "the organisation or pipeline slug is off Buildkite's grammar",
    );
  }
  const rawNumber = env.BUILDKITE_BUILD_NUMBER;
  if (typeof rawNumber !== "string" || !BUILD_NUMBER.test(rawNumber)) {
    return deploy("this build's number is not a build number");
  }
  const x = env.BUILDKITE_COMMIT;
  if (typeof x !== "string" || !FULL_SHA.test(x)) {
    return deploy("this build's commit is not a full sha");
  }
  if (typeof token !== "string" || !TOKEN.test(token)) {
    return deploy("the read token is empty or not one printable word");
  }

  const page = await readBuildsPage({
    org,
    pipeline,
    token,
    fetchImpl,
    limits,
    deadline,
  });
  if (!page.ok) return deploy(page.reason);
  const judged = judgePage(page.builds, {
    number: Number.parseInt(rawNumber, 10),
    commit: x,
    after,
  });
  if (judged.kind !== "candidate") return judged;

  const refusal = await judgeHistory({
    cwd,
    x,
    y: judged.commit,
    barriers,
    deadline,
    limits,
  });
  if (refusal !== undefined) return deploy(refusal);
  return { kind: "skip", number: judged.number, commit: judged.commit };
}

/** The one line the hook reads, and the exit code it reads beside it. */
export function verdictLine(verdict) {
  return verdict.kind === "skip"
    ? {
        line: `supersede: skipped for #${verdict.number} at ${verdict.commit}`,
        code: SKIP_EXIT_CODE,
      }
    : { line: `supersede: deploying, ${verdict.reason}`, code: 0 };
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

async function main() {
  const [after, ...barriers] = process.argv.slice(2);
  const token = await readStdin(process.stdin, DEFAULT_LIMITS.readMs);
  if (token === undefined) {
    return deploy("the read token did not arrive on stdin");
  }
  return decide({
    env: process.env,
    token: token.replace(/\r?\n$/, ""),
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
 * deploying.
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
  let verdict;
  try {
    verdict = await main();
  } catch (err) {
    verdict = deploy(
      `the check stopped on ${err instanceof Error ? err.name : "a non-error"}`,
    );
  }
  const { line, code } = verdictLine(verdict);
  process.stdout.write(`${line}\n`, () => process.exit(code));
}
