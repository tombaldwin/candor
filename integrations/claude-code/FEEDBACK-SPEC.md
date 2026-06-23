# Agent-visible feedback — spec ("candor checked this" + session stats)

Status: **design / not built.** Adoption feature. Does **not** touch the candor effect
contract (candor-spec); it surfaces and aggregates what the review already computes.

> **P0 RESOLVED (2026-06-23).** The user-visible, non-blocking channel is the Stop hook's
> top-level **`systemMessage`** field — shown to the human, not fed to the model, on a
> clean exit-0 allow. Confirmed against code.claude.com/docs/en/hooks. Also confirmed:
> hook **stderr is NOT shown on exit 0** (so the old `rc=2` stderr notice was invisible —
> now fixed), and the hook **stdin carries `session_id`** (B's delimiter) **and `tool_calls`**
> with each Edit/Write `file_path` — so the turn's edited files come straight from the hook
> input, no `git diff` needed. **P1 (the notice) is built** in `stop-hook.sh`.

## Why

Today the Stop hook (`stop-hook.sh`) is **silent on a clean turn**: `rc=0 → echo '{}'`.
It only speaks on a block (`rc=1`) or a setup error (`rc=2`). So when candor is doing its
job and nothing is wrong, the user sees *nothing* — and a tool whose help is invisible gets
uninstalled. This spec makes candor legible in the session:

- **A. Per-turn notice** — "candor checked this" on every turn, not only on a block.
- **B. Session stats** — measured, countable activity (the durable signal).
- **C. Per-answer cost comparison** — a clearly-labelled *model*, never a measurement, and
  not summed across a session.

## Non-goals

- Not part of candor-spec — integration/tooling, no wire/contract change.
- **No session-summed "tokens saved" figure by default** (see C — weak external validity).
- Not measuring the agent's real token spend — candor can't see it; any comparison is a
  modelled counterfactual.

---

## A. Per-turn notice ("candor checked this")

### Delivery (resolved — built)

The notice reaches the **user** via the Stop hook's top-level **`systemMessage`** field
(shown to the human, non-blocking, not fed to the model). The block path
(`{"decision":"block","reason":…}`) is unchanged, and now also carries a `systemMessage` so
the user sees the block too. Setup errors (`rc=2`) are surfaced via `systemMessage` as well,
since hook **stderr is not shown on a clean exit** (the old stderr notice was invisible).
Implemented in `stop-hook.sh`; JSON validity tested across clean / block / setup / each
verbosity level.

### Edited-units sourcing (two tiers)

The review diffs effects vs a baseline over the **whole repo**; it does *not* natively know
which symbols the agent touched this turn. So:

- **Precise (preferred):** the turn's edited files come straight from the hook input —
  `tool_calls[].tool_input.file_path` for the Edit/Write tools (no `git diff` needed). Map
  those files to units and report them. The hook passes them to the review via env.
- **Fallback (always available):** report the whole-repo delta vs baseline — "no new effects
  vs baseline" / "new effect {Net} vs baseline" — without naming a specific symbol.

The notice degrades to the fallback when the changed-file set isn't available. **It never
names a symbol it can't source.**

### What it says (one line, prefix `candor:`)

| State | Line |
|---|---|
| clean, no effect change | `candor: ✓ checked — no new effects, no boundary crossed.` (+ ` (OrderService.export reaches {Db}, ≤3 hops)` when the edited unit is sourced) |
| effects changed vs baseline | `candor: ✓ new effect {Db} in OrderService.export (≤3 hops) — within policy.` |
| blocked (`rc=1`) | `candor: ⚠ blocked — PricingService.quote now reaches {Net} via billing.charge; / AS-EFF-006 …` (verdict already goes to the agent) |
| setup (`rc=2`) | `candor: review could not run (rc=2) — <detail>` (existing) |

### Verbosity / fatigue

A line every turn risks becoming wallpaper — tuned out, the opposite of the goal.
`CANDOR_HOOK_NOTICE`:

- `summary` — one short line every turn (max legibility; best for first use / demos).
- `changes` — speak only when effects are present/changed or a boundary is involved.
- `quiet` — only on a block (today's behaviour).
- `off`.

The durable "it's working" signal is really **B**; the per-turn line is reassurance. Default
**`summary`** for first-run legibility, but `changes` is the saner long-term per-project
setting and the adopt starter should suggest it once a project is established.

### Latency

The clean path may early-exit today; computing the edited blast radius *every* turn adds work
to *every* turn — a latency tax on the loop on a large repo. **Budget:** the notice must reuse
the scan the review already ran and add no separate full re-analysis. If the blast radius
isn't already in hand, the notice uses the cheap effect-delta line rather than forcing a fresh
radius computation.

---

## B. Session stats (measured — no model anywhere)

### Activity log

`.candor/activity.jsonl`, one record per review run, written by the review scripts
(deterministic, local, no transcript parsing):

```json
{"ts":"2026-06-23T10:14:02Z","sessionId":"<from hook input>","engine":"java",
 "editedUnits":["app/OrderService.export"],"gained":[],"effects":["Db"],
 "blastRadius":41,"maxHops":3,"verdict":"clean","violations":[],"unknowns":6,"reviewMs":190}
```

- **`sessionId`** comes from the Claude Code hook input JSON; `stats` scopes "this session" by
  it. Without it, "session" is meaningless and conflates days of activity.
- `editedUnits` is `null` in the fallback tier (changed-file set unavailable).
- The **shell** stamps `ts` (engines stay deterministic — no `Date.now()` in-engine).
- **Hygiene:** rotate/cap the log (e.g. last 5k lines or 30 days); records are single-line
  appends (atomic for small writes) so parallel turns don't corrupt it.
- **Sole source:** the log only — no transcript corroboration (avoids double-counting).
- **Privacy:** holds edited symbol names → **local-only, never transmitted**, gitignored by
  the adopt starter. (Consistent with candor's "code never leaves your machine" promise.)

### Command

`candor-agents stats [--json] [--session <id>] [--since <iso>]` (alias `candor stats`) reports
**measured fields only**:

- reviews run; clean / blocked / setup counts
- blast-radius answered — total fns covered, max radius, max hops
- boundaries enforced (policy active?), violations caught (by AS-EFF code)
- Unknowns disclosed
- candor's own cost — total review wall-time

All directly counted. No model in B.

---

## C. Per-answer cost comparison (modelled, labelled, **not summed**)

**Revised after review.** A session-summed "tokens saved" figure over-extrapolates: the
benchmark (~17× tokens / ~50× tool calls / ~38× time) came from *one task shape on two Rust
repos*; summing it across a heterogeneous real session yields a number that can be materially
wrong — exactly the credibility candor can't spend. So:

- **No session-total saving by default.** `stats` shows measured activity (B) and stops.
- **Per-answer comparison (the defensible form):** when candor serves a single blast-radius
  answer, it may note the benchmark for a question *of that size* — "a blast radius this size
  (41 fns, 3 hops) averages ~17× the tokens / ~50× the tool calls by hand — benchmark." Tied
  to one comparable query, **not** summed.
- **Optional session estimate (`--estimate`, off by default):** if ever shown, it is tagged
  `(estimate — model, not measured)`, hedged ("on the order of"), **net of candor's own query
  cost** (its result enters the agent's context — not free), and links the methodology. Never
  shown without that caveat; never a default.

**Honesty contract (applied harder than v1):** candor cannot measure the counterfactual; the
comparison is a model; measured (B) and modelled (C) are never blended; the session sum is off
by default because its external validity is weak. A fabricated or fake-precise ROI number
would directly contradict candor's disclosure-not-fabrication claim and is the first thing a
skeptic attacks.

---

## Cross-agent (non-Claude-Code)

The per-turn notice is **Claude-Code-specific** — other agents have no Stop-hook equivalent,
so there's no clean per-turn trigger for them (honest gap, not papered over). What transfers:
the **activity log is written whenever the review runs** (any caller — MCP, other CLI agents),
so `candor-agents stats` works anywhere; and the review's summary line is on stdout for agents
that capture tool output.

## Config summary

- `CANDOR_HOOK_NOTICE` = `summary` (default) | `changes` | `quiet` | `off`
- `CANDOR_ACTIVITY_LOG` = path (default `.candor/activity.jsonl`; unset → logging off)
- `candor-agents stats [--json] [--session <id>] [--since <iso>] [--estimate]`

## Phasing

- **P0 — verify delivery.** Confirm the user-visible, non-blocking Stop-hook channel on a real
  Claude Code install. Gates all of A.
- **P1 — per-turn notice.** Effect-delta line via the verified channel; precise edited-units
  when `git diff` is available, else fallback; `CANDOR_HOOK_NOTICE`.
- **P2 — activity log.** `sessionId`, hygiene, privacy default.
- **P3 — `candor-agents stats`** (measured) over the log.
- **P4 — per-answer comparison;** the session `--estimate` last, if at all.

## Open questions

- **Pre-turn snapshot point** for the `git diff` (HEAD vs a ref stamped at turn start) — sets
  edited-units precision.
- **Default verbosity** — ship `summary` (first-run legibility) or `changes` (less fatigue)?
- **Size-scaled comparison** — the per-answer form scales by blast-radius size; the optional
  session `--estimate` would need the same to be even roughly right.
