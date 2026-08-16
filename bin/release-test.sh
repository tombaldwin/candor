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
cp "$UMBRELLA/bin/release-stage.sh" "$UMBRELLA/bin/_stage_changelogs.py" "$FIX/candor/bin/"
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
FOLD="$FIX/candor-swift/CHANGELOG.md"
printf '# Changelog\n\n## Unreleased\n\n- **stranded work** that landed after the heading was drafted.\n\n## [0.27.0] — 2026-08-07\n\n- the entry that was already written.\n' > "$FOLD"
# `-c user.email/-c user.name`, like every other commit in this file: a CI runner has NO git identity,
# so a bare `git commit` FAILS there and silently leaves the tree dirty. Green locally, red in CI — the
# exact class this project keeps a checklist for, and I reintroduced it twice in one commit.
(cd "$FIX/candor-swift" && git add -A && git -c user.email=t@e -c user.name=t commit -qm "fold fixture" 2>/dev/null)
ROOT="$FIX" VER=0.27.0 DATE=2026-08-08 python3 "$FIX/candor/bin/_stage_changelogs.py" >/dev/null 2>&1
grep -qE '^## Unreleased$' "$FOLD" && [ -z "$(awk '/^## Unreleased$/{f=1;next} /^## /{f=0} f && NF' "$FOLD")" ] \
  && ok "Unreleased is left EMPTY, so preflight [9] can go green" \
  || { bad "work is still stranded under Unreleased — the deadlock"; sed -n '1,12p' "$FOLD"; }
awk '/^## \[0\.27\.0\]/{f=1;next} /^## /{f=0} f' "$FOLD" | grep -q "stranded work" \
  && ok "the stranded entry was folded INTO the version section" || bad "the entry did not land in [0.27.0]"
awk '/^## \[0\.27\.0\]/{f=1;next} /^## /{f=0} f' "$FOLD" | grep -q "already written" \
  && ok "…and the entry that was already there survived" || bad "folding overwrote the existing entry"
# candor-spec was not in the stager's loop at all while preflight [9] checked it — the repo the rung is
# AUTHORED in was the one repo staging could not stage. Its headings are floor-shaped, not `## [x.y.z]`.
mkdir -p "$FIX/candor-spec"
printf '# Changelog\n\n## Unreleased\n\n- **spec work** that landed after the floor heading.\n\n## 0.27 — current floor (a thing)\n\n- the floor entry.\n' > "$FIX/candor-spec/CHANGELOG.md"
ROOT="$FIX" VER=0.27.0 DATE=2026-08-08 python3 "$FIX/candor/bin/_stage_changelogs.py" >/dev/null 2>&1
awk '/^## 0\.27 —/{f=1;next} /^## /{f=0} f' "$FIX/candor-spec/CHANGELOG.md" | grep -q "spec work" \
  && ok "candor-spec folds too, into its FLOOR-shaped heading" || bad "candor-spec still unstaged"

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
grep -q 'PINNED=' "$REALREL" && ok "the ENGINE_PIN guard exists in release.sh" || bad "no ENGINE_PIN guard"
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

if STEP7=$(extract_die "$REALREL" '^[[:space:]]*die "ENGINE_PIN is'); then
  ok "step 7's remedy is bounded by its own die string (not by a sentence)"
  printf '%s\n' "$STEP7" | grep -q 'MUST ALSO TOUCH' \
    && ok "…and still carries the pin-bump-touches-the-CHANGELOG warning" \
    || bad "step 7's remedy no longer warns that the pin-bump commit must touch the CHANGELOG"
  printf '%s\n' "$STEP7" | grep -q 'bin/candor' \
    && ok "step 7's remedy names bin/candor in its SOURCE text" \
    || bad "step 7's remedy lost bin/candor from its source text"
  # The block now begins at `die "ENGINE_PIN is ${PINNED:-unset}, not $VER`, which release.sh has bound
  # and this harness does not — under `set -u` the heredoc died and RENDERED came back EMPTY, which the
  # case below reports as "backticks are executing". A right verdict for the wrong reason is still a
  # wrong instrument, so: bind them, and say so separately when nothing rendered at all.
  # shellcheck disable=SC2034  # both ARE read — by the heredoc that `eval` expands on the next line
  RENDERED=$(cd /tmp && VER="0.0.0" PINNED="0.0.0"; eval "cat <<CANDOR_EOF
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

printf '\n'
if [ "$fail" -gt 0 ]; then printf '\033[31mrelease-test: %d FAILED, %d passed\033[0m\n' "$fail" "$pass"; exit 1; fi
printf '\033[32mrelease-test: OK — %d assertions\033[0m%s\n' "$pass" \
  "$( [ "$skipped" -gt 0 ] && printf ' (%d SKIPPED — a missing tool, not a pass)' "$skipped" )"
