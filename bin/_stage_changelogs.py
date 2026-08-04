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
for repo in ("candor-rust", "candor-java", "candor-ts", "candor-swift", "candor-agents"):
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
    if re.search(r"^## \[%s\]" % re.escape(VER), s, re.M):
        print("SAME %s: already has a `## [%s]` heading" % (repo, VER)); continue
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
u = os.path.join(ROOT, "candor", "CHANGELOG.md")
if os.path.exists(u):
    t = open(u).read()
    # `[ \t]*`, NOT `\s*`: `\s` matches newlines, so with re.M the trailing-whitespace class swallowed the
    # BLANK LINE after the heading and silently reflowed the file. Caught by a one-line diff in the commit
    # that added this — a staging script that quietly reformats what it touches is one nobody will trust.
    m2 = re.search(r"^(## \d{4}-\d{2}-\d{2} —[^\n]*?) \(unreleased\)[ \t]*$", t, re.M)
    if not m2:
        print("SAME candor: no dated heading marked `(unreleased)`")
    else:
        t = t[:m2.start()] + "%s (released %s as %s)" % (m2.group(1), DATE, VER) + t[m2.end():]
        open(u, "w").write(t)
        print("OK candor: dated heading marked released (%s as %s)" % (DATE, VER))
