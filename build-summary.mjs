#!/usr/bin/env node
/**
 * Summarises the image builds a deploy step ran, from the `fjall` builder's
 * BuildKit history, as one table row per image. The Fjall deploy action and
 * the Buildkite plugin run it after the CLI step, whatever that step's
 * result, and never let it change the deploy's exit code.
 *
 *   node build-summary.mjs --ci github|buildkite --since <epoch s>
 *     --checkout <dir> [--record-dir <dir>] [--summary-out <file>]
 *     [--outputs <file>]
 *
 * It reads the builder, never the CLI, so it works under any CLI major.
 *
 * 1. `docker buildx version`. Below 0.21.0 it prints one line and stops.
 * 2. `docker buildx history ls --format json`. It keeps each record created
 *    no more than 5 s before `--since` whose ref, the last segment buildx
 *    prints, is 25 lower case letters and digits. Nothing else from the list
 *    reaches argv.
 * 3. `docker version`, for the daemon's platform.
 * 4. For each kept record in build order, at most 20 shown,
 *    `docker buildx history inspect --format json` with the checkout as its
 *    cwd. buildx prints `Context` relative to the cwd only when the context
 *    is under it, so a record whose `Context` is absolute, `..`, outside or
 *    missing came from another checkout and is left out and counted. Then
 *    `docker buildx history logs --progress rawjson`, read from whichever
 *    stream holds JSON (stderr on buildx 0.37.2), and the SLSA v1 provenance
 *    attachment when the record lists one, for its `builderPlatform` alone.
 * 5. With `--record-dir`, buildx 0.23.0 or later and budget left,
 *    `docker buildx history export` writes the shown records to one
 *    `fjall-build-record-<8 hex>.dockerbuild`. `--finalize` first shipped in
 *    buildx 0.24.0, so 0.23 exports without it.
 *
 * Every buildx call passes `--builder fjall`. Every docker call runs with no
 * shell, gets SIGTERM at 15 s and SIGKILL 2 s later, tracked by the `exit`
 * event, and the whole run shares one 30 s budget, the table's reads first.
 *
 * BuildKit names a RUN step from its instruction with build arg values
 * expanded, and the module has no mask it can load. So nothing it prints
 * comes from operator text. It never reads `BuildArgs`, `Name`, `Target` or
 * `Dockerfile`, and reads `Context`, a stage name and a cache import's error
 * only to decide, keeping none of them. A row reads `image N (<platform>)`
 * and a step `[n/m] <KEYWORD>`.
 * What it prints is numbers, fixed words, platforms and refs that passed
 * their shape, and a buildx version that passed its own.
 *
 * Phases are windows on the builder's clock and overlap. Steps merge by
 * digest, then by label, because a target built beside another reports the
 * other's run of a shared step under a second digest. A step is cached when
 * any report says so, and failed when any carries an error. FROM is never
 * counted.
 *
 * It exits 64, with one line on stderr naming the flag and the rule, for a
 * malformed invocation, and 0 on every other outcome. Each outcome it could
 * not complete prints one line naming the cause and the cure.
 *
 * Measured on buildx 0.37.2 over BuildKit 0.34.2 in November 2026. Older
 * shapes are unverified, and an unreadable one degrades to one line.
 *
 * It stands alone like resolve-fjall-engine.mjs. The plugin ships with no
 * node_modules, so it imports only Node's own modules.
 */
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { appendFileSync, realpathSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const USAGE_EXIT_CODE = 64;
export const BUILDER = "fjall";
export const TABLE_FLOOR = "0.21.0";
export const RECORD_FLOOR = "0.23.0";
export const FINALIZE_FLOOR = "0.24.0";
export const MAX_IMAGES = 20;
export const SINCE_SLACK_SECONDS = 5;
export const PROVENANCE_TYPE = "https://slsa.dev/provenance/v1";
export const DEFAULT_LIMITS = Object.freeze({
  callMs: 15_000,
  graceMs: 2_000,
  totalMs: 30_000,
});
/**
 * A counted step's label, as BuildKit names a Dockerfile step's vertex. BuildKit
 * puts the platform in a label only when one build makes several, which no
 * Fjall build does.
 */
export const STEP_PATTERN =
  /^\[(?:([^\s\]]+)\s+|\s*)(\d+)\/(\d+)\]\s+([A-Z]+)\b/;
/** The runner each platform builds on natively, as `ciWorkflowTemplate` writes it. */
export const GITHUB_NATIVE_RUNNERS = Object.freeze({
  "linux/arm64": "ubuntu-24.04-arm",
  "linux/amd64": "ubuntu-24.04",
});

const MAX_OUTPUT_BYTES = 32 * 1024 * 1024;
const HISTORY_REF = /^[a-z0-9]{25}$/;
const PLATFORM = /^[a-z0-9]+\/[a-z0-9_]+(?:\/[a-z0-9]+)?$/;
const SHOWN_KEYWORDS = new Set(["RUN", "COPY", "ADD", "WORKDIR"]);
const FLAGS = [
  "--ci",
  "--since",
  "--checkout",
  "--record-dir",
  "--summary-out",
  "--outputs",
];
const REQUIRED_FLAGS = ["--ci", "--since", "--checkout"];
const CI_KINDS = ["github", "buildkite"];
const WHOLE_SECONDS = /^[0-9]{1,12}$/;
const NO_BUILDER = /no builder "fjall" found/;
const CONTEXT_VERTEX = "[internal] load build context";
const CONTEXT_STATUS = "transferring context:";
const LOOKUP_PREFIX = "importing cache manifest from ";
// Measured on buildx 0.37.2 with BuildKit 0.34.2 on 12 November 2026, a step
// BuildKit stopped, because a sibling stage failed or the client went away,
// ends its error with this, after the exit code its process was killed with.
const CANCELLED_ERROR = /context canceled$/;
const IMAGE_EXPORT = "exporting to image";
const CACHE_EXPORT_PREFIX = "exporting cache to ";
const PUSH_STATUS_PREFIX = "pushing ";
const LAYER_STATUS_PREFIX = "writing layer ";
const LOOKUP_OUTCOMES = ["found", "refused", "failed", "none-found"];
const LOOKUP_WORDS = Object.freeze({
  found: "found",
  "none-found": "none found",
  refused: "refused",
  failed: "failed",
});
const BUCKETS = ["cached", "rebuilt", "failed", "unfinished"];

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * The invocation as options, or the rule it broke. A refusal names a flag,
 * or an argument by its position, and never a value.
 */
export function parseArgs(argv) {
  const refuse = (message) => ({ ok: false, message });
  const seen = new Map();
  for (let i = 0; i < argv.length; i += 1) {
    const flag = argv[i];
    if (!FLAGS.includes(flag)) {
      return refuse(
        `argument ${i + 1} is not a flag build-summary.mjs takes (${FLAGS.join(", ")})`,
      );
    }
    if (seen.has(flag)) return refuse(`${flag} is given more than once`);
    const value = argv[i + 1];
    if (value === undefined || value === "" || FLAGS.includes(value)) {
      return refuse(`${flag} needs a value after it`);
    }
    seen.set(flag, value);
    i += 1;
  }
  for (const flag of REQUIRED_FLAGS) {
    if (!seen.has(flag)) return refuse(`${flag} is required`);
  }
  if (!CI_KINDS.includes(seen.get("--ci"))) {
    return refuse("--ci takes github or buildkite");
  }
  if (!WHOLE_SECONDS.test(seen.get("--since"))) {
    return refuse("--since takes a whole number of seconds since the epoch");
  }
  return {
    ok: true,
    options: {
      ci: seen.get("--ci"),
      since: Number.parseInt(seen.get("--since"), 10),
      checkout: seen.get("--checkout"),
      recordDir: seen.get("--record-dir"),
      summaryOut: seen.get("--summary-out"),
      outputs: seen.get("--outputs"),
    },
  };
}

/**
 * The version in `docker buildx version`'s answer, by the grammar of
 * `extractBuildxVersion` in `util/src/docker/DockerCli.daemon.ts`, or null.
 */
export function parseBuildxVersion(stdout) {
  if (typeof stdout !== "string") return null;
  const match = /github\.com\/docker\/buildx\s+(v?\d+\.\d+\.\d+)/.exec(stdout);
  if (match !== null && match[1] !== undefined) return match[1];
  const fallback = /(\d+\.\d+\.\d+)/.exec(stdout);
  return fallback?.[1] ?? null;
}

function semver(version) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(version);
  if (match === null) return null;
  return [match[1], match[2], match[3]].map((part) =>
    Number.parseInt(part, 10),
  );
}

/** Whether `version` is at or above `floor`, or undefined when either does not parse. */
export function versionAtLeast(version, floor) {
  const observed = semver(String(version));
  const minimum = semver(String(floor));
  if (observed === null || minimum === null) return undefined;
  for (let i = 0; i < 3; i += 1) {
    if (observed[i] !== minimum[i]) return observed[i] > minimum[i];
  }
  return true;
}

/** Whether the buildx version allows the table, the record and `--finalize`. */
export function versionGate(stdout) {
  const raw = parseBuildxVersion(stdout);
  if (raw === null) return { kind: "unreadable" };
  return {
    kind: "read",
    version: raw.replace(/^v/, ""),
    table: versionAtLeast(raw, TABLE_FLOOR) === true,
    record: versionAtLeast(raw, RECORD_FLOOR) === true,
    finalize: versionAtLeast(raw, FINALIZE_FLOOR) === true,
  };
}

/**
 * `history ls --format json`, one object a line or one array, as records
 * with a 25 character ref and a creation time. Others are counted, never
 * kept. Returns `{ ok: false }` when the answer is not JSON.
 */
export function parseHistoryList(stdout) {
  const text = String(stdout).trim();
  let entries;
  try {
    entries = text.startsWith("[")
      ? JSON.parse(text)
      : text
          .split("\n")
          .filter((line) => line.trim() !== "")
          .map((line) => JSON.parse(line));
  } catch {
    return { ok: false };
  }
  if (!Array.isArray(entries)) return { ok: false };
  const records = [];
  let offShape = 0;
  for (const entry of entries) {
    const ref =
      isRecord(entry) && typeof entry.ref === "string"
        ? entry.ref.split("/").at(-1)
        : undefined;
    const createdMs =
      isRecord(entry) && typeof entry.created_at === "string"
        ? Date.parse(entry.created_at)
        : Number.NaN;
    if (
      ref === undefined ||
      !HISTORY_REF.test(ref) ||
      Number.isNaN(createdMs)
    ) {
      offShape += 1;
      continue;
    }
    records.push({ ref, createdMs });
  }
  return { ok: true, records, offShape };
}

/** The records created no more than 5 s before `since`, in build order. */
export function selectRecords(records, sinceSeconds) {
  const floor = (sinceSeconds - SINCE_SLACK_SECONDS) * 1000;
  return records
    .filter((record) => record.createdMs >= floor)
    .sort(
      (a, b) =>
        a.createdMs - b.createdMs ||
        (a.ref < b.ref ? -1 : a.ref > b.ref ? 1 : 0),
    );
}

/**
 * Whether an inspected `Context` names a directory under the checkout:
 * relative, not `..` or below it, and no URL.
 */
export function isCheckoutContext(context) {
  if (typeof context !== "string" || context === "" || context === "-") {
    return false;
  }
  if (context.startsWith("/") || context.startsWith("\\")) return false;
  if (/^[A-Za-z]:[\\/]/.test(context) || context.includes("://")) return false;
  return context !== ".." && !context.startsWith("../");
}

/** The fields of `history inspect --format json` the module reads, or null. */
export function readInspect(stdout) {
  let doc;
  try {
    doc = JSON.parse(stdout);
  } catch {
    return null;
  }
  if (!isRecord(doc)) return null;
  return {
    context: typeof doc.Context === "string" ? doc.Context : undefined,
    platforms: Array.isArray(doc.Platform)
      ? doc.Platform.filter((platform) => typeof platform === "string")
      : [],
    durationMs:
      typeof doc.Duration === "number" &&
      Number.isFinite(doc.Duration) &&
      doc.Duration >= 0
        ? Math.round(doc.Duration / 1e6)
        : undefined,
    status: typeof doc.Status === "string" ? doc.Status.toLowerCase() : "",
    hasProvenance:
      Array.isArray(doc.Attachments) &&
      doc.Attachments.some(
        (attachment) =>
          isRecord(attachment) && attachment.Type === PROVENANCE_TYPE,
      ),
  };
}

/** The provenance attachment's `builderPlatform`, or undefined. */
export function readBuilderPlatform(stdout) {
  try {
    const doc = JSON.parse(stdout);
    const platform = doc?.buildDefinition?.internalParameters?.builderPlatform;
    return typeof platform === "string" ? platform : undefined;
  } catch {
    return undefined;
  }
}

/**
 * The status objects of one rawjson text. A line that does not start with
 * `{` is skipped, since buildx prints warnings as text on the same stream.
 */
export function parseRawjson(text) {
  const objects = [];
  for (const line of String(text).split("\n")) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    let value;
    try {
      value = JSON.parse(trimmed);
    } catch {
      return { ok: false, reason: "malformed" };
    }
    if (!isRecord(value)) return { ok: false, reason: "malformed" };
    objects.push(value);
  }
  return objects.length === 0
    ? { ok: false, reason: "empty" }
    : { ok: true, objects };
}

/** The rawjson objects from whichever of the 2 streams holds them. */
export function readLogStreams({ stdout, stderr }) {
  const fromStderr = parseRawjson(stderr);
  if (fromStderr.ok) return fromStderr;
  const fromStdout = parseRawjson(stdout);
  if (fromStdout.ok) return fromStdout;
  return {
    ok: false,
    reason:
      fromStderr.reason === "malformed" || fromStdout.reason === "malformed"
        ? "malformed"
        : "empty",
  };
}

function timeOf(value) {
  if (typeof value !== "string") return undefined;
  const ms = Date.parse(value);
  return Number.isNaN(ms) || ms < 0 ? undefined : ms;
}

/**
 * A cache lookup's outcome from its error, which is read here and never
 * kept. Measured on buildx 0.37.2 with BuildKit 0.34.2 on 12 November 2026,
 * an absent cache held `not found`, and a registry that refused the read
 * ended the error with `401 Unauthorized` or `403 Forbidden`.
 */
export function classifyLookupError(error) {
  if (/not found/i.test(error)) return "none-found";
  if (/\b40[13]\b|denied|unauthori[sz]ed|forbidden/i.test(error)) {
    return "refused";
  }
  return "failed";
}

/**
 * Merges every object's vertices by digest, the earliest start and the
 * latest completion, cached when any report is, and failed when any carries
 * an error, and every status by its vertex and id, the largest `current`.
 */
export function mergeStatus(objects) {
  const vertices = new Map();
  const statuses = new Map();
  for (const object of objects) {
    for (const vertex of Array.isArray(object.vertexes)
      ? object.vertexes
      : []) {
      if (!isRecord(vertex) || typeof vertex.digest !== "string") continue;
      const merged = vertices.get(vertex.digest) ?? {
        digest: vertex.digest,
        name: undefined,
        startMs: undefined,
        endMs: undefined,
        cached: false,
        cancelled: false,
        errorKind: undefined,
      };
      if (merged.name === undefined && typeof vertex.name === "string") {
        merged.name = vertex.name;
      }
      const start = timeOf(vertex.started);
      if (start !== undefined && (merged.startMs ?? Infinity) > start) {
        merged.startMs = start;
      }
      const end = timeOf(vertex.completed);
      if (end !== undefined && (merged.endMs ?? -Infinity) < end) {
        merged.endMs = end;
      }
      if (vertex.cached === true) merged.cached = true;
      if (typeof vertex.error === "string" && vertex.error !== "") {
        if (CANCELLED_ERROR.test(vertex.error)) merged.cancelled = true;
        else merged.errorKind = classifyLookupError(vertex.error);
      }
      vertices.set(vertex.digest, merged);
    }
    for (const status of Array.isArray(object.statuses)
      ? object.statuses
      : []) {
      if (!isRecord(status) || typeof status.id !== "string") continue;
      const vertex = typeof status.vertex === "string" ? status.vertex : "";
      const key = `${vertex}\u0000${status.id}`;
      const merged = statuses.get(key) ?? {
        id: status.id,
        vertex,
        current: 0,
        startMs: undefined,
        endMs: undefined,
      };
      if (
        typeof status.current === "number" &&
        status.current > merged.current
      ) {
        merged.current = status.current;
      }
      const start = timeOf(status.started);
      if (start !== undefined && (merged.startMs ?? Infinity) > start) {
        merged.startMs = start;
      }
      const end = timeOf(status.completed);
      if (end !== undefined && (merged.endMs ?? -Infinity) < end) {
        merged.endMs = end;
      }
      statuses.set(key, merged);
    }
  }
  return { vertices, statuses };
}

/** A vertex name's step label, or undefined when it is no Dockerfile step. */
export function parseStepLabel(name) {
  if (typeof name !== "string") return undefined;
  const match = STEP_PATTERN.exec(name);
  if (match === null) return undefined;
  return {
    stage: match[1],
    n: Number.parseInt(match[2], 10),
    m: Number.parseInt(match[3], 10),
    keyword: match[4],
  };
}

/** The label the summary shows, `[n/m] KEYWORD` with no stage name. */
export function stepLabel(label) {
  const keyword = SHOWN_KEYWORDS.has(label.keyword) ? label.keyword : "step";
  return `[${label.n}/${label.m}] ${keyword}`;
}

/**
 * The counted steps, FROM left out, each in one bucket. Failed wins over
 * cached, cached over rebuilt, and a step that never completed, or that
 * BuildKit stopped, is unfinished.
 */
export function countedSteps(vertices) {
  const groups = new Map();
  for (const vertex of vertices.values()) {
    const label = parseStepLabel(vertex.name);
    if (label === undefined || label.keyword === "FROM") continue;
    const key = `${label.stage ?? ""}\u0000${label.n}/${label.m}\u0000${label.keyword}`;
    const group = groups.get(key) ?? {
      label,
      startMs: undefined,
      endMs: undefined,
      cached: false,
      failed: false,
      cancelled: false,
    };
    if (
      vertex.startMs !== undefined &&
      (group.startMs ?? Infinity) > vertex.startMs
    ) {
      group.startMs = vertex.startMs;
    }
    if (
      vertex.endMs !== undefined &&
      (group.endMs ?? -Infinity) < vertex.endMs
    ) {
      group.endMs = vertex.endMs;
    }
    if (vertex.cached) group.cached = true;
    if (vertex.errorKind !== undefined) group.failed = true;
    if (vertex.cancelled) group.cancelled = true;
    groups.set(key, group);
  }
  return [...groups.values()].map((group) => {
    let bucket = "unfinished";
    if (group.failed) bucket = "failed";
    else if (group.cancelled) bucket = "unfinished";
    else if (group.cached) bucket = "cached";
    else if (group.endMs !== undefined) bucket = "rebuilt";
    const timed = group.startMs !== undefined && group.endMs !== undefined;
    return {
      label: stepLabel(group.label),
      n: group.label.n,
      bucket,
      startMs: group.startMs,
      endMs: group.endMs,
      ms: timed ? Math.max(0, group.endMs - group.startMs) : undefined,
    };
  });
}

/** How many counted steps fall in each bucket. */
export function bucketCounts(steps) {
  const counts = { cached: 0, rebuilt: 0, failed: 0, unfinished: 0 };
  for (const step of steps) counts[step.bucket] += 1;
  return { ...counts, total: BUCKETS.reduce((sum, b) => sum + counts[b], 0) };
}

/** The time a set of windows covers, each overlap counted once. */
export function unionMs(windows) {
  const timed = windows
    .filter((w) => w.startMs !== undefined && w.endMs !== undefined)
    .map((w) => [w.startMs, Math.max(w.startMs, w.endMs)])
    .sort((a, b) => a[0] - b[0]);
  let total = 0;
  let open;
  for (const [start, end] of timed) {
    if (open === undefined || start > open[1]) {
      if (open !== undefined) total += open[1] - open[0];
      open = [start, end];
    } else if (end > open[1]) {
      open[1] = end;
    }
  }
  if (open !== undefined) total += open[1] - open[0];
  return total;
}

/**
 * A cache lookup's outcome over its vertices. It is found when any ended
 * without an error, then refused, failed and none found in that order, and
 * undefined when none ended or BuildKit stopped each one.
 */
function lookupOutcome(lookups) {
  const outcomes = new Set();
  for (const vertex of lookups) {
    if (vertex.cancelled) continue;
    if (vertex.errorKind !== undefined) outcomes.add(vertex.errorKind);
    else if (vertex.endMs !== undefined) outcomes.add("found");
  }
  return LOOKUP_OUTCOMES.find((outcome) => outcomes.has(outcome));
}

/** Each phase's window on the builder's clock, from merged vertices and statuses. */
export function phasesOf({ vertices, statuses }, steps) {
  const all = [...vertices.values()].filter((v) => typeof v.name === "string");
  const named = (test) => all.filter((vertex) => test(vertex.name));
  const statusesOf = (group, test) => {
    const digests = new Set(group.map((vertex) => vertex.digest));
    return [...statuses.values()].filter(
      (status) => digests.has(status.vertex) && test(status.id),
    );
  };
  const context = named((name) => name === CONTEXT_VERTEX);
  const lookups = named((name) => name.startsWith(LOOKUP_PREFIX));
  const images = named((name) => name === IMAGE_EXPORT);
  const caches = named((name) => name.startsWith(CACHE_EXPORT_PREFIX));
  const cached = steps.filter((step) => step.bucket === "cached");
  const rebuilt = steps.filter(
    (step) => step.bucket === "rebuilt" || step.bucket === "failed",
  );
  return {
    context:
      context.length === 0
        ? undefined
        : {
            ms: unionMs(context),
            bytes: Math.max(
              0,
              ...statusesOf(context, (id) => id === CONTEXT_STATUS).map(
                (status) => status.current,
              ),
            ),
          },
    cacheLookup:
      lookups.length === 0
        ? undefined
        : { ms: unionMs(lookups), outcome: lookupOutcome(lookups) },
    cachePull: cached.length === 0 ? undefined : { ms: unionMs(cached) },
    rebuilt: rebuilt.length === 0 ? undefined : { ms: unionMs(rebuilt) },
    imagePush:
      images.length === 0
        ? undefined
        : {
            ms: unionMs(images),
            pushMs: unionMs(
              statusesOf(images, (id) => id.startsWith(PUSH_STATUS_PREFIX)),
            ),
          },
    cacheExport:
      caches.length === 0
        ? undefined
        : {
            ms: unionMs(caches),
            layers: statusesOf(caches, (id) =>
              id.startsWith(LAYER_STATUS_PREFIX),
            ).length,
          },
  };
}

/** The 3 longest rebuilt or failed steps of at least 1 s, longest first. */
export function slowestSteps(steps, limit = 3) {
  return steps
    .filter(
      (step) =>
        (step.bucket === "rebuilt" || step.bucket === "failed") &&
        step.ms !== undefined &&
        step.ms >= 1000,
    )
    .sort((a, b) => b.ms - a.ms || a.startMs - b.startMs)
    .slice(0, limit);
}

/**
 * The earliest started step that was rebuilt or failed. Any rebuilt step
 * upstream of it would have started earlier, so it broke the cache chain.
 */
export function firstMiss(steps) {
  let first;
  for (const step of steps) {
    if (step.bucket !== "rebuilt" && step.bucket !== "failed") continue;
    if (step.startMs === undefined) continue;
    if (
      first === undefined ||
      step.startMs < first.startMs ||
      (step.startMs === first.startMs && step.n < first.n)
    ) {
      first = step;
    }
  }
  return first;
}

/** A platform as `os/arch`, with the architecture's Docker name, or undefined. */
export function normalisePlatform(value) {
  if (typeof value !== "string") return undefined;
  const lowered = value.trim().toLowerCase();
  if (!PLATFORM.test(lowered)) return undefined;
  const [os, arch, variant] = lowered.split("/");
  const name = { x86_64: "amd64", aarch64: "arm64" }[arch] ?? arch;
  if (name === "arm64" && (variant === undefined || variant === "v8")) {
    return `${os}/arm64`;
  }
  return variant === undefined ? `${os}/${name}` : `${os}/${name}/${variant}`;
}

/**
 * Native when every target is the daemon's platform, emulated when one is
 * not, and unknown when either side is missing or the provenance's builder
 * platform disagrees with the daemon.
 */
export function emulationVerdict(native, targets, builderPlatform) {
  const host = normalisePlatform(native);
  const wanted = targets.map(normalisePlatform);
  if (host === undefined || wanted.length === 0 || wanted.includes(undefined)) {
    return { verdict: "unknown", targets: wanted.filter(Boolean) };
  }
  if (
    builderPlatform !== undefined &&
    normalisePlatform(builderPlatform) !== host
  ) {
    return { verdict: "unknown", targets: wanted };
  }
  return {
    verdict: wanted.every((target) => target === host) ? "native" : "emulated",
    host,
    targets: wanted,
  };
}

/** The cure for a build emulated on `host` for `target`, on this CI. */
export function emulationCure(ci, target) {
  if (ci === "github") {
    const runner = GITHUB_NATIVE_RUNNERS[target];
    return runner === undefined
      ? `Run this job on a ${target} runner to build it natively.`
      : `Run this job on \`${runner}\` to build it natively.`;
  }
  return `Run this step on a ${target} agent queue to build it natively.`;
}

/** One record's row, with its phases, steps and emulation verdict. */
export function summariseRecord({
  index,
  ref,
  inspect,
  objects,
  native,
  builderPlatform,
}) {
  const emulation = emulationVerdict(
    native,
    inspect.platforms,
    builderPlatform,
  );
  const base = {
    index,
    ref,
    platform:
      emulation.targets.length === 0
        ? "unknown platform"
        : emulation.targets.join(","),
    emulation,
    status: inspect.status,
    totalMs: inspect.durationMs,
  };
  if (objects === undefined) return { ...base, read: false };
  const merged = mergeStatus(objects);
  const steps = countedSteps(merged.vertices);
  return {
    ...base,
    read: true,
    phases: phasesOf(merged, steps),
    counts: bucketCounts(steps),
    slowest: slowestSteps(steps),
    firstMiss: firstMiss(steps),
    failedSteps: steps
      .filter((step) => step.bucket === "failed")
      .sort((a, b) => a.n - b.n)
      .map((step) => step.label),
  };
}

/** Milliseconds as seconds to 1 place, or minutes and seconds from a minute. */
export function formatDuration(ms) {
  if (ms < 59_950) return `${(ms / 1000).toFixed(1)} s`;
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)} min ${String(seconds % 60).padStart(2, "0")} s`;
}

/** Bytes in binary units to 1 place. */
export function formatBytes(bytes) {
  const units = ["KiB", "MiB", "GiB"];
  if (bytes < 1024) return `${bytes} B`;
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

const NONE = "none";

function totalCell(row) {
  if (row.status === "running") return "running";
  const time =
    row.totalMs === undefined ? "unread" : formatDuration(row.totalMs);
  if (row.status === "failed") return `${time}, failed`;
  return row.status === "canceled" ? `${time}, cancelled` : time;
}

function cachedCell(counts) {
  if (counts.total === 0) return NONE;
  const share = Math.round((counts.cached * 100) / counts.total);
  const extra = [];
  if (counts.failed > 0) extra.push(`${counts.failed} failed`);
  if (counts.unfinished > 0) extra.push(`${counts.unfinished} unfinished`);
  return [`${counts.cached} of ${counts.total} (${share}%)`, ...extra].join(
    ", ",
  );
}

/** The table cells of one row, in the column order. */
export function rowCells(row) {
  const head = [
    `image ${row.index} (${row.platform})`,
    row.emulation.verdict === "emulated"
      ? `emulated on ${row.emulation.host}`
      : row.emulation.verdict,
    totalCell(row),
  ];
  if (!row.read) return [...head, ...Array(7).fill("unread")];
  const { phases } = row;
  const timed = (phase, detail) =>
    phase === undefined
      ? NONE
      : [
          formatDuration(phase.ms),
          ...(detail === undefined ? [] : [detail]),
        ].join(", ");
  return [
    ...head,
    timed(
      phases.context,
      phases.context === undefined
        ? undefined
        : formatBytes(phases.context.bytes),
    ),
    timed(
      phases.cacheLookup,
      phases.cacheLookup === undefined
        ? undefined
        : phases.cacheLookup.outcome === undefined
          ? "not finished"
          : LOOKUP_WORDS[phases.cacheLookup.outcome],
    ),
    timed(phases.cachePull),
    timed(phases.rebuilt),
    cachedCell(row.counts),
    timed(
      phases.imagePush,
      phases.imagePush === undefined || phases.imagePush.pushMs === 0
        ? undefined
        : `push ${formatDuration(phases.imagePush.pushMs)}`,
    ),
    timed(
      phases.cacheExport,
      phases.cacheExport === undefined
        ? undefined
        : `${phases.cacheExport.layers} ${phases.cacheExport.layers === 1 ? "layer" : "layers"}`,
    ),
  ];
}

const COLUMNS = [
  "Image",
  "Built",
  "Total",
  "Context",
  "Cache lookup",
  "Cache pull",
  "Rebuilt steps",
  "Cached",
  "Image push",
  "Cache export",
];

/** The log command for one row's record. */
export function logCommand(ref) {
  return `docker buildx history logs --builder ${BUILDER} ${ref}`;
}

function listWords(items) {
  if (items.length <= 1) return items.join("");
  return `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}

function stepNotes(row) {
  if (!row.read) {
    return [
      `image ${row.index}'s build log could not be read, so its phases are missing.`,
    ];
  }
  const notes = [];
  if (row.slowest.length > 0) {
    notes.push(
      `image ${row.index}'s slowest ${row.slowest.length === 1 ? "step was" : "steps were"} ${listWords(
        row.slowest.map(
          (step) => `\`${step.label}\` ${formatDuration(step.ms)}`,
        ),
      )}.`,
    );
  }
  if (row.firstMiss !== undefined) {
    notes.push(
      `image ${row.index}'s first cache miss was \`${row.firstMiss.label}\`, so the steps after it in its stage could not come from the cache.`,
    );
  }
  if (row.failedSteps.length > 0) {
    notes.push(
      `image ${row.index} failed at ${listWords(row.failedSteps.map((label) => `\`${label}\``))}.`,
    );
  }
  return notes;
}

function emulationNotes(ci, rows) {
  const notes = [];
  const emulated = new Map();
  for (const row of rows) {
    if (row.emulation.verdict !== "emulated") continue;
    for (const target of row.emulation.targets) {
      if (target === row.emulation.host) continue;
      const key = `${target} on ${row.emulation.host}`;
      const entry = emulated.get(key) ?? {
        target,
        host: row.emulation.host,
        images: [],
      };
      entry.images.push(`image ${row.index}`);
      emulated.set(key, entry);
    }
  }
  for (const { target, host, images } of emulated.values()) {
    notes.push(
      `${listWords(images)} built ${target} under emulation on this ${host} ${ci === "github" ? "runner" : "agent"}, which runs RUN steps much more slowly. ${emulationCure(ci, target)}`,
    );
  }
  const unknown = rows
    .filter((row) => row.emulation.verdict === "unknown")
    .map((row) => `image ${row.index}`);
  if (unknown.length > 0) {
    notes.push(
      `Whether ${listWords(unknown)} ran under emulation is unknown, because the runner's or the builder's platform could not be read.`,
    );
  }
  return notes;
}

function lookupNotes(rows) {
  const by = { "none-found": [], refused: [], failed: [] };
  for (const row of rows) {
    const outcome = row.read ? row.phases.cacheLookup?.outcome : undefined;
    if (outcome !== undefined && outcome !== "found") {
      by[outcome].push(`image ${row.index}`);
    }
  }
  const notes = [];
  if (by["none-found"].length > 0) {
    notes.push(
      `${listWords(by["none-found"])} found no build cache to import, as on a first build or once the cache has expired.`,
    );
  }
  if (by.refused.length > 0) {
    notes.push(
      `The registry refused ${listWords(by.refused)}'s cache import. Check that the deploy role can pull from the cache repository.`,
    );
  }
  if (by.failed.length > 0) {
    notes.push(
      `${listWords(by.failed)}'s cache import failed. Its full log says why.`,
    );
  }
  return notes;
}

function plural(count, one, many) {
  return `${count} ${count === 1 ? one : many}`;
}

function leftOutNotes(left, budgetMs) {
  const notes = [];
  if (left.outside > 0) {
    notes.push(
      `${plural(left.outside, "build", "builds")} from outside this checkout ${left.outside === 1 ? "is" : "are"} left out.`,
    );
  }
  if (left.unreadable > 0) {
    notes.push(
      `${plural(left.unreadable, "build record", "build records")} could not be read and ${left.unreadable === 1 ? "is" : "are"} left out.`,
    );
  }
  if (left.beyondCap > 0) {
    notes.push(
      `${plural(left.beyondCap, "more build", "more builds")} past the first ${MAX_IMAGES} ${left.beyondCap === 1 ? "is" : "are"} not shown.`,
    );
  }
  if (left.unread > 0) {
    notes.push(
      `${plural(left.unread, "more build record", "more build records")} could not be read within the ${budgetMs / 1000} s budget.`,
    );
  }
  return notes;
}

/** The GitHub flavoured markdown the step summary or annotation shows. */
export function renderSummary({
  ci,
  rows,
  left,
  budgetMs = DEFAULT_LIMITS.totalMs,
}) {
  const lines = [
    "### Image builds",
    "",
    `| ${COLUMNS.join(" | ")} |`,
    `| ${COLUMNS.map(() => "---").join(" | ")} |`,
    ...rows.map((row) => `| ${rowCells(row).join(" | ")} |`),
    "",
  ];
  const notes = [
    ...rows.flatMap(stepNotes),
    ...emulationNotes(ci, rows),
    ...lookupNotes(rows),
    ...leftOutNotes(left, budgetMs),
    "Phases are windows on the builder's clock and overlap, so they don't add up to the total. Cache pull is an upper bound, since a cached step's window counts waiting as well as pulling.",
    ...rows.map(
      (row) =>
        `image ${row.index}'s full build log is \`${logCommand(row.ref)}\`.`,
    ),
  ];
  return `${[...lines, ...notes.map((note) => `- ${capitalise(note)}`)].join("\n")}\n`;
}

/** A note that starts with a row's label starts its sentence in capitals. */
function capitalise(text) {
  return `${text.charAt(0).toUpperCase()}${text.slice(1)}`;
}

/**
 * Where a later docker buildx history command finds this run's builds. A
 * Buildkite step is a job of its own, often on another agent.
 */
const HISTORY_HOST = Object.freeze({
  github: "in a later step of this job",
  buildkite: "on this agent's Docker host",
});

/** The line for records the run's budget left unread. */
function budgetLine(limits, unread, ci) {
  return `Build summary ran out of its ${limits.totalMs / 1000} s budget with ${plural(unread, "build record", "build records")} unread. Run docker buildx history ls --builder ${BUILDER} ${HISTORY_HOST[ci]} to list them.`;
}

/** How a docker call ended, for a line that names the cause. */
function callFailure(verb, result, limits) {
  if (result.budget) {
    return `${verb} did not run within the ${limits.totalMs / 1000} s budget`;
  }
  if (result.spawnFailed)
    return `${verb} did not start, so docker is not on the PATH`;
  if (result.timedOut)
    return `${verb} did not answer within ${limits.callMs / 1000} s`;
  if (result.overflowed) return `${verb} printed more than the summary reads`;
  return result.code === null
    ? `${verb} did not run to an exit`
    : `${verb} exited ${result.code}`;
}

/**
 * Runs docker with no shell, bounded. SIGTERM at `timeoutMs`, SIGKILL
 * `graceMs` later unless the `exit` event has come, and a settle `graceMs`
 * after that whatever the child does, so a run never waits on a child past
 * its bound. With `cwd`, `PWD` names it too, because buildx resolves its
 * working directory from `PWD` first. Resolves, never rejects.
 */
export function runDocker(
  args,
  {
    cwd,
    timeoutMs = DEFAULT_LIMITS.callMs,
    graceMs = DEFAULT_LIMITS.graceMs,
    spawnImpl = spawn,
    env = process.env,
  } = {},
) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawnImpl("docker", args, {
        cwd,
        shell: false,
        stdio: ["ignore", "pipe", "pipe"],
        env: cwd === undefined ? env : { ...env, PWD: cwd },
      });
    } catch {
      resolve({
        code: null,
        stdout: "",
        stderr: "",
        timedOut: false,
        spawnFailed: true,
      });
      return;
    }
    const out = [];
    const err = [];
    let size = 0;
    let timedOut = false;
    let overflowed = false;
    let exited = false;
    let settled = false;
    const timers = [];
    const settle = (fields) => {
      if (settled) return;
      settled = true;
      for (const timer of timers) clearTimeout(timer);
      resolve({
        code: null,
        stdout: Buffer.concat(out).toString("utf8"),
        stderr: Buffer.concat(err).toString("utf8"),
        timedOut,
        overflowed,
        spawnFailed: false,
        ...fields,
      });
    };
    const stop = () => {
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.kill("SIGTERM");
      timers.push(
        setTimeout(() => {
          if (!exited) child.kill("SIGKILL");
          timers.push(setTimeout(() => settle({}), graceMs));
        }, graceMs),
      );
    };
    timers.push(
      setTimeout(() => {
        timedOut = true;
        stop();
      }, timeoutMs),
    );
    const collect = (into) => (chunk) => {
      size += chunk.length;
      if (size > MAX_OUTPUT_BYTES) {
        if (!overflowed && !timedOut) {
          overflowed = true;
          stop();
        }
        return;
      }
      into.push(chunk);
    };
    child.stdout?.on("data", collect(out));
    child.stderr?.on("data", collect(err));
    child.once("exit", () => {
      exited = true;
    });
    child.once("error", () => settle({ spawnFailed: !exited && size === 0 }));
    child.once("close", (code) => settle({ code: overflowed ? null : code }));
  });
}

function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

/**
 * The whole run. Returns the lines for stdout, and appends the table to
 * `summaryOut` and the record's path to `outputs` through `deps`, which
 * the tests replace. Never rejects on a docker outcome.
 */
export async function run(options, deps = {}) {
  const limits = deps.limits ?? DEFAULT_LIMITS;
  const now = deps.now ?? Date.now;
  const docker =
    deps.docker ??
    ((args, opts) => runDocker(args, { ...opts, graceMs: limits.graceMs }));
  const appendFile = deps.appendFile ?? appendFileSync;
  const realpath = deps.realpath ?? realpathSync;
  const directoryExists = deps.isDirectory ?? isDirectory;
  const randomHex = deps.randomHex ?? (() => randomBytes(4).toString("hex"));
  const lines = [];
  const deadline = now() + limits.totalMs;
  // A call the budget cut short reads as the budget, never as a fault.
  const call = async (args, cwd) => {
    const remaining = deadline - now();
    if (remaining <= 0) return { budget: true };
    const timeoutMs = Math.min(limits.callMs, remaining);
    const result = await docker(args, {
      ...(cwd !== undefined && { cwd }),
      timeoutMs,
    });
    return result.timedOut && timeoutMs < limits.callMs
      ? { budget: true }
      : result;
  };
  const skip = (cause, cure) => {
    lines.push(`Build summary skipped because ${cause}. ${cure}`);
    return { lines };
  };
  const install = `Install Docker Buildx ${TABLE_FLOOR} or later on this runner.`;

  let checkout;
  try {
    checkout = realpath(options.checkout);
  } catch {
    return skip(
      "the checkout directory could not be read",
      "Pass the repository's checkout as --checkout.",
    );
  }

  const version = await call(["buildx", "version", "--builder", BUILDER]);
  if (version.code !== 0) {
    return skip(callFailure("docker buildx version", version, limits), install);
  }
  const gate = versionGate(version.stdout);
  if (gate.kind === "unreadable") {
    return skip("the docker buildx version could not be read", install);
  }
  if (!gate.table) {
    return skip(
      `Docker Buildx ${gate.version} is older than ${TABLE_FLOOR}`,
      install,
    );
  }

  const listed = await call([
    "buildx",
    "history",
    "ls",
    "--builder",
    BUILDER,
    "--format",
    "json",
  ]);
  if (listed.code !== 0) {
    if (NO_BUILDER.test(listed.stderr ?? "")) {
      lines.push("Build summary found no image build in this step.");
      return { lines };
    }
    return skip(
      callFailure("docker buildx history ls", listed, limits),
      `Run docker buildx history ls --builder ${BUILDER} ${HISTORY_HOST[options.ci]} to see why.`,
    );
  }
  const history = parseHistoryList(listed.stdout);
  if (!history.ok) {
    return skip("docker buildx history ls did not print JSON", install);
  }
  const selected = selectRecords(history.records, options.since);
  if (selected.length === 0) {
    lines.push("Build summary found no image build in this step.");
    return { lines };
  }

  const daemon = await call([
    "version",
    "--format",
    "{{.Server.Os}}/{{.Server.Arch}}",
  ]);
  const native = daemon.code === 0 ? daemon.stdout.trim() : undefined;

  const rows = [];
  const left = { outside: 0, unreadable: 0, beyondCap: 0, unread: 0 };
  for (let i = 0; i < selected.length; i += 1) {
    const { ref } = selected[i];
    if (rows.length === MAX_IMAGES) {
      left.beyondCap = selected.length - i;
      break;
    }
    const inspected = await call(
      [
        "buildx",
        "history",
        "inspect",
        "--builder",
        BUILDER,
        "--format",
        "json",
        ref,
      ],
      checkout,
    );
    if (inspected.budget) {
      left.unread = selected.length - i;
      break;
    }
    const inspect = inspected.code === 0 ? readInspect(inspected.stdout) : null;
    if (inspect === null) {
      left.unreadable += 1;
      continue;
    }
    if (!isCheckoutContext(inspect.context)) {
      left.outside += 1;
      continue;
    }
    const logs = await call([
      "buildx",
      "history",
      "logs",
      "--builder",
      BUILDER,
      "--progress",
      "rawjson",
      ref,
    ]);
    if (logs.budget) {
      left.unread = selected.length - i;
      break;
    }
    const streams = logs.code === 0 ? readLogStreams(logs) : { ok: false };
    let builderPlatform;
    if (inspect.hasProvenance) {
      const provenance = await call([
        "buildx",
        "history",
        "inspect",
        "attachment",
        "--builder",
        BUILDER,
        "--type",
        PROVENANCE_TYPE,
        ref,
      ]);
      if (provenance.code === 0) {
        builderPlatform = readBuilderPlatform(provenance.stdout);
      }
    }
    rows.push(
      summariseRecord({
        index: rows.length + 1,
        ref,
        inspect,
        objects: streams.ok ? streams.objects : undefined,
        native,
        builderPlatform,
      }),
    );
  }

  if (rows.length === 0) {
    lines.push(
      left.unread > 0
        ? budgetLine(limits, left.unread, options.ci)
        : `Build summary found no image build from this checkout in this step, and left out ${listWords(
            [
              ...(left.outside > 0
                ? [`${plural(left.outside, "build", "builds")} from outside it`]
                : []),
              ...(left.unreadable > 0
                ? [
                    `${plural(left.unreadable, "build record", "build records")} it could not read`,
                  ]
                : []),
            ],
          )}.`,
    );
    return { lines };
  }

  const summary = renderSummary({
    ci: options.ci,
    rows,
    left,
    budgetMs: limits.totalMs,
  });
  const images = plural(rows.length, "image build", "image builds");
  let written = false;
  if (options.summaryOut !== undefined) {
    try {
      appendFile(options.summaryOut, summary);
      written = true;
      lines.push(`Build summary of ${images} written to the summary file.`);
    } catch {
      lines.push(
        `Build summary of ${images} could not be added to the summary file, so it follows here.`,
      );
    }
  }
  if (!written) lines.push(summary.trimEnd());
  if (left.unread > 0) lines.push(budgetLine(limits, left.unread, options.ci));
  for (const row of rows) {
    lines.push(
      `Run ${logCommand(row.ref)} for image ${row.index}'s full build log.`,
    );
  }

  if (options.recordDir !== undefined) {
    lines.push(
      await writeRecord({
        options,
        gate,
        rows,
        call,
        limits,
        appendFile,
        directoryExists,
        randomHex,
      }),
    );
  }
  return { lines };
}

async function writeRecord({
  options,
  gate,
  rows,
  call,
  limits,
  appendFile,
  directoryExists,
  randomHex,
}) {
  const skipped = (cause) => `Build record skipped because ${cause}.`;
  if (!gate.record) {
    return `${skipped(`Docker Buildx ${gate.version} is older than ${RECORD_FLOOR}, which docker buildx history export needs`)} Install Docker Buildx ${RECORD_FLOOR} or later on this runner.`;
  }
  if (/[\r\n]/.test(options.recordDir)) {
    return `${skipped("the record directory's path holds a line break")} Pass a record directory whose path is one line.`;
  }
  if (!directoryExists(options.recordDir)) {
    return `${skipped("the record directory does not exist")} Create it before the summary runs.`;
  }
  const hex = randomHex();
  if (!/^[0-9a-f]{8}$/.test(hex)) return skipped("its name could not be made");
  const name = `fjall-build-record-${hex}.dockerbuild`;
  const path = resolve(options.recordDir, name);
  const exported = await call([
    "buildx",
    "history",
    "export",
    "--builder",
    BUILDER,
    ...(gate.finalize ? ["--finalize"] : []),
    "-o",
    path,
    ...rows.map((row) => row.ref),
  ]);
  if (exported.code !== 0) {
    return `${skipped(callFailure("docker buildx history export", exported, limits))} Export it ${HISTORY_HOST[options.ci]} with docker buildx history export --builder ${BUILDER} -o <file> <ref>.`;
  }
  if (options.outputs !== undefined) {
    try {
      appendFile(options.outputs, `record-path=${path}\nrecord-name=${name}\n`);
    } catch {
      return `Build record ${name} written, but its path could not be added to the outputs file.`;
    }
  }
  return `Build record ${name} written for ${plural(rows.length, "image build", "image builds")}.`;
}

/**
 * True only when node was started on THIS file, by realpath, as
 * resolve-fjall-engine.mjs decides it. The plugin ships standalone, so it
 * cannot import the repository's helper. Any failure to realpath either path
 * reads as not started, and the shims read a run that printed nothing as a
 * summary that did not run.
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
  const parsed = parseArgs(process.argv.slice(2));
  if (!parsed.ok) {
    process.stderr.write(`build-summary: ${parsed.message}\n`, () =>
      process.exit(USAGE_EXIT_CODE),
    );
  } else {
    let lines;
    try {
      ({ lines } = await run(parsed.options));
    } catch (err) {
      lines = [
        `Build summary stopped on ${err instanceof Error ? err.name : "a value that is not an error"}. The deploy's result is unchanged.`,
      ];
    }
    process.stdout.write(`${lines.join("\n")}\n`, () => process.exit(0));
  }
}
