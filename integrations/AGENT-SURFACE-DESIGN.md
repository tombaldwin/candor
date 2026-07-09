# The next agent-loop bet — one candor core, two delivery surfaces

Status: **partially shipped** — bet 1 (`candor-mcp`) shipped 2026-07-02; bet 2 (`candor-lsp`) P1
shipped 2026-07-02, P2 slices open (VS Code client, whatif code-action, large-repo lens performance);
both published on npm in candor-ts. Historical design below.

Decision (Tom, 2026-07-02): the recommended sequence — and bet 1 is BUILT. The unified
`candor-mcp` ships in the candor-ts package (the read layer was already engine-agnostic, so the "core
extraction" collapsed to enrichment): five new tools (gate / containment / blindspots / diff / gains),
MCP resources (report + checked-in policy), `.candor/config` policy discovery for `candor_gate`, the
`candor-mcp` bin alias, default-prefix discovery; verified serving all four engines' real reports through
one server; the rust python server carries a deprecation pointer. **Bet 2 (the LSP) — P1 SHIPPED same day too:**
`candor-lsp` (candor-ts pkg, new bin) — CodeLens `⚡ effects · blast radius N` per effectful fn +
the live §6.2 gate verdict as diagnostics (config-discovered policy), over the same read layer; verified
against candor-ts AND candor-java reports (bare bytecode locs resolve via package segments); freshness by
re-reading reports per request (watch/stop-hook/build refresh the lenses; the server never scans, §7.12).
Editor wiring documented for helix/neovim (native LSP clients). Remaining P2 slices: a thin VS Code client
extension, the `whatif` code-action, large-repo lens performance. (Hover provenance SHIPPED 2026-07-02:
the path hop chain per inherited effect + unknownWhy/invisible disclosure + the blast-radius count.)
Original scoping below.

## What exists today (the inventory that changes the picture)

The "MCP push" is not greenfield, and the pieces are further along than the backlog line suggests:

| Piece | Where | State |
|---|---|---|
| MCP server (TS) | `candor-ts/mcp.mjs` (`candor-ts-mcp`, npm) | 8 tools: impact / where / reachable / path / callers / show / map / whatif — with the name-match ladder + not-found handling done right |
| MCP server (Rust) | `candor-rust/integrations/mcp/candor-mcp.py` | 5 tools: effects / where / callers / whatif / diff — a thin wrapper over `candor-query` |
| Freshness loop | `candor-ts/watch.mjs` (`candor-ts-watch`) | content-hash watcher → rescan on real change, so the MCP serves *live* ground truth ("roadmap #1, the freshness half") |
| Edit-time gate | `integrations/claude-code/` stop-hook | ships; blocks-once with gained effects + blast radius |
| Machine verdict | `--gate-json` (spec 0.8, all four engines) | `{ok, violations:[{rule,fn,effects}]}` |
| Config | `.candor/config` (spec §3.4, all four engines) | target-anchored discovery — a consumer can find the repo's policy/baseline with zero wiring |

Two problems with the current shape: the two MCP servers are **per-engine and divergent** (different
tool sets, different plumbing, a JVM/Swift user has neither), and **neither exposes the newest, most
gate-relevant surfaces** — the `--gate-json` verdict, `containment`, `blindspots`, `gains`.

## The shared insight

Both candidate bets consume exactly the same thing: **the spec-0.8 report envelope + its sidecars**
(report / callgraph / hierarchy) plus the §6.2 policy and §3.4 config. That consumption layer is already
proven engine-agnostic twice — `candor-sarif` (report + verdict → SARIF, incl. the bytecode `loc` →
repo-path resolution) and the stop-hook's review scripts (the effect delta computed from the envelope).

So the work is **one core, two surfaces**:

```
                  ┌────────────────────────────────────────────────┐
  report set ───► │  candor-core (read layer, engine-agnostic)     │
  callgraph  ───► │  · fn-match ladder (§3.1)  · loc→path (sarif)  │
  hierarchy  ───► │  · callers/impact/path/whatif over sidecars    │
  .candor/config ►│  · gate verdict + policy parse  · watch/fresh  │
                  └───────┬───────────────────────────┬────────────┘
                          ▼                           ▼
                 candor-mcp (bet 1)            candor-lsp (bet 2)
                 tools for ANY MCP agent       CodeLens/hover/diagnostics
```

## Bet 1 — unify + enrich the MCP surface (days, direct north-star)

One **`candor-mcp`** (Node, npm — the TS server is the better base and npm is the family's existing
channel) that supersedes both per-engine servers:

- **Engine-agnostic:** reads any spec-0.7/0.8 report set under a prefix (the envelope is the contract),
  exactly like candor-sarif. One server for JVM/Rust/TS/Swift — the "one spec" moat, applied to MCP.
- **Full tool set:** today's 8 + `gate` (the `--gate-json` verdict — "is this repo passing its policy,
  and what exactly fails"), `containment`, `blindspots`, `gains`, `diff`. The gate verdict is the big
  add: an agent can ask *"would my edit pass CI?"* without running CI.
- **Resources, not just tools:** expose the report + policy as MCP resources so a capable agent reads
  the map directly instead of twenty tool calls.
- **Freshness:** generalize `watch.mjs` — scan-source engines rescan on content change (proven); the
  JVM watches the classes dir and refreshes on build (stale-until-build is honest and disclosed via the
  report's own provenance header).
- **Discovery:** `.candor/config` makes setup near-zero — point the server at a repo, it finds the
  report prefix/policy the way the engines do. (Open item: the §config vocabulary may want a `scan`
  key naming the refresh command; flag for a future amendment, not needed for v1.)

Effort: the TS server is 205 lines and the core queries exist in `query-core.mjs`; this is **days**,
mostly extraction + the new tools + tests. Payoff: every MCP-speaking agent (Claude Code, and the
growing rest) gets deterministic blast-radius/whatif/gate answers on all four languages.

## Bet 2 — the LSP (weeks, the ambient human surface)

`candor-lsp` over the same core, VS Code client first:

- **CodeLens per function:** `⚡ reaches {Db, Net} · blast radius 12` — the report, rendered where the
  code is. This is the "always-on ambient signal" the backlog describes.
- **Hover:** effect provenance — the `path` query's hop chain ("reaches Db via billing.charge → …").
- **Diagnostics:** the `--gate-json` verdict as squiggles at the violating fn's `loc` (the same
  fn→file:line resolution candor-sarif ships); the policy gate live in the editor, not just CI.
- **Code action:** *"what if this gained Net?"* → `whatif` (the pre-edit verdict, §3.2).
- **Freshness:** same watch story as bet 1; for the JVM the lens is labelled with the report's build
  provenance (§2.1) so a stale map is visibly stale — disclosure applied to the UI.

Effort: **weeks** — the LS protocol skeleton is mechanical, but editor UX (lens density, large-repo
performance, position mapping at scale) is a real tail. Distribution: VS Code marketplace + a bare LS
binary for other editors.

## Recommendation

**Sequence, don't choose: core → MCP (now) → LSP (next), all three on the same read layer.**

- Bet 1 is small, serves the *stated north-star directly* (agents), retires two divergent per-engine
  servers, and productizes the newest surfaces (gate verdict) the week they shipped.
- Bet 2 reuses everything bet 1 builds; starting with it instead would spend weeks before any agent
  sees a benefit, and the LSP's hardest problems (freshness, position mapping) get de-risked by bet 1
  in the meantime.
- If bet 2 is deferred indefinitely, bet 1 still stands alone; the reverse is not true.

## Open questions (before bet 1 starts)

1. **Home — RESOLVED:** it stays in the candor-ts package (the read layer lives there as
   `query-core.mjs`, one source of truth with the CLI; a separate package would fork it). The unified
   name ships as the `candor-mcp` bin alias.
2. **Deprecation — RESOLVED:** `candor-ts-mcp` stays as a compat alias; the rust python server carries
   a deprecation banner for one release cycle.
3. **The §config `scan` key** (the refresh command per repo) — a v1.1 amendment candidate, not v1.
4. **candor-agents** (the fleet engine) — its reports are the same envelope; the unified server
   should read them for free, worth a test.

*The go/no-go — and the choice of sequence vs LSP-first — is Tom's; this doc exists so the decision has
concrete shapes and costs.*
