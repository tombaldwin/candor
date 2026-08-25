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
# A SKIP IS NOT A PASS and must not be counted as one — but it must be SEEN. A row that vanishes when a
# tool is missing is the shape where "we tested that" and "that could not run" look identical.
skipped=0
# …and under CI a skip is a FAILURE. `note_skip` counted and printed, but the verdict line stayed the
# green "OK" with a parenthetical — and the CI job's tick, the only signal anyone consumes, was identical
# whether the arm ran or not. That arm is where BOTH defects this harness was extended for actually
# lived. Locally a skip is information; in CI it means the runner is missing a tool the gate needs, which
# is a broken gate, not a passing one.
note_skip(){ printf '  \033[33m•\033[0m SKIPPED: %s\n' "$*"; skipped=$((skipped+1))
             [ -n "${CI:-}" ] && bad "…and a SKIP is a FAILURE under CI — the runner is missing a tool this gate needs"; }

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
# The README's `## Status` line is a STAGED SITE, so the fixture has to carry it — otherwise the stage
# dies on a missing file and every later assertion fails with it, which is how this test went red the
# first time that site was added. A fixture missing a site does not merely skip it: `bump` treats an
# absent file as a moved site and refuses, deliberately.
mk candor-java/README.md '## Status: beta (v0.25.0, spec 0.24 — the family reference engine)
'
# A REAL CARGO WORKSPACE, not a lookalike. This carried `[workspace.dependencies]` and four
# name-less `[package]` stanzas, so `cargo update --workspace` errored on every run and the stager's
# Cargo.lock arm — which is a STAGED SITE — was unreachable from this harness. That is precisely how
# `note` shipped undefined and how the lock step reported `ok` on a no-op: a staged site absent from
# the fixture is an untested site, and both defects lived in the one arm the fixture could not enter.
# `members` + name/edition + a src/lib.rs is all it takes; the deps are path deps, so `--offline` resolves.
mk candor-rust/Cargo.toml '[workspace]
members = ["crates/candor-report", "crates/candor-classify", "crates/candor-scan", "crates/candor-query"]
resolver = "2"

[workspace.dependencies]
candor-report = { path = "crates/candor-report", version = "0.25.0" }
candor-classify = { path = "crates/candor-classify", version = "0.25.0" }
'
for c in candor-report candor-classify candor-scan candor-query; do
  # candor-report is the leaf every other crate depends on, so it must not depend on itself.
  dep=""
  [ "$c" = candor-report ] || dep="
[dependencies]
candor-report = { path = \"../candor-report\", version = \"0.25.0\" }"
  mk "candor-rust/crates/$c/Cargo.toml" "[package]
name = \"$c\"
version = \"0.25.0\"
edition = \"2021\"
$dep
"
  mk "candor-rust/crates/$c/src/lib.rs" "pub fn f() {}
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
# `_release_set.sh` IS A DEPENDENCY OF THE STAGER, not an optional extra: release-stage.sh sources it
# relative to its OWN directory, so a fixture bin/ without it makes every row in section 1 fail as
# "stage did not run" — a setup failure wearing a behaviour failure's clothes. Copy what the script
# needs, not just the script.
cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_stage_changelogs.py" "$UMBRELLA/bin/_release_set.sh" \
   "$UMBRELLA/bin/_release_notes.sh" "$FIX/candor/bin/"
# candor-spec IS A REPO IN THE FIXTURE, not a bare directory conjured mid-test. `_stage_changelogs.py`
# edits it, and `release-stage.sh` now refuses a dirty tree across all SEVEN repos it touches — so a
# fixture that carried candor-spec as a loose folder was missing the one repo whose CHANGELOG has the
# floor-shaped heading the helper has a dedicated branch for. The stager could not be exercised against
# the repo the rung is authored in.
mk candor-spec/CHANGELOG.md '# Changelog

## Unreleased

## 0.26 — current floor

⟨spec 0.26⟩ the previous rung.
'
for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec candor; do
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
# …and the README Status line beside it: only the SPEC number on that line was ever staged, so the
# version half read v0.19.x for nine releases. The assertion is the version, not the whole line.
is "java README status" '0.26.0' "$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-java/README.md" | head -1 | tr -d v)"
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

# ── 2026-08-08: THE FOLD. Writing the version heading early is how this project actually works — you
# cut `## [0.27.0]`, keep working, and the new work lands under a fresh `## Unreleased` ABOVE it. The
# stager used to SKIP any repo in that state ("already has a heading"), preflight [9] stayed red on the
# stranded section, and release.sh gates on preflight — so the tooling could not clear a state the
# tooling's own workflow produces. Found by a release-mechanics review; the only route left was
# hand-editing six changelogs, which is what lost three steps on 0.24.
say "1b. release-stage.sh FOLDS into an existing version heading instead of skipping"
# ON ITS OWN COPY, for the reason row 1b2 states twelve lines down and this row did not honour: it
# stages a DIFFERENT version (0.27.0) into two repos of the SHARED fixture and leaves them uncommitted,
# so groups 2 and 3 inherit a candor-swift and a candor-spec whose newest heading is 0.27.0 and whose
# trees are dirty. That was invisible while an empty `## Unreleased` was SKIPPED; now that it is STUBBED,
# group 2's "second run makes zero edits" saw two real edits and its dirty-tree rows refused on the wrong
# repo. Neither is a defect in the code under test — both are this row reaching forward into its
# neighbours, which is exactly the lesson 1b2 was written to record.
BFIX="$(mktemp -d)"; cp -R "$FIX/." "$BFIX/"
FOLD="$BFIX/candor-swift/CHANGELOG.md"
printf '# Changelog\n\n## Unreleased\n\n- **stranded work** that landed after the heading was drafted.\n\n## [0.27.0] — 2026-08-07\n\n- the entry that was already written.\n' > "$FOLD"
# `-c user.email/-c user.name`, like every other commit in this file: a CI runner has NO git identity,
# so a bare `git commit` FAILS there and silently leaves the tree dirty. Green locally, red in CI — the
# exact class this project keeps a checklist for, and I reintroduced it twice in one commit.
(cd "$BFIX/candor-swift" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "fold fixture" 2>/dev/null)
ROOT="$BFIX" VER=0.27.0 DATE=2026-08-08 python3 "$BFIX/candor/bin/_stage_changelogs.py" >/dev/null 2>&1
grep -qE '^## Unreleased$' "$FOLD" && [ -z "$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f && NF' "$FOLD")" ] \
  && ok "Unreleased is left EMPTY, so preflight [9] can go green" \
  || { bad "work is still stranded under Unreleased — the deadlock"; sed -n '1,12p' "$FOLD"; }
awk '/^## \[0\.27\.0\]/{f=1;next} /^## /{f=0} f' "$FOLD" | grep -q "stranded work" \
  && ok "the stranded entry was folded INTO the version section" || bad "the entry did not land in [0.27.0]"
awk '/^## \[0\.27\.0\]/{f=1;next} /^## /{f=0} f' "$FOLD" | grep -q "already written" \
  && ok "…and the entry that was already there survived" || bad "folding overwrote the existing entry"
# candor-spec was not in the stager's loop at all while preflight [9] checked it — the repo the rung is
# AUTHORED in was the one repo staging could not stage. Its headings are floor-shaped, not `## [x.y.z]`.
mkdir -p "$BFIX/candor-spec"
printf '# Changelog\n\n## Unreleased\n\n- **spec work** that landed after the floor heading.\n\n## 0.27 — current floor (a thing)\n\n- the floor entry.\n' > "$BFIX/candor-spec/CHANGELOG.md"
ROOT="$BFIX" VER=0.27.0 DATE=2026-08-08 python3 "$BFIX/candor/bin/_stage_changelogs.py" >/dev/null 2>&1
awk '/^## 0\.27 —/{f=1;next} /^## /{f=0} f' "$BFIX/candor-spec/CHANGELOG.md" | grep -q "spec work" \
  && ok "candor-spec folds too, into its FLOOR-shaped heading" || bad "candor-spec still unstaged"
rm -rf "$BFIX"

# ── 2026-08-08: the umbrella tarball carries ENGINE_PIN, and brew hashes that tarball. Cutting the
# umbrella before the pin moves ships a $VER front door that fetches the PREVIOUS line's engines.
# THE WRAPPER, NOT THE HELPER. Rows 1b call `_stage_changelogs.py` directly — so when the helper gained
# a `FOLD` verb the shell wrapper's `case` did not know, its `*) die` arm fired on the first fold line and
# `release-stage.sh` exited RED over edits already correctly on disk, and all 55 assertions stayed green.
# A test that bypasses the integration point is a test of the wrong thing. This row drives the WRAPPER.
#
# ON ITS OWN COPY, because the first version of this row staged a different version into the SHARED
# fixture and broke groups 2 and 3 downstream — passing itself while failing its neighbours, which is its
# own small lesson about tests that mutate what comes after them.
say "1b2. release-stage.sh (the WRAPPER) survives a fold-shaped tree"
WFIX="$(mktemp -d)"; cp -R "$FIX/." "$WFIX/"
for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec candor; do
  [ -d "$WFIX/$r" ] || mkdir -p "$WFIX/$r"
  printf '# Changelog\n\n## Unreleased\n\n- stranded.\n\n## [0.28.0] — 2026-08-07\n\n- already here.\n' > "$WFIX/$r/CHANGELOG.md"
  # Identity flags AND a hard check: a silent commit failure here leaves the copy dirty, `release-stage.sh`
  # correctly refuses it, and the row then reports "the wrapper died" for a reason that is not the wrapper.
  # A test whose setup can fail quietly measures its own setup.
  ( cd "$WFIX/$r" && git add -A && git -c user.email=t@e -c user.name=t commit -qm fold ) >/dev/null 2>&1
  [ -z "$(git -C "$WFIX/$r" status --porcelain 2>/dev/null)" ] || bad "1b2 setup: $r is dirty — the wrapper row would misreport"
done
wout="$(CANDOR_ROOT="$WFIX" bash "$WFIX/candor/bin/release-stage.sh" 0.28.0 2>&1)"; wrc=$?
[ "$wrc" = 0 ] && ok "the wrapper exits 0 on a fold" \
  || { bad "release-stage.sh died on its own helper's output (rc=$wrc)"; echo "$wout" | grep -iE "✘|FOLD" | head -3; }
echo "$wout" | grep -q "^.*FOLD candor" && bad "a raw FOLD line reached the operator unformatted" \
  || ok "fold lines are reported as edits, not raw helper output"
rm -rf "$WFIX"

say "1c. release.sh REFUSES to cut the umbrella while ENGINE_PIN lags"
# The REAL script: the fixture tree carries only what this test copies into it, and release.sh is read
# rather than run here (running it would publish).
REALREL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/release.sh"
grep -q 'rs_pin_violations' "$REALREL" && ok "the ENGINE_PIN guard exists in release.sh" || bad "no ENGINE_PIN guard"
awk '/^rel candor +"/{u=NR} /^say "6\. cross-repo pins/{p=NR} END{exit !(u>p && p>0)}' "$REALREL" \
  && ok "the umbrella release is cut AFTER the pin step, not before" \
  || bad "the umbrella is still cut before ENGINE_PIN moves"

# THE DIE MESSAGE MUST SURVIVE BEING PRINTED. `bash -n` cannot see this: backticks inside a
# double-quoted string are valid syntax AND live command substitution, so a message written with
# `bin/candor` in prose renders as the OUTPUT of running bin/candor — which is to say, as nothing, with
# the file names silently deleted. Measured: the step-7 remedy came out reading "CHANGELOG. ,  and
# jbang-catalog.json all count as SOURCE", losing exactly the three filenames it exists to name. This
# die fires on EVERY release's first pass by design, so it is the one message an operator is guaranteed
# to read. Render it and compare, rather than trusting a parse check.
#
# EXTRACTION IS THE DANGEROUS PART, and it used to be a BOOBY TRAP FOR THE NEXT EDITOR. The range was
# `/MUST ALSO TOUCH/,/fails on a pending run/` — prose at BOTH ends. An awk range whose closing pattern
# never matches runs to END OF FILE, silently, and the whole remainder of release.sh was then fed to
# `eval "cat <<EOF"` — every `$(…)` and backtick in it live. So correcting one stale sentence in the
# remedy (which is exactly what this release does: [10] now WAITS for pending CI, so "wait before the
# re-run" had to go) would have executed the tail of the release script. The test punished the fix it
# exists to enable.
#
# Both anchors are STRUCTURAL now — the `die "` that opens the string and the line that closes it — and
# the extractor FAILS CLOSED: no start, no end, or an implausible span reports and renders nothing. The
# eval is bounded by construction rather than by a sentence somebody might reword.
extract_die() {  # <file> <start-regex> — prints the die string's lines; nonzero if it cannot bound it
  # `closed` is tracked EXPLICITLY. The first version tested only `n > 40` in END, so a start line
  # followed by three unterminated ones fell off the bottom of the file and exited 0 with a partial
  # block — the run-to-EOF failure this rewrite exists to remove, reintroduced inside its replacement.
  # The probe below caught it on the first run. Running the negative case is not a formality.
  # QUOTE PARITY, not "the line ends in a quote". The ends-in-a-quote test stops at the first
  # CONTINUATION line that happens to end in `"` — an escaped \" closing a quoted phrase, or a line
  # broken after a quoted word — and returns 0 with a PARTIAL block. Latent today (the current remedy has
  # no such line, all twelve checked) and it fails in the safe direction, but with the wrong diagnosis:
  # the truncated render trips the "backticks are executing" row, sending the reader after a defect that
  # is not there. A shell double-quoted string closes when the running count of UNESCAPED double quotes
  # returns to even, which is the actual rule and not a proxy for it.
  awk -v re="$2" '
    function unescaped_quotes(s,   i, c, n, esc) {
      n = 0; esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (esc) { esc = 0; continue }
        if (c == "\\") { esc = 1; continue }
        if (c == "\"") n++
      }
      return n
    }
    !f && $0 ~ re { f=1; n=1; q = unescaped_quotes($0); print
                    if (q % 2 == 0) { closed=1; exit 0 }
                    next }
    f { n++; print; q += unescaped_quotes($0)
        if (q % 2 == 0) { closed=1; exit 0 }
        if (n > 40) { toolong=1; exit 3 } }
    END { if (!f) exit 2; if (toolong) exit 3; if (!closed) exit 4 }
  ' "$1"
}
# THE EXTRACTOR IS PROVED ABLE TO FAIL before it is trusted — the same rule this project applies to
# every oracle. A start line with no closing quote must come back nonzero, not come back with the file.
_probe="$(mktemp)"; printf 'x\ndie "opened and never closed\n  more prose\n' > "$_probe"
extract_die "$_probe" 'die "opened' >/dev/null 2>&1 \
  && bad "extract_die returned success on an UNTERMINATED die string — the run-to-EOF trap is back" \
  || ok "extract_die fails closed when the die string has no end (probe)"
extract_die "$_probe" 'no such line' >/dev/null 2>&1 \
  && bad "extract_die returned success when its start anchor matched nothing" \
  || ok "…and when the start anchor matches nothing"
# THE EARLY-CLOSE CASE, which the two probes above cannot see: both exercise a string that never ends.
# This one ends in the RIGHT place but has an intermediate line ending in a quote on the way.
printf 'die "opens here\n  a line ending in a quoted \\"word\\"\n  and the real end is here"\nafter=1\n' > "$_probe"
_early="$(extract_die "$_probe" 'die "opens')"
printf '%s' "$_early" | grep -q 'the real end is here' \
  && ok "…and it does not stop early on a continuation line that ends in a quote" \
  || bad "extract_die stopped at an intermediate quote — the block is TRUNCATED, and the render row will blame backticks"
printf '%s' "$_early" | grep -q 'after=1' \
  && bad "extract_die ran PAST the closing quote into the following script" \
  || ok "…and it stops at the closing quote, not after it"
rm -f "$_probe"

if STEP7=$(extract_die "$REALREL" '^[[:space:]]*die "ENGINE_PIN mismatch'); then
  ok "step 7's remedy is bounded by its own die string (not by a sentence)"
  printf '%s\n' "$STEP7" | grep -q 'MUST ALSO TOUCH' \
    && ok "…and still carries the pin-bump-touches-the-CHANGELOG warning" \
    || bad "step 7's remedy no longer warns that the pin-bump commit must touch the CHANGELOG"
  printf '%s\n' "$STEP7" | grep -q 'bin/candor' \
    && ok "step 7's remedy names bin/candor in its SOURCE text" \
    || bad "step 7's remedy lost bin/candor from its source text"
  # The block references $VER and $PINMSG, which release.sh has bound and this harness does not —
  # under `set -u` the heredoc died and RENDERED came back EMPTY, which the case below reports as
  # "backticks are executing". A right verdict for the wrong reason is still a wrong instrument, so:
  # bind them, and say so separately when nothing rendered at all.
  # shellcheck disable=SC2034  # all three ARE read — by the heredoc that `eval` expands below
  RENDERED=$(cd /tmp && VER="0.0.0" PINNED="0.0.0" PINMSG="       · java is pinned to 0.0.0"; eval "cat <<CANDOR_EOF
$STEP7
CANDOR_EOF" 2>/dev/null)
  [ -n "$RENDERED" ] || bad "step 7's remedy rendered to NOTHING — the heredoc itself failed, so the substitution check below did not run"
  case "$RENDERED" in
    *'bin/candor'*'adopt/*.yml'*'## Unreleased'*)
      ok "…and all three survive being RENDERED (no live backtick substitution)" ;;
    *) bad "step 7's remedy is garbled when printed — backticks are executing; escape them as \\\`" ;;
  esac
else
  bad "could not bound step 7's die string in release.sh — the remedy went UNCHECKED (nothing rendered)"
fi

say "2. release-stage.sh is idempotent and refuses a dirty tree"
# Commit ALL of them first: run 1 leaves every fixture repo dirty, and the stager refuses a dirty tree —
# so an un-committed second run tests the refusal, not idempotence. (It did, and reported "not idempotent".)
for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec candor; do
  ( cd "$FIX/$r" && git add -A && git -c user.email=t@e -c user.name=t commit -qm staged )
done
out2="$(CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.26.0 2>&1)"
# the summary line always contains the words "already-current", so assert on the COUNT: a second run must
# make ZERO edits. Matching the phrase would have passed on the first run too.
n2="$(echo "$out2" | sed -n 's/^release-stage: \([0-9]*\) edit(s).*/\1/p')"
is "second run makes zero edits" '0' "${n2:-missing}"
# THE Cargo.lock ARM, now that the fixture is a real workspace it can enter. `cargo update` SUCCEEDS on a
# no-op, so judging the arm by its exit code reported an edit every run — which is what shipped, and what
# the zero-edit row above cannot see unless this arm actually runs. Skipped, loudly, without cargo.
if command -v cargo >/dev/null 2>&1; then
  echo "$out" | grep -qi 'Cargo.lock' \
    && ok "the stager REACHES its Cargo.lock arm (the fixture workspace resolves)" \
    || bad "the Cargo.lock arm was not reached — the fixture is not a resolvable workspace again"
  [ -f "$FIX/candor-rust/Cargo.lock" ] \
    && ok "…and a lock file was produced" || bad "no Cargo.lock was written"
  # ASSERT THE BEHAVIOUR, NOT THE STAGER'S WORDING. This grepped for the literal `same()` message, so
  # (a) rewording that one line failed the row with "no longer idempotent", which would be false, and
  # (b) it passed against a stager whose SAME/OK discrimination was DEAD, because a dead discriminator
  # printed the SAME line unconditionally — the row read the prose that the defect produced. The lock's
  # BYTES before and after the second run are the actual property, and no wording can fake them.
  cp "$FIX/candor-rust/Cargo.lock" "$FIX/lock.snapshot" 2>/dev/null
  CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.26.0 >/dev/null 2>&1
  cmp -s "$FIX/lock.snapshot" "$FIX/candor-rust/Cargo.lock" \
    && ok "…and a repeat stage leaves Cargo.lock BYTE-IDENTICAL (idempotent in fact, not in wording)" \
    || bad "a repeat stage rewrote Cargo.lock — release-stage is not idempotent"
  echo "$out2" | grep -qiE 'Cargo\.lock (already at|absent)' \
    && ok "…and the second run REPORTS it as unchanged rather than as an edit" \
    || { bad "the lock arm claimed an edit on a no-op — the SAME/OK discrimination is dead"; echo "$out2" | grep -i lock | head -2; }
else
  note_skip "cargo is not installed — the Cargo.lock arm was NOT exercised by this run"
fi
is "second run changed nothing" '0.26.0' "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$FIX/candor-ts/package.json")"
# EVERY REPO IT EDITS, not just the engine it happened to dirty. The guard looped the five ENGINE repos
# while the script also edits `candor/bin/candor` and, via `_stage_changelogs.py`, candor-spec's and the
# umbrella's CHANGELOG — so the two repos a release author is most likely to have open (the spec they just
# amended, the umbrella they are running this FROM) were the two it did not cover. This row dirties each
# in turn, because one witness standing for the rest is how the gap survived: the old row dirtied
# candor-java, which was inside the guarded five.
for r in candor-java candor-spec candor; do
  printf 'dirt\n' >> "$FIX/$r/CHANGELOG.md"
  # ASSERT WHY IT REFUSED, not just that it did. With the old five-repo guard the `candor` row PASSED —
  # the run exited non-zero for an unrelated reason (a dirty umbrella CHANGELOG derails
  # `_stage_changelogs.py`), so "it refused" was true and "the guard covers this repo" was not. A row that
  # cannot tell the intended refusal from an incidental failure is the could-not-evaluate collapse in
  # miniature, and it is the exact shape this harness keeps finding elsewhere.
  dout="$(CANDOR_ROOT="$FIX" bash "$FIX/candor/bin/release-stage.sh" 0.27.0 2>&1)"; drc=$?
  if [ "$drc" = 0 ]; then
    bad "staged over a dirty $r — that repo is edited by this script and unguarded"
  elif printf '%s' "$dout" | grep -q "$r has uncommitted changes"; then
    ok "refuses a dirty tree in $r, BY NAME (the guard covers it)"
  else
    bad "the run failed on a dirty $r but not via the guard — '$(printf '%s' "$dout" | grep -m1 '✘' | cut -c1-70)'"
  fi
  ( cd "$FIX/$r" && git checkout -- CHANGELOG.md 2>/dev/null ) || sed -i.bak '$ d' "$FIX/$r/CHANGELOG.md"
done
( cd "$FIX/candor-java" && git checkout -q . )

say "3. the notes release.sh would publish"
# DEFECT 1 again, at the extraction site: by POSITION this yields the empty Unreleased; by VERSION it
# yields the real entry. This is the check that would have stopped five empty GitHub releases.
byver="$(awk -v v='## [0.26.0]' 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$FIX/candor-rust/CHANGELOG.md" | wc -l | tr -d ' ')"
bypos="$(awk '/^## /{n++} n==1{print} n==2{exit}' "$FIX/candor-rust/CHANGELOG.md" | wc -l | tr -d ' ')"
[ "$byver" -gt 3 ] && ok "version-anchored notes are non-empty ($byver lines)" || bad "version-anchored notes are empty ($byver lines)"
[ "$bypos" -le 2 ] && ok "position-anchored notes WOULD have been empty ($bypos lines) — the defect is reproduced" \
                   || bad "position-anchored extraction no longer reproduces the defect; this test has stopped discriminating"
# the umbrella has no version heading at all — release.sh must fall back, not die.
# DRIVEN THROUGH THE REAL SELECTOR, not a copy of it. The two rows here re-implemented release.sh's awk,
# so they went on measuring the old inline logic after selection moved to `bin/_release_notes.sh` — the
# "a test that bypasses the integration point is a test of the wrong thing" note in row 1b2, at the one
# site where it decides what gets published.
uver="$(awk -v v='## [0.26.0]' 'index($0,v)==1{f=1;print;next} f&&/^## /{exit} f{print}' "$FIX/candor/CHANGELOG.md" | wc -l | tr -d ' ')"
is "umbrella has no version-anchored section" '0' "$uver"
ufall="$(bash "$UMBRELLA/bin/_release_notes.sh" candor 0.26 0.26.0 "$FIX/candor/CHANGELOG.md" 2>/dev/null | wc -l | tr -d ' ')"
[ "$ufall" -gt 2 ] && ok "umbrella falls back to its newest dated section ($ufall lines)" || bad "umbrella fallback is empty"

# ── 2026-08-25: THE EMPTY `## Unreleased` REPUBLISHED THE PREVIOUS VERSION'S NOTES ────────────────
# `_stage_changelogs.py` SKIPPED an empty `## Unreleased` (deliberately — nothing should ship
# unlabelled), so a repo with nothing to say got no `## [VERSION]` heading; `release.sh` then fell
# through to "the newest non-empty section", i.e. the PREVIOUS release's notes, under the new tag, with
# a yellow `•` at the end of a long release. Hit at 0.29.1 — candor-swift's and candor-agents' entries
# there read, verbatim, "**Family build bump only — no engine changes in this repo**", hand-written for
# exactly this reason — and twice on 2026-08-25, the second time with all seven repos empty.
#
# Every row here was written by pointing it at the PRE-FIX logic first and watching it fail: 12 of the
# 12 REJECT rows went green on the old code, five of them publishing the literal stale body. The ACCEPT
# rows passed on both, which is what says this battery discriminates rather than just refusing things.
say "3b. release.sh REFUSES notes it cannot tie to the version being cut"
NOTES="$UMBRELLA/bin/_release_notes.sh"
NW="$(mktemp -d)"
PREVMARK='STALE-PREVIOUS-NOTES'
nrow() { # $1 label ; $2 repo ; $3 want-exit ; $4 changelog (MISSING = no file) ; $5 must-appear on stdout
  local label="$1" repo="$2" want="$3" content="$4" need="${5:-}" d out err rc why=""
  d="$NW/r$((RANDOM))$((RANDOM))"; mkdir -p "$d"; out="$d/out"; err="$d/err"
  [ "$content" = MISSING ] || printf '%s' "$content" > "$d/CHANGELOG.md"
  bash "$NOTES" "$repo" 0.32 0.32.1 "$d/CHANGELOG.md" > "$out" 2> "$err"; rc=$?
  [ "$rc" = "$want" ] || why="exit $rc, wanted $want"
  # A REFUSAL MUST PUBLISH NOTHING. `gh release create -F` reads whatever file it is handed, so a
  # caller that ignores the exit code must still be unable to publish a diagnostic — or, far worse,
  # the stale body the refusal exists to stop. Both are asserted, because they fail differently.
  if [ "$want" = 3 ]; then
    [ -s "$out" ] && why="${why:+$why; }refused but wrote $(wc -c <"$out" | tr -d ' ') bytes to stdout"
    grep -q "$PREVMARK" "$out" 2>/dev/null && why="${why:+$why; }THE STALE NOTES WERE PUBLISHED ANYWAY"
    grep -q 'Remedy\|refusing\|REFUSING' "$err" || why="${why:+$why; }refused with no remedy on stderr"
  fi
  [ -z "$need" ] || grep -qF "$need" "$out" || why="${why:+$why; }stdout lacks '$need'"
  [ -z "$why" ] && ok "$label" || bad "$label — $why"
}
# MUST REJECT ────────────────────────────────────────────────────────────────────────────────────
nrow "empty Unreleased above the previous version" candor-rust 3 \
"# CL

## Unreleased

## [0.32.0] — 2026-08-25

$PREVMARK
"
nrow "…the bracketed [Unreleased] spelling too" candor-rust 3 \
"# CL

## [Unreleased]

## [0.32.0] — 2026-08-25

$PREVMARK
"
nrow "…and an Unreleased carrying only a rung marker" candor-swift 3 \
"# CL

## Unreleased — ⟨spec 0.33⟩

## [0.32.0] — 2026-08-25

$PREVMARK
"
nrow "no Unreleased at all — just the previous version" candor-ts 3 \
"# CL

## [0.32.0] — 2026-08-25

$PREVMARK
"
# A HEADING IS NOT NOTES. `## [0.32.1]` with nothing under it publishes a release whose body reads, in
# full, as that one line — and for candor-spec it used to slide onto the FLOOR section below and publish
# the floor's notes under a patch tag, which is the same wrong-notes defect through the fallback.
nrow "a version heading with no body under it" candor-java 3 \
"# CL

## [0.32.1] — 2026-08-25

## [0.32.0] — 2026-08-25

$PREVMARK
"
nrow "…and a bodyless one must not slide onto the floor section" candor-spec 3 \
"# CL

## [0.32.1] — 2026-08-25

## 0.32 — the floor

$PREVMARK
"
nrow "no CHANGELOG.md at all" candor-agents 3 MISSING
nrow "a file containing nothing but an empty Unreleased" candor-rust 3 \
"# CL

## Unreleased
"
# THE UMBRELLA HAS THE SAME DEFECT IN ITS OWN SPELLING, and the brief that found this one did not name
# it. Its changelog is DATED, so the notes are picked by POSITION — and with no `(unreleased)` heading to
# stamp, "the newest section" is the previous release's. The `(released … as $VER)` stamp the stager
# writes is the only thing tying a dated section to a version, so the publisher now demands it.
nrow "umbrella: newest dated section stamped as the PREVIOUS version" candor 3 \
"# CL

## 2026-08-25 — the 0.32.0 cut (released 2026-08-25 as 0.32.0)

$PREVMARK
"
nrow "umbrella: newest dated section never staged (still '(unreleased)')" candor 3 \
"# CL

## 2026-08-25 — a cut in progress (unreleased)

body

## 2026-08-02 — older (released 2026-08-02 as 0.32.0)

$PREVMARK
"
nrow "umbrella: stamped for a LATER version than the one being cut" candor 3 \
"# CL

## 2026-08-26 — next (released 2026-08-26 as 0.33.0)

body

## 2026-08-25 — this one (released 2026-08-25 as 0.32.1)

$PREVMARK
"
# THE FENCE ON THE POSITIONAL ARM IS AN ALLOWLIST NAMING ONE REPO, and this row is why that shape is
# safe here: its omissions fail by REFUSING (loud, operator-only, one re-run), not by guessing.
nrow "a dated changelog in a repo that is not the umbrella" candor-umbrella 3 \
"# CL

## 2026-08-25 — dated (released 2026-08-25 as 0.32.1)

$PREVMARK
"
# MUST ACCEPT ────────────────────────────────────────────────────────────────────────────────────
# Without these the whole group is satisfied by a program that refuses everything.
nrow "[0.32.1] with a body, under the fresh empty Unreleased staging opens" candor-rust 0 \
"# CL

## Unreleased

## [0.32.1] — 2026-08-25

THE NEW NOTES

## [0.32.0] — 2026-08-25

$PREVMARK
" "THE NEW NOTES"
nrow "…even when Unreleased above it has content for the NEXT release" candor-ts 0 \
"# CL

## Unreleased

- work for the next rung

## [0.32.1] — 2026-08-25

THE NEW NOTES

## [0.32.0] — 2026-08-25

$PREVMARK
" "THE NEW NOTES"
nrow "…and when the heading carries no date suffix" candor-swift 0 \
"# CL

## [0.32.1]

THE NEW NOTES
" "THE NEW NOTES"
nrow "candor-spec's FLOOR-shaped heading when no patch section exists" candor-spec 0 \
"# CL

## Unreleased

## 0.32 — current floor

THE NEW NOTES
" "THE NEW NOTES"
nrow "umbrella: newest dated section stamped as THIS version" candor 0 \
"# CL

## 2026-08-25 — this cut (released 2026-08-25 as 0.32.1)

THE NEW NOTES

## 2026-08-02 — older (released 2026-08-02 as 0.32.0)

$PREVMARK
" "THE NEW NOTES"
nrow "umbrella: …with the empty Unreleased staging leaves above it" candor 0 \
"# CL

## Unreleased

## 2026-08-25 — this cut (released 2026-08-25 as 0.32.1)

THE NEW NOTES
" "THE NEW NOTES"

# THE OTHER HALF OF THE FIX: staging must be able to REACH the accepted state without a human writing a
# changelog entry by hand on release day. That is what turned this into folklore twice — the workaround
# was known, performed by hand, and skipped at the end of a long day.
say "3c. an EMPTY \`## Unreleased\` is STUBBED, not skipped"
SW="$(mktemp -d)"
for r in candor-rust candor-spec; do mkdir -p "$SW/$r"; done
mkdir -p "$SW/candor"
printf '# CL\n\n## Unreleased\n\n## [0.32.0] — 2026-08-25\n\n%s\n' "$PREVMARK" > "$SW/candor-rust/CHANGELOG.md"
# candor-spec: an empty Unreleased ABOVE an already-written section for the version being cut. Nothing is
# stranded and the version has its notes, so this must stay SAME — stubbing here would staple "no changes
# recorded" on top of a section full of them.
printf '# CL\n\n## Unreleased\n\n## [0.32.1] — 2026-08-25\n\nreal notes already written.\n' > "$SW/candor-spec/CHANGELOG.md"
printf '# CL — umbrella\n\ndated, most recent first.\n\n## 2026-08-25 — the floor cut (released 2026-08-25 as 0.32.0)\n\n%s\n' "$PREVMARK" > "$SW/candor/CHANGELOG.md"
sout="$(ROOT="$SW" VER=0.32.1 DATE=2026-08-25 python3 "$UMBRELLA/bin/_stage_changelogs.py" 2>&1)"
printf '%s' "$sout" | grep -q '^STUB candor-rust:' \
  && ok "an empty \`## Unreleased\` becomes a \`## [0.32.1]\` build-bump entry" \
  || { bad "the empty section was skipped — the state that republished stale notes"; printf '%s\n' "$sout" | head -4; }
printf '%s' "$sout" | grep -q '^SAME candor-spec:' \
  && ok "…but NOT when that version already has a section of its own (no stub over real notes)" \
  || { bad "the stager stubbed a version that already had its notes"; printf '%s' "$sout" | grep candor-spec; }
printf '%s' "$sout" | grep -q '^STUB candor:' \
  && ok "…and the umbrella's dated changelog gets a stamped dated section" \
  || { bad "the umbrella was left with only the PREVIOUS release's dated section"; printf '%s' "$sout" | grep '^\w* candor:'; }
grep -q '^## Unreleased$' "$SW/candor-rust/CHANGELOG.md" \
  && ok "…and a fresh empty \`## Unreleased\` is still opened above it" || bad "no fresh Unreleased after a stub"
# THE POSTCONDITION, ASSERTED THROUGH THE PUBLISHER. This is the row that ties the two halves together:
# whatever the stager did, `release.sh` must now be able to name notes for the version being cut.
for r in candor-rust candor-spec candor; do
  bash "$NOTES" "$r" 0.32 0.32.1 "$SW/$r/CHANGELOG.md" > "$SW/$r.notes" 2>"$SW/$r.err"; nrc=$?
  if [ "$nrc" = 0 ] && ! grep -q "$PREVMARK" "$SW/$r.notes"; then
    ok "after staging, release.sh publishes $r's OWN 0.32.1 notes"
  else
    bad "$r: exit $nrc, and $( grep -q "$PREVMARK" "$SW/$r.notes" 2>/dev/null && echo 'THE PREVIOUS NOTES WERE SELECTED' || echo 'no notes at all')"
  fi
done
# CONTROL: staging is a NO-OP on the second run. A stub that re-stubbed would grow a section per run.
sout2="$(ROOT="$SW" VER=0.32.1 DATE=2026-08-25 python3 "$UMBRELLA/bin/_stage_changelogs.py" 2>&1)"
printf '%s' "$sout2" | grep -q '^STUB' \
  && { bad "re-running the stager stubbed again — the file grows a section per run"; printf '%s' "$sout2" | grep '^STUB'; } \
  || ok "CONTROL: re-running the stager stubs nothing (it is a no-op, as its header promises)"
is "…and the umbrella has exactly one 0.32.1 dated section" '1' \
   "$(grep -c 'as 0.32.1)' "$SW/candor/CHANGELOG.md" | tr -d ' ')"
# CONTROL: the stub is a CLAIM, so `release-stage.sh` must surface it rather than bury it in ~19 edits.
grep -q 'GENERATED CHANGELOG STUBS — READ THESE BEFORE COMMITTING' "$UMBRELLA/bin/release-stage.sh" \
  && ok "CONTROL: release-stage.sh re-prints generated stubs under its summary" \
  || bad "a generated \"no changes recorded\" claim is reported once, mid-run, and scrolled past"
rm -rf "$NW" "$SW"

# THE GATE MUST ASK THE PUBLISHER'S QUESTION, NOT ITS OWN VERSION OF IT. preflight [9] certified a tree
# with an empty `## Unreleased` as clean — which was the exact tree that mis-published. [9b] closes it by
# CALLING `_release_notes.sh`, so the gate and the publisher cannot disagree.
grep -q '_release_notes.sh' "$UMBRELLA/bin/release-preflight.sh" \
  && ok "preflight [9b] asks the publisher's own selection program" \
  || bad "preflight re-derives 'is there a heading' — a gate that can go green on a cut that then refuses"

say "4. release.sh hands update-candor.sh a TAG, not a bare version"
# DEFECT 7 (0.26): passing $VER made update-candor.sh create a SECOND tag beside v$VER.
grep -q 'update-candor.sh" "v\$VER"' "$UMBRELLA/bin/release.sh" \
  && ok "release.sh passes v\$VER" || bad "release.sh passes a bare version — a second tag per release"
grep -q 'already exists — reusing it' "$UMBRELLA/scripts/update-candor.sh" \
  && ok "update-candor.sh reuses an existing tag/release" || bad "update-candor.sh would recreate the tag"

say "5. spec-bump.sh — the floor-bump rehearsal"
# The ⟨0.27⟩ bump was done by hand and turned SIX repos red on version-coupled assertions, every one
# findable locally. `spec-bump.sh` exists so a contract bump is rehearsed rather than discovered in CI.
SB=""
mkb() { mkdir -p "$(dirname "$SB/$1")"; printf '%s\n' "$2" > "$SB/$1"; }
# EVERY ROW BUILDS ITS OWN. $1 is the swift declaration line (so a row can move the site), $2 the SPEC.md
# headline (so a row can make it unreadable). Chaining these rows off one fixture meant the final control
# failed for a REAL reason — an earlier row had deliberately left swift unbumped, so the family it was
# asked to call consistent genuinely was not.
sbfix() {
  [ -n "$SB" ] && rm -rf "$SB"
  SB="$(mktemp -d)"
  mkb candor-rust/crates/candor-report/src/lib.rs 'pub const SPEC_VERSION: &str = "0.27";'
  mkb candor-java/src/main/java/io/poly/candor/Candor.java '    static final String SPEC_VERSION = "0.27";'
  mkb candor-ts/scan.mjs 'const SPEC_VERSION = "0.27";'
  mkb candor-ts/query.mjs 'const SPEC_VERSION = "0.27";'
  mkb candor-swift/Sources/candor-swift/main.swift "${1:-let specVersion = \"0.27\"}"
  mkb candor-agents/candor_agents/scan.py 'SPEC = "0.27"'
  mkb candor-spec/SPEC.md "${2:-**Version 0.27** — all code engines declare \`0.27\`; the floor is conformance-pinned.}"
  for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec; do
    ( cd "$SB/$r" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm i )
  done
}
sbfix
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" --check >/dev/null 2>&1   && ok "--check passes when the seven declarations agree" || bad "--check failed on a consistent tree"
# a SPLIT is the thing --check exists to catch: one engine emitting a contract the others do not
sbfix 'let specVersion = "0.26"'
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" --check >/dev/null 2>&1   && bad "--check PASSED a four-way contract split" || ok "--check catches a declaration split"
sbfix
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" 0.28 --decls-only >/dev/null 2>&1
n=$(grep -rl '"0\.28"\|Version 0\.28' "$SB" 2>/dev/null | wc -l | tr -d ' ')
is "bump moves all seven declarations" '7' "$n"
# a dirty tree must be refused: the script rewrites seven files across seven repos.
# COMMIT THE BUMP FIRST. The 0.28 run above left every repo dirty, so the added dirt was doing nothing and
# this row would have passed with the `printf` deleted — it asserted the refusal, but not the refusal it
# names, and a row that cannot tell those apart stops discriminating the moment the setup changes.
sbfix
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" 0.29 --decls-only >/dev/null 2>&1   && ok "a CLEAN tree is accepted (the control this row needs)" || bad "refused a clean tree"
sbfix; printf 'dirt\n' >> "$SB/candor-ts/scan.mjs"
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" 0.29 --decls-only >/dev/null 2>&1   && bad "staged over a dirty tree" || ok "refuses a dirty tree"

# A PRINTED ✘ THAT DOES NOT REACH THE EXIT CODE. Both of this script's false greens came from one line:
# its `bad()` printed and counted nothing, where release-preflight.sh's and release-verify.sh's both
# increment. A rehearsal that reports GREEN over a split family is worse than no rehearsal.
sbfix 'let specVersion: String = "0.27"'    # the declaration site MOVED — an ordinary refactor between rungs
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" 0.28 --decls-only >/dev/null 2>&1 \
  && bad "a MOVED declaration site was skipped and the run still exited 0 — one engine left on the old contract" \
  || ok "a skipped declaration site fails the run"
is "the skipped site was NOT bumped (so the run really was split)" '0.27' \
   "$(grep -oE '[0-9]+\.[0-9]+' "$SB/candor-swift/Sources/candor-swift/main.swift" | head -1)"
is "and the others DID move (so the split is real, not a no-op run)" '0.28' \
   "$(grep -oE '[0-9]+\.[0-9]+' "$SB/candor-ts/scan.mjs" | head -1)"

# THE CONTRACT DOCUMENT AND ITS OWN VERSION. --check printed `SPEC.md   ?` on the line directly above
# "every declaration agrees" and exited 0 — folding an unreadable answer into the agreement set.
sbfix '' 'Version zero point twenty-seven'
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" --check >/dev/null 2>&1 \
  && bad "--check called an UNREADABLE SPEC.md agreement" || ok "--check fails when the SPEC.md version itself is unreadable"
sbfix
CANDOR_ROOT="$SB" bash "$UMBRELLA/bin/spec-bump.sh" --check >/dev/null 2>&1 \
  && ok "--check still passes a consistent family (the control)" || bad "--check failed a consistent family"

# STEP 3 AND ITS LIVENESS PROBE — previously unreachable from this harness. Every row above drives
# `--decls-only`, which used to exit at step 1, so the remaining-mentions scan and the probe guarding it
# were untested by construction. (The probe exists because that scan once printed a green "no remaining
# mentions" over a loop that `set -u` had killed on its first iteration — a guard against a silent no-op
# that no test could reach is the same shape as the defect it guards.) Step 3 is grep, not a suite, so it
# now runs under --decls-only too.
# COMMIT EVERY REPO BETWEEN RUNS. A bump leaves all seven dirty and the script refuses a dirty tree, so
# the second run would test the REFUSAL and report the probe as asleep. (It did.)
sbcommit() { for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec; do
    ( cd "$SB/$r" && git add -A && git -c user.email=t@e -c user.name=t commit -qm x ) >/dev/null 2>&1
  done; }
sb2() { CANDOR_ROOT="$SB" bash "$1" 0.30 --decls-only 2>&1; }
SBSH="$UMBRELLA/bin/spec-bump.sh"
sbfix; printf 'the engine declares spec 0.27 here\n' > "$SB/candor-rust/lingering.md"; sbcommit
out3="$(sb2 "$SBSH")"
printf '%s' "$out3" | grep -q 'lingering.md' \
  && ok "step 3 REPORTS a mention the bump left behind (reached under --decls-only)" \
  || bad "step 3 did not report a lingering 0.27 mention — the triage step is still unreachable"
# THE PROBE'S TEETH: break the scan in a COPY so it cannot match, and require the run to fail.
#
# THE INJECTION IS DETERMINISTIC, and the first version was not. It reintroduced the exact historic defect
# by unbracing `${OLD}` so the multi-byte `⟩` would swallow the variable name under `set -u` — which works
# on macOS (bash 3.2: `OLD⟩: unbound variable`) and NOT on Linux (bash 5 parses the name as `OLD`, expands
# it, and the scan runs fine). So the row asserted a failure that only exists on one platform, was green
# locally, and turned CI red the moment it was pushed.
#
# Worth more than the fix: THE ORIGINAL DEFECT WAS BASH-3.2-ONLY. The green "no remaining mentions" over a
# scan that never ran could only have happened on a developer's Mac — CI would never have reproduced it,
# whichever way the test had been written. That is why the probe has to live in the script rather than in
# a row, and why the row's job is only to prove the probe still fires.
# The injection is a `return 0` at the top of `scan_for_old`, so the scan matches nothing for ANY input
# including the probe's known-positive fixture. Editing the grep itself was the obvious move and the wrong
# one: that line ends in a `\` continuation, so replacing it orphaned the `--include=` lines below and the
# copy died of a syntax error — a nonzero exit for a reason that has nothing to do with the probe, which
# the row would have read as success. A broken script and a working script whose scan is dead are exactly
# what this row has to tell apart.
# A CLEAN TREE FIRST. The previous run left every fixture repo bumped and dirty, and spec-bump refuses a
# dirty tree — so without this the broken copy never reaches step 3 at all, and BOTH rows below measure
# the refusal instead: the first fails with "the probe is asleep" (it is not, it never ran) and the second
# PASSES, because a run that stopped at the precondition never printed the green line either. That is a
# vacuous pass sitting directly beneath a misdiagnosed failure.
sbfix; printf 'the engine declares spec 0.27 here\n' > "$SB/candor-rust/lingering.md"; sbcommit
BROKE="$SB/broken-spec-bump.sh"
awk '{ print } /^[[:space:]]*scan_for_old\(\) \{[[:space:]]*$/ { print "  return 0" }' "$SBSH" > "$BROKE"
bash -n "$BROKE" 2>/dev/null || bad "the broken copy does not even parse — the teeth row would pass for the wrong reason"
if ! cmp -s "$SBSH" "$BROKE"; then
  out4="$(sb2 "$BROKE")"; rc4=$?
  # …and prove the run REACHED step 3, so neither row below can be satisfied by an early refusal.
  printf '%s' "$out4" | grep -q 'remaining mentions of' \
    || bad "the broken copy never reached step 3 — both teeth rows below are measuring something else"
  { [ "$rc4" != 0 ] && printf '%s' "$out4" | grep -q 'the SCAN is broken'; } \
    && ok "…and the liveness probe FAILS the run when the scan cannot match (teeth)" \
    || bad "a spec-bump whose mentions scan matches nothing still exited $rc4 — the probe is asleep"
  printf '%s' "$out4" | grep -q 'no remaining mentions' \
    && bad "the dead scan still printed a green 'no remaining mentions' ALONGSIDE the probe's ✘" \
    || ok "…and does not also print the reassuring green line"
else
  bad "could not break the mentions scan in the copy — this teeth test asserted nothing"
fi
# THE MAIN PATH, which no row reached — and that is where the regression lived. `remaining_mentions()`
# used the shared `rc` as its probe flag, but on the main path `rc` is step 2's SUITE accumulator, so any
# failed engine suite made the early return fire and step 3's triage list VANISHED beneath its own
# "TRIAGE THESE BY HAND" header. A red rehearsal is exactly when that list is wanted. Every row above
# drives `--decls-only`, which sets `rc=0` immediately before the call — so `rc` is always fresh there
# and the bug could only exist on the path the tests could not take.
#
# This row takes it. The fixture's engine dirs carry no build files, so every suite fails fast (that is
# the CONDITION being tested, not a defect in the fixture) and the run reaches step 3 with rc=1.
sbfix; printf 'the engine declares spec 0.27 here\n' > "$SB/candor-rust/lingering.md"; sbcommit
mainout="$(CANDOR_ROOT="$SB" bash "$SBSH" 0.30 2>&1)"
printf '%s' "$mainout" | grep -q 'lingering.md' \
  && ok "step 3 still lists a mention when the SUITES failed (the main path, rc=1)" \
  || bad "a red suite silenced step 3's triage list — the probe flag is sharing rc again"
printf '%s' "$mainout" | grep -q 'suites failed' \
  && ok "…and the summary names the SUITES as what failed" \
  || bad "the summary mislabelled a suite failure: $(printf '%s' "$mainout" | grep -c 'spec-bump:') summary line(s)"
rm -rf "$SB"

say "6. release.sh gates on preflight in PINS_ADVISORY mode"
# DEFECT 3 (0.26): [3] demands pins that only exist after publishing, while step 0 demands a green
# preflight — unsatisfiable, so every release bypassed the script written to stop bypasses.
grep -q 'PINS_ADVISORY=1 bash "$ROOT/candor/bin/release-preflight.sh"' "$UMBRELLA/bin/release.sh" \
  && ok "step 0 runs preflight with pins advisory" || bad "step 0 would deadlock on check [3]"
grep -q 'PINS_ADVISORY' "$UMBRELLA/bin/release-preflight.sh" \
  && ok "preflight honours PINS_ADVISORY" || bad "preflight has no advisory mode"

say "7b. release-preflight.sh [10] — the CI verdict cannot be self-contradictory"
# WHY THIS SECTION EXISTS. `release-preflight.sh` carries eleven checks and took FOUR fixes in this
# release, and until now the harness touched it only through two `grep -q` string-presence checks — the
# same "a staged site absent from the fixture is an untested site" argument that justified the Cargo.lock
# work, applied to nothing else. Both regressions repaired in that file were of a kind a row can catch.
#
# `gh` IS STUBBED, which is what makes [10] reachable at all: the real one needs auth and a network, and a
# check that can only run on a release day is a check nobody runs. The stub answers `run list --json` with
# whatever run state the row wants, so the branch under test is chosen rather than waited for.
PF="$(mktemp -d)"; mkdir -p "$PF/bin" "$PF/root/candor"
cat > "$PF/bin/gh" <<'GHEOF'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "run list")    printf '%s\n' "$GH_RUNS" ;;
  *)             exit 0 ;;
esac
GHEOF
chmod +x "$PF/bin/gh"
# One real repo, one commit, pushed-looking: [10] asks for HEAD and its upstream.
git -C "$PF/root/candor" init -q 2>/dev/null || { mkdir -p "$PF/root/candor"; git -C "$PF/root/candor" init -q; }
printf 'x\n' > "$PF/root/candor/f.txt"
git -C "$PF/root/candor" add -A
git -C "$PF/root/candor" -c user.email=t@e -c user.name=t commit -qm init
PFSHA="$(git -C "$PF/root/candor" rev-parse HEAD)"
pfrun() { # $1 = the runs JSON
  GH_RUNS="$1" PATH="$PF/bin:$PATH" CANDOR_ROOT="$PF/root" CI_NO_WAIT=1 PINS_ADVISORY=1 \
    bash "$UMBRELLA/bin/release-preflight.sh" 0.99 0.99.0 2>&1
}
# A repo whose CI is STILL RUNNING. The A3 regression made this print ✘ for the repo and then
# "✔ all N repos green on HEAD" underneath it — the failed-AND-green contradiction the same hunk's
# comment claims to have removed, reintroduced from the other side by the fix for it.
pending="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":null,\"status\":\"in_progress\",\"workflowName\":\"ci\"}]")"
printf '%s' "$pending" | grep -q "CI still unfinished" \
  && ok "[10] reports a repo whose CI is still running" \
  || bad "[10] did not report an in_progress run: $(printf '%s' "$pending" | grep -c '')-line output"
printf '%s' "$pending" | grep -q "repos green on HEAD" \
  && bad "[10] printed the all-green summary BESIDE a ✘ — failed AND green in one run" \
  || ok "…and does NOT also print the all-green summary (the verdict is not self-contradictory)"
# …and a real failure standing beside a pending one must still reach the operator. It used to be
# swallowed: the pending regex matched first and only "still waiting" was printed.
both="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"build\"},{\"headSha\":\"$PFSHA\",\"conclusion\":null,\"status\":\"in_progress\",\"workflowName\":\"publish\"}]")"
# `build:failure`, not `build` — the bare word appears elsewhere in preflight's output (workflow names,
# prose), so the loose pattern passed against a version that printed only "CI still unfinished". A row
# whose pattern is satisfied by unrelated text is not asserting the thing its label claims.
printf '%s' "$both" | grep -q "build:failure" \
  && ok "[10] names a REAL failure standing beside a still-running job" \
  || bad "[10] reported only the pending run; the 'build:failure' never reached the operator"
# THE CONTROL: an all-green repo must produce the green summary and no ✘ from [10].
green="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\"}]")"
printf '%s' "$green" | grep -q "repos green on HEAD" \
  && ok "[10] CONTROL: a green repo still gets the all-green summary" \
  || bad "[10] refuses even a passing repo — the rows above would pass against a check that always fails"
printf '%s' "$green" | grep -q "CI still unfinished" \
  && bad "[10] CONTROL: reported a completed success as unfinished" \
  || ok "[10] CONTROL: …and no spurious unfinished line"
rm -rf "$PF"

say "7c. release-preflight.sh [11] — the conformance REUSE stamp cannot outrun the tree"
# The stamp says "conformance was green at these SHAs", and a later run skips the 330-second suite when
# nothing that matters moved. Two ways that can lie, both repaired in this release and neither rowed:
# a stamp written over a DIRTY tree records HEAD for a state that included uncommitted edits, and a
# licensed-path skip that swallows a change under `conformance/` reuses a green for a suite that moved.
#
# `run.sh` is a STUB. The real four-way suite needs four engines and five minutes; what is under test
# here is the stamp bookkeeping around it, and a check that can only run when all four engines are built
# is a check this harness cannot have.
PC="$(mktemp -d)"; mkdir -p "$PC/bin" "$PC/root/candor-spec/conformance" "$PC/root/candor"
cat > "$PC/bin/gh" <<'GHEOF'
#!/bin/bash
case "$1 $2" in "auth status") exit 0 ;; "run list") printf '[]\n' ;; *) exit 0 ;; esac
GHEOF
chmod +x "$PC/bin/gh"
printf '#!/bin/bash\necho "  x -> MATCH"\necho "conformance: OK (stub)"\n' > "$PC/root/candor-spec/conformance/run.sh"
chmod +x "$PC/root/candor-spec/conformance/run.sh"
printf 'stub\n' > "$PC/root/candor-spec/conformance/README.md"
# THE STAMP MUST BE IGNORED, exactly as it is in the real repo (`conformance/.gitignore`). Without this
# the stamp file itself makes candor-spec dirty, the read path refuses on "uncommitted changes", and the
# reuse branch is unreachable — every row below would fail for a reason that is purely the fixture's.
printf '.last-green-shas\n' > "$PC/root/candor-spec/conformance/.gitignore"
printf 'x\n' > "$PC/root/candor/f.txt"
for r in candor-spec candor; do
  ( cd "$PC/root/$r" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )
done
STAMPF="$PC/root/candor-spec/conformance/.last-green-shas"
pcrun() { PATH="$PC/bin:$PATH" CANDOR_ROOT="$PC/root" CI_NO_WAIT=1 PINS_ADVISORY=1 \
            bash "$UMBRELLA/bin/release-preflight.sh" 0.99 0.99.0 2>&1; }

# A CLEAN tree: the suite runs and the stamp is recorded.
out="$(pcrun)"
printf '%s' "$out" | grep -q "conformance OK" && [ -f "$STAMPF" ] \
  && ok "[11] a green run over a CLEAN tree records the reuse stamp" \
  || bad "[11] no stamp after a green run over a clean tree"
# …and the next run REUSES it. Without this the dirty-tree row below cannot mean anything: a stamp that
# is never read is trivially honest.
printf '%s' "$(pcrun)" | grep -q "conformance REUSED" \
  && ok "[11] …and an unchanged tree REUSES it (so the stamp is load-bearing)" \
  || bad "[11] the stamp was written but never reused — the rows below would prove nothing"
# A DIRTY tree: the suite runs, and the stamp must be REMOVED rather than recorded against a bare HEAD.
# DIRTY A FILE THAT IS NOT THE STUB. The first version appended to `run.sh` itself, which made the stub
# a broken script — conformance then FAILED, and the row was measuring a failed suite rather than a
# dirty tree. Two different red states, one of which is not the subject.
printf 'uncommitted\n' >> "$PC/root/candor-spec/conformance/README.md"
dout="$(pcrun)"
printf '%s' "$dout" | grep -q "not recording a reuse stamp" \
  && ok "[11] a run covering UNCOMMITTED changes does not record a stamp, and says so" \
  || bad "[11] silently stamped a dirty tree — reuse would assert a green for a state never tested"
[ -f "$STAMPF" ] \
  && bad "[11] the stale stamp survived a dirty run — the next run reuses a green that predates the edits" \
  || ok "[11] …and the pre-existing stamp is removed, not left for the next run to trust"
( cd "$PC/root/candor-spec" && git add -A && git -c user.email=t@e -c user.name=t commit -qm dirty )
pcrun >/dev/null 2>&1   # re-establish a stamp over the now-clean tree
[ -f "$STAMPF" ] || bad "[11] setup: no stamp after the re-establishing run — the two rows below cannot mean anything"
# SKIP_NEVER BEFORE SKIP_LICENSED: `conformance/README.md` matches the licensed docs pattern AND lives
# under conformance/. Licensed-first would swallow it and reuse a green for a suite whose own directory
# moved; `must_ledger.py` READS that file, so the swallow was not hypothetical.
printf 'edited\n' >> "$PC/root/candor-spec/conformance/README.md"
( cd "$PC/root/candor-spec" && git add -A && git -c user.email=t@e -c user.name=t commit -qm readme )
printf '%s' "$(pcrun)" | grep -q "conformance OK" \
  && ok "[11] a change under conformance/ FORCES the run even though its name is licensed" \
  || bad "[11] reused a green across a conformance/ change — SKIP_LICENSED is winning over SKIP_NEVER"
pcrun >/dev/null 2>&1   # …and re-establish the stamp before the control below
# THE CONTROL: a genuinely licensed path outside conformance/ must still be skippable, or the row above
# passes against a check that simply never reuses.
printf 'note\n' >> "$PC/root/candor/CHANGELOG.md"
( cd "$PC/root/candor" && git add -A && git -c user.email=t@e -c user.name=t commit -qm chlog )
printf '%s' "$(pcrun)" | grep -q "conformance REUSED" \
  && ok "[11] CONTROL: a CHANGELOG-only change still reuses (the licence is not vacuous)" \
  || bad "[11] CONTROL: refused to reuse across a changelog edit — nothing is licensed, so nothing is tested"
rm -rf "$PC"

say "7. changelog-lag.sh — preflight [5b]"
# [5] asks whether the changelog MENTIONS the floor, which a section cut at staging time passes forever.
# This asks whether the description stopped moving while the thing it describes kept going. Two shapes
# below are the ones an earlier ALLOWLIST of source directories skipped in SILENCE, going green on a repo
# it could not see any source in at all: candor-ts ships `.mjs` at the repository ROOT, and candor-spec's
# product is `SPEC.md`, a file the prose exclusion removes unless it is asked for separately.
CL="$(mktemp -d)"
mkrepo() { # $1 repo name ; $2 path of the "source" file it ships
  local p="$CL/$1"; mkdir -p "$p/$(dirname "$2")"
  git -C "$p" init -q 2>/dev/null || { mkdir -p "$p"; git -C "$p" init -q; }
  printf 'v1\n' > "$p/$2"; printf '# Changelog\n\n## [0.1.0]\n' > "$p/CHANGELOG.md"
  git -C "$p" add -A && git -C "$p" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$p" tag v0.1.0
}
clrun() { CANDOR_ROOT="$CL" bash "$UMBRELLA/bin/changelog-lag.sh" "$*" 2>&1; }
clcommit() { git -C "$CL/$1" add -A && git -C "$CL/$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }

mkrepo candor-ts scan.mjs                # root-level source, no src/ dir
mkrepo candor-spec SPEC.md               # the product IS the prose file
clrun candor-ts candor-spec >/dev/null 2>&1 && ok "a tree at its tag passes (the control)" \
  || bad "changelog-lag failed a tree with no post-tag commits"

printf 'v2\n' > "$CL/candor-ts/scan.mjs";  clcommit candor-ts   "root .mjs changed"
printf 'v2\n' >> "$CL/candor-spec/SPEC.md"; clcommit candor-spec "the contract changed"
out="$(clrun candor-ts candor-spec)"; rc=$?
[ "$rc" = 1 ] && ok "a shipped change with no changelog line FAILS" || bad "a lagging changelog exited $rc, not 1"
printf '%s' "$out" | grep -q 'root .mjs changed' \
  && ok "root-level source is SEEN (the shape an allowlist skipped silently)" \
  || bad "a repo whose source is at the root was not measured"
printf '%s' "$out" | grep -q 'the contract changed' \
  && ok "SPEC.md is SEEN despite the prose exclusion" \
  || bad "candor-spec's own product was excluded as prose"
# An empty commit list under a ✘ means the PATHSPEC is wrong, not that the tree is fine — and both
# earlier versions of the list printed exactly that, invisibly, because the tree was green.
printf '%s' "$out" | grep -q 'the CHECK is wrong here' \
  && bad "a ✘ named no commits — triage is an investigation again" || ok "every ✘ names its commits"

printf '\n## [0.1.1]\n- it changed\n' >> "$CL/candor-ts/CHANGELOG.md";  clcommit candor-ts   "note it"
printf '\n## [0.1.1]\n- it changed\n' >> "$CL/candor-spec/CHANGELOG.md"; clcommit candor-spec "note it"
clrun candor-ts candor-spec >/dev/null 2>&1 && ok "writing the line clears it" || bad "a documented change still failed"

# A MERGED BRANCH whose commits PREDATE the changelog's last touch. This is the ordinary shape of any
# feature branch, and the timestamp-based version of this check greened straight over it: the source
# work lands on main AFTER the changelog moved but carries OLDER committer dates, so "newest source
# date <= newest changelog date" held while the merged work was described nowhere. A wrong CLEAR, which
# is the class this script's own header calls the cardinal sin. Found by adversarial review, not by me.
git -C "$CL/candor-ts" checkout -qb feat
printf 'merged\n' > "$CL/candor-ts/scan.mjs"; clcommit candor-ts "branch: source work with an older date"
git -C "$CL/candor-ts" checkout -q -
printf '\n## [0.1.2]\n- unrelated\n' >> "$CL/candor-ts/CHANGELOG.md"; clcommit candor-ts "changelog moves on main"
git -C "$CL/candor-ts" -c user.email=t@t -c user.name=t merge -q --no-ff feat -m "merge feat" 2>/dev/null
clrun candor-ts >/dev/null 2>&1 \
  && bad "a merged branch's source work was never described and the check passed (timestamps, not topology)" \
  || ok "a merged branch is caught even though its commits are older than the changelog"
printf '\n## [0.1.3]\n- the merged work\n' >> "$CL/candor-ts/CHANGELOG.md"; clcommit candor-ts "describe it"
clrun candor-ts >/dev/null 2>&1 && ok "…and describing it clears it" || bad "still red after the entry"

printf 'hello\n' > "$CL/candor-ts/README.md"; clcommit candor-ts "prose only"
clrun candor-ts >/dev/null 2>&1 && ok "a README-only commit does not demand an entry" \
  || bad "prose was treated as a shipped change"

rm -rf "$CL/candor-spec"
clrun candor-ts candor-spec >/dev/null 2>&1 \
  && bad "a MISSING repo passed — an unmeasured repo must never read as a clean bill" \
  || ok "a repo that cannot be checked FAILS rather than vanishing"
rm -rf "$CL"

# ---------------------------------------------------------------------------------------------------
say "8. the CUT SET — a scoped patch publishes a SUBSET, and the family form is untouched"
# ---------------------------------------------------------------------------------------------------
# WHAT THIS SECTION IS FOR. The release scripts could express exactly one release: the whole family at
# one version. That contradicts the project's own three-axis model (SPEC.md "Versioning policy" and
# preflight [4]'s own note: "a build id is PER-ENGINE by design … demanding equality DESTROYS the
# information the build id exists to carry"), and the record shows the tooling rather than a decision
# is what enforced it — candor-swift's and candor-agents' `## [0.29.1]` entries read "Family build bump
# only — no engine changes in this repo", two repos republished to say they had not changed.
#
# `--only <repos>` makes a subset expressible. The rows below assert the three things that must hold:
# the flag REFUSES a set it cannot mean, a scoped run publishes the subset AND NOTHING ELSE, and the
# guards that existed before still fire — a gate relaxed for a new mode is a gate removed.
#
# THE PUBLISH CALLS ARE STUBBED. This file's own header says the network half "cannot be exercised
# without either a dry-run mode or stubs, and neither exists yet"; these rows are the stubs. `cargo`,
# `gh`, `npx`, `npm` and `git push` are shimmed on PATH, so release.sh runs its real sequence end to end
# and nothing leaves the machine.
CS="$(mktemp -d)"; mkdir -p "$CS/bin"
cat > "$CS/bin/cargo" <<'EOF'
#!/usr/bin/env bash
# STDOUT, not stderr: release.sh runs `cargo publish -p X 2>/tmp/rel-X.txt`, so a stub that
# wrote to stderr was invisible to every assertion about it — both the scoped "publishes no crate"
# row and its family-wide control passed over text that could never have been printed.
case "${1:-}" in publish) echo "STUB cargo publish $*" ;; search) echo "candor-query stub" ;; esac
exit 0
EOF
cat > "$CS/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status")    exit 0 ;;
  "release view")   exit 1 ;;
  "release create") echo "STUB-CREATE $*"; exit 0 ;;
  "run list")       printf '%s\n' "${GH_RUNS:-[]}" ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "candor-ts stub"\n' > "$CS/bin/npx"
printf '#!/usr/bin/env bash\nexit 1\n'                > "$CS/bin/npm"
# git: the REAL git for every read, a no-op for `push` alone. A stub that faked `status`/`rev-parse`
# too would make the clean-tree and pushed-ness guards untestable, and those are two of the guards
# these rows exist to hold.
cat > "$CS/bin/git" <<'EOF'
#!/usr/bin/env bash
a=("$@"); i=0
while [ $i -lt ${#a[@]} ]; do
  case "${a[$i]}" in
    -C|-c) i=$((i+2)); continue ;;
    push)  echo "STUB-PUSH ${a[*]}"; exit 0 ;;
    *) break ;;
  esac
done
exec /usr/bin/git "$@"
EOF
printf '#!/usr/bin/env bash\necho "STUB preflight $*"\nexit 0\n' > "$CS/bin/release-preflight-stub.sh"
chmod +x "$CS"/bin/*

# --- the flag refuses what it cannot mean ----------------------------------------------------------
# BOTH FAILURE MODES OF A SET SELECTOR ARE WIDE-OPEN ONES, which is why they are gated rather than
# assumed: a mistyped repo that resolved to the empty set would cut NOTHING while reporting success,
# and a bare `--only` that defaulted to "" would mean the WHOLE FAMILY — the widest possible action,
# chosen by a typo, on the scripts that publish.
for s in release-stage.sh release-preflight.sh release-verify.sh release.sh; do
  ( CANDOR_ROOT="$CS" bash "$UMBRELLA/bin/$s" 0.99 0.99.0 --only jva ) >/dev/null 2>&1
  [ "$?" = 2 ] && ok "$s: --only rejects an unknown repo name (exit 2)" \
                || bad "$s: --only jva did not exit 2 — a typo would silently choose a set"
done
( CANDOR_ROOT="$CS" bash "$UMBRELLA/bin/release.sh" 0.99 0.99.0 --only ) >/dev/null 2>&1
[ "$?" = 2 ] && ok "--only with no value is an error, not an empty set meaning 'everything'" \
             || bad "a bare --only did not exit 2 — the widest action, chosen by a typo"

# --- the fixture: a family at 0.32.0 with candor-java staged at 0.32.1 -----------------------------
csfix() { # $1 = target dir. Rebuilt per row: preflight [11] writes a stamp into candor-spec.
  local F="$1"; rm -rf "$F"; mkdir -p "$F"
  csmk() { mkdir -p "$(dirname "$F/$1")"; printf '%s' "$2" > "$F/$1"; }
  csmk candor-agents/candor_agents/scan.py 'SPEC = "0.32"
VERSION = "agents-0.32.0"
'
  csmk candor-agents/pyproject.toml 'version = "0.32.0"
'
  csmk candor-swift/Sources/candor-swift/main.swift 'let specVersion = "0.32"
let engineVersion = "candor-swift-0.32.0"
'
  csmk candor-ts/package.json '{ "version": "0.32.0" }
'
  csmk candor-ts/query.mjs 'const SPEC_VERSION = "0.32";
'
  csmk candor-ts/scan.mjs  'const SPEC_VERSION = "0.32";
'
  csmk candor-java/src/main/java/io/poly/candor/Candor.java 'static final String SPEC_VERSION = "0.32";
'
  csmk candor-rust/Cargo.toml '[workspace]
members = ["crates/candor-report"]
resolver = "2"
'
  csmk candor-rust/crates/candor-report/Cargo.toml '[package]
name = "candor-report"
version = "0.32.0"
edition = "2021"
'
  csmk candor-rust/crates/candor-report/src/lib.rs 'pub const SPEC_VERSION: &str = "0.32";
'
  # The dispatcher's pin block, in the shape release.sh / preflight / release-verify actually parse:
  # a family line plus four per-engine declarations, empty = follow the family.
  csmk candor/bin/candor 'UMBRELLA_VERSION="0.32.0"
ENGINE_PIN="0.32.0"
ENGINE_PIN_JAVA=""
ENGINE_PIN_TS=""
ENGINE_PIN_RUST=""
ENGINE_PIN_SWIFT=""
'
  csmk candor/adopt/candor.yml '          CANDOR_JAVA_VERSION: 0.32.0
'
  csmk candor/adopt/candor-digest.yml '        run: pipx install "git+https://github.com/tombaldwin/candor-agents@v0.32.0"
'
  csmk candor/integrations/vscode/package.json '{ "candorTsVersion": "0.32.0" }
'
  csmk candor/integrations/jetbrains/gradle.properties 'candorJavaVersion=0.32.0
candorTsVersion=0.32.0
'
  csmk candor-spec/SPEC.md '**Version 0.32**
⟨0.32⟩ a rung marker.
'
  csmk candor-spec/CHANGELOG.md '# Changelog

## Unreleased

## 0.32 — current floor

the floor rung.
'
  csmk candor/CHANGELOG.md '# Changelog — candor (umbrella)

## 2026-08-25 — the floor cut (released 2026-08-25 as 0.32.0)
'
  # candor-java, STAGED at 0.32.1 — the patch under preparation.
  csmk candor-java/build.gradle.kts 'version = "0.32.1"
'
  csmk candor-java/README.md '## Status: beta (v0.32.1, spec 0.32)
'
  csmk candor-java/jbang-catalog.json '{"script-ref":"https://github.com/tombaldwin/candor-java/releases/download/v0.32.0/candor-java-0.32.0-all.jar"}
'
  csmk candor-java/build/libs/candor-java-0.32.1-all.jar 'stub-jar
'
  csmk candor-java/CHANGELOG.md '# Changelog

## Unreleased

## [0.32.1] — 2026-08-25

republish the two native binaries the 0.32.0 parity gate withheld.

## [0.32.0] — 2026-08-25

the floor cut.
'
  # …and candor-rust carries PENDING work under `## Unreleased`. THIS IS THE POINT OF THE FIXTURE: it
  # is the ordinary state between rungs, and preflight [9] must not hold a java patch hostage to it.
  csmk candor-rust/CHANGELOG.md '# Changelog

## Unreleased

- work in progress for the next rung, deliberately not released.

## [0.32.1] — 2026-08-25

the patch.

## [0.32.0] — 2026-08-25

the floor cut.
'
  # STAGED AT 0.32.1 TOO, and that is not fixture padding. The family-wide CONTROL run at the bottom of
  # this group cuts 0.32.1 across all seven, and `rel()` now REFUSES a repo with no section for the
  # version being cut rather than publishing the previous release's notes under it. A fixture left at
  # 0.32.0 would make that control die at step 3 for a reason that is not the ENGINE_PIN guard it exists
  # to hold — a green row measuring the wrong refusal.
  for r in candor-ts candor-swift candor-agents; do
    printf '# Changelog\n\n## Unreleased\n\n## [0.32.1] — 2026-08-25\n\nthe patch.\n\n## [0.32.0] — 2026-08-25\n\nthe floor cut.\n' > "$F/$r/CHANGELOG.md"
  done
  mkdir -p "$F/candor-spec/conformance"
  printf '#!/usr/bin/env bash\necho "conformance: OK (stub) MATCH"\n' > "$F/candor-spec/conformance/run.sh"
  chmod +x "$F/candor-spec/conformance/run.sh"
  cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_stage_changelogs.py" "$UMBRELLA/bin/_release_set.sh" \
     "$UMBRELLA/bin/release.sh" "$UMBRELLA/bin/release-verify.sh" "$UMBRELLA/bin/release-preflight.sh" \
     "$UMBRELLA/bin/changelog-lag.sh" "$UMBRELLA/bin/_release_notes.sh" "$F/candor/bin/"
  mkdir -p "$F/remotes"
  for r in candor-rust candor-java candor-ts candor-swift candor-agents candor-spec candor; do
    ( cd "$F/$r" && /usr/bin/git init -q && /usr/bin/git add -A \
      && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm init ) >/dev/null 2>&1
    /usr/bin/git init -q --bare "$F/remotes/$r.git"
    ( cd "$F/$r" && /usr/bin/git remote add origin "$F/remotes/$r.git" && /usr/bin/git push -q -u origin HEAD ) >/dev/null 2>&1
  done
}
CSF="$CS/fix"
GHGREEN='[{"headSha":"none","conclusion":"success","status":"completed","workflowName":"ci"}]'

# --- the stager stages the SUBSET, and only the subset ---------------------------------------------
csfix "$CSF"
CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release-stage.sh" 0.32.2 --only candor-java >/dev/null 2>&1
is "scoped stage moves java's gradle version" '0.32.2' \
   "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$CSF/candor-java/build.gradle.kts" | head -1)"
is "…and leaves candor-ts where it was"       '0.32.0' \
   "$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$CSF/candor-ts/package.json" | head -1)"
is "…and leaves the umbrella's own version"   '0.32.0' \
   "$(sed -n 's/^UMBRELLA_VERSION="\([^"]*\)".*/\1/p' "$CSF/candor/bin/candor")"
# A repo outside the cut must keep its `## Unreleased` heading: that work ships on the NEXT release of
# that repo, and renaming it here would label it as part of a version it is not in.
grep -qE '^## Unreleased$' "$CSF/candor-rust/CHANGELOG.md" \
  && ok "a repo outside the cut keeps its \`## Unreleased\` (its pending work is not relabelled)" \
  || bad "the scoped stage renamed an out-of-cut repo's Unreleased heading"

# --- preflight judges the subset, and stays family-wide where the claim is family-wide -------------
csfix "$CSF"
pfout="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
        bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$pfout" | grep -q "release-preflight: OK" \
  && ok "[scoped] a java-only 0.32.1 passes preflight while the family stays at 0.32.0" \
  || { bad "a correct java-only cut did not pass preflight"; printf '%s' "$pfout" | grep '✘' | head -4; }
printf '%s' "$pfout" | grep -q "SCOPED CUT: candor-java only" \
  && ok "…and the verdict says which set it judged (an OK over one repo is not the family's OK)" \
  || bad "the scoped verdict is worded like the family-wide one"
printf '%s' "$pfout" | grep -q "jetbrains jvm" \
  && ok "[3] still asks for the java-owned pins" || bad "[3] stopped asking for a pin this cut moves"
printf '%s' "$pfout" | grep -qE "⊘ (vscode ts|jetbrains ts)" \
  && ok "…and reports the candor-ts pins OUT OF SCOPE rather than demanding a version ts never published" \
  || bad "[3] still demands a pin naming an engine this cut does not publish"
printf '%s' "$pfout" | grep -q "⊘ engine pin" \
  && ok "…and says ENGINE_PIN is the one pin no subset can move" \
  || bad "[3] did not report ENGINE_PIN as unmovable by a scoped cut"
printf '%s' "$pfout" | grep -q "conformance OK" \
  && ok "[11] four-way conformance still RUNS for a one-engine patch (the floor claim is cross-engine)" \
  || bad "[11] was scoped away — the cheapest release became the least checked"
# THE CONTROL FOR EVERY ROW ABOVE: the same invocation must still go RED on the things it exists to
# catch. Without these, "a java-only cut passes" is satisfied by a preflight that passes everything.
csfix "$CSF"
printf 'version = "0.32.0"\n' > "$CSF/candor-java/build.gradle.kts"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "gradle version is 0.32.0, not 0.32.1" \
  && ok "CONTROL: a scoped cut still FAILS when java's own version lagged" \
  || bad "[7] passed a java cut whose gradle version is not the version being cut"
csfix "$CSF"
rm -f "$CSF/candor-java/build/libs/candor-java-0.32.1-all.jar"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "is NOT built" \
  && ok "CONTROL: …and when the jar release.sh uploads was never built" \
  || bad "[7] passed a java cut with no jar — release.sh would die after the earlier steps"
# CONTROL FOR [9b]: the check that stands between an empty `## Unreleased` and a release carrying the
# PREVIOUS version's notes. [9] certified this tree as clean — it asks only whether anything is stranded
# UNDER the heading, and an empty one strands nothing — so without teeth here the two halves of the
# release tooling go green over the state that mis-published.
csfix "$CSF"
printf '# Changelog\n\n## Unreleased\n\n## [0.32.0] — 2026-08-25\n\nthe floor cut.\n' > "$CSF/candor-java/CHANGELOG.md"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q 'has no `## \[0.32.1\]` section' \
  && ok "CONTROL: …and when the version being cut has no notes of its own (an empty \`## Unreleased\`)" \
  || { bad "[9b] passed a cut that would publish the PREVIOUS version's notes under the new tag"
       printf '%s' "$red" | grep -E '^\s*(✔|✘) \[?9' | head -3; }
printf '%s' "$red" | grep -q '\[9\] ' && printf '%s' "$red" | grep -q 'no CHANGELOG has content stranded' \
  && ok "…and [9] still calls that same tree CLEAN, which is why [9b] had to exist" \
  || bad "[9] no longer passes the empty-section tree — this control has stopped showing why [9b] is separate"
csfix "$CSF"
printf '#!/usr/bin/env bash\nexit 1\n' > "$CSF/candor-spec/conformance/run.sh"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "conformance FAILED" \
  && ok "CONTROL: …and when four-way conformance is RED, even though only one engine is moving" \
  || bad "a scoped cut published over a red conformance suite"

# --- release.sh publishes the subset, and stops before the umbrella --------------------------------
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
relout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$relout" | grep -q "STUB-CREATE.*-R tombaldwin/candor-java" \
  && ok "[scoped] release.sh cuts the candor-java release" || bad "release.sh did not cut the one repo in the cut"
printf '%s' "$relout" | grep -q "STUB-CREATE.*-R tombaldwin/candor-rust" \
  && bad "release.sh cut candor-rust for a java-only patch" \
  || ok "…and cuts NO release for a repo outside the cut"
# THE FILE `gh release create -F` IS ACTUALLY HANDED, end to end. Every other row about notes reads a
# changelog or drives the selector; this one reads the artifact release.sh produced during a real run of
# its own sequence, which is where a variable round-trip or a redirection mistake would show up.
[ -s "/tmp/rel-body-candor-java.md" ] && grep -q "republish the two native binaries" "/tmp/rel-body-candor-java.md" \
  && ok "…and the body it hands \`gh\` is candor-java's OWN 0.32.1 section" \
  || bad "the release body release.sh wrote is not the version's section: '$(head -1 /tmp/rel-body-candor-java.md 2>/dev/null)'"
grep -q "the floor cut" "/tmp/rel-body-candor-java.md" 2>/dev/null \
  && bad "the body carries 0.32.0's notes — the republish defect, at the artifact" \
  || ok "…and carries nothing from the 0.32.0 section below it"
printf '%s' "$relout" | grep -q "STUB cargo publish" \
  && bad "release.sh published crates for a cut that does not include candor-rust" \
  || ok "…and publishes no crate"
printf '%s' "$relout" | grep -q "STUB-PUSH.*v0.32.1" \
  && bad "release.sh pushed a tag (npm/umbrella) for a java-only cut" \
  || ok "…and pushes no npm or umbrella tag"
printf '%s' "$relout" | grep -q "the umbrella is not in this cut" \
  && ok "…and says the umbrella and ENGINE_PIN stay on the family line" \
  || bad "release.sh did not state the umbrella limit of a scoped cut"
printf '%s' "$relout" | grep -q "candor/integrations/jetbrains/gradle.properties  candorJavaVersion" \
  && ok "…and step 6 lists exactly the pins this cut moves" || bad "step 6's pin list is not scoped to the cut"
# THE INSTRUCTION LINES, NOT THE WORD. A bare `candorTsVersion` also appears in step 6's own SKIP
# message ("…and neither candorTsVersion pin moves"), which is the opposite of what this row is about —
# so the loose pattern reported a correct run as a defect. Anchor on the `    · <file>` list entry.
printf '%s' "$relout" | grep -qE '^ +· candor/integrations/(vscode|jetbrains)/[a-z.]+ +candorTsVersion' \
  && bad "step 6 told the operator to bump a candor-ts pin in a java-only cut — a pin naming a release nobody made" \
  || ok "…and does not name a pin for an engine this cut never published"
# --- …AND THE ONE-ENGINE PATCH THAT REACHES THE FRONT DOOR ------------------------------------------
# The whole point of the per-engine pins: `--only candor-java,candor` publishes ONE engine and moves the
# umbrella with it, so `candor update` and Homebrew install the patched java engine and the family line
# for everything else. Before this existed the umbrella could not ride a subset cut at all, and a
# one-engine fix reached the front door only by republishing five engines with no functional change.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
# THE OPERATOR'S STEP 6, done by hand as the script instructs: java's pin moves, the family line does not.
perl -pi -e 's/^ENGINE_PIN_JAVA=""/ENGINE_PIN_JAVA="0.32.1"/' "$CSF/candor/bin/candor"
grep -q '^ENGINE_PIN_JAVA="0.32.1"$' "$CSF/candor/bin/candor" \
  && ok "[fixture] the per-engine pin edit landed (this row's premise, measured not assumed)" \
  || bad "[fixture] ENGINE_PIN_JAVA was not set — every row below would measure the wrong thing"
printf '# Changelog — candor (umbrella)\n\n## 2026-08-25 — the java-only patch (released 2026-08-25 as 0.32.1)\n\nENGINE_PIN_JAVA moves to 0.32.1; the family line stays 0.32.0.\n' > "$CSF/candor/CHANGELOG.md"
perl -pi -e 's/^UMBRELLA_VERSION="0.32.0"/UMBRELLA_VERSION="0.32.1"/' "$CSF/candor/bin/candor"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
juout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java,candor 2>&1)"
printf '%s' "$juout" | grep -q "STUB-CREATE.*-R tombaldwin/candor" \
  && ok "[java+umbrella] the umbrella release IS cut for a one-engine patch" \
  || { bad "the umbrella was still refused for a scoped cut that legitimately moves the front door"
       printf '%s' "$juout" | grep -E '✘' | head -4; }
printf '%s' "$juout" | grep -q "ENGINE_PIN mismatch" \
  && bad "the step-7 guard fired on a correctly-pinned java patch" \
  || ok "…and the step-7 pin guard passes, because every pin names a release this cut publishes"
printf '%s' "$juout" | grep -q "STUB-CREATE.*-R tombaldwin/candor-ts" \
  && bad "a java+umbrella cut published candor-ts" || ok "…and still publishes no other engine"
is "…and the FAMILY line is untouched by the patch" '0.32.0' \
   "$(sed -n 's/^ENGINE_PIN="\([^"]*\)".*/\1/p' "$CSF/candor/bin/candor")"
printf '%s' "$juout" | grep -qE '^ +· candor/bin/candor +ENGINE_PIN_JAVA="0.32.1"' \
  && ok "…and step 6 tells the operator to move exactly ENGINE_PIN_JAVA" \
  || { bad "step 6 did not name the per-engine pin this cut has to move"; printf '%s' "$juout" | grep -A6 '6. cross-repo pins' | head -8; }
printf '%s' "$juout" | grep -qE '^ +· candor/bin/candor +ENGINE_PIN_(TS|RUST|SWIFT)=' \
  && bad "step 6 told the operator to move a pin for an engine this cut never published" \
  || ok "…and names no other engine's front-door pin"

# CONTROL 1: THE SAME CUT WITH THE PIN NOT MOVED MUST REFUSE. Without this row, "the umbrella can ride a
# scoped cut" is satisfied by a step 7 that no longer checks anything — which is the shape the whole
# guard exists to prevent, one level up.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
printf '# Changelog — candor (umbrella)\n\n## 2026-08-25 — the java-only patch (released 2026-08-25 as 0.32.1)\n\nnotes.\n' > "$CSF/candor/CHANGELOG.md"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
lagout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java,candor 2>&1)"
printf '%s' "$lagout" | grep -q "java is pinned to 0.32.0, not 0.32.1" \
  && ok "CONTROL: …and the same cut REFUSES while ENGINE_PIN_JAVA still follows the family line" \
  || bad "the umbrella was cut with a front door that installs the engine this patch replaced"
printf '%s' "$lagout" | grep -qE "(ts|rust|swift) is pinned to" \
  && bad "the guard demanded a pin move for an engine this cut does not publish" \
  || ok "…and demands nothing of the three engines it is not publishing"

# CONTROL 2: A PIN NAMING A RELEASE NOBODY CUT. The new failure mode the per-engine pins introduce —
# 0.32.1 exists for java and for nothing else, so a ts pin at 0.32.1 404s on every user's machine.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
perl -pi -e 's/^ENGINE_PIN_JAVA=""/ENGINE_PIN_JAVA="0.32.1"/; s/^ENGINE_PIN_TS=""/ENGINE_PIN_TS="0.32.1"/' "$CSF/candor/bin/candor"
grep -q '^ENGINE_PIN_TS="0.32.1"$' "$CSF/candor/bin/candor" \
  && ok "[fixture] the phantom ts pin landed" || bad "[fixture] ENGINE_PIN_TS was not set — the control below is vacuous"
printf '# Changelog — candor (umbrella)\n\n## 2026-08-25 — the java-only patch (released 2026-08-25 as 0.32.1)\n\nnotes.\n' > "$CSF/candor/CHANGELOG.md"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
ghostout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java,candor 2>&1)"
printf '%s' "$ghostout" | grep -q "ts is pinned to 0.32.1, but candor-ts is NOT in this cut" \
  && ok "CONTROL: …and a pin naming a release this cut never published is REFUSED" \
  || bad "the front door was allowed to name candor-ts@0.32.1, a release nobody made"

# --- preflight judges the front door too, with the same rule -----------------------------------------
csfix "$CSF"
perl -pi -e 's/^ENGINE_PIN_JAVA=""/ENGINE_PIN_JAVA="0.32.1"/' "$CSF/candor/bin/candor"
perl -pi -e 's/^UMBRELLA_VERSION="0.32.0"/UMBRELLA_VERSION="0.32.1"/' "$CSF/candor/bin/candor"
printf '# Changelog — candor (umbrella)\n\n## 2026-08-25 — the java-only patch (released 2026-08-25 as 0.32.1)\n\nnotes.\n' > "$CSF/candor/CHANGELOG.md"
pfj="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java,candor 2>&1)"
printf '%s' "$pfj" | grep -q "engine pin java: 0.32.1" \
  && ok "[3] reports the per-engine front-door pin for the engine being cut" \
  || { bad "[3] never asked what \`candor update\` would fetch for java"; printf '%s' "$pfj" | grep -i "engine pin" | head -4; }
printf '%s' "$pfj" | grep -qE "engine pin (ts|rust|swift): 0.32.0 \(follows the family line" \
  && ok "…and says the other three follow the family line rather than demanding a version they never cut" \
  || bad "[3] mis-scoped the per-engine pins of the engines this cut does not publish"
# CONTROL: the same preflight must go RED when the pin lags. PINS_ADVISORY is deliberately NOT set —
# it downgrades a lagging pin to a note pre-publish, and this row is about the strict form release-verify
# and the operator's re-run use.
csfix "$CSF"
perl -pi -e 's/^UMBRELLA_VERSION="0.32.0"/UMBRELLA_VERSION="0.32.1"/' "$CSF/candor/bin/candor"
pfr="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java,candor 2>&1)"
# THE VERDICT, NOT THE SENTENCE. The first version of this row grepped the message text — which `bad`
# and `note` print identically — so downgrading the check from a failure to a remark left the row GREEN.
# Found by mutating the arm it covers. Assert the ✘ marker AND that the run does not certify itself.
printf '%s' "$pfr" | grep -q "✘ engine pin java: 0.32.0, not 0.32.1" \
  && ok "CONTROL: [3] fails when the front door still installs the engine this patch replaces" \
  || { bad "[3] passed a java patch whose front door names the previous release"
       printf '%s' "$pfr" | grep -i "engine pin java" | head -2; }
printf '%s' "$pfr" | grep -q "release-preflight: OK" \
  && bad "[3] noted the lagging front-door pin and then certified the cut anyway" \
  || ok "…and the run as a whole is RED, not a remark inside a green verdict"

# CONTROL: the ENGINE_PIN guard is NOT disarmed. Family-wide, a lagging pin must still refuse the
# umbrella — the guard that stops brew hashing a tarball whose `candor update` fetches the old engines.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
famout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 2>&1)"
printf '%s' "$famout" | grep -q "java is pinned to 0.32.0, not 0.32.1" \
  && ok "CONTROL: family-wide, the step-7 ENGINE_PIN guard still refuses a lagging pin" \
  || bad "the ENGINE_PIN guard was disarmed by the cut-set change"
# …for EVERY engine, not just the first one it happens to name. A guard that reports one engine and
# stops would let a family cut move three pins and publish the fourth's front door on the old line.
for _e in ts rust swift; do
  printf '%s' "$famout" | grep -q "$_e is pinned to 0.32.0, not 0.32.1" \
    && ok "CONTROL: …and names $_e too (the rule is over all four engines)" \
    || bad "the step-7 pin guard did not report $_e"
done
printf '%s' "$famout" | grep -q "STUB cargo publish" \
  && ok "CONTROL: …and a family-wide cut still publishes the crates" \
  || bad "the default cut stopped publishing crates — the subset scoping leaked into the family form"
rm -rf "$CS"

printf '\n'
if [ "$fail" -gt 0 ]; then printf '\033[31mrelease-test: %d FAILED, %d passed\033[0m\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mrelease-test: OK — %d assertions\033[0m%s\n' "$pass" \
  "$( [ "$skipped" -gt 0 ] && printf ' (%d SKIPPED — a missing tool, not a pass)' "$skipped" )"
