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
    s = s[:m.start()] + "## Unreleased\n\n## [%s] — %s" % (VER, DATE) + s[m.end():]
    open(f, "w").write(s)
    print("OK %s: `## Unreleased` → `## [%s] — %s` (+ fresh empty Unreleased)" % (repo, VER, DATE))
