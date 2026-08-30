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

say "1d. release.sh step 0 — a repo that is not a git repo must not read as clean"
# THE NINTH FALSE GREEN (2026-08-30, adversarial review of release-rehearsal.sh and _release_notes.sh).
# `git -C <missing-dir> status --porcelain` fails with a `fatal:` line to STDERR and prints NOTHING on
# stdout — the same stdout a real "no changes" answer produces. Step 0's `[ -z "$(git ... status
# --porcelain)" ]` reads both cases identically, so a repo that was never cloned (wrong CANDOR_ROOT, a
# fresh machine mid-bootstrap — [[candor-anya-second-machine]]) sailed through as "clean and pushed"
# without ever being examined, and the SAME shape existed in release-rehearsal.sh's mirror of this check
# (below, section 10). PROVEN against the pre-fix script: it printed "✔ all mains clean + pushed" with
# one of the seven repos deleted entirely.
RS0="$(mktemp -d)"
mkdir -p "$RS0/candor/bin"
cp "$UMBRELLA/bin/release.sh" "$UMBRELLA/bin/_release_set.sh" "$RS0/candor/bin/"
chmod +x "$RS0/candor/bin/release.sh"
printf '#!/usr/bin/env bash\necho "stub preflight OK"\nexit 0\n' > "$RS0/candor/bin/release-preflight.sh"
chmod +x "$RS0/candor/bin/release-preflight.sh"
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents; do
  d="$RS0/$r"; mkdir -p "$d"
  ( cd "$d" && git init -q && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init )
done
( cd "$RS0/candor" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -q -m init )
rs0_run() { CANDOR_ROOT="$RS0" bash "$RS0/candor/bin/release.sh" 0.32 0.32.2 2>&1; }
# NAMED $rs0out/$rs0rc, NOT $out/$rc: this file uses those two as ambient scratch variables across
# sections (section 2's Cargo.lock row reads a `$out` captured back in section 1), and this row sits
# between them. The first version of this fix used `out`/`rc` here and clobbered section 1's capture,
# turning section 2's real assertion red for a reason that had nothing to do with either check — the
# exact "a fix that reddens ordinary runs" shape this project's own review process exists to catch.
rs0out="$(rs0_run)"
printf '%s' "$rs0out" | grep -q "all mains clean + pushed" \
  && ok "CONTROL: with every repo present and clean, step 0 passes" \
  || { bad "CONTROL setup is broken — step 0 does not pass on an all-clean fixture, so the row below proves nothing"; printf '%s\n' "$rs0out" | tail -6; }
rm -rf "$RS0/candor-java"
rs0out="$(rs0_run)"; rs0rc=$?
# THIS ROW USED TO READ ONLY `[ "$rs0rc" != 0 ]`, AND IT COULD NOT FAIL. Measured 2026-08-30 by
# removing the injection above and re-running: with NO repo deleted, release.sh still exits non-zero,
# because this fixture cannot reach a registry and dies at `cargo publish -p candor-report`. So the
# exit code says "release.sh stopped", never "step 0 stopped it" — the row would have stayed green
# with step 0 deleted outright, while being named for it. Its two siblings below always had teeth,
# and the reason is the whole pattern: they assert on the DOCUMENT (step 0's own diagnostic, and the
# ABSENCE of step 0's success claim), which no later failure can produce or suppress.
# So the exit code is kept — it is still the operator-visible signal — and BOUNDED: the run must have
# died BEFORE the publish step, which is the part only step 0 can cause.
[ "$rs0rc" != 0 ] \
  && ok "a repo missing entirely makes release.sh step 0 die, not pass" \
  || bad "release.sh exited 0 with candor-java's directory deleted — THE NINTH FALSE GREEN IS BACK"
printf '%s' "$rs0out" | grep -q "cargo publish" \
  && bad "release.sh got as far as \`cargo publish\` with a repo missing — step 0 did not stop it, so the exit code above is about something else" \
  || ok "…and dies AT step 0: the run never reaches \`cargo publish\`, which is what makes the row above attributable"
printf '%s' "$rs0out" | grep -q "candor-java is not a git checkout at" \
  && ok "…and names the repo and says why, rather than dying on an unrelated later step" \
  || bad "step 0 did not name the missing repo — '$(printf '%s' "$rs0out" | grep -m1 '✘')'"
printf '%s' "$rs0out" | grep -q "all mains clean + pushed" \
  && bad "release.sh still printed \"all mains clean + pushed\" with a repo missing — the false claim survives" \
  || ok "…and does not also claim \"all mains clean + pushed\""

# ── THE SIBLINGS THAT FIX LEFT, both directions ────────────────────────────────────────────────────
# The ninth-false-green fix guarded with `[ -d "$ROOT/$r/.git" ]`, and a DIRECTORY named `.git` is not
# what "is this a checkout" means. Measured 2026-08-30, truth table over four tree shapes:
#
#                        -d "$d/.git"   git -C "$d" rev-parse --git-dir
#   real checkout            TRUE                  TRUE
#   git WORKTREE             FALSE  ← wrong        TRUE
#   plain directory          FALSE                 FALSE
#   missing directory        FALSE                 FALSE
#
# So the fix closed a false-clean and opened a false-DEATH: in a worktree the root `.git` is a FILE,
# and `bin/verify-umbrella.sh` runs this repo's whole suite inside a throwaway worktree. Both rows
# below are about the SAME line; neither can be satisfied by the other, which is the point.
rm -rf "$RS0/candor-java"
git -C "$RS0/candor-spec" worktree add -q --detach "$RS0/candor-java" >/dev/null 2>&1
if [ -f "$RS0/candor-java/.git" ]; then
  rs0out="$(rs0_run)"
  printf '%s' "$rs0out" | grep -q "all mains clean + pushed" \
    && ok "a repo checked out as a git WORKTREE passes step 0 (its \`.git\` is a FILE, so \`-d\` said no)" \
    || bad "step 0 rejected a legitimate git worktree — '$(printf '%s' "$rs0out" | grep -m1 'not a git')'"
  git -C "$RS0/candor-spec" worktree remove --force "$RS0/candor-java" >/dev/null 2>&1
else
  note_skip "1d worktree row — \`git worktree add\` did not produce a \`.git\` FILE here, so the fixture cannot distinguish the two guard forms and the row would be vacuous"
fi
# …and the direction the ORIGINAL fix was right about must still hold for a directory that EXISTS but
# is not a checkout — an unpacked tarball, a copied tree, an interrupted clone. `git -C <it> status
# --porcelain` fails to stderr and prints nothing, byte-identical to "no changes".
rm -rf "$RS0/candor-java"; mkdir -p "$RS0/candor-java"; printf 'x\n' > "$RS0/candor-java/README.md"
rs0out="$(rs0_run)"; rs0rc=$?
[ "$rs0rc" != 0 ] && printf '%s' "$rs0out" | grep -q "candor-java is not a git checkout at" \
  && ok "a directory that is NOT a checkout dies at step 0 and is named, exactly as a missing one is" \
  || bad "a present-but-unversioned directory did not die at step 0 (rc=$rs0rc) — 'no changes' from a tree git cannot read read as clean"
printf '%s' "$rs0out" | grep -q "all mains clean + pushed" \
  && bad "release.sh claimed \"all mains clean + pushed\" over a directory git cannot read" \
  || ok "…and does not claim the mains were clean"
rm -rf "$RS0"

say "1e. the SWEEP behind 1d — every place a tree's git state is read, not the two that were reported"
# WHY A SEPARATE SECTION. The ninth-false-green fix (release.sh + release-rehearsal.sh) drew its
# boundary around its own trigger, and a review found two more sites by grepping the MECHANISM:
#
#   grep -rn 'status --porcelain' bin/ scripts/      # who READS a tree's cleanliness
#   grep -rn '\-d "[^"]*\.git"'   bin/ scripts/      # who GUARDS that read, and how
#
# Ten call sites across nine files, in two directions, both invisible on a healthy desk:
#   * guarded by `-d "$dir"`      → a directory that is not a checkout reports "no changes" and reads
#                                   CLEAN (release-stage.sh, spec-bump.sh, probe.sh, update-candor.sh)
#   * guarded by `-d "$dir/.git"` → a git WORKTREE keeps a FILE there, so a good checkout reads as
#                                   "not a git repo" (release.sh, release-rehearsal.sh,
#                                   changelog-lag.sh, release-preflight.sh ×4, bin/candor,
#                                   bootstrap-dev.sh)
# The rows below pin one end-to-end example of each direction, plus the sweep itself — because a row
# that pins only the instance it was handed is how this got to ten sites in the first place.

# ── DIRECTION 1, end to end: release-stage.sh is about to WRITE ~19 edits into these trees ─────────
ST0="$(mktemp -d)"
mkdir -p "$ST0/candor/bin"
cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_release_set.sh" "$ST0/candor/bin/"
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents; do
  ( mkdir -p "$ST0/$r" && cd "$ST0/$r" && git init -q \
    && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init )
done
( cd "$ST0/candor" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )
st0_run() { CANDOR_ROOT="$ST0" bash "$ST0/candor/bin/release-stage.sh" 0.26.0 2>&1; }
# THE CONTROL IS THE WHOLE ROW HERE. This fixture has no version sites, so the stager exits non-zero
# EITHER WAY — an rc-only assertion would be green with no fault injected at all, which is the vacuous
# shape this file has been bitten by. So both arms assert on the DIAGNOSTIC, and the control asserts
# its ABSENCE.
st0out="$(st0_run)"
printf '%s' "$st0out" | grep -q "is not a git checkout" \
  && bad "CONTROL is broken: the step-0 guard fires on an all-checkout fixture, so the row below proves nothing" \
  || ok "CONTROL: with every repo a real checkout, release-stage's step 0 says nothing about checkouts"
rm -rf "$ST0/candor-java"; mkdir -p "$ST0/candor-java"; printf 'x\n' > "$ST0/candor-java/README.md"
st0out="$(st0_run)"
printf '%s' "$st0out" | grep -q "candor-java at .* is not a git checkout" \
  && ok "a present-but-unversioned directory is refused by release-stage.sh, not staged into" \
  || bad "release-stage.sh staged into a directory git cannot read — its 'no changes' read as clean: $(printf '%s' "$st0out" | head -3)"
rm -rf "$ST0"

# ── DIRECTION 2, end to end: changelog-lag.sh's miss branch is fail-CLOSED, so `-d .git` made a ────
# healthy worktree a permanent ✘ — a red a reader learns to discount, which is worse than no check.
CL0="$(mktemp -d)"
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  ( mkdir -p "$CL0/$r" && cd "$CL0/$r" && git init -q \
    && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init )
done
rm -rf "$CL0/candor-ts"
git -C "$CL0/candor-spec" worktree add -q --detach "$CL0/candor-ts" >/dev/null 2>&1
if [ -f "$CL0/candor-ts/.git" ]; then
  clout="$(CANDOR_ROOT="$CL0" bash "$UMBRELLA/bin/changelog-lag.sh" 2>&1)"
  printf '%s' "$clout" | grep -q "candor-ts .*not a git checkout" \
    && bad "changelog-lag.sh calls a git WORKTREE 'not a git checkout' and counts it as lag" \
    || ok "changelog-lag.sh reads a git WORKTREE as the checkout it is (its \`.git\` is a FILE)"
  # THE OVER-CHARGE CONTROL: the branch must still fire for a directory that really is not a checkout,
  # or the row above is satisfied by a guard that was simply deleted.
  rm -rf "$CL0/candor-swift"; mkdir -p "$CL0/candor-swift"
  clout="$(CANDOR_ROOT="$CL0" bash "$UMBRELLA/bin/changelog-lag.sh" 2>&1)"
  printf '%s' "$clout" | grep -q "candor-swift .*not a git checkout" \
    && ok "…and still refuses a directory that genuinely is not one (the guard was widened, not deleted)" \
    || bad "the not-a-checkout branch no longer fires at all — the row above is vacuous"
else
  note_skip "1e worktree rows — \`git worktree add\` did not produce a \`.git\` FILE here, so the fixture cannot tell the two guard forms apart"
fi
rm -rf "$CL0"

# ── AND THE SWEEP ITSELF, so the NEXT site is caught by this file and not by the next review ───────
# `[ -d "<dir>/.git" ]` is never a correct test for "is this a git checkout" — it is false for every
# worktree. The authority is `git -C "<dir>" rev-parse --git-dir`. This row is deliberately a grep
# over the shipped scripts rather than a behaviour fixture: the failure it pins is a SPELLING that
# spreads by copy-paste, and it spread to ten sites before anything noticed.
strays="$(grep -rn --include='*.sh' --include='candor' -e '-d "[^"]*/\.git"' -e "-d '[^']*/\.git'" \
            "$UMBRELLA/bin" "$UMBRELLA/scripts" 2>/dev/null \
          | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v '/release-test\.sh:')"
[ -z "$strays" ] \
  && ok "no script under bin/ or scripts/ still tests for a checkout with \`-d …/.git\` (false for every worktree)" \
  || bad "\`-d …/.git\` is back as a checkout test — false for a git worktree: $(printf '%s' "$strays" | head -3 | tr '\n' ' ')"
# CONTROL FOR THE GREP: prove the pattern can actually match, or the row above passes because the
# expression is broken rather than because the tree is clean. A grep row with no positive control is
# the "0 violations from an instrument never shown able to fail" shape this whole family is about.
SWP="$(mktemp -d)"; printf 'if [ -d "$ROOT/x/.git" ]; then :; fi\n' > "$SWP/decoy.sh"
grep -rn --include='*.sh' -e '-d "[^"]*/\.git"' "$SWP" >/dev/null 2>&1 \
  && ok "…with the grep proven able to match (it finds a planted \`-d \"\$ROOT/x/.git\"\`)" \
  || bad "the sweep grep matches nothing even against a planted instance — the row above is vacuous"
rm -rf "$SWP"

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

say "3d. release.sh wires publish-floor-notes.sh in right where candor-spec's coarser-tag skip fires"
# candor-spec is the ONE repo in the family tagged at the CONTRACT version (`v0.32`, no patch
# component), so `rel candor-spec`'s "already released" branch fires on every patch cycle after the
# floor's first cut — correctly: a second v0.32 release, or a v0.32.1 tag, would fabricate a contract
# axis that does not exist. But release-stage.sh still opens `## [0.32.<patch>]` in candor-spec's own
# CHANGELOG.md every cycle, and once v0.32's release exists nothing in the ladder ever republishes it —
# permanently unpublished, not delayed. `candor-spec/scripts/publish-floor-notes.sh` (candor-spec's OWN
# script — this repo does not own or edit it, only calls it) closes the gap.
#
# THE FIXTURE SCRIPT BELOW IS A STAND-IN, NOT THE REAL FILE, and that is deliberate here — unlike the
# tap fix above (whose target, `scripts/update-candor.sh`, this repo OWNS outright), the real
# publish-floor-notes.sh lives in the candor-spec SIBLING repo, which `release-scripts.yml`'s
# `actions/checkout@v4` never fetches (it checks out `candor` alone) — a committed row here that
# `cp`'d the sibling's real file would find it on a dev machine and then find NOTHING in CI, which
# `note_skip` (this file's own rule, above) treats as a hard FAILURE precisely so a gate never
# degrades silently. So the stand-in below reproduces publish-floor-notes.sh's documented CALLING
# CONTRACT exactly (SPEC.md's floor → `gh release view` → concatenate the floor's `## [X.Y.<patch>]`
# CHANGELOG sections deterministically → `gh release edit -F`, exit code propagating naturally,
# same as the real file's own final line) — which is everything release.sh's WIRING can be asked to
# get right. publish-floor-notes.sh's own internal correctness (the awk section-extraction, its
# floor-vs-release-existence refusals) is candor-spec's own test's concern, not this repo's — this
# suite only owns "does release.sh call it in the right place, in the right way". (Verified once by
# hand against the actual sibling file during development: identical behavior — see the session
# report, not a row here, since it cannot run in CI.)
PFW="$(mktemp -d)"; RFX="$PFW/root"
mkdir -p "$RFX/candor-spec/scripts" "$RFX/candor/bin" "$PFW/bin"
cat > "$RFX/candor-spec/scripts/publish-floor-notes.sh" <<'PFNEOF'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO="tombaldwin/candor-spec"
FLOOR="$(grep -oE '^\*\*Version [0-9]+\.[0-9]+' "$ROOT/SPEC.md" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
TAG="v$FLOOR"
gh release view "$TAG" -R "$REPO" >/dev/null 2>&1 || { echo "publish-floor-notes: no release at $TAG" >&2; exit 3; }
OUT="$(mktemp "${TMPDIR:-/tmp}/floor-notes.XXXXXX")"
trap 'rm -f "$OUT"' EXIT
awk -v pfx="## [$FLOOR." 'index($0,pfx)==1{f=1;print;next} /^## /{f=0} f{print}' "$ROOT/CHANGELOG.md" > "$OUT"
grep -q '[^[:space:]]' "$OUT" || { echo "publish-floor-notes: nothing to publish" >&2; exit 3; }
gh release edit "$TAG" -R "$REPO" -F "$OUT" && echo "publish-floor-notes: $REPO $TAG notes refreshed"
PFNEOF
chmod +x "$RFX/candor-spec/scripts/publish-floor-notes.sh"
cp "$UMBRELLA/bin/release.sh" "$UMBRELLA/bin/_release_set.sh" "$UMBRELLA/bin/_release_notes.sh" "$RFX/candor/bin/"
chmod +x "$RFX/candor/bin/release.sh"
printf '#!/usr/bin/env bash\necho "STUB preflight $*"\nexit 0\n' > "$RFX/candor/bin/release-preflight.sh"
printf '#!/usr/bin/env bash\necho "STUB verify $*"\nexit 0\n'    > "$RFX/candor/bin/release-verify.sh"
chmod +x "$RFX/candor/bin/release-preflight.sh" "$RFX/candor/bin/release-verify.sh"
printf 'UMBRELLA_VERSION="0.32.0"\nENGINE_PIN="0.32.0"\nENGINE_PIN_JAVA=""\nENGINE_PIN_TS=""\nENGINE_PIN_RUST=""\nENGINE_PIN_SWIFT=""\n' > "$RFX/candor/bin/candor"
# candor-spec: floor at 0.32, a patch-cycle section already staged — the ordinary state between the
# floor's first cut and the next contract rung.
rfx_patch32() {
  printf '**Version 0.32**\n⟨0.32⟩ a rung marker.\n' > "$RFX/candor-spec/SPEC.md"
  printf '# Changelog\n\n## Unreleased\n\n## [0.32.1] — 2026-08-27\n\nTHE-PATCH-CYCLE-NOTES: a fix that landed after v0.32 was cut.\n\n## 0.32 — current floor\n\nthe floor rung.\n' > "$RFX/candor-spec/CHANGELOG.md"
}
rfx_patch32
mkdir -p "$RFX/remotes"
for r in candor-spec candor; do
  ( cd "$RFX/$r" && git init -q && git add -A && git -c user.email=t@e -c user.name=t commit -qm init ) >/dev/null 2>&1
  git init -q --bare "$RFX/remotes/$r.git"
  ( cd "$RFX/$r" && git remote add origin "$RFX/remotes/$r.git" && git push -q -u origin HEAD ) >/dev/null 2>&1
done
# gh stub: candor-spec's `v0.32` reports ALREADY released — the patch-cycle state under test. Every
# other tag/repo (including the DIFFERENT spec floor used by the control below) reports NOT released,
# so `rel()` takes its ordinary "create" branch, same as any other repo.
cat > "$PFW/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "release view")
    [ "$3" = "v0.32" ] && [ "$5" = "tombaldwin/candor-spec" ] && exit 0
    exit 1
    ;;
  "release create") echo "STUB-CREATE $*"; exit 0 ;;
  "release edit")
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "-F" ] && f="$a"; prev="$a"; done
    [ -n "$f" ] && cp "$f" "${GH_EDIT_CAPTURE:-/dev/null}"
    printf '%s\n' "STUB-EDIT $*" >> "${GH_EDIT_LOG:-/dev/null}"
    exit "${GH_EDIT_RC:-0}"
    ;;
esac
exit 0
EOF
chmod +x "$PFW/bin/gh"

# --- the row this whole gap is about: the patch-cycle skip fires, and the notes refresh runs directly --
: > "$PFW/edit.log"
r1out="$(PATH="$PFW/bin:$PATH" GH_EDIT_LOG="$PFW/edit.log" GH_EDIT_CAPTURE="$PFW/edit-body-1.md" \
        CANDOR_ROOT="$RFX" bash "$RFX/candor/bin/release.sh" 0.32 0.32.1 --only candor-spec 2>&1)"; r1rc=$?
[ "$r1rc" = 0 ] && ok "the wired run exits 0" || { bad "the wired run exited $r1rc"; printf '%s\n' "$r1out" | tail -20; }
printf '%s' "$r1out" | grep -q 'candor-spec v0.32 already released' \
  && ok "…the coarser-tag skip still fires exactly as before" || bad "the skip branch did not fire"
printf '%s' "$r1out" | grep -q 'candor-spec v0.32 floor notes refreshed with the 0.32.1 patch-cycle section' \
  && ok "…and release.sh calls publish-floor-notes.sh RIGHT THERE, unprompted" \
  || bad "release.sh did not report refreshing the floor notes after the skip"
[ -s "$PFW/edit.log" ] && ok "…gh release edit actually ran" || bad "gh release edit was never invoked"
grep -q -- '-R tombaldwin/candor-spec' "$PFW/edit.log" 2>/dev/null && grep -q 'v0.32' "$PFW/edit.log" 2>/dev/null \
  && ok "…targeting candor-spec's OWN v0.32 release, not a new tag or a different repo" \
  || bad "the edit call did not target candor-spec v0.32"
grep -q 'THE-PATCH-CYCLE-NOTES' "$PFW/edit-body-1.md" 2>/dev/null \
  && ok "…and the body it published carries the patch-cycle CHANGELOG section" \
  || bad "the published body is missing the patch-cycle notes"

# --- CONTROL: a NEW contract rung (the tag does not exist yet) must be UNCHANGED -----------------------
printf '**Version 0.33**\n⟨0.33⟩ a rung marker.\n' > "$RFX/candor-spec/SPEC.md"
printf '# Changelog\n\n## Unreleased\n\n## 0.33 — current floor\n\nfirst cut of the new floor.\n' > "$RFX/candor-spec/CHANGELOG.md"
( cd "$RFX/candor-spec" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "bump to 0.33" && git push -q ) >/dev/null 2>&1
: > "$PFW/edit.log"
r2out="$(PATH="$PFW/bin:$PATH" GH_EDIT_LOG="$PFW/edit.log" GH_EDIT_CAPTURE="$PFW/edit-body-2.md" \
        CANDOR_ROOT="$RFX" bash "$RFX/candor/bin/release.sh" 0.33 0.33.0 --only candor-spec 2>&1)"; r2rc=$?
[ "$r2rc" = 0 ] && ok "CONTROL: a new-rung cut still exits 0" || bad "CONTROL: a new-rung cut exited $r2rc"
printf '%s' "$r2out" | grep -q 'STUB-CREATE.*v0.33' \
  && ok "CONTROL: …the new tag takes the ordinary CREATE branch" || bad "CONTROL: the new rung did not create a release"
[ -s "$PFW/edit.log" ] \
  && { bad "CONTROL: gh release edit ran for a NEW contract rung — the skip-only gate is not fenced"; cat "$PFW/edit.log"; } \
  || ok "CONTROL: …and publish-floor-notes.sh was NOT invoked — nothing extra runs when the skip never fires"

# --- IDEMPOTENCE, BY EXECUTION: running the SAME patch cycle twice republishes the SAME bytes -----------
rfx_patch32
( cd "$RFX/candor-spec" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "back to 0.32 patch" && git push -q ) >/dev/null 2>&1
: > "$PFW/edit.log"
PATH="$PFW/bin:$PATH" GH_EDIT_LOG="$PFW/edit.log" GH_EDIT_CAPTURE="$PFW/edit-body-3.md" \
  CANDOR_ROOT="$RFX" bash "$RFX/candor/bin/release.sh" 0.32 0.32.1 --only candor-spec >/dev/null 2>&1
[ "$(grep -c 'release edit' "$PFW/edit.log" 2>/dev/null)" = 1 ] \
  && ok "IDEMPOTENCE: the second run also calls gh release edit exactly once" \
  || bad "IDEMPOTENCE: the second run's edit call count is wrong"
if diff -q "$PFW/edit-body-1.md" "$PFW/edit-body-3.md" >/dev/null 2>&1; then
  ok "IDEMPOTENCE: re-running republishes byte-identical notes (proved by execution, not by reading the header)"
else
  bad "IDEMPOTENCE: the second run's body differs from the first — re-running is not actually a no-op"
fi

# --- FAILURE INJECTION: gh release edit fails — the release must NOT die, and must say what to do -------
: > "$PFW/edit.log"
r4out="$(PATH="$PFW/bin:$PATH" GH_EDIT_LOG="$PFW/edit.log" GH_EDIT_RC=1 GH_EDIT_CAPTURE="$PFW/edit-body-4.md" \
        CANDOR_ROOT="$RFX" bash "$RFX/candor/bin/release.sh" 0.32 0.32.1 --only candor-spec 2>&1)"; r4rc=$?
[ "$r4rc" = 0 ] \
  && ok "a gh failure here does NOT abort the release (exit 0 — left no worse than not running it)" \
  || { bad "a gh release edit failure aborted the whole release — got exit $r4rc"; printf '%s\n' "$r4out" | tail -20; }
printf '%s' "$r4out" | grep -q 'publish-floor-notes.sh failed (exit 1)' \
  && ok "…the failure is reported, not swallowed" || bad "no diagnostic for the gh failure"
printf '%s' "$r4out" | grep -qF "bash $RFX/candor-spec/scripts/publish-floor-notes.sh" \
  && ok "…with the exact manual re-run in the message (the script is idempotent — safe to retry by hand)" \
  || bad "no manual remedy printed for the failure"
printf '%s' "$r4out" | grep -q 'STUB verify' \
  && ok "…and the release still reaches step 8 (release-verify) — the failure did not stop the ladder" \
  || bad "the release stopped after the gh failure instead of continuing"

rm -rf "$PFW"

say "4. release.sh hands update-candor.sh a TAG, not a bare version"
# DEFECT 7 (0.26): passing $VER made update-candor.sh create a SECOND tag beside v$VER.
grep -q 'update-candor.sh" "v\$VER"' "$UMBRELLA/bin/release.sh" \
  && ok "release.sh passes v\$VER" || bad "release.sh passes a bare version — a second tag per release"
grep -q 'already exists — reusing it' "$UMBRELLA/scripts/update-candor.sh" \
  && ok "update-candor.sh reuses an existing tag/release" || bad "update-candor.sh would recreate the tag"

say "4b. update-candor.sh's Homebrew tap push — a rejected push must retry, a real conflict must not"
# MEASURED during the 0.33.1 cut: `tombaldwin/homebrew-tap` carries every OTHER formula this maintainer
# publishes, so a push landing between our clone and our push is the NORMAL case in that repo, not an
# error. It rejected the tap push there (an unrelated `ebman 0.35.0` commit had landed), and by then the
# umbrella release + tag were ALREADY CUT — i.e. the rejection happened after the irreversible steps, so
# a routine race turned a healthy release into a failed run that had already published. Happened once
# before too. This is the FIRST execution-based coverage of the tap step at all: the header of this file
# says the tap "touches the network and cannot be exercised… neither exists yet" — `gh` and `curl` are
# stubbed on PATH exactly as the rest of this file already stubs them, and CANDOR_TAP (the script's own
# escape hatch) points at a throwaway bare-repo pair instead of ~/git/homebrew-tap. Nothing here reaches
# the real tap, the real GitHub repo, or the real umbrella.
UCW="$(mktemp -d)"
mkdir -p "$UCW/bin"
cat > "$UCW/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "release view")   exit 1 ;;
  "release create") echo "STUB-CREATE $*"; exit 0 ;;
esac
exit 0
EOF
printf '#!/usr/bin/env bash\necho "fake-tarball-bytes-for-testing"\nexit 0\n' > "$UCW/bin/curl"
chmod +x "$UCW/bin/gh" "$UCW/bin/curl"
# GIT IDENTITY BY ENVIRONMENT, NOT BY GLOBAL CONFIG: update-candor.sh's own `git commit` inside the tap
# takes no `-c` flags (unlike every commit this test harness makes directly), so a runner with no global
# git identity (CI's is bare) would fail the commit before the push logic under test ever ran.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
ucfix() { # $1=umbrella dir  $2=tag(vX.Y.Z) — a throwaway umbrella whose OWN tag pre-exists ON ORIGIN, so
  # update-candor.sh's umbrella tag/push and gh-release steps skip and this row is scoped to the tap alone.
  # ORIGIN, not just local: rs_tag_and_push (bin/_release_set.sh) now checks the REMOTE for this tag —
  # that is the fix this whole file exists to cover — so the fixture must give it a real origin carrying
  # the tag, or step 2 would try to push and fail on a fixture with no remote at all.
  local d="$1" tag="$2" ver="${2#v}" remote="${1}-remote.git"
  rm -rf "$d" "$remote"; mkdir -p "$d/scripts" "$d/bin"
  cp "$UMBRELLA/scripts/update-candor.sh" "$d/scripts/update-candor.sh"
  cp "$UMBRELLA/bin/_release_set.sh" "$d/bin/_release_set.sh"
  printf '#!/usr/bin/env bash\nUMBRELLA_VERSION="%s"\n' "$ver" > "$d/bin/candor"
  git init -q --bare "$remote"
  ( cd "$d" && git init -q && git add -A && git commit -qm init && git tag -a "$tag" -m t \
    && git remote add origin "$remote" && git push -q origin HEAD "$tag" )
}
uctap() { # $1=bare remote dir  $2=local clone dir — the pair `CANDOR_TAP` is pointed at
  local remote="$1" local_="$2" seed
  rm -rf "$remote" "$local_"
  git init -q --bare "$remote"
  seed="$(mktemp -d)"; git clone -q "$remote" "$seed"
  mkdir -p "$seed/Formula"
  printf 'class Candor < Formula\n  url "https://example.com/v0.0.0.tar.gz"\n  sha256 "%s"\nend\n' \
    "$(printf '0%.0s' $(seq 1 64))" > "$seed/Formula/candor.rb"
  ( cd "$seed" && git add -A && git commit -qm seed && git push -q )
  git clone -q "$remote" "$local_"
  rm -rf "$seed"
}

# --- CONTROL: no contention — must behave exactly as before (succeed on the first push, no retry text) --
UCU="$UCW/umbrella1"; ucfix "$UCU" "v9.9.1"
UCR="$UCW/tap-remote-1.git"; UCL="$UCW/tap-local-1"; uctap "$UCR" "$UCL"
ucout1="$(PATH="$UCW/bin:$PATH" CANDOR_TAP="$UCL" bash "$UCU/scripts/update-candor.sh" v9.9.1 2>&1)"; ucrc1=$?
[ "$ucrc1" = 0 ] && ok "CONTROL: no-contention tap push succeeds (exit 0)" \
                  || { bad "CONTROL: no-contention tap push failed — got exit $ucrc1"; printf '%s\n' "$ucout1"; }
printf '%s' "$ucout1" | grep -qiE 'rejected|retrying' \
  && bad "CONTROL: the no-contention path printed retry text — behaviour changed on the common case" \
  || ok "CONTROL: …and the no-contention path is silent about retries, same as before this fix"

# --- FALSIFICATION 1: a push rejected by a DIFFERENT formula file must rebase cleanly and SUCCEED -------
UCU="$UCW/umbrella2"; ucfix "$UCU" "v9.9.2"
UCR="$UCW/tap-remote-2.git"; UCL="$UCW/tap-local-2"; uctap "$UCR" "$UCL"
UCO="$(mktemp -d)"; git clone -q "$UCR" "$UCO"
printf 'class Ebman < Formula\n  url "x"\nend\n' > "$UCO/Formula/ebman.rb"
( cd "$UCO" && git add -A && git commit -qm "ebman 0.35.0" && git push -q ); rm -rf "$UCO"
ucout2="$(PATH="$UCW/bin:$PATH" CANDOR_TAP="$UCL" bash "$UCU/scripts/update-candor.sh" v9.9.2 2>&1)"; ucrc2=$?
[ "$ucrc2" = 0 ] && ok "a push rejected by an unrelated formula rebases cleanly and still succeeds" \
                  || { bad "a cleanly-rebasable rejection was not recovered — got exit $ucrc2"; printf '%s\n' "$ucout2"; }
printf '%s' "$ucout2" | grep -q 'tap push rejected (attempt 1/5)' \
  && ok "…and the retry is reported, not silent" || bad "no retry was attempted/reported for the rejection"
UCC="$(mktemp -d)"; git clone -q "$UCR" "$UCC"
[ -f "$UCC/Formula/ebman.rb" ] && ok "…the unrelated formula (ebman) is still on the tap" \
                                || bad "the retry lost the unrelated formula's commit"
grep -q 'v9.9.2.tar.gz' "$UCC/Formula/candor.rb" && ok "…and our own candor.rb update actually landed" \
                                                    || bad "the retry reported success but candor.rb was not updated"
rm -rf "$UCC"

# --- FALSIFICATION 2 (the over-charge control): a REAL conflict must fail LOUDLY, not retry forever -----
UCU="$UCW/umbrella3"; ucfix "$UCU" "v9.9.3"
UCR="$UCW/tap-remote-3.git"; UCL="$UCW/tap-local-3"; uctap "$UCR" "$UCL"
UCO="$(mktemp -d)"; git clone -q "$UCR" "$UCO"
perl -0pi -e 's{url "[^"]*"}{url "https://example.com/someone-elses-edit.tar.gz"}' "$UCO/Formula/candor.rb"
( cd "$UCO" && git add -A && git commit -qm "a competing candor.rb edit" && git push -q ); rm -rf "$UCO"
ucout3="$(PATH="$UCW/bin:$PATH" CANDOR_TAP="$UCL" bash "$UCU/scripts/update-candor.sh" v9.9.3 2>&1)"; ucrc3=$?
[ "$ucrc3" = 1 ] && ok "a REAL conflict on Formula/candor.rb fails loudly (exit 1), not a silent retry loop" \
                  || bad "a genuine conflict did not fail as expected — got exit $ucrc3"
printf '%s' "$ucout3" | grep -q 'REAL conflict' \
  && ok "…and names it as a real conflict, distinct from the retriable race" \
  || bad "no distinct diagnostic for a real conflict — indistinguishable from the retriable case"
printf '%s' "$ucout3" | grep -q 'resolve by hand' \
  && ok "…with a remedy, not a dead end" || bad "a real conflict gave no remedy"
# THE OVER-CHARGE CHECK: it must not have retried five times against an unresolvable conflict.
printf '%s' "$ucout3" | grep -qF 'attempt 5/5' \
  && bad "a real conflict was retried to exhaustion instead of failing on the first rebase conflict" \
  || ok "…and it failed on the FIRST conflict rather than burning through all 5 attempts"
# THE LOCAL REPO MUST BE LEFT CLEAN, not mid-rebase — `git rebase --abort` must actually have run.
( cd "$UCL" && git status --porcelain ) > "$UCW/ucl-status.txt"
[ -s "$UCW/ucl-status.txt" ] && { bad "the tap clone was left dirty/mid-rebase after the conflict"; cat "$UCW/ucl-status.txt"; } \
                              || ok "…and the local tap clone is left clean (the abort actually ran)"
[ -d "$UCL/.git/rebase-apply" ] || [ -d "$UCL/.git/rebase-merge" ] \
  && bad "a rebase was left in progress — the next release run would inherit a broken tap clone" \
  || ok "…no rebase-in-progress state was left behind"
( cd "$UCL" && git log --oneline -1 ) | grep -q "candor 9.9.3" \
  && ok "…and OUR commit is still there locally — a real conflict does not silently drop the update" \
  || bad "our own commit vanished after the failed push — the update was silently dropped"
UCC="$(mktemp -d)"; git clone -q "$UCR" "$UCC"
grep -q 'someone-elses-edit' "$UCC/Formula/candor.rb" \
  && ok "…and the remote still carries the competing edit untouched (no forced/corrupt push happened)" \
  || bad "the remote's competing edit was overwritten — a real conflict must never force-push over it"
rm -rf "$UCC"

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
rm -rf "$UCW"

say "4c. rs_tag_and_push — the guard checks the REMOTE, not the local ref"
# THE DEFECT. release.sh's steps 2 and 7 (and update-candor.sh's own umbrella tag) used to do
# `git tag "$tag" && git push origin "$tag" && ok "..."` — under release.sh's `set -uo pipefail` (no
# `-e`), the push half failing does not die: the `&&` chain just stops evaluating and the script carries
# on as if nothing happened. A rerun's idempotency check was `git rev-parse "$tag"`, which asks "do I
# have this ref LOCALLY" — always yes after the dead run — so the push was never retried and the tag
# never reached origin. For candor-ts that means the OIDC `publish.yml` an origin push triggers never
# fires; the failure surfaces ~25 minutes later at the npm wait, misdiagnosed as candor-ts's workflow.
#
# These rows exercise the REAL `rs_tag_and_push` (bin/_release_set.sh) — the exact function release.sh
# and update-candor.sh now call — against throwaway bare-repo pairs with real git. Nothing here reaches
# GitHub, npm, or any repo but the throwaway ones created below.
RTW="$(mktemp -d)"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@e GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@e
rtw_repo() { # $1=work dir — a fresh local clone-equivalent wired to a fresh bare "origin"
  local d="$1" remote="${1}-origin.git"
  rm -rf "$d" "$remote"
  git init -q --bare "$remote"
  git init -q "$d"
  ( cd "$d" && git commit -q --allow-empty -m init && git remote add origin "$remote" \
    && git push -q -u origin HEAD ) >/dev/null
}
rtw_run() { # $1=work dir  $2=tag — calls the REAL rs_tag_and_push from inside $1, prints RC=<n> last
  ( cd "$1" && . "$UMBRELLA/bin/_release_set.sh" && rs_tag_and_push "$2" ""; echo "RC=$?" )
}

# --- CONTROL A: a tag already on origin must be skipped, not touched again -----------------------------
D="$RTW/a"; rtw_repo "$D"
( cd "$D" && git tag v9.1.0 && git push -q origin v9.1.0 ) >/dev/null
outA="$(rtw_run "$D" v9.1.0 2>&1)"
printf '%s' "$outA" | grep -q '^RC=3$' \
  && ok "CONTROL A: a tag already on origin is recognised as done (RC=3), not re-pushed" \
  || { bad "a tag already on origin was not recognised as done"; printf '%s\n' "$outA"; }

# --- THE DEFECT'S OWN SHAPE: tag local-but-not-remote must now be PUSHED -------------------------------
D="$RTW/b"; rtw_repo "$D"
( cd "$D" && git tag v9.2.0 ) >/dev/null   # exactly the state a failed push used to leave behind
[ -z "$(git --git-dir="${D}-origin.git" tag -l)" ] \
  && ok "[fixture] origin does NOT have v9.2.0 yet — this is the defect's exact starting shape" \
  || bad "[fixture] origin already has the tag — this row would prove nothing"
outB="$(rtw_run "$D" v9.2.0 2>&1)"
printf '%s' "$outB" | grep -q '^RC=0$' \
  && ok "a tag local-but-not-remote is pushed (RC=0) — THE DEFECT'S FIX" \
  || { bad "a local-only tag was not pushed"; printf '%s\n' "$outB"; }
[ "$(git --git-dir="${D}-origin.git" tag -l)" = "v9.2.0" ] \
  && ok "…and origin now actually carries the tag" \
  || bad "rs_tag_and_push reported success but origin has no tag"

# --- THE OVER-CHARGE CONTROL: a genuine push failure must fail LOUDLY, once, and never retry ------------
D="$RTW/c"; rtw_repo "$D"
( cd "$D" && git tag v9.3.0 ) >/dev/null
( cd "$D" && git remote set-url origin "$RTW/does-not-exist.git" )   # simulates auth/network failure
outC="$(rtw_run "$D" v9.3.0 2>&1)"
printf '%s' "$outC" | grep -q '^RC=1$' \
  && ok "a genuine push failure returns 1 — not silently swallowed, not retried" \
  || { bad "a genuine push failure did not report RC=1"; printf '%s\n' "$outC"; }
printf '%s' "$outC" | grep -qi 'not retried automatically' \
  && ok "…and the diagnostic explains why (distinct from the tap's own contention-retry)" \
  || bad "no diagnostic explaining that this path does not retry"
( cd "$D" && git tag -l ) | grep -q v9.3.0 \
  && ok "…and the local tag is KEPT (a later rerun with fixed access can reuse it, never recreated)" \
  || bad "the local tag was deleted after a failed push — nothing left for a rerun to resume"
# Fix access and re-run: THIS is the actual regression proof — the OLD local-only guard would have
# printed "already exists" here and skipped forever, exactly as measured against release.sh's own
# code at the top of this run (see the bare `bash -c` reproduction in the task's own investigation).
( cd "$D" && git remote set-url origin "${D}-origin.git" )
outC2="$(rtw_run "$D" v9.3.0 2>&1)"
printf '%s' "$outC2" | grep -q '^RC=0$' \
  && ok "…and once access is fixed, the VERY NEXT run retries the same tag and succeeds" \
  || { bad "a rerun after fixing access did not retry the push"; printf '%s\n' "$outC2"; }
git --git-dir="${D}-origin.git" tag -l | grep -q v9.3.0 \
  && ok "…and origin has it now" || bad "origin still missing the tag after the successful rerun"

# --- CONTROL D: the no-failure path behaves identically to before --------------------------------------
D="$RTW/d"; rtw_repo "$D"
outD="$(rtw_run "$D" v9.4.0 2>&1)"
printf '%s' "$outD" | grep -q '^RC=0$' \
  && ok "CONTROL D: a brand-new tag with no prior attempt is created + pushed in one call (unchanged)" \
  || { bad "the ordinary no-failure path regressed"; printf '%s\n' "$outD"; }
git --git-dir="${D}-origin.git" tag -l | grep -q v9.4.0 \
  && ok "…and origin has it" || bad "origin is missing the tag on the ordinary, no-failure path"

unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
rm -rf "$RTW"

say "4d. release.sh + update-candor.sh actually WIRE UP the shared guard (regression pin)"
# Without this, 4c proves the function is correct in isolation while a caller could still carry its own,
# un-fixed `git rev-parse` check beside it — exactly the shape of bug this whole file's method exists to
# catch (a fix that doesn't reach every call site it needs to).
[ "$(grep -c 'rs_tag_and_push "v\$VER" ""' "$UMBRELLA/bin/release.sh")" = "2" ] \
  && ok "release.sh calls rs_tag_and_push at both tag sites (candor-ts step 2, umbrella step 7)" \
  || bad "release.sh does not call rs_tag_and_push exactly twice — a tag site kept the old local check"
grep -q 'git rev-parse "v\$VER"' "$UMBRELLA/bin/release.sh" \
  && bad "release.sh still has a LOCAL rev-parse tag-existence check — the defect this file closes" \
  || ok "…and no local-only tag-existence check remains in release.sh"
grep -q 'rs_tag_and_push "\$TAG"' "$UMBRELLA/scripts/update-candor.sh" \
  && ok "update-candor.sh's own umbrella tag also calls the shared guard" \
  || bad "update-candor.sh still has its own local-only tag guard"
grep -qE '^\s*if git rev-parse "\$TAG"' "$UMBRELLA/scripts/update-candor.sh" \
  && bad "update-candor.sh still has a LOCAL rev-parse tag-existence check (as CODE, not just the comment explaining why it was replaced)" \
  || ok "…and no local-only tag-existence check remains in update-candor.sh's code"

say "5. spec-bump.sh — the floor-bump rehearsal"
# The ⟨0.27⟩ bump was done by hand and turned SIX repos red on version-coupled assertions, every one
# findable locally. `spec-bump.sh` exists so a contract bump is rehearsed rather than discovered in CI.
SB=""
mkb() { mkdir -p "$(dirname "$SB/$1")"; printf '%s\n' "$2" > "$SB/$1"; }
# EVERY ROW BUILDS ITS OWN. $1 is the swift declaration line (so a row can move the site), $2 the SPEC.md
# headline (so a row can make it unreadable). Chaining these rows off one fixture meant the final control
# failed for a REAL reason — an earlier row had deliberately left swift unbumped, so the family it was
# asked to call consistent genuinely was not.
# THE FIXTURE CARRIES THE DOC SITES TOO, because step 1b treats a missing one as a MOVED one and fails
# the run — correctly: a `DOCS` entry that no longer exists is a document this script has stopped
# bumping, and the ⟨0.32⟩ finding is that exactly those go stale unnoticed. A fixture holding only the
# seven declarations would make every row below measure that failure instead of what it names.
#
# EVERY SPELLING IS REPRESENTED, one per file, and which file carries which is deliberate: swift's
# README holds the MARKDOWN-LINK form and java's README the ALIGNED-JSON form because those are the two
# the family's `{1,4}` grammar could not see, and a fixture that omits them cannot tell the widened
# grammar from the narrow one. The `(spec 0.7, informative)` markers are the control in the other
# direction — a true statement about a past rung that must NOT move.
sbdocs() {
  mkb candor-spec/README.md          '| Java | shipped (spec 0.27)** — the reference engine |'
  mkb candor-spec/AGENTS.md          '```json'$'\n''{ "candor": { "spec": "0.27" }, "functions": [] }'
  mkb candor-rust/README.md          '# → { "spec": "0.27", "ok": false }'$'\n''declaring **spec 0.27** (the same contract)'
  # the three AGENTS copies are MIRRORS — byte-identical, and 1b re-checks that after rewriting them
  local ragents='This project is on candor-scan 9.9.9 (spec 0.27).'$'\n''carrying `unitKind` (spec 0.7, informative); ordinary'
  mkb candor-rust/AGENTS.md "$ragents"
  mkb candor-rust/crates/candor-query/AGENTS.md "$ragents"
  mkb candor-rust/crates/candor-scan/AGENTS.md "$ragents"
  mkb candor-java/README.md          'an aligned envelope column, { "spec":    "0.27" }'
  local jagents='candor-java — the reference engine (spec 0.27) — reports per method.'
  mkb candor-java/AGENTS.md "$jagents"
  mkb candor-java/src/main/resources/AGENTS.md "$jagents"
  mkb candor-java/jbang-catalog.json '{ "description": "candor-java (candor-spec 0.27). Usage: jbang" }'
  mkb candor-ts/README.md            '| `{ candor: { spec: "0.27" }, functions }` envelope |'
  mkb candor-ts/AGENTS.md            'e.g. "This project is on candor-ts `<version>` (spec 0.27)."'
  mkb candor-ts/package.json         '{ "description": "candor for TypeScript (candor-spec 0.27)" }'
  mkb candor-swift/README.md         '**The Swift implementation of [candor-spec](https://x/candor-spec) 0.27** — per-function'
  local sagents='Writes the spec-0.27 envelope plus two sidecars.'$'\n''**Report shape:** `{ "candor": {…, "spec": "0.27"} }`'
  mkb candor-swift/AGENTS.md "$sagents"
  mkb candor-swift/Sources/candor-swift/AgentsDoc.swift "let AGENTS_MD = \"\"\""$'\n'"$sagents"
  mkb candor-swift/SPEC-EXTENSION-privacy.md '{ "candor": { "spec": "0.27" }, "extensions": [] }'
  # candor-agents/README.md and AGENTS.md carry NO current claim in the real repo — the `0 claim(s)`
  # line is a legitimate state and the fixture has to contain one, or the rows below would be asserting
  # that every listed doc must match, which is not what 1b promises.
  mkb candor-agents/README.md        'an annotated rung reference (spec 0.8, informative): nothing current'
  mkb candor-agents/AGENTS.md        'the agent contract, carrying no version claim at all'
  mkb candor-agents/pyproject.toml   'description = "candor for agent fleets (candor-spec 0.27)"'
  mkb candor-agents/candor_agents/__init__.py '"""candor-agents — effect analysis (candor-spec 0.27)."""'
}
# THE CANARIES, in the same files the real repos put them in. `lib.rs` already carries the rust
# DECLARATION, and the order matters: `current_of` takes the FIRST `SPEC_VERSION…"X.Y"` match in the
# file, so the declaration has to come before the assertion that names it — as it does in the real file.
sbcanaries() {
  mkb candor-rust/crates/candor-report/src/lib.rs \
    'pub const SPEC_VERSION: &str = "0.27";'$'\n''        assert!(s.contains("\"spec\":\"0.27\""), "envelope must carry it");'$'\n''        assert_eq!(SPEC_VERSION, "0.27");'
  mkb candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift \
    '        XCTAssertEqual(try declaredSpec(), "0.27", "the spec floor moved — bump this pin with it")'
}
sbfix() {
  [ -n "$SB" ] && rm -rf "$SB"
  SB="$(mktemp -d)"
  mkb candor-rust/crates/candor-report/src/lib.rs 'pub const SPEC_VERSION: &str = "0.27";'
  mkb candor-java/src/main/java/io/poly/candor/Candor.java '    static final String SPEC_VERSION = "0.27";'
  mkb candor-ts/scan.mjs 'const SPEC_VERSION = "0.27";'
  mkb candor-ts/query.mjs 'const SPEC_VERSION = "0.27";'
  mkb candor-swift/Sources/candor-swift/main.swift "${1:-let specVersion = \"0.27\"}"
  mkb candor-agents/candor_agents/scan.py 'SPEC = "0.27"'
  # SPEC.md carries the headline AND two envelope fences: one plain, one ALIGNED (the padding that
  # defeated a hand sweep at 0.30), plus an `, informative)` line that must survive the bump untouched.
  mkb candor-spec/SPEC.md "${2:-**Version 0.27** — all code engines declare \`0.27\`; the floor is conformance-pinned.}"$'\n''  "candor": { "version": "…", "toolchain": "…", "spec":    "0.27" },'$'\n''{ "candor": { "spec": "0.27" }, "functions": [] }'$'\n''  { "spec": "0.20" }   (measured at spec 0.20, informative)'
  sbdocs
  sbcanaries
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
# NAMED FILES, not a count over the whole tree. This row used to count files matching `"0.28"` and
# assert 7 — which conflated "the seven declarations moved" with "seven files in the tree mention the
# new version", so adding any doc site to the fixture broke a row about declarations. Ask each
# declaration file for ITS OWN value.
sbdecl_stale=""
for f in candor-rust/crates/candor-report/src/lib.rs candor-java/src/main/java/io/poly/candor/Candor.java \
         candor-ts/scan.mjs candor-ts/query.mjs candor-swift/Sources/candor-swift/main.swift \
         candor-agents/candor_agents/scan.py; do
  grep -q '0\.28' "$SB/$f" || sbdecl_stale="$sbdecl_stale $f"
done
grep -q '^\*\*Version 0\.28\*\*' "$SB/candor-spec/SPEC.md" || sbdecl_stale="$sbdecl_stale SPEC.md"
is "bump moves all seven declarations" '' "$sbdecl_stale"
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

say "5b. spec-bump.sh steps 1b/1c — the DOC literals and the deliberate pins"
# WHY THESE ROWS EXIST. Measured on the ⟨0.32⟩ bump: step 1 moved seven declarations and the version was
# ALSO hand-written in twenty-odd doc and packaging sites in three spellings. Every hand pass caught the
# two that LOOK LIKE DECLARATIONS and missed the one that LOOKS LIKE PROSE — candor-swift's embedded doc
# drifted by one character, two READMEs' JSON examples survived a full sweep, and SPEC.md itself carried
# three fences at the prior floor under a bumped header. Step 1b rewrites that named set by machine and
# step 1c names what it must not touch, so the acceptance question is not "did it change something" but
# "IS THE LIST COMPLETE" — which is what the last row here asks, the same way the real acceptance run did.
sbfix; sbcommit
bumpout="$(CANDOR_ROOT="$SB" bash "$SBSH" 0.28 --decls-only 2>&1)"

# 1b — EVERY DOC SITE, IN EVERY SPELLING. Named individually rather than counted: a count passes while
# the one file that matters is untouched, which is the exact failure mode this whole item is about.
docs_stale=""
for f in candor-spec/README.md candor-spec/AGENTS.md \
         candor-rust/README.md candor-rust/AGENTS.md \
         candor-rust/crates/candor-query/AGENTS.md candor-rust/crates/candor-scan/AGENTS.md \
         candor-java/README.md candor-java/AGENTS.md candor-java/src/main/resources/AGENTS.md \
         candor-java/jbang-catalog.json \
         candor-ts/README.md candor-ts/AGENTS.md candor-ts/package.json \
         candor-swift/README.md candor-swift/AGENTS.md candor-swift/SPEC-EXTENSION-privacy.md \
         candor-swift/Sources/candor-swift/AgentsDoc.swift \
         candor-agents/pyproject.toml candor-agents/candor_agents/__init__.py; do
  grep -q '0\.28' "$SB/$f" || docs_stale="$docs_stale $f"
done
is "1b moves every doc + packaging literal (prose, JSON, hyphenated, ALIGNED-JSON, markdown-link)" '' "$docs_stale"
# …and the two spellings a `{1,4}` grammar cannot reach, asserted BY NAME. Without these two rows the
# row above passes on a narrowed grammar, because both files also carry a spelling it can still see.
grep -q '"spec":    "0.28"' "$SB/candor-java/README.md" \
  && ok "…including the ALIGNED envelope column (six separators — invisible to a {1,4} grammar)" \
  || bad "the aligned \`\"spec\":    \"X.Y\"\` form was left behind: $(grep -o '"spec":[^,]*' "$SB/candor-java/README.md")"
grep -q 'candor-spec) 0.28' "$SB/candor-swift/README.md" \
  && ok "…and the markdown-link form \`[candor-spec](…) 0.28\` (the live claim in swift's real README)" \
  || bad "the markdown-link form was left behind: $(sed -n 1p "$SB/candor-swift/README.md")"
# THE OTHER DIRECTION, and it is the one a sweep gets wrong: a note naming the rung a feature arrived at
# is TRUE ABOUT THE PAST. `release-stage.sh`'s sibling lesson — the fixture reports built at the previous
# spec as INPUTS — is why this script lists rather than sweeps, and the `, informative)` marker is the
# same argument inside a file it DOES rewrite.
grep -q 'spec 0.7, informative' "$SB/candor-rust/AGENTS.md" \
  && ok "an \`(spec X.Y, informative)\` historical marker is NOT swept" \
  || bad "1b rewrote a historical marker — a true statement about a past rung now claims the new floor"
grep -q 'spec 0.8, informative' "$SB/candor-agents/README.md" \
  && ok "…and a file whose ONLY claim is an annotated one is left entirely alone (0 claims is legal)" \
  || bad "1b rewrote the annotated-only file"
# SPEC.md is JSON-ONLY on purpose: its prose is dense with true statements about past rungs.
is "1b moves SPEC.md's plain envelope fence"   '1' "$(grep -c '{ "candor": { "spec": "0.28" }' "$SB/candor-spec/SPEC.md" | tr -d ' ')"
is "…and its ALIGNED fence"                    '1' "$(grep -c '"spec":    "0.28"' "$SB/candor-spec/SPEC.md" | tr -d ' ')"
is "…and leaves the \`, informative)\` fence at its own rung" '1' "$(grep -c '{ "spec": "0.20" }' "$SB/candor-spec/SPEC.md" | tr -d ' ')"
# THE MIRRORS. A doc rewrite is precisely what breaks byte-equality between a canonical document and its
# shipped copy, so 1b re-checks it rather than leaving it to a red engine suite ten minutes later.
cmp -s "$SB/candor-java/AGENTS.md" "$SB/candor-java/src/main/resources/AGENTS.md" \
  && ok "the mirror copies stay byte-identical through the rewrite" \
  || bad "the jar-resource mirror diverged from AGENTS.md during 1b"

# 1c — THE CANARIES ARE NAMED AND NOT TOUCHED. Both halves matter: rewriting them silently would delete
# the only in-tree pins on the VALUE (everything else derives it, which checks agreement and not value),
# and NOT naming them is the [P2] this closes — they used to fire serially through CI, a round trip each.
canary_untouched=""
grep -q 'assert_eq!(SPEC_VERSION, "0.27")' "$SB/candor-rust/crates/candor-report/src/lib.rs" || canary_untouched="$canary_untouched rust-floor-pin"
grep -q 'spec\\":\\"0.27' "$SB/candor-rust/crates/candor-report/src/lib.rs" || canary_untouched="$canary_untouched rust-envelope"
grep -q 'declaredSpec(), "0.27"' "$SB/candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift" || canary_untouched="$canary_untouched swift-floor-pin"
is "1c does NOT rewrite the deliberate pins (their teeth are the point)" '' "$canary_untouched"
canary_named=""
for lbl in 'rust floor pin' 'rust envelope' 'swift floor pin'; do
  printf '%s' "$bumpout" | grep -q "$lbl" || canary_named="$canary_named [$lbl]"
done
is "1c NAMES every deliberate pin up front, with its before→after" '' "$canary_named"
printf '%s' "$bumpout" | grep -q 'assert_eq!(SPEC_VERSION, "0.27")  →  assert_eq!(SPEC_VERSION, "0.28")' \
  && ok "…and prints the exact edit, so it is a hand-edit LIST and not a hint" \
  || bad "1c named a pin without printing the substitution to make"

# THE ACCEPTANCE TEST. Apply EXACTLY the three edits 1c printed — nothing else — and require that no
# declaration, no gated document and no pin is left at the old floor. An incomplete list is the defect
# this step exists to fix, so completeness has to be the assertion, not a by-product of one.
sed -i.bak 's/"0\.27"/"0.28"/g; s/spec\\":\\"0\.27\\"/spec\\":\\"0.28\\"/g' \
  "$SB/candor-rust/crates/candor-report/src/lib.rs" "$SB/candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift"
rm -f "$SB"/candor-rust/crates/candor-report/src/lib.rs.bak "$SB"/candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift.bak
leftover="$(grep -rl --exclude-dir=.git 'spec[-: "*)]\{1,8\}0\.27\|"0\.27"' "$SB" 2>/dev/null | sed "s|$SB/||" | tr '\n' ' ')"
is "ACCEPTANCE: after 1b + exactly the 1c list, NOTHING in the tree is left at the old floor" '' "$leftover"

# TEETH ON THE LISTS THEMSELVES. Both are hand-maintained tables, and a table that silently stops
# covering a site is the failure this whole section is about — one layer up.
sbfix; rm -f "$SB/candor-ts/package.json"; sbcommit
CANDOR_ROOT="$SB" bash "$SBSH" 0.28 --decls-only >/dev/null 2>&1 \
  && bad "a DOCS site that no longer exists was skipped and the run still exited 0 — a document this script has quietly stopped bumping" \
  || ok "a moved/deleted DOCS site fails the run"
sbfix; printf 'drifted\n' >> "$SB/candor-java/src/main/resources/AGENTS.md"; sbcommit
CANDOR_ROOT="$SB" bash "$SBSH" 0.28 --decls-only >/dev/null 2>&1 \
  && bad "a BROKEN mirror passed 1b — the rewrite reached one copy and not the other, silently" \
  || ok "a broken mirror fails the run"
sbfix; mkb candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift 'the pin was refactored away'; sbcommit
canout="$(CANDOR_ROOT="$SB" bash "$SBSH" 0.28 --decls-only 2>&1)"; canrc=$?
{ [ "$canrc" != 0 ] && printf '%s' "$canout" | grep -q 'not pinning the floor'; } \
  && ok "a canary that cannot be LOCATED fails the run (a missing pin reads exactly like a satisfied one)" \
  || bad "a vanished deliberate pin exited $canrc without a word — the acknowledgement is gone and nothing said so"
rm -rf "$SB"

say "6. release.sh gates on preflight in PINS_ADVISORY mode"
# DEFECT 3 (0.26): [3] demands pins that only exist after publishing, while step 0 demands a green
# preflight — unsatisfiable, so every release bypassed the script written to stop bypasses.
grep -q 'PINS_ADVISORY=1 bash "$ROOT/candor/bin/release-preflight.sh"' "$UMBRELLA/bin/release.sh" \
  && ok "step 0 runs preflight with pins advisory" || bad "step 0 would deadlock on check [3]"
grep -q 'PINS_ADVISORY' "$UMBRELLA/bin/release-preflight.sh" \
  && ok "preflight honours PINS_ADVISORY" || bad "preflight has no advisory mode"

say "6b. release-preflight.sh [7b] — a per-job timeout, not a per-file one"
# DEFECT (2026-08-26 code review): candor's own jetbrains.yml has two jobs, `build` (timeout-minutes: 30)
# and `plugin-verifier` (none) — and [7b] used to be `grep -q timeout-minutes "$wf"`, a STRING search over
# the whole file. `build`'s line satisfied it and `plugin-verifier` was never looked at, so a real missing
# deadline sat behind a green check for as long as any OTHER job in the same file declared one. Fixed by
# parsing each workflow's `jobs:` map and checking every job individually.
T7B="$(mktemp -d)"; mkdir -p "$T7B/candor/.github/workflows"
git -C "$T7B/candor" init -q
t7brun() { CANDOR_ROOT="$T7B" bash "$UMBRELLA/bin/release-preflight.sh" 2>&1 | grep -A3 '\[7b\]'; }

# RED: reproduce the exact jetbrains.yml shape — one job with a timeout, one without.
cat > "$T7B/candor/.github/workflows/two-job.yml" <<'EOF'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps: [{run: echo hi}]
  plugin-verifier:
    runs-on: ubuntu-latest
    steps: [{run: echo hi}]
EOF
git -C "$T7B/candor" add -A; git -C "$T7B/candor" -c user.email=t@e -c user.name=t commit -qm wf -q
red7b="$(t7brun)"
printf '%s' "$red7b" | grep -q 'two-job.yml:plugin-verifier' \
  && ok "[7b] catches the job WITHOUT a timeout even though its sibling job in the same file has one" \
  || bad "[7b] missed a bare job beside a timed one — the per-file blind spot is back: $red7b"

# GREEN: give the second job a timeout too — the whole repo must go clean.
cat > "$T7B/candor/.github/workflows/two-job.yml" <<'EOF'
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps: [{run: echo hi}]
  plugin-verifier:
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps: [{run: echo hi}]
EOF
git -C "$T7B/candor" add -A; git -C "$T7B/candor" -c user.email=t@e -c user.name=t commit -qm wf2 -q
green7b="$(t7brun)"
printf '%s' "$green7b" | grep -q 'every job in every workflow' \
  && ok "[7b] GREEN once every job in the file declares a timeout" \
  || bad "[7b] still red after both jobs got a timeout: $green7b"

# CONTROL: a job that calls a reusable workflow (`uses:` at job level) must NOT be flagged — GitHub does
# not accept `timeout-minutes` there, so demanding one would be asking for a key that cannot be set.
cat > "$T7B/candor/.github/workflows/reusable.yml" <<'EOF'
on: push
jobs:
  call-it:
    uses: ./.github/workflows/two-job.yml
EOF
git -C "$T7B/candor" add -A; git -C "$T7B/candor" -c user.email=t@e -c user.name=t commit -qm wf3 -q
ctrl7b="$(t7brun)"
printf '%s' "$ctrl7b" | grep -q 'reusable.yml' \
  && bad "[7b] flagged a reusable-workflow call job, which cannot carry timeout-minutes at all: $ctrl7b" \
  || ok "[7b] CONTROL: a reusable-workflow call job is exempt, not flagged"
rm -rf "$T7B"

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

# DEFECT (2026-08-26 code review): [10]'s per-workflow dedupe sorted duplicate runs by `createdAt`, which
# `gh` reports at WHOLE-SECOND granularity. Python's stable sort left same-second ties in `gh`'s own
# (newest-first) order, and the "last write wins" merge that followed then picked whichever of the tied
# pair `gh` listed SECOND — not whichever was newest. Swapping the two objects in the input flipped the
# verdict over identical facts. None of the assertions above exercise two runs sharing a workflowName at
# all, so this had zero coverage. Fixed by adopting bin/ci-watch.sh's proven rule instead of re-deriving
# one: never re-sort, trust `gh`'s own order, keep the FIRST occurrence per workflow (bin/_ci_verdict.py).
#
# Distinct timestamps: two `ci` runs, no tie. The genuinely latest one (listed first, per gh's contract)
# is green; a stale duplicate behind it failed. The stale one must not resurrect a red verdict.
distinct="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:35:00Z\"},{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:30:00Z\"}]")"
printf '%s' "$distinct" | grep -q "repos green on HEAD" \
  && ok "[10] dedupe: distinct timestamps — the latest (listed-first) run wins over a stale duplicate" \
  || bad "[10] dedupe: a stale duplicate behind the real latest run poisoned the verdict"
printf '%s' "$distinct" | grep -q "ci:failure" \
  && bad "[10] dedupe: the stale duplicate's failure leaked into the verdict" \
  || ok "[10] dedupe: …and the stale duplicate's failure did not leak through"

# Same-second tie, order 1: the genuinely-newest run (a failure) is listed FIRST, as gh would list it.
# This is the exact repro: both runs share one createdAt second. The failure must be reported — this is
# the "genuinely-latest FAILURE hidden" shape from the defect report.
tie1="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:32:15Z\"},{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:32:15Z\"}]")"
printf '%s' "$tie1" | grep -q "ci:failure" \
  && ok "[10] dedupe: same-second tie, failure-first order — the failure is caught, not hidden" \
  || bad "[10] dedupe: same-second tie hid a genuinely-latest failure (order: failure, success)"
printf '%s' "$tie1" | grep -q "repos green on HEAD" \
  && bad "[10] dedupe: same-second tie printed the all-green summary over a real failure" \
  || ok "[10] dedupe: …and no all-green summary alongside it"
# Same-second tie, order 2: the SAME two facts, objects swapped. The genuinely-newest run (now success,
# listed first) must produce green — proving the verdict follows gh's listed order in BOTH directions
# rather than a fixed "whichever is second" bug that reports the same wrong answer regardless of order.
tie2="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:32:15Z\"},{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"ci\",\"createdAt\":\"2026-08-26T21:32:15Z\"}]")"
printf '%s' "$tie2" | grep -q "repos green on HEAD" \
  && ok "[10] dedupe: same-second tie, swapped order — success-first now reports green" \
  || bad "[10] dedupe: swapping the tied objects did not flip the verdict with the facts"
printf '%s' "$tie2" | grep -q "ci:failure" \
  && bad "[10] dedupe: swapped order still reported the superseded failure" \
  || ok "[10] dedupe: …and the superseded failure does not leak through"

# CONTROL: distinct workflow NAMES (no duplicates at all) must not be merged or dropped by the dedupe.
multi="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\"},{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"nightly\"}]")"
printf '%s' "$multi" | grep -q "repos green on HEAD" \
  && ok "[10] dedupe CONTROL: two distinct workflows, both green, stays green" \
  || bad "[10] dedupe CONTROL: distinct (non-duplicate) workflow names broke the verdict"

# THE FIFTH FALSE GREEN, the shape 97f7ef3 actually fixed (2026-08-30 revert sweep). Every dedupe row
# above omits workflowDatabaseId entirely, so all of them travel _ci_verdict.py's FALLBACK branch (key =
# workflowName, because the id is absent) and prove nothing about the id-keyed path the fix added. Two
# workflow FILES that both declare `name: ci` share a workflowName but never a workflowDatabaseId — the
# defect this commit's own message reproduced live: "two entries for 'ci' with different
# workflowDatabaseId, one success one failure, printed OK". Same shape here, id-keyed dedupe must NOT
# merge them.
idsplit="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\",\"workflowDatabaseId\":111},{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"ci\",\"workflowDatabaseId\":222}]")"
printf '%s' "$idsplit" | grep -q "ci:failure" \
  && ok "[10] dedupe: two FILES sharing workflowName 'ci' but distinct workflowDatabaseId — the failure is not merged away" \
  || bad "[10] dedupe: a second file's genuine failure was dropped as a same-NAME 'duplicate' (the fifth false green is back)"
printf '%s' "$idsplit" | grep -q "repos green on HEAD" \
  && bad "[10] dedupe: printed the all-green summary over a distinct-id failure sharing a display name" \
  || ok "[10] dedupe: …and no all-green summary alongside it"
# OVER-CHARGE CONTROL: a genuine RERUN of the SAME file (same workflowDatabaseId, two rows from retries)
# must still dedupe to its latest (listed-first) result — the id-keyed fix must not simply stop deduping.
idsame="$(pfrun "[{\"headSha\":\"$PFSHA\",\"conclusion\":\"success\",\"status\":\"completed\",\"workflowName\":\"ci\",\"workflowDatabaseId\":111,\"createdAt\":\"2026-08-30T10:05:00Z\"},{\"headSha\":\"$PFSHA\",\"conclusion\":\"failure\",\"status\":\"completed\",\"workflowName\":\"ci\",\"workflowDatabaseId\":111,\"createdAt\":\"2026-08-30T10:00:00Z\"}]")"
printf '%s' "$idsame" | grep -q "repos green on HEAD" \
  && ok "[10] dedupe CONTROL: same workflowDatabaseId (a genuine rerun) still collapses to its latest (listed-first) result" \
  || bad "[10] dedupe CONTROL: id-keyed dedupe stopped collapsing genuine reruns of the same workflow"
rm -rf "$PF"

# THE THIRD SIBLING (2026-08-26 code review): the NONE branch — a commit that triggered no workflow at
# all (docs-only, path-filtered) — used to answer "what is this repo's last known CI state" by taking
# element 0 of `gh run list`, unfiltered by workflow. A repo carries several workflows on different
# triggers; whichever one happened to finish most recently decided the verdict for ALL of them. This
# fixture is the shape that broke it: an unrelated cron-ish workflow ("nightly-bump") completed most
# recently and GREEN, while the real gate ("ci") last completed EARLIER and RED. Needs a properly
# upstream-tracked repo (unlike $PF above) so the NOT-PUSHED branch does not fire instead.
N=$(mktemp -d); mkdir -p "$N/bin" "$N/root/candor"
cat > "$N/bin/gh" <<'GHEOF'
#!/bin/bash
# ci_all_workflows_latest() (release-preflight.sh, the 2026-08-29 eighth-false-green fix) does not ask
# this NONE-branch's question with one unfiltered `gh run list` any more: it asks `gh workflow list` for
# this repo's own workflow ids, then `gh run list --workflow <id> --limit 1` for EACH one's own newest
# run, so a chatty sibling cannot age a quiet workflow's real failure off a shared page. This stub used
# to answer only the old shape, which made every NONE-branch fixture below fail enumeration instead of
# exercising the dedupe logic they exist to test — a regression this file introduced, not release-
# preflight.sh: both new shapes are answered from the same $GH_RUNS data. Workflow ids are assigned by
# distinct workflowName (jq's `unique`, alphabetical — internally consistent between the two calls below
# even though it need not match gh's own numbering), and `--workflow <id>` returns just that one
# workflow's own row(s), exactly as the real per-workflow query would.
case "$1 $2" in
  "auth status") exit 0 ;;
  "workflow list")
    printf '%s' "$GH_RUNS" | jq -c '[.[].workflowName] | unique | to_entries | map({id: (.key+1)})' ;;
  "run list")
    wf=""; lim=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --workflow) wf="$2"; shift 2 ;; --limit) lim="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -n "$wf" ]; then
      name="$(printf '%s' "$GH_RUNS" | jq -r --argjson wf "$wf" '[.[].workflowName] | unique | .[$wf-1]')"
      printf '%s' "$GH_RUNS" | jq -c --arg n "$name" '[.[] | select(.workflowName==$n)] | .[0:1]'
    else
      # THE STUB BUG (2026-08-30 revert sweep): `gh run list --limit N` (no `--workflow`) is a SHARED
      # PAGE across every workflow the repo has, and real `gh` truncates to it — that truncation IS the
      # eighth false green (a chatty sibling filling the page and ageing a quiet workflow's real failure
      # off it, never returned at all). This branch used to ignore `--limit` and return the WHOLE
      # $GH_RUNS array regardless, so no fixture — however crowded — could ever reproduce the page cutoff
      # through this harness, which is exactly how the ci_all_workflows_latest() fix (GAP 2 below) shipped
      # untested behind a test that only ever looked tested.
      if [ -n "$lim" ]; then
        printf '%s' "$GH_RUNS" | jq -c --argjson n "$lim" '.[0:$n]'
      else
        printf '%s\n' "$GH_RUNS"
      fi
    fi
    ;;
  *) exit 0 ;;
esac
GHEOF
chmod +x "$N/bin/gh"
git -C "$N/root/candor" init -q
git -C "$N/root/candor" branch -m main 2>/dev/null
printf 'docs only\n' > "$N/root/candor/f.txt"
git -C "$N/root/candor" add -A
git -C "$N/root/candor" -c user.email=t@e -c user.name=t commit -qm init -q
git init -q --bare "$N/bare.git"
git -C "$N/root/candor" remote add origin "$N/bare.git"
git -C "$N/root/candor" push -q origin main
git -C "$N/root/candor" branch --set-upstream-to=origin/main main >/dev/null
nonerun() { GH_RUNS="$1" PATH="$N/bin:$PATH" CANDOR_ROOT="$N/root" CI_NO_WAIT=1 PINS_ADVISORY=1 \
    bash "$UMBRELLA/bin/release-preflight.sh" 0.99 0.99.0 2>&1; }

# RED-shaped fixture: neither run's headSha matches this HEAD (fake shas), so the primary read is NONE
# and this branch is what answers. "nightly-bump" is freshest and green; "ci" is the real gate and is
# the one that failed, earlier.
mixed="$(nonerun '[{"headSha":"aaa1111aaa1111aaa1111aaa1111aaa1111aaaa","conclusion":"success","status":"completed","workflowName":"nightly-bump","createdAt":"2026-08-26T10:00:00Z"},{"headSha":"bbb2222bbb2222bbb2222bbb2222bbb2222bbbb","conclusion":"failure","status":"completed","workflowName":"ci","createdAt":"2026-08-26T08:00:00Z"}]')"
printf '%s' "$mixed" | grep -q "ci:failure" \
  && ok "[10] NONE branch: a stale failing workflow is NOT masked by an unrelated fresher green one" \
  || bad "[10] NONE branch: the real gate's failure did not surface — false clear reproduced: $mixed"
printf '%s' "$mixed" | grep -q "repos green on HEAD" \
  && bad "[10] NONE branch: printed the all-green summary over a genuinely failing workflow" \
  || ok "[10] NONE branch: …and no all-green summary alongside the failure"

# CONTROL: every workflow this repo has actually completed is green — must still pass and inform, not
# gate. This is the ordinary docs-only-commit shape and must read exactly as it always has.
allgreen="$(nonerun '[{"headSha":"aaa1111aaa1111aaa1111aaa1111aaa1111aaaa","conclusion":"success","status":"completed","workflowName":"nightly-bump","createdAt":"2026-08-26T10:00:00Z"},{"headSha":"bbb2222bbb2222bbb2222bbb2222bbb2222bbbb","conclusion":"success","status":"completed","workflowName":"ci","createdAt":"2026-08-26T08:00:00Z"}]')"
printf '%s' "$allgreen" | grep -q "last known CI state (aaa1111) is green across every workflow" \
  && ok "[10] NONE branch CONTROL: every workflow actually green — informational pass, names the anchor sha" \
  || bad "[10] NONE branch CONTROL: an all-green repo did not pass cleanly: $allgreen"

# THE EIGHTH FALSE GREEN, the shape 3e0d1e2 actually fixed (2026-08-30 revert sweep). "mixed"/"allgreen"
# above feed exactly ONE row per workflow, so even the OLD bare `gh run list --limit 30` (unfiltered, no
# per-workflow query) would have "found" the quiet workflow's real state — the stub's own `--limit`
# enforcement was missing until the fix just above, so no fixture size could ever have told the two
# mechanisms apart. 40 fresh "chatty" runs bury a single, older "ci" failure at position 41 — past any
# `--limit 30` cutoff a SHARED page would apply, but still reachable by ci_all_workflows_latest()'s
# PER-WORKFLOW `--workflow <id> --limit 1` query, which never shares a page with the chatty sibling at all.
crowded="$(nonerun "$(jq -n '[range(0;40) | {headSha: ("chatty-" + (.|tostring)), conclusion: "success", status: "completed", workflowName: "chatty", createdAt: "2026-08-30T10:00:00Z"}] + [{headSha: "quiet-1", conclusion: "failure", status: "completed", workflowName: "ci", createdAt: "2026-08-30T09:00:00Z"}]')")"
printf '%s' "$crowded" | grep -q "ci:failure" \
  && ok "[10] NONE branch: a quiet workflow's failure survives a 41-row page a chatty sibling fills (the eighth false green is back if this fails)" \
  || bad "[10] NONE branch: a chatty sibling's 40 runs buried the quiet workflow's real failure — THE EIGHTH FALSE GREEN IS BACK"
printf '%s' "$crowded" | grep -q "repos green on HEAD" \
  && bad "[10] NONE branch: printed the all-green summary over a page-buried failure" \
  || ok "[10] NONE branch: …and no all-green summary alongside it"
rm -rf "$N"

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

say "7d. release-verify.sh — a DRAFT release must be caught, not just a missing one"
# WHY THIS EXISTS. Deleting a git tag silently converts its GitHub Release to a draft, and a draft 404s
# on EVERY asset download URL even though the API reports the asset itself `state=uploaded` — the release
# LOOKS fine (`gh release view --json tagName` still returns the tag) and every consumer download fails
# anyway. Measured on the 0.33.0 cut: candor-swift's tag was deleted and re-pushed to recover an orphaned
# workflow run, the binary built and attached fine, and every `candor update` / direct download 404'd.
# Real `release-verify.sh` run directly here — `--only candor-spec` reaches the check with a single stubbed
# `gh` and no real network call (crates.io/npm/artifact-curl are all out of scope for that one repo).
PV="$(mktemp -d)"; mkdir -p "$PV/bin" "$PV/root/candor/bin"
# ONE combined `gh release view --json tagName,isDraft -q '...'` call now, not two adjacent ones (see
# release-verify.sh). The stub does not run real jq — it emits exactly the shape the real -q filter
# produces ("tagName|true" / "tagName|false"), so the test is over release-verify.sh's OWN branching, not
# over jq. GH_FAIL simulates the call failing OUTRIGHT (network blip / secondary rate limit / 409 / 403 —
# the incident that motivated the draft check in the first place) rather than returning a value.
cat > "$PV/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then
  [ "${GH_FAIL:-}" = "1" ] && exit 1
  tag="$3"
  echo "${tag}|${GH_DRAFT:-false}"
  exit 0
fi
[ "$1" = "auth" ] && exit 0
exit 1
GHEOF
chmod +x "$PV/bin/gh"
printf 'ENGINE_PIN="0.33.0"\n' > "$PV/root/candor/bin/candor"
pvrun() { GH_DRAFT="$1" GH_FAIL="${2:-}" PATH="$PV/bin:$PATH" CANDOR_ROOT="$PV/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 --only candor-spec 2>&1; }
green="$(pvrun false)"
printf '%s' "$green" | grep -q "✔ candor-spec v0.33" \
  && ok "an ordinary (non-draft) release passes" || bad "a normal release was not confirmed — control is broken"
printf '%s' "$green" | grep -q "release-verify: OK" \
  && ok "…and the run as a whole reports OK" || bad "a clean release did not report OK"
red="$(pvrun true)"
printf '%s' "$red" | grep -q "candor-spec: v0.33 is a DRAFT release" \
  && ok "CONTROL: a draft release is caught and NAMED, not conflated with a missing one" \
  || bad "a draft release passed release-verify — the exact 0.33.0 candor-swift failure would reach this check green"
printf '%s' "$red" | grep -q "gh release edit v0.33 -R tombaldwin/candor-spec --draft=false" \
  && ok "…and the remedy is the exact command to run, with the right repo and tag" \
  || bad "the draft diagnostic has no actionable remedy"
printf '%s' "$red" | grep -q "release-verify: 1 check(s) FAILED" \
  && ok "…and the run as a whole is RED, not a note beside a green verdict" \
  || bad "a draft release did not fail the run"

# DEFECT (code review, 2026-08-26): the OLD code read tagName and isDraft as two separate gh calls. If
# the second one failed, `draft` came back empty — empty is not "true" — so the `else` branch fired and
# printed `ok`. A transient failure on the call that exists to catch drafts was read as "confirmed not a
# draft". Proven here by making the gh call fail OUTRIGHT (exit 1, no output) rather than by disagreeing
# about a value — the shape a real 409/403 takes.
failed="$(pvrun false 1)"
printf '%s' "$failed" | grep -q "release-verify: OK" \
  && bad "[gh releases] a FAILED gh call was read as a confirmed non-draft release — the exact defect" \
  || ok "a gh call that fails outright does NOT silently pass as a confirmed non-draft"
printf '%s' "$failed" | grep -q "could not read release info for v0.33" \
  && ok "…and says WHY: the call itself failed, not that anything was confirmed" \
  || bad "a failed gh call produced no diagnostic naming the cause"
printf '%s' "$failed" | grep -q "release-verify: 1 check(s) FAILED" \
  && ok "…and the run as a whole is RED over the failed call, not a note beside a green verdict" \
  || bad "a failed gh call did not fail the run"

# THE THIRD STATE: the call SUCCEEDS (tagName matches) but isDraft itself resolves to neither true nor
# false — kept distinct from "the call failed outright" above, so the diagnostic names the right cause.
unreadable="$(pvrun bogus)"
printf '%s' "$unreadable" | grep -q "release-verify: OK" \
  && bad "an unreadable isDraft value was read as a confirmed non-draft release" \
  || ok "an unreadable isDraft value does NOT silently pass as a confirmed non-draft"
printf '%s' "$unreadable" | grep -q "draft status is UNREADABLE" \
  && ok "…and is named as UNREADABLE, distinct from a failed call or a real draft" \
  || bad "an unreadable isDraft value produced no distinct diagnostic"
rm -rf "$PV"

say "7e. release-verify.sh — a STALE per-engine pin must not read as \"live everywhere\""
# WHY THIS EXISTS. `bin/candor` carries ENGINE_PIN_JAVA/_TS/_RUST/_SWIFT beside the family ENGINE_PIN
# (2026-08-25), and each is what its own front door actually reads (`npx candor-ts@$ENGINE_PIN_TS`,
# `cargo install --version $ENGINE_PIN_RUST`, the swift download URL, the java jar URL — all in
# bin/candor). Before this fix, release-verify.sh read ONLY the java pin, and even that only DISCLOSED a
# divergence — it never failed one, in either direction. MEASURED against the pre-fix script: a fixture
# with every artifact genuinely published at $VER and only `ENGINE_PIN_TS` left three minor versions
# stale still printed "release-verify: OK — spec S / vV is live everywhere". The same fixture showed a
# SEPARATE bug in the opposite direction: a java pin correctly AHEAD (the ordinary shape of an unfinished
# one-engine patch — this file's own header says that "must not be a red monitor forever") made the
# family-wide form FAIL, because the java URLs built from the pin were held to the same "/v$VER/" rule
# jbang's catalog needs. Both are fixed the same way: rs_pin_report (release-verify.sh) judges the
# DIRECTION — behind fails the family form, ahead is disclosed and passes — for all four engines, not
# just java.
PJ="$(mktemp -d)"; mkdir -p "$PJ/bin" "$PJ/root/candor/bin"
# curl: crates.io's JSON shape for the four-crate check, and a bare 200 for every asset URL. Recognise
# `-w` STRUCTURALLY (loop over every arg) rather than by exact position, so an unrelated flag reorder in
# release-verify.sh cannot silently defang this stub the way a positional stub would.
cat > "$PJ/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; w=0
for a in "$@"; do
  case "$a" in
    http*) url="$a" ;;
    -w) w=1 ;;
  esac
done
case "$url" in
  https://crates.io/api/v1/crates/*) echo "{\"crate\":{\"max_version\":\"${PJ_VER:-0.0.0}\"}}" ;;
  *) [ "$w" = 1 ] && printf '200' || echo body ;;
esac
EOF
cat > "$PJ/bin/npm"  <<'EOF'
#!/usr/bin/env bash
[ "$1" = "view" ] && { echo "${PJ_VER:-0.0.0}"; exit 0; }
exit 1
EOF
cat > "$PJ/bin/npx"  <<'EOF'
#!/usr/bin/env bash
echo "candor-ts v${PJ_VER:-0.0.0} (spec ${PJ_SPEC:-0.0})"
EOF
# gh: every release, for every repo/tag asked, reports back as a clean non-draft — this row is about the
# pin logic, not the draft check (7d, above, already owns that).
cat > "$PJ/bin/gh"   <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "$3|false"; exit 0; fi
exit 1
EOF
chmod +x "$PJ"/bin/*
pjcandor() { # $1 = ENGINE_PIN_TS value under test ; every other per-engine pin stays empty
  printf 'ENGINE_PIN="0.33.0"\nENGINE_PIN_JAVA=""\nENGINE_PIN_TS="%s"\nENGINE_PIN_RUST=""\nENGINE_PIN_SWIFT=""\n' "$1" \
    > "$PJ/root/candor/bin/candor"
}
pjrun() { PJ_VER=0.33.0 PJ_SPEC=0.33 PATH="$PJ/bin:$PATH" CANDOR_ROOT="$PJ/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 2>&1; }

# CONTROL: the ordinary state (no per-engine pin at all) must report OK — establishes the rows below are
# measuring the PIN, not something wrong with the fixture.
pjcandor ""
printf '%s' "$(pjrun)" | grep -q "release-verify: OK — spec 0.33 / v0.33.0 is live everywhere" \
  && ok "CONTROL: no per-engine pin set — the ordinary state — reports OK" \
  || bad "[fixture] the clean baseline did not report OK; the rows below would measure nothing"

# THE DEFECT: candor-ts genuinely published at 0.33.0 (npm's `view` and the gh release both agree), but
# ENGINE_PIN_TS left BEHIND at a three-minor-old version — the version `candor update` actually installs.
pjcandor "0.30.0"
tsout="$(pjrun)"
printf '%s' "$tsout" | grep -q "release-verify: OK" \
  && bad "a candor-ts pin left BEHIND the release read as \"live everywhere\" — the false green" \
  || ok "a stale, BEHIND candor-ts pin fails the family-wide form"
printf '%s' "$tsout" | grep -q "pins ts BEHIND this release — it is 0.30.0, not 0.33.0" \
  && ok "…and names the engine, the pin's value and what it would still fetch" \
  || bad "a failing ts pin produced no actionable diagnostic"

# THE SAME QUESTION, ASKED OF RUST AND SWIFT — the reusable artefact is the question, not the one instance
# it was found in (candor-ts, above).
for kv in "ENGINE_PIN_RUST:rust" "ENGINE_PIN_SWIFT:swift"; do
  var="${kv%%:*}"; key="${kv##*:}"
  { echo 'ENGINE_PIN="0.33.0"'; echo 'ENGINE_PIN_JAVA=""'; echo 'ENGINE_PIN_TS=""'
    echo 'ENGINE_PIN_RUST=""'; echo 'ENGINE_PIN_SWIFT=""'; } \
    | sed "s/^$var=\"\"/$var=\"0.30.0\"/" > "$PJ/root/candor/bin/candor"
  eout="$(pjrun)"
  printf '%s' "$eout" | grep -q "release-verify: OK" \
    && bad "a $key pin left BEHIND the release read as \"live everywhere\"" \
    || ok "a stale, BEHIND $key pin fails the family-wide form too"
  printf '%s' "$eout" | grep -q "pins $key BEHIND this release — it is 0.30.0, not 0.33.0" \
    || bad "a failing $key pin produced no actionable diagnostic"
done

# THE OVER-CHARGE CONTROL, IN THE OTHER DIRECTION: a java pin AHEAD of the release (the ordinary, expected
# shape of a one-engine patch still in flight) must NOT fail the family-wide form. Before this fix it did:
# the java URLs built from the pin were held to the "/v$VER/" rule meant for jbang's catalog, so the
# weekly monitor would have gone red the moment a legitimate one-engine patch existed — the false-red
# found while fixing the false-green above.
printf 'ENGINE_PIN="0.33.0"\nENGINE_PIN_JAVA="0.34.0"\nENGINE_PIN_TS=""\nENGINE_PIN_RUST=""\nENGINE_PIN_SWIFT=""\n' \
  > "$PJ/root/candor/bin/candor"
aheadout="$(pjrun)"
printf '%s' "$aheadout" | grep -q "release-verify: OK — spec 0.33 / v0.33.0 is live everywhere" \
  && ok "CONTROL: a java pin AHEAD of the release (an in-flight one-engine patch) still reports OK" \
  || { bad "an AHEAD java pin failed the family-wide form — the false-red this fix also closes"
       printf '%s' "$aheadout" | grep -E '✘'; }
printf '%s' "$aheadout" | grep -q "pins java SEPARATELY at 0.34.0" \
  && ok "…and the divergence is still DISCLOSED, just not failed" \
  || bad "an ahead java pin vanished silently instead of being disclosed"

# AND A JAVA PIN BEHIND MUST STILL FAIL — same rule, same engine, now going through rs_pin_report instead
# of the coincidental "/v$VER/" string mismatch that used to catch (only) this one direction for java.
printf 'ENGINE_PIN="0.33.0"\nENGINE_PIN_JAVA="0.30.0"\nENGINE_PIN_TS=""\nENGINE_PIN_RUST=""\nENGINE_PIN_SWIFT=""\n' \
  > "$PJ/root/candor/bin/candor"
jbehindout="$(pjrun)"
printf '%s' "$jbehindout" | grep -q "release-verify: OK" \
  && bad "a java pin BEHIND the release read as \"live everywhere\"" \
  || ok "a stale, BEHIND java pin still fails the family-wide form"

# SCOPED: a diverged pin is DISCLOSED, never a failure — a scoped run does not claim "live everywhere" in
# the first place, so failing it over a fact only the family form is answerable for would be the wrong gate.
pjcandor "0.30.0"
scopedout="$(PJ_VER=0.33.0 PJ_SPEC=0.33 PATH="$PJ/bin:$PATH" CANDOR_ROOT="$PJ/root" \
             bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 --only candor-spec 2>&1)"
printf '%s' "$scopedout" | grep -q "release-verify: OK" \
  && ok "CONTROL: the SAME stale ts pin does not fail a SCOPED run — it is not that run's question" \
  || bad "a scoped run failed over a fact the family form alone is answerable for"
printf '%s' "$scopedout" | grep -q "pins ts SEPARATELY at 0.30.0" \
  && ok "…and is still disclosed, so an operator reading the scoped output is not blind to it" \
  || bad "a diverged pin vanished entirely under a scoped run"
rm -rf "$PJ"

say "7f. release-verify.sh — the npm version-mismatch line, and both adopt/ pin lines"
# WHY THIS EXISTS. Four release-verify.sh `bad()` branches were found by grepping the file for messages
# that never appear anywhere in this harness, never confirmed by actually driving them: the npm
# version-mismatch line, the two adopt/ pin lines (candor.yml's CANDOR_JAVA_VERSION, candor-digest.yml's
# candor-agents@v), "no pinned download URLs found", and the artifact URL version-mismatch line. Every
# existing fixture in this file (7d, 7e, 8, 9b) keeps npm and the adopt/ pins genuinely in step with $VER,
# so none of those rows could ever have exercised the branch that fires when they are NOT. This section and
# 7g/7h below are that confirmation, by deletion: each was run once with the `bad()` line under test
# commented out in a scratch copy, and every existing 295-assertion baseline stayed green — proving the gap
# was real, not merely unlikely.
NV="$(mktemp -d)"; mkdir -p "$NV/bin" "$NV/root/candor/bin" "$NV/root/candor/adopt"
printf 'ENGINE_PIN="0.33.0"\n' > "$NV/root/candor/bin/candor"
cat > "$NV/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "view" ] && { echo "${NPM_VER:-0.0.0}"; exit 0; }
exit 1
EOF
cat > "$NV/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "candor-ts v${NPM_VER:-0.0.0} (spec 0.33)"
EOF
# Generic: whatever tag is asked for comes back as that tag, non-draft. This section is not about the
# draft check (7d owns that) or about which repos are in scope (8 owns that).
cat > "$NV/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "$3|false"; exit 0; fi
exit 1
EOF
chmod +x "$NV"/bin/*
nvrun() { NPM_VER="$1" PATH="$NV/bin:$PATH" CANDOR_ROOT="$NV/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 --only candor-ts 2>&1; }
ctl="$(nvrun 0.33.0)"
printf '%s' "$ctl" | grep -q "release-verify: OK" \
  && ok "CONTROL: npm genuinely serving 0.33.0 passes, so the row below measures the mismatch" \
  || { bad "[fixture] the clean npm baseline did not pass; the row below would prove nothing"; printf '%s\n' "$ctl" | tail -6; }
red="$(nvrun 0.30.5)"
printf '%s' "$red" | grep -q "candor-ts: npm version '0.30.5' != 0.33.0" \
  && ok "[npm] a stale registry version is caught and named, not averaged into a pass" \
  || bad "[npm] deleted: npm serving a version other than the one just cut passed silently"
printf '%s' "$red" | grep -q "release-verify: OK" \
  && bad "[npm] a version mismatch on the registry still reported the run OK overall" \
  || ok "…and the run as a whole is FAILED, not a note beside a green verdict"
rm -rf "$NV"

# --- both adopt/ pin lines: candor.yml's CANDOR_JAVA_VERSION and candor-digest.yml's candor-agents@v ----
# Scoped to exactly the two pins' owner repos, so crates.io/npm/the artifact URLs never need stubbing —
# this section is purely about the adopt/ loop.
AD="$(mktemp -d)"; mkdir -p "$AD/bin" "$AD/root/candor/bin" "$AD/root/candor/adopt"
printf 'ENGINE_PIN="0.33.0"\n' > "$AD/root/candor/bin/candor"
cat > "$AD/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "$3|false"; exit 0; fi
exit 1
EOF
cat > "$AD/bin/curl" <<'EOF'
#!/usr/bin/env bash
w=0; for a in "$@"; do [ "$a" = "-w" ] && w=1; done
[ "$w" = 1 ] && printf '200' || echo body
EOF
chmod +x "$AD"/bin/*
adfiles() {  # $1 = java version string ; $2 = agents version string
  printf '          CANDOR_JAVA_VERSION: %s\n' "$1" > "$AD/root/candor/adopt/candor.yml"
  printf '        run: pipx install "git+https://github.com/tombaldwin/candor-agents@v%s"\n' "$2" \
    > "$AD/root/candor/adopt/candor-digest.yml"
}
adrun() { PATH="$AD/bin:$PATH" CANDOR_ROOT="$AD/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 --only candor-java,candor-agents 2>&1; }
adfiles 0.33.0 0.33.0
ctl="$(adrun)"
printf '%s' "$ctl" | grep -q "candor/adopt/candor.yml pins 0.33.0" \
  && ok "CONTROL: candor.yml's CANDOR_JAVA_VERSION genuinely at 0.33.0 is confirmed, not silent" \
  || { bad "[fixture] the clean adopt/ baseline did not confirm candor.yml; the row below proves nothing"; printf '%s\n' "$ctl" | tail -10; }
printf '%s' "$ctl" | grep -q "candor/adopt/candor-digest.yml pins 0.33.0" \
  && ok "CONTROL: candor-digest.yml's candor-agents@v genuinely at 0.33.0 is confirmed too" \
  || bad "[fixture] the clean adopt/ baseline did not confirm candor-digest.yml"
adfiles 0.32.0 0.33.0
red="$(adrun)"
printf '%s' "$red" | grep -q "candor/adopt/candor.yml pins 0.32.0, not 0.33.0 — every repo that ran \`candor init\` keeps installing 0.32.0" \
  && ok "[adopt java] a stale CANDOR_JAVA_VERSION is caught and named, not left for the next \`candor init\` to discover" \
  || bad "[adopt java] deleted: candor.yml left at the prior java version passed silently"
adfiles 0.33.0 0.31.5
red2="$(adrun)"
printf '%s' "$red2" | grep -q "candor/adopt/candor-digest.yml pins 0.31.5, not 0.33.0 — every repo that ran \`candor init\` keeps installing 0.31.5" \
  && ok "[adopt agents] a stale candor-agents@v pin is caught and named" \
  || bad "[adopt agents] deleted: candor-digest.yml left at the prior agents version passed silently"
printf '%s' "$red2" | grep -q "release-verify: OK" \
  && bad "[adopt agents] a stale consumer-facing pin still reported the run OK overall" \
  || ok "…and the run as a whole is FAILED over a pin nothing else in this file checks"
rm -rf "$AD"

say "7g. release-verify.sh — an artifact URL naming a DIFFERENT version than the one under verification"
# WHY THIS EXISTS. jbang-catalog.json's `script-ref` is read straight off disk (grep, not derived from
# ENGINE_PIN_JAVA), so it can go stale independently of the pin — release-stage.sh editing every OTHER
# staged site but missing this one is exactly the class 0.25/0.26 shipped (see this file's own header).
# `case "$u" in *"/v$VER/"*) ;; *) bad "pin names a different version..." ;; esac` is the one line that
# would catch it, and nothing here had ever driven a jbang URL whose version disagreed with $VER while
# ENGINE_PIN_JAVA itself was correct — every existing fixture (search "jbang-catalog.json" above) keeps
# the two in step.
JV="$(mktemp -d)"; mkdir -p "$JV/bin" "$JV/root/candor/bin" "$JV/root/candor-java"
printf 'ENGINE_PIN="0.33.0"\nENGINE_PIN_JAVA="0.33.0"\n' > "$JV/root/candor/bin/candor"
cat > "$JV/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "$3|false"; exit 0; fi
exit 1
EOF
cat > "$JV/bin/curl" <<'EOF'
#!/usr/bin/env bash
w=0; for a in "$@"; do [ "$a" = "-w" ] && w=1; done
[ "$w" = 1 ] && printf '200' || echo body
EOF
chmod +x "$JV"/bin/*
jvrun() { PATH="$JV/bin:$PATH" CANDOR_ROOT="$JV/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.33 0.33.0 --only candor-java 2>&1; }
printf '{"script-ref":"https://github.com/tombaldwin/candor-java/releases/download/v0.33.0/candor-java-0.33.0-all.jar"}' \
  > "$JV/root/candor-java/jbang-catalog.json"
ctl="$(jvrun)"
printf '%s' "$ctl" | grep -q "release-verify: OK" \
  && ok "CONTROL: jbang-catalog.json genuinely at v0.33.0 passes" \
  || { bad "[fixture] the clean jbang baseline did not pass; the row below proves nothing"; printf '%s\n' "$ctl" | tail -12; }
printf '{"script-ref":"https://github.com/tombaldwin/candor-java/releases/download/v0.32.1/candor-java-0.32.1-all.jar"}' \
  > "$JV/root/candor-java/jbang-catalog.json"
red="$(jvrun)"
printf '%s' "$red" | grep -q "pin names a different version than v0.33.0" \
  && ok "[artifact ver] jbang-catalog.json left at the prior release is caught, even though ENGINE_PIN_JAVA itself moved" \
  || bad "[artifact ver] deleted: a stale jbang-catalog.json URL passed silently while the pin looked fine"
printf '%s' "$red" | grep -q "release-verify: OK" \
  && bad "[artifact ver] a version-mismatched pinned URL still reported the run OK overall" \
  || ok "…and the run as a whole is FAILED"
rm -rf "$JV"

say "7h. release-verify.sh — \"no pinned download URLs found\" when a diverged pin empties the list"
# WHY THIS EXISTS. The urls[] array is fed from TWO places: jbang-catalog.json's own text, and a URL BUILT
# from ENGINE_PIN_JAVA — and the latter is routed to pin_urls (not urls) the moment the pin diverges from
# $VER (see release-verify.sh's own comment on `pin_urls`, "NOT held to the /v$VER/ rule"). Route java's
# only contribution to pin_urls, give candor-swift a version old enough that its own asset check legitimately
# expects nothing (candor-swift shipped no binaries before 0.27 — this file's own case statement says so),
# and urls[] is empty while EXPECT_URLS is still 1 — the exact shape `bad "no pinned download URLs found"`
# exists for. AHEAD (not behind) on purpose, so this measures the emptiness guard alone, not the
# already-covered (7e) BEHIND-pin failure riding along and explaining the row for the wrong reason.
UF="$(mktemp -d)"; mkdir -p "$UF/bin" "$UF/root/candor/bin"
cat > "$UF/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; w=0
for a in "$@"; do case "$a" in http*) url="$a" ;; -w) w=1 ;; esac; done
case "$url" in
  https://crates.io/api/v1/crates/*) echo "{\"crate\":{\"max_version\":\"${UF_VER:-0.0.0}\"}}" ;;
  *) [ "$w" = 1 ] && printf '200' || echo body ;;
esac
EOF
cat > "$UF/bin/npm" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "view" ] && { echo "${UF_VER:-0.0.0}"; exit 0; }
exit 1
EOF
cat > "$UF/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "candor-ts v${UF_VER:-0.0.0} (spec ${UF_SPEC:-0.0})"
EOF
cat > "$UF/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "release" ] && [ "$2" = "view" ]; then echo "$3|false"; exit 0; fi
exit 1
EOF
chmod +x "$UF"/bin/*
ufrun() { UF_VER=0.20.5 UF_SPEC=0.20 PATH="$UF/bin:$PATH" CANDOR_ROOT="$UF/root" \
            bash "$UMBRELLA/bin/release-verify.sh" 0.20 0.20.5 2>&1; }
# CONTROL: the same historical version, JPIN unset (ordinary state) — java's URLs land in urls[] the
# ordinary way and the emptiness guard must NOT fire.
printf 'ENGINE_PIN="0.20.5"\n' > "$UF/root/candor/bin/candor"
ctl="$(ufrun)"
printf '%s' "$ctl" | grep -q "no pinned download URLs found" \
  && bad "[fixture] the CONTROL (no diverged pin) already reports no URLs found — the row below proves nothing" \
  || ok "CONTROL: with ENGINE_PIN_JAVA unset, java's assets land in urls[] the ordinary way"
# THE DEFECT: ENGINE_PIN_JAVA diverges (AHEAD — a disclosed, not-failed state per 7e), which routes java's
# only urls[] contribution to pin_urls instead; candor-swift's own asset check contributes nothing at this
# VER by design. urls[] is now empty while EXPECT_URLS is 1.
printf 'ENGINE_PIN="0.20.5"\nENGINE_PIN_JAVA="0.21.0"\n' > "$UF/root/candor/bin/candor"
red="$(ufrun)"
printf '%s' "$red" | grep -q "no pinned download URLs found" \
  && ok "[empty urls] a diverged java pin emptying urls[] is caught, not silently passed as nothing to check" \
  || bad "[empty urls] deleted: EXPECT_URLS=1 with zero resolvable urls passed as if nothing needed checking"
printf '%s' "$red" | grep -q "release-verify: OK" \
  && bad "[empty urls] an empty, expected-nonempty urls[] still reported the run OK overall" \
  || ok "…and the run as a whole is FAILED, not a quiet pass over nothing checked"
rm -rf "$UF"

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
# See $N/bin/gh in the [10] NONE-branch fixture above for why "workflow list" and "run list --workflow
# <id>" are answered here too: GHGREEN's headSha ("none") never matches a real fixture commit, so every
# preflight run in this section takes ci_all_workflows_latest()'s NONE branch, and it needs both call
# shapes answered, not just the single unfiltered `run list` this stub used to provide.
case "$1 ${2:-}" in
  "auth status")    exit 0 ;;
  "release view")   exit 1 ;;
  "release create") echo "STUB-CREATE $*"; exit 0 ;;
  "workflow list")
    printf '%s' "${GH_RUNS:-[]}" | jq -c '[.[].workflowName] | unique | to_entries | map({id: (.key+1)})' ;;
  "run list")
    wf=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --workflow) wf="$2"; shift 2 ;; *) shift ;; esac; done
    if [ -n "$wf" ]; then
      name="$(printf '%s' "${GH_RUNS:-[]}" | jq -r --argjson wf "$wf" '[.[].workflowName] | unique | .[$wf-1]')"
      printf '%s' "${GH_RUNS:-[]}" | jq -c --arg n "$name" '[.[] | select(.workflowName==$n)] | .[0:1]'
    else
      printf '%s\n' "${GH_RUNS:-[]}"
    fi
    ;;
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
# release.sh's new final step (`8. release-verify`) runs the real release-verify.sh, which resolves
# curl/npm/gh against the real network — not hermetic, and not what these rows are about. Stubbed the
# same way preflight already is: copied OVER the fixture's own copy of the file, never invoked directly.
printf '#!/usr/bin/env bash\necho "STUB verify $*"\nexit 0\n' > "$CS/bin/release-verify-stub.sh"
# A SEPARATE stub that FAILS, with a distinct exit code and a distinctive diagnostic — used once, below,
# to prove release.sh forwards release-verify's own exit code and output rather than folding a verify
# failure into a generic `die` (which always exits 1 and would make the two indistinguishable).
printf '#!/usr/bin/env bash\necho "STUB verify $*"\necho "STUB verify: candor-swift v0.32.1 is a DRAFT release"\nexit 9\n' > "$CS/bin/release-verify-fail-stub.sh"
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
  # _ci_verdict.py MUST travel with release-preflight.sh: [10] execs it as "$HERE/_ci_verdict.py" (this
  # fixture's OWN bin/, not the real one), so leaving it out doesn't skip the CI check quietly — it makes
  # every verdict read ERR ("could not read CI status — treat as NOT verified") and fails the whole cut.
  # That is a real defect this harness caught on itself the first time this file changed: a missing
  # sibling script reads exactly like "CI status unknown", not like "test fixture incomplete".
  cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_stage_changelogs.py" "$UMBRELLA/bin/_release_set.sh" \
     "$UMBRELLA/bin/release.sh" "$UMBRELLA/bin/release-verify.sh" "$UMBRELLA/bin/release-preflight.sh" \
     "$UMBRELLA/bin/changelog-lag.sh" "$UMBRELLA/bin/_release_notes.sh" "$UMBRELLA/bin/_ci_verdict.py" \
     "$F/candor/bin/"
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
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
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
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
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
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
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
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
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
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
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

# --- release.sh's own final step (8): it must RUN release-verify, not just print instructions --------
# Regression pin for the wiring added after the 0.33.0 retrospective (candor-swift's DRAFT release
# reached users because nothing but a separately-remembered `release-verify.sh` invocation would have
# caught it). Before this, "DONE" was the last thing release.sh said and verification was homework left
# to the operator; now it is step 8 and its result decides whether the run reports success.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
vout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java 2>&1)"; vrc=$?
printf '%s' "$vout" | grep -qE 'STUB verify 0\.32 0\.32\.1 --only candor-java$' \
  && ok "release.sh's final step runs release-verify, SCOPED to exactly what this cut published" \
  || { bad "release.sh did not invoke release-verify with the cut's own --only scope"; printf '%s' "$vout" | tail -6; }
[ "$vrc" = 0 ] \
  && ok "…and a verify that reports OK lets release.sh exit 0" \
  || bad "release.sh exited $vrc despite release-verify reporting success"

# CONTROL: a verify FAILURE must reach the operator with release-verify's OWN exit code and output — not
# silently swallowed, and not folded into a generic `die` (which always exits 1 and would make "verify
# found a problem" indistinguishable from any other failure to a caller inspecting the exit code).
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
cp "$CS/bin/release-verify-fail-stub.sh" "$CSF/candor/bin/release-verify.sh"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
fvout="$(PATH="$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java 2>&1)"; fvrc=$?
[ "$fvrc" = 9 ] \
  && ok "CONTROL: release.sh exits with release-verify's OWN code (9), not a generic 1" \
  || bad "release.sh did not preserve release-verify's exit code — got $fvrc, expected 9"
printf '%s' "$fvout" | grep -q "candor-swift v0.32.1 is a DRAFT release" \
  && ok "…and release-verify's own diagnostic reaches the operator" \
  || bad "release-verify's failure detail was swallowed"
printf '%s' "$fvout" | grep -q "release-verify FAILED (exit 9)" \
  && ok "…and release.sh names the failure loudly instead of dying silently" \
  || bad "release.sh's own failure line did not fire"
printf '%s' "$fvout" | grep -q "STUB-CREATE.*-R tombaldwin/candor-java" \
  && ok "…and the publish itself still happened before verify ran (verify is the LAST step, not a gate before publishing)" \
  || bad "release.sh did not publish before running verify — the step ordering regressed"

say "9. gh release create can fail AFTER creating the release (e.g. a rejected asset upload) — must not swallow it"
# `gh release create <tag> <jar> …` can create the release and still exit non-zero if the asset upload
# fails (plausible for java's jar). The old code was `gh release create … && ok "$repo $tag"` with no
# `|| die` — the exact same swallowed-failure shape as the tag-push defect above. A rerun's own guard
# (`gh release view`, two lines up in `rel()`) then sees the release "exists" and skips, never
# re-uploading — release-verify.sh catches the missing asset later by resolving the URL, but until this
# fix the remedy (`gh release upload`) was in no die message anywhere in this script.
csfix "$CSF"
cp "$CS/bin/release-preflight-stub.sh" "$CSF/candor/bin/release-preflight.sh"
cp "$CS/bin/release-verify-stub.sh" "$CSF/candor/bin/release-verify.sh"
( cd "$CSF/candor" && /usr/bin/git add -A && /usr/bin/git -c user.email=t@e -c user.name=t commit -qm s \
  && /usr/bin/git push -q origin HEAD ) >/dev/null 2>&1
GHF="$(mktemp -d)"; mkdir -p "$GHF/bin"
cat > "$GHF/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status")  exit 0 ;;
  "release view") exit 1 ;;   # not yet released — rel() takes the create branch
  "release create")
    echo "STUB-CREATE-THEN-FAIL $*"   # the release half "succeeds" — gh still reports overall failure
    exit 1
    ;;
esac
exit 0
EOF
chmod +x "$GHF/bin/gh"
ghfail="$(PATH="$GHF/bin:$CS/bin:$PATH" CANDOR_ROOT="$CSF" bash "$CSF/candor/bin/release.sh" 0.32 0.32.1 --only candor-java 2>&1)"; ghfailrc=$?
[ "$ghfailrc" != 0 ] \
  && ok "a gh release create failure makes release.sh exit non-zero — not silently continuing" \
  || { bad "release.sh exited 0 despite gh release create failing — the swallowed-failure shape is back"; printf '%s\n' "$ghfail" | tail -6; }
printf '%s' "$ghfail" | grep -q "gh release create failed or a partial upload" \
  && ok "…and names the failure explicitly, rather than falling through to the next step" \
  || bad "no diagnostic for the gh release create failure"
printf '%s' "$ghfail" | grep -q "gh release upload v0.32.1 .* -R tombaldwin/candor-java --clobber" \
  && ok "…and the remedy (\`gh release upload\`) is IN the die message, not left for the operator to guess" \
  || bad "the gh release upload remedy is missing from the die message"
rm -rf "$GHF"

say "9b. release-preflight.sh — FAIL branches a guard-deletion sweep found nothing drives: [1][2][2b][3][4][5][6][8][12]"
# WHY THIS SECTION EXISTS. Every other row that runs a real (non-stubbed) release-preflight.sh over
# csfix's fixture keeps it internally consistent — same declared spec everywhere, no stray prior-floor
# string, matching crate deps, agreeing repo lists, a spec whose highest rung equals its own declared
# version. That consistency is what makes the OTHER rows in this file trustworthy; it also means eleven
# of preflight's `bad()` calls have never once fired in this harness — deleting any of them left the
# ✔/✘ symbol you would grep for STILL PRESENT via unrelated rows, or absent from the count entirely, and
# `bash bin/release-test.sh` stayed 281/281 green either way. Confirmed by actually deleting each guard
# in turn (bin/release-preflight.sh lines for [1], [2], [2b], [3]'s strict pin bad(), [4], [5], [6], both
# [8] arms and all of [12]) and re-running this file: every deletion left it at "281 assertions", nothing
# in CI or verify-local would have caught a regression in any of them. Each row below breaks the ONE
# invariant the check exists for and proves the specific message still reaches the operator.
csfix "$CSF"

# --- [1] engines DISAGREE on the declared spec -------------------------------------------------------
perl -pi -e 's/const SPEC_VERSION = "0\.32"/const SPEC_VERSION = "0.31"/' "$CSF/candor-ts/query.mjs"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "engines DISAGREE on the declared spec" \
  && ok "[1] a candor-ts spec one rung behind every other engine is caught, not averaged away" \
  || bad "[1] deleted: a genuine cross-engine spec split passed silently — 0.23->0.24's own failure shape"
csfix "$CSF"
ctl="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$ctl" | grep -q "all declare spec 0.32" \
  && ok "CONTROL: …and the untouched fixture agrees, so the row above is measuring the split, not noise" \
  || bad "[1] CONTROL is broken — the clean fixture does not even print the agreement line"

# --- [2] a leftover PRIOR-FLOOR ('spec 0.31') string in shipped, non-fixture, non-excluded source -----
csfix "$CSF"
printf '\n# legacy: spec 0.31 support was dropped here\n' >> "$CSF/candor-agents/pyproject.toml"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "leftover 'spec 0.31' in shipped source" \
  && ok "[2] a bump-miss-shaped 'spec 0.31' string in shipped source is caught" \
  || bad "[2] deleted: the exact bump-miss signature this check exists for passed silently"
csfix "$CSF"
ctl="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$ctl" | grep -q "no leftover 'spec 0.31' strings" \
  && ok "CONTROL: …and the untouched fixture has none — the row above measures the injected string" \
  || bad "[2] CONTROL is broken — the clean fixture already reports a leftover"

# --- [2b] the BARE-LITERAL form ('"spec"' ... '"0.31"' on one line) the [2] grep structurally misses --
csfix "$CSF"
printf '\n// legacy: obj?.["spec"] as? String == "0.31"\n' >> "$CSF/candor-ts/scan.mjs"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "bare-literal spec assertion at the prior floor" \
  && ok "[2b] a bare-literal \"spec\"/\"0.31\" pair (the [2] regex cannot see) is caught" \
  || bad "[2b] deleted: the literal-assertion bump-miss shape passed silently"

# --- [3] a cross-repo pin that does NOT name the version being cut, in STRICT (non-advisory) mode -----
# Every other row exercising [3] sets PINS_ADVISORY=1 (the deadlock-avoidance mode release.sh step 0
# actually runs under). Nothing in this harness had ever called preflight in the STRICT mode an operator
# uses when checking "did step 6 actually move the pins" — so the one branch that turns a forgotten pin
# bump into a hard failure had zero coverage.
csfix "$CSF"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "adopt java.*pin does not reference 0.32.1" \
  && ok "[3] STRICT mode fails a java-owned pin that was never moved to the version being cut" \
  || bad "[3] deleted: a stale cross-repo pin passed in the exact mode an operator runs by hand"
ctl="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$ctl" | grep -q "pin does not reference" \
  && bad "CONTROL: PINS_ADVISORY=1 should downgrade the same unmoved pin to advisory, not fail it" \
  || ok "CONTROL: …and PINS_ADVISORY=1 downgrades the identical state to advisory, as release.sh step 0 needs"

# --- [4] a hand-maintained build constant that disagrees with the version being cut -------------------
# THIS ROW COULD NOT FAIL EITHER, AND FOR A DIFFERENT REASON THAN 1d's: the FIXTURE already broke the
# invariant before anything was injected. `csfix` builds candor-ts/package.json at 0.32.0 while
# preflight is asked for 0.32.1, so [4]'s WANT_VER arm — its only `bad()` — fired with or without the
# perl edit, and the grep matched either way. Measured 2026-08-30 by removing the injection.
# The section header promises each row "breaks the ONE invariant the check exists for", so make that
# true: bring the manifest to the version being cut FIRST (a CONTROL that must pass), then break it.
csfix "$CSF"
perl -pi -e 's/"version": "0\.32\.0"/"version": "0.32.1"/' "$CSF/candor-ts/package.json"
ctl4="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-ts 2>&1)"
printf '%s' "$ctl4" | grep -q "a build version.*!= requested 0.32.1" \
  && { bad "[4] CONTROL: the fixture already fails [4] with nothing injected — the row below cannot attribute anything"; \
       printf '%s\n' "$ctl4" | grep -i 'build version' | head -3; } \
  || ok "[4] CONTROL: with candor-ts's manifest AT the version being cut, [4] passes"
perl -pi -e 's/"version": "0\.32\.1"/"version": "0.32.9"/' "$CSF/candor-ts/package.json"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-ts 2>&1)"
printf '%s' "$red" | grep -q "a build version.*!= requested 0.32.1" \
  && ok "[4] candor-ts's own package.json left at the wrong version fails, not just release-stage's edit" \
  || bad "[4] deleted: a hand-maintained build constant disagreeing with the cut passed silently"

# --- [5] a CHANGELOG that never mentions the floor being cut -------------------------------------------
csfix "$CSF"
printf '# Changelog\n\n## Unreleased\n\n## [0.31.5] - 2026-07-01\n\nold notes, never touched since.\n' \
  > "$CSF/candor-agents/CHANGELOG.md"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "candor-agents CHANGELOG.md has no 0.32 entry" \
  && ok "[5] a CHANGELOG that never mentions the floor fails, even for a repo outside the cut" \
  || bad "[5] deleted: a changelog describing a different release entirely passed silently"

# --- [6] a rust crate requiring a candor sibling at a PRIOR version (the mid-publish cargo failure) ----
csfix "$CSF"
cat >> "$CSF/candor-rust/crates/candor-report/Cargo.toml" <<'EOF'

[dependencies]
candor-classify = { path = "../candor-classify", version = "0.32.0" }
EOF
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-rust 2>&1)"
printf '%s' "$red" | grep -q "requires a candor sibling at 0.32.0, not 0.32.1" \
  && ok "[6] a sibling dep left at the prior version is caught (cargo publish dies mid-sequence otherwise)" \
  || bad "[6] deleted: the exact 0.25 failure shape (a stale intra-workspace dep) passed silently"

# --- [8] the publisher (release.sh) and verifier (release-verify.sh) naming DIFFERENT repo sets -------
csfix "$CSF"
perl -pi -e 's/"candor-agents:v\$VER" //' "$CSF/candor/bin/release-verify.sh"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "publisher and verifier disagree" \
  && ok "[8] release.sh publishing a repo release-verify.sh never checks is caught" \
  || bad "[8] deleted: the publisher/verifier repo-list split (the 4-vs-7 defect) passed silently"

# --- [8]'s own sibling check: changelog-lag.sh auditing a DIFFERENT repo set than release.sh cuts ------
csfix "$CSF"
perl -pi -e 's/candor-agents //' "$CSF/candor/bin/changelog-lag.sh"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "changelog-lag \[5b\] checks a DIFFERENT set" \
  && ok "[8] changelog-lag.sh silently dropping a repo release.sh still cuts is caught" \
  || bad "[8] deleted: an eighth-family-repo-shaped drop from changelog-lag's list passed silently"

# --- [12] SPEC.md describing a rung above the version it declares (the ⟨0.31⟩ non-additive near-miss) -
csfix "$CSF"
printf '**Version 0.32**\n⟨0.32⟩ a rung marker.\n⟨0.33⟩ a rung ahead of its own declared number.\n' \
  > "$CSF/candor-spec/SPEC.md"
red="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$red" | grep -q "SPEC.md declares Version 0.32 but describes ⟨0.33⟩" \
  && ok "[12] a spec rung ahead of its own declared version is caught (a routine cut would ship it)" \
  || bad "[12] deleted: the ⟨0.31⟩-shaped near-miss (text ahead of its number) passed silently"
csfix "$CSF"
ctl="$(PATH="$CS/bin:$PATH" GH_RUNS="$GHGREEN" CI_NO_WAIT=1 PINS_ADVISORY=1 CANDOR_ROOT="$CSF" \
      bash "$CSF/candor/bin/release-preflight.sh" 0.32 0.32.1 --only candor-java 2>&1)"
printf '%s' "$ctl" | grep -q "highest rung ⟨0.32⟩ is within the declared 0.32" \
  && ok "CONTROL: …and the untouched fixture's rung matches its version, so the row above measures the gap" \
  || bad "[12] CONTROL is broken — the clean fixture does not even print the within-floor line"

rm -rf "$CS"

say "10. release-rehearsal.sh arm [1] — a repo that is not a git repo must not read as clean, nor drop out of the count"
# THE NINTH FALSE GREEN, other half. Unlike release.sh (fixed above), this arm ALREADY checked
# `[ -d "$d/.git" ]` before touching the repo — but on a miss it just printed "⊘ … not a git repo" and
# `continue`d, never calling `problem()` and never counting toward `tree_bad`. So the summary line
# ("all $tree_n repo(s) clean and pushed") still fired, counting a repo the arm never actually examined
# as evidence it was fine. Detection worked; the surrounding aggregation discarded it — the same shape as
# every other false green this family has found in its release machinery.
RH="$(mktemp -d)"
mkdir -p "$RH/bin"
cp "$UMBRELLA/bin/release-rehearsal.sh" "$UMBRELLA/bin/_release_set.sh" "$RH/bin/"
chmod +x "$RH/bin/release-rehearsal.sh"
# Stub the three slow arms so this row tests ONLY the tree-state arm, in well under a second.
for s in verify-local.sh verify-umbrella.sh release-preflight.sh; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RH/bin/$s"; chmod +x "$RH/bin/$s"
done
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  d="$RH/$r"; mkdir -p "$d"
  ( cd "$d" && git init -q && git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init )
  git init -q --bare "$RH/remotes-$r.git"
  ( cd "$d" && git remote add origin "$RH/remotes-$r.git" && git push -q -u origin HEAD )
done
rh_run() { CANDOR_ROOT="$RH" bash "$RH/bin/release-rehearsal.sh" 0.32 0.32.2 2>&1; }
# NAMED $rhout/$rhrc, not the ambient $out/$rc this file reuses across sections — see the identical note
# on section 1d above, which is where reusing those names actually broke an unrelated later row.
rhout="$(rh_run)"; rhrc=$?
[ "$rhrc" = 0 ] && printf '%s' "$rhout" | grep -q "no problems found in 4 arm(s)" \
  && ok "CONTROL: with every repo present, clean and pushed, the rehearsal is green" \
  || { bad "CONTROL setup is broken — the all-clean fixture is not green, so the row below proves nothing"; printf '%s\n' "$rhout" | tail -15; }
rm -rf "$RH/candor-java"
rhout="$(rh_run)"; rhrc=$?
[ "$rhrc" != 0 ] \
  && ok "a repo missing entirely makes the rehearsal exit non-zero, not \"no problems found\"" \
  || bad "release-rehearsal exited 0 with candor-java's directory deleted — THE NINTH FALSE GREEN IS BACK"
printf '%s' "$rhout" | grep -q "all 7 repo(s) clean and pushed" \
  && bad "the summary still claims \"all 7 repo(s) clean and pushed\" with one of the seven missing" \
  || ok "…and does not also claim all 7 repos were clean and pushed"
printf '%s' "$rhout" | grep -q '\[1\] candor-java: not a git repo at' \
  && ok "…and the missing repo is named as a PROBLEM in the summary, not just an informational line" \
  || bad "the missing repo did not reach the problem list — '$(printf '%s' "$rhout" | grep -m1 'candor-java')'"
rm -rf "$RH"

say "11. verify-local.sh — the CANDOR_ROOT injection and the pass/fail signal itself"
# WHY THIS EXISTS. verify-local.sh's entire pass/fail signal is one line — `[ -s "$FAILED" ] && rc=1` —
# and it had no CANDOR_ROOT-style injection point at all, unlike every other release script (see
# release-preflight.sh, release.sh, release-stage.sh, spec-bump.sh, release-verify.sh, all sourced or
# grepped above). Every OTHER appearance of verify-local.sh in this file is as a STUBBED dependency of
# some other script's test (see the `for s in verify-local.sh …` loop further down) — never as the thing
# under test. So this line has never been driven, in either direction, by anything but a real engine's
# real suite breaking. Fixed by adding the identical `${CANDOR_ROOT:-…}` convention; this section is the
# test that convention exists to make possible.
VL="$(mktemp -d)"; mkdir -p "$VL/candor-agents"
vlpy() { printf 'import sys\nsys.exit(%s)\n' "$1" > "$VL/candor-agents/test.py"; }
vlrun() { CANDOR_ROOT="$VL" bash "$UMBRELLA/bin/verify-local.sh" candor-agents 2>&1; }
# Strip the elapsed-seconds field before any byte-for-byte comparison — real, so it is not itself
# fabricated, but its VALUE is wall-clock timing and asserting on that would make this row flaky rather
# than meaningful.
normtime() { printf '%s' "$1" | sed -E 's/\(([0-9]+)s\)/(Ns)/g'; }

vlpy 0
green1="$(vlrun)"; greenrc1=$?
[ "$greenrc1" = 0 ] && ok "an all-green fixture exits 0" || bad "an all-green fixture exited $greenrc1"
printf '%s' "$green1" | grep -q "verify-local: OK" \
  && ok "…and prints the OK verdict" || bad "an all-green fixture did not print the OK verdict"
green2="$(vlrun)"
[ "$(normtime "$green1")" = "$(normtime "$green2")" ] \
  && ok "…and two green runs are byte-identical (elapsed-seconds aside)" \
  || { bad "two green runs of the identical fixture differed"
       diff <(normtime "$green1") <(normtime "$green2") | head -6; }

vlpy 1
red="$(vlrun)"; redrc=$?
[ "$redrc" != 0 ] \
  && ok "a failing engine step makes verify-local.sh exit non-zero" \
  || bad "a failing python3 test.py step still exited 0 — the ONE pass/fail line is broken"
printf '%s' "$red" | grep -qE "candor-agents.*python3 test\.py.*✘ FAILED" \
  && ok "…and NAMES the failing step (repo + label), not just a bare non-zero exit" \
  || bad "a failing step's identity did not reach the output — '$(printf '%s' "$red" | grep -m1 candor-agents)'"
printf '%s' "$red" | grep -q "verify-local: FAILED" \
  && ok "…and prints the FAILED verdict, not OK beside a nonzero exit" \
  || bad "a failing run printed something other than the FAILED verdict"

# GUARD-DELETION TARGET: `wait` between launching the background steps and `[ -s "$FAILED" ] && rc=1`.
# Every step runs in `( … ) &`, so without `wait` the main shell can reach the pass/fail check before a
# SLOW step has written to $FAILED at all — exactly the "detector worked, aggregator discarded it" shape
# this session's brief describes elsewhere. A step that fails INSTANTLY (the row above) cannot tell a
# present `wait` apart from an absent one, because the race window is too narrow to matter. This one can:
# confirmed by actually deleting the `wait` line in a scratch copy and re-running this exact fixture, which
# then printed "verify-local: OK" while the backgrounded sleep was still running.
printf 'import sys, time\ntime.sleep(1)\nsys.exit(1)\n' > "$VL/candor-agents/test.py"
slow="$(vlrun)"; slowrc=$?
[ "$slowrc" != 0 ] \
  && ok "a step that fails AFTER a delay is still caught — \`wait\` closes the race before the verdict" \
  || bad "a slow-failing step raced past the pass/fail check and exited 0 — the \`wait\` guard is not doing its job"
printf '%s' "$slow" | grep -q "verify-local: FAILED" \
  && ok "…and the verdict itself reflects it, not just the exit code" \
  || bad "a slow-failing step's FAILED verdict did not print"
rm -rf "$VL"

say "11b. verify-local.sh — an unrecognised or absent \$ONLY must not read as \"nothing to check, so OK\""
# GUARD-DELETION FINDING, not a pre-existing test. `want()` is a plain string compare with no validation
# against it, so before this fix a typo'd engine name (or a valid name whose directory is simply not
# checked out) matched zero blocks, printed nothing — not even a SKIPPED line, which only fires when the
# directory exists but the toolchain doesn't — and still reached "verify-local: OK — every step of every
# engine present passed" having run ZERO steps. The identical false-green shape verify-umbrella.sh's own
# "NOTHING RAN" guard exists for, on the one script CLAUDE.md tells every agent to trust as a standing
# check before every push.
VE="$(mktemp -d)"
badname="$(CANDOR_ROOT="$VE" bash "$UMBRELLA/bin/verify-local.sh" candor-rustt 2>&1)"; badrc=$?
# `!= 0` COULD NOT SEE THE GUARD THIS ROW IS NAMED FOR. Measured 2026-08-30 by deleting verify-local's
# whole engine-name `case` branch: rc was STILL non-zero, because with no name matched `$RAN` stays
# empty and the downstream NOTHING RAN guard exits 1. Two different guards, one exit test, and the row
# was attributing to the wrong one. They use DIFFERENT codes — usage error 2, NOTHING RAN 1 — so
# asserting the code rather than its non-zeroness restores the attribution for free.
[ "$badrc" = 2 ] \
  && ok "an unrecognised engine name is a usage error (exit 2), not a silent no-op — and not the NOTHING RAN exit 1" \
  || bad "verify-local.sh 'candor-rustt' (typo) did not produce the usage exit 2 (rc=$badrc); a non-zero from the NOTHING RAN guard is a different check answering"
printf '%s' "$badname" | grep -q "is not a candor engine" \
  && ok "…and says WHY, rather than leaving the operator to guess" \
  || bad "no diagnostic for the unrecognised engine name"

missing="$(CANDOR_ROOT="$VE" bash "$UMBRELLA/bin/verify-local.sh" candor-agents 2>&1)"; missingrc=$?
[ "$missingrc" != 0 ] \
  && ok "a recognised engine name whose directory is not checked out is a FAILURE, not a quiet OK" \
  || bad "verify-local.sh ran zero steps for a missing candor-agents/ and still exited 0"
printf '%s' "$missing" | grep -q "NOTHING RAN" \
  && ok "…and says so explicitly, distinct from every-step-passed" \
  || bad "a zero-step run produced no NOTHING RAN diagnostic"
printf '%s' "$missing" | grep -q "verify-local: OK" \
  && bad "a zero-step run printed the OK verdict" \
  || ok "…and the OK verdict never prints over zero steps"
rm -rf "$VE"

say "12. verify-umbrella.sh — the pass/fail signal itself (zero dedicated tests until now)"
# WHY THIS EXISTS. verify-umbrella.sh has no CANDOR_ROOT-style injection point at all — REPO is derived
# from its OWN script location (`dirname "${BASH_SOURCE[0]}"/..`), not an env var — so the only way to
# exercise it has been to run it against THIS repo's real workflows, which cannot make a step fail on
# demand. Given the same treatment release-rehearsal.sh's own test already uses (section 10, above): copy
# the script plus its two collaborators into a throwaway git repo carrying a trivial workflow, so `REPO`
# resolves to the fixture by construction. Scoped to the two exit-code branches that matter most — a
# failing step must make the run exit non-zero, a clean one must exit 0 — not to the full breadth of
# wf-steps.py/wf-expected.py selection, which already carry their own --selftest.
UV="$(mktemp -d)"; mkdir -p "$UV/bin" "$UV/.github/workflows"
cp "$UMBRELLA/bin/verify-umbrella.sh" "$UMBRELLA/bin/wf-steps.py" "$UMBRELLA/bin/wf-expected.py" "$UV/bin/"
chmod +x "$UV/bin/verify-umbrella.sh"
uvwf() {  # $1 = the step's shell command
  cat > "$UV/.github/workflows/test.yml" <<EOF
name: Test
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: the step
        run: $1
EOF
  ( cd "$UV" && git add -A && git -c user.email=t@e -c user.name=t commit -q -m step )
}
( cd "$UV" && git init -q && git checkout -q -b main )
uvwf "exit 0"
uvout="$(bash "$UV/bin/verify-umbrella.sh" --all 2>&1)"; uvrc=$?
[ "$uvrc" = 0 ] && ok "an all-green workflow exits 0" || { bad "an all-green workflow exited $uvrc"; printf '%s\n' "$uvout" | tail -6; }
printf '%s' "$uvout" | grep -q "verify-umbrella: OK" \
  && ok "…and prints the OK verdict" || bad "an all-green run did not print the OK verdict"

uvwf 'echo boom; exit 1'
uvout="$(bash "$UV/bin/verify-umbrella.sh" --all 2>&1)"; uvrc=$?
[ "$uvrc" != 0 ] \
  && ok "a failing workflow step makes verify-umbrella.sh exit non-zero" \
  || bad "a failing step still exited 0 — verify-umbrella's own pass/fail signal is broken"
printf '%s' "$uvout" | grep -q "verify-umbrella: FAILED" \
  && ok "…and prints the FAILED verdict" || bad "a failing run did not print the FAILED verdict"
printf '%s' "$uvout" | grep -q "boom" \
  && ok "…and the failing step's own output reaches the report" || bad "the failing step's output did not reach the report"
rm -rf "$UV"

say "12b. verify-umbrella.sh — the SELECTION machinery: can a step that should run be skipped, or vice versa"
# WHY THIS EXISTS. Section 12 proves the pass/fail SIGNAL works, but its fixture workflow carries no path
# filter at all, so `wf_required()` — the function every RUN row in $STEPS is actually gated by — was
# never driven in either direction. wf-steps.py and wf-expected.py each carry their own `--selftest`; the
# code HERE that consumes their output (REQUIRED, wf_required(), the INSCOPE/dispatch loops) had none. A
# skip is the single easiest place for a false green to hide — a step that silently does not run looks,
# from the exit code alone, exactly like one that ran and passed.
UV2="$(mktemp -d)"; mkdir -p "$UV2/tool" "$UV2/.github/workflows" "$UV2/bin"
cp "$UMBRELLA/bin/verify-umbrella.sh" "$UMBRELLA/bin/wf-steps.py" "$UMBRELLA/bin/wf-expected.py" "$UV2/tool/"
chmod +x "$UV2/tool/verify-umbrella.sh"
cat > "$UV2/.github/workflows/filtered.yml" <<'EOF'
name: Filtered
on:
  push:
    branches: [main]
    paths: ['bin/**']
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: the filtered step
        run: echo FILTERED_RAN
EOF
cat > "$UV2/.github/workflows/always.yml" <<'EOF'
name: Always
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: the unfiltered step
        run: echo ALWAYS_RAN
EOF
printf 'keep\n' > "$UV2/bin/.keep"; printf 'x\n' > "$UV2/docs.md"
( cd "$UV2" && git init -q && git branch -m main 2>/dev/null && git add -A \
  && git -c user.email=t@e -c user.name=t commit -qm base )

# A commit that touches ONLY docs.md: GitHub would run `always.yml` (no filter) and would NOT run
# `filtered.yml` (its paths do not include docs.md).
printf 'y\n' >> "$UV2/docs.md"
( cd "$UV2" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "docs only" )
out2="$(bash "$UV2/tool/verify-umbrella.sh" 2>&1)"; rc2=$?
# A step's own stdout ("echo ALWAYS_RAN") is only printed in the report when it FAILS (run_step keeps a
# passing step's output out of the ledger) — so the evidence a step actually ran is its ROW, a job label
# beside a ✔ mark, not its echoed text.
printf '%s' "$out2" | grep -qE "the unfiltered step.*✔" \
  && ok "a workflow with NO path filter runs on a docs-only commit" \
  || bad "an unfiltered workflow did not run on a docs-only commit: $out2"
printf '%s' "$out2" | grep -qE "the filtered step.*✔" \
  && bad "a path-filtered workflow ran on a commit touching none of its paths — the skip machinery let a should-not-run step through" \
  || ok "a path-filtered workflow correctly did NOT run on a commit outside its paths"
printf '%s' "$out2" | grep -q 'GitHub would not trigger `Filtered`' \
  && ok "…and the skip carries its OWN reason, not a bare absence" \
  || bad "the filtered-out step's reason did not appear in the DID NOT RUN list: $out2"
[ "$rc2" = 0 ] && printf '%s' "$out2" | grep -q "verify-umbrella: OK" \
  && ok "one required step ran, one path-filtered step skipped — still an honest OK" \
  || bad "a legitimate mixed ran/skipped outcome did not print OK (rc=$rc2): $out2"

# Now a commit that DOES touch bin/**: both workflows must run.
printf 'a\n' > "$UV2/bin/a.sh"
( cd "$UV2" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "touch bin/a.sh" )
out2b="$(bash "$UV2/tool/verify-umbrella.sh" 2>&1)"
printf '%s' "$out2b" | grep -qE "the filtered step.*✔" \
  && ok "…and once a commit DOES touch bin/**, the same path-filtered workflow runs" \
  || bad "a workflow whose path filter the commit actually matches was still skipped: $out2b"
rm -rf "$UV2"

say "12c. verify-umbrella.sh — the multi-commit RANGE UNION, not just the pushed tip"
# WHY THIS EXISTS. GitHub path-filters a push on the UNION of every commit's changed files, not the tip's
# alone (this script's own comment above REQUIRED says so). The union loop over `base..SHA` had no test:
# a push of several commits where only an EARLIER one touches a path-filtered workflow's paths is exactly
# the shape a tip-only check would silently under-select.
UV3="$(mktemp -d)"; mkdir -p "$UV3/tool" "$UV3/.github/workflows" "$UV3/bin"
cp "$UMBRELLA/bin/verify-umbrella.sh" "$UMBRELLA/bin/wf-steps.py" "$UMBRELLA/bin/wf-expected.py" "$UV3/tool/"
chmod +x "$UV3/tool/verify-umbrella.sh"
cat > "$UV3/.github/workflows/bin.yml" <<'EOF'
name: BinOnly
on:
  push:
    branches: [main]
    paths: ['bin/**']
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: the step
        run: echo BIN_RAN
EOF
printf 'keep\n' > "$UV3/bin/.keep"
( cd "$UV3" && git init -q && git branch -m main 2>/dev/null && git add -A \
  && git -c user.email=t@e -c user.name=t commit -qm base )
BASESHA="$(git -C "$UV3" rev-parse HEAD)"
git -C "$UV3" update-ref refs/remotes/origin/main "$BASESHA"

# Commit A (NOT the tip): touches bin/**.
printf 'a\n' > "$UV3/bin/a.sh"
( cd "$UV3" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "touch bin/a.sh" )
# Commit B (the tip): touches only docs — alone it matches no filter at all.
printf 'b\n' > "$UV3/README.md"
( cd "$UV3" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "docs only, the tip" )

out3="$(bash "$UV3/tool/verify-umbrella.sh" 2>&1)"
printf '%s' "$out3" | grep -qE "the step.*✔" \
  && ok "a path-filtered workflow runs when an EARLIER commit in the push range touched its paths, even though the TIP alone does not" \
  || bad "the multi-commit range union is broken: an in-range commit touching bin/ did not make the workflow required — $out3"
printf '%s' "$out3" | grep -q "the 2 commit(s) in" \
  && ok "…and the report names the whole range, not just the tip" \
  || bad "the range description did not name the 2-commit union: $out3"
rm -rf "$UV3"

say "12d. verify-umbrella.sh — a broken SELECTOR must abort, not silently answer \"nothing required\""
# The comment above the wf-expected.py call is explicit that this call is NOT `2>/dev/null`-ed for exactly
# this reason: swallowing its failure would turn a broken selector into a silent, plausible-looking pass
# (every workflow reads not-required, everything skips, exit 0). Never actually driven.
UV4="$(mktemp -d)"; mkdir -p "$UV4/tool" "$UV4/.github/workflows"
cp "$UMBRELLA/bin/verify-umbrella.sh" "$UMBRELLA/bin/wf-steps.py" "$UV4/tool/"
chmod +x "$UV4/tool/verify-umbrella.sh"
cat > "$UV4/tool/wf-expected.py" <<'EOF'
#!/usr/bin/env python3
import sys
sys.stderr.write("stub: wf-expected.py forced failure\n")
sys.exit(1)
EOF
chmod +x "$UV4/tool/wf-expected.py"
cat > "$UV4/.github/workflows/filtered.yml" <<'EOF'
name: Filtered
on:
  push:
    branches: [main]
    paths: ['bin/**']
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: the step
        run: echo SHOULD_NOT_APPEAR
EOF
( cd "$UV4" && git init -q && git branch -m main 2>/dev/null && git add -A \
  && git -c user.email=t@e -c user.name=t commit -qm base )
out4="$(bash "$UV4/tool/verify-umbrella.sh" 2>&1)"; rc4=$?
[ "$rc4" = 2 ] \
  && ok "a broken wf-expected.py (the selection helper) aborts the whole run, exit 2" \
  || bad "a failing selection helper did not abort (rc=$rc4) — its failure could be silently swallowed into 'nothing required': $out4"
printf '%s' "$out4" | grep -q "the selection cannot be trusted" \
  && ok "…and says the selection itself is untrustworthy, not just \"something failed\"" \
  || bad "no diagnostic naming the broken selector: $out4"
printf '%s' "$out4" | grep -q "verify-umbrella: OK" \
  && bad "a broken selector still printed the OK verdict" \
  || ok "…and never reaches the OK verdict over an untrustworthy selection"
rm -rf "$UV4"

say "13. probe.sh — the differ-check and --concluded, its own two headline guards (zero dedicated tests until now)"
# WHY THIS EXISTS. probe.sh's own header lists five wrong measurements its differ-check exists to catch
# and five more its --concluded mode exists to catch, and states the whole point of the file: "a probe
# that will be cited … gets the same treatment as a row." Nothing had ever given IT that treatment. Fixed
# the same way as verify-local.sh: added the identical CANDOR_ROOT injection point (probe.sh had none
# either) so quiet_tree_check's sibling-repo walk does not touch the real, currently-dirty umbrella tree
# mid-edit, then drove the two guards directly.
#
# THE SAME ENVIRONMENT GUARD 13b CARRIES, HOISTED — because this section needed it too and did not have
# it. probe.sh's quiet_tree_check pgreps the WHOLE MACHINE, so another agent's conformance run refuses
# every probe below with exit 2. Measured 2026-08-30: three rows here went red for a reason that was not
# the subject, and the FIRST row went GREEN for a reason that was not the subject either — it asserts
# "control==subject is REFUSED, exit 2", and a refusal for being busy is also exit 2. Two mechanisms
# producing the same label, masking each other (AGENT-CORPUS-BRIEF rule 4), inside the file whose whole
# subject is instruments that read the right thing.
probe_env_busy() {
  pgrep -f "conformance/run.sh" >/dev/null 2>&1 || pgrep -f "swift build" >/dev/null 2>&1 \
    || pgrep -f "gradlew" >/dev/null 2>&1 || pgrep -f "cargo build" >/dev/null 2>&1 \
    || pgrep -f "cargo test" >/dev/null 2>&1
}
# A BOUNDED WAIT, not an immediate skip: this machine's interference is usually a short-lived check
# (measured: a mutation-gate poison run, gone within a few seconds), so give it a few chances before
# giving up rather than skipping on the first unlucky sample.
probe_wait_quiet() {
  local t=0
  while probe_env_busy && [ "$t" -lt 5 ]; do sleep 2; t=$((t+1)); done
  probe_env_busy && return 1 || return 0
}
if ! probe_wait_quiet; then
  note_skip "section 13 — a build or conformance run from another agent is still in flight after 10s. probe.sh's machine-wide guard refuses with exit 2 for that reason, which is the SAME exit code the differ-check uses, so these rows cannot tell the two apart. Re-run once the machine is quiet."
else
PR="$(mktemp -d)"
ctl="$(CANDOR_ROOT="$PR" bash "$UMBRELLA/bin/probe.sh" printf X -- printf X 2>&1)"; ctlrc=$?
[ "$ctlrc" = 2 ] \
  && ok "control and subject producing IDENTICAL output is REFUSED (exit 2), not reported as a finding" \
  || bad "control==subject was not refused (exit $ctlrc) — the differ-check is not doing its job"
printf '%s' "$ctl" | grep -q "CONTROL AND SUBJECT AGREE" \
  && ok "…and says why: the probe is presumed BROKEN, not that the two arms agree meaningfully" \
  || bad "no diagnostic for an agreeing control/subject pair"
diff="$(CANDOR_ROOT="$PR" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"; diffrc=$?
[ "$diffrc" = 0 ] \
  && ok "control and subject producing DIFFERENT output is accepted, not refused" \
  || bad "a genuinely discriminating control/subject pair was refused (exit $diffrc)"
printf '%s' "$diff" | grep -q "control and subject DIFFER" \
  && ok "…and says the probe discriminates" || bad "no confirmation that the probe discriminates"

conc="$(CANDOR_ROOT="$PR" bash "$UMBRELLA/bin/probe.sh" --concluded DONE -- bash -c 'echo DONE; exit 7' 2>&1)"; concrc=$?
[ "$concrc" = 7 ] \
  && ok "--concluded forwards the SUBJECT's own exit code when its marker printed" \
  || bad "--concluded did not forward exit 7 (got $concrc)"
printf '%s' "$conc" | grep -q "concluded (marker 'DONE' present)" \
  && ok "…and says the output IS a verdict" || bad "no 'concluded' confirmation for a marker that printed"
noconc="$(CANDOR_ROOT="$PR" bash "$UMBRELLA/bin/probe.sh" --concluded DONE -- bash -c 'echo partial; exit 1' 2>&1)"; noconcrc=$?
[ "$noconcrc" = 4 ] \
  && ok "a command that dies before printing its own marker is DID-NOT-CONCLUDE (exit 4), not read as a real result" \
  || bad "a command that never reached its marker was not flagged DID NOT CONCLUDE (got $noconcrc)"
printf '%s' "$noconc" | grep -q "DID NOT CONCLUDE" \
  && ok "…and says its rows above the stop are real but its absence of rows means nothing" \
  || bad "no DID NOT CONCLUDE diagnostic for a command that died mid-run"
rm -rf "$PR"
fi

say "13b. probe.sh — quiet_tree_check and provenance, its other two headline guards (zero dedicated tests until now)"
# WHY THIS EXISTS. Section 13 exercises the differ-check and --concluded. The two guards this file's own
# header spends the MOST words on — a dirty/moving tree (failure 2: a conformance run read a half-written
# file and reported a cardinal sin nobody had committed) and a stale binary (failure 4: a 2h-old release
# build was probed while the suite builds and uses .build/debug) — had never been driven at all.
PR2="$(mktemp -d)"; mkdir -p "$PR2/candor-rust"
( cd "$PR2/candor-rust" && git init -q && git branch -m main 2>/dev/null \
  && printf 'fn main(){}\n' > lib.rs && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )

# quiet_tree_check's pgrep calls scan the WHOLE MACHINE, by design (a build running ANYWHERE could be the
# one about to replace the binary under test) — which means the "expect no refusal" rows below are only
# meaningful when nothing ELSE on this box happens to match those same patterns. On a dedicated CI runner
# that is always true; on a shared dev box running several agents at once (this file's own AGENT-CORPUS-
# BRIEF.md: "concurrent agents on one box do contend") it sometimes is not — measured live while writing
# this section, when an unrelated `swift build` from another agent made every one of these rows fail for a
# reason that was not this fixture. Treat that as a SKIP, the same convention this file already uses for a
# missing tool, rather than either a false FAIL or silently trusting a result the environment could not
# actually produce.
# probe_env_busy / probe_wait_quiet are defined above section 13, which needs the same guard.
if ! probe_wait_quiet; then
  note_skip "section 13b — this machine still has a conformance run or a build in flight (from another agent) after waiting 10s, which would make probe.sh's own machine-wide guard fire for reasons unrelated to this fixture. Re-run once the machine is quiet."
  rm -rf "$PR2"
else

# CONTROL: a clean tree, nothing running — no dirty note, no refusal.
clean="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"; cleanrc=$?
[ "$cleanrc" = 0 ] && ok "a clean tree with nothing running is not flagged" \
  || bad "a clean tree was refused (rc=$cleanrc): $clean"
printf '%s' "$clean" | grep -q "dirty tree" \
  && bad "a clean tree was reported dirty" || ok "…and prints no dirty-tree note"

# An UNTRACKED-only file must NOT count as dirty — quiet_tree_check greps OUT `^?? ` lines on purpose.
printf 'scratch\n' > "$PR2/candor-rust/untracked.tmp"
untracked="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"
printf '%s' "$untracked" | grep -q "dirty tree" \
  && bad "an UNTRACKED file was reported as a dirty tree" \
  || ok "an untracked file alone does not trip the dirty-tree note"
rm -f "$PR2/candor-rust/untracked.tmp"

# A MODIFIED TRACKED file must be named, and must NOT be fatal — you may be probing your own edit.
printf 'fn main(){ changed(); }\n' > "$PR2/candor-rust/lib.rs"
dirty="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"; dirtyrc=$?
printf '%s' "$dirty" | grep -q "dirty tree(s):.*candor-rust" \
  && ok "a modified TRACKED file is named in the dirty-tree note" \
  || bad "a dirty tracked file did not produce the dirty-tree note: $dirty"
[ "$dirtyrc" = 0 ] && ok "…and a dirty tree is a NOTE, not a refusal" \
  || bad "a merely-dirty tree was refused outright (rc=$dirtyrc)"
git -C "$PR2/candor-rust" checkout -q -- lib.rs

# A CONFORMANCE RUN IN FLIGHT is fatal — it reads engines from their working trees, and probing or
# editing during it contaminates the run in both directions (failure 2 in this file's own header).
mkdir -p "$PR2/candor-spec/conformance"
printf '#!/bin/bash\nsleep 6\n' > "$PR2/candor-spec/conformance/run.sh"
chmod +x "$PR2/candor-spec/conformance/run.sh"
bash "$PR2/candor-spec/conformance/run.sh" & confpid=$!
sleep 0.3
inflight="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"; inflightrc=$?
kill "$confpid" 2>/dev/null; wait "$confpid" 2>/dev/null
[ "$inflightrc" = 2 ] && ok "a conformance run IN FLIGHT refuses the probe outright" \
  || bad "a live conformance run did not refuse the probe (rc=$inflightrc): $inflight"
printf '%s' "$inflight" | grep -q "conformance run is IN FLIGHT" \
  && ok "…and says why" || bad "no IN FLIGHT diagnostic: $inflight"
rm -rf "$PR2/candor-spec"

# A BUILD IN PROGRESS is fatal for the same reason — the binary being probed may be replaced mid-run.
mkdir -p "$PR2/fakebin"
printf '#!/bin/bash\nsleep 6\n' > "$PR2/fakebin/cargo"
chmod +x "$PR2/fakebin/cargo"
"$PR2/fakebin/cargo" build & buildpid=$!
sleep 0.3
building="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- printf Y 2>&1)"; buildingrc=$?
kill "$buildpid" 2>/dev/null; wait "$buildpid" 2>/dev/null
[ "$buildingrc" = 2 ] && ok "a build in progress (cargo build) refuses the probe" \
  || bad "a live 'cargo build' process did not refuse the probe (rc=$buildingrc): $building"
printf '%s' "$building" | grep -q "a build is running" \
  && ok "…and says which" || bad "no build-in-progress diagnostic: $building"

# PROVENANCE: a binary OLDER than the newest source file is a STALE measurement (failure 4).
printf '#!/bin/bash\necho ran\n' > "$PR2/candor-rust/binary"; chmod +x "$PR2/candor-rust/binary"
touch -t 202001010000 "$PR2/candor-rust/binary"
touch -t 202601010000 "$PR2/candor-rust/lib.rs"
stale="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PR2/candor-rust/binary" 2>&1)"; stalerc=$?
[ "$stalerc" = 3 ] && ok "a binary OLDER than the newest source exits 3 (STALE)" \
  || bad "a stale binary did not produce exit 3 (rc=$stalerc): $stale"
printf '%s' "$stale" | grep -q "STALE: this binary is OLDER THAN THE SOURCE" \
  && ok "…and names it as such, on the row" || bad "no STALE diagnostic for an old binary: $stale"

# CONTROL: a binary NEWER than every source file must not be flagged.
touch -t 202601020000 "$PR2/candor-rust/binary"
fresh="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PR2/candor-rust/binary" 2>&1)"; freshrc=$?
[ "$freshrc" = 0 ] && ok "a binary newer than every source file is not flagged stale" \
  || bad "a fresh binary was flagged stale (rc=$freshrc): $fresh"
printf '%s' "$fresh" | grep -q "STALE" \
  && bad "a fresh binary printed a STALE diagnostic anyway" || ok "…and prints no STALE line"

# The .build/release NOTE — a distinct binary from the one the suite actually builds and uses.
mkdir -p "$PR2/candor-swift/.build/release"
( cd "$PR2/candor-swift" && git init -q && git branch -m main 2>/dev/null \
  && printf 'struct X {}\n' > lib.swift && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )
printf '#!/bin/bash\necho ran\n' > "$PR2/candor-swift/.build/release/candor-swift"
chmod +x "$PR2/candor-swift/.build/release/candor-swift"
touch -t 202601020000 "$PR2/candor-swift/.build/release/candor-swift"
rel="$(CANDOR_ROOT="$PR2" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PR2/candor-swift/.build/release/candor-swift" 2>&1)"
printf '%s' "$rel" | grep -q "conformance builds and uses .build/debug/" \
  && ok "probing a .build/release binary is told conformance uses the OTHER one" \
  || bad "no .build/debug NOTE for a .build/release subject: $rel"
rm -rf "$PR2"
fi

say "14. changelog-lag.sh — the ONE-\`## Unreleased\`-per-file guard (zero dedicated tests until now)"
# WHY THIS EXISTS. Section 7 exercises the RECENCY half of this script. The DUPLICATE-SECTION half at the
# bottom of the file — the one release-stage.sh's own empty-stub trap depends on, since the stager renames
# only the FIRST `## Unreleased` and a second one ships silently still labelled unreleased — had never
# been driven directly.
CD="$(mktemp -d)"
mkclrepo() { # $1 = CHANGELOG.md body
  local p="$CD/candor-ts"; rm -rf "$p"; mkdir -p "$p"
  printf 'v1\n' > "$p/scan.mjs"
  printf '%s' "$1" > "$p/CHANGELOG.md"
  git -C "$p" init -q && git -C "$p" branch -m main 2>/dev/null
  git -C "$p" add -A && git -C "$p" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$p" tag v0.1.0
}
cdrun() { CANDOR_ROOT="$CD" bash "$UMBRELLA/bin/changelog-lag.sh" candor-ts 2>&1; }

mkclrepo '# Changelog

## Unreleased

## [0.1.0]

first cut.
'
out="$(cdrun)"; rc=$?
[ "$rc" = 0 ] && ok "a single Unreleased section passes" || bad "one Unreleased section failed (rc=$rc): $out"

mkclrepo '# Changelog

## Unreleased

### something landed after the cut
body

## Unreleased

## [0.1.0]

first cut.
'
out="$(cdrun)"; rc=$?
[ "$rc" = 1 ] && ok "TWO Unreleased sections above the first release FAIL" \
  || bad "two Unreleased sections passed (rc=$rc): $out"
printf '%s' "$out" | grep -q '2 `## Unreleased` sections' \
  && ok "…and the count is named" || bad "the duplicate count did not appear: $out"
printf '%s' "$out" | grep -q "the stager renames only the FIRST" \
  && ok "…with the mechanism, not just a bare complaint" || bad "no explanation of WHY this matters: $out"

# An OLD, historical '## [Unreleased] ...' heading sitting BELOW an already-numbered release (settled
# history) must NOT be counted, per this script's own comment: flagging settled history reads as noise and
# stops the check from being read at all.
mkclrepo '# Changelog

## Unreleased

## [0.1.0]

first cut.

## [Unreleased] (nightly lint)

some old note nobody is going to un-ship.
'
out="$(cdrun)"; rc=$?
[ "$rc" = 0 ] && ok "a historical '## [Unreleased]' heading buried below a numbered release is ignored" \
  || bad "settled history below the first release was wrongly counted as a duplicate (rc=$rc): $out"
rm -rf "$CD"

say "14b. _ci_verdict.py — attacked directly, not only through release-preflight.sh's fixtures"
# WHY THIS EXISTS. Every existing row for this file (7b, above) drives it THROUGH release-preflight.sh's
# stubbed \`gh\`, which always hands it well-formed JSON. The one defensive line actually IN the file — the
# try/except around json.load, printing "ERR" rather than an uncaught traceback — had never once been fed
# anything that would exercise it.
malformed="$(printf 'not json{' | python3 "$UMBRELLA/bin/_ci_verdict.py" deadbeef)"; rcm=$?
[ "$malformed" = "ERR" ] && [ "$rcm" = 0 ] \
  && ok "malformed JSON on stdin prints ERR and exits 0, not an uncaught traceback" \
  || bad "malformed JSON did not produce a clean ERR (rc=$rcm, out='$malformed')"

empty="$(printf '' | python3 "$UMBRELLA/bin/_ci_verdict.py" deadbeef)"; rce=$?
[ "$empty" = "ERR" ] && [ "$rce" = 0 ] \
  && ok "empty stdin (a gh call that produced nothing) also prints ERR, not a silent empty verdict" \
  || bad "empty stdin did not produce ERR (rc=$rce, out='$empty')"

say "15. gates.sh + gate-run.sh — the pre-push gate list and the tool that runs it (zero tests until now)"
# WHY THIS EXISTS. gate-run.sh's own header says it exists because "the expensive thing is the thing that
# gets quietly narrowed to five", and that green over an unrun gate is what it stops. Nothing tested it,
# and on 2026-08-30 it printed "OK — every gate ran and passed", exit 0, over a repo bin/gates.sh had
# never heard of: gates.sh printed nothing (its stderr went to /dev/null and its exit status was never
# read), the loop ran zero times, and zero failures read as success. A verification tool that is itself
# wrong converts unrun gates into reported-green, which is the exact failure it was built to prevent.
# Both files carry a CANDOR_ROOT injection point now, for the same reason probe.sh grew one.
GR="$(mktemp -d)"
mkwf() { mkdir -p "$GR/$1/.github/workflows"; cat > "$GR/$1/.github/workflows/$2"; }
grun()  { CANDOR_ROOT="$GR" bash "$UMBRELLA/bin/gate-run.sh" "$@" 2>&1; }
glist() { CANDOR_ROOT="$GR" bash "$UMBRELLA/bin/gates.sh"    "$@" 2>&1; }

# A NAME gates.sh DOES NOT KNOW is an error, not an empty list.
mkdir -p "$GR/candor-old"
out="$(glist candor-old)"; rc=$?
[ "$rc" = 2 ] && ok "gates.sh refuses a repo name it does not know (exit 2), rather than printing nothing" \
  || bad "an unknown repo name did not fail (rc=$rc): $out"
out="$(grun candor-old)"; rc=$?
[ "$rc" = 2 ] && ok "…and gate-run.sh propagates that: a gate LIST that could not be produced is exit 2" \
  || bad "gate-run.sh did not propagate a failing gates.sh (rc=$rc): $out"
printf '%s' "$out" | grep -q "gate LIST could not be produced" \
  && ok "…and says the list is the thing that failed, not the gates" \
  || bad "no diagnostic naming the LIST as the failure: $out"
printf '%s' "$out" | grep -q "OK — every gate ran and passed" \
  && bad "gate-run.sh printed the OK verdict over a repo whose gate list it could not read" \
  || ok "…and never reaches the OK verdict over an unreadable gate list"

# A repo gates.sh KNOWS, with no workflows at all: still not a pass.
mkdir -p "$GR/candor-agents"
out="$(grun candor-agents)"; rc=$?
[ "$rc" = 2 ] && ok "a repo with NO workflows is INCOMPLETE (exit 2), not OK over an empty gate set" \
  || bad "an empty gate set did not produce exit 2 (rc=$rc): $out"
printf '%s' "$out" | grep -q "OK — every gate ran and passed" \
  && bad "zero gates read as 'every gate ran and passed'" || ok "…and does not claim every gate passed"

# THE CONTROL FOR ALL OF THE ABOVE. A tool that never says OK would pass every row so far while being
# useless. So prove the green verdict is reachable on a repo whose one gate genuinely passes.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: true
YML
out="$(grun candor-agents)"; rc=$?
[ "$rc" = 0 ] && ok "CONTROL: a repo whose only gate passes DOES reach OK, exit 0" \
  || bad "the OK verdict is unreachable — every row above is vacuous (rc=$rc): $out"

# A FAILING GATE MUST REACH THE EXIT CODE (attack H: detection is rarely the failure, aggregation is).
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: true
      - name: b
        run: false
YML
out="$(grun candor-agents)"; rc=$?
[ "$rc" = 1 ] && ok "one failing gate among passing ones exits 1" \
  || bad "a failing gate did not reach the exit code (rc=$rc): $out"
printf '%s' "$out" | grep -q "gate-run: OK" \
  && bad "a failing gate still printed OK" || ok "…and prints NOT GREEN, never OK"

# A GATE THAT READS STDIN MUST NOT EAT THE GATE LIST. The loop reads its list on stdin, so without a
# `</dev/null` the first stdin-reading gate swallows every gate below it — and the run then reports only
# the gates that survived, with a clean OK. A silent narrowing that looks exactly like a short list.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: cat
      - name: b
        run: true
      - name: c
        run: true
YML
out="$(grun candor-agents)"; rc=$?
printf '%s' "$out" | grep -q "3 gate(s) run" \
  && ok "a gate that reads stdin does not swallow the gates below it (all 3 still run)" \
  || bad "a stdin-reading gate narrowed the run: $(printf '%s' "$out" | grep 'gate(s) run')"
[ "$rc" = 0 ] && ok "…and the run still concludes normally" || bad "stdin fixture did not conclude (rc=$rc): $out"

# `working-directory:` IS PART OF THE COMMAND. Dropped, both candor-spec and the umbrella were
# permanently un-greenable — and where a same-named script exists at the root, the wrong one runs.
mkdir -p "$GR/candor-agents/sub"; printf 'x\n' > "$GR/candor-agents/sub/marker.txt"
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        working-directory: sub
        run: test -f marker.txt
YML
out="$(glist candor-agents)"
printf '%s' "$out" | grep -q "cd sub && test -f marker.txt" \
  && ok "gates.sh prints a step's working-directory as an executable \`cd X && …\` prefix" \
  || bad "the working-directory was dropped from the printed gate line: $out"
out="$(grun candor-agents)"; rc=$?
[ "$rc" = 0 ] && ok "…so gate-run.sh runs it where CI runs it, and the gate passes" \
  || bad "a working-directory step did not run in its own directory (rc=$rc): $out"

# A `${{ }}` EXPRESSION HAS NO LOCAL VALUE. bash calls it a bad substitution and exits 1, which reads
# as a FAILING GATE — candor-java's `./dist/${{ matrix.asset }} --version` made that repo permanently red.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: ./dist/${{ matrix.asset }} --version
      - name: b
        run: true
YML
out="$(grun candor-agents)"; rc=$?
printf '%s' "$out" | grep -q 'GitHub \${{ }} expression' \
  && ok "an unexpanded GitHub expression is SKIPped and named, not run" \
  || bad "the \${{ }} step was not named as unrunnable: $out"
printf '%s' "$out" | grep -q "FAIL" \
  && bad "an unexpandable GitHub expression was reported as a FAILING gate" \
  || ok "…and is not miscounted as a failure"
[ "$rc" = 2 ] && ok "…and a skipped gate makes the verdict INCOMPLETE (exit 2), never OK" \
  || bad "a skipped gate did not produce INCOMPLETE (rc=$rc): $out"

# BLOCK (`run: |`) LINES ARE COUNTED AS MANUAL AND NEVER EXECUTED — they are script fragments, and the
# `~` marker gates.sh writes them with is at a different COLUMN from a gate line, so a line can be
# neither both nor neither. If they were executed, the `exit 7` below would run.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: |
          true
          exit 7
YML
out="$(grun candor-agents)"; rc=$?
printf '%s' "$out" | grep -q "0 gate(s) run, 0 ok, 0 failed, 0 skipped, 2 block line(s)" \
  && ok "a multi-line block step contributes block lines, never executed gates" \
  || bad "block-form accounting is wrong: $(printf '%s' "$out" | grep 'gate(s) run')"
[ "$rc" = 2 ] && ok "…and block lines nobody ran make the verdict INCOMPLETE, not OK" \
  || bad "unrun block lines did not produce INCOMPLETE (rc=$rc): $out"

# EVERY block-scalar indicator, not just `|`. A FOLDED step (`run: >`) matched as a ONE-LINE step whose
# command was the literal `>`, and the step's actual body vanished from the output altogether — not a
# gate line, not a `~` line, absent. Latent (nothing in the family uses `>` today) and reachable by
# writing one workflow, which is the silently-narrowed list both files exist to prevent.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: folded
        run: >
          echo one &&
          echo two
      - name: after
        run: true
YML
out="$(glist candor-agents)"
printf '%s' "$out" | grep -qx '        >' \
  && bad "a folded 'run: >' step is printed as a gate whose command is the literal '>'" \
  || ok "a folded 'run: >' step is not printed as a bare '>' gate"
printf '%s' "$out" | grep -q '~ echo one &&' \
  && ok "…and its body is kept, marked as block lines to read rather than run" \
  || bad "the folded step's body vanished from the list entirely: $out"
out="$(grun candor-agents)"; rc=$?
printf '%s' "$out" | grep -q "1 gate(s) run, 1 ok, 0 failed, 0 skipped, 2 block line(s)" \
  && ok "…and gate-run.sh counts it as 2 block lines beside the 1 real gate" \
  || bad "folded-step accounting is wrong: $(printf '%s' "$out" | grep 'gate(s) run')"

# …AND EVERY CHOMPING FORM OF IT, because the one that was covered is the only one that was LOUD.
# YAML's folded scalar takes an optional chomping indicator, so a step may be written `>`, `>-` or
# `>+`. Under the pre-fix regex all three were emitted as a GATE LINE whose command was the indicator
# itself and the body was dropped — but what `eval` then does with them differs completely. Measured
# 2026-08-30 against the pre-fix parse, holding gate-run.sh and this fixture constant and changing
# ONLY gates.sh's block-scalar regex:
#
#   `>`   → bash syntax error   → rc 1, a FAIL row          (wrong reason, but VISIBLE)
#   `>-`  → a REDIRECTION       → rc 0, `gate-run: OK`, and a file named `-` appears in the repo
#   `>+`  → a REDIRECTION       → rc 0, `gate-run: OK`, and a file named `+` appears in the repo
#
# So the covered variant was the single one that could not report green over an unrun gate, and the
# two uncovered ones both did — while writing a file into the tree being verified. A fixture set that
# stops at the spelling in the bug report inherits the bug report's blind spot.
#
# HONEST NOTE ON WHICH OF THESE ROWS WERE FALSIFIED. Against the pre-fix regex, 15 rows in this
# section go red — every row for `>-` and `>+`, both junk-file rows, and the body/indicator rows for
# `>`. The two VERDICT rows for `>` alone (`does not exit 0`, `never prints OK`) stay GREEN there,
# because `eval ">"` is a bash syntax error and the pre-fix tool therefore failed LOUDLY on that one
# spelling. They are kept — they are the same assertion applied uniformly and they discriminate
# against other regressions — but they are not evidence about THIS fix, and nobody should read the
# loop's uniformity as twelve falsified rows.
for ind in '>' '>-' '>+'; do
  # Quoted: `strip` is a real command, and shellcheck SC2209 flags a bare assignment from one.
  case "$ind" in '>') itag='plain' ;; '>-') itag='strip' ;; *) itag='keep' ;; esac
  mkwf candor-agents ci.yml <<YML
jobs:
  t:
    steps:
      - name: folded-$itag
        run: $ind
          bash soundness/run.sh 60
YML
  out="$(glist candor-agents)"
  printf '%s' "$out" | grep -q '~ bash soundness/run.sh 60' \
    && ok "gates.sh keeps the BODY of a \`run: $ind\` step, as a block line to read" \
    || bad "the body of a \`run: $ind\` step vanished from the list entirely: $out"
  printf '%s' "$out" | grep -qx "        $ind" \
    && bad "\`run: $ind\` printed the INDICATOR itself as a runnable gate command" \
    || ok "…and never prints \`$ind\` at the 8-space column, where gate-run.sh would eval it"
  out="$(grun candor-agents)"; rc=$?
  [ "$rc" != 0 ] \
    && ok "…so gate-run.sh over a \`$ind\` step does not exit 0 (rc=$rc — the body is unrun, and says so)" \
    || bad "gate-run.sh exited 0 over a \`run: $ind\` step whose body nothing ran"
  printf '%s' "$out" | grep -q "gate-run: OK" \
    && bad "gate-run.sh printed the OK verdict over an unrun \`run: $ind\` body" \
    || ok "…and never reaches the OK verdict"
done
# THE INDICATOR MUST NOT HAVE BEEN EVAL'D AT ALL, and the verdict alone cannot tell you that. `eval
# ">-"` is not a failed command, it is a successful REDIRECTION: it creates a file named `-` inside
# the repo the tool is verifying. A run that reported INCOMPLETE for some other reason would satisfy
# every row above while still having written into the tree.
for junk in - +; do
  [ -e "$GR/candor-agents/$junk" ] \
    && bad "a folded step's indicator was eval'd as a redirection — it created a file named '$junk' in the repo being verified" \
    || ok "no file named '$junk' exists in the fixture repo — the indicator was never eval'd"
done

# WHICH WORKFLOWS ARE PRE-PUSH GATES COMES FROM THEIR `on:` BLOCK, NOT THEIR FILENAME. gates.sh used
# `case "$(basename)" in release*|publish*|nightly*)`, and on the repo that HOLDS it that name glob
# excluded `release-scripts.yml` — `on: push: branches:[main]`, the job that runs THIS FILE — from
# `gates.sh candor` entirely. A gate list narrowed by a string match, under a parenthetical that read
# like a considered decision. Wrong in the other direction too: schedule-only `corpus.yml` was kept,
# and its `cargo build --manifest-path candor-rust/…` cannot resolve outside CI's checkout layout, so
# `gate-run.sh candor` was permanently red for a reason that is not a defect.
mkdir -p "$GR/candor-agents/.github/workflows"; rm -f "$GR/candor-agents/.github/workflows/ci.yml"
cat > "$GR/candor-agents/.github/workflows/release-things.yml" <<'YML'
on:
  push:
    branches: [main]
  pull_request:
jobs:
  t:
    steps:
      - name: a
        run: true
YML
cat > "$GR/candor-agents/.github/workflows/publish.yml" <<'YML'
on:
  push:
    tags: ['v*']
  workflow_dispatch:
jobs:
  t:
    steps:
      - name: a
        run: exit 3
      - name: b
        run: exit 3
YML
cat > "$GR/candor-agents/.github/workflows/weekly.yml" <<'YML'
on:
  schedule:
    - cron: '0 3 * * 1'
  workflow_dispatch:
jobs:
  t:
    steps:
      - name: a
        run: exit 3
YML
out="$(glist candor-agents)"
printf '%s' "$out" | grep -qx '        true' \
  && ok "a workflow NAMED release-* is printed when its own \`on:\` says push/pull_request" \
  || bad "a push-triggered workflow was excluded by its NAME — the gate list is short: $out"
printf '%s' "$out" | grep -q 'publish.yml (on: .*tags only.* — not a pre-push gate;' \
  && ok "…and a \`push: tags:\` workflow is excluded, NAMED, with the triggers it was judged on" \
  || bad "a tag-only workflow was not excluded-and-named: $(printf '%s' "$out" | grep publish)"
printf '%s' "$out" | grep -q 'weekly.yml (on: schedule.* — not a pre-push gate;' \
  && ok "…and so is a schedule-only one" || bad "a schedule-only workflow was not excluded-and-named: $out"
printf '%s' "$out" | grep -qx '        exit 3' \
  && bad "a step from an excluded workflow still reached the gate list" \
  || ok "…and no step from either excluded workflow reached the gate list"
# EXCLUDING IS NARROWING, SO IT MUST BE COUNTED. A per-workflow parenthetical scrolls past; the total
# at the bottom is where a wrong `on:` parse shows up as a number instead of as an absence.
printf '%s' "$out" | grep -q '2 workflow(s) excluded above as not-pre-push' \
  && ok "…and the count of exclusions is printed at the bottom, beside the verdict" \
  || bad "exclusions were not counted in the trailer: $(printf '%s' "$out" | tail -2)"
printf '%s' "$out" | grep -q '2 run step(s) behind this line' \
  && ok "…each naming how many run steps it stands in front of, so \"excluded\" cannot read as \"empty\"" \
  || bad "an exclusion line does not say how many steps are behind it: $(printf '%s' "$out" | grep publish)"
# AND THE FAIL-SAFE DIRECTION. An `on:` shape the parse cannot read must OVER-PRINT, never drop: this
# file's own rule is that a clever parser silently dropping a step is the failure it exists to prevent.
cat > "$GR/candor-agents/.github/workflows/odd.yml" <<'YML'
"on": [push, workflow_dispatch]
jobs:
  t:
    steps:
      - name: a
        run: echo ODD_KEPT
YML
out="$(glist candor-agents)"
printf '%s' "$out" | grep -q 'echo ODD_KEPT' \
  && ok "an inline/quoted \`on:\` the classifier cannot decompose is PRINTED, not dropped" \
  || bad "an unparseable \`on:\` block silently dropped the workflow's steps: $out"
rm -f "$GR/candor-agents/.github/workflows/release-things.yml" \
      "$GR/candor-agents/.github/workflows/publish.yml" \
      "$GR/candor-agents/.github/workflows/weekly.yml" \
      "$GR/candor-agents/.github/workflows/odd.yml"

# An unrecognised second argument must not silently mean "not a dry run" and execute everything.
# The fixture matters: over a repo that is INCOMPLETE anyway, exit 2 proves nothing, so use one whose
# gate really would run, and assert on the diagnostic and on nothing having run.
mkwf candor-agents ci.yml <<'YML'
jobs:
  t:
    steps:
      - name: a
        run: true
YML
out="$(grun candor-agents --dryrun)"; rc=$?
[ "$rc" = 2 ] && ok "a mistyped --dryrun is a usage error, not a live run of every gate" \
  || bad "an unknown second argument was accepted (rc=$rc): $out"
printf '%s' "$out" | grep -q "unknown argument '--dryrun'" \
  && ok "…and names the argument it did not understand" || bad "no usage diagnostic: $out"
printf '%s' "$out" | grep -q "gate(s) run" \
  && bad "a mistyped flag still ran the gates" || ok "…and no gate ran under it"
rm -rf "$GR"

say "15b. probe.sh — the OTHER half of the BSD/GNU split in the same printf, driven on both flavours"
# WHY THIS EXISTS. `stat` was fixed on 2026-08-30 and `date` — one line below it, in the same function,
# in the same printf — was not. BSD `date -r EPOCH` renders an epoch; GNU `date -r` takes a FILE. So on
# Linux both provenance timestamps rendered EMPTY ("built  · newest source  "), which reads as nothing
# to report rather than as a broken renderer. Verified under ubuntu:latest in Docker.
#
# A row that only has teeth on Linux is the "teeth only on macOS" defect wearing the other hat, so this
# drives BOTH flavours HERE by shimming `date` on PATH — the same trick for `stat`, whose failure path
# was unreachable because a `|| return 0` returned before the loud NOTE it exists for could print.
#
# Same environment caveat as 13b, and for the same reason: probe.sh's quiet_tree_check greps the WHOLE
# machine for a running build, so another agent's `swift build` refuses every probe below for a reason
# that is not this fixture. Measured live while writing this section. Skip, never a false FAIL.
if ! probe_wait_quiet; then
  note_skip "section 15b — a build or conformance run from another agent is still in flight after 10s, which makes probe.sh's machine-wide guard refuse before it reaches the provenance line these rows read. Re-run once the machine is quiet."
else
PB="$(mktemp -d)"; mkdir -p "$PB/root/candor-rust" "$PB/shim"
( cd "$PB/root/candor-rust" && git init -q && git branch -m main 2>/dev/null \
  && printf 'fn main(){}\n' > lib.rs && git add -A && git -c user.email=t@e -c user.name=t commit -qm init )
printf '#!/bin/bash\necho ran\n' > "$PB/root/candor-rust/binary"; chmod +x "$PB/root/candor-rust/binary"
touch -t 202601020000 "$PB/root/candor-rust/binary"; touch -t 202601010000 "$PB/root/candor-rust/lib.rs"

# CONTROL: this platform's own date, unshimmed. Both timestamps must render.
base="$(CANDOR_ROOT="$PB/root" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PB/root/candor-rust/binary" 2>&1)"
printf '%s' "$base" | grep -qE 'built [0-9]{2}:[0-9]{2}:[0-9]{2} · newest source [0-9]{2}:[0-9]{2}:[0-9]{2}' \
  && ok "provenance renders both timestamps on this platform's own date(1)" \
  || bad "a timestamp did not render on the native date(1): $(printf '%s' "$base" | grep built)"

# THE OTHER FLAVOUR. A GNU-shaped `date`: `-r` wants a FILE, `-d @EPOCH` renders an epoch.
cat > "$PB/shim/date" <<SHIM
#!/bin/bash
case "\$1" in
  -r) [ -e "\$2" ] || { echo "date: \$2: No such file or directory" >&2; exit 1; }
      exec /bin/date -r "\$(/usr/bin/stat -f %m "\$2")" "\$3" ;;
  -d) exec /bin/date -r "\${2#@}" "\$3" ;;
  *)  exec /bin/date "\$@" ;;
esac
SHIM
chmod +x "$PB/shim/date"
gnu="$(PATH="$PB/shim:$PATH" CANDOR_ROOT="$PB/root" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PB/root/candor-rust/binary" 2>&1)"
printf '%s' "$gnu" | grep -qE 'built [0-9]{2}:[0-9]{2}:[0-9]{2} · newest source [0-9]{2}:[0-9]{2}:[0-9]{2}' \
  && ok "…and on a GNU-shaped date(1), where \`date -r EPOCH\` is a file lookup that fails" \
  || bad "provenance timestamps went blank under a GNU-shaped date: $(printf '%s' "$gnu" | grep built)"
# CONTROL for the shim itself: it must actually be reached, or the row above proves nothing.
PATH="$PB/shim:$PATH" date -r 1000000000 '+%s' >/dev/null 2>&1 \
  && bad "the date shim was not on PATH (it still rendered an epoch via -r) — the row above is vacuous" \
  || ok "…with the shim proven to be the date(1) that ran (its -r rejects an epoch)"

# A stat that CANNOT read the mtime must print the loud NOTE, never return silently.
cat > "$PB/shim/stat" <<'SHIM'
#!/bin/bash
exit 1
SHIM
chmod +x "$PB/shim/stat"
noread="$(PATH="$PB/shim:$PATH" CANDOR_ROOT="$PB/root" bash "$UMBRELLA/bin/probe.sh" printf X -- "$PB/root/candor-rust/binary" 2>&1)"
printf '%s' "$noread" | grep -q "staleness NOT checked" \
  && ok "an unreadable mtime prints the loud NOTE (the \`|| return 0\` that skipped it is gone)" \
  || bad "a failing stat returned silently — a silent 'fresh' is how the Linux bug survived: $noread"
rm -rf "$PB"
fi

say "16. disk-guard.sh — a full disk fakes both a FAIL and an empty result, and says neither"
# Measured 2026-08-30: the volume hit zero mid-wave, four agents were running suites, and the
# harness could not write a command's own output file — so commands died BEFORE EXECUTING and
# returned nothing. The rows below hold the ONE distinction that matters: a FAIL produced after the
# crossing must not be reported as a finding, while a FAIL on a healthy disk still must be.
DG="$(mktemp -d)"
mkdir -p "$DG/root/candor-rust/.github/workflows" "$DG/root/candor-rust/ci"
cat > "$DG/root/candor-rust/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: one
        run: bash ci/a.sh
      - name: two
        run: bash ci/b.sh
YAML
printf '#!/bin/sh\nexit 0\n' > "$DG/root/candor-rust/ci/a.sh"
printf '#!/bin/sh\nexit 1\n' > "$DG/root/candor-rust/ci/b.sh"
chmod +x "$DG/root/candor-rust/ci/a.sh" "$DG/root/candor-rust/ci/b.sh"

# THE CONTROL COMES FIRST, deliberately. A guard that withholds every verdict would pass every row
# below it while having deleted the tool. This arm proves a real failure is still reported as one.
dg_ctl="$(CANDOR_ROOT="$DG/root" bash "$UMBRELLA/bin/gate-run.sh" candor-rust 2>&1)"; dg_ctl_rc=$?
[ "$dg_ctl_rc" -eq 1 ] && printf '%s' "$dg_ctl" | grep -q 'NOT GREEN' \
  && ok "healthy disk: a genuinely failing gate is still NOT GREEN (rc=1) — the control" \
  || bad "the over-charge control broke: a real FAIL no longer reports as one (rc=$dg_ctl_rc)"

# Breached BEFORE the first gate: refuse to start, and say it is not a verdict about the repo.
dg_pre="$(CANDOR_DISK_FAKE_FREE_MB=100 CANDOR_ROOT="$DG/root" bash "$UMBRELLA/bin/gate-run.sh" candor-rust 2>&1)"; dg_pre_rc=$?
[ "$dg_pre_rc" -eq 2 ] && printf '%s' "$dg_pre" | grep -q 'REFUSING TO START' \
  && ok "below the floor at the start: REFUSING TO START, rc=2" \
  || bad "a run started with no disk to trust it (rc=$dg_pre_rc)"
printf '%s' "$dg_pre" | grep -q 'not a verdict about' \
  && ok "…and names itself as not a verdict about the repo, so it cannot be read as a red repo" \
  || bad "the refusal did not distinguish itself from a failing repo"

# THE ROW THIS SECTION EXISTS FOR: healthy at the start, breached partway. A start-only check is
# blind to this, which is why the guard is called after every gate and latches.
dg_mid="$(CANDOR_DISK_FAKE_FREE_MB=9999,100 CANDOR_ROOT="$DG/root" bash "$UMBRELLA/bin/gate-run.sh" candor-rust 2>&1)"; dg_mid_rc=$?
[ "$dg_mid_rc" -eq 2 ] \
  && ok "crossed MID-RUN: rc=2, not the rc=1 the identical failing gate produces when healthy" \
  || bad "a mid-run crossing did not withhold the verdict (rc=$dg_mid_rc)"
printf '%s' "$dg_mid" | grep -q 'NOT findings until re-measured' \
  && ok "…and says the FAIL rows are NOT findings — the whole point, or ENOSPC gets filed as a bug" \
  || bad "a FAIL row under a crossed floor was left readable as a finding"
printf '%s' "$dg_mid" | grep -q 'first seen at: bash ci/a.sh' \
  && ok "…and names the gate it first crossed at, so the trustworthy prefix is identifiable" \
  || bad "the crossing point was not named; the table cannot be split into before and after"
printf '%s' "$dg_mid" | grep -qv 'NOT GREEN' \
  && ok "…and does NOT print NOT GREEN, which would attribute the failure to the repo" \
  || bad "a disk failure was attributed to the repo under test"

# THE INJECTION POINT MUST ITSELF WORK. The first version advanced its cursor in a variable inside a
# `$(...)` subshell, so the sequence never moved, every call returned the FIRST value, and the
# mid-run row above could not fire. It passed the start-breach row regardless. Pin the mechanism.
dg_seq="$(CANDOR_DISK_FAKE_FREE_MB=9999,9999,100 bash -c '. "$0"; for _ in 1 2 3 4; do disk_guard_min_mb .; done' "$UMBRELLA/bin/disk-guard.sh" | tr '\n' ' ')"
[ "$dg_seq" = "9999 9999 100 100 " ] \
  && ok "the fake-free sequence advances across subshell calls and holds its last value" \
  || bad "the injection point does not advance — every row above it is vacuous: got '$dg_seq'"

# A GATE WHOSE INTERPRETER IS ABSENT DID NOT FAIL, IT DID NOT RUN. Sibling of the `${{ }}` arm that
# already existed: that one exists because an unexpandable GitHub expression made candor-java
# "permanently red for a reason that is not a defect in candor-java". A missing binary is the same
# thing spelled differently, and only one of the two was handled. Measured 2026-08-30: CI provides
# `python`, macOS ships only `python3`, and three umbrella gates reported FAIL at rc=127 while all
# three of their assertions pass under python3.
mkdir -p "$DG/nb/candor-rust/.github/workflows" "$DG/nb/candor-rust/ci"
cat > "$DG/nb/candor-rust/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: absent interpreter
        run: definitely-not-a-real-binary-xyz --version
      - name: present
        run: bash ci/a.sh
YAML
printf '#!/bin/sh\nexit 0\n' > "$DG/nb/candor-rust/ci/a.sh"; chmod +x "$DG/nb/candor-rust/ci/a.sh"
dg_nb="$(CANDOR_ROOT="$DG/nb" bash "$UMBRELLA/bin/gate-run.sh" candor-rust 2>&1)"; dg_nb_rc=$?
printf '%s' "$dg_nb" | grep -q 'SKIP.*is not installed here' \
  && ok "an absent interpreter is SKIPPED and named, not reported as a failing gate" \
  || bad "a gate that could not run was reported as one that failed"
[ "$dg_nb_rc" -eq 2 ] \
  && ok "…and a skip still makes the verdict INCOMPLETE (rc=2) — unrunnable is still unrun" \
  || bad "an absent interpreter did not withhold the verdict (rc=$dg_nb_rc)"
printf '%s' "$dg_nb" | grep -q '1 gate(s) run' \
  && ok "…and the present gate beside it still ran" \
  || bad "the skip swallowed its neighbour"
# THE OVER-CHARGE CONTROL FOR THE SKIP: a path this repo owns must NOT be excused. `./gradlew` or
# `bin/foo.sh` going missing IS a defect, and a skip arm that swallowed it would delete the tool.
mkdir -p "$DG/own/candor-rust/.github/workflows"
cat > "$DG/own/candor-rust/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push]
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - name: our own missing script
        run: ./ci/does-not-exist.sh
YAML
dg_own="$(CANDOR_ROOT="$DG/own" bash "$UMBRELLA/bin/gate-run.sh" candor-rust 2>&1)"; dg_own_rc=$?
[ "$dg_own_rc" -eq 1 ] && printf '%s' "$dg_own" | grep -q 'FAIL' \
  && ok "a MISSING SCRIPT THIS REPO OWNS still FAILS — the skip does not excuse our own paths" \
  || bad "the not-installed skip swallowed a missing script the repo owns (rc=$dg_own_rc)"

# THE BSD/GNU mktemp SPLIT, driven on BOTH flavours. `mktemp -t NAME` appends randomness to a PREFIX
# on BSD and demands a TEMPLATE containing XXXXXX on GNU. gates.sh used the BSD form, so on every
# Linux runner its trigger classifier could not even be written: nothing was excluded-and-named and
# release-scripts went red on the workflow that gates.sh had just made visible. Green on macOS, dead
# on Linux — this is §15b's split (date -r, stat) one command over, so it gets the same treatment.
gm_shim="$DG/gnu"; mkdir -p "$gm_shim"
cat > "$gm_shim/mktemp" <<'SH'
#!/bin/sh
# GNU semantics: -t takes a TEMPLATE and refuses one with fewer than 6 trailing X's.
for a in "$@"; do
  case "$a" in
    -*) ;;
    *XXXXXX*) ;;
    *) echo "mktemp: too few X's in template '$a'" >&2; exit 1 ;;
  esac
done
exec /usr/bin/mktemp "$@"
SH
chmod +x "$gm_shim/mktemp"
# Prove the shim is the mktemp that ran, or the row below is vacuous on a box whose real mktemp is
# already lenient — the same non-vacuousness control §15b carries for its date shim.
PATH="$gm_shim:$PATH" mktemp -t no-x-here >/dev/null 2>&1 \
  && bad "the GNU mktemp shim did not reject a template without XXXXXX — the row below proves nothing" \
  || ok "the GNU mktemp shim is the mktemp that ran (it rejects a bare -t prefix)"
gm_out="$(PATH="$gm_shim:$PATH" CANDOR_ROOT="$DG/nb" bash "$UMBRELLA/bin/gates.sh" candor-rust 2>&1)"; gm_rc=$?
[ "$gm_rc" -eq 0 ] && ! printf '%s' "$gm_out" | grep -q "too few X's" \
  && ok "gates.sh runs under GNU mktemp semantics — the -t PREFIX form is gone" \
  || bad "gates.sh still dies under GNU mktemp: $(printf '%s' "$gm_out" | head -1)"
printf '%s' "$gm_out" | grep -q 'bash ci/a.sh' \
  && ok "…and still prints the gate list, so the classifier actually ran on the GNU flavour" \
  || bad "gates.sh survived GNU mktemp but produced no gate list — dead in a quieter way"

# Fail closed when the measurement itself is unavailable: an unreadable df is not a healthy disk.
dg_shim="$DG/shim"; mkdir -p "$dg_shim"
printf '#!/bin/sh\nexit 1\n' > "$dg_shim/df"; chmod +x "$dg_shim/df"
dg_nodf_rc=0
PATH="$dg_shim:$PATH" bash "$UMBRELLA/bin/disk-guard.sh" --quiet || dg_nodf_rc=$?
[ "$dg_nodf_rc" -eq 2 ] \
  && ok "a df that FAILS is treated as below the floor — 'I could not tell' is not 'there is room'" \
  || bad "an unreadable filesystem reported healthy (rc=$dg_nodf_rc)"
rm -rf "$DG"

printf '\n'
if [ "$fail" -gt 0 ]; then printf '\033[31mrelease-test: %d FAILED, %d passed\033[0m\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mrelease-test: OK — %d assertions\033[0m%s\n' "$pass" \
  "$( [ "$skipped" -gt 0 ] && printf ' (%d SKIPPED — NOT a pass; read the • lines above for why)' "$skipped" )"
