#!/usr/bin/env node
// Stage the PINNED candor-ts from npm and esbuild its lsp.mjs into the single-file server bundle the
// extension ships (dist/candor-lsp.mjs) — the same stageServer → bundleServer chain the JetBrains
// plugin runs in gradle. The pin (`candorTsVersion` in package.json) is the only input: bump it and
// re-run, and the bundle is re-staged from npm — never from a local checkout (verify the artifact you
// ship, TESTING.md §11).
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const pin = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8")).candorTsVersion;
if (!pin) { console.error("stage-server: FAIL — no candorTsVersion pin in package.json"); process.exit(1); }

// A stub package.json makes the stage dir its own npm project — without it npm walks UP, finds the
// EXTENSION's package.json, and installs candor-ts into the extension's node_modules instead.
const stage = path.join(root, "build", "server-stage");
fs.mkdirSync(stage, { recursive: true });
fs.writeFileSync(path.join(stage, "package.json"), '{ "private": true }\n');
execFileSync("npm", ["install", "--no-save", "--no-audit", "--no-fund", `candor-ts@${pin}`],
  { cwd: stage, stdio: "inherit" });

// The pin gate: the STAGED package must BE the pinned version — a stale stage dir or an unexpected npm
// resolution fails the build here, not in a user's editor.
const staged = JSON.parse(fs.readFileSync(
  path.join(stage, "node_modules", "candor-ts", "package.json"), "utf8")).version;
if (staged !== pin) {
  console.error(`stage-server: FAIL — staged candor-ts is ${staged}, the pin is ${pin}`);
  process.exit(1);
}

fs.mkdirSync(path.join(root, "dist"), { recursive: true });
execFileSync(path.join(root, "node_modules", ".bin", "esbuild"), [
  path.join(stage, "node_modules", "candor-ts", "lsp.mjs"),
  "--bundle", "--platform=node", "--format=esm",
  `--outfile=${path.join(root, "dist", "candor-lsp.mjs")}`,
], { stdio: "inherit" });
console.log(`stage-server: ok — candor-ts ${staged} staged from npm + bundled to dist/candor-lsp.mjs`);
