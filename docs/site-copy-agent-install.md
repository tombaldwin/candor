# Drop-in replacement copy for candor.poly.io — the agent install block

> **READ THIS FIRST — what to publish.**
>
> **Publish only the blockquoted text in “§1 THE COPY” (and “§1b” if you want the second block).** That is the page content. Everything from
> “§2 BACKGROUND” onward is working notes for whoever maintains this file — the measurements behind the
> copy, and a record of claims that turned out to be false. **None of §2 goes on the site.**
>
> The code blocks inside §1 are commands a reader will paste. Reproduce them **verbatim** — every one has
> been run end to end, and the flags are load-bearing (`-y`, `--allow-js`, the exact `claude mcp add`
> form). If a command looks redundant, it is not; check §2 before trimming it.
>
> If anything in §1 contradicts what the live product does, the product wins and this file is stale —
> say so rather than publishing it.

**Why this changes.** The live page says *"Install and map your repo by pasting one line — paste this to
your coding agent"*, and the pasted line tells the agent to **read
`https://github.com/tombaldwin/candor/blob/main/AGENTS.md` and follow it**. That asks an agent to fetch a
remote document and act on whatever it currently says: the instructions can change under the reader, can
be tampered with, and arrive from somewhere other than the thing being installed.

**Every command below was run end to end before this file was written**, and re-run against the
published **0.38.1** on 2026-09-15 — on a Rust, a TypeScript, a JVM and a Swift project, not just one,
each from a completely empty engine cache.

*What a reader actually installs today:* `brew install` gives the **0.38.1** umbrella, which pins the
engines at **0.38.0** with **rust at 0.38.1** (a one-engine patch). `candor doctor` shows that split and
calls it a deliberate pin rather than drift.

---

## §1 THE COPY — publish this. Tested against the published 0.38.1

The whole path, from nothing installed to an agent that can answer. Three lines, one paste, no choices
to make on the way.

> ### Give your agent candor
>
> ```bash
> brew install tombaldwin/tap/candor   # install candor
> candor scan .                        # map the repo (Rust: builds the engine, see below)
> candor mcp install                   # give the agent the queries
> ```
>
> Your agent asks *"what's the blast radius of this change?"* or *"what reaches the network?"* and gets a
> deterministic answer from a precomputed map, instead of tracing call graphs by hand.
>
> Claude Code will ask you to approve the server the next time you start it — that prompt is the point:
> nothing registers itself behind your back.
>
> **Any language.** `candor scan` picks the engine from the manifest — Rust, the JVM, Swift or
> TypeScript — and `candor mcp` reads whatever engine's report is in `.candor/`. The three commands are the
> same for every language; what differs is what line 2 has to fetch or build (see the two notes below).
>
> Any MCP client works; point its server config at `candor mcp`. `candor mcp --help` prints the snippet —
> from the copy on your machine, not from a URL.
>
> **Rust today:** `candor-rust` publishes no release binaries yet, so on a Rust crate line 2 builds the
> engine with `cargo` (~50s, needs a Rust toolchain). Every other language fetches a native binary.
>
> **Swift on Linux:** the Swift engine ships as a macOS arm64 binary only. The CLI runs on Linux, and the
> JVM, Rust and TypeScript engines work there — a Swift package needs a Mac, or candor-swift built from
> source. `candor scan` says so rather than failing quietly.
>
> Your client may already know about candor: it is published to the
> [MCP Registry](https://registry.modelcontextprotocol.io) as `io.github.tombaldwin/candor`, so MCP
> clients and directories can discover it by that exact ID without anyone pasting a link. Search by the
> bare word "candor" and an unrelated `money.candor/candor-finance` comes back too, so name the ID.

**Homebrew 7 requires third-party taps to be TRUSTED, and the page should say so.** Verified on
Homebrew 7.0.1: `brew trust tombaldwin/tap` followed by `brew install tombaldwin/tap/candor` installs
candor cleanly (0.38.1 as of 2026-09-15). Without it, brew refuses with a message naming whichever tap is untrusted — on a
machine that already has any other third-party tap, the name in that message is **that other tap**, not
ours, which makes the failure read as unrelated to candor. Brew prints the remedy itself
(`brew trust <tap>`), so this is a note for the page rather than a fourth command in the block:

> *(On Homebrew 7 or newer, run `brew trust tombaldwin/tap` first — Homebrew now asks you to trust a
> third-party tap before installing from it.)*

**What "fetches the engine it needs" is true of, exactly.** Measured on a machine with nothing
installed, one language at a time:

| language | what `candor scan .` needs from the reader |
| --- | --- |
| JVM | **nothing** — fetches a native binary, no JVM required |
| Swift | **nothing** on macOS arm64 — fetches a native binary, no Swift toolchain |
| TypeScript | **Node**, which the reader already has if this is their repo; the engine runs via `npx` |
| Rust | **cargo today, and still today.** The binaries workflow exists and is green, but `v0.38.1` shipped *without* assets — the tag predates the workflow, and a workflow is read from the ref it runs on. So the fetch 404s and falls back to a source build (~50s, with progress). It joins the JVM and Swift rows at the next candor-rust release, **not** at "the next release" — an earlier draft of this row said that, 0.38.1 came and went, and the row was wrong the moment it shipped. |

Neither remaining prerequisite is one a reader in that language is likely to lack — a Rust developer has
cargo and a Node developer has Node — and both now fail with a remedy that works (`https://rustup.rs`,
"install Node") rather than the old loop that advised a command which would skip again. **Do not write
"no prerequisites" on the page until the Rust row says "nothing"**; that is one release away, not
shipped.

**`candor update` is deliberately NOT in this block, and that is a recent change.** The formula installs
only the dispatcher (`bin.install "bin/candor"`), so something has to fetch an engine — but `candor scan`
now does it itself, for all four languages, announcing what it is fetching and from where. It pulls the
ONE engine that repo needs rather than all four. `candor update` is the *existing-user* command: it syncs
the whole family to a new pin after `brew upgrade candor`. Putting it in the install block made a
first-time reader download three engines they may never use, to fix a problem they did not have.

**If they can't use Homebrew**, a single engine still works standalone — `npx -y candor-ts . --out
.candor/report` for TypeScript (add `--allow-js` for JavaScript), `cargo install candor-scan` for Rust,
the `candor-java` jar for the JVM — and `npx -y candor-ts --mcp` serves any engine's report. Keep this
as a footnote, not a second route.

---

## §1b OPTIONAL — a second block, if the page wants a next step

Once the agent can query the map, the other half of candor is the gate. **`candor init` is now worth
linking**, which it was not before 2026-09-15 — it had two defects that made its first run fail, and both
are fixed:

> ```bash
> candor init          # propose a policy from what the code already does, record a baseline, write CI
> ```
>
> Every rule it proposes passes today, so adopting it is safe; what it catches is the *next* change. It
> also writes `.candor/run` — the gate as one command — and a CI workflow.

Verified on 2026-09-15 across all four engines, in both directions, which is the claim that matters for a
gate: a freshly initialised project's first `.candor/run` exits **0**, and a formerly-pure function that
gains `Fs` fails it with `AS-EFF-005`, exit 1.

| engine | first run | after a regression |
| --- | --- | --- |
| TypeScript | 0 | exit 1 |
| Rust | 0 | exit 1 |
| JVM | 0 | exit 1 |
| Swift | 0 | exit 1 |

*(Both TypeScript and the JVM used to exit **2** on that first run — one from a rule-less proposed policy
being wired anyway, one from assuming Maven. Do not link `init` from any page built before this date
without re-checking it.)*

## §2 BACKGROUND — NOT for the page

### What changed since the first draft — both deferred items have landed

A first draft led with `candor mcp install` and `npx -y candor-ts --mcp`; both were wrong for a
first-time reader at the time — the first needs candor already on PATH (so it belongs under a route that
says so, which it now does), and the second was a flag the published package did not have (it has since
shipped, and is used below).

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

### Three corrections to the previous draft

The first was a review catch; the other two came from re-running the draft's own commands.

- **It offered the reader a choice, and it read as a TypeScript tool.** Both headline commands were
  `candor-ts`, every other language sat in an italic parenthetical ending "…then `candor scan .` and the
  same `claude mcp add` line", and a later draft turned that into two labelled routes — which is worse:
  a reader who has to pick a route has already stopped reading, and the install steps were still not in
  the block. It is now one paste that starts from nothing installed. The
  parenthetical was *true* — reports are engine-agnostic, and candor-ts's MCP server does read a Rust
  report (measured: `candor_where Exec` → `{"directly":["fetch"]}` against a `candor-scan` report) — but
  telling someone who just ran `cargo install candor-scan` to invoke an **npm package** for the server is
  the wrong shape, and burying three of four engines in an aside misrepresents what candor is. The two
  routes are now peers, and Route A names no language at all. Verified on all four:
  `candor scan .` → `candor-scan` on a Rust crate, `candor-ts` on a TS project, `candor-java` on compiled
  classes (`Fs 1`, 1 entry), `candor-swift` on an SPM package — then `candor mcp` served each report.

- **`npx` does not cover plain JavaScript without a flag.** The old parenthetical said it "covers
  JavaScript and TypeScript". Measured: a JS-only repo answers
  `candor-ts: no TypeScript sources under .` and exits **2** with no report — the paste-line silently
  does nothing for a JavaScript reader. `--allow-js` fixes it, and the copy above says so.
- **SPEC §7.12 does not exist and never did.** The note below cited it for the server's read-only
  boundary. The read-only query surface is **§3.1**, and §7's conformance item 10 points at §3.1/§3.2.
  A section number in public copy is a pin like any other: resolve it, do not carry it forward.

---

### Notes for whoever edits the page

- **Keep the scan as its own step.** The MCP server is deliberately read-only: it reads
  `.candor/report*.json` and never scans (SPEC §3.1 — a written report plus its call-graph sidecar
  answers structural questions *without re-analysis*). Copy implying the server maps your repo would
  misdescribe what it does.
- `candor mcp install` backs up an existing `.mcp.json` and refuses one it cannot parse, rather than
  overwriting it.
- The written route (AGENTS.md) still works and should stay — it just should not be the first thing an
  agent is told to fetch. Once an engine is installed, `--agents` prints the same contract
  version-matched to the installed build, which a web page cannot do.
- **Sixteen tools**, verified by calling every one of them against a real report on 2026-09-15 — and
  the gate among them checked in BOTH directions, since a tool that only ever answers `ok` is not
  evidence. Names from `tools/list`: `candor_activity`, `candor_blindspots`,
  `candor_callers`, `candor_containment`, `candor_diff`, `candor_fix`, `candor_gains`, `candor_gate`,
  `candor_impact`, `candor_map`, `candor_path`, `candor_reachable`, `candor_show`, `candor_unverified`,
  `candor_whatif`, `candor_where`. If the page names a subset, `candor_impact`, `candor_reachable` and
  `candor_where` are the ones worth naming.
