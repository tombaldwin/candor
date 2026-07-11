# candor fix — the boundary fix (from "you crossed a boundary" to "here's where the effect belongs")

Status: **SPEC (2026-07-11).** The ambitious agent-loop capability: when an edit crosses an architecture
boundary, candor doesn't just block — it computes the *architectural fix* (where the effect should live and
the refactor to get it there) and hands that to the agent. Builds only on primitives that already ship
(`where`, `path`, `callers`, the §6.2 policy layer model); adds no new analysis.

## The problem

The edit-time loop today is **reactive and diagnostic**: after the agent's turn, it blocks once and reports
the verdict —

> `[AS-EFF-006] Pricing::quote performs { Net }, forbidden by policy: deny Net` (domain layer)
> blast radius: 16 functions transitively gained Net.

Correct, and useful. But the *fix* for a boundary violation is an **architectural refactor** — dependency
inversion / effect-hoisting — and that is precisely the thing coding agents get wrong. Told only "the domain
can't do Net," a model will often "fix" it by adding `allow Net` to the domain (defeating the boundary), or
by shuffling the I/O one call up (still inside the domain), or by threading a client handle through fifteen
signatures the wrong way. The loop makes the agent re-derive, from scratch, a design candor already has the
information to describe.

## The capability

`candor fix` answers the question the block leaves open: **"a boundary was crossed — where should this
effect live, and what is the smallest refactor that puts it there?"** It emits a concrete plan naming real
functions:

> **The fix — hoist Net out of the domain.**
> `fetch_rate()` (the Net call) sits in `Pricing::quote`, in the `domain` layer, which forbids Net.
> **Perform Net at `api::get_quote`** (the `api` layer already allows Net) and pass the result down:
> - `Pricing::quote` takes a new parameter `rate: Rate` instead of fetching it;
> - thread `rate` through the pure span it opened — `quote_bulk → OrderService::quote_* → api::get_quote`;
> - `api::get_quote` performs the fetch once and calls `quote(cart, rate)`.
> Then `Pricing::quote` and the whole domain chain go back to pure; only the `api` boundary performs Net.
> **Verify:** re-run the gate — the domain blast radius for Net should be empty.
>
> _Alternative, if the domain is meant to reach the network:_ this isn't a code bug, it's a policy one —
> relax the boundary with `allow Net pricing` (candor prints the exact line). Choose the refactor if the
> domain should stay pure; choose the policy edit if it shouldn't.

## Why candor — and only candor — can compute this

The remedy is a graph-plus-policy computation over things candor already produces:

- **the direct effect site** — `where Net 0` (functions performing Net *directly*, not inherited) ∩ the
  callees of the violating function → the actual I/O call, the thing to hoist;
- **the pure span** — `path <fn> Net` gives the chain by which the function comes to perform the effect; the
  segment of it that lies inside the forbidden layer is what must become pure (it threads the value);
- **the hoist frontier** — walk `callers` upward from the violating function to the nearest caller(s) in a
  layer the policy *allows* the effect: that is where the effect should originate;
- **the layers** — the §6.2 policy's scope patterns already assign functions to layers, and the `deny`/
  `allow` rules already say which layers may hold which effects.

No LLM guessing, no new inference: a deterministic cut between "must stay pure" (the forbidden-layer span)
and "may perform the effect" (the nearest allowed ancestor). candor is uniquely positioned because it is the
only tool that holds both the transitive effect graph *and* the architecture model at once. This is the
inverse of `whatif`: `whatif` is the forward question (*if this gained an effect, what would it reach?*);
`fix` is the remedy (*given it did and shouldn't have, where does the effect belong?*).

## The algorithm

Given a violation `(F, E, layer D)` where `D` denies `E` and `F ∈ D` performs `E`:

1. **Direct site(s) `S`** = { g ∈ transitive-callees(F) ∪ {F} : g performs E *directly* } (`where E 0`). The
   real I/O call(s).
2. **Hoist frontier `G`** = walk `callers(F)` upward; `G` = the nearest ancestor(s) whose layer *allows* E
   under the policy. (If several, present each — hoisting higher keeps more functions pure but threads
   through more signatures; candor states that trade-off.)
3. **Pure span** = the functions on the paths `S … G` that lie in `D` — these lose the effect and gain the
   threaded value/parameter.
4. **Emit** the plan: perform E at `G`; thread the produced value down the pure span into `S`; the parameter
   candor names is the value `S` currently fetches.
5. **No clean hoist** (no allowed-layer ancestor — every caller up to an entry point is also in `D`): candor
   does NOT invent a target. It states the two honest options —
   (a) **introduce a port**: make `D` depend on an *interface* parameter (a trait/protocol) it receives, so
   an adapter in an allowed layer performs E and injects it (dependency inversion — candor names the seam);
   (b) **the policy is wrong**: `D` legitimately needs E → candor prints the exact `allow E <scope>` edit.
6. **Verify** (the loop already does this): after the agent applies the refactor, the edit-time diff
   re-scans; a correct fix empties the forbidden layer's blast radius for E. A wrong one blocks again — so a
   bad suggestion can never pass silently. `fix` is advisory; the gate stays the ground truth.

## The surface (how it's delivered)

1. **`candor fix <fn> <effect> [policy]`** (a candor-query subcommand) — prints the plan; `--json` for tools.
2. **The gate verdict** (`--gate-json`) gains an optional `remedy` object per violation `{ site, hoistTo,
   pureSpan[], parameter, policyAlternative }` — machine-readable, so every consumer inherits it.
3. **The agent-loop block message** (`candor-review*.sh`) carries the plan: when the loop blocks, it hands
   the *fix*, not just the finding. This is the headline win — the agent self-corrects toward the *right*
   architecture instead of guessing.
4. **The LSP code-action / MCP `candor_fix`** — "candor: how should I fix this?" in the IDE and for the
   agent's own tool use.

## Honest limits (the disclosure ethos, applied to advice)

- **candor proposes the STRUCTURE, not the syntax.** It names the hoist target, the pure span, and the
  parameter to thread; the agent writes the code. It never mutates source — candor stays an analyzer, not an
  auto-fixer, so its soundness guarantees are untouched and a bad suggestion is caught by the re-scan.
- **The policy-relax alternative is ALWAYS offered.** Sometimes the effect belongs where it is; candor is not
  the architect, and it says so — it presents the refactor and the `allow` edit side by side and lets the
  human/agent supply the intent.
- **Ambiguity is disclosed, not hidden.** Multiple valid hoist targets → all shown with the trade-off; a
  site candor can't resolve (an `Unknown` in the chain) → said plainly, never a confident wrong plan.
- **Scope: effect-boundary hoisting only.** Not a general refactoring engine — just the one refactor candor
  uniquely has the information to compute. That narrowness is the point.
- **The port purity hierarchy** (validated by the fix-loop eval — candor-rust/eval/fixloop/DISPATCH-NOTE.md).
  For a no-clean-hoist violation the three fix shapes are NOT equivalent, and the advice says so: (1) hoisting
  the effect out and threading the value as DATA makes the layer *provably pure* (candor verifies no effect —
  clean under any policy); (2) injecting a *fn/closure* clears `deny E`/`pure` but candor can't see through the
  function, so the layer reads `Unknown` — a hole only `deny E Unknown` closes; (3) a *trait/interface* port
  does NOT clear the gate at all — candor soundly resolves the dispatch back to the effect-performing impl, so
  the layer still violates. Rejecting the trait port is correct, not a bug: treating it as clean would silently
  under-report the effect the layer reaches at runtime (the cardinal sin). The remedy leads with (1).

## Phasing

- **P1 — the engine. ✅ SHIPPED (2026-07-11).** `candor fix <prefix> <fn> <Effect> [policy] [0|1]` in
  candor-query (`src/fix.rs`): the cut algorithm + text/JSON output. `denied_layer` mirrors `whatif`'s
  violation predicate exactly; the direct site is a BFS through the effect-carrying subgraph to the direct
  source, the pure span is the affected∩denied set, the hoist frontier is the allowed-layer callers of that
  span. Ground-truth-tested on the `orderflow` worked example (Net into the domain → site `infra::fetch_rate`,
  span the two `domain` fns, hoist to `api::get_quote`) and a no-clean-hoist fixture (→ port + `allow` edit).
  Regression tests in `tests/cli.rs` pin the plan, both no-op branches, and the fail-loud contracts
  (unreadable/absent policy → exit 2). **The higher-vs-lower hoist trade-off now ships** (2026-07-11): the
  remedy carries `hoistTo` (the minimal frontier) AND `hoistHigher` — the allowed-layer transitive callers of
  the frontier that also route the effect, i.e. every place you could originate it further up; the text
  surfaces the trade-off (hoisting higher keeps the frontier pure too, at the cost of threading through more
  signatures). All four engines compute it identically (pinned by conformance PART 12b's leaf-normalized
  tuple). **The sandwiched layer is now handled** (2026-07-11): when an ALLOWED layer is CALLED BY a DENIED
  one (`D1 → A → D2 → site`), hoisting the effect to the nearest allowed frontier `A` would leave `D1` still
  inheriting it — so `cleanHoist` is now `false` (a forbidden fn calls into the frontier), and the message
  says so ("the nearest allowed layer is itself called by a forbidding layer … a forbidden layer sandwiching
  an allowed one") and offers the port/relax options rather than a misleading "hoist to A". All four engines
  detect it in the same upward climb that gathers `hoistHigher`; pinned four-way by conformance PART 12b's
  sandwiched sub-check. Remaining as-designed limit (not a soundness gap — the re-scan verifies any fix):
  "allowed" = not-denied (allow-rule *exemptions* from a deny aren't yet modelled as hoist targets).
- **P2 — the loop. ✅ SHIPPED (2026-07-11).** `candor-query fix-gate <prefix> [policy] [0|1]` (candor-query
  0.8.3): a remedy for EVERY deny/`pure` crossing in a report, collapsing the inheritors of one root cause to
  a single plan (keyed by effect/layer/site/hoist). `candor-review-source.sh` folds it into the block message
  — when the gate fails and a policy is set, the loop appends the fix under the finding, so the agent self-
  corrects toward the right architecture. Graceful no-op when candor-query is absent or can't read the
  engine's report (`CANDOR_QUERY` overrides the binary). Design note: the machine-readable remedy is emitted
  by `fix-gate --json` (`{ok, remedies[]}`) over the MERGED report, NOT bolted onto the per-member scanner's
  `--gate-json` — the hoist frontier is a whole-graph computation, so it belongs where the whole graph is
  assembled (candor-query), keeping the scanner's per-member gate simple and drift-free. Reach today is the
  candor-scan report shape (candor-review-source.sh); ts/swift/java is P3.
- **P3 — the surfaces + the reference engine. ✅ SHIPPED (2026-07-11).**
  - ✅ **MCP + wrapper** (candor-rust): `cargo candor fix <fn> <Effect>` mirrors `whatif`; `candor-mcp.py`
    gains a `candor_fix` tool (thin wrapper over `candor-query fix --json`) — the remedy is reachable to any
    MCP agent, told to it as "call this instead of guessing a fix".
  - ✅ **candor-java port** (0.8.8): native `fix` / `fix-gate` in the JVM reference engine, byte-for-byte the
    same remedy shape as candor-query (verified on real bytecode). `candor-review.sh` (the JVM edit-time
    loop) folds the plan into the block message. The cut is **site-anchored** (walks up from the direct site
    through the denied layer), so the pure span is root-independent — the same refinement landed back in
    candor-query 0.8.4 so both engines share the algorithm.
  - ✅ **candor-ts LSP code-action + MCP tool** (0.8.10): `query.mjs fix`/`fix-gate`, the `candor_fix` MCP
    tool (policy resolves from `.candor/config` like `candor_gate`), and the `candor.fix` LSP code-action —
    offered when the cursor sits in a function that actually violates the policy, alongside the existing
    whatif action. Same site-anchored cut, byte-for-byte parity with candor-query / candor-java. The VS Code
    extension picks it up on its next candor-ts server pin (bump `candorTsVersion` to ≥ 0.8.10).

## What NOT to build

- Not an **auto-applier** — candor advises, the agent (or human) edits, the gate verifies. Mutating code
  would forfeit the "analyzer, never silently wrong" contract that is candor's whole basis.
- Not a **general refactoring tool** — only the effect-boundary hoist.
- Not a **replacement for the block** — the gate still fails the build; `fix` makes the failure *actionable*,
  it never waves a violation through.
