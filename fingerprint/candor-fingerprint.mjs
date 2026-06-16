#!/usr/bin/env node
// candor effects fingerprint — a fixed-size, text-free, DETERMINISTIC abstract mark of a project's
// effect profile, rendered from any candor engine's report. Same report -> same image.
//
//   node candor-fingerprint.mjs <report-prefix>... [options]
//
//   <report-prefix>   path to the report; reads <prefix>.json (the report) and, if present,
//                     <prefix>.callgraph.json (the call-graph sidecar all engines emit). A path
//                     ending in .json is accepted directly. Works with any engine's output:
//                       rust:  candor-scan <dir> --out <prefix>    (-> <prefix>.<crate>.scan.json)
//                       java:  candor <classes-or-jar> --json <prefix>.json
//                       ts:    candor-ts <dir> --json <prefix>.json
//                     A Rust WORKSPACE prefix is auto-resolved: if <prefix>.json is absent but
//                     <prefix>.<crate>.scan.json siblings exist, they are merged into one fingerprint.
//                     Several prefixes can be passed and are merged (one mark for the whole set).
//
//   --svg  <file>     write the SVG (default: <prefix>.fingerprint.svg)
//   --png  <file>     also write a PNG (needs a rasterizer: rsvg-convert / resvg / headless Chrome,
//                     auto-detected; set CANDOR_CHROME to point at a Chrome/Chromium binary)
//   --html <file>     write a standalone HTML wrapper (the SVG + a colour legend)
//   --size <px>       PNG/SVG pixel size (the viewBox is always 600; default 1100)
//   --json            print the fingerprint metadata (effect mix + structure/health score) to stdout
//   --no-svg          skip the SVG file (e.g. when you only want --png or --json)
//   (flags also accept --flag=value form)
//
// The SVG generation is pure, offline and deterministic — independent of the order an engine happens
// to emit callgraph keys in (node ids are sorted before layout), so the SAME logical graph yields the
// SAME image across engines and re-scans. PNG export is the only step that shells out (to a rasterizer);
// it is optional and never part of the deterministic artifact.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

const fail = (m) => { console.error("candor-fingerprint: " + m); process.exit(1); };
const warn = (m) => { console.error("candor-fingerprint: " + m); };
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// ---------------------------------------------------------------- args
const argv = process.argv.slice(2);
if (!argv.length || argv[0] === "-h" || argv[0] === "--help") {
  console.error("usage: candor-fingerprint <report-prefix>... [--svg f] [--png f] [--html f] [--size px] [--json] [--no-svg]");
  process.exit(argv.length ? 0 : 1);
}
const opts = { size: 1100 };
const positional = [];
function clampSize(v) { if (!/^\d+$/.test(v)) fail(`--size needs a non-negative integer, got "${v}"`); return Math.max(200, Math.min(4096, parseInt(v, 10))); }
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === "--") { for (let j = i + 1; j < argv.length; j++) positional.push(argv[j]); break; }  // end-of-options
  let a = argv[i], inlineVal = null;
  const eq = a.startsWith("--") ? a.indexOf("=") : -1;
  if (eq > 0) { inlineVal = a.slice(eq + 1); a = a.slice(0, eq); }
  const takeVal = (name) => {
    if (inlineVal !== null) return inlineVal;
    const nx = argv[i + 1];
    if (nx === undefined || nx.startsWith("--")) fail(`${name} requires a value`);
    return argv[++i];
  };
  if (a === "--svg") opts.svg = takeVal("--svg");
  else if (a === "--png") opts.png = takeVal("--png");
  else if (a === "--html") opts.html = takeVal("--html");
  else if (a === "--size") opts.size = clampSize(takeVal("--size"));
  else if (a === "--json") opts.json = true;
  else if (a === "--no-svg") opts.noSvg = true;
  else if (a.startsWith("--")) fail(`unknown flag ${a}`);
  else positional.push(a);
}
if (!positional.length) fail("a <report-prefix> is required");

// ---------------------------------------------------------------- load + merge reports
// Resolve a prefix to one or more report STEMS (path without `.json`): an explicit `.json`, a
// `<prefix>.json`, or — for a Rust workspace — the `<prefix>.<crate>.scan.json` siblings, merged.
function resolveStems(arg) {
  if (arg.endsWith(".json")) return [arg.replace(/\.json$/, "")];
  if (fs.existsSync(arg + ".json")) return [arg];
  const dir = path.dirname(arg), base = path.basename(arg);
  let sibs = [];
  try {
    sibs = fs.readdirSync(dir)
      .filter((f) => f.startsWith(base + ".") && f.endsWith(".scan.json") && !f.endsWith(".callgraph.json"))
      .sort();   // sort: deterministic merge order regardless of readdir order
  } catch { /* dir unreadable -> fall through to the clean not-found error below */ }
  if (sibs.length) return sibs.map((f) => path.join(dir, f.replace(/\.json$/, "")));
  return [arg];   // loadReport will emit the clean "report not found" error
}
// Read+parse a JSON file. `soft` (the optional sidecar) warns and returns null instead of exiting.
// Rejects non-regular files (a FIFO would otherwise hang the blocking read forever) and strips a BOM.
function readJson(file, what, soft) {
  const bail = (m) => { if (soft) { warn(m); return null; } fail(m); };
  let stat;
  try { stat = fs.statSync(file); } catch { return bail(`${what} not found: ${file}`); }
  if (!stat.isFile()) return bail(`${what} is not a regular file: ${file}`);
  let txt;
  try { txt = fs.readFileSync(file, "utf8"); } catch (e) { return bail(`cannot read ${what} ${file}: ${e.message}`); }
  if (txt.charCodeAt(0) === 0xFEFF) txt = txt.slice(1);
  try { return JSON.parse(txt); } catch (e) { return bail(`${what} is not valid JSON (${file}): ${e.message}`); }
}
const stems = [...new Set(positional.flatMap(resolveStems))].sort();
// the resolved input files — outputs that collide with one are REFUSED (never clobber a report).
const inputFiles = new Set(stems.flatMap((s) => [path.resolve(s + ".json"), path.resolve(s + ".callgraph.json")]));
let mergedFns = [], cg = Object.create(null);   // null-proto: a `__proto__` callgraph key is a real entry, not a setter
for (const stem of stems) {
  const rep = readJson(stem + ".json", "report");
  const part = Array.isArray(rep) ? rep : (Array.isArray(rep.functions) ? rep.functions : []);
  mergedFns = mergedFns.concat(part);
  const cgp = stem + ".callgraph.json";
  if (fs.existsSync(cgp)) {
    const parsed = readJson(cgp, "callgraph sidecar", true);
    // UNION adjacency per node, don't overwrite: merging a workspace's per-crate callgraphs, two crates
    // that share a function name (main/new/run/…) would otherwise clobber each other's edges (the later
    // crate's empty `main` erasing the earlier crate's command fan-out). Mirror the fn-dedup union.
    if (parsed && typeof parsed === "object") for (const k of Object.keys(parsed)) {
      const add = Array.isArray(parsed[k]) ? parsed[k] : [];
      if (Array.isArray(cg[k])) { for (const c of add) if (!cg[k].includes(c)) cg[k].push(c); }
      else cg[k] = add.slice();
    }
  }
}
// Dedup by fn name (UNION of inferred), so the effect mix and per-node colour are independent of report
// order and of duplicate/colliding names (engines with plain-name collisions, or the multi-prefix merge).
// Rejects entries without a string `fn` or a non-array/empty `inferred` (a non-array would be char-iterated).
const fnMap = new Map();
for (const f of mergedFns) {
  if (!f || typeof f.fn !== "string" || !Array.isArray(f.inferred) || !f.inferred.length) continue;
  const ex = fnMap.get(f.fn);
  if (ex) { for (const e of f.inferred) if (!ex.inferred.includes(e)) ex.inferred.push(e); }
  else fnMap.set(f.fn, { fn: f.fn, inferred: [...f.inferred] });
}
const fns = [...fnMap.values()];
const cgVal = (n) => { const v = cg[n]; return Array.isArray(v) ? v : []; };

// ---------------------------------------------------------------- palette
const PALETTE = [["Exec", "#ff5470"], ["Net", "#4cc4ff"], ["Db", "#ffb347"], ["Fs", "#3ce8a0"],
  ["Ipc", "#c77dff"], ["Env", "#a78bfa"], ["Clock", "#2dd4bf"], ["Rand", "#ff7ad9"],
  ["Log", "#94a3b8"], ["Clipboard", "#e0c84a"]];
const COLOR = Object.fromEntries(PALETTE), ORDER = PALETTE.map(([e]) => e);
const UNK = "#8c84b8";        // Unknown's colour — a dusty lavender-slate ("fog"), not a flat grey
const UNK_MIN = 0.01;         // single threshold for showing the Unknown territory/legend/sector

// ---------------------------------------------------------------- DNA
const inc = Object.fromEntries(ORDER.map((e) => [e, 0]));
let unkInc = 0, totInc = 0, edges = 0;
// Any effect not in the palette (e.g. a future/spec-added or language-specific effect) folds into
// Unknown rather than vanishing silently — it is "something candor saw that this tool can't name".
for (const f of fns) for (const e of f.inferred) { totInc++; if (Object.hasOwn(inc, e)) inc[e]++; else unkInc++; }
for (const v of Object.values(cg)) edges += (Array.isArray(v) ? v.length : 0);
const nNodesCg = Object.keys(cg).length || fns.length || 1;
const effs = ORDER.filter((e) => inc[e] > 0).map((e) => ({ e, c: COLOR[e], share: inc[e] / (totInc || 1) })).sort((a, b) => b.share - a.share);
const unkShare = unkInc / (totInc || 1);
const density = Math.min(1, totInc / (fns.length || 1) / 2.0);   // a tuned visual-saturation knob
const tangle = Math.min(1, edges / nNodesCg / 2.6);
const complexity = Math.min(1, (Math.log2(fns.length + 1) / 7) * 0.6 + tangle * 0.4);

// deterministic seed from the rounded effect-PROFILE DNA (same profile -> same nebula). Effects are
// delimited so two different mixes can't alias to the same string (e.g. "Db40" vs "Db4"+"0…"). NOTE: the
// raw function COUNT is deliberately NOT in the seed — FNV avalanches, so a `n${fns.length}` term made the
// whole layout re-randomize on a ±1-function edit (a project looked unrecognizable after a one-line
// change). The seed keys only the bucketed effect profile; the real call graph (which genuinely changed)
// still drives node/filament layout, so distinct projects stay distinct AND small edits degrade gracefully.
const dna = effs.map((x) => x.e + ":" + Math.round(x.share * 20)).join("|") + `|u${Math.round(unkShare * 10)}d${Math.round(density * 8)}t${Math.round(tangle * 8)}`;
let h = 2166136261 >>> 0; for (const ch of dna) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
// LCG via Math.imul so the 32-bit multiply doesn't overflow 2^53 (bit-exact, engine-portable).
let st = h || 1; const rnd = () => { st = (Math.imul(st, 1103515245) + 12345) & 0x7fffffff; return st / 0x7fffffff; };

function shade(col, f) {
  if (col[0] !== "#") return col;
  const r = parseInt(col.slice(1, 3), 16), g = parseInt(col.slice(3, 5), 16), b = parseInt(col.slice(5, 7), 16);
  const cl = (x) => Math.max(0, Math.min(255, Math.round(x))) | 0;
  return `rgb(${cl(r * f)},${cl(g * f)},${cl(b * f)})`;
}
const op = (b) => +(0.34 + density * 0.34 + b * 0.16).toFixed(2);

const CX = 300, CY = 300, DISC = 272;
const R0 = 14, RMAX = DISC - 8;
const RINGS = Math.round(24 + complexity * 22);
const spacing = Math.max(5, 11 - complexity * 6);

// ---- background: effect-mix nebula in soft spatial CLUSTERS (one colour territory per effect) ----
let base = "";
const baseOp = 0.46 + density * 0.34;
const segs = [...effs.map((x) => ({ c: x.c, share: x.share })), ...(unkShare > UNK_MIN ? [{ c: UNK, share: unkShare }] : [])];
if (!segs.length) segs.push({ c: UNK, share: 1 });
const segTot = segs.reduce((s, x) => s + x.share, 0) || 1;
const aBase = rnd() * 6.283;
const centers = segs.map((seg, si) => {
  const frac = seg.share / segTot;
  const a = aBase + si * 2.39996 + (rnd() - 0.5) * 0.4;
  const rr = si === 0 ? rnd() * RMAX * 0.16 : RMAX * (0.52 + (rnd() - 0.5) * 0.16);
  return { c: seg.c, frac, x: CX + Math.cos(a) * rr, y: CY + Math.sin(a) * rr };
});
const gauss = () => (rnd() + rnd() + rnd() - 1.5);
for (const ctr of centers) {
  const cnt = Math.max(3, Math.round(ctr.frac * 190));
  const spread = RMAX * (0.27 + ctr.frac * 0.48);
  for (let k = 0; k < cnt; k++) {
    const x = ctr.x + gauss() * spread, y = ctr.y + gauss() * spread;
    base += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(40 + rnd() * 48).toFixed(0)}" fill="${ctr.c}" opacity="${(baseOp * (0.5 + rnd() * 0.5)).toFixed(2)}"/>`;
  }
}
for (const ctr of centers.filter((c) => c.frac > 0.04).slice(0, 6)) for (let k = 0; k < 2; k++) {
  const x = ctr.x + gauss() * RMAX * 0.18, y = ctr.y + gauss() * RMAX * 0.18;
  base += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(16 + rnd() * 30).toFixed(0)}" fill="${ctr.c}" opacity="${(0.72 + rnd() * 0.25).toFixed(2)}"/>`;
}
const segCol = (x, y) => {
  const jx = x + (rnd() - 0.5) * RMAX * 0.12, jy = y + (rnd() - 0.5) * RMAX * 0.12;
  let best = centers[0], bd = 1e18;
  for (const ctr of centers) { const d = ((ctr.x - jx) ** 2 + (ctr.y - jy) ** 2) / Math.pow(ctr.frac + 0.02, 0.7); if (d < bd) { bd = d; best = ctr; } }
  return best.c;
};
// full-disc fill: a jittered grid of overlapping soft blobs (each its territory's hue) -> ZERO GAPS
let fill = "";
const GRID = 22, cell = (2 * DISC) / (GRID - 1), frad = cell * 0.95;
for (let gy = 0; gy < GRID; gy++) for (let gx = 0; gx < GRID; gx++) {
  const x = CX - DISC + gx * cell + (rnd() - 0.5) * cell * 0.6;
  const y = CY - DISC + gy * cell + (rnd() - 0.5) * cell * 0.6;
  if ((x - CX) ** 2 + (y - CY) ** 2 > (DISC + cell) ** 2) continue;
  fill += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(frad * (0.85 + rnd() * 0.4)).toFixed(1)}" fill="${segCol(x, y)}" opacity="${(0.5 + density * 0.35).toFixed(2)}"/>`;
}
// inter-ring tracery — soft blurred glints (tangle detail)
let tracery = "";
for (let l = 0; l < RINGS; l++) {
  const r = R0 + (RMAX - R0) * (l / (RINGS - 1 || 1));
  const K = Math.max(3, Math.round((2 * Math.PI * Math.max(r, 10)) / spacing));
  const hh = (RMAX - R0) / RINGS * (2.2 + rnd() * 1.3);
  if (tangle > 0.2) {
    const dd = Math.round(K * tangle * 0.28);
    for (let d = 0; d < dd; d++) {
      const a = rnd() * Math.PI * 2, rr = r + (rnd() - 0.5) * hh, tx = CX + Math.cos(a) * rr, ty = CY + Math.sin(a) * rr;
      tracery += `<circle cx="${tx.toFixed(1)}" cy="${ty.toFixed(1)}" r="${(1.6 + rnd() * 2.8).toFixed(1)}" fill="${shade(segCol(tx, ty), 0.55 + rnd() * 0.85)}" opacity="${(op(rnd()) * 0.4).toFixed(2)}"/>`;
    }
  }
}

// ---- effect-path FILAMENTS ----
const infOf = new Map(fns.map((f) => [f.fn, f.inferred]));
const peCache = new Map();
const primEff = (id) => {
  if (peCache.has(id)) return peCache.get(id);
  const inf = infOf.get(id) || [];
  const e = ORDER.find((x) => inf.includes(x)) || (inf.length ? "Unknown" : null);
  peCache.set(id, e); return e;
};
// node ids SORTED — the layout consumes the RNG in node order, so sorting makes the image independent
// of the order an engine emits callgraph keys (determinism across engines & re-scans).
const nodeIds = [...new Set([...Object.keys(cg), ...Object.values(cg).flat()])].sort();
const callers = new Map(nodeIds.map((n) => [n, []]));
for (const n of Object.keys(cg).sort()) for (const c of cgVal(n)) { if (!callers.has(c)) callers.set(c, []); callers.get(c).push(n); }
const bcache = new Map();
// blast = transitive-caller count (propagation weight). Exact distinct-ancestor counting is inherently
// O(N·E) on dense/deep graphs (the per-node flood can't share work without materializing ancestor sets),
// which HUNG on pathological inputs (a 50k ring / 200k chain). A global visit BUDGET bounds total work:
// most projects stay exact (uFlexi ~344k visits) but a few genuinely huge graphs exceed it (hibernate-core
// ~91M) and degrade to bounded, deterministic (sorted-order) APPROXIMATE weights — reported via
// `meta.blastApprox` + a stderr note so it's never silent. This is a viz weight, not an exact analysis.
const BLAST_BUDGET = 50_000_000;
let blastBudget = BLAST_BUDGET;
const blast = (n) => {
  if (bcache.has(n)) return bcache.get(n);
  const seen = new Set(), sk = [];
  for (const c of (callers.get(n) || [])) if (!seen.has(c)) { seen.add(c); sk.push(c); }  // mark-on-push
  while (sk.length && blastBudget > 0) { const x = sk.pop(); blastBudget--; for (const y of (callers.get(x) || [])) if (!seen.has(y)) { seen.add(y); sk.push(y); } }
  bcache.set(n, seen.size); return seen.size;
};
let maxB = 1; for (const id of nodeIds) maxB = Math.max(maxB, blast(id));

// ---- STRUCTURE / health score (0 bad .. 1 good): smear + Unknown haze + tangle + cycles ----
const smear = fns.filter((f) => f.inferred.filter((e) => e !== "Unknown").length >= 3).length / (fns.length || 1);
// ITERATIVE Tarjan SCC — counts nodes in non-trivial cycles. Iterative so a deep call chain (tens of
// thousands of nodes) cannot overflow the stack (the recursive form did, and the failure was silently
// swallowed into cycleRatio=0, falsely flattering big tangled graphs).
function countCyclicNodes() {
  const index = new Map(), low = new Map(), onStack = new Set(), S = [];
  let idx = 0, inCyc = 0;
  for (const root of Object.keys(cg)) {
    if (index.has(root)) continue;
    const work = [[root, 0]];
    while (work.length) {
      const frame = work[work.length - 1], v = frame[0];
      if (frame[1] === 0) { index.set(v, idx); low.set(v, idx); idx++; S.push(v); onStack.add(v); }
      const succ = cgVal(v);
      let descended = false;
      while (frame[1] < succ.length) {
        const w = succ[frame[1]++];
        if (!index.has(w)) { work.push([w, 0]); descended = true; break; }
        else if (onStack.has(w)) low.set(v, Math.min(low.get(v), index.get(w)));
      }
      if (descended) continue;
      if (low.get(v) === index.get(v)) {
        const comp = []; let w;
        do { w = S.pop(); onStack.delete(w); comp.push(w); } while (w !== v);
        if (comp.length > 1 || cgVal(v).includes(v)) inCyc += comp.length;
      }
      work.pop();
      if (work.length) { const p = work[work.length - 1][0]; low.set(p, Math.min(low.get(p), low.get(v))); }
    }
  }
  return inCyc;
}
const inCyc = countCyclicNodes();
const cycleRatio = inCyc / (nodeIds.length || 1);
const tangleExcess = Math.max(0, tangle - 0.4) / 0.6;
const structureRaw = Math.max(0, Math.min(1, 1 - (0.3 * smear + 0.26 * unkShare + 0.24 * tangleExcess + 0.2 * Math.min(1, cycleRatio * 3))));
// A degenerate input has nothing meaningful to score — report n/a rather than a flattering grade:
// no effectful functions, an empty graph, OR zero CONCRETE effects resolved (effs empty == everything is
// Unknown, e.g. a TS scan candor couldn't resolve — grading that "B" implies analysis quality that isn't there).
const degenerate = fns.length === 0 || nodeIds.length === 0 || effs.length === 0;
const structure = degenerate ? null : structureRaw;
const grade = structure === null ? "n/a"
  : structure >= 0.85 ? "A" : structure >= 0.7 ? "B" : structure >= 0.55 ? "C" : structure >= 0.4 ? "D" : "F";

// ---- node positions: effect sectors sized over EFFECTFUL nodes; pure substrate spread full-circle ----
const present = [...effs.map((x) => x.e), ...(unkShare > UNK_MIN ? ["Unknown"] : [])];
const effOrder = {}; present.forEach((e, i) => effOrder[e] = i);
const grp = new Map();
for (const id of nodeIds) { const pe = primEff(id) ?? "_pure"; if (!grp.has(pe)) grp.set(pe, []); grp.get(pe).push(id); }
const effKeys = [...grp.keys()].filter((k) => k !== "_pure").sort((a, b) => (effOrder[a] ?? 99) - (effOrder[b] ?? 99));
const effTotal = effKeys.reduce((s, k) => s + grp.get(k).length, 0) || 1;
const pos = new Map();
const radiusFor = (id, k) => DISC * Math.max(0.12, Math.min(1.0,
  0.36 + 0.63 * (1 - Math.sqrt(blast(id) / maxB)) + ((k * 0.61803) % 1) * 0.16 + (rnd() - 0.5) * 0.07));
let acc = 0;
for (const pe of effKeys) {
  const ids2 = grp.get(pe), frac = ids2.length / effTotal, a0 = acc * 6.283, a1 = (acc + frac) * 6.283; acc += frac;
  ids2.forEach((id, k) => {
    const a = a0 + ((k + 0.5) / ids2.length) * (a1 - a0) + (rnd() - 0.5) * ((a1 - a0) / Math.max(ids2.length, 1)) * (0.45 + (1 - structureRaw) * 1.1);
    const r = radiusFor(id, k);
    pos.set(id, [CX + Math.cos(a) * r, CY + Math.sin(a) * r]);
  });
}
const pureIds = grp.get("_pure") || [];
pureIds.forEach((id, k) => {
  const a = (k * 2.39996) + (rnd() - 0.5) * 0.5;
  const r = radiusFor(id, k);
  pos.set(id, [CX + Math.cos(a) * r, CY + Math.sin(a) * r]);
});

// ---- draw the threads: weighted by blast, bundled by structure, capped per-node so no hub blows out ----
const bundlePull = 0.18 + structureRaw * 0.55;
let filGlow = "", filCol = "", filWhite = "";
const fedges = [];
for (const a of Object.keys(cg).sort()) for (const b of cgVal(a)) { if (primEff(b) != null && pos.get(a) && pos.get(b)) fedges.push([a, b, blast(b)]); }
const MAXFIL = 300, CAP_SRC = 9, CAP_DST = 7;
// tiebreak on edge identity (src,dst) so cap-selection and draw order are independent of the order an
// engine emits adjacency lists in — equal-blast threads otherwise sort by push order (non-deterministic).
const byEdge = (u, v) => (u[0] < v[0] ? -1 : u[0] > v[0] ? 1 : u[1] < v[1] ? -1 : u[1] > v[1] ? 1 : 0);
fedges.sort((u, v) => (v[2] - u[2]) || byEdge(u, v));
const perSrc = new Map(), perDst = new Map();
const filDrawn = [];
for (const e of fedges) {
  if ((perSrc.get(e[0]) || 0) >= CAP_SRC || (perDst.get(e[1]) || 0) >= CAP_DST) continue;
  perSrc.set(e[0], (perSrc.get(e[0]) || 0) + 1);
  perDst.set(e[1], (perDst.get(e[1]) || 0) + 1);
  filDrawn.push(e);
  if (filDrawn.length >= MAXFIL) break;
}
const filCapped = fedges.length - filDrawn.length;
filDrawn.sort((u, v) => (u[2] - v[2]) || byEdge(u, v));
for (const [a, b, wgt] of filDrawn) {
  const pe = primEff(b), pa = pos.get(a), pb = pos.get(b), col = pe === "Unknown" ? UNK : COLOR[pe];
  const t = Math.sqrt(wgt) / Math.sqrt(maxB);
  const mx = (pa[0] + pb[0]) / 2, my = (pa[1] + pb[1]) / 2;
  const cxp = mx + (CX - mx) * bundlePull, cyp = my + (CY - my) * bundlePull;
  const wwn = 0.8 + t * 3.0, ww = wwn.toFixed(2), oo = (0.8 + t * 0.2).toFixed(2);
  const rr = 0.9 + t * 2.4, cw = Math.max(0.55, wwn * 0.5).toFixed(2);
  const d = `M ${pa[0].toFixed(1)} ${pa[1].toFixed(1)} Q ${cxp.toFixed(1)} ${cyp.toFixed(1)} ${pb[0].toFixed(1)} ${pb[1].toFixed(1)}`;
  filGlow += `<path d="${d}" fill="none" stroke="${col}" stroke-width="${(wwn + 4.5).toFixed(2)}" opacity="${(0.3 + t * 0.26).toFixed(2)}" stroke-linecap="round"/>`;
  filGlow += `<circle cx="${pb[0].toFixed(1)}" cy="${pb[1].toFixed(1)}" r="${(rr + 4).toFixed(1)}" fill="${col}" opacity="${(0.28 + t * 0.22).toFixed(2)}"/>`;
  filCol += `<path d="${d}" fill="none" stroke="${col}" stroke-width="${ww}" opacity="${oo}" stroke-linecap="round" style="mix-blend-mode:screen"/>`;
  filCol += `<circle cx="${pb[0].toFixed(1)}" cy="${pb[1].toFixed(1)}" r="${rr.toFixed(1)}" fill="${col}" opacity="${oo}" style="mix-blend-mode:screen"/>`;
  filWhite += `<path d="${d}" fill="none" stroke="#fffaf4" stroke-width="${cw}" opacity="${(0.5 + t * 0.45).toFixed(2)}" stroke-linecap="round" style="mix-blend-mode:screen"/>`;
  filWhite += `<circle cx="${pb[0].toFixed(1)}" cy="${pb[1].toFixed(1)}" r="${Math.max(0.6, rr * 0.5).toFixed(1)}" fill="#fffaf4" opacity="${(0.7 + t * 0.3).toFixed(2)}" style="mix-blend-mode:screen"/>`;
}
const domColor = effs.length ? effs[0].c : UNK;

// ---------------------------------------------------------------- assemble SVG
function buildSvg(size) {
  // No full-canvas background: only the DISC is painted, so the corners are TRANSPARENT — the fingerprint
  // is an embeddable badge that composites onto any page background. (The HTML wrapper supplies its own
  // dark page bg for the standalone preview; the disc keeps its own dark backing circle below.)
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="${size}" height="${size}">
 <defs>
  <clipPath id="disc"><circle cx="${CX}" cy="${CY}" r="${DISC}"/></clipPath>
  <filter id="neb" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="11"/></filter>
  <radialGradient id="warm" cx="50%" cy="42%" r="62%"><stop offset="0%" stop-color="#ffd089" stop-opacity="0.5"/><stop offset="55%" stop-color="#ff8a3c" stop-opacity="0.38"/><stop offset="100%" stop-color="#b83a1c" stop-opacity="0.34"/></radialGradient>
  <filter id="glow2" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="3.4"/></filter>
  <filter id="cglow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.7"/></filter>
 </defs>
 <circle cx="${CX}" cy="${CY}" r="${DISC}" fill="#05070b"/>
 <g clip-path="url(#disc)">
   <g filter="url(#neb)">${fill}</g>
   <g filter="url(#neb)">${base}</g>
   <g filter="url(#glow2)" opacity="0.45">${tracery}</g>
   <circle cx="${CX}" cy="${CY}" r="${DISC}" fill="url(#warm)" style="mix-blend-mode:soft-light" opacity="0.22"/>
   <g filter="url(#glow2)" style="mix-blend-mode:screen;isolation:isolate">${filGlow}</g>
   <g filter="url(#cglow)" style="isolation:isolate">${filCol}</g>
   <g style="mix-blend-mode:screen;isolation:isolate">${filWhite}</g>
 </g>
 <circle cx="${CX}" cy="${CY}" r="${DISC}" fill="none" stroke="${domColor}" stroke-width="1.5" opacity="0.6"/>
 <circle cx="${CX}" cy="${CY}" r="${DISC + 4}" fill="none" stroke="${domColor}" stroke-width="0.6" opacity="0.3"/>
</svg>`;
}

const name = path.basename(positional[0]).replace(/\.(json)$/, "");
const meta = {
  name,
  functions: fns.length,
  nodes: nodeIds.length,
  edges,
  effects: Object.fromEntries(effs.map((x) => [x.e, +x.share.toFixed(5)])),
  unknown: +unkShare.toFixed(5),
  density: +density.toFixed(3),
  tangle: +tangle.toFixed(3),
  complexity: +complexity.toFixed(3),
  structure: structure === null ? null : +structure.toFixed(3),
  health: { score: structure === null ? null : Math.round(structure * 100), grade, smear: +smear.toFixed(3), unknown: +unkShare.toFixed(3), tangleExcess: +tangleExcess.toFixed(3), cycleRatio: +cycleRatio.toFixed(3) },
  threads: fedges.length,
  threadsDrawn: filDrawn.length,
  threadsCapped: filCapped,
  blastApprox: blastBudget <= 0,   // true when the blast-visit budget was exhausted (weights approximate)
  seed: h,
};
if (meta.blastApprox) warn(`blast-visit budget (${BLAST_BUDGET.toLocaleString()}) exhausted on this large graph — propagation weights are approximate`);

// ---------------------------------------------------------------- PNG export (optional, shells out)
function findRasterizer() {
  const which = (c) => { const r = spawnSync(process.platform === "win32" ? "where" : "which", [c], { encoding: "utf8" }); return r.status === 0 ? (r.stdout.trim().split(/\r?\n/)[0]) : null; };
  if (which("rsvg-convert")) return { kind: "rsvg", bin: "rsvg-convert" };
  if (which("resvg")) return { kind: "resvg", bin: "resvg" };
  const chromeCandidates = [process.env.CANDOR_CHROME,
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    which("google-chrome"), which("google-chrome-stable"), which("chromium"), which("chromium-browser")].filter(Boolean);
  for (const c of chromeCandidates) if (c && fs.existsSync(c)) return { kind: "chrome", bin: c };
  return null;
}
function rasterize(svgFile, pngFile, size) {
  const rz = findRasterizer();
  if (!rz) { warn("no rasterizer found (install rsvg-convert or resvg, or set CANDOR_CHROME) — PNG skipped, SVG written"); return false; }
  try { if (fs.existsSync(pngFile)) fs.unlinkSync(pngFile); } catch { /* ignore */ }   // never report a STALE png as success
  let r;
  if (rz.kind === "rsvg") r = spawnSync(rz.bin, ["-w", String(size), "-h", String(size), "-o", pngFile, svgFile], { encoding: "utf8" });
  else if (rz.kind === "resvg") r = spawnSync(rz.bin, ["-w", String(size), "-h", String(size), svgFile, pngFile], { encoding: "utf8" });
  // --default-background-color=00000000 keeps the canvas transparent so the disc's corners stay
  // transparent in the PNG (rgba) — an embeddable badge. rsvg-convert/resvg preserve SVG alpha by default.
  else r = spawnSync(rz.bin, ["--headless", "--disable-gpu", "--no-sandbox", "--force-device-scale-factor=1", `--screenshot=${pngFile}`, `--window-size=${size},${size}`, "--default-background-color=00000000", svgFile], { encoding: "utf8", timeout: 60000 });
  if (r.error) { warn(`rasterizer (${rz.kind}) failed to launch: ${r.error.message} — PNG skipped`); return false; }
  if (r.status !== 0 || !fs.existsSync(pngFile) || fs.statSync(pngFile).size === 0) { warn(`rasterizer (${rz.kind}) produced no output — PNG skipped`); return false; }
  return true;
}

// ---------------------------------------------------------------- outputs
function writeFile(p, content, what) {
  if (inputFiles.has(path.resolve(p))) fail(`refusing to overwrite an input report with the ${what}: ${p}`);
  try { fs.writeFileSync(p, content); }
  catch (e) { fail(`cannot write ${what} to ${p}: ${e.message}`); }
}
if (opts.noSvg && !opts.png && !opts.html && !opts.json) warn("--no-svg with no --png/--html/--json: nothing to write");
const svg = buildSvg(opts.size);
const written = [];
const defaultStem = positional[0].replace(/\.json$/, "");
const svgPath = opts.noSvg ? null : (opts.svg || defaultStem + ".fingerprint.svg");
if (svgPath) { writeFile(svgPath, svg, "SVG"); written.push(svgPath); }

if (opts.png) {
  let src = svgPath, tmp = null;
  if (!src) { tmp = path.join(os.tmpdir(), `candor-fp-${h}-${process.pid}.svg`); writeFile(tmp, svg, "temp SVG"); src = tmp; }
  if (rasterize(src, opts.png, opts.size)) written.push(opts.png);
  if (tmp) try { fs.unlinkSync(tmp); } catch { /* ignore */ }
}

const legendParts = effs.map((x) => `<span style="color:${x.c}">●</span> ${x.e} ${Math.round(x.share * 100)}%`);
if (unkShare > UNK_MIN) legendParts.push(`<span style="color:${UNK}">●</span> Unknown ${Math.round(unkShare * 100)}%`);
const legend = legendParts.join("  ");
if (opts.html) {
  writeFile(opts.html, `<!doctype html><meta charset="utf-8"><title>${esc(name)} · candor fingerprint</title>
<body style="margin:0;background:#070a0e;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;font:12px ui-monospace,monospace;color:#8c84b8">
${svg}
<div style="margin-top:12px;letter-spacing:.4px">${legend}</div>
<div style="margin-top:4px;color:#3a434e">${esc(name)} · ${fns.length} fns · structure ${structure === null ? "n/a" : meta.health.score + "% (" + grade + ")"} · ${fedges.length} effect threads</div>
</body>`, "HTML");
  written.push(opts.html);
}

if (opts.json) process.stdout.write(JSON.stringify(meta, null, 2) + "\n");

const summaryParts = effs.map((x) => x.e + " " + Math.round(x.share * 100) + "%");
if (unkShare > UNK_MIN) summaryParts.push("Unknown " + Math.round(unkShare * 100) + "%");
console.error(`candor-fingerprint: ${name} — ${fns.length} effectful fns · structure ${structure === null ? "n/a" : meta.health.score + "% (" + grade + ")"} · [${summaryParts.join(", ") || "no effects"}]`
  + (filCapped > 0 ? ` · ${filDrawn.length}/${fedges.length} threads drawn` : "")
  + (written.length ? `\n  wrote: ${written.join(", ")}` : ""));
