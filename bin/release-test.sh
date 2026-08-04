#!/usr/bin/env bash
# release-test.sh — exercise the release scripts against a FIXTURE tree, so they stop being tested by
# publishing.
#
#   bash bin/release-test.sh
#
# WHY THIS EXISTS, stated as it happened rather than as a principle.
#
# `release-stage.sh` performs ~19 edits across six repos; `release-preflight.sh` carries eleven checks;
# `release.sh` stands between all of that and crates.io, npm and seven GitHub releases. Until now NOTHING
# gated any of them, and the record is unambiguous — NINE defects across the 0.25 and 0.26 cuts, every one
# found by RUNNING the scripts and not one by reading them:
#
#   0.25 · a heredoc nested inside `$(...)` is a shell parse hazard
#        · `\1` immediately followed by `0.26.0` parses as group TEN (`\g<1>` is the only safe form)
#   0.26 · release.sh would have published EMPTY notes for all five engines (it read "the first `## `
#          section", and the stager inserts a fresh empty `## Unreleased` above the entry it cuts)
#        · the staged heading silently lost its `⟨spec N⟩` rung marker
#        · preflight [3] and release.sh step 0 DEADLOCKED: [3] demands the pins name the new version, its
#          own message says they move after publish, and step 0 refuses to run unless preflight is green
#        · preflight [10] failed the release on a docs-only commit (workflows are path-filtered)
#        · `bin/candor`'s UMBRELLA_VERSION was staged by nothing and checked by nothing
#        · the umbrella's DATED changelog was not staged at all
#        · `update-candor.sh` was handed a bare version, so every release grew a second tag
#        · the fix for the dated changelog ate a blank line (`\s` matches newlines)
#
# Each row below is one of those. A test that cannot fail is worth nothing, so every assertion here was
# written by REPRODUCING the defect against the fixture first and watching it fail.
#
# WHAT THIS DOES NOT COVER, said plainly: the publish calls themselves — `cargo publish`, the npm OIDC tag,
# `gh release create`, the Homebrew tap. Those touch the network and cannot be exercised without either a
# dry-run mode or stubs, and neither exists yet. Eight of the nine defects above are on this side of that
# line; the ninth (the double tag) is checked here at the argument level only.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UMBRELLA="$(cd "$HERE/.." && pwd)"
FIX="$(mktemp -d)"
trap 'rm -rf "$FIX"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; fail=$((fail+1)); }
say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
is()   { # $1 label ; $2 expected ; $3 actual
  [ "$2" = "$3" ] && ok "$1" || bad "$1 — expected '$2', got '$3'"; }
has()  { # $1 label ; $2 file ; $3 fixed string
  grep -qF "$3" "$2" && ok "$1" || bad "$1 — '$3' not in $2"; }
hasnt(){ grep -qF "$3" "$2" && bad "$1 — '$3' still in $2" || ok "$1"; }

# ---------------------------------------------------------------------------------------------------
# The fixture: six stub repos carrying exactly the sites the stager edits, at 0.25.0.
# Real git repos, because release-stage.sh refuses on a dirty tree and that refusal is itself behaviour
# worth keeping honest.
# ---------------------------------------------------------------------------------------------------
mk() { mkdir -p "$(dirname "$FIX/$1")"; printf '%s' "$2" > "$FIX/$1"; }
CHLOG='# Changelog

## Unreleased — ⟨spec 0.26⟩

### a real entry
body line one
body line two

## [0.25.0] — 2026-08-02

⟨spec 0.25⟩ previous
'
mk candor-agents/candor_agents/scan.py 'VERSION = "agents-0.25.0"
'
mk candor-agents/pyproject.toml '[project]
version = "0.25.0"
'
mk candor-swift/Sources/candor-swift/main.swift 'let engineVersion = "candor-swift-0.25.0"
'
mk candor-ts/package.json '{
  "name": "candor-ts",
  "version": "0.25.0"
}
'
mk candor-java/build.gradle.kts 'version = "0.25.0"
'
mk candor-rust/Cargo.toml '[workspace.dependencies]
candor-report = { path = "crates/candor-report", version = "0.25.0" }
candor-classify = { path = "crates/candor-classify", version = "0.25.0" }
'
for c in candor-report candor-classify candor-scan candor-query; do
  mk "candor-rust/crates/$c/Cargo.toml" "[package]
version = \"0.25.0\"

[dependencies]
candor-report = { path = \"../candor-report\", version = \"0.25.0\" }
"
done
mk candor/bin/candor 'UMBRELLA_VERSION="0.25.0"                    # the umbrella'"'"'s OWN version
ENGINE_PIN="0.25.0"                          # moves AFTER a release exists
'
mk candor/CHANGELOG.md '# Changelog — candor (umbrella)

It is **not a versioned release artifact**, so this changelog is **dated**.

## 2026-08-02 — spec 0.26: a sidecar'"'"'s KEY SET is its manifest (unreleased)

⟨spec 0.26⟩ the rung.

## 2026-07-30 — something older
'
for r in candor-rust candor-java candor-ts candor-swift candor-agents; do
  printf '%s' "$CHLOG" > "$FIX/$r/CHANGELOG.md"
done
cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_stage_changelogs.py" "$FIX/candor/bin/"
for r in candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  ( cd "$FIX/$r" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )
done

# ---------------------------------------------------------------------------------------------------
say "1. release-stage.sh — every version site moves, and the changelogs are cut correctly"
# ---------------------------------------------------------------------------------------------------
out="$(CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.26.0 2>&1)"
echo "$out" | grep -q "edit(s)" && ok "stage ran" || { bad "stage did not run"; echo "$out" | tail -5; }

is "agents VERSION"   '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-agents/candor_agents/scan.py")"
is "agents pyproject" '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-agents/pyproject.toml")"
is "swift engine"     '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-swift/Sources/candor-swift/main.swift")"
is "ts package.json"  '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-ts/package.json")"
is "java gradle"      '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-java/build.gradle.kts")"
# DEFECT 5 (0.26): staged by nothing, checked by nothing, caught only by update-candor.sh refusing.
is "umbrella UMBRELLA_VERSION" '0.26.0' "$(sed -n 's/^UMBRELLA_VERSION="\([^"]*\)".*/\1/p' "$FIX/candor/bin/candor")"
# ENGINE_PIN names a PUBLISHED release, so it must NOT move here — different axis, different moment.
is "umbrella ENGINE_PIN untouched" '0.25.0' "$(sed -n 's/^ENGINE_PIN="\([^"]*\)".*/\1/p' "$FIX/candor/bin/candor")"

is "rust crate version" '0.26.0' "$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$FIX/candor-rust/crates/candor-scan/Cargo.toml")"
hasnt "no inter-crate dep left at the old version" "$FIX/candor-rust/Cargo.toml" '0.25.0'
hasnt "no crate-level dep left at the old version" "$FIX/candor-rust/crates/candor-scan/Cargo.toml" '0.25.0'

# DEFECT 2 (0.26): the rung marker was captured and discarded.
has "released heading keeps the rung marker" "$FIX/candor-rust/CHANGELOG.md" '## [0.26.0] — '
grep -qE '^## \[0\.26\.0\] — [0-9-]+ ⟨spec 0\.26⟩$' "$FIX/candor-rust/CHANGELOG.md" \
  && ok "rung marker survives the rename" || bad "rung marker lost — the released entry no longer records its contract"
# DEFECT 1 (0.26): a fresh empty Unreleased above the entry, which release.sh then published as the notes.
grep -qE '^## Unreleased$' "$FIX/candor-rust/CHANGELOG.md" && ok "fresh empty Unreleased opened" || bad "no fresh Unreleased"
has "the entry body survived" "$FIX/candor-rust/CHANGELOG.md" 'body line two'
# DEFECT 6 (0.26): the umbrella's DATED changelog was not staged at all.
hasnt "umbrella dated heading no longer says (unreleased)" "$FIX/candor/CHANGELOG.md" '(unreleased)'
has   "umbrella dated heading marked released"             "$FIX/candor/CHANGELOG.md" 'as 0.26.0)'

# DEFECT 8 (0.26): `\s*$` matched newlines and silently reflowed the file.
# awk, not sed: BSD sed rejects `/re/{n;/./p}` and ERRORED to empty output, which made `[ -z ... ]` true
# and the assertion pass regardless of the file. A test that cannot fail is the thing this file exists to
# stop, so it is worth saying that this one was written that way first.
nb="$(awk '/^## 2026-08-02/{getline; if (length($0)) print "NONBLANK"}' "$FIX/candor/CHANGELOG.md")"
[ -z "$nb" ] && ok "umbrella heading did not eat the following blank line" \
             || bad "the blank line after the dated heading was consumed — the stager reflowed the file"

say "2. release-stage.sh is idempotent and refuses a dirty tree"
# Commit ALL of them first: run 1 leaves every fixture repo dirty, and the stager refuses a dirty tree —
# so an un-committed second run tests the refusal, not idempotence. (It did, and reported "not idempotent".)
for r in candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  ( cd "$FIX/$r" && git add -A && git -c user.email=t@e -c user.name=t commit -qm staged )
done
out2="$(CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.26.0 2>&1)"
# the summary line always contains the words "already-current", so assert on the COUNT: a second run must
# make ZERO edits. Matching the phrase would have passed on the first run too.
n2="$(echo "$out2" | sed -n 's/^release-stage: \([0-9]*\) edit(s).*/\1/p')"
is "second run makes zero edits" '0' "${n2:-missing}"
is "second run changed nothing" '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-ts/package.json")"
printf 'dirt\n' >> "$FIX/candor-java/CHANGELOG.md"
CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.27.0 >/dev/null 2>&1 \
  && bad "staged over a dirty tree" || ok "refuses a dirty tree"
( cd "$FIX/candor-java" && git checkout -q . )

say "3. the notes release.sh would publish"
# DEFECT 1 again, at the extraction site: by POSITION this yields the empty Unreleased; by VERSION it
# yields the real entry. This is the check that would have stopped five empty GitHub releases.
byver="$(awk -v v='## [0.26.0]' 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$FIX/candor-rust/CHANGELOG.md" | wc -l | tr -d ' ')"
bypos="$(awk '/^## /{n++} n==1{print} n==2{exit}' "$FIX/candor-rust/CHANGELOG.md" | wc -l | tr -d ' ')"
[ "$byver" -gt 3 ] && ok "version-anchored notes are non-empty ($byver lines)" || bad "version-anchored notes are empty ($byver lines)"
[ "$bypos" -le 2 ] && ok "position-anchored notes WOULD have been empty ($bypos lines) — the defect is reproduced" \
                   || bad "position-anchored extraction no longer reproduces the defect; this test has stopped discriminating"
# the umbrella has no version heading at all — release.sh must fall back, not die
uver="$(awk -v v='## [0.26.0]' 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$FIX/candor/CHANGELOG.md" | wc -l | tr -d ' ')"
ufall="$(awk '/^## /{n++} n==1{print} n==2{exit}' "$FIX/candor/CHANGELOG.md" | wc -l | tr -d ' ')"
is "umbrella has no version-anchored section" '0' "$uver"
[ "$ufall" -gt 2 ] && ok "umbrella falls back to its newest dated section ($ufall lines)" || bad "umbrella fallback is empty"

say "4. release.sh hands update-candor.sh a TAG, not a bare version"
# DEFECT 7 (0.26): passing $VER made update-candor.sh create a SECOND tag beside v$VER.
grep -q 'update-candor.sh" "v\$VER"' "$UMBRELLA/bin/release.sh" \
  && ok "release.sh passes v\$VER" || bad "release.sh passes a bare version — a second tag per release"
grep -q 'already exists — reusing it' "$UMBRELLA/scripts/update-candor.sh" \
  && ok "update-candor.sh reuses an existing tag/release" || bad "update-candor.sh would recreate the tag"

say "5. release.sh gates on preflight in PINS_ADVISORY mode"
# DEFECT 3 (0.26): [3] demands pins that only exist after publishing, while step 0 demands a green
# preflight — unsatisfiable, so every release bypassed the script written to stop bypasses.
grep -q 'PINS_ADVISORY=1 bash "$ROOT/candor/bin/release-preflight.sh"' "$UMBRELLA/bin/release.sh" \
  && ok "step 0 runs preflight with pins advisory" || bad "step 0 would deadlock on check [3]"
grep -q 'PINS_ADVISORY' "$UMBRELLA/bin/release-preflight.sh" \
  && ok "preflight honours PINS_ADVISORY" || bad "preflight has no advisory mode"

printf '\n'
if [ "$fail" -gt 0 ]; then printf '\033[31mrelease-test: %d FAILED, %d passed\033[0m\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mrelease-test: OK — %d assertions\033[0m\n' "$pass"
