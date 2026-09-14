# Drop-in replacement copy for candor.poly.io — the agent install block

**Why this changes.** The live page says *"Install and map your repo by pasting one line — paste this to
your coding agent"*, and the pasted line tells the agent to **read
`https://github.com/tombaldwin/candor/blob/main/AGENTS.md` and follow it**. That asks an agent to fetch a
remote document and act on whatever it currently says: the instructions can change under the reader, can
be tampered with, and arrive from somewhere other than the thing being installed.

**Every command below was run end to end before this file was written**, and re-run against 0.38.0 on
2026-09-14. A first draft of this copy led with `candor mcp install` and `npx -y candor-ts --mcp`; both
were wrong for a first-time reader at the time — the first needs candor already on PATH (in an *install*
guide), and the second was a flag the published package did not have. One of those two has since
shipped and is used below; see **What changed since the first draft**.

---

## USE NOW — tested against the published 0.38.0

> ### Give your agent candor
>
> Two commands, nothing to install first. Your agent asks *"what's the blast radius of this change?"* or
> *"what reaches the network?"* and gets a deterministic answer from a precomputed map, instead of
> tracing call graphs by hand.
>
> ```bash
> npx -y candor-ts . --out .candor/report          # map the repo
> claude mcp add candor -- npx -y candor-ts --mcp  # give the agent the queries
> ```
>
> Claude Code will ask you to approve the server the next time you start it — that prompt is the point:
> nothing registers itself behind your back.
>
> Any MCP client works; point it at `npx -y candor-ts --mcp`. Already have candor installed?
> `candor mcp install` writes the same `.mcp.json` for you, and `candor mcp --help` prints the snippet —
> from the copy on your machine, not from a URL.
>
> Your client may already know about candor: it is published to the
> [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.tombaldwin/candor`, so MCP
> clients and directories can discover it without anyone pasting a link.
>
> *(`npx` covers TypeScript out of the box; for a **JavaScript** repo add `--allow-js` to the scan line.
> For Rust, the JVM or Swift, install that engine — `cargo install candor-scan`, the `candor-java` jar,
> `brew install tombaldwin/tap/candor` — then `candor scan .` and the same `claude mcp add` line.)*

---

## What changed since the first draft — both deferred items have landed

Both were written as "SWAP IN LATER, only once its precondition is real". Both preconditions are now
real, verified by running them rather than by assuming the release implied them:

1. **The shorter server command is in.** `npx -y candor-ts --mcp` answers a real `initialize` result on
   0.38.0, so the copy above uses it instead of `-p candor-ts candor-mcp`. The longer form still works
   and is not wrong — it is just noisier. Re-verify after any release with:
   `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"p","version":"0"}}}\n' | npx -y candor-ts --mcp`
   — a JSON result means it has shipped.

2. **The registry paragraph is in.** The blocker was measured and is gone: the 0.36.2 publish was
   REFUSED with `NPM package 'candor-ts' is missing required 'mcpName' field` — npm verifies namespace
   ownership from a `mcpName` field in `package.json`, while the `mcp-name:` README marker is the
   *crates.io* convention and had been copied across without checking it transfers. npm does not allow
   republishing a version, so the listing could only land with a later release. It has:
   `curl -s 'https://registry.modelcontextprotocol.io/v0/servers?search=candor'` now returns
   `io.github.tombaldwin/candor` at 0.37.0 and 0.38.0. Note a *different* product,
   `money.candor/candor-finance`, also answers that search — look for the `io.github.tombaldwin` name
   specifically.

## Two corrections to the previous draft, both found by re-running its own commands

- **`npx` does not cover plain JavaScript without a flag.** The old parenthetical said it "covers
  JavaScript and TypeScript". Measured: a JS-only repo answers
  `candor-ts: no TypeScript sources under .` and exits **2** with no report — the paste-line silently
  does nothing for a JavaScript reader. `--allow-js` fixes it, and the copy above says so.
- **SPEC §7.12 does not exist and never did.** The note below cited it for the server's read-only
  boundary. The read-only query surface is **§3.1**, and §7's conformance item 10 points at §3.1/§3.2.
  A section number in public copy is a pin like any other: resolve it, do not carry it forward.

---

## Notes for whoever edits the page

- **Keep the scan as its own step.** The MCP server is deliberately read-only: it reads
  `.candor/report*.json` and never scans (SPEC §3.1 — a written report plus its call-graph sidecar
  answers structural questions *without re-analysis*). Copy implying the server maps your repo would
  misdescribe what it does.
- `candor mcp install` backs up an existing `.mcp.json` and refuses one it cannot parse, rather than
  overwriting it.
- The written route (AGENTS.md) still works and should stay — it just should not be the first thing an
  agent is told to fetch. Once an engine is installed, `--agents` prints the same contract
  version-matched to the installed build, which a web page cannot do.
- **Sixteen tools**, verified against 0.38.0's `tools/list`: `candor_activity`, `candor_blindspots`,
  `candor_callers`, `candor_containment`, `candor_diff`, `candor_fix`, `candor_gains`, `candor_gate`,
  `candor_impact`, `candor_map`, `candor_path`, `candor_reachable`, `candor_show`, `candor_unverified`,
  `candor_whatif`, `candor_where`. If the page names a subset, `candor_impact`, `candor_reachable` and
  `candor_where` are the ones worth naming.
