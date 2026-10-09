#!/usr/bin/env python3
"""bin/corpus-ab.py — THE corpus A/B differential. Use this; do not write another `ab.py`.

WHY THIS FILE EXISTS
====================
The corpus A/B is the family's most-used instrument and until now it had no implementation. On
2026-09-07 there were FIFTEEN ad-hoc `ab.py`/`ab.mjs` scripts in one session scratchpad and no shared
tool. Every round wrote its own, every one copied the last one's key, and so every one inherited the
last one's blind spots. That is AGENT-CORPUS-BRIEF §G — fifteen paths computing one fact — and it is
why SOUNDNESS R288 survived long enough to make every ADDED/REMOVED/CHANGED figure in the register a
lower bound.

The four defects it is built against, each measured, each with a proof in `--selftest`:

  R288  KEYING ON BARE `fn` LOSES ROWS.  Every inherited `ab.py` did `out[f["fn"]] = row`, so N report
        rows sharing a qual collapsed to ONE and the last one silently won.  Measured over the 1,509
        crate rust registry corpus: 274,912 rows, 267,370 distinct `fn` — 7,542 rows (2.7%) in 3,901
        duplicate groups across 599 crates, invisible to every diff ever run over it.
        This tool keys on `(entry, package, fn, hash)` AND holds a MULTISET of row values under each
        key, so multiplicity survives.  See "WHAT ACTUALLY CAUSES R288" below: the package is NOT the
        discriminator, and a fix that only added it would have changed nothing.

  R242  A HOLLOWED CORPUS ENTRY JUDGES NOTHING and a differential over it prints
        `ADDED 0 / REMOVED 0 / CHANGED 0` — character-for-character what a correct, safely-inert
        change prints.  Two corpora were found hollow under `$TMPDIR`, and one write-up claiming "six
        real TypeScript repos" had measured nothing.  So an entry whose `analyzed.count` is 0 is
        FATAL here, named, exit 3.  KEYED ON THE INTEGER, NEVER ON THE EMPTINESS OF `functions`:
        SPEC ⟨0.24⟩ measured that a rule keyed on emptiness would have withdrawn 104 legitimate
        all-pure claims to catch 6 real ones, and the first version of this guard did exactly that —
        it refused 238 of the 1,509 rust registry crates on its first real run.  The hollow
        DIAGNOSIS is asked of `bin/corpus.sh --hollow-check` rather than reimplemented (§G again).

  §E1   A NARROW VALUE KEY IS BLIND TO EVERY DISCLOSURE CHANNEL.  Keyed on `inferred` alone, a java
        corpus showed 400 changed rows; keyed wide, the same arms showed 16,461 on `invisible` alone.
        `incomplete`, `declared`, `invisible`, `unknownWhy`, `unresolved`, `netClass` are exactly
        where fail-closed behaviour lives.  So the value is WIDE by default — every field — and when
        you narrow it with `--fields`, the wide numbers are printed beside the narrow ones anyway.

  §E1   AN UNCHANGED ROW IS NOT EVIDENCE THE CODE RAN.  R79/R85/R87/R92 each ran a full A/B, returned
        byte-identical, and only afterwards was it found that the corpus contained zero instances of
        the shape.  "0 changed with 0 reaches" and "0 changed with 800 reaches" are different claims
        and the register has been conflating them.  So REACH is a first-class output: `--mark` counts
        a marker your instrumented arm prints, it is reported beside the diff and never inside it,
        and a zero-diff with no reach measurement EXITS 4 rather than reading as a clean result.

WHAT ACTUALLY CAUSES R288 — READ THIS BEFORE "FIXING" THE KEY AGAIN
===================================================================
R288 as filed says the `fn` key "collapses workspace members that share one".  Measured against the
R288 evidence itself, that mechanism is wrong, and the correction matters because the fix it implies
(add the package to the key) does nothing:

  · The 8 named crates are single-crate registry checkouts.  All their duplicate rows carry the SAME
    `package`, the SAME `fn`, the SAME `loc` and the SAME `hash` — `async_std#string::extend::String::extend`
    appears 5×, byte-identical, from 5 impl arms the collector visits separately.  `(package, fn)`
    merges them exactly as `fn` did.
  · Census over all 1,509 crates: 3,901 duplicate groups, and the number of groups whose members
    DIFFER from each other within one arm is **0**.  So the merge lost MULTIPLICITY, not content —
    the R270 diff's row-level under-count (291 census rows vs 263 reported CHANGED) is entirely that
    2.7%, and no row was hidden behind a sibling moving the other way on that corpus.

The package still belongs in the key — SPEC §2.2 is explicit that names repeat across packages, and a
report SET (a multi-package tree scanned to one `--out` prefix) is the case where two genuinely
different units collide on `fn` alone.  But the thing that closes R288 is the MULTISET, and a tool
that keyed on `(package, fn)` with a plain dict would have reported the same 263.

And `(package, fn)` alone is not even safe: the rust registry holds `flate2-1.1.9` and `flate2-1.1.10`
side by side, both reporting `"package": "flate2"`.  Keying two corpus ENTRIES together is R288's own
defect one level out, and this file had it until the first real run priced the legacy key at 187 where
R288's own write-up said 263 — the discrepancy that exposed it.  The corpus entry is in every key mode.

EXIT CODES — and why a failure can never look like a clean diff (SOUNDNESS R289)
================================================================================
R289 is the cautionary tale this tool is shaped around: `gate --report` returns exit 2 on any tree
holding a `Package.swift`, which would have masked an entire 1,524-cell matrix UNIFORMLY and read as
"could not evaluate" rather than "the caller is absent".  A uniform failure that produces an empty
result is the worst outcome an instrument can have, so:

  0   a comparison was produced.  A nonzero diff is a RESULT, not a failure.
  2   usage error.
  3   NO COMPARISON WAS PRODUCED.  Zero entries; an entry's arm errored; an entry judged nothing
      (`analyzed.count` 0); or nothing anywhere produced a row.  This never prints a diff summary —
      there is nothing to summarise.  `--allow-fail N` / `--allow-unjudged` relax the first two, in
      writing, and the excluded entries are named on every subsequent run.
  4   a comparison was produced but it is NOT EVIDENCE: `--mark` was given and every mark counted
      zero (the A/B is safety-only), or the diff is empty and reach was never measured at all.
      `--allow-zero-reach` acknowledges it deliberately; nothing suppresses it silently.

USAGE
=====
  # the normal shape: two binaries over a corpus of entry directories
  bin/corpus-ab.py --pre-cmd  '/path/candor-scan-PRE  {entry} --json' \\
                   --post-cmd '/path/candor-scan-POST {entry} --json' \\
                   --entries-dir ~/.cargo/registry/src/index.crates.io-* \\
                   --mark R290PROBE --mark-env CANDOR_ALIAS_DEBUG=1 \\
                   --out ab.json

  # an engine that writes a report SET rather than one document on stdout
  bin/corpus-ab.py --pre-cmd  'java -jar pre.jar  {entry} --out {outdir}/r' \\
                   --post-cmd 'java -jar post.jar {entry} --out {outdir}/r' --entries-dir corpus

  # two captured reports, no engine (also how --selftest drives itself)
  bin/corpus-ab.py --pre-json a.json --post-json b.json

  bin/corpus-ab.py --selftest        # the four calibration proofs; run by CI

`{entry}` is substituted per corpus entry.  `{outdir}` (optional) is a fresh temp dir per entry per
arm; when present, every `*.json` under it after the run is read as a report.  All four engines'
report shapes are accepted: the ⟨0.2⟩+ envelope with `package` (rust/ts/swift) or `packages` (the JVM
shape), a bare legacy v0.1 top-level array, and several documents concatenated on one stdout.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures as cf
import glob
import hashlib
import json
import os
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# The value fields a narrow key would look at.  Named here only so the calibration table can show what
# narrowing costs; the DEFAULT is every field.
NARROW_DEFAULT = ("inferred",)


# ── reading reports ───────────────────────────────────────────────────────────────────────────────
class BadReport(Exception):
    pass


def parse_documents(text):
    """Every JSON document in `text`.  Engines print one; a report set may print several."""
    dec = json.JSONDecoder()
    docs = []
    i, n = 0, len(text)
    while i < n:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            break
        try:
            doc, j = dec.raw_decode(text, i)
        except ValueError as e:
            raise BadReport("not JSON at offset %d: %s" % (i, e))
        docs.append(doc)
        i = j
    if not docs:
        raise BadReport("no JSON document on stdout")
    return docs


def rows_of(doc, label):
    """(package, [row, …]) for one report document, across all four engines' shapes."""
    if isinstance(doc, dict):
        if "functions" not in doc:
            raise BadReport("envelope has no `functions` key (keys: %s)" % ",".join(sorted(doc))[:120])
        pkg = doc.get("package")
        if pkg is None:
            pkgs = doc.get("packages")
            # The JVM shape: one compilation unit genuinely spanning several packages (SPEC §2.2).
            if isinstance(pkgs, list) and pkgs:
                pkg = "+".join(str(p) for p in pkgs)
        return pkg, list(doc["functions"])
    if isinstance(doc, list):
        # The legacy v0.1 bare array.  Readers MUST accept both during migration (SPEC §2.1).
        if doc and not all(isinstance(x, dict) for x in doc):
            raise BadReport("top-level array holds non-objects")
        if doc and all("functions" in x for x in doc):
            raise BadReport("a JSON array OF reports — emit them as separate documents")
        return None, list(doc)
    raise BadReport("top-level JSON is %s, not an object or array" % type(doc).__name__)


def pkg_of_row(row, envelope_pkg, entry_label):
    """Per-row package.  Envelope first; then the `hash` prefix, which every engine namespaces by
    package (`async_std#io::copy`, `axios#AxiosHeaders.set`, `app/Cell.callAfter()V`); then the entry
    name, so a package is never silently None and two entries never merge."""
    if envelope_pkg:
        return envelope_pkg
    h = row.get("hash")
    if isinstance(h, str):
        if "#" in h:
            return h.split("#", 1)[0]
        if "/" in h:
            return h.rsplit("/", 1)[0]
    return "<entry:%s>" % entry_label


def judged_of(doc):
    """`analyzed.count` — the number of units the engine actually JUDGED, or None if the document does
    not say.  SPEC ⟨0.24⟩ is emphatic that this integer, and never the emptiness of `functions`, is
    what separates "judged nothing" from "judged and found nothing"."""
    if not isinstance(doc, dict):
        return None
    a = doc.get("analyzed")
    if isinstance(a, dict) and isinstance(a.get("count"), int):
        return a["count"]
    return None


def read_reports(text, entry_label):
    """-> ([(package, row), …], judged_units_or_None)."""
    out = []
    judged = None
    for doc in parse_documents(text):
        pkg, rows = rows_of(doc, entry_label)
        j = judged_of(doc)
        if j is not None:
            judged = (judged or 0) + j
        for r in rows:
            if not isinstance(r, dict) or "fn" not in r:
                raise BadReport("a `functions` element is not an object with `fn`")
            out.append((pkg_of_row(r, pkg, entry_label), r))
    return out, judged


# ── keys and values ───────────────────────────────────────────────────────────────────────────────
# THE CORPUS ENTRY IS ALWAYS PART OF THE KEY, IN EVERY MODE.  It is the coordinate the corpus is
# indexed by, and two entries are never the same unit — but they very often share a PACKAGE name:
# the rust registry holds `flate2-1.1.9` and `flate2-1.1.10` side by side, both reporting
# `"package": "flate2"`, both full of identical `fn` quals.  A `(package, fn)` key merges those two
# crates into one, which is R288's own defect one level out — and the first version of this file had
# it.  It also keeps the `fn` mode below a FAITHFUL reproduction of the inherited `ab.py`, which
# built one dict per crate directory and summed: comparing against a corpus-flattened `fn` key would
# be comparing against a strawman, and the point of the table is to price the real thing.
def row_key(entry, pkg, row, mode):
    if mode == "fn":
        return (entry, row["fn"])
    if mode == "pkgfn":
        return (entry, pkg, row["fn"])
    if mode == "unit":
        return (entry, pkg, row["fn"], row.get("hash"))
    raise ValueError(mode)


def row_value(row, fields):
    """Canonical comparison value.  `fields=None` is WIDE: every field except `fn` (which is in the
    key).  `hash` is deliberately kept in the value for the coarser keys, so a hash move is visible
    as a change rather than as nothing."""
    if fields is None:
        d = {k: v for k, v in row.items() if k != "fn"}
    else:
        d = {k: row.get(k) for k in fields}
    return json.dumps(d, sort_keys=True, separators=(",", ":"))


def index_multiset(rows, mode, fields):
    idx = collections.defaultdict(collections.Counter)
    for entry, pkg, row in rows:
        idx[row_key(entry, pkg, row, mode)][row_value(row, fields)] += 1
    return idx


def index_lastwins(rows, mode, fields):
    """The inherited `ab.py` behaviour, reproduced exactly so the calibration table can price it:
    `out[f["fn"]] = row`, one dict per corpus entry, last row wins."""
    idx = {}
    for entry, pkg, row in rows:
        idx[row_key(entry, pkg, row, mode)] = row_value(row, fields)
    return idx


def diff_multiset(pre, post):
    added_rows = removed_rows = 0
    changed_keys = changed_rows = 0
    added_keys = removed_keys = 0
    detail = {"added": [], "removed": [], "changed": []}
    for k in post.keys() - pre.keys():
        added_keys += 1
        n = sum(post[k].values())
        added_rows += n
        detail["added"].append([list(k), n, sorted(post[k])])
    for k in pre.keys() - post.keys():
        removed_keys += 1
        n = sum(pre[k].values())
        removed_rows += n
        detail["removed"].append([list(k), n, sorted(pre[k])])
    for k in pre.keys() & post.keys():
        a, b = pre[k], post[k]
        if a == b:
            continue
        gone, came = a - b, b - a
        changed_keys += 1
        # A 1-row key whose value moved is ONE changed row, not two; a 6-row key all of whose rows
        # moved is six.  `max` is the count that reconciles with a census of rows carrying a reason,
        # which is the number these A/Bs are always checked against.
        changed_rows += max(sum(gone.values()), sum(came.values()))
        detail["changed"].append([list(k), sorted(gone.elements()), sorted(came.elements())])
    return {
        "added_rows": added_rows, "removed_rows": removed_rows,
        "added_keys": added_keys, "removed_keys": removed_keys,
        "changed_keys": changed_keys, "changed_rows": changed_rows,
    }, detail


def diff_lastwins(pre, post):
    added = len(post.keys() - pre.keys())
    removed = len(pre.keys() - post.keys())
    changed = sum(1 for k in pre.keys() & post.keys() if pre[k] != post[k])
    return {"added_rows": added, "removed_rows": removed, "added_keys": added,
            "removed_keys": removed, "changed_keys": changed, "changed_rows": changed}


# ── running an arm ────────────────────────────────────────────────────────────────────────────────
def run_arm(template, entry, timeout, env_extra, outdir_glob="*.json",
            outdir_exclude=()):
    """-> (stdout_text, stderr_bytes, error_or_None)."""
    outdir = None
    try:
        argv = shlex.split(template)
        if any("{outdir}" in a for a in argv):
            outdir = tempfile.mkdtemp(prefix="corpus-ab.")
        argv = [a.replace("{entry}", entry).replace("{outdir}", outdir or "") for a in argv]
        env = dict(os.environ)
        env.update(env_extra)
        try:
            p = subprocess.run(argv, capture_output=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            return None, b"", "TIMEOUT after %ss" % timeout
        except OSError as e:
            return None, b"", "cannot execute: %s" % e
        if p.returncode != 0:
            tail = p.stderr.decode("utf-8", "replace").strip().splitlines()
            return None, p.stderr, "exit %d: %s" % (p.returncode, tail[-1][:200] if tail else "(no stderr)")
        if outdir:
            files = sorted(glob.glob(os.path.join(outdir, "**", outdir_glob), recursive=True))
            # A DENYLIST, NOT AN ALLOWLIST.  Reading every file the engine wrote is the sound
            # over-approximation; this narrows it.  Engines drop SIDECARS beside the report
            # (`x.callgraph.json`, `x.hierarchy.json`, `x.locs.json` — candor-java writes all three
            # under `--parallel`), and a sidecar is a map keyed by fn, not a report.  Narrowing by
            # denylist means an UNKNOWN sidecar shape reaches the reader and is refused loudly as
            # "envelope has no `functions` key"; an allowlist would silently drop a real report
            # whose name we had not thought of.  Which direction it fails in is the whole point.
            kept, skipped = [], []
            for f in files:
                b = os.path.basename(f)
                (skipped if any(b.endswith(x) for x in outdir_exclude) else kept).append(f)
            if not kept:
                return None, p.stderr, ("wrote no report under {outdir} (%d file(s) matched the "
                                        "sidecar denylist: %s)" % (len(skipped),
                                        ", ".join(os.path.basename(x) for x in skipped[:4]))
                                        if skipped else "wrote nothing matching %s under {outdir}"
                                        % outdir_glob)
            return "\n".join(open(f).read() for f in kept), p.stderr, None
        return p.stdout.decode("utf-8", "replace"), p.stderr, None
    finally:
        if outdir:
            for f in glob.glob(os.path.join(outdir, "**", "*"), recursive=True):
                if os.path.isfile(f):
                    os.unlink(f)
            for d in sorted(glob.glob(os.path.join(outdir, "**", "*"), recursive=True), reverse=True):
                if os.path.isdir(d):
                    os.rmdir(d)
            os.rmdir(outdir)


# ── DOES THIS RUN'S TWO ARMS ACTUALLY DIFFER?  SOUNDNESS R691 ─────────────────────────────────────
# `cargo build --release` returned exit 0 in 0.02s WITHOUT REBUILDING, because both arms shared one
# `CARGO_TARGET_DIR`, so a differential's PRE and POST were THE SAME BINARY.  Every figure it produced
# would have been a self-comparison — ADDED 0 / REMOVED 0 / CHANGED 0, indistinguishable from a change
# that is correctly inert.  It was caught by `shasum` on the two binaries and NOT by the exit code,
# which was 0 and honest.  That is the R242 class at the BINARY: the family has now paid for it three
# times — a hollow corpus, a hollow jar (okio, correct sha1, zero `.class` files), and a hollow ARM.
#
# THE RULE R691 EARNS: every differential must PROVE ITS ARMS DIFFER before it reports a number, and
# the proof must be on the ARTEFACT rather than on a command's exit code.  So this hashes the file
# CONTENT of every path-shaped token in each template and compares.
#
# IT REFUSES ONLY WHEN THE TWO ARMS ARE INDISTINGUISHABLE — same residual argv, same binary content,
# same per-arm env.  That bound is deliberate and it is what keeps the check from firing on the
# legitimate same-binary A/B: `--policy A` vs `--policy B`, a feature flag, or `--mark-env` setting a
# probe variable on one arm only, are all real differentials over one binary and all keep their
# residual argv (or their env) DIFFERENT.  A check that refused those would be turned off, and then it
# would not be a check.
#
# AND WHEN IT CANNOT LOOK, IT SAYS SO (§H).  A template that hides its binary inside a `bash -c`
# string, or names it through `$PATH`, yields no file to hash; the run then prints that it did NOT
# prove its arms differ rather than printing nothing, because silence here reads as a clean check.
def arm_identity(template):
    """(sorted content hashes of the path-shaped tokens, residual argv with those tokens masked)."""
    try:
        argv = shlex.split(template)
    except ValueError:
        return (), (template,)
    hashes, residual = [], []
    for tok in argv:
        masked = tok
        # A token may itself be a small script (`bash -c 'PRE/bin {entry} --json'`), so look at every
        # whitespace-separated piece of it and not only at the token as a whole.
        for piece in tok.split():
            if not piece or piece.startswith("-"):
                continue
            path = os.path.expanduser(piece)
            if not os.path.isfile(path):
                continue
            try:
                with open(path, "rb") as fh:
                    h = hashlib.sha256(fh.read()).hexdigest()
            except OSError:
                continue
            hashes.append(h)
            masked = masked.replace(piece, "<FILE:%s>" % h[:12])
        residual.append(masked)
    return tuple(sorted(hashes)), tuple(residual)


def arms_are_indistinguishable(pre_cmd, post_cmd, mark_env, mark_arm):
    """(verdict, note).  verdict is True only when NOTHING separates the two arms."""
    pre_h, pre_r = arm_identity(pre_cmd)
    post_h, post_r = arm_identity(post_cmd)
    env_differs = bool(mark_env) and mark_arm in ("pre", "post")
    if not pre_h and not post_h:
        return False, ("arm identity: NOT PROVEN — no path-shaped token in either --pre-cmd/--post-cmd "
                       "resolved to a file, so this run did not check that its arms differ (R691).")
    if pre_h == post_h and pre_r == post_r and not env_differs:
        return True, "arm identity: the two arms are byte-identical commands over byte-identical files."
    if pre_h == post_h and pre_h:
        # NOT PROVEN, not "legitimate": a wrapper script (`bash arm.sh pre|post`) hashes identically on
        # both arms while choosing DIFFERENT engines by its argument — measured 2026-10-09, when a java
        # lane's real A/B printed one hash for both arms. The arguments differ, so this does not refuse;
        # it says the artefact difference was not shown, which is what is true.
        return False, ("arm identity: both arms name the SAME file content (%s…) and differ only in "
                       "their arguments or env. Either a one-binary differential (legitimate) or a "
                       "wrapper that picks the binary by argument — the arms' ENGINES were NOT proven "
                       "to differ at the artefact (R691); name the binaries directly to prove it."
                       % pre_h[0][:12])
    return False, ("arm identity: the arms' binaries differ (%s… vs %s…), proven by content hash."
                   % ((pre_h[0][:12] if pre_h else "none"), (post_h[0][:12] if post_h else "none")))


# ── WHAT DID THIS DIFF LOSE?  SOUNDNESS R701 ──────────────────────────────────────────────────────
# A removal audit read `detail["changed"]` with the WRONG RECORD SHAPE — records are `[key, PRE, POST]`
# and it read them as `[key, values]`, so the `post` half was empty, every loss test was skipped, and
# it printed a confident `0 losses`.  Minutes later the SAME lane's corrected audit found a real
# 91-row regression (a ⟨0.39⟩ `dispatchesOn` key silently dropped on `swift-nio`).  An audit that
# cannot see a loss reports exactly what a clean fix reports, so the record-shape assumption belongs
# in ONE place, written once and calibrated once — which is R288's argument, applied to the second
# ad-hoc instrument in a week.
#
# WHY IT IS NOT `--buckets`.  Bucket 3 counts a lost CONCRETE EFFECT: it reads `inferred` and nothing
# else.  The loss that was nearly missed was a `dispatchesOn` KEY — a field a gate does not read but
# ⟨0.39⟩ obligation 3 joins on — so the bucket ladder was structurally blind to it.  This audit is
# per FIELD, every field, and it names the quals.
def losses_audit(detail, sample=6):
    """Per-field value losses over a diff detail.  Refuses a record shape it does not understand."""
    lost = collections.Counter()
    where = collections.defaultdict(list)
    seen = {"changed": 0, "removed": 0}
    shape_errors = []

    def fields_of(values):
        """field -> multiset of json-encoded values, over a row-value multiset."""
        out = collections.defaultdict(collections.Counter)
        for v in values:
            try:
                row = json.loads(v)
            except (ValueError, TypeError):
                continue
            if not isinstance(row, dict):
                continue
            for k, val in row.items():
                out[k][json.dumps(val, sort_keys=True)] += 1
        return out

    for rec in detail.get("changed", []):
        # THE ASSERTION THE AD-HOC AUDIT DID NOT MAKE.  `[key, gone, came]` — three elements.  Read as
        # two, `came` is never bound, every comparison is against nothing, and the audit prints 0.
        if not isinstance(rec, (list, tuple)) or len(rec) != 3:
            shape_errors.append("changed record has %s element(s), want 3 ([key, PRE, POST])"
                                % (len(rec) if isinstance(rec, (list, tuple)) else type(rec).__name__))
            continue
        seen["changed"] += 1
        key, gone, came = rec
        pre_f, post_f = fields_of(gone), fields_of(came)
        for field, pre_vals in pre_f.items():
            missing = pre_vals - post_f.get(field, collections.Counter())
            if missing:
                lost[field] += sum(missing.values())
                where[field].append((key, sorted(missing.elements())[:1]))

    for rec in detail.get("removed", []):
        if not isinstance(rec, (list, tuple)) or len(rec) != 3:
            shape_errors.append("removed record has %s element(s), want 3 ([key, count, values])"
                                % (len(rec) if isinstance(rec, (list, tuple)) else type(rec).__name__))
            continue
        seen["removed"] += 1
        key, _n, values = rec
        for field, pre_vals in fields_of(values).items():
            lost[field] += sum(pre_vals.values())
            where[field].append((key, ["<row removed>"]))

    return {"lost": dict(lost), "seen": seen, "shape_errors": shape_errors,
            "where": {k: v[:sample] for k, v in where.items()}}


# ── A SWIFTPM ENTRY WHOSE DEPENDENCIES ARE NOT RESOLVED CANNOT CHAIN.  SOUNDNESS R700 ─────────────
# candor-swift's `dependencyModulePackages` reads the CONSUMER'S OWN `.build/checkouts` to map module ->
# package, so without them `chainedPkgs` is empty and the join never runs at all.  A chained A/B over an
# unresolved package therefore measures TWO UNCHAINED SCANS: the lane's first run came back
# BYTE-IDENTICAL, 555 rows, same `coverage.uncovered` — and after `swift package resolve`, 319 of 569
# rows differed with 251 probe hits.  R700 asked for a refusal in "the swift equivalent of
# corpus-chained-rs.sh"; there is no such script — the swift chained arm is driven through THIS tool —
# so the diagnosis belongs here, next to the zero-reach refusal that is the only reason R700 was caught.
#
# IT ADVISES AND DOES NOT REFUSE, and the direction matters: for a STANDALONE swift A/B an unresolved
# package is perfectly normal (the deps are invisible and candor says so), so refusing would break the
# commonest swift run to protect the rarer chained one.  It is printed on every run that has one, and it
# is REPEATED inside the exit-4 blocks, because "0 changed, 0 reach" is exactly the shape this produces
# and a refusal that does not name the likeliest cause sends the reader hunting.
#
# THE TEST IS DELIBERATELY TWO-SIDED, and its failure direction is a printed line rather than a wrong
# verdict: `Package.resolved` holding pins is SwiftPM's own record that dependencies exist (the
# authority, §G), and a `.package(` in the manifest is the weaker textual signal kept for a tree that
# has never resolved at all and so has no `Package.resolved`.
def swift_unresolved_entries(entries):
    """Entries that are SwiftPM packages with dependencies DECLARED and NOT checked out."""
    out = []
    for e in entries:
        manifest = os.path.join(e, "Package.swift")
        if not os.path.isfile(manifest):
            continue
        if os.path.isdir(os.path.join(e, ".build", "checkouts")):
            continue
        declared = False
        resolved = os.path.join(e, "Package.resolved")
        if os.path.isfile(resolved):
            try:
                doc = json.loads(open(resolved).read())
                pins = doc.get("pins") or (doc.get("object") or {}).get("pins") or []
                declared = bool(pins)
            except (ValueError, OSError):
                declared = False
        if not declared:
            try:
                declared = ".package(" in open(manifest, errors="replace").read()
            except OSError:
                declared = False
        if declared:
            out.append(e)
    return out


def swift_unresolved_note(unfit, total):
    return [
        "%d of %d entr%s a SwiftPM package with dependencies DECLARED and NOT RESOLVED (no"
        % (len(unfit), total, "y is" if len(unfit) == 1 else "ies are"),
        "`.build/checkouts`).  SOUNDNESS R700: candor-swift maps module -> package out of that",
        "directory, so a CHAINED arm cannot chain there and chained vs unchained comes back",
        "BYTE-IDENTICAL — 555 rows, same coverage, 0 reach.  Run `swift package resolve` in each",
        "tree first if this run is meant to be chained.  Harmless for a standalone A/B.",
    ] + ["    %s" % e for e in unfit[:6]] + (
        ["    … and %d more" % (len(unfit) - 6)] if len(unfit) > 6 else [])


def one_entry(job):
    entry, pre_cmd, post_cmd, timeout, marks, mark_env, mark_arm, oglob, oexcl = job
    label = os.path.basename(entry.rstrip("/")) or entry
    res = {"entry": entry, "label": label}
    arms = {}
    for name, cmd in (("pre", pre_cmd), ("post", post_cmd)):
        env = dict(mark_env) if (mark_arm in (name, "both")) else {}
        text, err_bytes, error = run_arm(cmd, entry, timeout, env, oglob, oexcl)
        if error is not None:
            res["error"] = "%s arm: %s" % (name, error)
            return res
        try:
            arms[name], res[name + "_judged"] = read_reports(text, label)
        except BadReport as e:
            res["error"] = "%s arm: unreadable report: %s" % (name, e)
            return res
        if mark_arm in (name, "both"):
            res.setdefault("reach", {})
            for m in marks:
                res["reach"][m] = res["reach"].get(m, 0) + err_bytes.count(m.encode())
    res["pre"], res["post"] = arms["pre"], arms["post"]
    return res


# ── the hollow diagnosis, asked of the authority ──────────────────────────────────────────────────
def hollow_diagnosis(paths):
    """AGENT-CORPUS-BRIEF §G: `bin/corpus.sh` owns the R242 content assertion.  We ask it; we do not
    carry a second copy that will drift from it."""
    script = os.path.join(HERE, "corpus.sh")
    if not os.path.exists(script):
        return {}
    try:
        p = subprocess.run(["bash", script, "--hollow-check"] + list(paths),
                           capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {"<error>": "could not ask bin/corpus.sh --hollow-check: %s" % e}
    out = {}
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[0] in ("ok", "HOLLOW", "MISSING", "EMPTY", "NOTGIT", "NOTDIR"):
            out[parts[1].split(" —")[0].strip()] = line.strip()
    return out


# ── reporting ─────────────────────────────────────────────────────────────────────────────────────
def fmt(d):
    return "ADDED %-7d REMOVED %-7d CHANGED %-7d  (keys: +%d -%d ~%d)" % (
        d["added_rows"], d["removed_rows"], d["changed_rows"],
        d["added_keys"], d["removed_keys"], d["changed_keys"])


def emit(msg=""):
    sys.stdout.write(msg + "\n")


def refuse(lines):
    emit()
    emit("=" * 96)
    emit("corpus-ab: NO COMPARISON WAS PRODUCED.  There is no diff below, because there is no diff.")
    for line in lines:
        emit("  " + line)
    emit("=" * 96)
    return 3


# ── main ──────────────────────────────────────────────────────────────────────────────────────────

# ── VERDICT BUCKETS ───────────────────────────────────────────────────────────────────────────
# SOUNDNESS R662/R664.  A CHANGED ROW IS NOT A CHANGED VERDICT, and conflating them is how a month
# of engine work gets reported as user-visible when most of it is advisory.  This lives HERE rather
# than in a scratchpad because R288: fifteen copies of an ad-hoc `ab.py` meant a defect found in one
# was fixed in none.  The classifier below was written in a scratchpad, run once, and had TWO errors
# caught by its own first gate-validation pass; both corrections are encoded as C1/C2 and both are
# calibrated in --selftest.
#
# C1 — A row with `interfaceUnion: true` is FILTERED AT EVERY GATE'S INGRESS (candor-query gate.rs,
#      load.rs, and candor-scan's own --policy: SOUNDNESS R511).  It is published, and it can never
#      move a verdict at its own qual, so it is not a gain a gate user can see.
# C2 — The key is (entry, pkg, fn, hash).  A NEW ROW DUPLICATING AN ALREADY-EFFECTFUL `fn` under a
#      different hash is a new KEY but not a new verdict: the scoped gate was already red there.
#      Integrated into this tool the test is exact — the PRE rows are already in hand, so unlike the
#      scratchpad original it does not re-read reports from a guessed path.
BUCKET_LABELS = [
    ("1", "1 absent/pure -> CONCRETE effect (a scoped deny moves)"),
    ("2", "2 absent/pure -> Unknown ONLY (disclosure; bare deny does not move)"),
    ("3", "3 CONCRETE effect LOST (a regression; expect ~0)"),
    ("4", "4 everything else (pure rows, other fields)"),
]


def _eff_of_values(vals):
    """(concrete effects, has Unknown, is an interfaceUnion row) over a row-value multiset."""
    concrete, unknown, union = set(), False, False
    for v in vals:
        try:
            r = json.loads(v)
        except (ValueError, TypeError):
            continue
        if not isinstance(r, dict):
            continue
        if r.get("interfaceUnion"):
            union = True
        for e in (r.get("inferred") or []):
            if e == "Unknown":
                unknown = True
            else:
                concrete.add(e)
    return concrete, unknown, union


def classify_verdicts(detail, pre_rows):
    """Sort a diff into verdict buckets.  `pre_rows` is the (entry, pkg, row) stream of the PRE arm."""
    pre_by_fn = collections.defaultdict(set)
    for entry, _pkg, row in pre_rows:
        for e in (row.get("inferred") or []):
            if e != "Unknown":
                pre_by_fn[(entry, row.get("fn"))].add(e)

    counts, dropped = collections.Counter(), collections.Counter()
    def cat1(key, pre, post):
        entry, fn = key[0], key[2] if len(key) > 2 else key[-1]
        if post[2]:
            dropped["union row — no gate can address it at its own qual (C1)"] += 1
            return
        if (post[0] - pre[0]) <= pre_by_fn.get((entry, fn), set()):
            dropped["duplicate of an already-red qual (C2)"] += 1
            return
        counts["1"] += 1
    def cat2(key, post):
        if post[2]:
            dropped["union row — no gate can address it at its own qual (C1)"] += 1
            return
        counts["2"] += 1

    for key, _n, vals in detail.get("added", []):
        post = _eff_of_values(vals)
        if post[0]:
            cat1(key, (set(), False, False), post)
        elif post[1]:
            cat2(key, post)
        else:
            counts["4"] += 1
    for key, _n, vals in detail.get("removed", []):
        counts["3" if _eff_of_values(vals)[0] else "4"] += 1
    for key, gone, came in detail.get("changed", []):
        pre, post = _eff_of_values(gone), _eff_of_values(came)
        P, Q = pre[0], post[0]
        if Q - P:
            cat1(key, pre, post)
        elif P - Q:
            counts["3"] += 1
        elif not P and not Q and post[1] and not pre[1]:
            cat2(key, post)
        else:
            counts["4"] += 1
    return {"counts": dict(counts), "dropped": dict(dropped)}


def build_parser():
    ap = argparse.ArgumentParser(
        prog="corpus-ab.py", add_help=True,
        description="The shared corpus A/B differential (SOUNDNESS R288/R242/R289).",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pre-cmd", help="argv template for the PRE arm; {entry} and {outdir} substituted")
    ap.add_argument("--post-cmd", help="argv template for the POST arm")
    ap.add_argument("--entry", action="append", default=[], help="one corpus entry (repeatable)")
    ap.add_argument("--entries-dir", action="append", default=[],
                    help="every immediate child directory of DIR is an entry (repeatable)")
    ap.add_argument("--entries-file", help="a file of entry paths, one per line")
    ap.add_argument("--pre-json", help="pair mode: a captured PRE report")
    ap.add_argument("--post-json", help="pair mode: a captured POST report")
    ap.add_argument("--mark", action="append", default=[],
                    help="a marker string your instrumented arm prints on stderr; counted as REACH")
    ap.add_argument("--mark-env", action="append", default=[],
                    help="K=V set only on the marked arm (e.g. CANDOR_ALIAS_DEBUG=1)")
    ap.add_argument("--mark-arm", choices=("pre", "post", "both"), default="post")
    ap.add_argument("--allow-zero-reach", action="store_true",
                    help="acknowledge that this A/B is safety-only, in writing, rather than silently")
    ap.add_argument("--key", choices=("unit", "pkgfn", "fn"), default="unit",
                    help="headline identity key; the corpus ENTRY is in all three "
                         "(unit = entry+package+fn+hash, the default)")
    ap.add_argument("--fields", help="narrow the compared VALUE to these fields (comma separated). "
                                     "The wide numbers are printed regardless.")
    ap.add_argument("--outdir-glob", default="*.json",
                    help="which files under {outdir} to read (default *.json)")
    ap.add_argument("--outdir-exclude", default=".callgraph.json,.hierarchy.json,.locs.json",
                    help="comma-separated basename SUFFIXES under {outdir} that are sidecars, not "
                         "reports.  A denylist: an unrecognised sidecar is refused loudly rather "
                         "than silently joining the diff.")
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=300)
    ap.add_argument("--limit", type=int, help="use only the first N entries (a smoke run)")
    ap.add_argument("--allow-fail", type=int, default=0,
                    help="tolerate up to N entries whose arm ERRORED; they are still named")
    ap.add_argument("--allow-unjudged", action="store_true",
                    help="compare the rest anyway when some entries have analyzed.count 0 (judged "
                         "nothing).  They are excluded from the diff and named on every run.")
    ap.add_argument("--out", help="write the full diff detail as JSON here")
    ap.add_argument("--allow-identical-arms", action="store_true",
                    help="acknowledge in writing that both arms are the SAME command over the SAME "
                         "bytes (R691); without it such a run REFUSES rather than self-comparing")
    ap.add_argument("--losses", action="store_true",
                    help="audit what the diff LOST, per field (R701): values present in the PRE arm "
                         "and absent from the POST one, plus every removed row")
    ap.add_argument("--buckets", action="store_true",
                    help="sort the diff into VERDICT buckets (R662/R664): a changed row is not a "
                         "changed verdict. A bucket-1 count PREDICTS a scoped-gate flip; validate it.")
    ap.add_argument("--selftest", action="store_true", help="run the four calibration proofs and exit")
    return ap


def collect_entries(args):
    entries = list(args.entry)
    for d in args.entries_dir:
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if os.path.isdir(p):
                entries.append(p)
    if args.entries_file:
        with open(args.entries_file) as fh:
            entries += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]
    if args.limit:
        entries = entries[:args.limit]
    return entries


def run(args):
    fields = tuple(f.strip() for f in args.fields.split(",")) if args.fields else None
    mark_env = {}
    for kv in args.mark_env:
        if "=" not in kv:
            emit("corpus-ab: --mark-env wants K=V, got %r" % kv)
            return 2
        k, v = kv.split("=", 1)
        mark_env[k] = v

    # ── gather both arms ──
    results = []
    swift_unfit = []
    arm_identity_note = ("arm identity: pair mode — two captured reports, so there is no command to "
                         "hash; the arms are whatever produced those files.")
    if args.pre_json or args.post_json:
        if not (args.pre_json and args.post_json):
            emit("corpus-ab: pair mode needs BOTH --pre-json and --post-json")
            return 2
        res = {"entry": args.pre_json, "label": os.path.basename(args.pre_json)}
        for name, path in (("pre", args.pre_json), ("post", args.post_json)):
            try:
                res[name], res[name + "_judged"] = read_reports(open(path).read(), res["label"])
            except (BadReport, OSError) as e:
                res["error"] = "%s arm: %s" % (name, e)
        results.append(res)
        entries = [args.pre_json]
    else:
        if not (args.pre_cmd and args.post_cmd):
            emit("corpus-ab: need --pre-cmd and --post-cmd (or --pre-json/--post-json)")
            return 2
        entries = collect_entries(args)
        if not entries:
            return refuse(["The entry set is EMPTY.  Nothing was scanned, so nothing was compared.",
                           "Check --entries-dir / --entry / --entries-file."])
        # BEFORE A SINGLE ENTRY IS SCANNED — R691.  Two arms that are the same thing cost hours and
        # then report a zero that reads like a safe change.
        same_arms, arm_note = arms_are_indistinguishable(args.pre_cmd, args.post_cmd,
                                                         mark_env, args.mark_arm)
        if same_arms and not args.allow_identical_arms:
            return refuse([
                arm_note,
                "",
                "THIS IS A SELF-COMPARISON.  It would print ADDED 0 / REMOVED 0 / CHANGED 0 — which is",
                "character-for-character what a correct, safely-inert change prints.  SOUNDNESS R691:",
                "a shared CARGO_TARGET_DIR made `cargo build --release` exit 0 in 0.02s without",
                "rebuilding, so a differential's PRE and POST were one binary.  The exit code was 0 and",
                "honest; only the content hash could tell.",
                "",
                "Rebuild the arms into SEPARATE target dirs and check `shasum` on the two binaries — or,",
                "if you meant to compare one binary with itself, pass --allow-identical-arms and say so",
                "in the row.",
            ])
        arm_identity_note = arm_note
        swift_unfit = swift_unresolved_entries(entries)
        oexcl = tuple(x.strip() for x in args.outdir_exclude.split(",") if x.strip())
        jobs = [(e, args.pre_cmd, args.post_cmd, args.timeout,
                 tuple(args.mark), mark_env, args.mark_arm, args.outdir_glob, oexcl)
                for e in entries]
        with cf.ProcessPoolExecutor(max_workers=max(1, args.jobs)) as ex:
            for res in ex.map(one_entry, jobs):
                results.append(res)

    # ── THE R242 PRECONDITION, KEYED ON THE INTEGER AND NOT ON THE EMPTINESS ──────────────────────
    # An entry that contributed zero rows is not necessarily an entry that changed nothing (R242) —
    # but it is not necessarily broken either, and SPEC ⟨0.24⟩ measured exactly what a rule keyed on
    # emptiness costs: over 1,997 JVM jars, 79 emit `count: 0` (of which 6 grant coverage) while 104
    # are the LEGITIMATE all-pure kind.  "A fix keyed on emptiness would have withdrawn 104 real
    # claims to catch 6."  The first version of this guard was keyed on emptiness and refused 238 of
    # the 1,509 rust registry crates — the plausible-but-wrong fix, live, on the first real run.
    #
    # So there are THREE classes, split on `analyzed.count`:
    #   ERROR      the arm failed, timed out, or emitted an unreadable report.       always fatal
    #   UNJUDGED   `analyzed.count` is 0 (or absent) with no rows: the engine judged NOTHING.  This is
    #              R242's exact signature and also SPEC ⟨0.24⟩'s "treat as NOT COVERED — it licenses
    #              no purity claim".                                       fatal, --allow-unjudged
    #   ALL-PURE   units were judged and none was reported.  A real, comparable entry.       compared
    # An entry with rows on one arm and none on the other is NOT an error: a fix that removes a small
    # crate's last row is a finding, and refusing it would hide the very thing E1 says to audit.
    bad, unjudged, allpure = [], [], []
    for r in results:
        if "error" in r:
            bad.append((r["entry"], r["error"]))
            continue
        for arm in ("pre", "post"):
            j = r.get(arm + "_judged")
            if not r[arm] and not j:
                unjudged.append((r["entry"], "%s arm: analyzed.count %s with no rows — NOTHING WAS JUDGED"
                                 % (arm, "0" if j == 0 else "absent")))
                break
        else:
            if not r["pre"] and not r["post"]:
                allpure.append(r["entry"])

    excluded = bad + (unjudged if not args.allow_unjudged else [])
    exc_set = {e for e, _ in excluded}
    good = [r for r in results if r["entry"] not in exc_set]

    over = (len(bad) > args.allow_fail) or (unjudged and not args.allow_unjudged)
    if over:
        lines = ["%d of %d entries could not be compared:" % (len(excluded), len(results))]
        if bad:
            lines.append("  %d ERRORED  (--allow-fail is %d)" % (len(bad), args.allow_fail))
        if unjudged and not args.allow_unjudged:
            lines.append("  %d judged NOTHING  (pass --allow-unjudged to compare the rest anyway)"
                         % len(unjudged))
        diag = hollow_diagnosis([e for e, _ in excluded[:40]])
        for e, why in excluded[:40]:
            lines.append("  %s" % e)
            lines.append("      %s" % why)
            if e in diag:
                lines.append("      bin/corpus.sh --hollow-check: %s" % diag[e])
        if len(excluded) > 40:
            lines.append("  … and %d more" % (len(excluded) - 40))
        # Say which class stopped the run.  A message about hollow trees printed over a list of
        # crashed arms sends the reader to the corpus when the fault is in the command.
        lines.append("")
        if unjudged and not args.allow_unjudged:
            lines += [
                "AN ENTRY THAT JUDGED NOTHING IS NOT AN ENTRY THAT CHANGED NOTHING — SOUNDNESS R242.",
                "A hollowed tree does not error: candor refuses it at exit 2, it contributes zero rows,",
                "and a differential over it prints ADDED 0 / REMOVED 0 / CHANGED 0, which is exactly",
                "what a correct, safely-inert change prints.  That is the result you were hoping for,",
                "which is why it stops here.  Check the named trees are real; then --allow-unjudged.",
            ]
        if len(bad) > args.allow_fail:
            lines += [
                "AN ARM THAT FAILED MEASURED NOTHING, and an A/B that quietly drops the entries it could",
                "not run reports a diff over a corpus it never names.  Fix the command or the entry —",
                "or raise --allow-fail deliberately, at which point every dropped entry is printed on",
                "every run.",
            ]
        return refuse(lines)

    if not good:
        return refuse(["Every entry was excluded, so the comparison covered NOTHING."])
    if not any(r["pre"] or r["post"] for r in good):
        # No flag reaches this one.  If nothing anywhere produced a row there is no comparison, and
        # saying so is the entire reason this file exists.
        return refuse(["NOT ONE of the %d compared entries produced a single report row, on either arm."
                       % len(good),
                       "There is no diff to report and no flag that makes one."])

    # ── flatten ──
    pre_rows, post_rows = [], []
    for r in good:
        pre_rows += [(r["entry"], p, row) for p, row in r["pre"]]
        post_rows += [(r["entry"], p, row) for p, row in r["post"]]

    # ── the calibration table.  Every run prices its own key, so nobody has to remember R288. ──
    head = diff_multiset(index_multiset(pre_rows, args.key, fields),
                         index_multiset(post_rows, args.key, fields))
    headline, detail = head

    emit()
    emit("corpus-ab  entries %d compared / %d given   rows  pre %d  post %d"
         % (len(good), len(results), len(pre_rows), len(post_rows)))
    # PRINTED ON EVERY RUN, INCLUDING WHEN IT PASSES — R691.  "The arms differ" is a claim this tool
    # makes, so it says on what evidence, and says NOT PROVEN when it could not look (§H).
    emit("  " + arm_identity_note)
    if args.allow_identical_arms:
        emit("  --allow-identical-arms: a self-comparison was ACKNOWLEDGED.  Every number below is a "
             "diff of one artefact against itself.")
    if swift_unfit:
        for line in swift_unresolved_note(swift_unfit, len(results)):
            emit("  " + line)
    if allpure:
        emit("  %d entr%s judged units and reported NO rows (the legitimate all-pure kind, SPEC ⟨0.24⟩)"
             % (len(allpure), "y" if len(allpure) == 1 else "ies"))
    if unjudged and args.allow_unjudged:
        # SOUNDNESS R307 — this used to say the entries were "NOT compared", which is the OPPOSITE of
        # what --allow-unjudged does: `excluded` drops them from the exclusion list, so they stay in
        # `good` and their rows JOIN the diff. The behaviour is the safe one (a 0 -> N transition
        # surfaces as ADDED), but a reader who believed the sentence computed a corpus 91 entries
        # smaller than the one that was actually measured. A tool that misdescribes its own scope is
        # the same class of defect as the silences it exists to find.
        emit("  %d entr%s judged NOTHING in one arm and %s COMPARED ANYWAY — --allow-unjudged,"
             % (len(unjudged), "y" if len(unjudged) == 1 else "ies",
                "was" if len(unjudged) == 1 else "were"))
        emit("  acknowledged. They remain in the %d compared above, and a 0 -> N transition in either"
             % len(good))
        emit("  direction WILL surface as ADDED/REMOVED. Listed so the population is auditable:")
        for e, _ in unjudged[:8]:
            emit("      %s" % e)
        if len(unjudged) > 8:
            emit("      … and %d more" % (len(unjudged) - 8))
    for e, why in bad:
        emit("  EXCLUDED  %s — %s" % (e, why))
    emit()
    emit("  %-34s %-9s %s" % ("KEY", "VALUE", "DIFF"))
    # EVERY ROW OF THIS TABLE IS COMPUTED WIDE EXCEPT THE LAST ONE, INCLUDING WHEN `--fields` NARROWS
    # THE HEADLINE.  The point of the table is to price what the operator's choices cost, and a table
    # that adopted the narrowing would price nothing — it would agree with the headline by
    # construction.  (The docstring claimed this before the code did it; `--selftest` [3] caught that.)
    narrow_fields = fields if fields else NARROW_DEFAULT
    rows_tbl = [
        ("entry+package+fn+hash, multiset", "wide", "unit", None),
        ("entry+package+fn,      multiset", "wide", "pkgfn", None),
        ("entry+fn,              multiset", "wide", "fn", None),
        ("entry+fn, LAST-WINS [old ab.py]", "wide", "fn", "lastwins"),
        ("entry+package+fn+hash, multiset", ",".join(narrow_fields)[:9], "unit", "narrow"),
    ]
    for label, vlabel, mode, kind in rows_tbl:
        if kind == "lastwins":
            d = diff_lastwins(index_lastwins(pre_rows, mode, None),
                              index_lastwins(post_rows, mode, None))
        elif kind == "narrow":
            d, _ = diff_multiset(index_multiset(pre_rows, mode, narrow_fields),
                                 index_multiset(post_rows, mode, narrow_fields))
        else:
            d, _ = diff_multiset(index_multiset(pre_rows, mode, None),
                                 index_multiset(post_rows, mode, None))
        star = " <<" if (mode == args.key and ((kind is None and fields is None)
                                               or (kind == "narrow" and fields is not None))) else ""
        emit("  %-34s %-9s %s%s" % (label, vlabel, fmt(d), star))
    emit()
    emit("  HEADLINE (--key %s, %s value):  %s"
         % (args.key, "narrow " + ",".join(fields) if fields else "wide", fmt(headline)))
    if fields:
        emit("  NARROWED VALUE — this diff is BLIND to every field outside %s.  §E1: a java audit keyed"
             % ",".join(fields))
        emit("  on `inferred` saw 400 of ~20,000 changed rows and concluded the fix was quiet.")

    # ── REACH, reported BESIDE the diff and never inside it ──
    emit()
    reach = collections.Counter()
    reach_entries = collections.Counter()
    # SOUNDNESS R307 — keep the SET, not only the tally. A count cannot be cross-checked against
    # anything: it could not answer "did the branch fire only in entries the run also skipped?", and
    # when a reach of 7 produced 819 row deltas there was no way to say which 7 without re-deriving
    # them by hand from lockfiles. The set is the difference between a number and evidence.
    reach_where = collections.defaultdict(list)
    for r in good:
        for m, n in (r.get("reach") or {}).items():
            if n:
                reach[m] += n
                reach_entries[m] += 1
                reach_where[m].append((r.get("entry"), n))
    zero_reach = False
    if args.mark:
        emit("  REACH (%s arm, counted on stderr) — an unchanged row is not evidence the code ran:" % args.mark_arm)
        for m in args.mark:
            emit("    %-40s %8d hits across %d entries" % (m, reach[m], reach_entries[m]))
            for ent, n in sorted(reach_where.get(m, []), key=lambda t: -t[1])[:5]:
                emit("        %6d  %s" % (n, ent))
            if len(reach_where.get(m, [])) > 5:
                emit("        … and %d more entries (full set in the --out JSON)"
                     % (len(reach_where[m]) - 5))
        zero_reach = not any(reach[m] for m in args.mark)
    else:
        emit("  REACH: NOT MEASURED.  This run cannot tell \"0 changed because the change is inert\"")
        emit("  from \"0 changed because the corpus never reached it\".  Pass --mark to separate them.")

    # ── VERDICT BUCKETS (--buckets) ──────────────────────────────────────────────────────────
    if args.buckets:
        emit()
        emit("  VERDICT BUCKETS — a changed ROW is not a changed VERDICT.")
        b = classify_verdicts(detail, pre_rows)
        tot = max(1, len(post_rows))
        for k, label in BUCKET_LABELS:
            n = b["counts"].get(k, 0)
            emit("    %-46s %6d   %.4f%% of %d post rows" % (label, n, 100.0 * n / tot, tot))
        if b["dropped"]:
            emit("    ── candidates DROPPED, and why a changed row is not a flip ──")
            for k, n in sorted(b["dropped"].items(), key=lambda kv: -kv[1]):
                emit("       %-43s %6d" % (k, n))
        emit("    A bucket-1 count is a PREDICTION about a scoped gate, not a measurement of one.")
        emit("    Validate it: run the real gate over a sample of bucket-1 quals on BOTH arms.")

    # ── WHAT DID IT LOSE (--losses) ───────────────────────────────────────────────────────────
    if args.losses:
        emit()
        emit("  LOSS AUDIT — §E1: the REMOVALS are the claim under test, and a lost KEY is not a lost")
        emit("  effect.  Every field, not just `inferred`.")
        la = losses_audit(detail)
        emit("    records audited: %d changed, %d removed" % (la["seen"]["changed"], la["seen"]["removed"]))
        if la["shape_errors"]:
            # A shape this audit does not understand is REPORTED, never skipped: skipping is what
            # printed `0 losses` over a real 91-row regression (R701).
            emit("    RECORD SHAPE NOT UNDERSTOOD — this audit could not look at %d record(s):"
                 % len(la["shape_errors"]))
            for e in la["shape_errors"][:4]:
                emit("      %s" % e)
            emit("    A loss audit that cannot read its input prints the same thing as a clean fix.")
        if not la["lost"]:
            emit("    NO field lost a value in any compared row.")
        for field, n in sorted(la["lost"].items(), key=lambda kv: -kv[1]):
            emit("    %-16s %6d value(s) lost" % (field, n))
            for key, vals in la["where"].get(field, []):
                emit("        %s  %s" % (" / ".join(str(x) for x in key), (vals or [""])[0][:70]))
        emit("    Audit the loss set in FULL and ground-truth it from the SOURCE, never from candor's")
        emit("    own report: a wrong removal and a right one are the same bytes.")

    # ── write detail ──
    if args.out:
        with open(args.out, "w") as fh:
            json.dump({"headline": headline, "key": args.key, "fields": fields,
                       "entries_compared": len(good), "entries_given": len(results),
                       "excluded": bad, "unjudged": unjudged, "all_pure": allpure, "pre_rows": len(pre_rows), "post_rows": len(post_rows),
                       "reach": dict(reach), "reach_entries": dict(reach_entries),
                       "reach_where": {k: v for k, v in reach_where.items()},
                       "detail": detail}, fh)
        emit()
        emit("  detail → %s" % args.out)

    # ── the "produced, but not evidence" exits ──
    empty = (headline["added_rows"] == 0 and headline["removed_rows"] == 0
             and headline["changed_rows"] == 0)
    if zero_reach and not args.allow_zero_reach:
        emit()
        emit("=" * 96)
        emit("corpus-ab: EVERY MARK COUNTED ZERO.  The corpus never reached the code under test, so this")
        emit("A/B is SAFETY-ONLY and its diff says nothing about the change.  Measured four times on")
        emit("2026-09-01 (R79/R85/R87/R92): full A/B, byte-identical, zero instances of the shape.")
        emit("Write that down in the row NOW, then re-run with --allow-zero-reach.")
        if swift_unfit:
            emit("")
            for line in swift_unresolved_note(swift_unfit, len(results)):
                emit(line)
        emit("=" * 96)
        return 4
    if empty and not args.mark and not args.allow_zero_reach:
        emit()
        emit("=" * 96)
        emit("corpus-ab: EMPTY DIFF WITH NO REACH MEASUREMENT.  This is the single most flattering and")
        emit("least informative number available, and it is indistinguishable from having measured")
        emit("nothing.  Instrument the branch you changed, pass --mark, and re-run — or pass")
        emit("--allow-zero-reach to record deliberately that you did not.")
        if swift_unfit:
            emit("")
            for line in swift_unresolved_note(swift_unfit, len(results)):
                emit(line)
        emit("=" * 96)
        return 4
    return 0


# ── selftest ──────────────────────────────────────────────────────────────────────────────────────
def _report(pkg, fns, judged=None):
    return json.dumps({"candor": {"spec": "0.35", "version": "fixture"}, "package": pkg,
                       "analyzed": {"count": len(fns) if judged is None else judged},
                       "functions": fns})


def _fn(name, inferred=None, why=None, invisible=None, loc="src/a.rs:1:1", hash_=None):
    r = {"fn": name, "loc": loc, "inferred": inferred or [],
         "hash": hash_ if hash_ is not None else "pkg#" + name}
    if why:
        r["unknownWhy"] = why
    if invisible:
        r["invisible"] = invisible
    return r


def selftest():
    """The four proofs.  A tool nobody has watched fail is not a tool."""
    tmp = tempfile.mkdtemp(prefix="corpus-ab-selftest.")
    fails = []

    def mk(entry, pre_fns, post_fns, pkg="pkg", err="", judged=None):
        d = os.path.join(tmp, entry)
        os.makedirs(d, exist_ok=True)
        open(os.path.join(d, "pre.json"), "w").write(_report(pkg, pre_fns, judged))
        open(os.path.join(d, "post.json"), "w").write(_report(pkg, post_fns, judged))
        open(os.path.join(d, "err"), "w").write(err)
        return d

    PRE = "bash -c 'cat {entry}/pre.json'"
    POST = "bash -c 'cat {entry}/post.json; cat {entry}/err >&2'"

    def go(argv):
        ap = build_parser()
        args = ap.parse_args(argv)
        import io
        buf = io.StringIO()
        old, sys.stdout = sys.stdout, buf
        try:
            rc = run(args)
        finally:
            sys.stdout = old
        return rc, buf.getvalue()

    def check(name, cond, extra=""):
        if cond:
            emit("  ok   %s" % name)
        else:
            emit("  FAIL %s%s" % (name, ("\n       " + extra) if extra else ""))
            fails.append(name)

    emit("corpus-ab --selftest")
    emit()
    emit("[1] R288 — a duplicate qual must not collapse.  5 byte-identical rows share one `fn`,")
    emit("    exactly the async-std/tiff shape, and all 5 move.  The old key reports 1.")
    dup_pre = [_fn("String::extend", ["Unknown"], ["ambiguous:x"]) for _ in range(5)] + \
              [_fn("other", [])]
    dup_post = [_fn("String::extend", ["Unknown"], ["macro:x"]) for _ in range(5)] + \
               [_fn("other", [])]
    e1 = mk("dupqual", dup_pre, dup_post)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e1, "--allow-zero-reach"])
    unit = [l for l in out.splitlines() if "entry+package+fn+hash, multiset" in l and "wide" in l]
    old = [l for l in out.splitlines() if "LAST-WINS" in l]
    check("exit 0", rc == 0, out)
    check("multiset key reports CHANGED 5", bool(unit) and "CHANGED 5 " in unit[0], out)
    check("the old fn last-wins key reports CHANGED 1", bool(old) and "CHANGED 1 " in old[0], out)
    # The table computes every key independently of the headline, so a row saying 5 does not prove the
    # HEADLINE says 5.  Mutating the headline back to the merged key left this whole section green.
    hl = [l for l in out.splitlines() if "HEADLINE" in l]
    check("and the HEADLINE — the number a reader quotes — says 5 too",
          bool(hl) and "CHANGED 5 " in hl[0], out)
    check("and they DIFFER, which is the whole finding",
          bool(unit) and bool(old) and unit[0].split("CHANGED")[1] != old[0].split("CHANGED")[1])

    emit()
    emit("[2] R242 — an entry that judged NOTHING must REFUSE, not return zeros …")
    e2 = mk("hollow", [], [], judged=0)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e1, "--entry", e2])
    check("exit 3 (no comparison produced)", rc == 3, out)
    check("names the entry", e2 in out, out)
    check("prints NO diff summary", "HEADLINE" not in out, out)
    check("cites R242", "R242" in out, out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e1, "--entry", e2,
                  "--allow-unjudged", "--allow-zero-reach"])
    check("--allow-unjudged still NAMES it on every run", rc == 0 and "judged NOTHING" in out and e2 in out, out)

    emit()
    emit("[2b] SPEC ⟨0.24⟩ CONTROL — the all-pure entry (analyzed.count 9, no rows) must be COMPARED.")
    emit("     A rule keyed on the EMPTINESS of `functions` withdraws 104 real claims to catch 6, and")
    emit("     the first version of this guard refused 238 of 1,509 real crates.  This row is why.")
    e2b = mk("allpure", [], [], judged=9)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e1, "--entry", e2b,
                  "--allow-zero-reach"])
    check("exit 0 — not refused", rc == 0, out)
    check("counted as the legitimate all-pure kind", "all-pure kind" in out, out)
    check("and it is NOT reported as unjudged", "judged NOTHING" not in out, out)

    emit()
    emit("[3] §E1 — a change an `inferred`-only key misses.  `invisible` moves; `inferred` does not.")
    e3 = mk("narrowmiss",
            [_fn("f", ["Fs"], None, ["dep_a"])],
            [_fn("f", ["Fs"], None, ["dep_a", "dep_b"])])
    rc, wide = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e3, "--allow-zero-reach"])
    rc2, narrow = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e3,
                      "--fields", "inferred", "--allow-zero-reach"])
    wl = [l for l in wide.splitlines() if "HEADLINE" in l]
    nl = [l for l in narrow.splitlines() if "HEADLINE" in l]
    check("wide value sees CHANGED 1", bool(wl) and "CHANGED 1 " in wl[0], wide)
    check("narrow `inferred` value sees CHANGED 0", bool(nl) and "CHANGED 0 " in nl[0], narrow)
    check("narrowing is announced, not silent", "BLIND" in narrow, narrow)
    check("the wide row is printed even when narrowed",
          any("entry+package+fn+hash, multiset" in l and "wide" in l and "CHANGED 1 " in l
              for l in narrow.splitlines()), narrow)

    emit()
    # ── [5] VERDICT BUCKETS (R662/R664) ──────────────────────────────────────────────────────
    # The classifier this promotes had TWO errors on its first real run, BOTH caught by gate
    # validation and NEITHER visible in its own output.  So both corrections are driven here, in
    # the direction that would hide them: each case is a row the naive classifier calls a
    # verdict change and which a real gate does NOT move.
    emit()
    emit("[5] VERDICT BUCKETS — a changed ROW is not a changed VERDICT.")
    def _v(**kw):
        return json.dumps(kw, sort_keys=True, separators=(",", ":"))
    cases = [
        ("a pure row gaining a CONCRETE effect is bucket 1",
         {"added": [[["e", "p", "f", "h1"], 1, [_v(inferred=["Net"])]]]}, [], "1", 1),
        ("C1: an interfaceUnion row gaining Net is NOT a flip",
         {"added": [[["e", "p", "f", "h1"], 1, [_v(inferred=["Net"], interfaceUnion=True)]]]}, [], "1", 0),
        ("C2: a duplicate of an already-red qual is NOT a flip",
         {"added": [[["e", "p", "f", "h2"], 1, [_v(inferred=["Net"])]]]},
         [("e", "p", {"fn": "f", "inferred": ["Net"]})], "1", 0),
        ("…but the SAME qual gaining a DIFFERENT effect IS a flip",
         {"added": [[["e", "p", "f", "h2"], 1, [_v(inferred=["Fs"])]]]},
         [("e", "p", {"fn": "f", "inferred": ["Net"]})], "1", 1),
        ("Unknown-only is bucket 2, never bucket 1",
         {"added": [[["e", "p", "f", "h1"], 1, [_v(inferred=["Unknown"])]]]}, [], "2", 1),
        ("…and the same row is NOT counted as a flip",
         {"added": [[["e", "p", "f", "h1"], 1, [_v(inferred=["Unknown"])]]]}, [], "1", 0),
        ("a LOST concrete effect is bucket 3",
         {"removed": [[["e", "p", "f", "h1"], 1, [_v(inferred=["Fs"])]]]}, [], "3", 1),
        ("a pure row appearing is bucket 4, not 1 or 2",
         {"added": [[["e", "p", "f", "h1"], 1, [_v(inferred=[])]]]}, [], "4", 1),
    ]
    for name, detail, pre_rows, bucket, want in cases:
        got = classify_verdicts(detail, pre_rows)["counts"].get(bucket, 0)
        if got == want:
            emit("  ok   %s" % name)
        else:
            emit("  FAIL %s — bucket %s got %d want %d" % (name, bucket, got, want))
            fails.append(name)

    emit("[4] VACUITY CONTROL — identical arms must return zero, so a zero means something.")
    same = [_fn("a", ["Fs"]), _fn("a", ["Fs"]), _fn("b", [], ["macro:y"])]
    e4 = mk("identical", same, list(same))
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e4, "--allow-zero-reach"])
    hl = [l for l in out.splitlines() if "HEADLINE" in l]
    check("identical arms → ADDED 0 REMOVED 0 CHANGED 0",
          bool(hl) and "ADDED 0" in hl[0] and "REMOVED 0" in hl[0] and "CHANGED 0" in hl[0], out)
    check("exit 0 when the vacuity is acknowledged", rc == 0, out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e4])
    check("but an unacknowledged empty diff with no reach exits 4", rc == 4, out)

    emit()
    emit("[5] REACH is reported beside the diff, and a zero-reach A/B says so.")
    e5 = mk("reached", [_fn("a", [])], [_fn("a", ["Fs"])], err="R290PROBE\nR290PROBE\n")
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e5, "--mark", "R290PROBE"])
    check("counts marks on the post arm's stderr", rc == 0 and "2 hits across 1 entries" in out, out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e5, "--mark", "NEVERPRINTED"])
    check("all-zero marks exit 4 and say SAFETY-ONLY",
          rc == 4 and "SAFETY-ONLY" in out, out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e5, "--mark", "NEVERPRINTED",
                  "--allow-zero-reach"])
    check("…and --allow-zero-reach acknowledges it", rc == 0, out)

    emit()
    emit("[6] R289 — a run that cannot produce a comparison must never look like a clean one.")
    rc, out = go(["--pre-cmd", "bash -c 'exit 2'", "--post-cmd", POST, "--entry", e1])
    check("a uniformly failing arm exits 3, not 0", rc == 3, out)
    check("…and prints no diff", "HEADLINE" not in out, out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entries-dir", os.path.join(tmp, "dupqual")])
    check("an empty entry set exits 3", rc == 3, out)
    e6 = mk("garbage", [_fn("a", [])], [_fn("a", [])])
    open(os.path.join(e6, "post.json"), "w").write("not json at all")
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e6])
    check("an unreadable report exits 3", rc == 3 and "unreadable" in out, out)

    emit()
    emit("[8] R691 — TWO ARMS THAT ARE ONE ARM.  A differential over one binary prints exactly what a")
    emit("    safely-inert change prints, and only the CONTENT HASH can tell.")
    binA = os.path.join(tmp, "engine-pre"); binB = os.path.join(tmp, "engine-post")
    binC = os.path.join(tmp, "engine-other")
    open(binA, "w").write("#!/bin/sh\ncat \"$1/pre.json\"\n")
    open(binB, "w").write("#!/bin/sh\ncat \"$1/pre.json\"\n")          # SAME bytes, different path
    open(binC, "w").write("#!/bin/sh\ncat \"$1/post.json\"\n")         # different bytes
    for b in (binA, binB, binC):
        os.chmod(b, 0o755)
    rc, out = go(["--pre-cmd", "sh %s {entry}" % binA, "--post-cmd", "sh %s {entry}" % binB,
                  "--entry", e1, "--allow-zero-reach"])
    check("identical-content arms REFUSE at exit 3", rc == 3, out)
    check("…naming the mechanism rather than the symptom", "SELF-COMPARISON" in out and "R691" in out, out)
    check("…and printing NO diff", "HEADLINE" not in out, out)
    rc, out = go(["--pre-cmd", "sh %s {entry}" % binA, "--post-cmd", "sh %s {entry}" % binB,
                  "--entry", e1, "--allow-zero-reach", "--allow-identical-arms"])
    check("--allow-identical-arms proceeds and SAYS it is a self-comparison",
          rc == 0 and "ACKNOWLEDGED" in out, out)
    rc, out = go(["--pre-cmd", "sh %s {entry}" % binA, "--post-cmd", "sh %s {entry}" % binC,
                  "--entry", e1, "--allow-zero-reach"])
    check("arms that genuinely differ run, and say so by hash",
          rc == 0 and "binaries differ" in out, out)
    # THE OVER-REFUSAL CONTROL, in both of its shapes.  A one-binary A/B is a real differential when
    # the flags or the env differ, and a check that refused those would be turned off within a day.
    rc, out = go(["--pre-cmd", "sh %s {entry}" % binA, "--post-cmd", "sh %s {entry} --wide" % binA,
                  "--entry", e1, "--allow-zero-reach"])
    check("CONTROL: same binary, DIFFERENT flags is not refused", rc == 0, out)
    check("…and is named as a one-binary differential", "one-binary differential" in out, out)
    rc, out = go(["--pre-cmd", "sh %s {entry}" % binA, "--post-cmd", "sh %s {entry}" % binA,
                  "--entry", e1, "--mark-env", "PROBE=1", "--mark-arm", "post", "--allow-zero-reach"])
    check("CONTROL: same binary, env on ONE arm only is not refused as a self-comparison",
          rc != 3 and "SELF-COMPARISON" not in out, out)
    rc, out = go(["--pre-cmd", "bash -c 'cat {entry}/pre.json'",
                  "--post-cmd", "bash -c 'cat {entry}/post.json'", "--entry", e1, "--allow-zero-reach"])
    check("when no token resolves to a file it says NOT PROVEN, never nothing (§H)",
          rc == 0 and "NOT PROVEN" in out, out)

    emit()
    emit("[9] R701 — A LOSS AUDIT THAT CANNOT SEE A LOSS PRINTS WHAT A CLEAN FIX PRINTS.  `changed`")
    emit("    records are [key, PRE, POST]; read as [key, values] every loss test is skipped.")
    def _v2(**kw):
        return json.dumps(kw, sort_keys=True, separators=(",", ":"))
    # (a) the exact shape of the near-miss: a ⟨0.39⟩ `dispatchesOn` key dropped while `inferred` holds.
    d_lost = {"changed": [[["e", "p", "EventLoopPromise.fail", "h1"],
                           [_v2(inferred=["Fs"], dispatchesOn=["Backend.size"])],
                           [_v2(inferred=["Fs"])]]]}
    la = losses_audit(d_lost)
    check("a dropped `dispatchesOn` key is counted as a loss",
          la["lost"].get("dispatchesOn") == 1, json.dumps(la))
    check("…and `inferred`, which did not move, is NOT counted", "inferred" not in la["lost"], json.dumps(la))
    check("…and the qual is named, not just tallied",
          any("EventLoopPromise.fail" in " / ".join(str(x) for x in k)
              for k, _ in la["where"]["dispatchesOn"]), json.dumps(la))
    # (b) the direction that must stay quiet: a field GAINED is not a loss.
    d_gain = {"changed": [[["e", "p", "f", "h1"], [_v2(inferred=["Fs"])],
                           [_v2(inferred=["Fs"], dispatchesOn=["X.y"])]]]}
    check("CONTROL: a field GAINED is not reported as lost", not losses_audit(d_gain)["lost"],
          json.dumps(losses_audit(d_gain)))
    # (c) a removed row loses everything it carried.
    d_rm = {"removed": [[["e", "p", "f", "h1"], 1, [_v2(inferred=["Net"])]]]}
    check("a REMOVED row counts as a loss on every field it carried",
          losses_audit(d_rm)["lost"].get("inferred") == 1, json.dumps(losses_audit(d_rm)))
    # (d) THE CALIBRATION THAT MATTERS — the wrong record shape must be REPORTED, not skipped.  This is
    #     the defect itself: feed the audit R701's misread record and it must refuse to call it clean.
    d_bad = {"changed": [[["e", "p", "f", "h1"], [_v2(inferred=["Fs"], dispatchesOn=["X.y"])]]]}
    la_bad = losses_audit(d_bad)
    check("a 2-element `changed` record is REPORTED as unreadable, never silently skipped",
          bool(la_bad["shape_errors"]) and la_bad["seen"]["changed"] == 0, json.dumps(la_bad))
    check("…and `0 losses` is therefore never printed over a record it could not read",
          not la_bad["lost"] and bool(la_bad["shape_errors"]), json.dumps(la_bad))
    # (e) end to end, through the real diff machinery rather than a hand-built detail.
    e9 = mk("lossrun", [_fn("f", ["Fs"]), _fn("g", ["Net"])], [_fn("f", ["Fs"])])
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", e9, "--losses", "--allow-zero-reach"])
    check("--losses over a real run names the lost field and the count",
          rc == 0 and "LOSS AUDIT" in out and "inferred" in out.split("LOSS AUDIT")[1], out)

    emit()
    emit("[10] R700 — A SWIFTPM ENTRY WITH NO `.build/checkouts` CANNOT CHAIN, and a chained A/B over")
    emit("     one measures two unchained scans: byte-identical, 0 reach, which reads as inert.")
    def _spm(name, manifest, resolved=None, checkouts=False):
        d = mk(name, [_fn("f", ["Fs"])], [_fn("f", ["Fs"])])
        open(os.path.join(d, "Package.swift"), "w").write(manifest)
        if resolved is not None:
            open(os.path.join(d, "Package.resolved"), "w").write(resolved)
        if checkouts:
            os.makedirs(os.path.join(d, ".build", "checkouts"), exist_ok=True)
        return d
    dep_manifest = 'let package = Package(name: "x", dependencies: [.package(url: "u", from: "1.0.0")])\n'
    unresolved = _spm("spm-unresolved", dep_manifest)
    pinned = _spm("spm-pinned", 'let package = Package(name: "x")\n',
                  resolved=json.dumps({"pins": [{"identity": "nio"}]}))
    ok_checkouts = _spm("spm-resolved", dep_manifest, checkouts=True)
    nodeps = _spm("spm-nodeps", 'let package = Package(name: "x", targets: [])\n')
    plain = mk("not-spm", [_fn("f", ["Fs"])], [_fn("f", ["Fs"])])
    check("an unresolved SwiftPM tree is named", swift_unresolved_entries([unresolved]) == [unresolved])
    check("…and so is one whose Package.resolved holds pins (SwiftPM's own record, §G)",
          swift_unresolved_entries([pinned]) == [pinned])
    check("CONTROL: a tree WITH .build/checkouts is not named",
          swift_unresolved_entries([ok_checkouts]) == [])
    check("CONTROL: a SwiftPM tree with NO dependencies is not named",
          swift_unresolved_entries([nodeps]) == [])
    check("CONTROL: a non-SwiftPM entry is not named", swift_unresolved_entries([plain]) == [])
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", unresolved])
    check("the exit-4 refusal REPEATS the diagnosis, where the reader is looking",
          rc == 4 and "R700" in out.split("=" * 96)[-2], out)
    rc, out = go(["--pre-cmd", PRE, "--post-cmd", POST, "--entry", unresolved, "--allow-zero-reach"])
    check("…and it is ADVISORY: a standalone swift A/B still runs", rc == 0 and "R700" in out, out)

    emit()
    emit("[7] all four engines' report shapes parse.")
    shapes = {
        "rust/ts/swift envelope": _report("async_std", [_fn("io::copy", [])]),
        "JVM `packages` list": json.dumps({"packages": ["app"], "functions": [
            {"fn": "app.Cell.f", "hash": "app/Cell.f()V", "inferred": []}]}),
        "legacy v0.1 bare array": json.dumps([{"fn": "f", "hash": "p#f", "inferred": []}]),
        "a concatenated report SET": _report("a", [_fn("f", [])]) + "\n" + _report("b", [_fn("f", [])]),
    }
    for name, text in shapes.items():
        try:
            rows, judged = read_reports(text, "x")
            check("%s → %d row(s), package %s, analyzed.count %s"
                  % (name, len(rows), rows[0][0], judged), bool(rows))
        except BadReport as e:
            check(name, False, str(e))
    # The set case is the one where a bare `fn` key would MERGE two genuinely different units.
    setrows, _ = read_reports(shapes["a concatenated report SET"], "x")
    check("a report set keeps two same-named units apart",
          len({row_key("e", p, r, "pkgfn") for p, r in setrows}) == 2)
    check("…and a bare `fn` key merges them, which is why package is in the key",
          len({row_key("e", p, r, "fn") for p, r in setrows}) == 1)
    check("two ENTRIES sharing a package name never merge (flate2-1.1.9 vs flate2-1.1.10)",
          len({row_key(e, "flate2", {"fn": "f", "hash": "flate2#f"}, "unit")
               for e in ("flate2-1.1.9", "flate2-1.1.10")}) == 2)

    emit()
    if fails:
        emit("corpus-ab selftest: %d FAILED — %s" % (len(fails), "; ".join(fails)))
        return 1
    emit("corpus-ab selftest: OK")
    return 0


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.selftest:
        return selftest()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
