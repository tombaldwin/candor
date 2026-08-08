#!/usr/bin/env python3
"""Rename each engine CHANGELOG's BARE `## Unreleased` heading to the version being cut, and open a
fresh empty one above it. Helper for release-stage.sh (kept out of that script because a heredoc nested
inside a command substitution is a shell parse hazard).

Only a BARE heading is touched. A QUALIFIED one — candor-rust's `## [Unreleased] (nightly lint)` tracks
a component with its own cadence — must survive untouched, and an EMPTY section needs no rename because
nothing would ship unlabelled.
"""
import os, re, sys

ROOT, VER, DATE = os.environ["ROOT"], os.environ["VER"], os.environ["DATE"]

# candor-spec IS IN THE LOOP. It was not, while preflight [9] checked it — so the one repo the rung is
# AUTHORED in was the one repo staging could not stage, and the only way to clear the gate was by hand.
# Its headings are floor-shaped (`## 0.27 — …`) rather than `## [0.27.0]`, which is why `fold_into`
# below matches either spelling. Same class of miss as the 0.24 release forgetting to TAG candor-spec:
# the repo you work IN is the one you forget to treat as a repo.
for repo in ("candor-spec", "candor-rust", "candor-java", "candor-ts", "candor-swift", "candor-agents"):
    f = os.path.join(ROOT, repo, "CHANGELOG.md")
    if not os.path.isfile(f):
        continue
    s = open(f).read()
    m = re.search(r"^## \[?Unreleased\]?[ \t]*(—[^\n]*)?$", s, re.M)
    if not m:
        print("SAME %s: no bare `## Unreleased` heading" % repo); continue
    nxt = re.search(r"^## ", s[m.end():], re.M)
    body = s[m.end(): m.end() + (nxt.start() if nxt else len(s))]
    if not body.strip():
        print("SAME %s: `## Unreleased` is empty — nothing would ship unlabelled" % repo); continue
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
    existing = re.search(r"^## (\[%s\]|%s)([ \t]+—[^\n]*)?$" % (re.escape(VER), re.escape(VER)), s, re.M)
    if not existing:
        # Floor-shaped spelling (candor-spec writes `## 0.27 — …`, not the full patch version).
        floor = VER.rsplit(".", 1)[0]
        existing = re.search(r"^## (\[%s\]|%s)([ \t]+—[^\n]*)?$" % (re.escape(floor), re.escape(floor)), s, re.M)
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
if os.path.exists(u):
    t = open(u).read()
    # `[ \t]*`, NOT `\s*`: `\s` matches newlines, so with re.M the trailing-whitespace class swallowed the
    # BLANK LINE after the heading and silently reflowed the file. Caught by a one-line diff in the commit
    # that added this — a staging script that quietly reformats what it touches is one nobody will trust.
    pat = re.compile(r"^(## \d{4}-\d{2}-\d{2} —[^\n]*?) \(unreleased\)[ \t]*$", re.M)
    n = len(pat.findall(t))
    if not n:
        print("SAME candor: no dated heading marked `(unreleased)`")
    else:
        t = pat.sub(lambda m2: "%s (released %s as %s)" % (m2.group(1), DATE, VER), t)
        open(u, "w").write(t)
        print("OK candor: %d dated heading(s) marked released (%s as %s)" % (n, DATE, VER))
