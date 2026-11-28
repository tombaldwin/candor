#!/usr/bin/env python3
"""swift_indexstore.py: read a Swift/clang index store through libIndexStore's C API (ctypes). Helper of
bin/swift-index-diff.py; usable alone:

    python3 -I bin/swift_indexstore.py <store-dir> [--src-prefix P] [--out occ.jsonl.gz]

Each occurrence is one JSON object:
    {"file","module","line","col","usr","name","kind","roles":[...],"rel":[[roles,usr,name],...]}

Unit selection (Fable review 2026-11-28, change 8): EVERY unit in the store is read and the occurrence set is the
UNION over all of them. A file compiled in two targets or two configurations has one record per distinct content
and active-arm set; records are de-duplicated by record name (content-addressed), never by file, so no unit's arm is
dropped. Staleness is measured, not assumed: a source file whose mtime is newer than the unit that indexed it is
counted, and `stats["stale_files"]` lists it. The caller decides whether a stale store is a measurement.

The library is found from `$SWIFT_INDEXSTORE_LIB`, else next to the active `swift` (xcrun / PATH), else Xcode's
default toolchain. Nothing here builds or executes the package."""
import ctypes as C
import gzip
import json
import os
import shutil
import subprocess
import sys

ROLES = ['decl', 'def', 'ref', 'read', 'write', 'call', 'dynamic', 'addressof', 'implicit', 'childOf', 'baseOf',
         'overrideOf', 'receivedBy', 'calledBy', 'extendedBy', 'accessorOf', 'containedBy', 'ibTypeOf',
         'specializationOf']
DEP_UNIT, DEP_RECORD, DEP_FILE = 1, 2, 3


def find_lib():
    env = os.environ.get('SWIFT_INDEXSTORE_LIB')
    if env:
        return env
    cands = []
    sw = None
    try:
        sw = subprocess.check_output(['xcrun', '--find', 'swift'], text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        sw = shutil.which('swift')
    if sw:
        lib = os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(sw))), 'lib')
        cands += [os.path.join(lib, 'libIndexStore.dylib'), os.path.join(lib, 'libIndexStore.so')]
    cands.append('/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib')
    for c in cands:
        if os.path.exists(c):
            return c
    raise SystemExit('swift_indexstore: libIndexStore not found (set SWIFT_INDEXSTORE_LIB); tried ' + ', '.join(cands))


class _SR(C.Structure):
    _fields_ = [('data', C.c_char_p), ('length', C.c_size_t)]


_P = C.c_void_p
_CB = C.CFUNCTYPE(C.c_bool, _P, _P)


def _load(path):
    L = C.CDLL(path)

    def sig(name, res, args):
        f = getattr(L, name)
        f.restype = res
        f.argtypes = args
    sig('indexstore_store_create', _P, [C.c_char_p, C.POINTER(_P)])
    sig('indexstore_error_get_description', C.c_char_p, [_P])
    sig('indexstore_unit_reader_create', _P, [_P, C.c_char_p, C.POINTER(_P)])
    for f in ('indexstore_unit_reader_get_main_file', 'indexstore_unit_reader_get_module_name',
              'indexstore_unit_reader_get_target', 'indexstore_unit_reader_get_output_file'):
        sig(f, _SR, [_P])
    sig('indexstore_unit_reader_get_modification_time', None, [_P, C.POINTER(C.c_int64), C.POINTER(C.c_int64)])
    sig('indexstore_unit_reader_dependencies_apply_f', C.c_bool, [_P, _P, _CB])
    sig('indexstore_unit_dependency_get_kind', C.c_int, [_P])
    for f in ('indexstore_unit_dependency_get_filepath', 'indexstore_unit_dependency_get_name'):
        sig(f, _SR, [_P])
    sig('indexstore_record_reader_create', _P, [_P, C.c_char_p, C.POINTER(_P)])
    sig('indexstore_record_reader_occurrences_apply_f', C.c_bool, [_P, _P, _CB])
    sig('indexstore_occurrence_get_symbol', _P, [_P])
    sig('indexstore_occurrence_get_roles', C.c_uint64, [_P])
    sig('indexstore_occurrence_get_line_col', None, [_P, C.POINTER(C.c_uint), C.POINTER(C.c_uint)])
    sig('indexstore_occurrence_relations_apply_f', C.c_bool, [_P, _P, _CB])
    sig('indexstore_symbol_relation_get_roles', C.c_uint64, [_P])
    sig('indexstore_symbol_relation_get_symbol', _P, [_P])
    for f in ('indexstore_symbol_get_usr', 'indexstore_symbol_get_name'):
        sig(f, _SR, [_P])
    sig('indexstore_symbol_get_kind', C.c_int, [_P])
    sig('indexstore_symbol_get_subkind', C.c_int, [_P])
    sig('indexstore_record_reader_dispose', None, [_P])
    sig('indexstore_unit_reader_dispose', None, [_P])
    sig('indexstore_store_dispose', None, [_P])
    return L


def _s(x):
    return C.string_at(x.data, x.length).decode('utf-8', 'replace') if x.data else ''


def _roles(x):
    return [n for i, n in enumerate(ROLES) if x >> i & 1]


def read_store(store, src_prefix=None, lib=None):
    """Return (occurrences, stats). Occurrences are dicts (schema in the module docstring)."""
    L = _load(lib or find_lib())
    err = _P()
    st = L.indexstore_store_create(store.encode(), C.byref(err))
    if not st:
        raise SystemExit('swift_indexstore: cannot open store %s: %s' % (store, L.indexstore_error_get_description(err).decode()))
    udir = os.path.join(store, 'v5', 'units')
    if not os.path.isdir(udir):
        raise SystemExit('swift_indexstore: %s has no v5/units — not an index store' % store)
    pref = os.path.realpath(src_prefix) if src_prefix else None

    def own(fp):
        return pref is None or os.path.realpath(fp).startswith(pref + os.sep)
    records = {}           # record name -> (filepath, module)
    file_records = {}      # filepath -> set(record names)
    stale = set()
    units = 0
    for un in sorted(os.listdir(udir)):
        ur = L.indexstore_unit_reader_create(st, un.encode(), C.byref(err))
        if not ur:
            continue
        units += 1
        mod = _s(L.indexstore_unit_reader_get_module_name(ur))
        sec, nsec = C.c_int64(), C.c_int64()
        L.indexstore_unit_reader_get_modification_time(ur, C.byref(sec), C.byref(nsec))
        utime = sec.value + nsec.value / 1e9
        deps = []

        def dep(ctx, d, deps=deps):
            k = L.indexstore_unit_dependency_get_kind(d)
            if k in (DEP_RECORD, DEP_FILE):
                deps.append((k, _s(L.indexstore_unit_dependency_get_name(d)), _s(L.indexstore_unit_dependency_get_filepath(d))))
            return True
        L.indexstore_unit_reader_dependencies_apply_f(ur, None, _CB(dep))
        L.indexstore_unit_reader_dispose(ur)
        for k, rn, fp in deps:
            if not fp or not own(fp):
                continue
            try:
                if os.path.getmtime(fp) > utime + 1e-3:
                    stale.add(fp)
            except OSError:
                pass
            if k == DEP_RECORD:
                records.setdefault(rn, (fp, mod))
                file_records.setdefault(fp, set()).add(rn)
    occ = []
    for rn, (fp, mod) in sorted(records.items()):
        rr = L.indexstore_record_reader_create(st, rn.encode(), C.byref(err))
        if not rr:
            continue

        def one(ctx, o, fp=fp, mod=mod):
            ln, col = C.c_uint(), C.c_uint()
            L.indexstore_occurrence_get_line_col(o, C.byref(ln), C.byref(col))
            sp = L.indexstore_occurrence_get_symbol(o)
            rel = []

            def r(ctx2, rl):
                rs = L.indexstore_symbol_relation_get_symbol(rl)
                rel.append([_roles(L.indexstore_symbol_relation_get_roles(rl)), _s(L.indexstore_symbol_get_usr(rs)),
                            _s(L.indexstore_symbol_get_name(rs))])
                return True
            L.indexstore_occurrence_relations_apply_f(o, None, _CB(r))
            occ.append(dict(file=fp, module=mod, line=ln.value, col=col.value, usr=_s(L.indexstore_symbol_get_usr(sp)),
                            name=_s(L.indexstore_symbol_get_name(sp)), kind=L.indexstore_symbol_get_kind(sp),
                            sub=L.indexstore_symbol_get_subkind(sp),
                            roles=_roles(L.indexstore_occurrence_get_roles(o)), rel=rel))
            return True
        L.indexstore_record_reader_occurrences_apply_f(rr, None, _CB(one))
        L.indexstore_record_reader_dispose(rr)
    L.indexstore_store_dispose(st)
    # the same occurrence can appear in two records of one file (two configurations agreeing on it): de-duplicate
    seen, uniq = set(), []
    for o in occ:
        k = (o['file'], o['line'], o['col'], o['usr'], tuple(o['roles']), tuple(r[1] for r in o['rel']))
        if k not in seen:
            seen.add(k)
            uniq.append(o)
    stats = dict(units=units, records=len(records), files=len(file_records),
                 multi_record_files=sum(1 for v in file_records.values() if len(v) > 1),
                 occurrences=len(uniq), stale_files=sorted(stale))
    return uniq, stats


def write_occ(path, occ):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'wt') as f:
        for o in occ:
            f.write(json.dumps(o, separators=(',', ':')) + '\n')


def load_occ(path):
    op = gzip.open if path.endswith('.gz') else open
    with op(path, 'rt') as f:
        return [json.loads(line) for line in f if line.strip()]


def main(argv):
    if not argv or argv[0] in ('-h', '--help'):
        print(__doc__)
        return 0
    store = argv[0]
    pref = argv[argv.index('--src-prefix') + 1] if '--src-prefix' in argv else None
    out = argv[argv.index('--out') + 1] if '--out' in argv else None
    occ, stats = read_store(store, pref)
    if out:
        write_occ(out, occ)
    else:
        for o in occ:
            sys.stdout.write(json.dumps(o) + '\n')
    sys.stderr.write(json.dumps({k: (v if k != 'stale_files' else len(v)) for k, v in stats.items()}) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
