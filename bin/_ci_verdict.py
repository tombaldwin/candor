#!/usr/bin/env python3
# _ci_verdict.py — the ONE implementation of "what did CI conclude for this commit", shared by both call
# sites in release-preflight.sh's [10] (the initial read, and the post-wait re-check after CI_WAIT_BUDGET).
#
# Until 2026-08-26 this logic was pasted twice, and the comment beside each copy already warned that "a
# rule on one route and not its sibling is this family's oldest defect" — a warning about staying in sync,
# not about being CORRECT, and both copies carried the same bug in sync with each other.
#
# THE BUG: `gh run list --json ...,createdAt` reports `createdAt` at WHOLE-SECOND granularity. On
# 2026-08-26, three workflows from one push shared a single second. The old code did
#     mine.sort(key=lambda x: x.get('createdAt') or '')
#     latest = {}
#     for x in mine: latest[x['workflowName']] = x     # last write wins
# Python's sort is stable, so two entries tied on createdAt keep their INPUT order after the sort — and
# "last write wins" then picks whichever of the tied pair happened to be listed SECOND in that input, which
# is not "whichever is newest": it is just "whichever is second", full stop. Swapping the two objects in
# the input JSON (same facts, same timestamps) flipped the verdict, because the thing being read was the
# array's incidental order, not recency.
#
# THE FIX, taken from bin/ci-watch.sh rather than invented a third time: `gh run list` (undocumented but
# already relied on by ci-watch.sh) returns runs NEWEST-FIRST. So: never re-sort, and keep the FIRST
# occurrence of each workflow. That is exact — there is no second-granularity to lose — and ci-watch.sh's
# own header explains the sibling lesson: an earlier version of THAT script sorted rows alphabetically
# instead of trusting gh's order, and "which duplicate survives was arbitrary" ever since. Trusting gh's own
# order here means this file now has the same assumption in exactly one place, not two independently-argued
# ones that could drift.
#
# THE SECOND BUG, same family, found and fixed 2026-08-29 alongside ci-watch.sh's "fifth false green":
# "each workflow" above used to mean workflowName — a DISPLAY STRING a human writes in `name:`, which
# GitHub does NOT require to be unique across FILES. Two workflow files in one repo can both declare
# `name: ci`; `seen.add(wf)`/`wf in seen`, keyed on that shared name, silently treated the second file's
# run as a duplicate of the first and dropped it — including a genuine failure, in the exact release gate
# ([10] in release-preflight.sh) that is supposed to catch one. Reproduced live before this fix: two
# entries for "ci" with different workflowDatabaseId, one success one failure, printed "OK". Fixed by
# keying on workflowDatabaseId instead — GitHub's own numeric per-FILE identifier, confirmed via `gh
# workflow list --json id,path` reporting the same number `gh run list --json workflowDatabaseId` does
# for that file's runs. workflowName is still carried in the "BAD ..." message, for a human to read, but
# it is never again what decides which rows are "the same workflow".
#
# INPUT (stdin): a JSON array from `gh run list --json
# headSha,conclusion,status,workflowName,workflowDatabaseId,createdAt`.
# ARGV[1]: the head SHA being judged, or "" (see below).
# OUTPUT (one line): ERR | NONE | OK | BAD <workflow:conclusion-or-status>[, ...]
#
# ARGV[1] == "" — THE THIRD CALL SITE (2026-08-26 code review): [10]'s NONE branch (a docs-only commit
# that triggered no workflow at all) used to ask a DIFFERENT question with its own inline python: not
# "did HEAD's own CI pass" but "what is this repo's last known CI state", by grepping `gh run list` and
# taking element 0 — the single freshest completed run, of WHATEVER workflow happened to finish most
# recently, unfiltered by workflow name. That mixes unrelated signals: a repo carries several workflows
# on different triggers (push, weekly cron, nightly), and whichever one happens to have completed most
# recently decides the verdict for ALL of them. A stale, unrelated workflow finishing green after the
# real CI workflow broke would report "last CI run green" over a genuinely broken build — a false clear
# in exactly the direction this family's own rule calls the cardinal sin. An empty head means "no commit
# to match against" — skip the headSha filter and dedupe every workflow's own latest completed run
# instead, same rule as a real commit, so ONE straggler cannot stand in for the whole repo either way.
import json
import sys

head = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    runs = json.load(sys.stdin)
except Exception:
    print("ERR")
    raise SystemExit

mine = runs if head == "" else [x for x in runs if x.get("headSha") == head]
if not mine:
    print("NONE")
    raise SystemExit

# THE THIRD BUG, found 2026-09-03 during the 0.35.0 cut: GitHub can create TWO runs of the SAME
# workflow for the SAME commit in the SAME second — candor-rust's push of `75053f1` produced two
# `realworld-oracle-deep` runs, one `success` and one `cancelled` (the workflow's own concurrency group
# killed the duplicate trigger). "first occurrence wins" — the fix for the FIRST bug above — trusts gh's
# listed order to mean "newest first", which this family's own header on THAT bug already documents as
# unreliable at whole-second granularity: two rows tied on createdAt have no reliable order between them
# at all. Here it picked the cancelled twin, and [10] failed a preflight whose repos were all actually
# green; a re-run of the cancelled twin cleared it, which is the tell that nothing was actually broken.
#
# THE FIX extends "first occurrence per workflow ID wins" rather than replacing it: within a workflow's
# group of runs at this commit, a `success` wins the group outright, wherever gh lists it. Only when NO
# run in the group succeeded does the group fall back to the first-occurrence (gh's listed order) rule,
# unchanged from the first fix — so a workflow with no successful run still fails, and a run still
# in_progress/queued with no successful sibling still carries that status through to the caller's wait
# loop. A `cancelled` run losing to a `success` sibling is exactly the case above; nothing here changes
# what happens when NEITHER run of a group succeeded.
#
# FIRST OCCURRENCE PER WORKFLOW ID, grouped (not deduped eagerly): `mine` preserves gh's own newest-first
# order (filtering by headSha above does not reorder), so within each group the first entry is that
# workflow's nominal-latest run — used only as the fallback when the group has no success. Falls back to
# workflowName as the grouping key only if workflowDatabaseId is absent from the input entirely (a
# caller that has not been updated to request it) — degraded, not silently wrong: the fallback is the
# OLD key, not a crash, but every current call site in release-preflight.sh requests the id.
order = []
groups = {}
for x in mine:
    key = x.get("workflowDatabaseId", x.get("workflowName"))
    if key not in groups:
        groups[key] = []
        order.append(key)
    groups[key].append(x)

latest = []
for key in order:
    entries = groups[key]
    success = next((e for e in entries if (e.get("conclusion") or e.get("status")) == "success"), None)
    latest.append(success if success is not None else entries[0])

bad = [x for x in latest if (x.get("conclusion") or x.get("status")) not in ("success", "skipped")]
if bad:
    print("BAD " + ", ".join("%s:%s" % (x.get("workflowName"), x.get("conclusion") or x.get("status")) for x in bad))
else:
    print("OK")
