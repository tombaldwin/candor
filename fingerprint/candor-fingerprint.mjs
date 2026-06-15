#!/usr/bin/env node
// candor effects fingerprint — a fixed-size, text-free, DETERMINISTIC abstract mark of a project's
// effect profile, rendered from any candor engine's report. Same report -> same image.
//
//   node candor-fingerprint.mjs <report-prefix> [options]
//
//   <report-prefix>   path to the report; reads <prefix>.json (the report) and, if present,
//                     <prefix>.callgraph.json (the call-graph sidecar all engines emit). A path
//                     ending in .json is accepted directly. Works with any engine's output:
//                       rust:  candor-scan <dir> --out <prefix>    (-> <prefix>.<crate>.scan.json)
//                       java:  candor <classes-or-jar> --json <prefix>.json
//                       ts:    candor-ts <dir> --json <prefix>.json
//
//   --svg  <file>     write the SVG (default: <prefix>.fingerprint.svg)
//   --png  <file>     also write a PNG (needs a rasterizer: rsvg-convert / resvg / headless Chrome,
//                     auto-detected; set CANDOR_CHROME to point at a Chrome/Chromium binary)
//   --html <file>     write a standalone HTML wrapper (the SVG + a colour legend)
//   --size <px>       PNG/SVG pixel size (the viewBox is always 600; default 1100)
//   --json            print the fingerprint metadata (effect mix + structure/health score) to stdout
//   --no-svg          skip the SVG file (e.g. when you only want --png or --json)
//
// The SVG generation is pure, offline and deterministic. PNG export is the only step that shells out
// (to a rasterizer); it is optional and never part of the deterministic artifact.
//
// What it encodes (the visual grammar):
//   • background nebula  = the project's effect MIX — each effect a soft colour territory sized by its
//                          share (Unknown = lavender "fog"); the disc is always filled, zero gaps.
//   • neon filaments     = real effect-propagation edges (a call that carries an effect), weighted by
//                          BLAST RADIUS (how far the effect spreads); white-cored, brightening where
//                          they cross. Capped/​fanned so one god-object hub can't blow out.
//   • order vs chaos     = code STRUCTURE drives the feel — well-structured code renders calm and
//                          radial, tangled/​smeared/​cyclic code renders chaotic and overheated.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

// ---------------------------------------------------------------- args
const argv = process.argv.slice(2);
if (!argv.length || argv[0] === "-h" || argv[0] === "--help") {
  console.error("usage: candor-fingerprint <report-prefix> [--svg f] [--png f] [--html f] [--size px] [--json] [--no-svg]");
  process.exit(argv.length ? 0 : 1);
}
const opts = { size: 1100 };
const positional = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--svg") opts.svg = argv[++i];
  else if (a === "--png") opts.png = argv[++i];
  else if (a === "--html") opts.html = argv[++i];
  else if (a === "--size") opts.size = Math.max(200, Math.min(4096, parseInt(argv[++i], 10) || 1100));
  else if (a === "--json") opts.json = true;
  else if (a === "--no-svg") opts.noSvg = true;
  else if (a.startsWith("--")) { console.error(`candor-fingerprint: unknown flag ${a}`); process.exit(1); }
  else positional.push(a);
}
const arg = positional[0];
if (!arg) { console.error("candor-fingerprint: a <report-prefix> is required"); process.exit(1); }

const repPath = arg.endsWith(".json") ? arg : arg + ".json";
if (!fs.existsSync(repPath)) { console.error(`candor-fingerprint: report not found: ${repPath}`); process.exit(1); }
const stem = repPath.replace(/\.json$/, "");
const rep = JSON.parse(fs.readFileSync(repPath, "utf8"));
const all = Array.isArray(rep) ? rep : rep.functions || [];
const fns = all.filter((f) => (f.inferred || []).length);
const cgPath = stem + ".callgraph.json";
const cg = fs.existsSync(cgPath) ? JSON.parse(fs.readFileSync(cgPath, "utf8")) : {};

// ---------------------------------------------------------------- palette
const PALETTE = [["Exec", "#ff5470"], ["Net", "#4cc4ff"], ["Db", "#ffb347"], ["Fs", "#3ce8a0"],
  ["Ipc", "#c77dff"], ["Env", "#a78bfa"], ["Clock", "#2dd4bf"], ["Rand", "#ff7ad9"],
  ["Log", "#94a3b8"], ["Clipboard", "#e0c84a"]];
const COLOR = Object.fromEntries(PALETTE), ORDER = PALETTE.map(([e]) => e);
const UNK = "#8c84b8";   // Unknown's colour — a dusty lavender-slate ("fog"), not a flat grey

// ---------------------------------------------------------------- DNA
const inc = Object.fromEntries(ORDER.map((e) => [e, 0]));
let unkInc = 0, totInc = 0, edges = 0;
for (const f of fns) for (const e of f.inferred) { if (e === "Unknown") { unkInc++; totInc++; } else if (e in inc) { inc[e]++; totInc++; } }
for (const v of Object.values(cg)) edges += (v || []).length;
const nNodesCg = Object.keys(cg).length || all.length || 1;
const effs = ORDER.filter((e) => inc[e] > 0).map((e) => ({ e, c: COLOR[e], share: inc[e] / (totInc || 1) })).sort((a, b) => b.share - a.share);
const unkShare = unkInc / (totInc || 1);
const density = Math.min(1, totInc / (fns.length || 1) / 2.0);
const tangle = Math.min(1, edges / nNodesCg / 2.6);
const complexity = Math.min(1, (Math.log2(fns.length + 1) / 7) * 0.6 + tangle * 0.4);

// deterministic seed from the rounded DNA (same profile -> same fingerprint)
const dna = effs.map((x) => x.e + Math.round(x.share * 40)).join("") + `u${Math.round(unkShare * 20)}d${Math.round(density * 10)}t${Math.round(tangle * 10)}n${fns.length}`;
let h = 2166136261 >>> 0; for (const ch of dna) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619) >>> 0; }
let st = h || 1; const rnd = () => (st = (st * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;

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

// ---- background: effect-mix nebula in soft spatial CLUSTERS (one territory per effect) ----
let base = "";
const baseOp = 0.46 + density * 0.34;
const segs = [...effs.map((x) => ({ c: x.c, share: x.share })), ...(unkShare > 0.01 ? [{ c: UNK, share: unkShare }] : [])];
if (!segs.length) segs.push({ c: UNK, share: 1 });
const segTot = segs.reduce((s, x) => s + x.share, 0) || 1;
const aBase = rnd() * 6.283;
const centers = segs.map((seg, si) => {
  const frac = seg.share / segTot;
  // dominant (si 0) near centre; others pushed out to a ring (golden-angle spaced) so clusters separate
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
// bright glowing cores — a saturated hotspot per significant cluster (vivid depth)
for (const ctr of centers.filter((c) => c.frac > 0.04).slice(0, 6)) for (let k = 0; k < 2; k++) {
  const x = ctr.x + gauss() * RMAX * 0.18, y = ctr.y + gauss() * RMAX * 0.18;
  base += `<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="${(16 + rnd() * 30).toFixed(0)}" fill="${ctr.c}" opacity="${(0.72 + rnd() * 0.25).toFixed(2)}"/>`;
}
// colour at a point = the SHARE-WEIGHTED nearest cluster (a high-share effect claims more area)
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
// inter-ring tracery — soft blurred glints (tangle detail, folded into the bloom blur)
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
const primEff = (id) => { const inf = infOf.get(id) || []; return ORDER.find((e) => inf.includes(e)) || (inf.includes("Unknown") ? "Unknown" : null); };
const nodeIds = [...new Set([...Object.keys(cg), ...Object.values(cg).flat()])];
const callers = new Map(nodeIds.map((n) => [n, []]));
for (const [n, cs] of Object.entries(cg)) for (const c of cs) { if (!callers.has(c)) callers.set(c, []); callers.get(c).push(n); }
const bcache = new Map();
const blast = (n) => { if (bcache.has(n)) return bcache.get(n); const seen = new Set(); const sk = [...(callers.get(n) || [])]; while (sk.length) { const x = sk.pop(); if (!seen.has(x)) { seen.add(x); sk.push(...(callers.get(x) || [])); } } bcache.set(n, seen.size); return seen.size; };
let maxB = 1; for (const id of nodeIds) maxB = Math.max(maxB, blast(id));

// ---- STRUCTURE / health score (0 bad .. 1 good): smear + Unknown haze + tangle + cycles ----
const smear = fns.filter((f) => f.inferred.filter((e) => e !== "Unknown").length >= 3).length / (fns.length || 1);
let inCyc = 0;
try {
  const index = new Map(), low = new Map(), onst = new Set(), stk = []; let ix = 0;
  const strong = (v) => {
    index.set(v, ix); low.set(v, ix); ix++; stk.push(v); onst.add(v);
    for (const w of (cg[v] || [])) { if (!index.has(w)) { strong(w); low.set(v, Math.min(low.get(v), low.get(w))); } else if (onst.has(w)) low.set(v, Math.min(low.get(v), index.get(w))); }
    if (low.get(v) === index.get(v)) { const comp = []; let w; do { w = stk.pop(); onst.delete(w); comp.push(w); } while (w !== v); if (comp.length > 1 || (cg[v] || []).includes(v)) inCyc += comp.length; }
  };
  for (const v of Object.keys(cg)) if (!index.has(v)) strong(v);
} catch { inCyc = 0; }
const cycleRatio = inCyc / (nodeIds.length || 1);
const tangleExcess = Math.max(0, tangle - 0.4) / 0.6;
const structure = Math.max(0, Math.min(1, 1 - (0.3 * smear + 0.26 * unkShare + 0.24 * tangleExcess + 0.2 * Math.min(1, cycleRatio * 3))));
const grade = structure >= 0.85 ? "A" : structure >= 0.7 ? "B" : structure >= 0.55 ? "C" : structure >= 0.4 ? "D" : "F";

// ---- node positions: effect sectors sized over EFFECTFUL nodes; pure substrate spread full-circle ----
const present = [...effs.map((x) => x.e), ...(unkShare > 0.02 ? ["Unknown"] : [])];
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
    const a = a0 + ((k + 0.5) / ids2.length) * (a1 - a0) + (rnd() - 0.5) * ((a1 - a0) / Math.max(ids2.length, 1)) * (0.45 + (1 - structure) * 1.1);
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
const bundlePull = 0.18 + structure * 0.55;
let filGlow = "", filCol = "", filWhite = "";
const fedges = [];
for (const [a, cs] of Object.entries(cg)) for (const b of cs) { if (primEff(b) != null && pos.get(a) && pos.get(b)) fedges.push([a, b, blast(b)]); }
const MAXFIL = 300, CAP_SRC = 9, CAP_DST = 7;
fedges.sort((u, v) => v[2] - u[2]);
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
filDrawn.sort((u, v) => u[2] - v[2]);
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
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 600" width="${size}" height="${size}">
 <defs>
  <radialGradient id="bg" cx="50%" cy="50%" r="55%"><stop offset="0%" stop-color="#0a0e15"/><stop offset="100%" stop-color="#04060a"/></radialGradient>
  <clipPath id="disc"><circle cx="${CX}" cy="${CY}" r="${DISC}"/></clipPath>
  <filter id="neb" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="11"/></filter>
  <radialGradient id="warm" cx="50%" cy="42%" r="62%"><stop offset="0%" stop-color="#ffd089" stop-opacity="0.5"/><stop offset="55%" stop-color="#ff8a3c" stop-opacity="0.38"/><stop offset="100%" stop-color="#b83a1c" stop-opacity="0.34"/></radialGradient>
  <filter id="glow2" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="3.4"/></filter>
  <filter id="cglow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="0.7"/></filter>
 </defs>
 <rect width="600" height="600" fill="url(#bg)"/>
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

const name = repPath.split("/").pop().replace(/\.json$/, "");
const meta = {
  name,
  functions: fns.length,
  nodes: nodeIds.length,
  edges,
  effects: Object.fromEntries(effs.map((x) => [x.e, +x.share.toFixed(4)])),
  unknown: +unkShare.toFixed(4),
  density: +density.toFixed(3),
  tangle: +tangle.toFixed(3),
  complexity: +complexity.toFixed(3),
  structure: +structure.toFixed(3),
  health: { score: Math.round(structure * 100), grade, smear: +smear.toFixed(3), unknown: +unkShare.toFixed(3), tangleExcess: +tangleExcess.toFixed(3), cycleRatio: +cycleRatio.toFixed(3) },
  threads: fedges.length,
  threadsDrawn: filDrawn.length,
  threadsCapped: filCapped,
  seed: h,
};

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
  if (!rz) { console.error("candor-fingerprint: no rasterizer found (install rsvg-convert or resvg, or set CANDOR_CHROME) — PNG skipped, SVG written"); return false; }
  let r;
  if (rz.kind === "rsvg") r = spawnSync(rz.bin, ["-w", String(size), "-h", String(size), "-o", pngFile, svgFile], { encoding: "utf8" });
  else if (rz.kind === "resvg") r = spawnSync(rz.bin, ["-w", String(size), svgFile, pngFile], { encoding: "utf8" });
  else r = spawnSync(rz.bin, ["--headless", "--disable-gpu", "--no-sandbox", `--screenshot=${pngFile}`, `--window-size=${size},${size}`, "--default-background-color=00000000", svgFile], { encoding: "utf8" });
  if (r.status !== 0 || !fs.existsSync(pngFile)) { console.error(`candor-fingerprint: rasterizer (${rz.kind}) failed — PNG skipped`); return false; }
  return true;
}

// ---------------------------------------------------------------- outputs
const svg = buildSvg(opts.size);
const written = [];
const svgPath = opts.noSvg ? null : (opts.svg || stem + ".fingerprint.svg");
if (svgPath) { fs.writeFileSync(svgPath, svg); written.push(svgPath); }

if (opts.png) {
  // rasterizers need an SVG file on disk; use the written one or a temp file
  let src = svgPath, tmp = null;
  if (!src) { tmp = path.join(os.tmpdir(), `candor-fp-${h}.svg`); fs.writeFileSync(tmp, svg); src = tmp; }
  if (rasterize(src, opts.png, opts.size)) written.push(opts.png);
  if (tmp) try { fs.unlinkSync(tmp); } catch { /* ignore */ }
}

if (opts.html) {
  const legend = effs.map((x) => `<span style="color:${x.c}">●</span> ${x.e} ${Math.round(x.share * 100)}%`).join("  ")
    + (unkShare > 0.02 ? `  <span style="color:${UNK}">●</span> Unknown ${Math.round(unkShare * 100)}%` : "");
  fs.writeFileSync(opts.html, `<!doctype html><meta charset="utf-8"><title>${name} · candor fingerprint</title>
<body style="margin:0;background:#070a0e;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;font:12px ui-monospace,monospace;color:#8c84b8">
${svg}
<div style="margin-top:12px;letter-spacing:.4px">${legend}</div>
<div style="margin-top:4px;color:#3a434e">${name} · ${fns.length} fns · structure ${meta.health.score}% (${grade}) · ${fedges.length} effect threads</div>
</body>`);
  written.push(opts.html);
}

if (opts.json) process.stdout.write(JSON.stringify(meta, null, 2) + "\n");

const effSummary = effs.map((x) => x.e + " " + Math.round(x.share * 100) + "%").join(", ") + (unkShare > 0.02 ? `, Unknown ${Math.round(unkShare * 100)}%` : "");
console.error(`candor-fingerprint: ${name} — ${fns.length} effectful fns · structure ${meta.health.score}% (${grade}) · [${effSummary}]`
  + (filCapped > 0 ? ` · ${filDrawn.length}/${fedges.length} threads drawn` : "")
  + (written.length ? `\n  wrote: ${written.join(", ")}` : ""));
