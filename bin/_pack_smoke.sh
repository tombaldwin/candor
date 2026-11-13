#!/usr/bin/env bash
# _pack_smoke.sh — START the package exactly as a consumer receives it: `npm pack`, unpack the tarball somewhere
# else, and run its first `bin` with `--version`.
#
#   bash bin/_pack_smoke.sh <package-dir>      # 0 starts, 1 does not (reason on stdout), 3 could not run it, 4 declares no bin
#   bash bin/_pack_smoke.sh --selftest         # seeds the 0.42.0 defect; the smoke must refuse it
#
# WHY. candor-ts 0.42.0 reached npm without `env.mjs` (absent from package.json `files`). Every test ran from the git
# tree, where the file exists, so the battery, CI and publish.yml were all green and `npx candor-ts@0.42.0` died on
# start with ERR_MODULE_NOT_FOUND. candor-ts's own `test-pack.mjs` now follows the import graph of the tarball's file
# list, but it lives in that repo's `npm test`, so the release ladder had no check of its own: the only thing that ran
# the PUBLISHED shape was the post-publish `npx` smoke, i.e. after the broken version was on the registry for good
# (npm will not take a version back). This is the pre-publish half. It is deliberately a different instrument from
# test-pack.mjs: that one reads import statements, this one executes the entry, so it also catches a missing
# non-import file, a bad `bin` path, or a shebang/permission fault that a static walk cannot see.
#
# The unpacked copy has no dependencies of its own, so the package's node_modules is symlinked in. That is a
# deliberate concession: it can hide a runtime dependency missing from `dependencies`, which this check does not cover.
set -uo pipefail

pack_smoke() { # $1 = package dir
  local pkg="$1" tmp tgz bin out rc
  [ -f "$pkg/package.json" ] || { echo "no package.json in $pkg"; return 3; }
  command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1 || { echo "npm and node are both required"; return 3; }
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/pack-smoke.XXXXXX")" || return 3
  # --ignore-scripts: a `prepack` may rewrite files in the working tree (candor-ts copies its lockfile).
  tgz="$(cd "$pkg" && npm pack --ignore-scripts --silent --pack-destination "$tmp" 2>"$tmp/pack.err" | tail -1)"
  if [ -z "$tgz" ] || [ ! -f "$tmp/$tgz" ]; then
    echo "npm pack produced no tarball: $(head -3 "$tmp/pack.err" | tr '\n' ' ')"; rm -rf "$tmp"; return 1
  fi
  mkdir "$tmp/x" && tar -xzf "$tmp/$tgz" -C "$tmp/x" || { echo "tarball $tgz does not unpack"; rm -rf "$tmp"; return 1; }
  bin="$(node -e 'const b=require(process.argv[1]).bin;console.log(typeof b==="string"?b:b?Object.values(b)[0]:"")' "$pkg/package.json" 2>/dev/null)"
  if [ -z "$bin" ]; then echo "package.json declares no bin — nothing to start"; rm -rf "$tmp"; return 4; fi
  if [ -d "$pkg/node_modules" ]; then ln -s "$(cd "$pkg" && pwd)/node_modules" "$tmp/x/package/node_modules"; fi
  if [ ! -f "$tmp/x/package/$bin" ]; then echo "the tarball does not contain its own bin $bin"; rm -rf "$tmp"; return 1; fi
  out="$(cd "$tmp/x/package" && node "$bin" --version 2>&1)"; rc=$?
  rm -rf "$tmp"
  if [ "$rc" != 0 ] || [ -z "$out" ]; then
    echo "the PACKED $bin did not start (exit $rc): $(printf '%s' "$out" | grep -m1 -E 'Error|error' || printf '%s' "$out" | head -1)"
    return 1
  fi
  echo "$out" | head -1
  return 0
}

selftest() {
  local d bad=0 rc out
  d="$(mktemp -d "${TMPDIR:-/tmp}/pack-smoke-st.XXXXXX")" || return 2
  mkdir -p "$d/good" && cd "$d/good" || return 2
  printf '{"name":"fx","version":"1.0.0","bin":{"fx":"./main.mjs"},"files":["main.mjs","dep.mjs"]}\n' > package.json
  printf 'import { v } from "./dep.mjs";\nconsole.log("fx " + v);\n' > main.mjs
  printf 'export const v = "1.0.0";\n' > dep.mjs
  out="$(pack_smoke "$d/good")"; rc=$?
  [ "$rc" = 0 ] && echo "  ok   a complete package starts: $out" || { echo "  FAIL control: a complete package did not start (rc $rc): $out"; bad=$((bad+1)); }
  # THE 0.42.0 SHAPE: dep.mjs exists in the tree and is imported, but `files` does not ship it.
  mkdir -p "$d/bad" && cp "$d/good/main.mjs" "$d/good/dep.mjs" "$d/bad/"
  printf '{"name":"fx","version":"1.0.0","bin":{"fx":"./main.mjs"},"files":["main.mjs"]}\n' > "$d/bad/package.json"
  out="$(pack_smoke "$d/bad")"; rc=$?
  [ "$rc" = 1 ] && echo "  ok   a package missing an imported file is refused: $out" || { echo "  FAIL the 0.42.0 shape (imported file not in files) was not refused (rc $rc): $out"; bad=$((bad+1)); }
  # NOT A PASS: no bin cannot be started, and must not read as one.
  mkdir -p "$d/nobin"; printf '{"name":"fx","version":"1.0.0"}\n' > "$d/nobin/package.json"
  out="$(pack_smoke "$d/nobin")"; rc=$?
  [ "$rc" = 4 ] && echo "  ok   a package with no bin is UNRUN (4), not green" || { echo "  FAIL no-bin returned $rc: $out"; bad=$((bad+1)); }
  rm -rf "$d"
  [ "$bad" = 0 ] && { echo "_pack_smoke selftest: OK"; return 0; }
  echo "_pack_smoke selftest: $bad FAILED"; return 1
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --selftest) selftest; exit $? ;;
    ""|-*) echo "usage: _pack_smoke.sh <package-dir> | --selftest" >&2; exit 2 ;;
    *) pack_smoke "$1"; exit $? ;;
  esac
fi
