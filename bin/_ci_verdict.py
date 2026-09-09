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
    # SOUNDNESS R356 — `or`, not a default. `.get(k, default)` returns a PRESENT-but-null value, so a
    # null `workflowDatabaseId` keyed every workflow under `None` and merged them into one group; the
    # newest then won across UNRELATED workflows and a failing one was dropped. Measured:
    # [ci success@10:05, native failure@10:00] with both ids null answered OK. That is the 2026-08-29
    # same-name-merge defect through a different door.
    key = x.get("workflowDatabaseId") or x.get("workflowName")
    if key not in groups:
        groups[key] = []
        order.append(key)
    groups[key].append(x)

# SOUNDNESS R352 — "ANY SUCCESS IN THE GROUP WINS" MASKS A NEWER FAILURE, AND THIS IS RELEASE GATE
# [10], the check that authorises publishing a commit. The line was
#     success = next((e for e in entries if ... == "success"), None)
#     latest.append(success if success is not None else entries[0])
# which answers OK for [failure(newest), success(older)] at one sha. Measured against the published
# v0.35.0 on identical stdin and argv: v0.35.0 -> `BAD ci:failure`, this file before the fix -> `OK`.
#
# The real trigger is not hypothetical: `native.yml` and candor-swift's `release.yml` both document
# `workflow_dispatch` RECOVERY paths that create a second run at an unmoved sha, and the cron
# workflows (`realworld-oracle-deep`, `disclosure-recall`) re-run at a sha that has not moved. A
# recovery dispatch that FAILS after an earlier success read green.
#
# WHY THE OVERSHOOT HAPPENED: the defect this replaced was a `cancelled` twin — a supersede — and the
# repair generalised from "a cancelled run is not a verdict" to "a success outranks anything", which
# also swallows `failure`. The narrow rule keeps the first half and drops the second.
#
# AND "WORST WINS" IS NOT THE FIX EITHER — it was the first wording tried and it is wrong: it would
# fail `idsame` (a success at 10:05 legitimately superseding a failure at 10:00) and would block every
# re-run at an unmoved sha until the sha changed, which is precisely what a recovery dispatch is for.
# Recency must still decide; the tie is the only place order cannot.
#
# THE RULE, in three steps:
#   1. drop `cancelled` entries that have a non-cancelled sibling in the group — a cancelled run is an
#      ABSENCE of verdict, and the sibling's completed run IS a verdict on that sha. No cause is
#      asserted about WHY it cancelled, so nothing has to be earned from a workflow file (ci-watch.sh's
#      `workflow_cancels_in_progress` guard answers a DIFFERENT question — an older commit's newest run
#      — and importing it here would need a `gh workflow list` call per repo against a shared API quota).
#   2. take the FIRST remaining entry; `gh run list` returns newest-first, which is the assumption this
#      file already documents and shares with ci-watch.sh.
#   3. if any other remaining entry shares the winner's whole-second `createdAt` and is not itself a
#      success, the group is BAD. Second-granularity is exactly where "newest" stops being decidable —
#      the defect this file was written for — so at a tie the safe answer is the failing one.
latest = []
for key in order:
    entries = groups[key]
    def _concl(e):
        return e.get("conclusion") or e.get("status")
    non_cancelled = [e for e in entries if _concl(e) != "cancelled"]
    live = non_cancelled if non_cancelled else entries
    winner = live[0]
    # SOUNDNESS R356 — AND THIS TEST MUST NAME THE OK SET, NOT JUST `success`. The verdict below
    # treats BOTH `success` and `skipped` as acceptable, and this line asked only about `success`, so a
    # `skipped` twinned with a failure at the same second REPLACED the winner with the skip and the
    # group answered OK. Measured on the fix that closed R352, i.e. this rule reintroduced the class it
    # was written to close, in the same gate:
    #     [failure, skipped]            -> OK        (the failure masked)
    #     [skipped, failure]            -> BAD       (…and the verdict depends on gh's array order,
    #     [failure, skipped, failure]   -> OK         which is the 2026-08-26 defect this file exists for)
    # `skipped` is reachable in this family — candor-swift's ci.yml, candor-spec's conformance.yml and
    # the umbrella's jetbrains.yml all carry job-level `if:`.
    OK_CONCLUSIONS = ("success", "skipped")
    tied = [e for e in live[1:]
            if (e.get("createdAt") or "") == (winner.get("createdAt") or "")
            and _concl(e) not in OK_CONCLUSIONS]
    latest.append(tied[0] if tied else winner)

bad = [x for x in latest if (x.get("conclusion") or x.get("status")) not in ("success", "skipped")]
if bad:
    print("BAD " + ", ".join("%s:%s" % (x.get("workflowName"), x.get("conclusion") or x.get("status")) for x in bad))
else:
    print("OK")
