#!/usr/bin/env bash
# Calibration for bin/build-at.sh.  Run:  bash bin/build-at.sh --selftest   (or this file directly).
#
# HERMETIC: fixture repos built in a temp dir, named like the real engines (the script picks the build recipe from the
# repo's basename).  No network beyond what `npm ci` / `swift build` already do with no dependencies, no engine checkout.
#
# THE POINT OF EVERY CHECK BELOW IS THAT IT CAN FAIL.  The ground truth is EXECUTED, never read: each fixture commit
# prints a different constant, and the built binary is RUN.  Section [naive] first reproduces the very defect this
# tool exists for (a `git archive` extraction over an existing target dir, commit-time mtimes older than the cargo
# fingerprint, so the stale artefact is reused and exit 0 reports a build) and requires the executed constant to be
# the WRONG one, so the comparison used everywhere else is shown to detect it.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BA="$HERE/build-at.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/build-at-selftest.XXXXXX")"
LOCKPID=""
trap '[ -n "$LOCKPID" ] && kill "$LOCKPID" 2>/dev/null; rm -rf "${T:?}"' EXIT
export CANDOR_BUILD_AT_ROOT="$T/root"
unset CARGO_TARGET_DIR RUSTFLAGS RUSTC_WRAPPER

fails=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; shift; [ $# -gt 0 ] && printf '       %s\n' "$@"; fails=$((fails + 1)); }
GIT() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }

# $1 label ; $2 expected rc ; rest: command.  Captures stdout and stderr SEPARATELY and the real exit status.
rc_is() {
  local label="$1" want="$2"; shift 2
  OUT="$("$@" 2>"$T/err")"; RC=$?; ERR="$(cat "$T/err")"
  if [ "$RC" = "$want" ]; then ok "$label (exit $RC)"; else bad "$label" "want exit $want, got $RC" "stdout: $OUT" "stderr: $(printf '%s' "$ERR" | tail -3)"; fi
}
err_says() { case "$ERR" in *"$2"*) ok "$1" ;; *) bad "$1" "stderr lacks: $2" "$(printf '%s' "$ERR" | tail -3)" ;; esac; }

# ── fixture: a tiny rust workspace shaped like candor-rust (a `candor-scan` package under crates/) ────────────────
R="$T/fx/candor-rust"; mkdir -p "$R/crates/candor-scan/src"; cd "$R" || exit 2
GIT init -q -b main .
printf '[workspace]\nmembers = ["crates/candor-scan"]\nresolver = "2"\n' > Cargo.toml
printf '[package]\nname = "candor-scan"\nversion = "0.0.0"\nedition = "2021"\n' > crates/candor-scan/Cargo.toml
src() { printf 'fn main() { println!("ENGINE-%s"); }\n' "$1" > crates/candor-scan/src/main.rs; }
src A; cargo generate-lockfile -q 2>/dev/null
GIT add -A; GIT commit -q -m A;                       CA="$(git rev-parse HEAD)"
src B;           GIT commit -q -am B;                 CB="$(git rev-parse HEAD)"
echo readme > README.md; GIT add -A; GIT commit -q -m "readme only"; CR="$(git rev-parse HEAD)"
src C;           GIT commit -q -am C;                 CC="$(git rev-parse HEAD)"
printf 'fn main( { broken\n' > crates/candor-scan/src/main.rs; GIT commit -q -am broken; CBAD="$(git rev-parse HEAD)"
git checkout -q "$CC" 2>/dev/null; git reset -q --hard "$CC"; git checkout -q main 2>/dev/null; git reset -q --hard "$CC"
git branch -q -f bad "$CBAD"
sleep 1   # commit-time mtimes must be OLDER than anything a build writes below, as in real life

says_binary() { # $1 label ; $2 path ; $3 expected constant
  local got; got="$("$2" 2>&1)"
  if [ "$got" = "ENGINE-$3" ]; then ok "$1: the EXECUTED binary prints ENGINE-$3"; else bad "$1" "binary printed '$got', want ENGINE-$3"; fi
}

echo "[naive] the defect itself: extract over an existing target dir with commit-time mtimes"
N="$T/naive"; mkdir -p "$N/src"
( cd "$R" && git archive "$CA" ) | tar -x -C "$N/src"
( cd "$N/src" && CARGO_TARGET_DIR="$N/target" cargo build -q --locked -p candor-scan 2>/dev/null )
( cd "$R" && git archive "$CB" ) | tar -x -C "$N/src"      # now the tree is B's; its mtimes are commit time < the build above
( cd "$N/src" && CARGO_TARGET_DIR="$N/target" cargo build -q --locked -p candor-scan 2>/dev/null )
naive="$("$N/target/debug/candor-scan" 2>&1)"
if [ "$naive" = "ENGINE-A" ]; then ok "the naive method REPRODUCES the stale build: asked for B, exit 0, got ENGINE-A (the executed check detects it)"
else bad "the naive method did not reproduce the stale-artefact trap (it built '$naive')" "this section is the proof the executed check can fail; without it the sections below prove nothing about stale reuse"; fi

echo "[rust] build-at over the same engine commits"
rc_is "build A" 0 bash "$BA" --debug "$R" "$CA";  PA="$OUT"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 1 ] && ok "stdout is exactly one line (the artefact path)" || bad "stdout is not one line" "$OUT"
says_binary "A" "$PA" A
rc_is "build B (same root: nothing from A can be reused)" 0 bash "$BA" --debug "$R" "$CB"; PB="$OUT"
says_binary "B" "$PB" B
[ "$(shasum -a 256 < "$PA")" != "$(shasum -a 256 < "$PB")" ] && ok "adjacent commits that change engine source give different binary sha256" || bad "A and B have the same sha256"
shaA="$(sed -n 's/^artefact_sha256=//p' "$(dirname "$PA")/../MANIFEST")"
rc_is "rebuild A (--rebuild)" 0 bash "$BA" --debug --rebuild "$R" "$CA"
[ "$(sed -n 's/^artefact_sha256=//p' "$(dirname "$OUT")/../MANIFEST")" = "$shaA" ] \
  && ok "a second build of the same commit is BIT-IDENTICAL on this toolchain (sha256 equal)" \
  || bad "two builds of one commit differ" "if this toolchain is not bit-reproducible, compare behaviour and say so in the report"
rc_is "readme-only commit builds" 0 bash "$BA" --debug "$R" "$CR"; says_binary "readme-only" "$OUT" B
rc_is "request A again: REUSED after re-hash" 0 bash "$BA" --debug "$R" "$CA"; err_says "…and says it was reused, verified" "REUSED the verified build"
rc_is "a branch name resolves to its commit" 0 bash "$BA" --debug "$R" main; says_binary "main" "$OUT" C
err_says "…and the manifest/log names the FULL sha" "$CC"

echo "[provenance] source check, isolation from the engine repo"
echo "UNCOMMITTED" >> "$R/crates/candor-scan/src/main.rs"; echo junk > "$R/untracked.txt"
before_status="$(git -C "$R" status --porcelain)"; before_refs="$(git -C "$R" for-each-ref)"; before_wt="$(git -C "$R" worktree list)"
rc_is "build A with a DIRTY engine tree (--rebuild)" 0 bash "$BA" --debug --rebuild "$R" "$CA"
says_binary "dirty tree" "$OUT" A
[ "$(git -C "$R" status --porcelain)" = "$before_status" ] && [ "$(git -C "$R" for-each-ref)" = "$before_refs" ] \
  && [ "$(git -C "$R" worktree list)" = "$before_wt" ] && ok "the engine repo's working tree, refs and worktrees are untouched" || bad "build-at changed the engine repo"
git -C "$R" checkout -q -- crates/candor-scan/src/main.rs; rm -f "$R/untracked.txt"
CANDOR_BUILD_AT_FAULT=corrupt-source rc_is "a source tree corrupted after checkout is REFUSED by the on-disk blob check (seeded fault)" 1 bash "$BA" --debug --rebuild "$R" "$CA"
err_says "…by the source check, not by something later" "SOURCE CHECK FAILED"
rc_is "…and the next clean request is unaffected" 0 bash "$BA" --debug --rebuild "$R" "$CA"
rc_is "an unknown commit is refused" 2 bash "$BA" --debug "$R" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
rc_is "a path that is not an engine is refused" 2 bash "$BA" --debug "$T/fx" "$CA"
GIT -C "$R" update-index --add --cacheinfo "160000,$CA,sub" 2>/dev/null; GIT -C "$R" commit -q -m submodule; CSUB="$(git -C "$R" rev-parse HEAD)"
rc_is "a commit with a submodule is refused (its content is not in the tree)" 2 bash "$BA" --debug "$R" "$CSUB"
git -C "$R" reset -q --hard "$CC"

echo "[no cross-commit reuse] a build of ANOTHER commit sitting in this commit's slot"
mkdir -p "$CANDOR_BUILD_AT_ROOT/candor-rust"
cp -R "$(dirname "$PA")/.." "$CANDOR_BUILD_AT_ROOT/candor-rust/${CC}.debug.x" 2>/dev/null
rm -rf "${CANDOR_BUILD_AT_ROOT:?}/candor-rust/${CC}.debug"; mv "$CANDOR_BUILD_AT_ROOT/candor-rust/${CC}.debug.x" "$CANDOR_BUILD_AT_ROOT/candor-rust/${CC}.debug"
rc_is "A's build planted in C's slot is REFUSED, not reused" 1 bash "$BA" --debug "$R" "$CC"
err_says "…naming the other commit" "names commit $CA"
rc_is "…and --verify refuses it too" 1 bash "$BA" --verify "$CANDOR_BUILD_AT_ROOT/candor-rust/${CC}.debug"
rc_is "--rebuild replaces it, and the binary is now C's" 0 bash "$BA" --debug --rebuild "$R" "$CC"; PC="$OUT"; says_binary "C after refusing the plant" "$PC" C

echo "[verify] a tampered artefact is caught"
rc_is "verify the good build" 0 bash "$BA" --verify "$(dirname "$PC")/.."
printf 'x' >> "$PC"
rc_is "verify after one appended byte" 1 bash "$BA" --verify "$(dirname "$PC")/.."
err_says "…for the right reason (a hash mismatch, not a bad path)" "MISMATCH"
rc_is "…and a request for it refuses to reuse it" 1 bash "$BA" --debug "$R" "$CC"
rc_is "--rebuild heals it" 0 bash "$BA" --debug --rebuild "$R" "$CC"

echo "[failure] a build that fails advertises nothing"
rc_is "broken commit" 1 bash "$BA" --debug "$R" "$CBAD"
[ -z "$OUT" ] && ok "stdout is empty" || bad "a failed build printed a path" "$OUT"
[ ! -e "$CANDOR_BUILD_AT_ROOT/candor-rust/${CBAD}.debug" ] && ok "no build dir was created" || bad "a failed build left a finished-looking dir"
ls -d "$CANDOR_BUILD_AT_ROOT"/candor-rust/.work-* "$CANDOR_BUILD_AT_ROOT"/candor-rust/.lock-* >/dev/null 2>&1 && bad "work or lock dir left behind" || ok "work dir and lock are cleaned up"

echo "[guards] disk and concurrency"
CANDOR_DISK_FLOOR_MB=999999999 rc_is "disk-guard unhappy -> refused" 2 bash "$BA" --debug --rebuild "$R" "$CA"
mkdir -p "$CANDOR_BUILD_AT_ROOT/candor-rust/.lock-${CA}.debug"; sleep 30 & LOCKPID=$!
echo "$LOCKPID" > "$CANDOR_BUILD_AT_ROOT/candor-rust/.lock-${CA}.debug/pid"
rc_is "a live build of the same sha holds the lock -> refused" 1 bash "$BA" --debug --rebuild "$R" "$CA"
kill "$LOCKPID" 2>/dev/null; wait "$LOCKPID" 2>/dev/null; LOCKPID=""
rc_is "a lock whose owner died is taken over" 0 bash "$BA" --debug --rebuild "$R" "$CA"

echo "[prune] bounded disk"
nb="$(ls -d "$CANDOR_BUILD_AT_ROOT"/candor-rust/*/ | wc -l | tr -d ' ')"
mkdir -p "$CANDOR_BUILD_AT_ROOT/candor-rust/not-a-build"
rc_is "--prune 1" 0 bash "$BA" --prune 1
left="$(ls -d "$CANDOR_BUILD_AT_ROOT"/candor-rust/*/ | wc -l | tr -d ' ')"
[ "$left" = 2 ] && ok "kept the newest build + the non-build dir ($nb -> $left); it never deletes a dir with no MANIFEST" || bad "prune left $left dirs (had $nb)"

echo "[java] the jar's baked stamp must be the commit's (a synthetic jar; the real gradle build is not fixture-able)"
J="$CANDOR_BUILD_AT_ROOT/candor-java/$CA"; mkdir -p "$J/lib" "$T/jar/candor"
mkjar() { printf 'version=%s\ntoolchain=jdk-17\nrelease=0.0.0\n' "$1" > "$T/jar/candor/build-info.properties"; ( cd "$T/jar" && rm -f "$J/lib/x.jar" && zip -qr "$J/lib/x.jar" candor ); }
manifest() { printf 'repo=candor-java\nkind=java\ncommit=%s\nartefact=lib/x.jar\nartefact_sha256=%s\n' "$CA" "$(shasum -a 256 "$J/lib/x.jar" | cut -d' ' -f1)" > "$J/MANIFEST"; }
mkjar "${CA:0:9}"; manifest
rc_is "stamp == the commit's short sha verifies" 0 bash "$BA" --verify "$J"
mkjar "fatal: not a git repository"; manifest
rc_is "a jar stamped with git's own error text is refused (the poisoned-daemon case)" 1 bash "$BA" --verify "$J"
mkjar "${CB:0:9}"; manifest
rc_is "a jar stamped with ANOTHER commit's sha is refused" 1 bash "$BA" --verify "$J"

echo "[ts] node tree: identity is the tree + lockfile"
TS="$T/fx/candor-ts"; mkdir -p "$TS"; cd "$TS" || exit 2
GIT init -q -b main .
printf '{"name":"fx","version":"0.0.0","type":"module"}\n' > package.json
npm install --package-lock-only --no-fund --no-audit >/dev/null 2>&1
printf 'console.log("TS-A")\n' > scan.mjs; GIT add -A; GIT commit -q -m a; TA="$(git rev-parse HEAD)"
printf 'console.log("TS-B")\n' > scan.mjs; GIT commit -q -am b; TB="$(git rev-parse HEAD)"
rc_is "ts build A" 0 bash "$BA" "$TS" "$TA"; [ "$(node "$OUT/scan.mjs" 2>&1)" = "TS-A" ] && ok "executed: TS-A" || bad "ts A did not run as TS-A"
rc_is "ts build B" 0 bash "$BA" "$TS" "$TB"; [ "$(node "$OUT/scan.mjs" 2>&1)" = "TS-B" ] && ok "executed: TS-B" || bad "ts B did not run as TS-B"
ma="$(sed -n 's/^artefact_sha256=//p' "$CANDOR_BUILD_AT_ROOT/candor-ts/$TA/MANIFEST")"; mb="$(sed -n 's/^artefact_sha256=//p' "$CANDOR_BUILD_AT_ROOT/candor-ts/$TB/MANIFEST")"
[ -n "$ma" ] && [ "$ma" != "$mb" ] && ok "adjacent commits have different artefact ids" || bad "ts artefact ids: '$ma' vs '$mb'"
echo tamper >> "$CANDOR_BUILD_AT_ROOT/candor-ts/$TA/ts/scan.mjs"
rc_is "ts verify catches an edited source file" 1 bash "$BA" --verify "$CANDOR_BUILD_AT_ROOT/candor-ts/$TA"

echo "[swift] a no-dependency SwiftPM package named like the engine"
if command -v swift >/dev/null 2>&1; then
  SW="$T/fx/candor-swift"; mkdir -p "$SW/Sources/candor-swift"; cd "$SW" || exit 2
  GIT init -q -b main .
  printf '// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: "candor-swift", targets: [.executableTarget(name: "candor-swift")])\n' > Package.swift
  printf 'print("SW-A")\n' > Sources/candor-swift/main.swift; GIT add -A; GIT commit -q -m a; SA="$(git rev-parse HEAD)"
  printf 'print("SW-B")\n' > Sources/candor-swift/main.swift; GIT commit -q -am b; SB="$(git rev-parse HEAD)"
  rc_is "swift build A" 0 bash "$BA" --debug "$SW" "$SA"; [ "$("$OUT" 2>&1)" = "SW-A" ] && ok "executed: SW-A" || bad "swift A did not print SW-A"
  rc_is "swift build B" 0 bash "$BA" --debug "$SW" "$SB"; [ "$("$OUT" 2>&1)" = "SW-B" ] && ok "executed: SW-B" || bad "swift B did not print SW-B"
  sa="$(sed -n 's/^artefact_sha256=//p' "$CANDOR_BUILD_AT_ROOT/candor-swift/$SA.debug/MANIFEST")"
  rc_is "swift rebuild A" 0 bash "$BA" --debug --rebuild "$SW" "$SA"
  [ "$sa" = "$(sed -n 's/^artefact_sha256=//p' "$CANDOR_BUILD_AT_ROOT/candor-swift/$SA.debug/MANIFEST")" ] && ok "swift: second build of the same commit is bit-identical" || bad "swift rebuild differs"
else
  bad "swift is not installed, so the swift recipe was NOT calibrated here"
fi

echo
if [ "$fails" = 0 ]; then echo "build-at selftest: OK"; exit 0; fi
echo "build-at selftest: $fails FAILED"; exit 1
