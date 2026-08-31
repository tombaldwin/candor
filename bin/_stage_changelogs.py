#!/usr/bin/env python3
"""Rename each engine CHANGELOG's BARE `## Unreleased` heading to the version being cut, and open a
fresh empty one above it. Helper for release-stage.sh (kept out of that script because a heredoc nested
inside a command substitution is a shell parse hazard).

Only a BARE heading is touched. A QUALIFIED one — candor-rust's `## [Unreleased] (nightly lint)` tracks
a component with its own cadence — must survive untouched.

THE POSTCONDITION IS THE POINT: after this runs, every repo in the cut set HAS a section belonging to
the version being cut. `release.sh` selects the release body by that heading, and `bin/_release_notes.sh`
now REFUSES when it is absent rather than falling through to the newest section — so leaving a repo
without one no longer republishes the previous version's notes silently, it stops the cut. This file is
the half that makes the postcondition reachable without hand-editing changelogs on release day.

AN EMPTY `## Unreleased` USED TO BE SKIPPED HERE ("nothing would ship unlabelled"). The concern was real
and is kept — nothing UNLABELLED ships — but the skip answered it by producing NO section at all, which
is what fed the fall-through. Measured three times: candor-swift's and candor-agents' `## [0.29.1]`
entries read, verbatim, "**Family build bump only — no engine changes in this repo**" and say in the
entry itself that they were hand-written only because an empty section would otherwise republish the
previous notes; candor-agents hit it again before the 0.32.0 cut; and after that cut all seven repos sat
empty. A version-only bump is a legitimate thing to cut and had no way to say so, so the workaround was
folklore performed by hand — the shape that gets skipped at the end of a long day.

So an empty section is now STUBBED, not skipped: it becomes a `## [VERSION]` entry whose body says, in
one line, that nothing was recorded for this repo. That is a LABEL, and a true one. It is not a licence
to forget the changelog — `release-preflight.sh` [5b] (changelog-lag) is the check that asks whether
SOURCE moved without the changelog moving, and it is unaffected by this — and release-stage.sh commits
nothing, so the stub lands in a diff a person reviews before anything is permanent.
"""
import os, re, sys

ROOT, VER, DATE = os.environ["ROOT"], os.environ["VER"], os.environ["DATE"]

# The generated body of a stubbed entry. It says WHAT it claims (nothing recorded), WHO wrote it (the
# stager, not a person), and WHY the claim is stated rather than left implicit — so a reader of the
# published release notes is not left guessing whether the notes went missing.
STUB_BODY = (
    "- **Family build bump only — no changes recorded in this repo for this release.**\n"
    "  `## Unreleased` was empty when %s was cut, so `release-stage.sh` wrote this entry rather than\n"
    "  leaving the version without notes of its own: an absent section used to make `release.sh`\n"
    "  republish the PREVIOUS version's notes under the new tag.\n"
)


def find_version_heading(s):
    """The section belonging to VER, in either spelling this family writes.

    `## [0.32.1] — …` is what the engines use. candor-spec's older headings are FLOOR-shaped
    (`## 0.27 — …`), which is why the floor is tried second. Kept BYTE-IDENTICAL to the question
    `bin/_release_notes.sh` asks at publish time — a gate and a publisher that ask different questions
    are how the version heading could exist for one and not the other.
    """
    m = re.search(r"^## (\[%s\]|%s)([ \t]+—[^\n]*)?$" % (re.escape(VER), re.escape(VER)), s, re.M)
    if m:
        return m
    floor = VER.rsplit(".", 1)[0]
    return re.search(r"^## (\[%s\]|%s)([ \t]+—[^\n]*)?$" % (re.escape(floor), re.escape(floor)), s, re.M)

# THE CUT SET (bin/_release_set.sh). A scoped patch stages only the changelogs of the repos it
# publishes: renaming another repo's `## Unreleased` to this version would label pending work as
# shipped in a release that does not contain it — the 0.25 defect this file exists to fix, pointing the
# other way. Absent or empty means the whole family, which is what every unscoped run passes.
RS_SET = os.environ.get("RS_SET", "").split() or None

# candor-spec IS IN THE LOOP. It was not, while preflight [9] checked it — so the one repo the rung is
# AUTHORED in was the one repo staging could not stage, and the only way to clear the gate was by hand.
# Its headings are floor-shaped (`## 0.27 — …`) rather than `## [0.27.0]`, which is why `fold_into`
# below matches either spelling. Same class of miss as the 0.24 release forgetting to TAG candor-spec:
# the repo you work IN is the one you forget to treat as a repo.
for repo in ("candor-spec", "candor-rust", "candor-java", "candor-ts", "candor-swift", "candor-agents"):
    if RS_SET is not None and repo not in RS_SET:
        print("OOS %s: not in this cut — its `## Unreleased` stays unreleased" % repo); continue
    f = os.path.join(ROOT, repo, "CHANGELOG.md")
    if not os.path.isfile(f):
        continue
    s = open(f).read()
    m = re.search(r"^## \[?Unreleased\]?[ \t]*(—[^\n]*)?$", s, re.M)
    if not m:
        print("SAME %s: no bare `## Unreleased` heading" % repo); continue
    nxt = re.search(r"^## ", s[m.end():], re.M)
    body = s[m.end(): m.end() + (nxt.start() if nxt else len(s))]
    existing = find_version_heading(s)
    if not body.strip():
        # ── AN EMPTY SECTION: STUB IT, DO NOT SKIP ───────────────────────────────────────────────
        # Order matters, and this branch has to ask the FOLD question first: an empty `## Unreleased`
        # sitting above an ALREADY-WRITTEN `## [VER]` is the normal mid-release state (you cut the
        # heading, then keep working), and stubbing there would staple "no changes recorded" on top of
        # a section full of them. Nothing is stranded and the version has its section, so: SAME.
        if existing:
            print("SAME %s: `## Unreleased` is empty and `%s` already has its own section"
                  % (repo, existing.group(0).strip())); continue
        s = s[:m.start()] + "## Unreleased\n\n## [%s] — %s\n\n%s" % (VER, DATE, STUB_BODY % VER) + s[m.end():]
        open(f, "w").write(s)
        print("STUB %s: `## Unreleased` was empty → `## [%s] — %s` with a build-bump entry "
              "(REVIEW IT: rewrite in this repo's voice, or delete the whole section if this repo is not in the cut)"
              % (repo, VER, DATE))
        continue
    # ── THE HEADING ALREADY EXISTS: FOLD, DO NOT SKIP ────────────────────────────────────────────
    # Skipping here was a DEADLOCK, found by a release-mechanics review on 2026-08-08. Writing the
    # version heading early is the normal way this project works — you cut `## [0.27.0]`, then keep
    # working, and the new work lands under a fresh `## Unreleased` above it. Staging then refused every
    # one of those repos ("already has a heading"), preflight [9] stayed red on the stranded sections,
    # and `release.sh` gates on preflight — so the tooling could not clear a state the tooling's own
    # workflow produces, and the only route left was hand-editing six changelogs. Hand-driving the
    # release is what lost three steps on 0.24.
    #
    # Folding is the honest resolution: the stranded work IS part of the version being cut, so it belongs
    # INSIDE that section, at the top — newest first, matching how entries are written. The heading
    # itself is kept VERBATIM, date included: it records when the version was cut, and a fold is not
    # a re-cut. (This comment said "with the date refreshed" while line 53 copied the heading
    # unchanged — a claim not matching the artifact, inside the fix that exists to stop exactly that.)
    # `find_version_heading` (top of file) — ONE definition, because the empty-section branch above asks
    # the same question and two copies of it drifting apart would stub a repo that already has a section.
    if existing:
        head_end = existing.end()
        s = (s[:m.start()]                      # everything before `## Unreleased`
             + "## Unreleased\n"                # a fresh empty one
             + s[m.end() + len(body):existing.start()]   # whatever sat between the two headings
             + s[existing.start():head_end]      # the existing version heading, verbatim
             + "\n" + body.rstrip("\n") + "\n"   # the stranded work, folded in at the TOP
             + s[head_end:])
        open(f, "w").write(s)
        print("FOLD %s: `## Unreleased` (%d line(s)) → the existing `%s` section"
              % (repo, len([l for l in body.splitlines() if l.strip()]), existing.group(0).strip()))
        continue
    # PRESERVE THE RUNG MARKER. The bare heading is often `## Unreleased — ⟨spec 0.26⟩`, and dropping that
    # suffix strips the released entry of the one thing that records WHICH CONTRACT it carries — which
    # every prior release entry has. Measured on 0.26: all five engines lost it before this line existed.
    suffix = (m.group(1) or "").strip()
    marker = ""
    if suffix:
        marker = " " + suffix.lstrip("—").strip()
    s = s[:m.start()] + "## Unreleased\n\n## [%s] — %s%s" % (VER, DATE, marker) + s[m.end():]
    open(f, "w").write(s)
    print("OK %s: `## Unreleased` → `## [%s] — %s` (+ fresh empty Unreleased)" % (repo, VER, DATE))

# THE UMBRELLA'S CHANGELOG IS DATED, NOT VERSIONED — its own header says it is "not a versioned release
# artifact". So the `## Unreleased` rename above never applies to it, and its entry sat marked
# "(unreleased)" through the whole 0.26 run until a human noticed. Different shape, same obligation.
# EVERY `(unreleased)` HEADING, NOT THE FIRST. The live file carries two — 2026-08-07 and 2026-08-05 —
# and marking one per run shipped the older section still labelled "(unreleased)" inside the tag, while a
# second run mutated the file again although the contract says re-running is a no-op. Found by a
# release-mechanics review, 2026-08-08.
u = os.path.join(ROOT, "candor", "CHANGELOG.md")
if RS_SET is not None and "candor" not in RS_SET:
    # A scoped cut that is not publishing the umbrella must not stamp its dated headings "released as
    # <ver>": the umbrella is not released at that version, and the heading would say it was.
    print("OOS candor: not in this cut — its dated headings stay `(unreleased)`")
elif os.path.exists(u):
    t = open(u).read()
    # `[ \t]*`, NOT `\s*`: `\s` matches newlines, so with re.M the trailing-whitespace class swallowed the
    # BLANK LINE after the heading and silently reflowed the file. Caught by a one-line diff in the commit
    # that added this — a staging script that quietly reformats what it touches is one nobody will trust.
    pat = re.compile(r"^(## \d{4}-\d{2}-\d{2} —[^\n]*?) \(unreleased\)[ \t]*$", re.M)
    n = len(pat.findall(t))
    if not n and re.search(r"^## \d{4}-\d{2}-\d{2} —[^\n]*\(released [0-9-]+ as %s\)" % re.escape(VER), t, re.M):
        # Already stamped for THIS version by an earlier run. Re-running is a no-op, as the header promises.
        print("SAME candor: newest dated heading is already `(released … as %s)`" % VER)
    elif not n:
        # ── NOTHING TO STAMP: OPEN A DATED STUB ──────────────────────────────────────────────────────
        # The umbrella has the SAME defect as the engines, in its own spelling. Its changelog is dated,
        # so `bin/_release_notes.sh` picks its notes by POSITION — and with no `(unreleased)` heading to
        # stamp, the newest section is the PREVIOUS release's, which is what would get republished. The
        # publisher now refuses that (it demands a `(released … as $VER)` stamp on the section it
        # selects), so leaving this as a bare "SAME" would turn an unremarkable state into a dead stop
        # at step 3 with no tooling route out — the 0.24 hand-driven-release shape.
        # Inserted ABOVE the first `## ` heading so "most recent first" holds, and written already
        # stamped, exactly as the substitution above would have left it.
        stub = ("## %s — family build bump (released %s as %s)\n\n"
                "No change to the umbrella's own surface — `adopt/`, `integrations/`, `fingerprint/` and the\n"
                "family docs are as they were. This entry exists because a release with no notes of its own\n"
                "used to be published under the PREVIOUS release's notes; `ENGINE_PIN` moves to %s so\n"
                "`candor update` and the Homebrew formula fetch the engines this cut published.\n\n" % (DATE, DATE, VER, VER))
        first = re.search(r"^## ", t, re.M)
        at = first.start() if first else len(t)
        t = t[:at] + stub + t[at:]
        open(u, "w").write(t)
        print("STUB candor: no dated heading marked `(unreleased)` → opened `## %s — family build bump` "
              "(REVIEW IT: rewrite in the umbrella's voice, or delete it if this cut changes nothing there)" % DATE)
    else:
        t_before_sub = t
        t = pat.sub(lambda m2: "%s (released %s as %s)" % (m2.group(1), DATE, VER), t)
        open(u, "w").write(t)
        # A MARKER THIS PATTERN DID NOT MATCH IS THE DANGEROUS CASE, because the count above reads as
        # completeness. Measured 2026-08-31: six dated headings carried `(unreleased)` placed after the
        # DATE instead of at the END of the heading, so none matched, exactly one pre-existing
        # well-formed heading was stamped, and this line printed "1 dated heading(s) marked released"
        # and exited 0. `_release_notes.sh` then refused at exit 3 with a remedy naming the command
        # that had just reported OK — and the operator-plausible escape (mark only the newest) would
        # have shipped four sections of real work inside the tag permanently unlabelled, every gate
        # green. Count the WORD, compare against what the PATTERN took, and name the difference.
        loose = len(re.findall(r"^## \d{4}-\d{2}-\d{2}[^\n]*\(unreleased\)", t_before_sub, re.M))
        if loose > n:
            print("WARN candor: %d dated heading(s) carry `(unreleased)` but only %d matched — the marker "
                  "belongs at the END of the heading (`## DATE — title (unreleased)`), not after the date. "
                  "The unmatched %d will ship inside the tag STILL LABELLED unreleased."
                  % (loose, n, loose - n))
        print("OK candor: %d dated heading(s) marked released (%s as %s)" % (n, DATE, VER))
