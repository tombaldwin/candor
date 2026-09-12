# Installing candor into an agent

The old route was a line you pasted into your agent telling it to **read a URL and follow it**. That is
worth replacing on its own terms: it asks an agent to fetch a remote file and act on whatever it says,
so the instructions can change under you, can be tampered with, and arrive from somewhere other than the
thing you installed. It also only works if somebody hands you the line in the first place.

Candor's route has two halves, and neither involves fetching a document.

## 1. Discovery is passive

candor is published to the official [MCP Registry](https://registry.modelcontextprotocol.io) as
**`io.github.tombaldwin/candor`**. MCP clients and directories can find it there. Nothing tells an agent
to go and read anything; the client already knows how to list servers.

The manifest is [`server.json`](https://github.com/tombaldwin/candor-ts/blob/main/server.json) in
candor-ts — the package that hosts the server. The registry verifies namespace ownership through GitHub
OIDC plus a visible `mcp-name:` marker in the published npm README, and the publish is a CI job gated on
the npm release, so the registry entry can never point at a version that is not live.

## 2. Registration comes from the thing you installed

```bash
npx -y candor-ts --mcp        # the server itself, over stdio
candor mcp install            # write/merge .mcp.json for this repo
candor mcp --help             # print the .mcp.json snippet and the `claude mcp add` line
```

`candor mcp --help` and `candor mcp install` emit the exact registration from the binary already on your
machine. There is no remote file in the loop, and `install` is the only one that writes anything — it
backs up an existing `.mcp.json` first and refuses a file it cannot parse rather than overwriting it.

For Claude Code specifically:

```bash
claude mcp add candor -- candor mcp
```

or, project-local and portable (resolves `candor` on PATH):

```json
{ "mcpServers": { "candor": { "command": "candor", "args": ["mcp"] } } }
```

## What the agent gets

Sixteen read-only tools over a precomputed report — `candor_impact` (blast radius of a change),
`candor_reachable`, `candor_where`, `candor_path`, `candor_callers`, `candor_whatif`, the gate verdict —
answered deterministically instead of by tracing a call graph with grep.

The server never scans: it reads `.candor/report*.json`, so run `candor scan .` (or `candor init`) first.
That split is deliberate — SPEC §7.12 keeps the analyzer's self-boundary, so the server's own effect
surface is `Fs` only.

## Reading, rather than installing

[AGENTS.md](../AGENTS.md) is the written route, and it still works. But once an engine is installed,
prefer **its own** copy: every engine prints its per-language contract under `--agents`
(`candor-scan --agents`, `npx -y candor-ts --agents`, `java -jar candor-java-*-all.jar --agents`,
`candor-swift --agents`, `candor-agents --agents`), version-matched to the build you are running. A
document on the web can describe a newer candor than the one you have; `--agents` cannot.
