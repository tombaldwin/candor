# Drop-in replacement copy for candor.poly.io — the agent install block

**Why this changes.** The live page says *"Install and map your repo by pasting one line — paste this to
your coding agent"*, and the pasted line tells the agent to **read
`https://github.com/tombaldwin/candor/blob/main/AGENTS.md` and follow it**. That asks an agent to fetch a
remote document and act on whatever it currently says: the instructions can change under the reader, can
be tampered with, and arrive from somewhere other than the thing being installed. It also only works if
someone hands you the line.

---

## USE NOW — accurate today

> ### Install candor into your agent
>
> candor runs as an MCP server, so your agent asks *"what's the blast radius of this change?"* or
> *"what reaches the network?"* and gets a deterministic answer from a precomputed map — not from
> tracing call graphs by hand.
>
> ```bash
> candor mcp install        # writes .mcp.json for this repo
> ```
>
> Already using Claude Code? `claude mcp add candor -- candor mcp`. Any MCP client works — point it at
> `candor mcp`, or run the server directly with `npx -y candor-ts --mcp`.
>
> The registration details are printed by the copy of candor you installed (`candor mcp --help`) — there
> is no remote file to fetch, and nothing asks your agent to run something it did not choose to install.
>
> Then map the repo: `candor scan .`

---

## SWAP IN AFTER THE NEXT candor-ts RELEASE — once the registry entry is live

Add this paragraph under the commands above. **Do not publish it before the `mcp_registry` job has run**
(it fires on the next `candor-ts` tag, gated on the npm publish) — until then it would be a claim about
something that is not there yet, which is the kind of thing this page exists not to do.

> Your client may already know about candor: it is published to the
> [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.tombaldwin/candor`, so MCP
> clients and directories can discover it without anyone pasting a link.

---

## Notes for whoever edits the page

- Keep `candor scan .` as a separate step. The MCP server is deliberately read-only — it reads
  `.candor/report*.json` and never scans (SPEC §7.12 keeps the analyzer's self-boundary), so a page that
  implies the server maps your repo would be wrong about what it does.
- `candor mcp install` backs up an existing `.mcp.json` and refuses one it cannot parse, rather than
  overwriting it — worth keeping if the page mentions what it touches.
- The written route (AGENTS.md) still exists and still works; it just should not be the FIRST thing an
  agent is told to fetch. Once an engine is installed, `--agents` prints the same contract
  version-matched to the installed build, which a web page cannot do.
- Sixteen tools are exposed, including `candor_impact`, `candor_reachable`, `candor_where`,
  `candor_path`, `candor_callers` and `candor_whatif`.
