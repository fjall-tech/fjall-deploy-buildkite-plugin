#!/usr/bin/env node
/**
 * Resolve the fjall ENGINE npm spec (`fjall@<major>`) whose major matches the
 * app's pinned `@fjall/components-infrastructure`, so the GitHub Action never
 * installs an engine that skews across a major from the constructs the app
 * synthesises. Echoes `fjall@<major>` on stdout for `npm install -g "$(…)"`.
 *
 * Invoked by action.yml when `cli-version: auto`. Takes the app's working
 * directory (where fjall-config.json + package.json live) as argv[1], since the
 * action is a reusable plugin that cannot assume the consumer's repo layout.
 *
 * Fails LOUD (non-zero exit, diagnostics on stderr) when no pin is found or the
 * pins disagree — guessing an engine major is exactly the silent-skew failure
 * this closes. See aiDocs decisions/2026-07-25-deploy-engine-runtime-version-contract.md.
 *
 * Byte-identical to the copy the other CI plugin ships: each plugin is published
 * on its own, so each carries the resolver rather than importing a shared
 * module. engineResolver.test.ts in @fjall/cli pins the two equal.
 */
import {
  readFileSync,
  existsSync,
  readdirSync,
  statSync,
  realpathSync,
} from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const CONSTRUCT_PACKAGE = "@fjall/components-infrastructure";

/**
 * Extract the major version from an npm version range. Strips a leading range
 * operator (`^`, `~`, `>=`, `<`, `=`, `v`) and reads the first dotted segment.
 * Returns null for anything without a numeric major (`latest`, `*`, `workspace:…`,
 * a git/file URL) — the caller treats null as "cannot determine" and fails loud.
 */
export function majorFromRange(range) {
  if (typeof range !== "string") return null;
  const stripped = range.trim().replace(/^[\^~>=<v\s]+/, "");
  const major = stripped.split(".")[0];
  if (major === undefined || !/^\d+$/.test(major)) return null;
  return Number(major);
}

/**
 * Collect every `@fjall/components-infrastructure` pin declared under workDir:
 * the workDir package.json and each fjall/<app>/package.json, in both
 * `dependencies` and `devDependencies`. Returns `[{ file, range }]`.
 */
export function findConstructPins(workDir) {
  const candidates = [join(workDir, "package.json")];
  const fjallDir = join(workDir, "fjall");
  if (existsSync(fjallDir) && statSync(fjallDir).isDirectory()) {
    for (const entry of readdirSync(fjallDir)) {
      const pkgPath = join(fjallDir, entry, "package.json");
      if (existsSync(pkgPath)) candidates.push(pkgPath);
    }
  }

  const pins = [];
  for (const file of candidates) {
    if (!existsSync(file)) continue;
    let pkg;
    try {
      pkg = JSON.parse(readFileSync(file, "utf8"));
    } catch {
      // A malformed manifest in the search path is skipped, not fatal — if it
      // held the only pin, the caller's "no pin found" branch fails loud anyway.
      console.error(`resolve-fjall-engine: skipping unreadable ${file}`);
      continue;
    }
    const range =
      pkg?.dependencies?.[CONSTRUCT_PACKAGE] ??
      pkg?.devDependencies?.[CONSTRUCT_PACKAGE];
    if (typeof range === "string") pins.push({ file, range });
  }
  return pins;
}

/**
 * Reduce collected pins to a single engine major, throwing (fail loud) when no
 * pin parses or the pins disagree across a major boundary.
 */
export function resolveEngineMajor(pins) {
  const resolved = [];
  for (const pin of pins) {
    const major = majorFromRange(pin.range);
    if (major === null) {
      throw new Error(
        `cannot parse a major version from "${pin.range}" (${CONSTRUCT_PACKAGE} pin in ${pin.file})`,
      );
    }
    resolved.push({ ...pin, major });
  }

  if (resolved.length === 0) {
    throw new Error(
      `no ${CONSTRUCT_PACKAGE} pin found under the working directory — cannot compute the matching fjall engine major`,
    );
  }

  const majors = [...new Set(resolved.map((p) => p.major))];
  if (majors.length > 1) {
    const detail = resolved
      .map((p) => `${p.file}: ${p.range} (major ${p.major})`)
      .join("; ");
    throw new Error(
      `conflicting ${CONSTRUCT_PACKAGE} pins — cannot pick one fjall engine major: ${detail}`,
    );
  }

  return majors[0];
}

/** Compose the full `fjall@<major>` engine spec for the app rooted at workDir. */
export function resolveEngineSpec(workDir) {
  return `fjall@${resolveEngineMajor(findConstructPins(workDir))}`;
}

function main() {
  const workDir = process.argv[2];
  if (typeof workDir !== "string" || workDir.length === 0) {
    throw new Error(
      "usage: resolve-fjall-engine.mjs <working-directory> (missing directory argument)",
    );
  }
  console.log(resolveEngineSpec(workDir));
}

/**
 * True only when node was started on THIS file. Compares realpaths: node
 * canonicalises the entry module through symlinks, so `import.meta.url`
 * arrives resolved while `process.argv[1]` is the caller's spelling made
 * absolute, with symlinks kept. The suffix match this replaced answered false
 * for a start through a symlinked file or directory, unless the path node was
 * given happened to end the real one (as `/tmp/…` ends `/private/tmp/…` on
 * macOS). When it answered false, the script exited 0 having printed no
 * engine spec at all.
 *
 * This keeps a subset of the fjall repository's
 * `scripts/started-on-this-file.mjs` on purpose: the plugin ships standalone
 * to customers' CI, with no node_modules and no repository around it, so it
 * cannot import that helper. Both compare realpaths, so a start through a
 * symlinked file or directory reads as started. The helper also resolves
 * `argv[1]` first, which completes a start without the extension or by a
 * directory. Node never completes an `.mjs` extension, and reaches an `.mjs`
 * file by a directory only through that directory's package.json `main`,
 * which neither plugin ships, so this file does not need that. What else
 * differs is failure: this reads any failure to realpath either path as "not
 * started", where the helper says "not started" only when `argv[1]` names no
 * module and rethrows anything else. Each plugin starts this file by its full
 * path and refuses an answer that names no engine, so that reading cannot
 * install an unnamed one.
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
  try {
    main();
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    console.error(`resolve-fjall-engine: ${detail}`);
    process.exit(1);
  }
}
