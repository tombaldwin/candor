# candor digest — making the silent gate visible (spec)

Status: **Phase 1 BUILT (2026-07-10)** — `candor-agents digest` renders the owner report to a
committable `CANDOR-REPORT.md` (13 tests, on data the stop-hook already logs). Phases 2–3 (log CI /
standalone runs; scheduled + Slack/email delivery) below, not built. Builds on the shipped
`.candor/activity.jsonl` log and the `candor-agents stats` summarizer — no new analysis, a delivery
surface over data candor already keeps.

## The problem it solves

candor's value is that it's quiet: it speaks only when something crosses a line, so it never becomes
the tool developers mute. But silence has a cost — the person who *decides to keep candor* (a lead, a
manager, whoever owns the renewal) never sees it working, so "why are we running this?" is an easy
question to ask and a hard one to answer. Every good preventive tool has this shape (backups,
insurance, a firewall): invisible until the day it saves you, and resented if that day never comes.

**The fix is not to make candor louder.** The instant it starts pinging developers to prove it's
alive, the quiet-in-the-flow feature — the thing that keeps it adopted — is gone. The fix is that
there are **two audiences with opposite needs**, and today candor serves only one:

- the **developer** in the loop wants *minimal* interruption (a green check, an occasional catch);
- the **owner** who renews wants *evidence of value* — and currently gets nothing.

The digest is a **separate, periodic, owner-facing channel** that the developer never has to look at.
It turns silence into a quantified record: *you haven't heard from candor because nothing crossed a
line — here is the month that proves it.*

## What it reads (already logged — no new instrumentation for the agent loop)

`.candor/activity.jsonl`, one record per checked turn, written by `stop-hook.sh` today:

```json
{"ts":"…","sessionId":"…","engine":"java","edited":[…],"gained":["Db"],
 "blastRadius":5,"verdict":"clean|blocked|setup","violations":["AS-EFF-006"],
 "unknowns":3,"effects":["Db","Log"],"reviewMs":142}
```

`candor-agents stats` already parses this into measured counts (edits checked; clean/blocked/setup;
violations by code; effects introduced; largest blast radius; sessions; time span). The digest is a
**renderer over `stats --json`**, plus the two gaps below.

**Two gaps to close for a complete picture** (both small):
1. **CI-gate and standalone runs don't log yet** (FEEDBACK-SPEC notes this deferred). The digest's
   most valuable line — "held the line on N violations in CI" — needs the PR-gate and
   `candor-review*.sh` standalone paths to append the same record shape. A one-function addition,
   reusing the existing log writer.
2. **Dependency checks (`candor-gains`) are a future source.** When the gains wedge is in use, "N
   dependency updates scanned, 1 gained a capability" is a digest line. Out of scope until gains ships.

## What it says (owner-facing narrative, not a dev stats dump)

A short, plain-language summary — the tone of a backup tool's "everything's fine, here's what I did":

```
candor — protection report · acme-service · June 2026
────────────────────────────────────────────────────
Checked        312 changes across 24 sessions.
Held the line   4 architecture violations caught before merge
                  · 3× domain layer reaching the database (AS-EFF-006)
                  · 1× a formatter gaining a network call (AS-EFF-008)
New capability  2 changes introduced a new effect (Db ×1, Net ×1) — both reviewed, both allowed.
Largest blast   1 change would have rippled to 41 functions; candor showed the full radius up front.
Coverage        candor could not fully resolve 6 changes (dynamic dispatch / reflection) — listed for
                a human look. Everything else was analysed to the leaf.
Quiet is good   308 of 312 changes crossed no boundary. That silence is the product working.
```

**Content rules:**
- **Lead with the catches, close with the silence.** The held-the-line count is the value; the "308
  clean" line reframes silence as coverage, not absence.
- **Always include the coverage/honesty line** — the count candor *couldn't* fully see (`unknowns`).
  This is what separates the digest from a vanity dashboard: it's the same disclosure candor sells,
  pointed at itself. Never hide the gaps; they're the "where to look by hand" that builds trust.
- **Report the boring months honestly.** A month with zero catches says "312 changes, none crossed a
  line" — not silence, and not inflated. The insurance-statement principle: you send it even in a
  claim-free year.
- **Counts, never a leaderboard.** No per-developer stats, no "who introduced the most effects" — that
  turns a trust tool into a surveillance tool and poisons adoption. Aggregate only.

## Where it lands (cheapest first, cadence weekly or monthly)

1. **A committed `CANDOR-REPORT.md`** (or printed by `candor-agents digest`): zero infra, works today,
   the owner reads it in the repo or a scheduled CI job commits/updates it. Ship this first.
2. **A PR / issue comment or a CI job summary** on a schedule (a weekly Action posting the digest):
   still no new service, lands where the team already looks.
3. **Slack / email** (a thin webhook wrapper): the push channel an owner actually notices. One step of
   infra; do it only if 1–2 show the digest is read.

Each step is the same rendered text through a different pipe. Start at 1.

## Privacy (non-negotiable — the log holds file paths)

`.candor/activity.jsonl` records edited file paths, so it is **local-only and gitignored** today. The
digest **aggregates to counts and effect kinds** — it must never carry file paths or code off the
machine. A committed `CANDOR-REPORT.md` and any Slack/email payload contain numbers and AS-EFF codes,
never paths or snippets. The rule: the digest is derived facts, at the same privacy tier as the gate
verdict, not the raw log.

## Build order

- **Phase 1 — DONE (2026-07-10).** `candor-agents digest [<dir>] [--since] [--out <path|->] [--title]`
  renders the owner narrative (single-sourced on `stats._load`/`_summary`) to a committable
  `CANDOR-REPORT.md`: leads with the catches, splits **caught** (blocked) from **allowed** (clean
  introductions), always carries the coverage/honesty line (in both directions — "couldn't resolve N"
  or "resolved everything"), closes with silence-as-coverage, aggregate-only (no paths), honest on a
  quiet period and on an empty log (exit 0, a note, no misleading file). 13 tests.
- **Phase 2:** log CI-gate + standalone runs (close gap 1) so "held the line in CI" is real, and add
  the scheduled-Action delivery (option 2).
- **Phase 3 (if pulled):** Slack/email push; the gains dependency line when that wedge is live.

## What NOT to build

More noise in the developer's channel; per-developer metrics; any digest that transmits file paths or
code; manufactured activity numbers to look busy. The digest is true, aggregate, periodic, and aimed
at the owner — a different audience, cadence, and channel than the silent gate itself.
