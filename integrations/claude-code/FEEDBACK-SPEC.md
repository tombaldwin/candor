# Agent-visible feedback — spec ("candor checked this" + session stats)

Status: **SHIPPED (P0–P4, 2026-06-23…07-01; contract locked by `test-stop-hook.sh`). Remaining:
`maxHops`, standalone/CI logging.** Adoption feature. Does **not** touch the candor effect
contract (candor-spec); it surfaces and aggregates what the review already computes.

> **P0 RESOLVED (2026-06-23).** The user-visible, non-blocking channel is the Stop hook's
> top-level **`systemMessage`** field — shown to the human, not fed to the model, on a
> clean exit-0 allow. Confirmed against code.claude.com/docs/en/hooks. Also confirmed:
> hook **stderr is NOT shown on exit 0** (so the old `rc=2` stderr notice was invisible —
> now fixed), and the hook **stdin carries `session_id`** (B's delimiter) but **NOT `tool_calls`**
> — the Stop payload is only `session_id`/`transcript_path`/`cwd`/`permission_mode`/`hook_event_name`.
> (An earlier claim that Stop carries `tool_calls` was a `claude-code-guide` hallucination, caught in
> review and corrected against the docs.) So the turn's edited files are read from **`transcript_path`**
> (the JSONL), scoped to the last turn — not the hook input. **P1 (the notice) is built** in `stop-hook.sh`.

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

- **From the transcript:** Stop stdin has no `tool_calls`, so the hook reads `transcript_path`
  (the session JSONL) and extracts the Edit/Write/MultiEdit/NotebookEdit `file_path`s from the
  assistant `tool_use` events **since the last human (string-content) message** — i.e. this turn.
  Logged as `null` (not a misleading `[]`) when there's no transcript or the parse fails.
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
- `changes` — silent on every clean turn (`rc=0`, even one whose effects changed within policy);
  speaks only when something fired — the block `⚠` notice and setup errors.
- `quiet` — no per-turn and no block notice (the block still reaches the **agent** as the
  `reason`; the human sees nothing for it); only setup errors surface.
- `off` — nothing, ever.

(These are the tested semantics — `test-stop-hook.sh` locks them, including the suppressed
block `systemMessage` under `quiet`.)

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

### Activity log — built (hook-side, P2)

`.candor/activity.jsonl`, one record per turn, written by **`stop-hook.sh`** — it holds the most
context (`session_id`, the turn's edited files, the review output, the verdict). Best-effort:
needs jq, writes only when the log's dir already exists (never creates `.candor/`),
`CANDOR_ACTIVITY_LOG=off` disables, `CANDOR_ACTIVITY_CAP` (default 5000) caps growth.

```json
{"ts":"2026-06-23T19:43:13Z","sessionId":"sess-123","engine":"java",
 "edited":["src/Bar.java","src/Foo.java"],"gained":["Db"],"blastRadius":5,
 "verdict":"blocked","violations":["AS-EFF-006"]}
```

- `sessionId` + `edited` (Edit/Write `file_path`s) come from the hook input JSON; `null`/`[]`
  when absent. `stats` scopes "this session" by `sessionId`.
- `verdict` from the review exit code; `blast`/`gained`/`violations` parsed from the review's
  output — **stats-only**: a field that doesn't parse logs `0`/`[]`; the notice and the gate are
  unaffected.
- The shell stamps `ts` (engines stay deterministic). `>>` of a single line is atomic; the
  cap+rotate is best-effort (a rare concurrent-write race loses a stat line, never the gate).
- **Privacy:** holds edited file paths → **local-only, never transmitted**; gitignored by the
  adopt starter.

**P2.1 — DONE (the richer fields).** `candor-review*.sh` now emit a `CANDOR_SUMMARY {…}` trailer
(gated on `CANDOR_EMIT_SUMMARY`, so standalone callers never see it) carrying `unknowns`, the
distinct `effects` present, and `reviewMs`; the hook reads it into the log and strips it from the
user notice + the agent reason. **Still deferred:** `maxHops` (needs graph-depth, not cheap) and
logging on **standalone / CI** runs (the trailer flag + logging are hook-side; a standalone review
doesn't log).

### Command — built (P3)

`candor-agents stats [<dir>] [--log <path>] [--session <id>] [--since <iso>] [--json]` reports
**measured fields only**, counted from the log:

- edits checked; clean / blocked / setup counts
- policy violations caught (by AS-EFF code)
- effects introduced this period; turns that introduced an effect
- largest blast radius seen
- files touched; sessions; time span

All directly counted, no model. Corrupt log lines are skipped, a missing log is a clean no-op,
an unknown flag exits 2 (7 tests in candor-agents). Unknowns disclosed and candor's own wall-time
are now surfaced too (P2.1 trailer). Still out: `maxHops` (not cheap to compute).

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

**Disclosure contract (applied harder than v1):** candor cannot measure the counterfactual; the
comparison is a model; measured (B) and modelled (C) are never blended; the session sum is off
by default because its external validity is weak. A fabricated or fake-precise ROI number
would directly contradict candor's disclosure-not-fabrication claim and is the first thing a
skeptic attacks.

---

## Cross-agent (non-Claude-Code)

The per-turn notice is **Claude-Code-specific** — other agents have no Stop-hook equivalent,
so there's no clean per-turn trigger for them (a disclosed gap, not papered over). What transfers:
the **activity log is written whenever the review runs** (any caller — MCP, other CLI agents),
so `candor-agents stats` works anywhere; and the review's summary line is on stdout for agents
that capture tool output.

## Config summary

- `CANDOR_HOOK_NOTICE` = `summary` (default) | `changes` | `quiet` | `off`
- `CANDOR_ACTIVITY_LOG` = path (default `.candor/activity.jsonl`; on when that dir exists; `off` disables)
- `CANDOR_ACTIVITY_CAP` = max log lines (default 5000)
- `candor-agents stats [--json] [--session <id>] [--since <iso>] [--estimate]`

## Phasing

- **P0 — verify delivery.** ✓ done — channel is `systemMessage` (see top).
- **P1 — per-turn notice.** ✓ built — `systemMessage` on clean/block/setup; `CANDOR_HOOK_NOTICE`. The
  block-path user notice NAMES the cause (the `AS-EFF` line or the `• fn introduces {E}` introducer), not the
  dangling `…introduced new effects:` header (fixed 2026-07-01). Contract locked by `test-stop-hook.sh` (22
  assertions: every path is valid JSON, clean allows, block fires + names the cause, setup allows, the
  active-guard doesn't re-run the review, the activity log appends).
- **P2 — activity log.** ✓ built (hook-side) — `sessionId` + edited from hook input, verdict/blast/
  gained/violations, rotation, privacy. **P2.1 ✓** — a `CANDOR_SUMMARY` trailer from the reviews
  adds `effects`/`unknowns`/`reviewMs`. Still out: `maxHops`, standalone/CI logging.
- **P3 — `candor-agents stats`** ✓ built — measured gate activity over the log (edits checked,
  blocks, violations by AS-EFF code, effects introduced, blast radius, files, sessions, span);
  `--json` / `--session` / `--since` / `--log`; corrupt-line/missing-log/bad-flag handled; 7 tests.
- **P4 — `candor-agents savings`** ✓ built — counts candor-query calls in the session transcript
  (its true data source, NOT the gate log) and prints a clearly-labelled model: measured count vs
  the published benchmark, no fake-precise total, "model, not measured", methodology linked. 4 tests.

## Open questions

- **Pre-turn snapshot point** for the `git diff` (HEAD vs a ref stamped at turn start) — sets
  edited-units precision.
- **Default verbosity** — ship `summary` (first-run legibility) or `changes` (less fatigue)?
- **Size-scaled comparison** — the per-answer form scales by blast-radius size; the optional
  session `--estimate` would need the same to be even roughly right.
