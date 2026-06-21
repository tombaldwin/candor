# candor fingerprint

A fixed-size, text-free, **deterministic** abstract mark of a project's effect profile, rendered from
any candor engine's report. Same report → same image. One glance tells you *what a codebase touches*
(the effect mix), *how far those effects reach* (the neon propagation threads), and *how well-structured
it is* (order vs. chaos).

![example](../assets/fingerprint-example.png)

## Usage

```sh
node candor-fingerprint.mjs <report-prefix>... [options]
```

`<report-prefix>` points at a report; the tool reads `<prefix>.json` (the report) and, if present,
`<prefix>.callgraph.json` (the call-graph sidecar every engine emits). A path ending in `.json` is
accepted directly. Produce a report with any engine:

| engine | command | report |
| --- | --- | --- |
| rust | `candor-scan <dir> --out <prefix>` | `<prefix>.<crate>.scan.json` (+ `.callgraph.json`) |
| java | `candor <classes-or-jar> --json <prefix>.json` | `<prefix>.json` (+ `.callgraph.json`) |
| ts | `candor-ts <dir> --json <prefix>.json` | `<prefix>.json` (+ `.callgraph.json`) |

**Workspaces / multiple reports.** A Rust workspace emits one report per crate
(`<prefix>.<crate>.scan.json`). Pass the bare `<prefix>` and the tool auto-discovers and **merges**
those siblings into one fingerprint — no manual merge step. You can also pass several prefixes
explicitly; they're merged into a single mark for the whole set.

### Options

| flag | effect |
| --- | --- |
| `--svg <file>` | write the SVG (default: `<prefix>.fingerprint.svg`) |
| `--png <file>` | also write a PNG (needs a rasterizer — see below) |
| `--html <file>` | write a standalone HTML wrapper (SVG + colour legend) |
| `--size <px>` | output pixel size (the viewBox is always 600; default 1100) |
| `--json` | print the fingerprint **metadata** (effect mix + structure descriptor) to stdout |
| `--baseline <prefix>` | diff the structure descriptor vs a baseline report — the **change** (trend / PR-over-PR), not an absolute number; adds a `baseline` block to `--json` + a summary line |
| `--no-svg` | skip the SVG file (e.g. when you only want `--png` or `--json`) |

Flags also accept the `--flag=value` form. A degenerate input (no effectful functions / empty graph)
reports `structure: null` rather than a flattering number.

### Examples

```sh
# SVG next to the report, plus a PNG and the metadata
node candor-fingerprint.mjs ./.candor/report.myapp.scan --png myapp.png --json

# just the structure descriptor, no image
node candor-fingerprint.mjs ./report --no-svg --json

# the CHANGE vs a baseline (e.g. main) — the deterministic-gate framing, not an absolute grade
node candor-fingerprint.mjs ./report --no-svg --baseline ./report.main
#   -> "vs ./report.main: structure -0.06 — drifted toward chaos (tangleExcess +0.04, cycleRatio +0.02)"
```

## The visual grammar

- **Background nebula** — the project's **effect mix**. Each effect owns a soft colour territory sized
  by its share; the dominant effect anchors the centre. The disc is always filled, edge to edge.
  Each effect has a fixed colour; **Unknown** (an effect candor can't resolve — reflection, dynamic
  dispatch) is a dusty lavender "fog".
- **Neon filaments** — real **effect-propagation edges** (a call that carries an effect from callee to
  caller), weighted by **blast radius** (how far the effect spreads through the call graph). They're
  white-cored and brighten where they cross; fan-in/out per node is capped so one god-object hub can't
  blow out the image.
- **Order vs. chaos** — code **structure** drives the feel. Well-structured code renders calm and
  radial; tangled, effect-smeared, or cyclic code renders chaotic and overheated.

## Metadata & the structure descriptor

`--json` emits the DNA behind the image, including a single **structure descriptor** (0–100, order vs
chaos) and its components:

```json
{
  "effects": { "Db": 0.49, "Log": 0.10, "Clock": 0.04, ... },
  "unknown": 0.35,
  "structure": 0.70,
  "structure_detail": { "value": 70,
                        "smear": 0.04, "unknown": 0.35, "tangleExcess": 0.71, "cycleRatio": 0.05 }
}
```

`structure = 1 − (0.30·smear + 0.26·unknownShare + 0.24·tangleExcess + 0.20·cycleRatio)`, where:

- **smear** — share of functions carrying ≥3 distinct effects (god-functions that do everything),
- **unknownShare** — share of effect incidences candor couldn't resolve (analysis opacity),
- **tangleExcess** — call-graph density above a baseline,
- **cycleRatio** — share of functions inside a call cycle.

All four are *structural* signals candor already computes — the descriptor just composes them. It is a
**descriptor, not a quality grade**: candor deliberately doesn't grade a codebase (spec §6.1). A
high-Unknown or naturally effect-heavy codebase reads lower without being "bad" — there is no letter
grade and no pass/fail.

## Determinism & offline

The disc has **transparent corners** (RGBA PNG / no background rect in the SVG), so it drops cleanly onto
any page as an embeddable badge — light, dark, or coloured.

SVG generation is pure, offline and deterministic, and **engine-independent**: node ids are sorted and
filament ordering is tie-broken on edge identity before layout, so the *same logical graph* yields
byte-identical SVG regardless of the order an engine happens to emit callgraph keys or adjacency lists
(verified across reversed key+adjacency order). The seed is an FNV hash of the rounded effect DNA.
**PNG export is the only step that shells out**, to a rasterizer, and is never part of the deterministic
artifact. The tool auto-detects, in order:
`rsvg-convert`, `resvg`, then a headless Chrome/Chromium (set `CANDOR_CHROME` to point at a binary). If
none is found, the SVG is still written and the PNG is skipped with a note.
