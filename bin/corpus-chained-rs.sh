#!/usr/bin/env bash
# corpus-chained-rs.sh — THE RUST HALF OF THE CHAINED CENSUS.  SOUNDNESS R673(a) is the gap; this
# closes it.  `bin/corpus-chained.sh` is the java half; the two are separate scripts because every
# line of the java one is about jars, javac and a classpath, and rust shares none of that.
#
#     bash bin/corpus-chained-rs.sh calibrate  --r609 PRE,POST --r652 PRE,POST
#     bash bin/corpus-chained-rs.sh build      --entries FILE --work DIR [--jobs N] [--cap N]
#     bash bin/corpus-chained-rs.sh scan       ENTRY ENGINE OUTDIR WORK VARIANT [KEEPDIR]
#     bash bin/corpus-chained-rs.sh standalone --pre BIN --post BIN --entries FILE --work DIR --out DIR
#     bash bin/corpus-chained-rs.sh measure    --pre BIN --post BIN --entries FILE --work DIR --out DIR
#                                             --variant noimpl|impl
#     bash bin/corpus-chained-rs.sh validate   --pre BIN --post BIN --work DIR --out DIR [--sample N]
#
# WHY.  Every rust census so far ([[R662]]/[[R664]]) scanned each crate STANDALONE.  A standalone scan
# answers "does the engine parse this crate"; it cannot answer "does the engine understand how this
# crate is USED", and the whole ⟨0.39⟩ chained-dispatch rung lives in the second question — literally:
# `e4808bf`'s own conjunct 2 is CHAINED, so no standalone scan of any crate can exhibit it.  R664
# measured a month of rust fixes as flipping ZERO gates at module scope and ZERO at crate scope.  This
# arm asks whether that zero survives a consumer.
#
# THE TWO HALVES MOVE TOGETHER ([[R608]]).  PRE = pre-engine library report + pre-engine consumer scan.
# A fixed library report read by a varying consumer engine measures a mixture and the number is
# worthless, so `scan` takes ONE engine and uses it for both halves.
#
# THE CONSUMER IS GENERATED (bin/corpus-chained/consumer-gen-rs) FROM THE LIBRARY'S PUBLIC API AS
# `syn` SEES IT — not from the engine's own report, which omits pure functions by design and could only
# ever probe what the engine already sees.  The consumer SOURCE is generated ONCE and shared by both
# arms, so the only variable between them is the engine binary.
#
# TWO CONSUMER VARIANTS, because ⟨0.39⟩ conjunct 4 is asked of the CRATE ("this crate supplies no
# implementor of that abstraction") and one crate cannot both withhold and supply one:
#   noimpl  the java arm's shape.  Nothing effectful is planted, so every effect in the consumer
#           arrived across the dependency boundary — the module- and crate-scope arithmetic is clean
#           and this is the variant whose scope figures are quotable.
#   impl    an effectful implementor of every public trait, in one separate top-level module.  R529's
#           chained shape, and the only one that can see the implementor-union half of the window
#           (R576b/R597/R598/R652).  Its crate ALREADY carries the planted effect on both arms, so its
#           module/crate figures are NOT quotable — function scope and the probe-state table are.
#
# ABSENT IS NOT PURE ([[R636]]).  `bin/corpus-chained-judge.py --lang rust` buckets a missing consumer
# row as ABSENT in its own column and never as pure.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GENSRC="$HERE/bin/corpus-chained/consumer-gen-rs"
CENSUS="${CANDOR_CENSUS_HOME:-$HOME/.candor/census}/rust"

die() { echo "corpus-chained-rs: $*" >&2; exit 2; }
[ -d "$GENSRC" ] || die "REFUSING — no generator at $GENSRC"

# The generator is built ONCE into the caller's work dir, never into the repo: a `target/` inside
# bin/ dirties the tree and `release.sh` step 0 then refuses (and a conformance run would attribute
# the dirt to itself — CLAUDE.md records that exact false verdict).
gen_bin() {
  local work="$1"
  local out="$work/gen-target/release/consumer-gen-rs"
  if [ ! -x "$out" ]; then
    ( cd "$GENSRC" && CARGO_TARGET_DIR="$work/gen-target" cargo build --release >"$work/gen-build.log" 2>&1 ) \
      || { echo "consumer-gen-rs did not build:" >&2; tail -20 "$work/gen-build.log" >&2; return 3; }
  fi
  echo "$out"
}

# ── one entry, one engine: the library report (cached), then the consumer scan that chains it ──────
# The library report depends only on (entry, engine) and never on the consumer variant or the policy,
# so it is cached under a digest of the engine binary.  Without that, the same multi-megabyte crate is
# re-scanned once per variant and once per validated qual.
lib_report() {
  local entry="$1" eng="$2" work="$3"
  local name; name="$(basename "$entry")"
  local tag; tag="$(shasum -a 1 "$eng" | cut -c1-12)"
  local d="$work/libreports/$tag"; mkdir -p "$d"
  if [ ! -s "$d/$name.json" ]; then
    "$eng" "$entry" --json > "$d/$name.json.part" 2>"$d/$name.err" || { rm -f "$d/$name.json.part"; return 3; }
    mv "$d/$name.json.part" "$d/$name.json"
  fi
  [ -s "$d/$name.json" ] || return 3
  echo "$d/$name.json"
}

cmd_scan() {
  local entry="$1" eng="$2" outdir="$3" work="$4" variant="$5" keep="${6:-}"
  local name; name="$(basename "$entry")"
  local cdir="$work/c/$variant/$name"
  [ -f "$cdir/src/lib.rs" ] || { echo "no $variant consumer built for $name (run: build)" >&2; return 3; }
  # A consumer with no probe source scans clean for a reason that has nothing to do with the engine.
  # R242: zero rows and a correctly-inert change print the same thing.
  if [ -z "$(find "$cdir/src" -name '*.rs' ! -name lib.rs -print -quit 2>/dev/null)" ]; then
    echo "$variant consumer for $name holds NO probe module — refusing to report it as a clean scan" >&2
    return 3
  fi
  local lib; lib="$(lib_report "$entry" "$eng" "$work")" || {
    echo "library arm FAILED for $name" >&2; return 3; }
  mkdir -p "$outdir"
  CANDOR_DEPS="$lib" "$eng" "$cdir" --json > "$outdir/consumer.json" 2>"$outdir/consumer.err"
  local rc=$?
  if [ ! -s "$outdir/consumer.json" ]; then
    echo "consumer arm produced no report for $name (rc=$rc):" >&2; tail -3 "$outdir/consumer.err" >&2
    return 3
  fi
  # The arm's consumer report is KEPT, per arm, so the scope table and the absent-row accounting are
  # computed from the same bytes the A/B compared — not from a re-run.
  if [ -n "$keep" ]; then mkdir -p "$keep" && cp "$outdir/consumer.json" "$keep/$name.json"; fi
  return 0
}

# One arm, one entry, STANDALONE — the same library report the chained arm uses, so the two
# measurements are over one set of bytes and the only difference is the consumer.
cmd_scanlib() {
  local entry="$1" eng="$2" outdir="$3" work="$4"
  local name; name="$(basename "$entry")"
  local lib; lib="$(lib_report "$entry" "$eng" "$work")" || { echo "library arm FAILED for $name" >&2; return 3; }
  mkdir -p "$outdir"; cp "$lib" "$outdir/lib.json"
}

# ── generate both consumer variants, once, engine-independently ────────────────────────────────────
cmd_build() {
  local entries="" work="" jobs=6 cap=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --entries) entries="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;;
      --jobs) jobs="$2"; shift 2 ;;
      --cap) cap="$2"; shift 2 ;;
      *) die "build: unknown argument $1" ;;
    esac
  done
  [ -f "$entries" ] || die "build: --entries FILE is required"
  [ -n "$work" ] || die "build: --work DIR is required"
  bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1 || die "disk-guard is unhappy — a full disk fakes an empty corpus"
  mkdir -p "$work/c/noimpl" "$work/c/impl" "$work/gen"
  local G; G="$(gen_bin "$work")" || exit 3
  # `${arr[@]}` on an EMPTY array is an unbound-variable error under `set -u` on bash 3.2, which is
  # what macOS ships.  Measured: every one of 21 entries printed GEN-FAIL and the build reported
  # "entries WITH both consumers: 0" — loud, but a plain string avoids the question.
  local capflag=""; [ "$cap" -gt 0 ] && capflag="--cap $cap"
  local n=0
  while read -r entry; do
    [ -n "$entry" ] || continue
    (
      nm="$(basename "$entry")"
      for v in noimpl impl; do
        "$G" "$entry" "$work/c/$v/$nm" "$work/gen/$nm.$v.json" $capflag --variant "$v" \
          >"$work/gen/$nm.$v.log" 2>&1 || echo "  GEN-FAIL($v) $nm: $(tail -1 "$work/gen/$nm.$v.log")"
      done
    ) &
    n=$((n + 1)); [ $((n % jobs)) -eq 0 ] && wait
  done < "$entries"
  wait
  # THE ENTRY SET THE MEASUREMENT MAY USE.  A crate with no public trait, no public fn and no public
  # inherent method yields ZERO probes — and so does a bin-only crate with no lib target.  That is a
  # property of the crate, not a failure of the run, and such entries are NAMED and dropped rather
  # than carried into the A/B with an empty consumer: an entry contributing zero rows prints exactly
  # like a change that is correctly inert (R242).
  # ONE LIST PER VARIANT, not one list for both.  A crate with no public TRAIT yields no `impl`
  # consumer and a perfectly good `noimpl` one; intersecting the two lists would drop it from the
  # measurement it can support, and a smaller denominator moves every percentage the flattering way.
  : > "$work/entries-noprobe.txt"
  for v in noimpl impl; do : > "$work/entries-built-$v.txt"; done
  while read -r entry; do
    [ -n "$entry" ] || continue
    local nm; nm="$(basename "$entry")"
    for v in noimpl impl; do
      if [ -f "$work/c/$v/$nm/src/lib.rs" ]; then
        echo "$entry" >> "$work/entries-built-$v.txt"
      else
        echo "$v	$entry	$(tail -1 "$work/gen/$nm.$v.log" 2>/dev/null)" >> "$work/entries-noprobe.txt"
      fi
    done
  done < "$entries"
  echo "corpus-chained-rs build: $n entries"
  for v in noimpl impl; do
    echo "  entries with a $v consumer: $(grep -c . "$work/entries-built-$v.txt")"
  done
  echo "  variant/entry pairs with NO consumer (named, and in no denominator): $(grep -c . "$work/entries-noprobe.txt")"
  awk -F'\t' '{split($3,a," "); print $1, a[1]}' "$work/entries-noprobe.txt" | sort | uniq -c | sort -rn | sed 's/^/     /'
  python3 "$HERE/bin/corpus-chained-judge.py" --coverage-rs "$work" "$entries"
}

cmd_measure() {
  local pre="" post="" entries="" work="" out="" jobs=6 variant="noimpl"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pre) pre="$2"; shift 2 ;;  --post) post="$2"; shift 2 ;;
      --entries) entries="$2"; shift 2 ;; --work) work="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;; --jobs) jobs="$2"; shift 2 ;;
      --variant) variant="$2"; shift 2 ;;
      *) die "measure: unknown argument $1" ;;
    esac
  done
  [ -x "$pre" ] && [ -x "$post" ] || die "measure: --pre and --post must both name engine binaries"
  [ -n "$work" ] && [ -n "$out" ] || die "measure: --work and --out are required"
  [ -f "$entries" ] || die "measure: --entries FILE is required"
  if [ -f "$work/entries-built-$variant.txt" ]; then
    echo "measure: using $work/entries-built-$variant.txt ($(grep -c . "$work/entries-built-$variant.txt") of $(grep -c . "$entries") entries have a $variant consumer;"
    echo "  the rest are named in $work/entries-noprobe.txt and are NOT counted in any denominator)"
    entries="$work/entries-built-$variant.txt"
  fi
  bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1 || die "disk-guard is unhappy"
  mkdir -p "$out"
  python3 "$HERE/bin/corpus-ab.py" \
    --pre-cmd  "bash $HERE/bin/corpus-chained-rs.sh scan {entry} $pre {outdir} $work $variant $out/rep-pre" \
    --post-cmd "bash $HERE/bin/corpus-chained-rs.sh scan {entry} $post {outdir} $work $variant $out/rep-post" \
    --entries-file "$entries" --jobs "$jobs" --buckets --allow-zero-reach --out "$out/ab.json" \
    | tee "$out/ab.txt"
  local rc="${PIPESTATUS[0]}"
  echo
  python3 "$HERE/bin/corpus-chained-judge.py" --report-rs "$out" "$work" "$entries" "$variant" | tee "$out/judge.txt"
  return "$rc"
}

# The STANDALONE arm, over the very same library reports the chained arm chained.  It exists here
# rather than being quoted from R662/R664 so that the consumer-vs-standalone comparison holds the
# ARITHMETIC constant as well as the window — R673(b) is the record of what happens when it does not.
cmd_standalone() {
  local pre="" post="" entries="" work="" out="" jobs=6 variant="noimpl"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pre) pre="$2"; shift 2 ;;  --post) post="$2"; shift 2 ;;
      --entries) entries="$2"; shift 2 ;; --work) work="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;; --jobs) jobs="$2"; shift 2 ;;
      --variant) variant="$2"; shift 2 ;;
      *) die "standalone: unknown argument $1" ;;
    esac
  done
  [ -x "$pre" ] && [ -x "$post" ] || die "standalone: --pre and --post must both name engine binaries"
  [ -n "$work" ] && [ -n "$out" ] || die "standalone: --work and --out are required"
  # The standalone arm is compared against ONE chained variant, so it must run over that variant's
  # entry list: a consumer-vs-standalone contrast over two different corpora is not a contrast.
  [ -f "$work/entries-built-$variant.txt" ] && entries="$work/entries-built-$variant.txt"
  [ -f "$entries" ] || die "standalone: --entries FILE is required"
  mkdir -p "$out/rep-pre" "$out/rep-post"
  local n=0
  while read -r entry; do
    [ -n "$entry" ] || continue
    (
      nm="$(basename "$entry")"
      for a in pre post; do
        eng="$pre"; [ "$a" = post ] && eng="$post"
        l="$(lib_report "$entry" "$eng" "$work")" && cp "$l" "$out/rep-$a/$nm.json"
      done
    ) &
    n=$((n + 1)); [ $((n % jobs)) -eq 0 ] && wait
  done < "$entries"
  wait
  python3 "$HERE/bin/corpus-chained-judge.py" --report-rs "$out" "$work" "$entries" standalone | tee "$out/judge.txt"
}

# ── GATE VALIDATION.  A bucket count is a PREDICTION about a gate; this runs the gate. ────────────
# Two categories, and the second is the CONTROL that makes the first mean something (R662/R665/R671
# all ran this pair): a bucket-1 qual must move under a BARE scoped `deny <E> <qual>` — PRE 0, POST 1
# — and a bucket-2 qual must NOT move under the bare form while moving under `deny <E> Unknown <qual>`.
# The bare form is the one a real deployment writes, and it is the only one that distinguishes a
# DISCLOSURE gain from a CONCRETE one.
chain_gate() {   # entry engine work variant polfile -> exit code of the CONSUMER scan
  local entry="$1" eng="$2" work="$3" variant="$4" pol="$5"
  local name; name="$(basename "$entry")"
  local lib; lib="$(lib_report "$entry" "$eng" "$work")" || return 125
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/cgaters.XXXXXX")"
  CANDOR_DEPS="$lib" "$eng" "$work/c/$variant/$name" --policy "$pol" >/dev/null 2>&1
  local rc=$?
  rm -rf "$t"
  return $rc
}

cmd_validate() {
  local pre="" post="" work="" out="" sample=25 variant="noimpl"
  while [ $# -gt 0 ]; do
    case "$1" in
      --pre) pre="$2"; shift 2 ;;  --post) post="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;; --out) out="$2"; shift 2 ;;
      --sample) sample="$2"; shift 2 ;; --variant) variant="$2"; shift 2 ;;
      *) die "validate: unknown argument $1" ;;
    esac
  done
  [ -x "$pre" ] && [ -x "$post" ] || die "validate: --pre and --post must both name engine binaries"
  [ -f "$out/judge.json" ] || die "validate: no $out/judge.json — run measure first"
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/cvalrs.XXXXXX")"
  python3 - "$out/judge.json" "$sample" > "$t/plan.tsv" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); n = int(sys.argv[2])
def stride(rows, k):
    if not rows: return []
    s = max(1, len(rows) // k)
    return rows[::s][:k]
for name, fn, effs in stride(d.get("gain_detail") or [], n):
    print("cat1\t%s\t%s\t%s" % (name, fn, effs[0]))
for name, fn in stride(d.get("unk_detail") or [], n):
    print("cat2\t%s\t%s\t%s" % (name, fn, "Net"))
PY
  local c1=0 c1ok=0 c2=0 c2ok=0
  while IFS=$'\t' read -r cat name fn eff; do
    [ -n "$cat" ] || continue
    local entry="$CENSUS/$name"
    if [ "$cat" = cat1 ]; then
      echo "deny $eff $fn" > "$t/p.pol"
      chain_gate "$entry" "$pre"  "$work" "$variant" "$t/p.pol"; local a=$?
      chain_gate "$entry" "$post" "$work" "$variant" "$t/p.pol"; local b=$?
      c1=$((c1 + 1)); { [ "$a" = 0 ] || [ "$a" = 2 ]; } && [ "$b" = 1 ] && c1ok=$((c1ok + 1))
      printf '  cat1 %-30s %-50s deny %-6s PRE=%s POST=%s %s\n' "$name" "${fn:0:50}" "$eff" "$a" "$b" \
        "$({ [ "$a" = 0 ] || [ "$a" = 2 ]; } && [ "$b" = 1 ] && echo OK || echo "MISPREDICTED")"
    else
      echo "deny $eff $fn" > "$t/p.pol"
      chain_gate "$entry" "$pre"  "$work" "$variant" "$t/p.pol"; local a=$?
      chain_gate "$entry" "$post" "$work" "$variant" "$t/p.pol"; local b=$?
      echo "deny $eff Unknown $fn" > "$t/q.pol"
      chain_gate "$entry" "$pre"  "$work" "$variant" "$t/q.pol"; local c=$?
      chain_gate "$entry" "$post" "$work" "$variant" "$t/q.pol"; local d=$?
      c2=$((c2 + 1)); [ "$a" = "$b" ] && [ "$c" != "$d" ] && [ "$d" = 1 ] && c2ok=$((c2ok + 1))
      printf '  cat2 %-30s %-50s bare PRE=%s POST=%s | +Unknown PRE=%s POST=%s %s\n' "$name" "${fn:0:50}" \
        "$a" "$b" "$c" "$d" "$([ "$a" = "$b" ] && [ "$c" != "$d" ] && [ "$d" = 1 ] && echo OK || echo "MISPREDICTED")"
    fi
  done < "$t/plan.tsv"
  rm -rf "$t"
  echo "validate: category 1 (bare scoped deny moves ->1) $c1ok/$c1 ; category 2 (bare does NOT move, +Unknown does) $c2ok/$c2"
  [ "$c1" -gt 0 ] || { echo "validate: NO bucket-1 sample — nothing was validated"; return 1; }
  return 0
}

# ── CALIBRATION (brief §1b: a gate lands with its calibration, and a gate that has never failed has
# not been shown to be a gate).  Two chained fixtures, each with a ONE-VARIABLE control, both closed
# rows in the window under measurement and both CONSUMER-OBSERVABLE:
#
#   R609/R628  a library declares a trait NOTHING implements, and a consumer dispatches on it.  PRE
#              publishes nothing for the abstraction and the consumer reads `inferred: []` with no
#              `unknownWhy` — a positive purity claim over a call it could not resolve.  POST's two
#              halves (R609 publishes the zero-implementor union; R608 charges `Unknown` when nothing
#              on the wire answers the key) make the consumer disclose.  ONE-VARIABLE CONTROL: the
#              same library with ONE effectful implementor of the same trait — the union then answers
#              the key and BOTH arms must be red, which is what proves the fixture is pinning the
#              zero-implementor case and not merely "a dispatch".
#
#   R549/R532b a library function whose published `dispatchesOn` key names a member the trait does NOT
#              declare (an extension-trait method reached through the base trait).  No consumer can
#              join it.  ONE-VARIABLE CONTROL: the same call spelled through the declaring trait, which
#              must be joinable on both arms.
#
# Each must read a PASS (exit 0 — a positive purity claim, whether the row is pure or ABSENT) on the
# PRE engine and a FAIL (exit 1) on the POST engine.  Anything else and the arm is not built. ────────
cal_lib_r609() {   # $1 = dir, $2 = "zero" | "one"
  local g="$1" mode="$2"
  mkdir -p "$g/src"
  cat > "$g/Cargo.toml" <<'T'
[package]
name = "callib"
version = "0.0.0"
T
  cat > "$g/src/lib.rs" <<'R'
pub trait Handler {
    fn handle(&self);
}
R
  if [ "$mode" = one ]; then
    cat >> "$g/src/lib.rs" <<'R'
pub struct Real;
impl Handler for Real {
    fn handle(&self) { let _ = std::net::TcpStream::connect("127.0.0.1:9"); }
}
R
  fi
}

cal_app_r609() {
  local g="$1"
  mkdir -p "$g/src"
  cat > "$g/Cargo.toml" <<'T'
[package]
name = "calapp"
version = "0.0.0"

[dependencies]
callib = "1"
T
  cat > "$g/src/lib.rs" <<'R'
pub fn run(h: &dyn callib::Handler) { h.handle(); }
R
  echo 'deny Net Unknown run' > "$g/scoped.pol"
}

cal_lib_r652() {   # $1 = dir, $2 = "collide" | "clean"
  local g="$1" mode="$2"
  mkdir -p "$g/src"
  cat > "$g/Cargo.toml" <<'T'
[package]
name = "callib2"
version = "0.0.0"
T
  # R652's own fixture, verbatim in shape: a LOCAL trait with ZERO implementors whose LEAF collides
  # with a foreign/std trait that IS implemented here.  `trait_impls` was keyed by leaf with no
  # locality test, so the local trait acquired an implementor vector of `["W"]`, every lookup resolved
  # nothing, the union came out EMPTY — and since R609 an empty union PUBLISHES, so the consumer read
  # a §2 purity claim about an abstraction with no implementor at all.
  cat > "$g/src/lib.rs" <<'R'
pub trait Write {
    fn emit(&self);
}
pub struct W;
R
  if [ "$mode" = collide ]; then
    # THE ONE VARIABLE: an impl of a DIFFERENT trait that happens to share the leaf `Write`.
    cat >> "$g/src/lib.rs" <<'R'
impl std::io::Write for W {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> { Ok(b.len()) }
    fn flush(&mut self) -> std::io::Result<()> { Ok(()) }
}
R
  fi
}

cal_app_r652() {
  local g="$1"
  mkdir -p "$g/src"
  cat > "$g/Cargo.toml" <<'T'
[package]
name = "calapp2"
version = "0.0.0"

[dependencies]
callib2 = "1"
T
  cat > "$g/src/lib.rs" <<'R'
pub fn run(c: &dyn callib2::Write) { c.emit(); }
R
  echo 'deny Net Unknown run' > "$g/scoped.pol"
}

cal_run() {   # libdir engine appdir polfile qual -> "exit=N ROW|ABSENT inferred=… why=…"
  local libdir="$1" eng="$2" appdir="$3" pol="$4" qual="$5" t
  t="$(mktemp -d "${TMPDIR:-/tmp}/ccalrs.XXXXXX")"
  "$eng" "$libdir" --json > "$t/lib.json" 2>/dev/null
  CANDOR_DEPS="$t/lib.json" "$eng" "$appdir" --json > "$t/app.json" 2>/dev/null
  CANDOR_DEPS="$t/lib.json" "$eng" "$appdir" --policy "$pol" >/dev/null 2>&1
  local rc=$?
  python3 - "$t/app.json" "$qual" "$rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); qual, rc = sys.argv[2], sys.argv[3]
rows = [r for r in d.get("functions", []) if r.get("fn") == qual]
if not rows:
    # ABSENT IS NOT PURE (R636): a missing row is a POSITIVE purity claim and is labelled as one.
    print("exit=%s ABSENT" % rc)
else:
    r = rows[0]
    print("exit=%s ROW inferred=%s unresolved=%s why=%s dispatchesOn=%s" % (
        rc, r.get("inferred"), r.get("unresolved"), r.get("unknownWhy"), r.get("dispatchesOn")))
PY
  rm -rf "$t"
}

cmd_calibrate() {
  # EACH ANCHOR NAMES ITS OWN PAIR, because the two rows are closed by DIFFERENT commits inside one
  # window and a single pair cannot drive both.  R671's lane paid exactly this: it calibrated against
  # the WIDE window's PRE and R595 read red on both arms, which would have been reported as *the arm
  # cannot see it*.
  local r609="" r652="" work="${TMPDIR:-/tmp}/candor-chained-rs-cal"
  while [ $# -gt 0 ]; do
    case "$1" in
      --r609) r609="$2"; shift 2 ;;
      --r652) r652="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;;
      *) die "calibrate: unknown argument $1" ;;
    esac
  done
  [ -n "$r609" ] && [ -n "$r652" ] || die "calibrate: --r609 PRE,POST and --r652 PRE,POST are both required"
  rm -rf "$work"; mkdir -p "$work"
  local fail=0 a b c d

  local pre="${r609%%,*}" post="${r609##*,}"
  [ -x "$pre" ] && [ -x "$post" ] || die "calibrate: --r609 wants two executable engine binaries"
  echo "== R609/R628 — a consumer dispatches on a dependency trait NOTHING implements"
  cal_lib_r609 "$work/r609/lib0" zero
  cal_lib_r609 "$work/r609/lib1" one
  cal_app_r609 "$work/r609/app"
  cmp -s "$work/r609/lib0/src/lib.rs" "$work/r609/lib1/src/lib.rs" && die "calibrate: the R609 arms are identical"
  a="$(cal_run "$work/r609/lib0" "$pre"  "$work/r609/app" "$work/r609/app/scoped.pol" run)"
  b="$(cal_run "$work/r609/lib0" "$post" "$work/r609/app" "$work/r609/app/scoped.pol" run)"
  c="$(cal_run "$work/r609/lib1" "$pre"  "$work/r609/app" "$work/r609/app/scoped.pol" run)"
  d="$(cal_run "$work/r609/lib1" "$post" "$work/r609/app" "$work/r609/app/scoped.pol" run)"
  printf '   %-32s PRE  %s\n' "dep trait: NO implementor" "$a"
  printf '   %-32s POST %s\n' "dep trait: NO implementor" "$b"
  printf '   %-32s PRE  %s\n' "control: ONE effectful impl" "$c"
  printf '   %-32s POST %s\n' "control: ONE effectful impl" "$d"
  case "$a" in exit=0*) ;; *) echo "   FAIL — the PRE engine does not PASS this consumer; the arm cannot see R609"; fail=1 ;; esac
  case "$b" in exit=1*) ;; *) echo "   FAIL — the POST engine does not FAIL this consumer"; fail=1 ;; esac
  case "$c" in exit=1*) ;; *) echo "   FAIL — the one-variable control passes on PRE; the fixture is not pinning zero-implementor"; fail=1 ;; esac
  case "$d" in exit=1*) ;; *) echo "   FAIL — the one-variable control is not red on POST"; fail=1 ;; esac
  [ "$fail" = 0 ] && echo "   OK — PRE passes, POST fails, and the one-implementor control is red on both."

  pre="${r652%%,*}"; post="${r652##*,}"
  [ -x "$pre" ] && [ -x "$post" ] || die "calibrate: --r652 wants two executable engine binaries"
  echo "== R652 — a foreign impl sharing a local trait's LEAF manufactures a pure union the consumer joins"
  local f2=0
  cal_lib_r652 "$work/r652/libc" collide
  cal_lib_r652 "$work/r652/libn" clean
  cal_app_r652 "$work/r652/app"
  cmp -s "$work/r652/libc/src/lib.rs" "$work/r652/libn/src/lib.rs" && die "calibrate: the R652 arms are identical"
  a="$(cal_run "$work/r652/libc" "$pre"  "$work/r652/app" "$work/r652/app/scoped.pol" run)"
  b="$(cal_run "$work/r652/libc" "$post" "$work/r652/app" "$work/r652/app/scoped.pol" run)"
  c="$(cal_run "$work/r652/libn" "$pre"  "$work/r652/app" "$work/r652/app/scoped.pol" run)"
  d="$(cal_run "$work/r652/libn" "$post" "$work/r652/app" "$work/r652/app/scoped.pol" run)"
  printf '   %-32s PRE  %s\n' "dep: leaf-colliding foreign impl" "$a"
  printf '   %-32s POST %s\n' "dep: leaf-colliding foreign impl" "$b"
  printf '   %-32s PRE  %s\n' "control: no foreign impl" "$c"
  printf '   %-32s POST %s\n' "control: no foreign impl" "$d"
  case "$a" in exit=0*) ;; *) echo "   FAIL — the PRE engine does not PASS this consumer; the arm cannot see R652"; f2=1 ;; esac
  case "$b" in exit=1*) ;; *) echo "   FAIL — the POST engine does not FAIL this consumer"; f2=1 ;; esac
  case "$c" in exit=1*) ;; *) echo "   FAIL — the one-variable control passes on PRE; the fixture is not pinning the leaf collision"; f2=1 ;; esac
  case "$d" in exit=1*) ;; *) echo "   FAIL — the one-variable control is not red on POST"; f2=1 ;; esac
  [ "$f2" = 0 ] && echo "   OK — PRE passes, POST fails, and the no-collision control is red on both."
  fail=$((fail + f2))

  echo
  if [ "$fail" != 0 ]; then
    echo "corpus-chained-rs calibrate: FAILED — the arm is not calibrated, so its numbers are not evidence."
    return 1
  fi
  echo "corpus-chained-rs calibrate: OK — both rows reproduce PRE exit 0 / POST exit 1 through the chain,"
  echo "  and both one-variable controls are red on both arms."
  return 0
}

case "${1:-}" in
  scan)       shift; cmd_scan "$@" ;;
  scanlib)    shift; cmd_scanlib "$@" ;;
  build)      shift; cmd_build "$@" ;;
  measure)    shift; cmd_measure "$@" ;;
  standalone) shift; cmd_standalone "$@" ;;
  validate)   shift; cmd_validate "$@" ;;
  calibrate)  shift; cmd_calibrate "$@" ;;
  *) sed -n '2,14p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
