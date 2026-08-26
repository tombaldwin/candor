#!/usr/bin/env bash
# spec-bump.sh — REHEARSE a spec-floor bump before committing one.
#
#   bash bin/spec-bump.sh --check          # are all seven declarations already consistent?
#   bash bin/spec-bump.sh 0.28             # bump every declaration AND every doc/packaging literal,
#                                          # name the pins it must not touch, then verify the family
#
# WHY THIS EXISTS, stated as it happened.
#
# `release-stage.sh` performs the RELEASE bump (build versions, crate deps, changelogs) and deliberately
# does NOT touch the spec declarations, because a floor bump is a contract decision on a different axis.
# So the contract bump had no tooling at all: on 2026-08-04 the ⟨0.27⟩ bump was done by hand and turned
# SIX repos' CI red on version-coupled assertions — four in candor-agents' test.py, three in candor-java's
# smoke.sh, several in candor-rust's cli tests plus its integration script and its own doc-drift gate,
# README/AGENTS/package.json in candor-ts, and doc strings in three more. Every one was findable locally in
# minutes. None was found until CI went red, because nothing ran the family's suites against the bump.
#
# WHAT IT DOES
#   1.  Bumps the SEVEN declaration sites (the constants each engine emits as `candor.spec`, plus SPEC.md).
#   1b. Bumps the DOC + PACKAGING literals — READMEs, AGENTS docs, `package.json`, `pyproject.toml`,
#       jbang's catalog description, SPEC.md's own envelope fences — in EVERY spelling.
#   1c. NAMES the deliberate literal canaries, which it must not touch, as a hand-edit list.
#   2.  Runs every engine's own suite, the four-way conformance run, and the doc-drift gates.
#   3.  LISTS every remaining mention of the old version for a human to triage.
#
# WHY STEP 1b EXISTS, measured on the ⟨0.32⟩ bump. Step 1 rewrote seven declarations and the version was
# ALSO written by hand in twenty-odd doc and packaging sites, in three spellings — `spec-0.31`,
# `"spec": "0.31"` and `(spec 0.31)` in prose. Every hand pass caught the two that LOOK LIKE DECLARATIONS
# and missed the one that LOOKS LIKE PROSE: candor-swift's embedded doc drifted by one character,
# candor-rust's and candor-java's README JSON examples survived a full sweep, and SPEC.md itself carried
# three fences saying `"spec": "0.31"` under a `**Version 0.32**` header. The gates that DERIVE from an
# engine's own constant never failed. Only literals did — so the literals are now rewritten by machine,
# and what cannot be is NAMED (1c) rather than discovered one CI round at a time.
#
# WHY STEP 1b IS AN ALLOWLIST AND STEP 3 IS STILL A LIST. A blanket find-and-replace would have caused
# harm on 2026-08-04: candor-rust's `crates/candor-scan/src/tests.rs` builds fixture reports declaring the
# PREVIOUS spec version as INPUTS, proving an older report still loads. Replacing those would have
# silently deleted a backward-compatibility test. So 1b rewrites a NAMED SET of documents whose every
# spec claim is a claim about the CURRENT contract, and everything outside that set is reported, never
# swept. An allowlist under-reaches by construction, and that is the safe direction here: a doc this
# script forgets is a doc the engines' own derived gates redden on, and it appears in step 3's list.
#
# It does not commit, tag or push. It leaves the tree bumped on failure ON PURPOSE — you fix forward from
# a rehearsal, and reverting would throw away the diff you need to read.
set -uo pipefail
ROOT="${CANDOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
# COUNTS, like release-preflight.sh's and release-verify.sh's do. This script's did not, and BOTH of its
# false greens followed from that one line: a moved declaration site printed ✘ and the run still exited 0
# saying "the family is GREEN", with one engine still emitting the OLD contract — the four-way split this
# script exists to prevent, reported as its absence.
fails=0
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; fails=$((fails+1)); }
note() { printf '  \033[33m•\033[0m %s\n' "$*"; }

# label | repo-relative file | sed pattern capturing the version
DECLS=(
  "rust|candor-rust/crates/candor-report/src/lib.rs|pub const SPEC_VERSION: &str = \"%s\";"
  "java|candor-java/src/main/java/io/poly/candor/Candor.java|    static final String SPEC_VERSION = \"%s\";"
  "ts-scan|candor-ts/scan.mjs|const SPEC_VERSION = \"%s\";"
  "ts-query|candor-ts/query.mjs|const SPEC_VERSION = \"%s\";"
  "swift|candor-swift/Sources/candor-swift/main.swift|let specVersion = \"%s\""
  "agents|candor-agents/candor_agents/scan.py|SPEC = \"%s\""
)

# ── THE DOC + PACKAGING LITERALS (step 1b) ──────────────────────────────────────────────────────────
# Every file here is a document whose spec claims are claims about the CURRENT contract, so every claim
# in it moves with the floor. Missing from the list ON PURPOSE:
#   · candor-spec/SPEC.md — handled separately below, JSON-ONLY. That file is dense with TRUE statements
#     about past rungs ("⟨0.27⟩", "measured at spec 0.28", clause histories) and a prose sweep there
#     would be a false-positive machine. Inside a fence, `"spec": "X.Y"` is always an envelope example,
#     i.e. always a current-contract claim, so restricting to it loses nothing.
#   · every test fixture, every CHANGELOG, every night log. Those are dated records and INPUTS; see the
#     header's note on the backward-compatibility fixtures a blanket sweep would have deleted.
# The three MIRROR copies (java's jar resource, rust's two crate copies) are listed because they are
# byte-identical siblings pinned by their own repos' gates — rewriting the root and forgetting the
# mirror turns one hand-edit into a red suite, so the same rewrite is applied to both and the equality
# is re-checked afterwards. candor-swift's `AgentsDoc.swift` embeds AGENTS.md inside a raw string, so it
# takes the identical rewrite for the identical reason.
DOCS=(
  candor-spec/README.md
  candor-spec/AGENTS.md
  candor-rust/README.md
  candor-rust/AGENTS.md
  candor-rust/crates/candor-query/AGENTS.md
  candor-rust/crates/candor-scan/AGENTS.md
  candor-java/README.md
  candor-java/AGENTS.md
  candor-java/src/main/resources/AGENTS.md
  candor-java/jbang-catalog.json
  candor-ts/README.md
  candor-ts/AGENTS.md
  candor-ts/package.json
  candor-swift/README.md
  candor-swift/AGENTS.md
  candor-swift/SPEC-EXTENSION-privacy.md
  candor-swift/Sources/candor-swift/AgentsDoc.swift
  candor-agents/README.md
  candor-agents/AGENTS.md
  candor-agents/pyproject.toml
  candor-agents/candor_agents/__init__.py
)

# MIRRORS — `a|b` pairs that must stay byte-identical, re-checked after 1b rewrites them. Their own
# repos' suites assert this too; checking it here means a forgotten sibling is reported by the step that
# caused it, in the same second, rather than by a red engine suite ten minutes later.
MIRRORS=(
  "candor-java/AGENTS.md|candor-java/src/main/resources/AGENTS.md"
  "candor-rust/AGENTS.md|candor-rust/crates/candor-query/AGENTS.md"
  "candor-rust/AGENTS.md|candor-rust/crates/candor-scan/AGENTS.md"
)

# ── THE DELIBERATE CANARIES (step 1c) ───────────────────────────────────────────────────────────────
# label | repo-relative file | the literal, with @V@ standing in for the version.
#
# These three assertions are literals ON PURPOSE and each carries a comment saying so: everything else in
# their repos DERIVES the spec from the engine's own constant, which is right for checking AGREEMENT and
# useless for checking the VALUE. With only derived assertions there is no in-tree pin at all — setting
# candor-swift's `specVersion = "0.29"` once passed every test and both drift gates. They exist to make a
# human acknowledge a floor bump, so this script must NOT rewrite them.
#
# It must still NAME them. Before this list they fired serially through CI, one round trip each, which is
# the round-trip cost the rest of this script exists to remove — the teeth were never the problem.
#
# `@V@` rather than printf's `%s`: these patterns contain escaped quotes, and bash's printf interprets
# backslash escapes in its FORMAT string, so a `\"` in a template is silently a different string from the
# one in the file. Parameter expansion does not interpret anything.
CANARIES=(
  "rust floor pin|candor-rust/crates/candor-report/src/lib.rs|assert_eq!(SPEC_VERSION, \"@V@\")"
  "rust envelope|candor-rust/crates/candor-report/src/lib.rs|\\\"spec\\\":\\\"@V@\\\""
  "swift floor pin|candor-swift/Tests/CandorCoreTests/AgentsDocDriftTests.swift|declaredSpec(), \"@V@\""
)

current_of() {  # echo the version a declaration file currently carries
  grep -oE 'SPEC_VERSION[^"]*"[0-9]+\.[0-9]+"|specVersion = "[0-9]+\.[0-9]+"|^SPEC = "[0-9]+\.[0-9]+"' "$1" 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# ── --check: are the seven already consistent? ──────────────────────────────────────────────────────
if [ "${1:-}" = "--check" ]; then
  say "declaration consistency"
  seen=""; rc=0
  for d in "${DECLS[@]}"; do
    IFS='|' read -r label rel _ <<<"$d"
    v="$(current_of "$ROOT/$rel")"
    [ -n "$v" ] || { bad "$label: no declaration found in $rel"; rc=1; continue; }
    note "$(printf '%-9s %s' "$label" "$v")"
    case " $seen " in *" $v "*) ;; *) seen="$seen $v";; esac
  done
  sv="$(grep -oE '^\*\*Version [0-9]+\.[0-9]+' "$ROOT/candor-spec/SPEC.md" | grep -oE '[0-9]+\.[0-9]+')"
  if [ -z "$sv" ]; then
    # NOT foldable into the agreement set. SPEC.md is the contract the other six declare conformance TO,
    # and an unreadable version there is the least safe thing to call agreement — it printed `?` on the
    # line directly above the verdict, and the verdict said "every declaration agrees" anyway.
    bad "SPEC.md: no '**Version X.Y**' headline — the contract document's own version is unreadable"
  else
    note "$(printf '%-9s %s' "SPEC.md" "$sv")"
    case " $seen " in *" $sv "*) ;; *) seen="$seen $sv";; esac
  fi
  n=$(echo $seen | wc -w | tr -d ' ')
  if [ "$n" = 1 ] && [ "$fails" = 0 ]; then ok "every declaration agrees on ${seen# }"; elif [ "$n" != 1 ]; then
    bad "declarations DISAGREE (${seen# }) — an engine emitting a spec version the others do not is a
       four-way contract split, not a version-number detail"; fi
  [ "$fails" = 0 ] || rc=1
  exit $rc
fi

NEW="${1:?usage: spec-bump.sh <new-spec e.g. 0.28> | --check}"
case "$NEW" in [0-9]*.[0-9]*) ;; *) echo "spec-bump: '$NEW' is not an X.Y spec version" >&2; exit 2;; esac

# Refuse a dirty tree: this rewrites seven files across seven repos and an interrupted run is unreviewable.
say "0. preconditions"
dirty=0
for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
  [ -d "$ROOT/$r" ] || continue
  [ -z "$(git -C "$ROOT/$r" status --porcelain)" ] || { bad "$r has uncommitted changes"; dirty=1; }
done
[ "$dirty" = 0 ] || { echo; echo "spec-bump: commit or stash first — a rehearsal must start from a known tree."; exit 1; }
OLD="$(current_of "$ROOT/candor-rust/crates/candor-report/src/lib.rs")"
[ -n "$OLD" ] || { bad "cannot read the current spec version"; exit 2; }
ok "clean trees; bumping $OLD → $NEW"

# ── 1. the declarations ─────────────────────────────────────────────────────────────────────────────
say "1. spec declarations"
for d in "${DECLS[@]}"; do
  IFS='|' read -r label rel tmpl <<<"$d"
  f="$ROOT/$rel"
  [ -f "$f" ] || { bad "$label: missing $rel"; continue; }
  # shellcheck disable=SC2059
  from="$(printf "$tmpl" "$OLD")"; to="$(printf "$tmpl" "$NEW")"
  if grep -qF "$from" "$f"; then
    python3 - "$f" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
assert s.count(a) == 1, f"{p}: expected exactly one declaration, found {s.count(a)}"
open(p, "w").write(s.replace(a, b, 1))
PY
    ok "$(printf '%-9s → %s   (%s)' "$label" "$NEW" "$rel")"
  else
    bad "$(printf '%-9s declaration not found — the site moved; update DECLS in this script   (%s)' "$label" "$rel")"
  fi
done
python3 - "$ROOT/candor-spec/SPEC.md" "$OLD" "$NEW" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
a = f"**Version {old}** — all code engines declare `{old}`"
b = f"**Version {new}** — all code engines declare `{new}`"
if a in s:
    open(p, "w").write(s.replace(a, b, 1)); print("  \033[32m✔\033[0m SPEC.md   → " + new)
else:
    print("  \033[31m✘\033[0m SPEC.md headline version not found in the expected form")
    sys.exit(3)
PY

[ "${PIPESTATUS[0]:-0}" = 3 ] && fails=$((fails+1))   # the SPEC.md bump above failed; count it

# ── 1b. the doc + packaging literals, in EVERY spelling ─────────────────────────────────────────────
say "1b. doc + packaging literals"
docs_abs=()
for rel in "${DOCS[@]}"; do
  if [ -f "$ROOT/$rel" ]; then docs_abs+=("$ROOT/$rel")
  else bad "$(printf 'doc site missing — it moved or was renamed; update DOCS in this script   (%s)' "$rel")"; fi
done
if [ "${#docs_abs[@]}" -gt 0 ]; then
  CB_ROOT="$ROOT" python3 - "$OLD" "$NEW" "${docs_abs[@]}" <<'PY'
import os, re, sys
old, new, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
root = os.environ["CB_ROOT"].rstrip("/") + "/"

# THE FAMILY'S SHARED CLAIM GRAMMAR — the same one candor-rust's `spec_claims`, candor-java's
# `spec_claims.py`, candor-ts's `claim`, candor-swift's `AgentsDocDriftTests` and candor-agents'
# `_claim` carry: `spec` + one to EIGHT of [-: "*)\]] + <digits>.<digits>.
#
# ONE GRAMMAR FOR THE REWRITER AND THE CHECKERS, deliberately. If the bump could rewrite a spelling the
# gates cannot see, a stale claim would ship silently; if the gates could see one the bump cannot
# rewrite, the gate's remedy would be a hand edit — which is this whole item. Eight rather than four
# because SPEC.md's own aligned `"spec":    "0.32"` needs six separators (spec 0.32, informative);
# `)` and `]` because candor-swift's README says `[candor-spec](…) 0.32`. Both were live in shipped
# documents at ⟨0.32⟩ and every gate in the family read clean over them.
claim = re.compile(r'spec[-: "*)\]]{1,8}(\d+\.\d+)')

for p in paths:
    s = open(p, encoding="utf-8").read()
    out, last, moved, kept = [], 0, 0, []
    for m in claim.finditer(s):
        # The family's historical marker: a note naming the rung a feature arrived at is a true
        # statement about the PAST and must not move with the floor. Keying on the marker rather than
        # on a list of tolerated old versions means a new annotation never needs this script edited.
        if s[m.end():m.end() + 16].startswith(", informative)"):
            kept.append(m.group(1)); continue
        if m.group(1) != old:
            # A claim at neither the old floor nor an exempt marker. NOT rewritten and NOT silent: it
            # is either a stale claim an earlier bump missed or a typo, and both want a human.
            kept.append(m.group(1) + "?"); continue
        out.append(s[last:m.start(1)]); out.append(new); last = m.end(1); moved += 1
    out.append(s[last:])
    if moved:
        open(p, "w", encoding="utf-8").write("".join(out))
    rel = p[len(root):] if p.startswith(root) else p
    unknown = [k for k in kept if k.endswith("?")]
    tail = ""
    if unknown:
        tail = "   \033[33m← %s NOT at %s: %s\033[0m" % (
            len(unknown), old, ", ".join(sorted(set(k[:-1] for k in unknown))))
    mark, colour = ("✔", "32") if moved else ("•", "33")
    print("  \033[%sm%s\033[0m %-52s %s claim(s) → %s%s"
          % (colour, mark, rel, moved, new, tail))
PY
fi

# SPEC.md's own envelope fences — JSON-ONLY, for the reason `check_agents_drift.py` states at length:
# this document's PROSE is full of true statements about past rungs, and inside a fence `"spec": "X.Y"`
# is always an envelope example, i.e. always a claim about the current contract. Three of them were left
# at the prior floor under a bumped header at ⟨0.32⟩, and the alignment padding on one had already
# defeated a hand sweep for the exact string at 0.30.
CB_ROOT="$ROOT" python3 - "$ROOT/candor-spec/SPEC.md" "$OLD" "$NEW" <<'PY'
import re, sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
json_spec = re.compile(r'("spec"\s*:\s*")(\d+\.\d+)(")')
moved = 0
lines = s.splitlines(keepends=True)
for i, line in enumerate(lines):
    if ", informative)" in line:      # per-LINE, because that is where SPEC.md puts the marker
        continue
    def sub(m):
        global moved
        if m.group(2) != old:
            return m.group(0)
        moved += 1
        return m.group(1) + new + m.group(3)
    lines[i] = json_spec.sub(sub, line)
if moved:
    open(p, "w", encoding="utf-8").write("".join(lines))
mark, colour = ("✔", "32") if moved else ("•", "33")
print("  \033[%sm%s\033[0m %-52s %s envelope fence(s) → %s"
      % (colour, mark, "candor-spec/SPEC.md (JSON fences only)", moved, new))
PY

# THE MIRRORS MUST STILL MATCH. A doc rewrite is exactly what breaks byte-equality between a canonical
# document and its shipped copy — one forgotten entry in DOCS above and the copies diverge — so the
# invariant is re-checked by the step that just risked it, not ten minutes later by a red engine suite.
for m in "${MIRRORS[@]}"; do
  IFS='|' read -r a b <<<"$m"
  [ -f "$ROOT/$a" ] && [ -f "$ROOT/$b" ] || continue
  if cmp -s "$ROOT/$a" "$ROOT/$b"; then
    note "mirror OK: $b matches $a"
  else
    bad "mirror BROKEN: $b no longer matches $a — the rewrite reached one copy and not the other"
  fi
done

# ── 1c. the DELIBERATE canaries — named, never rewritten ────────────────────────────────────────────
say "1c. deliberate literal pins — EDIT THESE BY HAND, in this pass"
echo "  These are literals ON PURPOSE: everything else derives the spec from an engine's own constant,"
echo "  which checks AGREEMENT and not the VALUE. They are the only in-tree pins that notice the"
echo "  constant moved, so this script names them and refuses to edit them. Keep the teeth."
echo
canary_todo=0
for c in "${CANARIES[@]}"; do
  IFS='|' read -r label rel pat <<<"$c"
  f="$ROOT/$rel"
  [ -f "$f" ] || { bad "$(printf 'canary %-14s missing file %s' "$label" "$rel")"; continue; }
  at_old="${pat//@V@/$OLD}"; at_new="${pat//@V@/$NEW}"
  if grep -qF "$at_old" "$f"; then
    canary_todo=$((canary_todo+1))
    printf '  \033[33m✎\033[0m %-14s %s\n      %s\n' "$label" "$rel" "$at_old  →  $at_new"
  elif grep -qF "$at_new" "$f"; then
    note "$(printf '%-14s already at %s   (%s)' "$label" "$NEW" "$rel")"
  else
    # NOT a silent skip. A canary that cannot be located is not pinning anything, and the failure mode
    # of a missing pin is indistinguishable from a satisfied one — which is what made the pin necessary.
    bad "$(printf 'canary %-14s not found at %s OR %s — it moved or was deleted; a pin nobody can locate is not pinning the floor   (%s)' "$label" "$OLD" "$NEW" "$rel")"
  fi
done
[ "$canary_todo" = 0 ] && ok "no canary edits outstanding"

# ── 3. what is LEFT — reported, never swept ─────────────────────────────────────────────────────────
# A FUNCTION, so `--decls-only` can run it too. It was written inline BELOW the suites, and the harness
# drives every spec-bump row through `--decls-only` — which exits at step 1. So this step, and the
# liveness probe that exists because this step once printed green over a scan that never ran, were
# unreachable from the test suite: the guard against a silent no-op was itself untested. It needs no
# suite (it is grep over the bumped tree), so nothing was buying that coupling.
# Sets `scan_dead=1` — NOT `rc` — if the scan cannot prove itself live. `rc` is step 2's SUITE
# accumulator on the main path, and the first version of this hoist reused it as the probe flag: any
# failed engine suite then made the early return below fire and step 3's triage list vanished, under its
# own "TRIAGE THESE BY HAND" header, with nothing beneath it. A red rehearsal is precisely when that list
# is wanted, since a red rehearsal is when you are fixing forward. The harness could not see it — every
# row drives `--decls-only`, which sets `rc=0` immediately before the call, so `rc` is always fresh there
# and the bug lives only on the path the tests cannot reach. Same shape as the defect the hoist fixed.
scan_dead=0
remaining_mentions() {
  say "3. remaining mentions of $OLD — TRIAGE THESE BY HAND"
  echo "  A blanket replace would be wrong: on the 0.27 bump, candor-rust's tests.rs built FIXTURE reports"
  echo "  at the old version as INPUTS (proving an older report still loads). Sweeping them would have"
  echo "  silently deleted a backward-compatibility test. Read each one."
  echo
  # KNOWN CONSEQUENCE, stated up front because it fails the conformance run and looks alarming. SPEC.md's
  # Contents carries "**Version X.Y** — all code engines declare `X.Y`", so a floor bump REWORDS a normative
  # statement and its `must-ledger.json` hash moves with it. The run then reports one unclassified statement
  # plus one orphaned entry — a correct catch, not a defect. Re-anchor by replacing the orphan's entry with
  # the JSON line the checker prints (keeping its `status`), then re-run `conformance/must_ledger.py`.
  echo "  NOTE: the floor bump rewords SPEC.md's Contents version line, so conformance's MUST LEDGER will"
  echo "  report it unclassified + the old entry orphaned. Re-anchor must-ledger.json with the line the"
  echo "  checker prints — expected on every bump, not a defect."
  # ONE definition, so the liveness probe below can run the IDENTICAL pipeline rather than a lookalike.
  scan_for_old() {
    grep -rn "spec.\{0,3\}$OLD\|\"$OLD\"" "$1" \
      --include='*.rs' --include='*.java' --include='*.mjs' --include='*.swift' --include='*.py' \
      --include='*.sh' --include='*.md' --include='*.json' 2>/dev/null \
      | grep -viE "/target/|/\.build/|node_modules|/build/|CHANGELOG|⟨${OLD}⟩|${OLD}\.[0-9]" | head -12
  }
  # PROVE THE SCAN CAN RUN AT ALL — FIRST, by running THE SAME PIPELINE over a KNOWN-POSITIVE fixture.
  #
  # `⟨$OLD⟩` unbraced made bash read the multi-byte `⟩` as part of the variable name, so under `set -u`
  # every iteration died, `hits` came back empty, and this step printed a green "no remaining mentions"
  # over a scan that never executed. A step whose failure mode is indistinguishable from its success has
  # to assert its own liveness.
  #
  # THE FIRST VERSION OF THIS GUARD WAS ITSELF VACUOUS — the same defect, one layer up. It asked whether
  # `$OLD` still appeared in candor-spec's CHANGELOG, which (a) stays TRUE when the loop dies, so it never
  # fired in the failure mode it was written for, (b) targets a file the scan's own filter EXCLUDES, so it
  # exercised a path the scan cannot take, and (c) goes FALSE when bumping a floor whose predecessor was
  # never released, failing a clean tree. Calling `scan_for_old` on a fixture that must match removes all
  # three: it is the real pipeline, on an input whose answer is known.
  probe_dir="$(mktemp -d)"; printf 'spec %s\n' "$OLD" > "$probe_dir/probe.md"
  if [ -z "$(scan_for_old "$probe_dir")" ]; then
    # NOT via `bad`: that increments `fails`, which the line below reports as "declaration site(s) NOT
    # bumped — the family is SPLIT". A broken scan is not a split family, and saying so sends the reader
    # to seven declaration files that are all correct.
    scan_dead=1
    printf '  \033[31m✘\033[0m %s\n' "the remaining-mentions scan cannot match a line that is definitionally a match — the SCAN is broken, not the tree — NOTHING was scanned, so no verdict follows"
  fi
  rm -rf "$probe_dir"
  # RETURN, so the loop below never runs and its green line is never printed. It used to run
  # anyway: a dead scan found nothing, printed a green "no remaining mentions", and the ✘ landed
  # BELOW it — the operator got the reassurance and the refutation in that order, from one step.
  # Caught by the harness row that asserts the green line is ABSENT, not just that the ✘ is present.
  [ "$scan_dead" = 0 ] || return 0
  found=0
  for r in candor-spec candor-rust candor-java candor-ts candor-swift candor-agents candor; do
    [ -d "$ROOT/$r" ] || continue
    hits="$(scan_for_old "$ROOT/$r")"
    [ -n "$hits" ] && { printf '  \033[1m%s\033[0m\n' "$r"; echo "$hits" | sed "s|$ROOT/||" | sed 's/^/    /' | cut -c1-118; found=1; }
  done
  [ "$found" = 0 ] && ok "no remaining mentions"
}

# `--decls-only` exists so the harness can exercise the bump MECHANICS against a fixture tree without
# running seven real suites. It is not a shortcut for a real bump: skipping step 2 is skipping the entire
# reason this script exists.
if [ "${2:-}" = "--decls-only" ]; then
  echo
  # It exits EARLY, so it must do the step-1 accounting itself — otherwise the shortcut is the one path
  # where a skipped declaration site still reports success.
  [ "$fails" = 0 ] || { bad "$fails site(s) NOT bumped — the family is SPLIT"; exit 1; }
  # Step 3 DOES run here — it is grep, not a suite — so the harness can reach it and its liveness probe.
  rc=0; remaining_mentions
  [ "$scan_dead" = 0 ] || exit 1
  echo
  ok "declarations bumped + mentions triaged (--decls-only: the SUITES were skipped — not a rehearsal)"
  exit 0
fi

# ── 2. the family's own suites ──────────────────────────────────────────────────────────────────────
say "2. every engine's suite (this is the step that was missing)"
rc=0
run_suite() { # $1 label ; $2 dir ; shift 2 = command
  local label="$1" dir="$2"; shift 2
  printf '  … %-8s ' "$label"
  if ( cd "$dir" && "$@" >/tmp/spec-bump-$label.log 2>&1 ); then printf '\033[32mPASS\033[0m\n'
  else printf '\033[31mFAIL\033[0m  (see /tmp/spec-bump-%s.log)\n' "$label"; rc=1; fi
}
[ -d "$ROOT/candor-rust" ]   && run_suite rust   "$ROOT/candor-rust"   cargo test --workspace
[ -d "$ROOT/candor-rust" ]   && run_suite rustint "$ROOT/candor-rust"  bash tests/integration.sh
[ -d "$ROOT/candor-java" ]   && run_suite java   "$ROOT/candor-java"   ./gradlew -q test
[ -d "$ROOT/candor-java" ]   && run_suite jsmoke "$ROOT/candor-java"   bash test/smoke.sh
[ -d "$ROOT/candor-ts" ]     && run_suite ts     "$ROOT/candor-ts"     npm test
[ -d "$ROOT/candor-swift" ]  && run_suite swift  "$ROOT/candor-swift"  swift test
[ -d "$ROOT/candor-swift" ]  && run_suite ssmoke "$ROOT/candor-swift"  bash smoke.sh
[ -d "$ROOT/candor-agents" ] && run_suite agents "$ROOT/candor-agents" python3 test.py
[ -f "$ROOT/candor-spec/scripts/check_agents_drift.py" ] \
  && run_suite drift "$ROOT/candor-spec" python3 scripts/check_agents_drift.py
[ -f "$ROOT/candor-spec/conformance/run.sh" ] \
  && run_suite conform "$ROOT/candor-spec/conformance" ./run.sh


remaining_mentions
echo
# A skipped DECLARATION is not a suite failure, so it would not otherwise reach this line — which is
# exactly how "GREEN at 0.28" got printed over an engine still emitting 0.27.
[ "$fails" = 0 ] || { rc=1; bad "$fails site(s) NOT bumped — the family is SPLIT, whatever the suites say"; echo; }
# THE CANARIES ARE THE EXPECTED RED, so say so where the operator is standing when the suites go red.
# Without this line the run ends in "suites failed", the operator reads a red engine suite, and the two
# assertions that were SUPPOSED to fail look like defects rather than the acknowledgement they are.
[ "$canary_todo" = 0 ] || printf '  \033[33m✎\033[0m %s\n' \
  "$canary_todo deliberate pin(s) still at $OLD — step 1c lists them; the candor-report and \
candor-swift suites are RED until you edit them, and that is the pin working"
# NAME THE RIGHT ONE. Three different failures used to arrive under the single label "suites failed": a
# red engine suite, a moved declaration site, and a mentions scan that could not run. This file already
# carries a comment saying why a broken scan must not be announced as a split family; the summary was
# doing exactly that, one line further down. The ✘ lines above were right — the line an operator ACTS on
# was not.
why=""
[ "$rc" = 0 ]        || why="suites failed"
[ "$fails" = 0 ]     || why="${why:+$why + }$fails declaration/doc site(s) not bumped"
[ "$scan_dead" = 0 ] || { why="${why:+$why + }the remaining-mentions scan is broken"; rc=1; }
if [ "$rc" = 0 ]; then
  printf '\033[32mspec-bump: the family is GREEN at %s.\033[0m Review the diff, triage any list above, then commit.\n' "$NEW"
else
  printf '\033[31mspec-bump: %s — the tree is left BUMPED on purpose so you can fix forward.\033[0m\n' "$why"
  echo "Prefer DERIVING a version-coupled assertion from the engine's own constant over re-editing a literal:"
  echo "  that class was closed as \"a one-off\" once and cost an edit in every repo the next rung."
fi
exit $rc
