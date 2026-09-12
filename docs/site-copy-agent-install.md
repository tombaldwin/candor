# Drop-in replacement copy for candor.poly.io — the agent install block

**Why this changes.** The live page says *"Install and map your repo by pasting one line — paste this to
your coding agent"*, and the pasted line tells the agent to **read
`https://github.com/tombaldwin/candor/blob/main/AGENTS.md` and follow it**. That asks an agent to fetch a
remote document and act on whatever it currently says: the instructions can change under the reader, can
be tampered with, and arrive from somewhere other than the thing being installed.

**Every command below was run end to end before this file was written.** A first draft of this copy led
with `candor mcp install` and `npx -y candor-ts --mcp`; both are wrong for a first-time reader —
the first needs candor already on PATH (in an *install* guide), and the second is a flag that does not
exist in the published package yet. What follows is what actually works today.

---

## USE NOW — tested against the published 0.36.1

> ### Give your agent candor
>
> Two commands, nothing to install first. Your agent asks *"what's the blast radius of this change?"* or
> *"what reaches the network?"* and gets a deterministic answer from a precomputed map, instead of
> tracing call graphs by hand.
>
> ```bash
> npx -y candor-ts . --out .candor/report                    # map the repo
> claude mcp add candor -- npx -y -p candor-ts candor-mcp    # give the agent the queries
> ```
>
> Claude Code will ask you to approve the server the next time you start it — that prompt is the point:
> nothing registers itself behind your back.
>
> Any MCP client works; point it at `npx -y -p candor-ts candor-mcp`. Already have candor installed?
> `candor mcp install` writes the same `.mcp.json` for you, and `candor mcp --help` prints the snippet —
> from the copy on your machine, not from a URL.
>
> *(`npx` covers JavaScript and TypeScript. For Rust, the JVM or Swift, install that engine — 
> `cargo install candor-scan`, the `candor-java` jar, `brew install tombaldwin/tap/candor` — then
> `candor scan .` and the same `claude mcp add` line.)*

---

## SWAP IN LATER — two changes, each only once its precondition is real

1. **The shorter server command.** After the next `candor-ts` release, `npx -y candor-ts --mcp` works and
   is tidier than `-p candor-ts candor-mcp`. It does **not** work before that: the published 0.36.1
   answers `unknown flag --mcp`. Verify with
   `printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"p","version":"0"}}}\n' | npx -y candor-ts --mcp`
   — a JSON result means it has shipped.

2. **The registry paragraph.** Only after the `mcp_registry` CI job has run (it fires on the next
   `candor-ts` tag, gated on the npm publish):

   > Your client may already know about candor: it is published to the
   > [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.tombaldwin/candor`, so MCP
   > clients and directories can discover it without anyone pasting a link.

   Publishing this before the job has run would claim a listing that does not exist. Check with
   `curl -s 'https://registry.modelcontextprotocol.io/v0/servers?search=candor'` — note that a
   *different* product, `money.candor/candor-finance`, already answers that search, so look for the
   `io.github.tombaldwin/candor` name specifically.

---

## Notes for whoever edits the page

- **Keep the scan as its own step.** The MCP server is deliberately read-only: it reads
  `.candor/report*.json` and never scans (SPEC §7.12 keeps the analyzer's self-boundary). Copy implying
  the server maps your repo would misdescribe what it does.
- `candor mcp install` backs up an existing `.mcp.json` and refuses one it cannot parse, rather than
  overwriting it.
- The written route (AGENTS.md) still works and should stay — it just should not be the first thing an
  agent is told to fetch. Once an engine is installed, `--agents` prints the same contract
  version-matched to the installed build, which a web page cannot do.
- Sixteen tools, including `candor_impact`, `candor_reachable`, `candor_where`, `candor_path`,
  `candor_callers` and `candor_whatif`.
