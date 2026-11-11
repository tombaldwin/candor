#!/usr/bin/env python3
"""bin/ab-price.py — PRICE a corpus A/B in the terms CLAUDE.md uses.  Reads `bin/corpus-ab.py --out`.

WHY A SEPARATE FILE, AND NOT A FLAG ON corpus-ab.py.  It is a pure CONSUMER of the A/B's `--out` JSON, so
it can price an A/B that was run last week, a chained arm beside a standalone one, or a cached published arm,
without re-running anything; and corpus-ab.py is already 1,800 lines whose job is producing the diff.  What it
needed FROM corpus-ab.py (the analysed-unit denominators and the per-qual gate state) is added to `--out`
there, once, so this tool never re-derives a number the A/B already holds (R288).  It replaces the per-lane
`price.py` / `pricing.py` / `flips.py` / `remcheck.py` copies of 2026-10-30.

WHAT IT PRINTS, in CLAUDE.md's own order
=========================================
  1. DIRECTION.  CLAUDE.md prices three different things three different ways, and "say which direction the
     change runs in BEFORE quoting any band at it":
        adds Unknown            priced by REACH against the bands (~1.5% ships, ~2.6% declined, between = Tom)
        removes Unknown         priced by ACCOUNTING FOR EVERY REMOVAL + a fixture for the disclosure it deletes;
                                the band is meaningless (REMOVED > 0 is the point of a resolution)
        adds a concrete effect  priced by AUDITING EVERY NEW CHARGE; the band is NON-DISCRIMINATING there
        or `incomplete`         (swift R798: 0.0069% is three orders under the lower band and says nothing)
     plus the direction nobody wants: a concrete effect / incomplete / invisible LOST.  That is the
     cardinal-sin direction and it is not a price, it is a list to read.
  2. COUNTS beside percentages, and WHICH DENOMINATOR (analysed units, from the A/B's `analyzed.count`).
  3. The BAND VERDICT only where the band applies, and the literal words "band does not apply" where it
     does not.  A new instrument escalates regardless (the ruling) — this tool says so about itself.
  4. GATE FLIPS: the user-visible cost.  A qual is judged on the UNION of its rows on each arm, so an
     untouched sibling row that already carried the effect means the gate did NOT flip.  `deny E <qual>`
     and `deny Unknown <qual>`, at the row's own qual (prefix/transitive scopes are not computed).
  5. The REMOVED PARTITION: by what the PRE row carried — concrete / Unknown-only / invisible-only /
     incomplete-only / nothing — and the same partition for CHANGED rows that lost something.  The A/B's
     flip list is BLIND to rows removed while carrying only `invisible`; this is where they show up.
  6. With `--sidecar-pre/--sidecar-post`, the Unknown-lost units are classified C1 (resolved to genuinely
     pure) / C2 (resolved, reaches a non-analysed leaf) / C3 (hedge gone, nothing replacing it: THE CARDINAL
     SIN) / R (resolved to a concrete effect).  "C3 is empty" is evidence ONLY once the classifier has been
     shown able to find one, so every run first re-runs a SEEDED world (a C3, a C2, a C1) and says whether the
     classifier fired on it; if it did not, the C-table is withheld.

SIDECAR LAYOUT (for 6; the A/B itself deletes sidecars, so the lane scans the few entries it needs):
    DIR/<basename of the corpus entry>/callgraph.json     {fn: [callee, ...]}  every analysed unit a key
    DIR/<basename of the corpus entry>/report.json        (post arm only) the engine report, for callee rows

EXIT: 0 priced.  2 usage.  3 the input could not be priced (not an --out, no detail, headline does not
reconcile with detail) — never a price built on a malformed input.

  bin/ab-price.py AB.json [AB2.json ...] [--denominator N] [--json OUT] [--sidecar-pre D --sidecar-post D]
  bin/ab-price.py --arms-pre PREDIR --arms-post POSTDIR [--flips-out FLIPS.tsv]     # ARM MODE (see below)
  bin/ab-price.py --selftest

ARM MODE — the release bar's "every 1->0 flip", per unit, including `deny Unknown[<class>]`.  The --out document
holds effect tokens only (no `unknownWhy`, no call graph) and prints the first 8 quals, so a class lost while a
plain `Unknown` stays — SOUNDNESS R1668 — could not be seen in it and lanes kept `flips.py` copies keyed on `fn`
with last-wins.  ARM MODE reads the arms directly (`<entry>.scan.json[.gz]` + `.scan.callgraph.json[.gz]`; or a
pubarm_cache `<version>/<engine>` dir, whose rust reports carry no graph and java's carry `calls`), judges each
qual on the UNION of its rows, projects `unknownWhy` to the engine's classes, propagates them over the graph,
and writes EVERY flipped unit.  One arm without a graph => both compared direct-only, and it says so.
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import sys

BAND_SHIP, BAND_DECLINE = 1.5, 2.6          # percent; CLAUDE.md "When a disclosure-only change ships without asking"
SMALL_DENOM = 100_000                       # below this, a percentage swings on a handful of rows


# ── row / token helpers ──────────────────────────────────────────────────────────────────────────
def _row(v):
    try:
        r = json.loads(v) if isinstance(v, str) else v
    except ValueError:
        return {}
    return r if isinstance(r, dict) else {}


def tokens_of_row(r):
    t = set(r.get("inferred") or [])
    t.update("~incomplete:%s" % x for x in (r.get("incomplete") or []))
    t.update("~invisible:%s" % x for x in (r.get("invisible") or []))
    return t


def tokens_of_vals(vals):
    t = set()
    for v in vals:
        t |= tokens_of_row(_row(v))
    return t


def is_eff(tok):
    return not tok.startswith("~") and tok != "Unknown"


def fn_of_key(key):
    return key[2] if len(key) > 2 else key[-1]


def partition_cell(lost):
    """The most severe thing a row carried / lost: concrete > Unknown > incomplete > invisible > nothing."""
    if any(is_eff(t) for t in lost):
        return "concrete"
    if "Unknown" in lost:
        return "Unknown-only"
    if any(t.startswith("~incomplete:") for t in lost):
        return "incomplete-only"
    if any(t.startswith("~invisible:") for t in lost):
        return "invisible-only"
    return "nothing"


CELLS = ("concrete", "Unknown-only", "incomplete-only", "invisible-only", "nothing")


# ── input validation ─────────────────────────────────────────────────────────────────────────────
class Unpriceable(Exception):
    pass


def validate(d):
    if not isinstance(d, dict) or "detail" not in d or "headline" not in d:
        raise Unpriceable("not a bin/corpus-ab.py --out document (no `detail`/`headline`)")
    det = d["detail"]
    for k in ("added", "removed", "changed"):
        if k not in det:
            raise Unpriceable("`detail` has no `%s`" % k)
    h = d["headline"]
    # RECONCILE: the headline counts keys; the detail lists them.  A mismatch means the input was cut,
    # merged by hand, or written by something that is not corpus-ab, and any price off it is a guess.
    for hk, dk in (("added_keys", "added"), ("removed_keys", "removed"), ("changed_keys", "changed")):
        if h.get(hk) != len(det[dk]):
            raise Unpriceable("headline %s=%s but detail.%s has %d records — the document does not reconcile"
                              % (hk, h.get(hk), dk, len(det[dk])))


# ── the pricing ──────────────────────────────────────────────────────────────────────────────────
def gate_states(d):
    """-> (list of (entry, qual, preTokens, postTokens) for quals whose token set MOVED, exact: bool)."""
    if "gate_by_fn" in d:
        return [(e, q, set(a), set(b)) for e, q, a, b in d["gate_by_fn"]], True
    # An --out from before gate state was recorded.  Row-level reconstruction: it cannot see an UNTOUCHED
    # sibling row at the same qual, so it OVER-states flips.  Labelled, never silent.
    pre, post = collections.defaultdict(set), collections.defaultdict(set)
    det = d["detail"]
    for key, _n, vals in det["added"]:
        post[(key[0], fn_of_key(key))] |= tokens_of_vals(vals)
    for key, _n, vals in det["removed"]:
        pre[(key[0], fn_of_key(key))] |= tokens_of_vals(vals)
    for key, gone, came in det["changed"]:
        pre[(key[0], fn_of_key(key))] |= tokens_of_vals(gone)
        post[(key[0], fn_of_key(key))] |= tokens_of_vals(came)
    out = []
    for k in sorted(set(pre) | set(post)):
        if pre.get(k, set()) != post.get(k, set()):
            out.append((k[0], k[1], pre.get(k, set()), post.get(k, set())))
    return out, False


def price(d, denominator=None):
    validate(d)
    det = d["detail"]
    res = {"errors": [], "notes": []}

    # ── denominators ──
    den_post, den_pre = d.get("analyzed_post"), d.get("analyzed_pre")
    den_src = "analysed units, post arm (`analyzed.count` summed by corpus-ab)"
    if denominator is not None:
        den_post, den_src = denominator, "SUPPLIED BY THE CALLER (--denominator), not measured by this tool"
    elif den_post is None:
        den_src = "NOT IN THIS --out (written before corpus-ab recorded it); pass --denominator N"
    elif not den_post:
        den_post, den_src = None, "analysed units = 0 in this --out (nothing was judged)"
    res["denominator"] = {"post_analysed": den_post, "pre_analysed": den_pre, "source": den_src,
                          "post_rows": d.get("post_rows"), "entries": d.get("entries_compared")}

    # ── row-level (key-level) counts ──
    new_unknown_rows = lost_unknown_rows = 0
    for key, n, vals in det["added"]:
        new_unknown_rows += sum(1 for v in vals if "Unknown" in (_row(v).get("inferred") or []))
    for key, gone, came in det["changed"]:
        g = sum(1 for v in gone if "Unknown" in (_row(v).get("inferred") or []))
        c = sum(1 for v in came if "Unknown" in (_row(v).get("inferred") or []))
        new_unknown_rows += max(0, c - g)
        lost_unknown_rows += max(0, g - c)
    for key, n, vals in det["removed"]:
        lost_unknown_rows += sum(1 for v in vals if "Unknown" in (_row(v).get("inferred") or []))
    res["rows"] = {"newly_unknown": new_unknown_rows, "lost_unknown": lost_unknown_rows,
                   "added": d["headline"].get("added_rows"), "removed": d["headline"].get("removed_rows"),
                   "changed": d["headline"].get("changed_rows")}

    # ── gate flips, per qual ──
    states, exact = gate_states(d)
    res["gate_exact"] = exact
    flips = collections.defaultdict(list)
    by_eff_gain, by_eff_loss = collections.Counter(), collections.Counter()
    for e, q, P, Q in states:
        gain, loss = Q - P, P - Q
        if "Unknown" in gain:
            flips["adds_unknown"].append((e, q))
        if "Unknown" in loss:
            flips["removes_unknown"].append((e, q))
        if any(is_eff(t) for t in gain):
            flips["adds_concrete"].append((e, q))
            for t in gain:
                if is_eff(t):
                    by_eff_gain[t] += 1
        if any(is_eff(t) for t in loss):
            flips["loses_concrete"].append((e, q))
            for t in loss:
                if is_eff(t):
                    by_eff_loss[t] += 1
        if any(t.startswith("~incomplete:") for t in gain):
            flips["adds_incomplete"].append((e, q))
        if any(t.startswith("~incomplete:") for t in loss):
            flips["loses_incomplete"].append((e, q))
        if any(t.startswith("~invisible:") for t in gain):
            flips["adds_invisible"].append((e, q))
        if any(t.startswith("~invisible:") for t in loss):
            flips["loses_invisible"].append((e, q))
    res["flips"] = {k: len(v) for k, v in flips.items()}
    res["flip_quals"] = {k: v[:8] for k, v in flips.items()}
    res["flips_by_effect"] = {"deny E 0->1": dict(by_eff_gain), "deny E 1->0": dict(by_eff_loss)}

    # ── directions ──
    n = res["flips"].get
    dirs = []
    if n("adds_unknown"):
        dirs.append("adds_unknown")
    if n("removes_unknown"):
        dirs.append("removes_unknown")
    if n("adds_concrete") or n("adds_incomplete"):
        dirs.append("adds_concrete_or_incomplete")
    if n("adds_invisible"):
        dirs.append("adds_invisible")
    regress = [k for k in ("loses_concrete", "loses_incomplete", "loses_invisible") if n(k)]
    res["directions"], res["regressions"] = dirs, regress

    # ── the band ──
    pct = None
    if den_post and new_unknown_rows is not None:
        pct = 100.0 * new_unknown_rows / den_post
    res["band_input"] = {"rows_newly_unknown": new_unknown_rows, "denominator": den_post, "percent": pct}
    if dirs == ["adds_unknown"] and not regress:
        if pct is None:
            verdict = "UNPRICED: the denominator is unknown, so no percentage can be computed"
        elif pct < BAND_SHIP:
            verdict = ("SHIPS WITHOUT ASKING if it also NAMES THE SILENCE IT CLOSES (%.3f%% < %.1f%%); "
                       "the rule prices cost and ignores benefit — state the benefit separately" % (pct, BAND_SHIP))
        elif pct > BAND_DECLINE:
            verdict = "DECLINED WITHOUT ASKING (%.3f%% > %.1f%%)" % (pct, BAND_DECLINE)
        else:
            verdict = "ASK TOM: %.3f%% is between %.1f%% and %.1f%%" % (pct, BAND_SHIP, BAND_DECLINE)
        res["band"] = verdict
    elif not dirs and not regress:
        res["band"] = "no gate moved: nothing to price (and see REACH)"
    elif "adds_unknown" in dirs:
        res["band"] = ("band applies to the Unknown-ADDING component only (%s rows = %s%% of %s) and is NOT a "
                       "ship decision for a change that also runs %s%s"
                       % (new_unknown_rows, "%.3f" % pct if pct is not None else "?", den_post,
                          ", ".join(x for x in dirs if x != "adds_unknown") or "no other direction",
                          " and LOSES " + "/".join(regress) if regress else ""))
    else:
        why = {"removes_unknown": "it prices ADDING Unknown; a removal turns a red `deny E Unknown` green",
               "adds_concrete_or_incomplete": "it is NON-DISCRIMINATING for a concrete/incomplete add (swift R798)",
               "adds_invisible": "no band is defined for invisible"}
        res["band"] = "band does not apply: " + "; ".join(why.get(x, x) for x in dirs) + \
                      ("; and the change LOSES " + "/".join(regress) + " — not a price question" if regress else "")

    # ── reach ──
    rc = d.get("reach") or {}
    res["reach"] = {"measured": bool(rc) or bool(d.get("reach_entries")), "marks": rc}

    # ── REMOVED partition, and CHANGED-that-lost partition ──
    rem = {c: [0, 0] for c in CELLS}          # [keys, rows]
    rem_where = collections.defaultdict(list)
    for key, nrows, vals in det["removed"]:
        c = partition_cell(tokens_of_vals(vals))
        rem[c][0] += 1
        rem[c][1] += nrows
        rem_where[c].append(key)
    chg = {c: 0 for c in CELLS if c != "nothing"}
    chg_where = collections.defaultdict(list)
    for key, gone, came in det["changed"]:
        lost = tokens_of_vals(gone) - tokens_of_vals(came)
        if not lost:
            continue
        c = partition_cell(lost)
        chg[c] += 1
        chg_where[c].append(key)
    res["removed_partition"] = {c: {"keys": v[0], "rows": v[1]} for c, v in rem.items()}
    res["removed_where"] = {c: v[:5] for c, v in rem_where.items()}
    res["changed_loss_partition"] = chg
    res["changed_loss_where"] = {c: v[:5] for c, v in chg_where.items()}
    res["unknown_lost_units"] = [(e, q) for e, q in flips.get("removes_unknown", [])]
    res["pre_cache"], res["post_cache"] = d.get("pre_cache"), d.get("post_cache")
    return res


# ── C1 / C2 / C3 (sidecars) ──────────────────────────────────────────────────────────────────────
def classify_unknown_lost(unit, post_tokens, g_pre, g_post, post_rows):
    """One unit that lost `Unknown`.  -> (class, reason).  Shares no code with any engine.
    R   post row carries a concrete effect: the hedge was RESOLVED to a real charge
    C3  nothing replaces it: no gained callee; a gained callee that is not an analysed unit (a dropped edge);
        or a gained callee's row carries an effect the unit's own post row does not
    C2  resolved, but the gained callees' closure reaches a non-analysed leaf or a row carrying
        Unknown/invisible/incomplete
    C1  resolved to genuinely pure: every gained callee analysed, closure clean."""
    if any(is_eff(t) for t in post_tokens):
        return "R", "post row carries %s" % sorted(t for t in post_tokens if is_eff(t))
    gained = set(g_post.get(unit, [])) - set(g_pre.get(unit, []))
    if not gained:
        return "C3", "no gained callee: the hedge is gone and no edge replaces it"
    analysed = set(g_post)
    for g in sorted(gained):
        if g not in analysed:
            return "C3", "gained callee %s is not an analysed unit (a dropped edge, or a leaf nobody read)" % g
    seen, stack, c2 = set(), list(gained), None
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        t = tokens_of_vals(post_rows.get(n, []))
        if any(is_eff(x) for x in t) and not (t & post_tokens):
            return "C3", "callee %s carries %s that %s's own post row does not" % (
                n, sorted(x for x in t if is_eff(x)), unit)
        if (t - {x for x in t if is_eff(x)}) and c2 is None:
            c2 = "callee %s carries %s" % (n, sorted(t - {x for x in t if is_eff(x)}))
        for m in g_post.get(n, []):
            if m not in analysed:
                c2 = c2 or "closure reaches non-analysed leaf %s" % m
            else:
                stack.append(m)
    return ("C2", c2) if c2 else ("C1", "gained %d callee(s), all analysed, closure clean" % len(gained))


def seeded_world():
    """A tiny world with one unit of each class.  The classifier MUST find each, or its C-table is withheld."""
    pre = {"c1": ["old"], "c2": ["old"], "c3a": [], "c3b": ["old"], "r": ["old"], "c3c": ["old"]}
    post = {"c1": ["old", "pure"], "c2": ["old", "leafy"], "c3a": [], "c3b": ["old", "ghost"],
            "r": ["old", "io"], "c3c": ["old", "loud"], "pure": [], "leafy": ["jdk.Thing"], "io": [],
            "loud": [], "old": []}
    rows = {"io": ['{"inferred":["Fs"]}'], "loud": ['{"inferred":["Net"]}']}
    want = {"c1": "C1", "c2": "C2", "c3a": "C3", "c3b": "C3", "r": "R", "c3c": "C3"}
    posttok = {"r": {"Fs"}}
    return pre, post, rows, want, posttok


def canary():
    pre, post, rows, want, posttok = seeded_world()
    got = {u: classify_unknown_lost(u, posttok.get(u, set()), pre, post, rows)[0] for u in want}
    return got == want, got, want


def load_graph(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def sidecar_classify(res, d, pre_dir, post_dir):
    """Classify every Unknown-lost unit that has sidecars; the rest are listed UNCLASSIFIED, never skipped."""
    ok, got, want = canary()
    out = {"canary_fired": ok, "canary": {"got": got, "want": want}, "classes": collections.Counter(),
           "where": collections.defaultdict(list), "unclassified": []}
    if not ok:
        out["withheld"] = ("the classifier did NOT find the seeded classes (got %s, want %s): its C-table would "
                           "be arithmetic, not a measurement, so none is printed" % (got, want))
        return out
    post_tok = {(e, q): set(Q) for e, q, _P, Q in d.get("gate_by_fn", [])}
    cache = {}
    for e, q in res["unknown_lost_units"]:
        lab = os.path.basename(e.rstrip("/"))
        if lab not in cache:
            cache[lab] = (load_graph(os.path.join(pre_dir, lab, "callgraph.json")),
                          load_graph(os.path.join(post_dir, lab, "callgraph.json")),
                          load_graph(os.path.join(post_dir, lab, "report.json")))
        gp, gq, rep = cache[lab]
        if gp is None or gq is None:
            out["unclassified"].append((e, q, "no callgraph sidecar for %s in %s"
                                        % (lab, pre_dir if gp is None else post_dir)))
            continue
        rows = collections.defaultdict(list)
        for r in ((rep or {}).get("functions") or []):
            rows[r.get("fn")].append(r)
        c, why = classify_unknown_lost(q, post_tok.get((e, q), set()), gp, gq, rows)
        out["classes"][c] += 1
        out["where"][c].append((e, q, why))
    return out


# ── rendering ────────────────────────────────────────────────────────────────────────────────────
DIR_TEXT = {
    "adds_unknown": "ADDS Unknown  (a hedge: discloses that the engine does not know)",
    "removes_unknown": "REMOVES Unknown  (a resolution, or a lost disclosure: account for every one)",
    "adds_concrete_or_incomplete": "ADDS a CONCRETE EFFECT or an `incomplete` marker  (a resolution: audit every new charge)",
    "adds_invisible": "ADDS `invisible`  (a disclosure; no band is defined for it)",
}


def render(res, name=""):
    o = []
    w = o.append
    w("=" * 100)
    w("ab-price  %s" % name)
    w("=" * 100)
    dn = res["denominator"]
    w("DENOMINATOR  %s analysed units post arm (%s pre arm)  over %s entries;  source: %s"
      % (dn["post_analysed"] if dn["post_analysed"] is not None else "UNKNOWN",
         dn["pre_analysed"] if dn["pre_analysed"] is not None else "?", dn["entries"], dn["source"]))
    if dn["post_analysed"] and dn["post_analysed"] < SMALL_DENOM:
        w("  SMALL DENOMINATOR (< %d): a handful of rows swings the percentage.  Quote the ABSOLUTE count." % SMALL_DENOM)
    if dn["pre_analysed"] and dn["post_analysed"] and abs(dn["pre_analysed"] - dn["post_analysed"]) > 0.01 * dn["post_analysed"]:
        w("  pre and post analysed counts differ by more than 1%%: the arms did not judge the same population.")
    for k in ("pre_cache", "post_cache"):
        if res.get(k):
            w("  %s arm was served from the published-arm cache %s:%s" % (k[:-6].upper(), res[k]["version"], res[k]["engine"]))
    w("")
    w("1. DIRECTION  (say this BEFORE quoting any band)")
    if not res["directions"] and not res["regressions"]:
        w("   no qual's gate state moved on either arm.")
    for x in res["directions"]:
        w("   - %s" % DIR_TEXT[x])
    for x in res["regressions"]:
        w("   - !! LOSES %s  (the cardinal-sin direction: a candidate silent under-report; not a price, a list to read)"
          % x[len("loses_"):])
    w("")
    w("2. COUNTS")
    r = res["rows"]
    w("   rows (keys) newly carrying Unknown %d   |  rows that lost Unknown %d   |  A/B headline: added %s removed %s changed %s"
      % (r["newly_unknown"], r["lost_unknown"], r["added"], r["removed"], r["changed"]))
    f = res["flips"]
    w("   GATE FLIPS at the qual's own qual (%s):" % ("exact: union over every row of the qual, both arms"
                                                    if res["gate_exact"] else
                                                    "ROW-LEVEL RECONSTRUCTION — this --out predates gate state, so an untouched "
                                                    "sibling row is invisible and flips are OVER-stated"))
    for k, label in (("adds_unknown", "deny Unknown  0 -> 1"), ("removes_unknown", "deny Unknown  1 -> 0"),
                     ("adds_concrete", "deny <E>      0 -> 1"), ("loses_concrete", "deny <E>      1 -> 0"),
                     ("adds_incomplete", "incomplete   0 -> 1"), ("loses_incomplete", "incomplete   1 -> 0"),
                     ("adds_invisible", "invisible    0 -> 1"), ("loses_invisible", "invisible    1 -> 0")):
        w("     %-22s %7d" % (label, f.get(k, 0)))
    for k, dct in res["flips_by_effect"].items():
        if dct:
            w("     %s by effect: %s" % (k, dict(sorted(dct.items(), key=lambda kv: -kv[1]))))
    w("")
    w("3. BAND")
    bi = res["band_input"]
    w("   input: %d rows newly carrying Unknown / %s analysed units = %s"
      % (bi["rows_newly_unknown"], bi["denominator"], "%.4f%%" % bi["percent"] if bi["percent"] is not None else "?"))
    w("   verdict: %s" % res["band"])
    w("   INSTRUMENT: this tool is new and calibrated only by its own --selftest.  Per the ruling a NEW INSTRUMENT")
    w("   escalates regardless: any SHIPS/DECLINED above is 'ASK TOM' until it has been reconciled against a figure")
    w("   from an older instrument (corpus-ab.py --buckets) on the same --out.")
    w("")
    w("4. REACH")
    if res["reach"]["measured"]:
        w("   measured: %s" % res["reach"]["marks"])
    else:
        w("   NOT MEASURED in this --out.  An unchanged/zero diff here is NOT evidence the code ran.")
    w("")
    w("5. REMOVED PARTITION  (by what the PRE row carried)")
    rp = res["removed_partition"]
    for c in CELLS:
        w("   %-16s %7d keys  %7d rows" % (c, rp[c]["keys"], rp[c]["rows"]))
    if rp["invisible-only"]["keys"]:
        w("   !! invisible-only removals: the A/B's flip list is BLIND to these.  Each needs the slot-(c) check:")
        w("      the callee D is directly called, and chaining D's report MEASURABLY charges or Unknowns the row.")
    if rp["Unknown-only"]["keys"]:
        w("   Unknown-only removals need C1/C2/C3 (section 6).")
    w("   CHANGED rows that LOST something, by the most severe loss:")
    for c, n_ in res["changed_loss_partition"].items():
        w("   %-16s %7d keys" % (c, n_))
    for c in ("concrete", "invisible-only", "incomplete-only"):
        for key in (res["removed_where"].get(c, []) + res["changed_loss_where"].get(c, []))[:3]:
            w("      e.g. [%s] %s" % (c, " / ".join(str(x) for x in key)[:110]))
    w("")
    sc = res.get("sidecar")
    w("6. Unknown-LOST UNITS  (%d unit(s) with deny Unknown 1 -> 0)" % len(res["unknown_lost_units"]))
    if sc is None:
        w("   not classified: no --sidecar-pre/--sidecar-post given.  They are NOT thereby resolved, and not thereby")
        w("   pure.  C3 is the cardinal sin; this run did not look for it.")
    else:
        w("   classifier calibration: seeded world C1/C2/C3/R/C3/C3 -> %s"
          % ("FIRED on all (%s)" % sc["canary"]["got"] if sc["canary_fired"] else "DID NOT FIRE"))
        if sc.get("withheld"):
            w("   " + sc["withheld"])
        else:
            for c in ("C1", "C2", "C3", "R"):
                w("   %-3s %6d" % (c, sc["classes"].get(c, 0)))
            for e, q, why in sc["where"].get("C3", [])[:8]:
                w("      C3  %s :: %s  — %s" % (os.path.basename(e.rstrip("/")), q, why))
            if sc["unclassified"]:
                w("   UNCLASSIFIED %d (no sidecar): %s" % (len(sc["unclassified"]), sc["unclassified"][0][2]))
            if not sc["classes"].get("C3") and not sc["unclassified"]:
                w("   C3 is empty AND the classifier was shown able to find one: that is evidence.")
            elif not sc["classes"].get("C3"):
                w("   C3 is empty only over the CLASSIFIED units; the unclassified ones could hold one.")
    return "\n".join(o)


# ── selftest ─────────────────────────────────────────────────────────────────────────────────────
def _val(inferred=(), invisible=(), incomplete=(), fn="f"):
    r = {"loc": "x:1:1", "inferred": list(inferred)}
    if invisible:
        r["invisible"] = list(invisible)
    if incomplete:
        r["incomplete"] = list(incomplete)
    return json.dumps(r, sort_keys=True, separators=(",", ":"))


def _doc(added=(), removed=(), changed=(), gate=None, den=10000, reach=None):
    """Build an --out-shaped document.  Keys are (entry, pkg, fn, hash)."""
    det = {"added": [[["e", "p", f, "h" + f], 1, [v]] for f, v in added],
           "removed": [[["e", "p", f, "h" + f], 1, [v]] for f, v in removed],
           "changed": [[["e", "p", f, "h" + f], [a], [b]] for f, a, b in changed]}
    d = {"headline": {"added_keys": len(det["added"]), "removed_keys": len(det["removed"]),
                      "changed_keys": len(det["changed"]), "added_rows": len(det["added"]),
                      "removed_rows": len(det["removed"]), "changed_rows": len(det["changed"])},
         "detail": det, "entries_compared": 1, "post_rows": 1}
    if den is not None:
        d["analyzed_post"] = d["analyzed_pre"] = den
    if gate is not None:
        d["gate_by_fn"] = gate
    if reach is not None:
        d["reach"] = reach
    return d


def _unk_doc(n_new, den):
    """n_new quals each newly carrying Unknown, over a denominator `den`."""
    return _doc(added=[("u%d" % i, _val(["Unknown"])) for i in range(n_new)], den=den, reach={"M": 3},
                gate=[["e", "u%d" % i, [], ["Unknown"]] for i in range(n_new)])


# ── ARM-DIRECTORY MODE: every 1->0 gate flip, per unit, incl. Unknown[<class>] ───────────────────
# WHY THIS EXISTS (measured 2026-11-11 from nine per-lane `flips.py` copies, SOUNDNESS R1668).  The --out
# document above holds EFFECT-level tokens per qual: no `unknownWhy`, no call graph, so it cannot say that
# `deny Unknown[unresolved] <qual>` went 1->0 while the unit keeps a plain `Unknown` of ANOTHER class.  And it
# prints only the first 8 flipped quals.  Both are why lanes kept a copy.  This mode reads the ARMS (the
# `<entry>.scan.json[.gz]` + `<entry>.scan.callgraph.json[.gz]` pairs a lane keeps, or a pubarm_cache dir) and
# writes EVERY flipped unit to a TSV.
#
# UNIT = QUAL, JUDGED ON THE UNION OF ITS ROWS (candor-query gate.rs: "two entries sharing a hash are ONE unit
# by construction").  A last-wins dict over `fn` is the bug the copies had: a trait-default row plus an
# `interfaceUnion: true` beside row share a qual, and last-wins reports whichever row came last.
#
# THE CLASS PROJECTION IS THE ENGINE'S, not a copy of a lane's: candor-rust crates/candor-classify/src/policy.rs
# `ReasonClass::classify` (lowercase, trimmed, PREFIX tests; the five §4 kinds first, so an alias cannot shadow
# one) and `reason_class_matches` (a unit with `Unknown` and NO class gates as `unresolved`), propagated over the
# call graph as scan.rs `reason_class_acc = propagate_str(...)` does.  The selftest checks the prefix table
# against that file when a candor-rust checkout is present.
CLASS_PREFIXES = (("reflect", "reflect"), ("native", "native"), ("dispatch", "dispatch"), ("callback", "indirect"),
                  ("ambiguous", "dispatch"), ("dynamicmemberlookup", "reflect"), ("closure", "indirect"),
                  ("task-handoff", "indirect"), ("indy", "dispatch"), ("missing-config", "setup"),
                  ("no-tsconfig", "setup"), ("no-node_modules", "setup"))


def reason_class(why):
    w = str(why).strip().lower()
    for p, c in CLASS_PREFIXES:
        if w.startswith(p):
            return c
    return "unresolved"


def _read_json(path):
    import gzip
    op = gzip.open if path.endswith(".gz") else open
    with op(path, "rt") as f:
        return json.load(f)


def _first(*paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None


def arm_index(d):
    """{entry-name: (report_path, callgraph_path|None)} for a directory of arms.  Layouts: A) `<e>.scan.json[.gz]`
    (+ `<e>.scan.callgraph.json[.gz]`); B) a pubarm_cache dir (`entries/<label>-<sha>.report.gz` + `.meta.json`)."""
    idx = {}
    if os.path.isdir(os.path.join(d, "entries")):
        ent = os.path.join(d, "entries")
        for m in sorted(os.listdir(ent)):
            if m.endswith(".meta.json"):
                lab = _read_json(os.path.join(ent, m)).get("entry_label")
                rp = os.path.join(ent, m[:-len(".meta.json")] + ".report.gz")
                if lab and os.path.exists(rp):
                    idx[lab] = (rp, None)
        return idx
    for f in sorted(os.listdir(d)):
        for suf in (".scan.json.gz", ".scan.json"):
            if f.endswith(suf):
                n = f[:-len(suf)]
                idx[n] = (os.path.join(d, f), _first(os.path.join(d, n + ".scan.callgraph.json.gz"),
                                                     os.path.join(d, n + ".scan.callgraph.json")))
    return idx


def load_units(report_path, cg_path, use_graph=True):
    """-> {qual: {"eff": set, "unknown": bool, "classes": set}} — ONE record per qual, the UNION of its rows
    (never last-wins), classes transitive over the call graph.  `calls` on the rows are the fallback graph."""
    rep = _read_json(report_path)
    rows = collections.defaultdict(list)
    for f in rep.get("functions") or []:
        rows[f["fn"]].append(f)
    cg, graph_src = {}, "none"
    if not use_graph:
        pass
    elif cg_path:
        cg, graph_src = _read_json(cg_path), "sidecar"
    else:
        for q, rs in rows.items():
            for r in rs:
                if r.get("calls"):
                    cg.setdefault(q, set()).update(r["calls"])
                    graph_src = "report"
    direct = {q: {reason_class(w) for r in rs for w in (r.get("unknownWhy") or [])} for q, rs in rows.items()}
    acc = {q: set(s) for q, s in direct.items()}
    changed = True
    while changed:
        changed = False
        for q, cs in cg.items():
            if q not in rows and not cs:
                continue
            s = acc.setdefault(q, set())
            b = len(s)
            for c in cs:
                s |= acc.get(c, set())
            if len(s) != b:
                changed = True
    out = {}
    for q, rs in rows.items():
        inf = set()
        for r in rs:
            inf.update(r.get("inferred") or [])
        unk = "Unknown" in inf
        out[q] = {"eff": {t for t in inf if is_eff(t)}, "unknown": unk,
                  "classes": (acc.get(q) or {"unresolved"}) if unk else set()}
    return out, graph_src


def arm_flips(pre_dir, post_dir):
    """Every unit whose gate moved 1->0 (and 0->1, counted) between two arm directories.  A unit absent from the
    post report is pure there.  Returns a dict with `rows` (every flip: entry, qual, kind, detail) and counts."""
    A, B = arm_index(pre_dir), arm_index(post_dir)
    res = {"rows": [], "gain": collections.Counter(), "loss": collections.Counter(), "entries": 0,
           "only_pre": sorted(set(A) - set(B)), "only_post": sorted(set(B) - set(A)),
           "graph": collections.Counter(), "dup_quals": 0}
    for n in sorted(set(A) & set(B)):
        (pa, ca), (pb, cb) = A[n], B[n]
        ua, ga = load_units(pa, ca)
        ub, gb = load_units(pb, cb)
        if (ga == "none") != (gb == "none"):
            # ONE arm has a graph and the other does not: comparing transitive classes against direct ones FABRICATES
            # flips (a caller that inherits a class on one side only).  Compare like with like: direct on both.
            ua, ga = load_units(pa, ca, use_graph=False)
            ub, gb = load_units(pb, cb, use_graph=False)
            res["graph"]["MISMATCH->none"] += 1
        res["entries"] += 1
        res["graph"][ga + "/" + gb] += 1
        for q, a in ua.items():
            b = ub.get(q, {"eff": set(), "unknown": False, "classes": set()})
            for e in sorted(a["eff"] - b["eff"]):
                res["rows"].append((n, q, "deny " + e, "1->0"))
                res["loss"]["deny " + e] += 1
            if a["unknown"] and not b["unknown"]:
                res["rows"].append((n, q, "deny Unknown", "1->0"))
                res["loss"]["deny Unknown"] += 1
            for c in sorted(a["classes"] - b["classes"]):
                kept = "plain Unknown KEPT, classes now " + ",".join(sorted(b["classes"])) if b["unknown"] else "Unknown gone"
                res["rows"].append((n, q, "deny Unknown[%s]" % c, "1->0 (%s)" % kept))
                res["loss"]["deny Unknown[%s]" % c] += 1
        for q, b in ub.items():
            a = ua.get(q, {"eff": set(), "unknown": False, "classes": set()})
            for e in b["eff"] - a["eff"]:
                res["gain"]["deny " + e] += 1
            if b["unknown"] and not a["unknown"]:
                res["gain"]["deny Unknown"] += 1
            for c in b["classes"] - a["classes"]:
                res["gain"]["deny Unknown[%s]" % c] += 1
    return res


def render_arm_flips(res, pre, post, show=12):
    o = ["=" * 100, "ab-price --arms   pre=%s  post=%s" % (pre, post), "=" * 100,
         "entries compared %d  (only in pre: %d, only in post: %d)" % (res["entries"], len(res["only_pre"]), len(res["only_post"]))]
    if res["only_pre"] or res["only_post"]:
        o.append("  !! entries present in one arm only are NOT compared: pre-only %s ... post-only %s"
                 % (res["only_pre"][:3], res["only_post"][:3]))
    if res["entries"] == 0:
        o.append("  NOT A MEASUREMENT: no entry exists in both arms.")
    g = res["graph"]
    o.append("call graph (pre/post): " + ", ".join("%s x%d" % kv for kv in sorted(g.items())))
    if any("none" in k for k in g):  # includes MISMATCH->none
        o.append("  !! an arm with NO call graph computes DIRECT classes only: a class reaching a unit through a callee is "
                 "invisible, so class flips are UNDER-counted there (the sin direction).  Supply the sidecar.")
    o.append("")
    o.append("1->0 gate flips (the cardinal-sin direction): %d units-gates" % len(res["rows"]))
    kinds = collections.Counter(r[2] for r in res["rows"])
    for k, v in sorted(kinds.items()):
        o.append("   %-28s %d" % (k, v))
    cls_kept = [r for r in res["rows"] if r[2].startswith("deny Unknown[") and "KEPT" in r[3]]
    o.append("   of which a class lost while plain Unknown KEPT: %d   <- invisible to `deny Unknown`, only `deny E Unknown[<class>]` sees it" % len(cls_kept))
    for r in res["rows"][:show]:
        o.append("     %s  %s  %s  %s" % r)
    if len(res["rows"]) > show:
        o.append("     ... %d more: write them all with --flips-out FILE" % (len(res["rows"]) - show))
    o.append("0->1 gate flips (adds; priced elsewhere): %d" % sum(res["gain"].values()))
    return "\n".join(o)


def selftest():
    global classify_unknown_lost
    fails = []

    def check(name, cond, extra=""):
        print("  %-4s %s%s" % ("ok" if cond else "FAIL", name, ("\n         " + extra) if (extra and not cond) else ""))
        if not cond:
            fails.append(name)

    print("ab-price --selftest — every bucket is SEEDED and must fire; each negative must stay quiet")
    print("[band] adds-Unknown only: the three regions of the ruling, at fixed denominators")
    r = price(_unk_doc(140, 10000))
    check("1.40% of 10000 -> SHIPS", r["directions"] == ["adds_unknown"] and r["band"].startswith("SHIPS"), r["band"])
    r = price(_unk_doc(200, 10000))
    check("2.00% -> ASK TOM (between 1.5 and 2.6)", r["band"].startswith("ASK TOM"), r["band"])
    r = price(_unk_doc(300, 10000))
    check("3.00% -> DECLINED", r["band"].startswith("DECLINED"), r["band"])
    r = price(_unk_doc(150, 10000))
    check("exactly 1.50% is NOT 'ships' (the band is < 1.5)", r["band"].startswith("ASK TOM"), r["band"])
    r = price(_unk_doc(1, 10000), denominator=None)
    check("the absolute count is carried beside the percentage", r["band_input"]["rows_newly_unknown"] == 1
          and r["band_input"]["denominator"] == 10000)
    d = _unk_doc(5, None)
    d.pop("analyzed_post", None)
    r = price(d)
    check("no denominator in the --out -> UNPRICED, never a percentage", r["band"].startswith("UNPRICED") and r["band_input"]["percent"] is None, r["band"])
    r = price(d, denominator=1000)
    check("--denominator is accepted and labelled as caller-supplied", "SUPPLIED BY THE CALLER" in r["denominator"]["source"] and r["band_input"]["percent"] == 0.5)

    print("[direction] the band must say 'does not apply' where it does not")
    r = price(_doc(removed=[("a", _val(["Unknown"]))], gate=[["e", "a", ["Unknown"], []]]))
    check("removes Unknown only -> band does not apply", r["directions"] == ["removes_unknown"] and r["band"].startswith("band does not apply"), r["band"])
    r = price(_doc(added=[("a", _val(["Net"]))], den=1000000, gate=[["e", "a", [], ["Net"]]]))
    check("adds concrete only -> band does not apply (non-discriminating)", r["directions"] == ["adds_concrete_or_incomplete"]
          and r["band"].startswith("band does not apply") and "NON-DISCRIMINATING" in r["band"], r["band"])
    check("…and the flip is attributed to its effect", r["flips_by_effect"]["deny E 0->1"] == {"Net": 1})
    r = price(_doc(changed=[("a", _val(), _val(incomplete=["Fs"]))], gate=[["e", "a", [], ["~incomplete:Fs"]]]))
    check("adds an `incomplete` marker only -> the concrete/incomplete direction", r["directions"] == ["adds_concrete_or_incomplete"]
          and r["flips"].get("adds_incomplete") == 1, str(r["directions"]))
    r = price(_doc(changed=[("a", _val(["Fs"]), _val())], gate=[["e", "a", ["Fs"], []]]))
    check("LOSES a concrete effect -> flagged as a regression, not priced", r["regressions"] == ["loses_concrete"]
          and "not a price question" in r["band"], r["band"])
    r = price(_doc(removed=[("a", _val(invisible=["pkg"]))], gate=[["e", "a", ["~invisible:pkg"], []]]))
    check("loses an `invisible` -> regression", r["regressions"] == ["loses_invisible"], str(r["regressions"]))
    r = price(_doc(added=[("a", _val(["Unknown"])), ("b", _val(["Fs"]))],
                   gate=[["e", "a", [], ["Unknown"]], ["e", "b", [], ["Fs"]]]))
    check("mixed adds-Unknown + concrete -> the band is NOT a ship decision", len(r["directions"]) == 2
          and "NOT a ship decision" in r["band"], r["band"])
    r = price(_doc(den=1000))
    check("nothing moved -> 'no gate moved' and REACH NOT MEASURED is visible", r["band"].startswith("no gate moved")
          and not r["reach"]["measured"] and "NOT MEASURED" in render(r))

    print("[gate] a flip is the UNION over a qual's rows, including an untouched sibling")
    doc = _doc(changed=[("a", _val(), _val(["Unknown"]))], gate=[])      # recorded gate state: unchanged
    r = price(doc)
    check("a sibling row already carried Unknown -> rows say 1, gate flips say 0",
          r["rows"]["newly_unknown"] == 1 and r["flips"].get("adds_unknown", 0) == 0 and r["gate_exact"])
    doc.pop("gate_by_fn")
    r = price(doc)
    check("an --out with no gate state falls back to row-level and SAYS SO", not r["gate_exact"] and r["flips"].get("adds_unknown") == 1
          and "OVER-stated" in render(r))

    print("[partition] REMOVED rows by what the PRE row carried — one seeded row per cell")
    rem = [("c", _val(["Fs"])), ("u", _val(["Unknown"])), ("i", _val(invisible=["x"])), ("n", _val()),
           ("k", _val(incomplete=["Fs"]))]
    r = price(_doc(removed=rem, gate=[]))
    rp = r["removed_partition"]
    check("concrete / Unknown-only / invisible-only / incomplete-only / nothing each = 1",
          [rp[c]["keys"] for c in CELLS] == [1, 1, 1, 1, 1], str(rp))
    check("a row carrying Unknown AND invisible is Unknown-only (priority), not invisible-only",
          price(_doc(removed=[("z", _val(["Unknown"], invisible=["x"]))], gate=[]))["removed_partition"]["Unknown-only"]["keys"] == 1)
    r = price(_doc(changed=[("a", _val(["Unknown"]), _val()), ("b", _val(invisible=["x"]), _val()),
                            ("c", _val(["Fs", "Unknown"]), _val(["Unknown"])), ("d", _val(["Fs"]), _val(["Fs"], invisible=["y"]))], gate=[]))
    check("CHANGED rows that lost something are partitioned too (and a pure gain is not a loss)",
          r["changed_loss_partition"] == {"concrete": 1, "Unknown-only": 1, "incomplete-only": 0, "invisible-only": 1}, str(r["changed_loss_partition"]))

    print("[C1/C2/C3] the classifier must FIND a seeded C3 before an empty C3 means anything")
    ok, got, want = canary()
    check("seeded world: C1, C2, C3 x3 and R each found", ok, "got %s want %s" % (got, want))
    pre, post, rows, want, posttok = seeded_world()
    mutated = dict(post)
    mutated["c3a"] = ["pure"]                                       # give the C3 unit a clean gained callee
    check("negative control: a unit WITH a clean gained callee is C1, not C3",
          classify_unknown_lost("c3a", set(), pre, mutated, rows)[0] == "C1")
    check("negative control: a C3 is not found by an indiscriminate classifier (C1 stays C1)",
          classify_unknown_lost("c1", set(), pre, post, rows)[0] == "C1")
    import tempfile
    import shutil
    tmp = tempfile.mkdtemp(prefix="ab-price-selftest.")
    try:
        for arm, g in (("pre", pre), ("post", post)):
            os.makedirs(os.path.join(tmp, arm, "ent"))
            json.dump(g, open(os.path.join(tmp, arm, "ent", "callgraph.json"), "w"))
        json.dump({"functions": [{"fn": k, "inferred": ["Fs"]} for k in ()] + [
            {"fn": "io", "inferred": ["Fs"]}, {"fn": "loud", "inferred": ["Net"]}]},
            open(os.path.join(tmp, "post", "ent", "report.json"), "w"))
        gate = [["ent", u, ["Unknown"], sorted(posttok.get(u, []))] for u in want]
        d = _doc(removed=[(u, _val(["Unknown"])) for u in want], gate=gate)
        r = price(d)
        r["sidecar"] = sidecar_classify(r, d, os.path.join(tmp, "pre"), os.path.join(tmp, "post"))
        cl = r["sidecar"]["classes"]
        check("end to end over sidecars: C1=1 C2=1 C3=3 R=1", dict(cl) == {"C1": 1, "C2": 1, "C3": 3, "R": 1}, str(dict(cl)))
        check("…and the C3 units are NAMED with a reason", len(r["sidecar"]["where"]["C3"]) == 3 and all(w[2] for w in r["sidecar"]["where"]["C3"]))
        txt = render(r)
        check("…and the report says the classifier fired on the seed", "FIRED on all" in txt)
        r2 = price(d)
        r2["sidecar"] = sidecar_classify(r2, d, os.path.join(tmp, "nope"), os.path.join(tmp, "post"))
        check("missing sidecars -> UNCLASSIFIED, never silently C1", not r2["sidecar"]["classes"] and len(r2["sidecar"]["unclassified"]) == len(want))
        check("…and an empty C3 over unclassified units is NOT declared evidence", "C3 is empty AND" not in render(r2))
        # a classifier that cannot find the seed must withhold its table
        real = classify_unknown_lost
        classify_unknown_lost = lambda *a, **k: ("C1", "stub")
        try:
            r3 = price(d)
            r3["sidecar"] = sidecar_classify(r3, d, os.path.join(tmp, "pre"), os.path.join(tmp, "post"))
        finally:
            classify_unknown_lost = real
        check("a BROKEN classifier (everything C1) is caught by the seed and its table WITHHELD",
              not r3["sidecar"]["canary_fired"] and "withheld" in r3["sidecar"] and not r3["sidecar"]["classes"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("[input] a document that does not reconcile is never priced")
    bad = _unk_doc(3, 100)
    bad["headline"]["added_keys"] = 4
    try:
        price(bad)
        check("headline/detail mismatch refused", False)
    except Unpriceable:
        check("headline/detail mismatch refused", True)
    try:
        price({"foo": 1})
        check("a non --out document refused", False)
    except Unpriceable:
        check("a non --out document refused", True)

    print("[e2e] a REAL corpus-ab.py --out priced by this tool")
    import subprocess
    tmp = tempfile.mkdtemp(prefix="ab-price-e2e.")
    try:
        here = os.path.dirname(os.path.abspath(__file__))
        rep = lambda fns: json.dumps({"candor": {"spec": "0.35", "version": "x"}, "package": "p",
                                      "analyzed": {"count": 100}, "functions": fns})
        fn = lambda q, inf, **k: dict({"fn": q, "loc": "a:1:1", "hash": "h" + q, "inferred": inf}, **k)
        open(os.path.join(tmp, "pre.json"), "w").write(rep([fn("a", []), fn("b", ["Fs"]), fn("c", ["Unknown"])]))
        open(os.path.join(tmp, "post.json"), "w").write(rep([fn("a", ["Unknown"]), fn("b", ["Fs"]), fn("c", [])]))
        outp = os.path.join(tmp, "ab.json")
        p = subprocess.run([sys.executable, os.path.join(here, "corpus-ab.py"), "--pre-json", os.path.join(tmp, "pre.json"),
                            "--post-json", os.path.join(tmp, "post.json"), "--allow-zero-reach", "--out", outp],
                           capture_output=True, text=True)
        check("corpus-ab wrote an --out", p.returncode == 0 and os.path.exists(outp), p.stdout[-300:] + p.stderr[-300:])
        r = price(json.load(open(outp)))
        check("denominator is the engine's analysed.count (100), not the row count (3)", r["denominator"]["post_analysed"] == 100)
        check("a gained Unknown and a lost Unknown are both seen, exactly", r["flips"] == {"adds_unknown": 1, "removes_unknown": 1}, str(r["flips"]))
        check("…gate state is exact", r["gate_exact"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print("[arms] class-scoped 1->0 flips, over DUPLICATE-QUAL rows, proven able to fail")
    import gzip
    import re
    import shutil
    import tempfile
    tmp = tempfile.mkdtemp(prefix="ab-price-arms.")
    try:
        row = lambda q, inf, why=(), **k: dict({"fn": q, "inferred": list(inf), "unknownWhy": list(why)}, **k)
        MACRO, DISP = "macro:unreadable macro_rules! template `with_inner`", "dispatch:untyped receiver of `x`"

        def arm(name, rows, cg=None):
            os.makedirs(os.path.join(tmp, name), exist_ok=True)
            with gzip.open(os.path.join(tmp, name, "e1.scan.json.gz"), "wt") as f:
                json.dump({"functions": rows}, f)
            if cg is not None:
                with gzip.open(os.path.join(tmp, name, "e1.scan.callgraph.json.gz"), "wt") as f:
                    json.dump(cg, f)
        # pre: Object::sym has a real row (dispatch) AND a beside row (`macro:` -> class unresolved), beside row FIRST.
        # post (the bad arm): the beside row is gone; the unit keeps `Unknown` with class dispatch only.
        # ctrl: a pure twin with unique name that must not flip; `pure_both` carries the same class on both arms.
        pre = [row("sym", ["Unknown"], [MACRO], interfaceUnion=True), row("sym", ["Unknown"], [DISP]),
               row("caller", ["Unknown"]), row("same", ["Unknown"], [DISP])]
        bad = [row("sym", ["Unknown"], [DISP]), row("caller", ["Unknown"]), row("same", ["Unknown"], [DISP])]
        good = [row("sym", ["Unknown"], [DISP]), row("sym", ["Unknown"], [MACRO], interfaceUnion=True),
                row("caller", ["Unknown"]), row("same", ["Unknown"], [DISP])]
        cg = {"caller": ["sym"], "sym": [], "same": []}
        arm("pre", pre, cg); arm("bad", bad, cg); arm("good", good, cg); arm("badnocg", bad)
        r = arm_flips(os.path.join(tmp, "pre"), os.path.join(tmp, "bad"))
        got = sorted((x[1], x[2]) for x in r["rows"])
        check("SEED FIRES: sym AND its caller (transitively) lose Unknown[unresolved]; nothing else",
              got == [("caller", "deny Unknown[unresolved]"), ("sym", "deny Unknown[unresolved]")], str(got))
        check("…and each is a class lost while plain Unknown is KEPT (`deny Unknown` never moves)",
              all("KEPT" in x[3] for x in r["rows"]) and "deny Unknown" not in {x[2] for x in r["rows"]}, str(r["rows"]))
        check("negative control: the beside row restored (the fix) -> ZERO flips",
              arm_flips(os.path.join(tmp, "pre"), os.path.join(tmp, "good"))["rows"] == [])
        check("negative control: identical arms -> ZERO flips",
              arm_flips(os.path.join(tmp, "pre"), os.path.join(tmp, "pre"))["rows"] == [])

        def lastwins(path):
            u = {}
            for f in _read_json(path)["functions"]:
                u[f["fn"]] = {reason_class(w) for w in f.get("unknownWhy") or []}
            return u
        lw_pre = lastwins(os.path.join(tmp, "pre", "e1.scan.json.gz"))
        lw_bad = lastwins(os.path.join(tmp, "bad", "e1.scan.json.gz"))
        check("the seed is DISCRIMINATING: a last-wins loader over the same arms sees no class lost on `sym`",
              lw_pre["sym"] - lw_bad["sym"] == set(), str(lw_pre["sym"]))
        r = arm_flips(os.path.join(tmp, "pre"), os.path.join(tmp, "badnocg"))
        check("graph on ONE arm only: compared direct-vs-direct (no fabricated caller flip), and the report SAYS the graph is missing",
              sorted(x[1] for x in r["rows"]) == ["sym"] and "NO call graph" in render_arm_flips(r, "a", "b")
              and r["graph"]["MISMATCH->none"] == 1, str(r["rows"]))
        pure = [row("pureA", [])]
        arm("pp", pure, {}); arm("pq", pure + [row("pureB", ["Fs"])], {})
        r = arm_flips(os.path.join(tmp, "pq"), os.path.join(tmp, "pp"))
        check("a lost concrete effect is listed too, and an absent unit counts as pure", [(x[1], x[2]) for x in r["rows"]] == [("pureB", "deny Fs")])
        arm("pn", [row("g", ["Unknown"], [DISP])], {}); arm("pz", [], {})
        r = arm_flips(os.path.join(tmp, "pn"), os.path.join(tmp, "pz"))
        check("an Unknown that vanishes entirely lists `deny Unknown` AND its class",
              sorted(x[2] for x in r["rows"]) == ["deny Unknown", "deny Unknown[dispatch]"])
        check("flip list is COMPLETE, not first-8 (30 units)", len(arm_flips(
            *[(arm("m%d" % i, [row("u%d" % j, ["Net"]) for j in range(30)] if i == 0 else [], {}), os.path.join(tmp, "m%d" % i))[1] for i in (0, 1)])["rows"]) == 30)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    for w, c in (("dispatch:x", "dispatch"), ("ambiguous:same-name", "dispatch"), ("callback:cb", "indirect"),
                 ("macro:unreadable", "unresolved"), ("  REFLECT:y", "reflect"), ("dep:abc", "unresolved"),
                 ("dep-stale:p", "unresolved"), ("dynamicMemberLookup:R.p", "reflect"), ("closure:c", "indirect"),
                 ("indy:z", "dispatch"), ("no-tsconfig", "setup"), ("native:ffi", "native"), ("", "unresolved")):
        check("reason_class(%r) == %s" % (w, c), reason_class(w) == c, reason_class(w))
    pol = os.path.expanduser("~/git/candor-rust/crates/candor-classify/src/policy.rs")
    if os.path.exists(pol):
        src = open(pol).read()
        # drift guard against the engine's own table (skipped when no checkout): every prefix we hold is a
        # string literal in ReasonClass::classify (or a Kind token), so a renamed/removed alias shows up here.
        miss = [p for p, _ in CLASS_PREFIXES if ('"%s' % p) not in src and p.replace("_", "-") not in src]
        check("every prefix in CLASS_PREFIXES still appears in candor-rust's policy.rs", not miss, str(miss))
    else:
        print("  (candor-rust checkout absent: engine-table drift guard skipped)")

    if fails:
        print("ab-price selftest: %d FAILED — %s" % (len(fails), "; ".join(fails)))
        return 1
    print("ab-price selftest: OK")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ab-price.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("files", nargs="*", help="bin/corpus-ab.py --out documents (each priced separately)")
    ap.add_argument("--denominator", type=int, help="analysed units, if the --out predates corpus-ab recording it")
    ap.add_argument("--sidecar-pre", help="DIR/<entry>/callgraph.json for the PRE arm (see the docstring)")
    ap.add_argument("--sidecar-post", help="DIR/<entry>/{callgraph,report}.json for the POST arm")
    ap.add_argument("--json", help="also write the priced result here")
    ap.add_argument("--arms-pre", help="ARM-DIRECTORY MODE: the PRE arm dir (`<entry>.scan.json[.gz]` + `.scan.callgraph.json[.gz]`, "
                    "or a pubarm_cache `<version>/<engine>` dir).  Lists EVERY 1->0 flip incl. `deny Unknown[<class>]`.")
    ap.add_argument("--arms-post", help="ARM-DIRECTORY MODE: the POST arm dir (same layouts)")
    ap.add_argument("--flips-out", help="ARM-DIRECTORY MODE: write EVERY flipped unit here as TSV (entry, qual, gate, detail)")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if bool(args.arms_pre) != bool(args.arms_post):
        print("ab-price: --arms-pre and --arms-post go together")
        return 2
    if args.arms_pre:
        try:
            res = arm_flips(args.arms_pre, args.arms_post)
        except (OSError, ValueError) as e:
            print("ab-price: CANNOT READ ARMS — %s" % e)
            return 3
        print(render_arm_flips(res, args.arms_pre, args.arms_post))
        if args.flips_out:
            with open(args.flips_out, "w") as f:
                for r in res["rows"]:
                    f.write("\t".join(r) + "\n")
        if res["entries"] == 0:
            return 3
        if not args.files:
            return 0
    if not args.files:
        ap.print_usage()
        return 2
    if bool(args.sidecar_pre) != bool(args.sidecar_post):
        print("ab-price: --sidecar-pre and --sidecar-post go together")
        return 2
    allres = {}
    for f in args.files:
        try:
            d = json.load(open(f))
            res = price(d, args.denominator)
        except (OSError, ValueError, Unpriceable) as e:
            print("ab-price: CANNOT PRICE %s — %s" % (f, e))
            return 3
        if args.sidecar_pre:
            res["sidecar"] = sidecar_classify(res, d, args.sidecar_pre, args.sidecar_post)
        print(render(res, f))
        allres[f] = res
    if args.json:
        json.dump(allres, open(args.json, "w"), indent=1, default=lambda o: dict(o) if isinstance(o, collections.Counter) else str(o))
    return 0


if __name__ == "__main__":
    sys.exit(main())
