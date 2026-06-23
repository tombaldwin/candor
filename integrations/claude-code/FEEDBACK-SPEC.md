# Agent-visible feedback — spec ("candor checked this" + session stats)

Status: **design / not built.** Adoption feature. Does **not** touch the candor effect
contract (candor-spec); it surfaces and aggregates what the review already computes.

## Why

Today the Stop hook (`stop-hook.sh`) is **silent on a clean turn**: `rc=0 → echo '{}'`.
It only speaks when something fires (`rc=1`, block + verdict) or on a setup error
(`rc=2`, stderr). So when candor is doing its job and nothing is wrong, the user sees
*nothing* — and a tool whose help is invisible gets uninstalled. This spec makes candor
legible in the session:

- **A. Per-turn notice** — "candor checked this" on every turn, not just on a block.
- **B. Session stats** — measured, countable activity.
- **C. Savings estimate** — a clearly-labelled *model* (never a measurement).

## Non-goals

- Not part of candor-spec — this is integration/tooling, no wire/contract change.
- Not a fabricated or fake-precise savings number (see **Honesty contract**).
- Not measuring the agent's real token spend — candor can't see it; the saving is a
  modelled counterfactual.

---

## A. Per-turn notice ("candor checked this")

Extend the **review scripts** (`candor-review.sh` / `candor-review-source.sh`) to emit a
one-line summary of what the turn's edits touch, and have **`stop-hook.sh` surface it on
`rc=0` via stderr** (Claude Code shows hook stderr to the human; it does not block and
does not re-prompt the agent). The block (`rc=1`) and setup (`rc=2`) paths are unchanged;
they just gain a consistent `candor:` prefix.

One line, prefix `candor:`:

| State | Line |
|---|---|
| clean, no effect change | `candor: ✓ checked — no new effects, no boundary crossed (N fns in the edited blast radius).` |
| effects present, unchanged vs baseline | `candor: ✓ OrderService.export reaches {Db} (≤3 hops) — unchanged vs baseline, no boundary crossed.` |
| blocked (`rc=1`) | `candor: ⚠ blocked — PricingService.quote now reaches {Net} via billing.charge; or AS-EFF-006 …` (verdict already goes to the agent) |
| setup (`rc=2`) | `candor: review could not run (rc=2) — <detail>` (existing behaviour) |

The review already prints gained effects + blast radius on `rc=1`; on a clean turn it must
also compute the edited units' **current** effect set + blast-radius size for the summary
(cheap — it already scanned the tree).

**Verbosity** — env `CANDOR_HOOK_NOTICE`:
- `summary` (default) — the clean line every turn.
- `quiet` — only on a block (today's behaviour).
- `off` — nothing on stderr.

---

## B. Session stats (measured — no estimation)

**Source of truth: an activity log the review appends each run** — `.candor/activity.jsonl`,
one record per review (deterministic, local, no transcript parsing required):

```json
{"ts":"2026-06-23T10:14:02Z","engine":"java","editedUnits":["app/OrderService.export"],
 "gained":[],"effects":["Db"],"blastRadius":41,"maxHops":3,
 "verdict":"clean","violations":[],"unknowns":6,"reviewMs":190}
```

The shell hook stamps `ts` (engines stay deterministic — no `Date.now()` in-engine).
candor-agents *may* also corroborate from the Claude Code transcript it already parses,
but the log is primary.

**Command: `candor-agents stats [--json] [--since <iso>] [--no-estimate]`** (alias
`candor stats`) reads the log and reports **only measured fields**:

- reviews run; clean / blocked / setup counts
- blast-radius answered — total fns covered, max radius, max hops
- boundaries enforced (policy active?), violations caught (by AS-EFF code)
- Unknowns disclosed
- candor's own cost — total review wall-time

All directly counted. No model anywhere in section B.

---

## C. Savings estimate (modelled, labelled)

**Honesty contract — the crux.** candor's whole pitch is *disclosure, not fabrication*; its
own ROI counter has to hold to that or the first skeptic (rightly) tears it apart. candor
**cannot measure** what the agent would have spent re-deriving — that is a counterfactual.
So the saving is a **model, never a measurement**, and the output must say so.

- **Measured input:** number of blast-radius answers candor served (each = a "what does
  this touch?" the agent did not have to re-derive) and their sizes.
- **Model:** the published benchmark per-question deltas — **~17× tokens, ~50× tool calls,
  ~38× wall-clock** (one candor query ≈ 24k tokens / 1 tool call / ~8 s). Source:
  candor.poly.io/agents.
- **Estimate** = served answers × (benchmark multiple − 1) × per-query baseline.

**Presentation rules (enforced in the formatter):**
1. Show measured activity (B) **first and separately**.
2. Tag the estimate line `(estimate — model, not measured)` and state its basis.
3. Hedged magnitude only — "on the order of", never `saved 412,337 tokens`.
4. Link the methodology.
5. Never print a savings figure without the benchmark caveat attached.
6. `--no-estimate` shows measured only.

**Example output:**

```
candor this session (measured)
  8 edits checked · 8 blast-radius answers · up to 41 fns, 3 hops
  1 boundary enforced · 0 violations · 6 Unknowns disclosed · 1.5 s of candor

Estimated saving (model, not measured)
  deriving those 8 answers by hand averaged ~17× tokens / ~50× tool calls / ~38× time
  → on the order of a few hundred K tokens and ~40 min of agent tracing avoided
  basis: candor.poly.io/agents — one query ≈ 24k tok / 1 call / ~8 s
```

---

## Cross-agent (non-Claude-Code)

The per-turn hook is Claude-Code-specific (a Stop hook). But the **activity log is written
by the review scripts regardless of caller**, so `stats` works for any agent that runs the
review (MCP, other CLI agents). The generic "notice" for those is just the review's
clean-summary line on stdout, which they already capture as tool output.

## Config summary

- `CANDOR_HOOK_NOTICE` = `summary` (default) | `quiet` | `off`
- `CANDOR_ACTIVITY_LOG` = path (default `.candor/activity.jsonl`); unset → logging off
- `candor-agents stats [--json] [--since <iso>] [--no-estimate]`

## Phasing

- **P1 — per-turn notice.** Clean-summary line in `candor-review*.sh`; `stop-hook.sh`
  surfaces it on `rc=0` via stderr; `CANDOR_HOOK_NOTICE`. *Smallest change, biggest
  legibility win — do this first.*
- **P2 — activity log.** Review appends `.candor/activity.jsonl` each run.
- **P3 — `candor-agents stats`** (measured) over the log.
- **P4 — the labelled estimate** in `stats`, behind the Honesty contract.

## Open questions

- **Per-query baseline vs per-size scaling.** The 24k-tok / benchmark multiples are
  averages; scaling the estimate by each answer's actual blast-radius size would be more
  accurate (still a model). Decide in P4.
- **Privacy.** `activity.jsonl` holds edited symbol names — keep it local; add to
  `.gitignore` in the adopt starter by default.
- **`ts` source.** Shell stamps it; confirm the review scripts never need it in-engine.
