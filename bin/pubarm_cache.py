#!/usr/bin/env python3
"""bin/pubarm_cache.py — a DURABLE, KEYED cache of a PUBLISHED release's corpus results.

WHY THIS EXISTS
===============
Every corpus A/B has two arms, and the PUBLISHED arm (the previous release's engine over the corpus) never
changes: the same jar over the same entries gives the same report.  Round-2 lanes re-scanned it from scratch
each time, into /private/tmp, which the macOS cleaner wipes after ~3 days — about half the lanes' spend was
redoing a measurement that already existed once.  This is the one place that measurement lives:

    /Users/tom/candor-handoff/pubarm/<candor version>/<engine>/
        MANIFEST.json                       what was filled, with what, when, how long, how big
        entries/<label>-<entrysha16>.meta.json     the key this entry was stored under
        entries/<label>-<entrysha16>.report.gz     the raw report text the arm produced
        entries/<label>-<entrysha16>.callgraph.json.gz   the arm's `--out` call-graph SIDECAR, if it wrote one
                                                         ({fn: [callee,...]}, every analysed unit a key; a tree
                                                         with several sidecars is merged by union)

(`CANDOR_PUBARM` overrides the root.)  Outside /private/tmp on purpose.

A STALE OR MISMATCHED ENTRY CANNOT BE READ AS CURRENT
=====================================================
A cache that returns the wrong thing is worse than no cache: its numbers look measured.  So a lookup is
keyed on EVERYTHING that determines the report, and every part is re-verified on read:

  version        the candor RELEASE the cache was filled for (the directory).  NOTE the report's own
                 `candor.version` is NOT that: candor-java 0.40.18 prints a git short sha there ("8656e03"),
                 measured 2026-11-02.  So the label is tied to the artefact two other ways: `fill` takes
                 `--engine-sha256` (the digest the release page publishes) and refuses unless the engine
                 file's content hash equals it, and every entry records the `candor.version` it saw.
  engine sha     sha256 of every file the arm's command names (the jar, the interpreter...) — the content,
                 not the path.  corpus-ab.py's `arm_identity` computes it; this module does not copy it (R288).
  cmd key        the arm's command with those files masked: a different flag is a different measurement.
  entry sha      sha256 of the corpus entry's CONTENT (a file; or a directory tree, path+content).  Same
                 label, different bytes -> a miss.
  report sha     of the stored report, so a truncated or edited file is a miss, not a short corpus.

THE SIDECAR (why it is stored).  An A/B of a candidate against a PUBLISHED version needs the SAME KIND of call
graph on both arms.  The candidate arm has a sidecar (`--out`); a cache that kept only the report forced the
published arm onto the report's `calls` lists, and the two route interfaceUnion differently: on a java release bar
17 `hasEdgeConnecting` units read as class flips, and the same 452 jars gave 0 with sidecars on both arms.  So `fill`
now keeps the sidecar beside the report, under its own sha (`callgraph_sha256` in the meta), and `lookup_callgraph`
verifies it on read.  An entry filled BEFORE this had none: `meta.callgraph` is absent, `lookup_callgraph` raises
CacheMiss("... predates sidecar storage"), and `bin/ab-price.py --arms` reports the arm graph-less / report-graph and
says the pair is not like-with-like.  `fill --require-callgraph` fails an entry whose arm wrote no sidecar (use it
whenever the arm command is meant to; an engine or flag that writes none is otherwise a silent graph-less fill), and
an entry already cached WITHOUT a sidecar is re-filled under that flag rather than skipped.

A MISS NEVER RETURNS EMPTY.  `lookup` raises `CacheMiss` with the specific reason (no such version / engine
sha differs: cached X wanted Y / ...).  An empty or unreadable report is `CacheMiss` too — `fill` refuses to
store one (R242: an entry that judged nothing is not a measurement).

USAGE
=====
  bin/pubarm_cache.py fill   --version 0.40.18 --engine java --cmd 'java -jar JAR {entry} --json {outdir}/r.json'
                             --entries-dir DIR [--jobs 4] [--timeout 600] [--require-callgraph]
  bin/pubarm_cache.py status [--version V] [--engine E]
  bin/pubarm_cache.py check  --version V --engine E --cmd '...' --entries-dir DIR     # hit/miss per entry
  bin/pubarm_cache.py --selftest
  # and from the A/B:  bin/corpus-ab.py --pre-cache 0.40.18:java --pre-cmd '<same cmd>' ...
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import gzip
import hashlib
import importlib.util
import json
import os
import re
import shutil
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.expanduser("~/candor-handoff/pubarm")
SCHEMA = 1
SKIP_DIRS = {".git", "target", "node_modules", ".build", "build", ".gradle"}


class CacheMiss(Exception):
    """A lookup that cannot be answered from the cache.  The message says why; callers surface it."""


def root_dir():
    return os.environ.get("CANDOR_PUBARM") or DEFAULT_ROOT


def arm_dir(version, engine, root=None):
    return os.path.join(root or root_dir(), version, engine)


def _sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def entry_identity(path):
    """(sha256, kind, size).  A file is its content; a directory is every (relpath, content-sha) under it,
    sorted, minus VCS/build dirs.  Raises CacheMiss if the path does not exist (an entry that is not there
    has no identity to look up)."""
    path = path.rstrip("/") if len(path) > 1 else path
    if os.path.isfile(path):
        return _sha256_file(path), "file", os.path.getsize(path)
    if os.path.isdir(path):
        h, size = hashlib.sha256(), 0
        for dp, dns, fns in os.walk(path):
            dns[:] = sorted(d for d in dns if d not in SKIP_DIRS)
            for fn in sorted(fns):
                p = os.path.join(dp, fn)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                h.update(os.path.relpath(p, path).encode() + b"\0" + _sha256_file(p).encode() + b"\n")
                size += os.path.getsize(p)
        return h.hexdigest(), "dir", size
    raise CacheMiss("corpus entry %r does not exist, so it has no identity to look up" % path)


def entry_id(path, esha):
    label = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(path.rstrip("/")) or "entry")
    return "%s-%s" % (label, esha[:16])


def cmd_key(residual):
    return hashlib.sha256(json.dumps(list(residual)).encode()).hexdigest()


def _paths(version, engine, eid, root=None):
    d = os.path.join(arm_dir(version, engine, root), "entries")
    return os.path.join(d, eid + ".meta.json"), os.path.join(d, eid + ".report.gz")


def _atomic_write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def _report_version(text):
    """The `candor.version` the report itself carries (first document), or None."""
    m = re.search(r'"candor"\s*:\s*\{[^{}]*?"version"\s*:\s*"([^"]*)"', text)
    return m.group(1) if m else None


def merge_callgraphs(texts):
    """Union of {fn: [callee,...]} documents -> one document (text).  Refuses anything that is not that shape."""
    out = {}
    for t in texts:
        d = json.loads(t)
        if not isinstance(d, dict) or not all(isinstance(v, list) for v in d.values()):
            raise CacheMiss("a call-graph sidecar is not a {fn: [callee,...]} map — refusing to store it")
        for k, v in d.items():
            cur = out.setdefault(k, [])
            cur.extend(c for c in v if c not in cur)
    return json.dumps(out, sort_keys=True)


def store(version, engine, entry_path, text, engine_hashes, residual, secs=None, root=None, judged=None,
          expect_report_version=None, callgraph=None):
    """Write one entry.  Refuses an empty report, and (if given) a report whose own `candor.version` is not
    `expect_report_version`."""
    if not text or not text.strip():
        raise CacheMiss("refusing to store an EMPTY report for %s (R242: that is not a measurement)" % entry_path)
    if not engine_hashes:
        raise CacheMiss("the arm command names no file that exists, so the engine cannot be identified; "
                        "an unidentified engine cannot key a cache")
    rv = _report_version(text)
    if expect_report_version is not None and rv != expect_report_version:
        raise CacheMiss("the report says candor.version=%r but %r was expected — the wrong engine was run.  "
                        "Not stored." % (rv, expect_report_version))
    esha, kind, size = entry_identity(entry_path)
    eid = entry_id(entry_path, esha)
    raw = text.encode("utf-8")
    gz = gzip.compress(raw, 6)
    meta = {"schema": SCHEMA, "version": version, "engine": engine, "entry_label": os.path.basename(entry_path.rstrip("/")),
            "entry_sha256": esha, "entry_kind": kind, "entry_bytes": size,
            "engine_sha256": sorted(engine_hashes), "cmd_key": cmd_key(residual), "cmd_residual": list(residual),
            "report_candor_version": rv, "report_sha256": hashlib.sha256(raw).hexdigest(),
            "report_bytes": len(raw), "stored_bytes": len(gz), "scan_seconds": secs, "judged": judged,
            "stored_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    mp, rp = _paths(version, engine, eid, root)
    cp = _cg_path(rp)
    if callgraph is not None and callgraph.strip():
        craw = callgraph.encode("utf-8")
        meta["callgraph"] = {"sha256": hashlib.sha256(craw).hexdigest(), "bytes": len(craw)}
        _atomic_write(cp, gzip.compress(craw, 6))
    elif os.path.exists(cp):
        os.unlink(cp)        # a re-store without a sidecar must not leave an older one claiming to match
    _atomic_write(rp, gz)
    _atomic_write(mp, json.dumps(meta, indent=1, sort_keys=True).encode())
    return meta


def _cg_path(report_path):
    return report_path[:-len(".report.gz")] + ".callgraph.json.gz"


def lookup_callgraph(version, engine, entry_path, root=None):
    """-> sidecar text, verified against the sha its meta recorded.  Raises CacheMiss(reason): no sidecar stored
    (an entry filled before sidecars were kept, or an arm that wrote none), or the file is missing/corrupt/edited.
    Call AFTER `lookup` has verified the entry's key; this only answers for the sidecar."""
    esha, _k, _s = entry_identity(entry_path)
    eid = entry_id(entry_path, esha)
    mp, rp = _paths(version, engine, eid, root)
    try:
        meta = json.load(open(mp))
    except (OSError, ValueError) as e:
        raise CacheMiss("meta for %s unreadable: %s" % (eid, e))
    want = (meta.get("callgraph") or {}).get("sha256")
    if not want:
        raise CacheMiss("entry %s has NO call-graph sidecar stored (filled before sidecars were kept, or the arm wrote "
                        "none) — refill with --require-callgraph" % eid)
    cp = _cg_path(rp)
    try:
        raw = gzip.decompress(open(cp, "rb").read())
    except (OSError, EOFError, ValueError) as e:
        raise CacheMiss("call-graph sidecar for %s unreadable (%s) — missing, truncated or corrupt" % (eid, e))
    if hashlib.sha256(raw).hexdigest() != want:
        raise CacheMiss("call-graph sidecar for %s fails its own sha — edited or truncated" % eid)
    return raw.decode("utf-8")


def lookup(version, engine, entry_path, engine_hashes, residual, root=None):
    """-> (report_text, meta).  Raises CacheMiss(reason) — never returns an empty or unverified report."""
    base = arm_dir(version, engine, root)
    if not os.path.isdir(os.path.join(base, "entries")):
        r = root or root_dir()
        present = []
        if os.path.isdir(r):
            for v in sorted(os.listdir(r)):
                present += ["%s/%s" % (v, e) for e in sorted(os.listdir(os.path.join(r, v)))
                            if os.path.isdir(os.path.join(r, v, e))]
        raise CacheMiss("no cache for version %s engine %s at %s (present: %s)"
                        % (version, engine, base, ", ".join(present) or "nothing"))
    esha, _kind, _size = entry_identity(entry_path)
    eid = entry_id(entry_path, esha)
    mp, rp = _paths(version, engine, eid, root)
    if not os.path.isfile(mp) or not os.path.isfile(rp):
        label = os.path.basename(entry_path.rstrip("/"))
        near = sorted(f[:-len(".meta.json")] for f in os.listdir(os.path.join(base, "entries"))
                      if f.endswith(".meta.json") and f.startswith(re.sub(r"[^A-Za-z0-9._-]", "_", label) + "-"))
        raise CacheMiss("no entry %s under %s%s" % (eid, base, (" — same label cached with different content: %s "
                        "(entry bytes changed since the fill)" % ", ".join(near[:3])) if near else
                        " — this entry was never filled"))
    try:
        meta = json.load(open(mp))
    except (OSError, ValueError) as e:
        raise CacheMiss("meta for %s unreadable: %s" % (eid, e))
    want = {"schema": SCHEMA, "version": version, "engine": engine, "entry_sha256": esha,
            "engine_sha256": sorted(engine_hashes), "cmd_key": cmd_key(residual)}
    for k, v in want.items():
        if meta.get(k) != v:
            what = {"engine_sha256": "engine sha differs", "cmd_key": "arm command differs",
                    "entry_sha256": "entry content differs", "version": "version differs",
                    "engine": "engine differs", "schema": "schema differs"}[k]
            extra = ""
            if k == "engine_sha256":
                extra = ": cached %s, wanted %s" % ([h[:12] for h in meta.get(k) or []], [h[:12] for h in v])
            if k == "cmd_key":
                extra = ": cached %s, wanted %s" % (meta.get("cmd_residual"), list(residual))
            raise CacheMiss("%s for %s%s" % (what, eid, extra))
    try:
        raw = gzip.decompress(open(rp, "rb").read())
    except (OSError, EOFError, ValueError) as e:
        raise CacheMiss("report for %s unreadable (%s) — truncated or corrupt" % (eid, e))
    if hashlib.sha256(raw).hexdigest() != meta.get("report_sha256") or not raw.strip():
        raise CacheMiss("report for %s fails its own sha (or is empty) — edited or truncated" % eid)
    return raw.decode("utf-8"), meta


def _load_ab():
    spec = importlib.util.spec_from_file_location("corpus_ab", os.path.join(HERE, "corpus-ab.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["corpus_ab"] = mod
    spec.loader.exec_module(mod)
    return mod


def identity_of(template):
    """(engine_hashes list, residual tuple) for an arm command — corpus-ab.py's own `arm_identity`."""
    h, r = _load_ab().arm_identity(template)
    return list(h), r


def _list_entries(args):
    out = []
    for d in args.entries_dir:
        out += sorted(os.path.join(d, x) for x in os.listdir(d) if not x.startswith("."))
    out += list(args.entry)
    if getattr(args, "entries_file", None):
        out += [l.strip() for l in open(args.entries_file) if l.strip()]
    return out


def _fill_one(job):
    entry, template, version, engine, timeout, hashes, residual, root, expect_rv, keep_unjudged, need_cg = job
    ab = _load_ab()
    t0 = time.time()
    cgs = []
    text, _err, error = ab.run_arm(template, entry, timeout, {}, "*.json", (".callgraph.json", ".hierarchy.json", ".locs.json"),
                                   callgraph_out=cgs)
    secs = round(time.time() - t0, 1)
    if error is not None:
        return entry, None, "scan failed: %s" % error, secs
    try:
        _rows, judged = ab.read_reports(text, os.path.basename(entry))
    except Exception as e:   # noqa: BLE001 — surface any reader refusal as this entry's failure
        return entry, None, "unreadable report: %s" % e, secs
    if not judged and not _rows and not keep_unjudged:
        return entry, None, "judged NOTHING (analyzed.count %s, no rows) — R242, not stored (pass --store-unjudged to keep it)" % judged, secs
    if need_cg and not cgs:
        return entry, None, "--require-callgraph: the arm wrote NO *.callgraph.json under {outdir} (does --cmd pass --out " \
                            "{outdir}/r and the engine's call-graph flag?) — not stored", secs
    try:
        meta = store(version, engine, entry, text, hashes, residual, secs, root, judged, expect_rv,
                     callgraph=merge_callgraphs(cgs) if cgs else None)
    except (CacheMiss, ValueError) as e:
        return entry, None, str(e), secs
    return entry, meta, None, secs


def cmd_fill(args):
    entries = _list_entries(args)
    if not entries:
        print("pubarm fill: the entry set is EMPTY — nothing to fill")
        return 3
    hashes, residual = identity_of(args.cmd)
    if not hashes:
        print("pubarm fill: --cmd names no file that exists, so the engine cannot be identified.  Refusing.")
        return 3
    root = args.root
    if args.engine_sha256 and args.engine_sha256.lower() not in hashes:
        print("pubarm fill: REFUSING — the engine file(s) in --cmd hash to %s, but --engine-sha256 says the "
              "%s release is %s.  This is not that artefact." % ([h[:12] for h in hashes], args.version,
                                                                args.engine_sha256[:12]))
        return 3
    t0 = time.time()
    ok, failed, skipped = [], [], 0
    jobs = []
    for e in entries:
        try:
            lookup(args.version, args.engine, e, hashes, residual, root)
            if args.require_callgraph:
                lookup_callgraph(args.version, args.engine, e, root)   # cached WITHOUT a sidecar -> refill, not skip
            skipped += 1                     # already cached AND verified — resumable
        except CacheMiss:
            jobs.append((e, args.cmd, args.version, args.engine, args.timeout, hashes, residual, root,
                         args.expect_report_version, args.store_unjudged, args.require_callgraph))
    with cf.ProcessPoolExecutor(max_workers=max(1, args.jobs)) as ex:
        for entry, meta, err, secs in ex.map(_fill_one, jobs):
            if err:
                failed.append((entry, err))
                print("  FAILED %s — %s" % (entry, err), flush=True)
            else:
                ok.append(meta)
    wall = round(time.time() - t0, 1)
    write_manifest(args.version, args.engine, root, args.cmd, residual, hashes, wall, failed)
    st = status_of(args.version, args.engine, root)
    print("pubarm fill %s/%s: %d entries given, %d already cached, %d filled, %d FAILED, wall %.0fs, "
          "now %d entries / %.1f MB stored (%.1f MB raw)"
          % (args.version, args.engine, len(entries), skipped, len(ok), len(failed), wall,
             st["entries"], st["stored_bytes"] / 1e6, st["report_bytes"] / 1e6))
    return 1 if failed else 0


def status_of(version, engine, root=None):
    d = os.path.join(arm_dir(version, engine, root), "entries")
    n = sb = rb = ncg = 0
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith(".meta.json"):
                try:
                    m = json.load(open(os.path.join(d, f)))
                except (OSError, ValueError):
                    continue
                n += 1
                ncg += 1 if (m.get("callgraph") or {}).get("sha256") else 0
                sb += m.get("stored_bytes", 0)
                rb += m.get("report_bytes", 0)
    return {"entries": n, "stored_bytes": sb, "report_bytes": rb, "callgraphs": ncg}


def write_manifest(version, engine, root, template, residual, hashes, wall, failed):
    st = status_of(version, engine, root)
    prior = 0.0
    try:
        prior = json.load(open(os.path.join(arm_dir(version, engine, root), "MANIFEST.json"))).get("fill_wall_seconds_total", 0.0)
    except (OSError, ValueError):
        pass
    man = {"fill_wall_seconds_total": round(prior + wall, 1), "schema": SCHEMA, "version": version, "engine": engine, "arm_command": template,
           "cmd_residual": list(residual), "engine_sha256": sorted(hashes), "filled_wall_seconds_last_run": wall,
           "entries": st["entries"], "stored_bytes": st["stored_bytes"], "report_bytes": st["report_bytes"],
           "failed_last_run": [{"entry": e, "why": w} for e, w in failed],
           "updated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
           "note": "Advisory summary only. A lookup trusts the per-entry .meta.json it re-verifies, never this file."}
    _atomic_write(os.path.join(arm_dir(version, engine, root), "MANIFEST.json"), json.dumps(man, indent=1).encode())


def cmd_status(args):
    root = args.root or root_dir()
    if not os.path.isdir(root):
        print("pubarm: no cache root at %s" % root)
        return 0
    for v in sorted(os.listdir(root)):
        if args.version and v != args.version:
            continue
        vd = os.path.join(root, v)
        if v.startswith("_"):
            continue            # _engines/ holds the pinned jars, not a cache
        for e in sorted(os.listdir(vd)) if os.path.isdir(vd) else []:
            if args.engine and e != args.engine:
                continue
            st = status_of(v, e, root)
            print("%-10s %-8s %5d entries (%d with call-graph sidecar)  %8.1f MB stored  %8.1f MB raw" %
                  (v, e, st["entries"], st["callgraphs"], st["stored_bytes"] / 1e6, st["report_bytes"] / 1e6))
    return 0


def cmd_check(args):
    hashes, residual = identity_of(args.cmd)
    hit = miss = 0
    for e in _list_entries(args):
        try:
            lookup(args.version, args.engine, e, hashes, residual, args.root)
            hit += 1
        except CacheMiss as m:
            miss += 1
            print("  MISS %s — %s" % (e, m))
    print("pubarm check: %d hit, %d MISS" % (hit, miss))
    return 0 if not miss else 1


def selftest():
    tmp = tempfile.mkdtemp(prefix="pubarm-selftest.")
    fails = []

    def expect(label, cond):
        print("  %-4s %s" % ("ok" if cond else "FAIL", label))
        if not cond:
            fails.append(label)

    def must_miss(label, frag, **kw):
        try:
            lookup(**kw)
            expect(label + " (returned a report instead of missing)", False)
        except CacheMiss as e:
            expect("%s -> MISS mentions %r" % (label, frag), frag in str(e))

    try:
        root = os.path.join(tmp, "root")
        ent = os.path.join(tmp, "lib-1.0.jar")
        eng = os.path.join(tmp, "engine.jar")
        open(ent, "wb").write(b"entry-bytes-v1")
        open(eng, "wb").write(b"engine-bytes-v1")
        rep = json.dumps({"candor": {"spec": "0.35", "version": "9.9.9"}, "package": "p",
                          "analyzed": {"count": 1}, "functions": [{"fn": "a", "inferred": ["Fs"]}]})
        hashes, resid = identity_of("%s %s" % (eng, "{entry}"))
        expect("identity names the engine file by content", len(hashes) == 1 and len(hashes[0]) == 64)
        base = dict(version="9.9.9", engine="java", entry_path=ent, engine_hashes=hashes, residual=resid, root=root)
        store("9.9.9", "java", ent, rep, hashes, resid, 1.0, root)
        text, meta = lookup(**base)
        expect("positive control: exact key HITS and returns the stored text", text == rep and meta["scan_seconds"] == 1.0)
        # every key component, mutated one at a time, must MISS
        must_miss("another version", "no cache for version", **{**base, "version": "9.9.8"})
        must_miss("another engine name", "no cache for version", **{**base, "engine": "rust"})
        must_miss("another engine binary", "engine sha differs", **{**base, "engine_hashes": ["0" * 64]})
        must_miss("another arm command", "arm command differs", **{**base, "residual": resid + ("--extra",)})
        ent2 = os.path.join(tmp, "other-1.0.jar")
        open(ent2, "wb").write(b"x")
        must_miss("an entry never filled", "never filled", **{**base, "entry_path": ent2})
        must_miss("a missing entry path", "does not exist", **{**base, "entry_path": os.path.join(tmp, "nope")})
        # SAME LABEL, DIFFERENT BYTES (the stale-entry case) must name the staleness, not just miss
        open(ent, "wb").write(b"entry-bytes-v2")
        must_miss("entry bytes changed under the same label", "same label cached with different content", **base)
        open(ent, "wb").write(b"entry-bytes-v1")
        expect("restoring the bytes HITS again (the key is content, not mtime)", lookup(**base)[0] == rep)
        # corruption
        mp, rp = _paths("9.9.9", "java", entry_id(ent, entry_identity(ent)[0]), root)
        good = open(rp, "rb").read()
        open(rp, "wb").write(good[: len(good) // 2])
        must_miss("a truncated report", "unreadable", **base)
        open(rp, "wb").write(gzip.compress(rep.replace("Fs", "Net").encode()))
        must_miss("an edited report (valid gzip, wrong sha)", "fails its own sha", **base)
        open(rp, "wb").write(good)
        expect("repairing it HITS again", lookup(**base)[0] == rep)
        # refusals at store
        for label, kwargs in (("empty report", dict(text="  \n")),
                              ("report from an unexpected engine build",
                               dict(text=rep.replace("9.9.9", "9.9.8"), expect_report_version="9.9.9"))):
            try:
                store("9.9.9", "java", ent, kwargs.pop("text"), hashes, resid, 1.0, root, **kwargs)
                expect("store refuses a " + label, False)
            except CacheMiss:
                expect("store refuses a " + label, True)
        try:
            store("9.9.9", "java", ent, rep, [], resid, 1.0, root)
            expect("store refuses an unidentified engine", False)
        except CacheMiss:
            expect("store refuses an unidentified engine", True)
        # directory entries: any content change moves the identity
        dent = os.path.join(tmp, "crate")
        os.makedirs(os.path.join(dent, "src"))
        open(os.path.join(dent, "src", "a.rs"), "w").write("fn a(){}")
        os.makedirs(os.path.join(dent, ".git"))
        open(os.path.join(dent, ".git", "HEAD"), "w").write("x")
        s1 = entry_identity(dent)[0]
        open(os.path.join(dent, ".git", "HEAD"), "w").write("y")
        expect("directory identity ignores .git", entry_identity(dent)[0] == s1)
        open(os.path.join(dent, "src", "a.rs"), "w").write("fn b(){}")
        expect("directory identity moves with a source edit", entry_identity(dent)[0] != s1)
        # call-graph sidecar: stored beside the report, verified on read, never invented
        cg = json.dumps({"a": ["b"], "b": []})
        try:
            lookup_callgraph("9.9.9", "java", ent, root)
            expect("an entry stored WITHOUT a sidecar answers CacheMiss, not an empty graph", False)
        except CacheMiss as e:
            expect("an entry stored WITHOUT a sidecar answers CacheMiss, not an empty graph", "NO call-graph sidecar" in str(e))
        store("9.9.9", "java", ent, rep, hashes, resid, 1.0, root, callgraph=cg)
        expect("sidecar round-trips", json.loads(lookup_callgraph("9.9.9", "java", ent, root)) == {"a": ["b"], "b": []})
        cp = _cg_path(mp[:-len(".meta.json")] + ".report.gz")
        goodcg = open(cp, "rb").read()
        open(cp, "wb").write(gzip.compress(b'{"a": []}'))
        try:
            lookup_callgraph("9.9.9", "java", ent, root)
            expect("an edited sidecar (valid gzip, wrong sha) is a MISS", False)
        except CacheMiss as e:
            expect("an edited sidecar (valid gzip, wrong sha) is a MISS", "fails its own sha" in str(e))
        os.unlink(cp)
        try:
            lookup_callgraph("9.9.9", "java", ent, root)
            expect("a deleted sidecar is a MISS", False)
        except CacheMiss:
            expect("a deleted sidecar is a MISS", True)
        open(cp, "wb").write(goodcg)
        expect("restoring it HITS again", "a" in json.loads(lookup_callgraph("9.9.9", "java", ent, root)))
        store("9.9.9", "java", ent, rep, hashes, resid, 1.0, root)
        expect("re-storing without a sidecar removes the old one (it cannot claim to match)", not os.path.exists(cp))
        expect("merge_callgraphs unions per-package sidecars",
               json.loads(merge_callgraphs(['{"a":["b"]}', '{"a":["c"],"z":[]}'])) == {"a": ["b", "c"], "z": []})
        try:
            merge_callgraphs(['["not","a","map"]'])
            expect("merge_callgraphs refuses a non-graph shape", False)
        except CacheMiss:
            expect("merge_callgraphs refuses a non-graph shape", True)
        # END TO END through `fill`: a fake engine that writes a report + sidecar under {outdir}, and one that writes none
        eng_ok = os.path.join(tmp, "eng-ok.sh")
        eng_nocg = os.path.join(tmp, "eng-nocg.sh")
        body = 'out="$2"\nprintf \'%s\' \'' + rep + '\' > "$out/r.json"\n'
        open(eng_ok, "w").write("#!/bin/bash\n" + body + 'printf \'{"a":["b"],"b":[]}\' > "$out/r.callgraph.json"\n')
        open(eng_nocg, "w").write("#!/bin/bash\n" + body)
        import argparse as _ap
        for eng_path, req, want_fail, label in ((eng_ok, True, 0, "arm WITH a sidecar, --require-callgraph"),
                                                (eng_nocg, True, 1, "arm with NO sidecar, --require-callgraph FAILS the entry"),
                                                (eng_nocg, False, 0, "arm with no sidecar, no flag: stored graph-less")):
            r2 = os.path.join(tmp, "root-" + label[:6].replace(" ", "_") + str(req))
            tmpl = "bash %s {entry} {outdir}" % eng_path
            a = _ap.Namespace(cmd=tmpl, version="9.9.9", engine="java", entries_dir=[], entry=[ent], entries_file=None,
                              root=r2, engine_sha256=None, store_unjudged=False, expect_report_version=None,
                              require_callgraph=req, jobs=1, timeout=60)
            import io
            import contextlib
            with contextlib.redirect_stdout(io.StringIO()):
                rc = cmd_fill(a)
            expect("fill: " + label + " -> failed=%d" % want_fail, rc == want_fail)
            h2, rs2 = identity_of(tmpl)
            if eng_path == eng_ok:
                expect("fill stored a verified sidecar", json.loads(lookup_callgraph("9.9.9", "java", ent, r2)) == {"a": ["b"], "b": []})
                expect("status counts it", status_of("9.9.9", "java", r2)["callgraphs"] == 1)
        # status / manifest
        write_manifest("9.9.9", "java", root, "t", resid, hashes, 1.0, [])
        expect("manifest written and status counts the entry", status_of("9.9.9", "java", root)["entries"] == 1)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if fails:
        print("pubarm_cache selftest: %d FAILED — %s" % (len(fails), "; ".join(fails)))
        return 1
    print("pubarm_cache selftest: OK")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="pubarm_cache.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--selftest", action="store_true")
    sub = ap.add_subparsers(dest="sub")
    for name in ("fill", "check"):
        p = sub.add_parser(name)
        p.add_argument("--version", required=True)
        p.add_argument("--engine", required=True)
        p.add_argument("--cmd", required=True, help="the arm command template; {entry} and {outdir} substituted")
        p.add_argument("--entries-dir", action="append", default=[])
        p.add_argument("--entry", action="append", default=[])
        p.add_argument("--entries-file")
        p.add_argument("--root")
        p.add_argument("--engine-sha256", help="fill: the release's published digest; refuse unless the engine "
                                               "file in --cmd hashes to exactly this")
        p.add_argument("--store-unjudged", action="store_true",
                       help="fill: also store an entry that judged NOTHING (analyzed.count 0, no rows).  Without "
                            "this it is refused (R242).  Needed to serve an A/B that runs --allow-unjudged; the "
                            "stored meta records judged=0 so the fact is not lost.")
        p.add_argument("--expect-report-version", help="fill: refuse any report whose candor.version differs")
        p.add_argument("--require-callgraph", action="store_true",
                       help="fill: an entry whose arm wrote no *.callgraph.json sidecar FAILS (and one cached without "
                            "a sidecar is refilled).  Needed for an A/B against a candidate arm that has one.")
        p.add_argument("--jobs", type=int, default=2)
        p.add_argument("--timeout", type=int, default=600)
    p = sub.add_parser("status")
    p.add_argument("--version")
    p.add_argument("--engine")
    p.add_argument("--root")
    args = ap.parse_args(argv)
    if args.selftest:
        return selftest()
    if args.sub == "fill":
        return cmd_fill(args)
    if args.sub == "check":
        return cmd_check(args)
    if args.sub == "status":
        return cmd_status(args)
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
