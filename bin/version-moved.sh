#!/usr/bin/env bash
# version-moved.sh — did each engine whose SOURCE changed since its last release also MOVE the version
# string its built artifact reports?   (release-preflight [4b])
#
#   bash bin/version-moved.sh [<ver>] [--only <repos>]   # judge the cut set; exit 1 if any engine is silent
#   bash bin/version-moved.sh --selftest                 # prove it can FAIL, offline, on a throwaway tree
#
# WHY (SOUNDNESS R1670, rust). SPEC's version-skew rule sends a consumer that does not recognise a
# producer's build to §2.1's `Unknown`. It recognises one by the report's `candor.version` STRING. When a
# release changes how rows are keyed (rust's co-path split `Ty::m(Ty)` / `Ty::m(Tr)`, ⟨0.42⟩) but the
# string is the one the previous release already carried, an OLD consumer reads the producer's bare-path
# calls as ABSENT — a silent under-report with nothing flagging it. [4] cannot see it: it asserts the
# constants equal $WANT_VER, and a re-publish at the SAME version satisfies that.
#
# WHAT IT READS, per engine in the cut set (the strings §2.1 compares are the report's `candor.version`):
#   rust   `scan-<CARGO_PKG_VERSION>`      crates/candor-scan/Cargo.toml   (BUILT arm: target/release/candor-scan --version)
#   swift  `candor-swift-<x.y.z>`          Sources/candor-swift/main.swift (BUILT arm: .build/release/candor-swift --version)
#   ts     `candor-ts-<x.y.z>`             package.json                    (interpreted: the source constant IS the artifact)
#   agents `agents-<x.y.z>`                candor_agents/scan.py           (interpreted, likewise)
# candor-java is OUT, and says so: its report's `candor.version` is the git short hash, which moves on
# every commit by construction (its jar NAME is gated by [7]).
#
# PREVIOUS RELEASE = the newest `vX.Y.Z` tag in that repo other than v$VER (so it still answers after the
# cut's own tag exists). The tag it used is PRINTED. A clone whose tags were never fetched compares against an
# OLDER release, which can only make a silent engine look LESS silent — a FALSE OK (R1718: the engine clones'
# newest local tag was v0.40.17 while 0.41.x was published, and rust passed). So the local tag is NOT trusted
# alone: it is checked against `origin`'s tags (`git ls-remote`, no clone state touched) and a newer remote tag
# than any local one FAILS with the fetch command to run. A clone with no reachable origin FAILS too (it cannot
# say its tags are current); CANDOR_VM_NO_REMOTE=1 is the explicit offline opt-out and prints a warning line
# saying the tags were NOT verified, never a ✔.
# SOURCE CHANGED = any file under the engine's source pathspec differs between that tag and the working
# tree (uncommitted included: it is what the build reads). Docs, changelogs and tests do not count.
# FAILS when (1) source changed and the version the built artifact reports equals the previous release's, or
# (2) a built binary is present and reports something other than the source constant (a stale build — the
# bump never reached the binary that will be shipped). Binary override: CANDOR_BUILT_RUST / _SWIFT.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_release_set.sh
. "$HERE/_release_set.sh"

# repo | version file | key regex | spec-prefix | source pathspecs (space separated, ':(exclude)' allowed) | built binary (relative) | override var
VM_TABLE='candor-rust|crates/candor-scan/Cargo.toml|^version = "[0-9]+\.[0-9]+\.[0-9]+"|scan-|crates/*/src/* :(exclude)*/tests.rs :(exclude)*/tests/*|target/release/candor-scan|CANDOR_BUILT_RUST
candor-swift|Sources/candor-swift/main.swift|engineVersion *= *"candor-swift-[0-9]+\.[0-9]+\.[0-9]+"|candor-swift-|Sources|.build/release/candor-swift|CANDOR_BUILT_SWIFT
candor-ts|package.json|"version": *"[0-9]+\.[0-9]+\.[0-9]+"|candor-ts-|*.mjs :(exclude)test*.mjs :(exclude)*scratch*||
candor-agents|candor_agents/scan.py|^VERSION *= *"agents-[0-9]+\.[0-9]+\.[0-9]+"|agents-|candor_agents||'

_vm_semver() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -u; }   # unique versions on stdin

# vm_check <root> <want_ver> <set>  → prints lines, returns number of failures
vm_check() {
  local root="$1" want="$2" set="$3" fails=0 inset=0 compared=0
  local repo file key prefix paths bin ovr
  while IFS='|' read -r repo file key prefix paths bin ovr; do
    case " $set " in *" $repo "*) ;; *) printf '  ⊘ %s: not in this cut\n' "$repo"; continue;; esac
    local d="$root/$repo"; inset=$((inset+1))
    # An engine IN THE CUT that is not a clone here was NOT compared; passing over it is the vacuous OK (an umbrella
    # worktree's CANDOR_ROOT has no engine clones at all and the check printed OK having judged nothing).
    git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || { printf '  ✘ %s: in this cut but %s is not a git clone — NOT compared; point CANDOR_ROOT at the directory holding the engine clones\n' "$repo" "$d"; fails=$((fails+1)); continue; }
    local tag
    tag="$(git -C "$d" tag -l 'v[0-9]*.[0-9]*.[0-9]*' | grep -vx "v${want}" | sort -V | tail -1)"
    # Are the LOCAL tags current?  Ask the remote what the newest release tag is (names only; nothing is fetched).
    local rtag=""
    if [ "${CANDOR_VM_NO_REMOTE:-}" = 1 ]; then
      printf '  ⚠ %s: CANDOR_VM_NO_REMOTE=1 — local tags NOT verified against origin; the previous release below may be stale\n' "$repo"
    else
      local rls
      if ! rls="$(GIT_TERMINAL_PROMPT=0 git -C "$d" ls-remote --tags --refs origin 'v[0-9]*.[0-9]*.[0-9]*' 2>&1)"; then
        printf '  ✘ %s: cannot reach origin to check the local tags are current (%s) — a stale clone gives a FALSE OK (R1718); fetch, or set CANDOR_VM_NO_REMOTE=1 to say you are offline\n' \
          "$repo" "$(printf '%s' "$rls" | tail -1 | cut -c1-120)"; fails=$((fails+1)); continue
      fi
      rtag="$(printf '%s\n' "$rls" | sed -n 's#.*refs/tags/##p' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | grep -vx "v${want}" | sort -V | tail -1)"
    fi
    if [ -n "$rtag" ] && { [ -z "$tag" ] || [ "$(printf '%s\n%s\n' "$tag" "$rtag" | sort -V | tail -1)" != "$tag" ]; }; then
      printf '  ✘ %s: origin has release tag %s but the newest LOCAL tag is %s — this clone'"'"'s tags are stale, so "previous release" would be the wrong one (R1718, false OK). Run: git -C %s fetch --tags origin\n' \
        "$repo" "$rtag" "${tag:-none}" "$d"; fails=$((fails+1)); continue
    fi
    [ -n "$tag" ] || { printf '  ⊘ %s: no previous release tag — nothing to compare\n' "$repo"; continue; }
    local prev cur n
    prev="$(git -C "$d" show "$tag:$file" 2>/dev/null | grep -oE "$key" | _vm_semver)"
    cur="$([ -f "$d/$file" ] && grep -oE "$key" "$d/$file" | _vm_semver)"
    n="$(printf '%s\n' "$prev" | grep -c .)"
    if [ "$n" != 1 ] || [ "$(printf '%s\n' "$cur" | grep -c .)" != 1 ]; then
      printf '  ✘ %s: cannot read ONE version from %s (at %s: "%s", now: "%s") — refusing to pass over a value it cannot read\n' \
        "$repo" "$file" "$tag" "$(tr "\n" " " <<<"$prev")" "$(tr "\n" " " <<<"$cur")"; fails=$((fails+1)); continue
    fi
    # The built arm: what the artifact will actually report.
    local eff="$cur" how="source constant" binp=""
    if [ -n "$bin" ]; then
      binp="$(eval "printf '%s' \"\${$ovr:-}\"")"; [ -n "$binp" ] || binp="$d/$bin"
      if [ -x "$binp" ]; then
        local got; got="$("$binp" --version 2>/dev/null | head -1 | _vm_semver)"
        if [ -z "$got" ]; then
          printf '  ✘ %s: %s ran but printed no version — cannot judge the built arm\n' "$repo" "$binp"; fails=$((fails+1)); continue
        fi
        if [ "$got" != "$cur" ]; then
          printf '  ✘ %s: the BUILT binary reports %s but the source says %s — stale build; the bump never reached what ships\n' "$repo" "$got" "$cur"
          fails=$((fails+1)); continue
        fi
        eff="$got"; how="built binary"
      fi
    fi
    compared=$((compared+1))
    local -a pa; set -f; read -ra pa <<<"$paths"; set +f   # no shell glob: git expands the pathspecs itself
    local changed; changed="$(git -C "$d" diff --name-only "$tag" -- "${pa[@]}" 2>/dev/null | grep -c .)"
    if [ "$changed" -gt 0 ] && [ "$eff" = "$prev" ]; then
      printf '  ✘ %s: %d source file(s) changed since %s but the %s still reports %s%s — an old consumer reads the new keying as ABSENT (R1670); bump it\n' \
        "$repo" "$changed" "$tag" "$how" "$prefix" "$eff"; fails=$((fails+1))
    elif [ "$changed" -gt 0 ]; then
      printf '  ✔ %s: %s%s (%s) moved from %s%s (%s); %d source file(s) changed\n' "$repo" "$prefix" "$eff" "$how" "$prefix" "$prev" "$tag" "$changed"
    else
      printf '  • %s: no source change since %s — version %s%s unchanged is correct\n' "$repo" "$tag" "$prefix" "$eff"
    fi
  done <<<"$VM_TABLE"
  # The check must have JUDGED something.  Engines in the cut, none compared (every one ⊘ for want of a release tag, or
  # failed above) is not a pass: say so.  CANDOR_VM_ALLOW_EMPTY=1 is the explicit opt-out and stays loud.
  if [ "$inset" -gt 0 ] && [ "$compared" -eq 0 ]; then
    if [ "${CANDOR_VM_ALLOW_EMPTY:-}" = 1 ]; then
      printf '  ⚠ version-moved compared ZERO of %d engine(s) in this cut — CANDOR_VM_ALLOW_EMPTY=1, so this is NOT a pass of the check, only an allowed skip\n' "$inset"
    elif [ "$fails" -eq 0 ]; then
      printf '  ✘ version-moved compared ZERO of %d engine(s) in this cut — nothing was judged, which is not OK (set CANDOR_VM_ALLOW_EMPTY=1 only if you mean it)\n' "$inset"
      fails=$((fails+1))
    fi
  fi
  return "$fails"
}

vm_selftest() {
  local T s=0; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local g=(git -c user.email=t@t -c user.name=t -c commit.gpgsign=false)
  mk() { # $1 root  — a rust repo at 0.1.0 tagged v0.1.0, plus a swift repo likewise
    mkdir -p "$1/candor-rust/crates/candor-scan/src" "$1/candor-swift/Sources/candor-swift"
    printf '[package]\nname = "candor-scan"\nversion = "0.1.0"\n' > "$1/candor-rust/crates/candor-scan/Cargo.toml"
    echo 'fn a(){}' > "$1/candor-rust/crates/candor-scan/src/scan.rs"
    echo 'let engineVersion = "candor-swift-0.1.0"' > "$1/candor-swift/Sources/candor-swift/main.swift"
    local r; for r in candor-rust candor-swift; do
      "${g[@]}" -C "$1/$r" init -q; "${g[@]}" -C "$1/$r" add -A; "${g[@]}" -C "$1/$r" commit -qm one; "${g[@]}" -C "$1/$r" tag v0.1.0
      git init -q --bare "$1/$r.origin.git"; "${g[@]}" -C "$1/$r" remote add origin "$1/$r.origin.git"; "${g[@]}" -C "$1/$r" push -q origin HEAD v0.1.0
    done
  }
  stub() { printf '#!/bin/sh\necho "%s %s (spec 0.1)"\n' "$1" "$2" > "$3"; chmod +x "$3"; }
  run() { vm_check "$1" "${2:-0.2.0}" "${3:-candor-rust candor-swift}" 2>&1; }
  expect() { # $1 label $2 want-rc $3 output-regex $4 actual-rc $5 output
    if [ "$4" = "$2" ] && grep -qE "$3" <<<"$5"; then printf '  selftest ✔ %s\n' "$1"; else printf '  selftest ✘ %s (rc=%s want %s)\n%s\n' "$1" "$4" "$2" "$5"; s=$((s+1)); fi; }
  local out rc

  mk "$T/a"                                   # A. no change since the tag, same version: correct, passes
  out="$(run "$T/a")"; rc=$?; expect "unchanged source + unchanged version passes" 0 'no source change' "$rc" "$out"

  echo 'fn b(){}' >> "$T/a/candor-rust/crates/candor-scan/src/scan.rs"
  out="$(run "$T/a")"; rc=$?                  # B. SEEDED FAIL: source changed, version still the published one
  expect "SEEDED: rust source changed, version NOT moved -> FAILS" 1 '✘ candor-rust: 1 source file' "$rc" "$out"

  sed -i.bak 's/0.1.0/0.2.0/' "$T/a/candor-rust/crates/candor-scan/Cargo.toml"; rm "$T/a/candor-rust/crates/candor-scan/Cargo.toml.bak"
  out="$(run "$T/a" 0.2.0 candor-rust)"; rc=$?   # C. moved: passes
  expect "same change, version moved -> passes" 0 '✔ candor-rust: scan-0.2.0' "$rc" "$out"

  stub candor-scan 0.1.0 "$T/stale"             # D. SEEDED FAIL, built arm: source says 0.2.0, the binary still prints 0.1.0
  out="$(CANDOR_BUILT_RUST="$T/stale" run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "SEEDED: built binary prints the published version -> FAILS" 1 'BUILT binary reports 0.1.0 but the source says 0.2.0' "$rc" "$out"

  stub candor-scan 0.2.0 "$T/fresh"
  out="$(CANDOR_BUILT_RUST="$T/fresh" run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "built binary prints the moved version -> passes (built arm is live)" 0 'built binary' "$rc" "$out"

  # E. a source constant that is not readable must refuse, not pass: the check cannot be vacuous
  echo 'let x = 1' > "$T/a/candor-swift/Sources/candor-swift/main.swift"
  out="$(run "$T/a" 0.2.0 candor-swift)"; rc=$?
  expect "unreadable version constant -> FAILS (no vacuous pass)" 1 'cannot read ONE version' "$rc" "$out"

  # F. the tag of the cut itself must not become 'previous'
  "${g[@]}" -C "$T/a/candor-rust" add -A; "${g[@]}" -C "$T/a/candor-rust" commit -qm two; "${g[@]}" -C "$T/a/candor-rust" tag v0.2.0
  out="$(run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "the cut's own tag is skipped when choosing the previous release" 0 'from scan-0.1.0 \(v0.1.0\)' "$rc" "$out"

  # G. STALE LOCAL TAGS (R1718).  A second clone publishes v0.1.5 to origin; `$T/a` never fetched it.  Source is unchanged
  #    here, so before this check the cut passed against v0.1.0 — the false OK.  It must FAIL and name the fetch command.
  git clone -q "$T/a/candor-rust.origin.git" "$T/pub" 2>/dev/null
  "${g[@]}" -C "$T/pub" tag v0.1.5; "${g[@]}" -C "$T/pub" push -q origin v0.1.5
  out="$(run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "SEEDED: origin has v0.1.5, local newest tag is v0.1.0 -> FAILS and says fetch" 1 'origin has release tag v0.1.5 but the newest LOCAL tag is v0.1.0.*fetch --tags' "$rc" "$out"
  "${g[@]}" -C "$T/a/candor-rust" fetch -q --tags origin
  out="$(run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "after fetching the tag it passes, against the NEW previous release" 0 'moved from scan-0.1.0 \(v0.1.5\)' "$rc" "$out"
  # H. an unreachable origin is not a pass; the offline opt-out is explicit and is never a ✔
  "${g[@]}" -C "$T/a/candor-rust" remote set-url origin "$T/does-not-exist.git"
  out="$(run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "SEEDED: origin unreachable -> FAILS (cannot confirm the tags are current)" 1 'cannot reach origin' "$rc" "$out"
  out="$(CANDOR_VM_NO_REMOTE=1 run "$T/a" 0.2.0 candor-rust)"; rc=$?
  expect "CANDOR_VM_NO_REMOTE=1 is explicit and prints a NOT-verified warning" 0 'local tags NOT verified' "$rc" "$out"

  # I. VACUOUS PASS: an engine in the cut that is not a clone under CANDOR_ROOT.  Used to print ⊘ and OK.
  mkdir -p "$T/empty"
  out="$(run "$T/empty" 0.2.0 candor-rust)"; rc=$?
  expect "SEEDED: engine in the cut but no clone under the root -> FAILS" 1 '✘ candor-rust: in this cut but .* is not a git clone' "$rc" "$out"
  #    …and every engine in the cut with no previous release tag compares nothing: also a failure.
  mkdir -p "$T/notag/candor-rust"; "${g[@]}" -C "$T/notag/candor-rust" init -q
  out="$(CANDOR_VM_NO_REMOTE=1 run "$T/notag" 0.2.0 candor-rust)"; rc=$?
  expect "SEEDED: every engine in the cut skipped (no release tag) -> FAILS: compared ZERO" 1 'compared ZERO of 1' "$rc" "$out"
  out="$(CANDOR_VM_NO_REMOTE=1 CANDOR_VM_ALLOW_EMPTY=1 run "$T/notag" 0.2.0 candor-rust)"; rc=$?
  expect "CANDOR_VM_ALLOW_EMPTY=1 is explicit and prints a NOT-a-pass warning" 0 'compared ZERO .*NOT a pass' "$rc" "$out"
  out="$(run "$T/empty" 0.2.0 candor-spec)"; rc=$?
  expect "an empty cut (no engine in it) is not an error" 0 'not in this cut' "$rc" "$out"

  [ "$s" = 0 ] && echo "version-moved selftest: OK (every SEEDED case failed as required)" || echo "version-moved selftest: $s FAILED"
  return "$s"
}

if [ "${1:-}" = "--selftest" ]; then vm_selftest; exit $?; fi
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  ROOT="${CANDOR_ROOT:-$(cd "$HERE/../.." && pwd)}"
  rs_split_args "$@"; set -- "${RS_ARGS[@]+"${RS_ARGS[@]}"}"; rs_init
  vm_check "$ROOT" "${1:-}" "$RS_SET"; n=$?
  [ "$n" = 0 ] && echo "version-moved: OK" || echo "version-moved: $n engine(s) FAILED"
  [ "$n" = 0 ]
fi
