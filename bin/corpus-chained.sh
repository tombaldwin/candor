#!/usr/bin/env bash
# corpus-chained.sh — THE SECOND ARM: scan each census library AS A DEPENDENCY OF A CONSUMER.
# SOUNDNESS R668 (the gap) / R671 (this instrument).
#
#     bash bin/corpus-chained.sh calibrate --r595 PRE.jar,POST.jar --r530b PRE.jar,POST.jar
#     bash bin/corpus-chained.sh build   --entries FILE [--work DIR] [--jobs N]
#     bash bin/corpus-chained.sh measure  --pre JAR --post JAR --entries FILE [--work DIR] --out DIR
#     bash bin/corpus-chained.sh validate --pre JAR --post JAR [--work DIR] --out DIR [--sample N]
#     bash bin/corpus-chained.sh scan    ENTRY_JAR ENGINE_JAR OUTDIR WORKDIR      # one arm, one entry
#
# WHY.  `bin/corpus-census.sh` acquires libraries and every census so far scanned them STANDALONE.
# A standalone scan answers "does the engine parse this code"; it cannot answer "does the engine
# understand how this code is USED", and the whole <0.39> chained-dispatch rung lives in the second
# question.  R595 is the proof and it SHIPPED in 0.39.2: adding a pure default to a library deleted a
# real `Fs` from every consumer.  No standalone scan of that library can contain that defect, so the
# census measured R595 as "zero movement" and that said nothing about the fix.
#
# THE TWO HALVES MOVE TOGETHER.  PRE = pre-engine library report + pre-engine consumer scan.  POST =
# post + post.  R608's own row measured that the producer and consumer halves are NOT separable to
# ship; a fixed library report read by a varying consumer engine measures a mixed engine, and the
# number is worthless.  `scan` therefore takes ONE engine jar and uses it for both.
#
# THE CONSUMER IS GENERATED, NOT HAND-WRITTEN (bin/corpus-chained/ConsumerGen.java).  At 452 jars a
# hand-written consumer is not an option, and <0.39> obligation 3 is mechanical.  The consumer's
# BYTECODE IS BUILT ONCE and shared by both arms, so the only variable between them is the engine.
#
# ABSENT IS NOT PURE.  `bin/corpus-chained-judge.py` buckets a missing consumer row as ABSENT in its
# own column and never as pure.  SOUNDNESS R636 is exactly this trap one repo over: PART 92's
# `judge()` renders a missing entry as `eff=∅, unknown=False` and two arms pass unconditionally on it.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$HERE/bin/corpus-chained/ConsumerGen.java"
CENSUS="${CANDOR_CENSUS_HOME:-$HOME/.candor/census}/java"
WORK_DEFAULT="${TMPDIR:-/tmp}/candor-chained"

die() { echo "corpus-chained: $*" >&2; exit 2; }
[ -f "$GEN" ] || die "REFUSING — no generator at $GEN"

# ── one entry, one engine: the library report, then the consumer scan that chains it ──────────────
cmd_scan() {
  local jar="$1" eng="$2" outdir="$3" work="$4" keep="${5:-}"
  local name; name="$(basename "$jar" .jar)"
  local cls="$work/c/$name/cls"
  [ -d "$cls" ] || { echo "no consumer built for $name (run: corpus-chained.sh build)" >&2; return 3; }
  # A consumer directory with no class files scans clean for a reason that has nothing to do with
  # the engine.  R242: zero rows and a correctly-inert change print the same thing.
  if [ -z "$(find "$cls" -name '*.class' -print -quit 2>/dev/null)" ]; then
    echo "consumer for $name holds NO class files — refusing to report it as a clean scan" >&2
    return 3
  fi
  mkdir -p "$outdir"
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/cchain.XXXXXX")" || return 3
  if ! java -jar "$eng" "$jar" --json "$t/lib.json" >"$t/lib.log" 2>&1; then
    echo "library arm FAILED for $name:" >&2; tail -5 "$t/lib.log" >&2; rm -rf "$t"; return 3
  fi
  CANDOR_DEPS="$t/lib.json" java -jar "$eng" "$cls" --json "$outdir/consumer.json" >"$t/app.log" 2>&1
  local rc=$?
  if [ ! -s "$outdir/consumer.json" ]; then
    echo "consumer arm produced no report for $name (rc=$rc):" >&2; tail -5 "$t/app.log" >&2
    rm -rf "$t"; return 3
  fi
  rm -rf "$t"
  # The arm's consumer report is also KEPT, per arm, so the scope-sensitivity table and the
  # absent-row accounting are computed from the same bytes the A/B compared — not from a re-run.
  if [ -n "$keep" ]; then mkdir -p "$keep" && cp "$outdir/consumer.json" "$keep/$name.json"; fi
  return 0
}

# ── generate + compile every consumer, once, engine-independently ─────────────────────────────────
build_one() {
  local jar="$1" work="$2" cp="$3"
  local name; name="$(basename "$jar" .jar)"
  local d="$work/c/$name"
  rm -rf "$d"; mkdir -p "$d/src" "$d/cls"
  if ! java "$GEN" "$jar" "$d/src" "$d/manifest.json" "$cp" >"$d/gen.log" 2>&1; then
    echo "  GEN-FAIL $name"; return 1
  fi
  find "$d/src" -name '*.java' | sort > "$d/files.txt"
  [ -s "$d/files.txt" ] || { echo "  NO-PROBES $name"; return 1; }
  # THE RECOVERY LOOP.  A generated call can still be rejected — an inaccessible return type, an
  # overload javac resolves differently under a raw receiver.  One bad CALL must cost one call, not
  # the type and not the entry, so failing LINES are commented out and the file is retried; only a
  # file that still fails is dropped, and both counts land in the manifest.  Silently dropping them
  # would move the denominator in the flattering direction and say nothing.
  local round=0 dropped=0 lines=0
  while :; do
    javac -nowarn -proc:none -Xmaxerrs 100000 -cp "$jar:$cp" -d "$d/cls" "@$d/files.txt" \
      >"$d/javac.$round.log" 2>&1 && break
    round=$((round + 1))
    [ "$round" -gt 6 ] && break
    python3 - "$d" "$round" <<'PY' || break
import os, re, sys
d, rnd = sys.argv[1], int(sys.argv[2])
bad = {}
for ln in open(os.path.join(d, "javac.%d.log" % (rnd - 1)), errors="replace"):
    m = re.match(r"^(/.*\.java):(\d+): error: ", ln)
    if m: bad.setdefault(m.group(1), set()).add(int(m.group(2)))
if not bad: raise SystemExit(1)
files = [l.strip() for l in open(os.path.join(d, "files.txt")) if l.strip()]
drop, cut = [], 0
for f, lns in bad.items():
    try: src = open(f, errors="replace").read().split("\n")
    except OSError: drop.append(f); continue
    # a probe call is exactly one line; a header/decl error is not recoverable by line surgery
    if any(n - 1 >= len(src) or not src[n - 1].lstrip().startswith("try {") for n in lns):
        drop.append(f); continue
    for n in lns: src[n - 1] = "        // DROPPED (javac): " + src[n - 1].strip(); cut += 1
    open(f, "w").write("\n".join(src))
files = [f for f in files if f not in set(drop)]
open(os.path.join(d, "files.txt"), "w").write("\n".join(files) + ("\n" if files else ""))
open(os.path.join(d, "recovery.txt"), "a").write("round %d: %d line(s) dropped, %d file(s) dropped\n" % (rnd, cut, len(drop)))
PY
    [ -s "$d/files.txt" ] || { echo "  ALL-DROPPED $name"; return 1; }
  done
  local n; n="$(find "$d/cls" -name '*.class' | wc -l | tr -d ' ')"
  [ "$n" -gt 0 ] || { echo "  NO-CLASSES $name"; return 1; }
  echo "  OK $name  $(wc -l < "$d/files.txt" | tr -d ' ') probe files, $n class files"
  return 0
}

cmd_build() {
  local entries="" work="$WORK_DEFAULT" jobs=6
  while [ $# -gt 0 ]; do
    case "$1" in
      --entries) entries="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;;
      --jobs) jobs="$2"; shift 2 ;;
      *) die "build: unknown argument $1" ;;
    esac
  done
  [ -f "$entries" ] || die "build: --entries FILE is required"
  bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1 || die "disk-guard is unhappy — a full disk fakes an empty corpus"
  mkdir -p "$work/c"
  # The whole census on the classpath, the entry jar FIRST.  Without the rest, every member whose
  # signature names a transitive dependency is unresolvable and the probe is dropped; without the
  # entry jar first, javac can resolve the library's own type from a SIBLING VERSION on the path and
  # reject a cast the generator built from the real one (measured on guava).
  local cp; cp="$(ls "$CENSUS"/*.jar 2>/dev/null | tr '\n' ':')"
  local n=0
  while read -r jar; do
    [ -n "$jar" ] || continue
    build_one "$jar" "$work" "$cp" &
    n=$((n + 1)); [ $((n % jobs)) -eq 0 ] && wait
  done < "$entries"
  wait
  # THE ENTRY SET THE MEASUREMENT MAY USE.  Some real libraries declare no public abstract type and
  # no reassignable functional field at all — a pure annotation or marker jar (checker-qual,
  # error_prone_annotations, jakarta.annotation-api, lombok) yields ZERO probes, and that is a
  # property of the library, not a failure of the run.  They are NAMED here and dropped from the
  # entry list rather than tolerated with --allow-fail, because an entry silently carried into the
  # A/B with an empty consumer contributes zero rows and prints exactly like an inert change (R242).
  : > "$work/entries-built.txt"; : > "$work/entries-noprobe.txt"
  while read -r jar; do
    [ -n "$jar" ] || continue
    local nm; nm="$(basename "$jar" .jar)"
    if [ -n "$(find "$work/c/$nm/cls" -name '*.class' -print -quit 2>/dev/null)" ]; then
      echo "$jar" >> "$work/entries-built.txt"
    else
      echo "$jar" >> "$work/entries-noprobe.txt"
    fi
  done < "$entries"
  echo "corpus-chained build: $n entries, consumers under $work/c"
  echo "  entries WITH a consumer: $(wc -l < "$work/entries-built.txt" | tr -d ' ')"
  echo "  entries with NO probe at all (no public abstract type, no reassignable functional field):"
  sed 's/^/     /' "$work/entries-noprobe.txt"
  python3 "$HERE/bin/corpus-chained-judge.py" --coverage "$work" "$entries"
}

cmd_measure() {
  local pre="" post="" entries="" work="$WORK_DEFAULT" out="" jobs=6
  while [ $# -gt 0 ]; do
    case "$1" in
      --pre) pre="$2"; shift 2 ;;
      --post) post="$2"; shift 2 ;;
      --entries) entries="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --jobs) jobs="$2"; shift 2 ;;
      *) die "measure: unknown argument $1" ;;
    esac
  done
  [ -f "$pre" ] && [ -f "$post" ] || die "measure: --pre and --post must both name engine jars"
  [ -f "$entries" ] || die "measure: --entries FILE is required"
  [ -n "$out" ] || die "measure: --out DIR is required"
  # Measure only what has a consumer, and say so.  `build` wrote the list and named the rest.
  if [ -f "$work/entries-built.txt" ]; then
    echo "measure: using $work/entries-built.txt ($(wc -l < "$work/entries-built.txt" | tr -d ' ') of $(grep -c . "$entries") entries have a consumer;"
    echo "  the rest are named in $work/entries-noprobe.txt and are NOT counted in any denominator)"
    entries="$work/entries-built.txt"
  fi
  bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1 || die "disk-guard is unhappy"
  mkdir -p "$out"
  python3 "$HERE/bin/corpus-ab.py" \
    --pre-cmd  "bash $HERE/bin/corpus-chained.sh scan {entry} $pre {outdir} $work $out/rep-pre" \
    --post-cmd "bash $HERE/bin/corpus-chained.sh scan {entry} $post {outdir} $work $out/rep-post" \
    --entries-file "$entries" --jobs "$jobs" --buckets --out "$out/ab.json" \
    | tee "$out/ab.txt"
  local rc="${PIPESTATUS[0]}"
  echo
  python3 "$HERE/bin/corpus-chained-judge.py" --report "$out" "$work" "$entries" | tee "$out/judge.txt"
  return "$rc"
}

# ── GATE VALIDATION.  A bucket count is a PREDICTION about a gate; this runs the gate. ────────────
# Two categories, and the second is the CONTROL that makes the first mean something (R665 ran the
# same pair): a bucket-1 qual must move under a BARE scoped `deny <E> <qual>` — PRE 0, POST 1 — and
# a bucket-2 qual must NOT move under the bare form while moving under `deny <E> Unknown <qual>`.
# The bare form is the one a real deployment writes (`deny Net com.acme.domain`), and it is also the
# only one that distinguishes a DISCLOSURE gain from a CONCRETE one: where PRE already said
# `Unknown`, `deny <E> Unknown` was red on both arms and reports no flip at all.
chain_gate() {   # jar engine work polfile -> exit code of the CONSUMER scan
  local jar="$1" eng="$2" work="$3" pol="$4"
  local name; name="$(basename "$jar" .jar)"
  # The library report depends only on (entry, engine), never on the policy, so it is CACHED.
  # Without this each sampled qual re-scans a multi-megabyte jar twice and the validation costs
  # more than the measurement it is validating.
  local tag; tag="$(shasum -a 1 "$eng" | cut -c1-12)"
  local lib="$work/libreports/$tag"; mkdir -p "$lib"
  [ -s "$lib/$name.json" ] || java -jar "$eng" "$jar" --json "$lib/$name.json" >/dev/null 2>&1
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/cgate.XXXXXX")"
  CANDOR_DEPS="$lib/$name.json" java -jar "$eng" "$work/c/$name/cls" --json "$t/app.json" --policy "$pol" >/dev/null 2>&1
  local rc=$?
  rm -rf "$t"
  return $rc
}

cmd_validate() {
  local pre="" post="" work="$WORK_DEFAULT" out="" sample=25
  while [ $# -gt 0 ]; do
    case "$1" in
      --pre) pre="$2"; shift 2 ;;  --post) post="$2"; shift 2 ;;
      --work) work="$2"; shift 2 ;; --out) out="$2"; shift 2 ;;
      --sample) sample="$2"; shift 2 ;;
      *) die "validate: unknown argument $1" ;;
    esac
  done
  [ -f "$pre" ] && [ -f "$post" ] || die "validate: --pre and --post must both name engine jars"
  [ -f "$out/judge.json" ] || die "validate: no $out/judge.json — run measure first"
  local t; t="$(mktemp -d "${TMPDIR:-/tmp}/cval.XXXXXX")"
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
    local jar="$CENSUS/$name.jar"
    if [ "$cat" = cat1 ]; then
      echo "deny $eff $fn" > "$t/p.pol"
      chain_gate "$jar" "$pre"  "$work" "$t/p.pol"; local a=$?
      chain_gate "$jar" "$post" "$work" "$t/p.pol"; local b=$?
      c1=$((c1 + 1)); [ "$a" = 0 ] && [ "$b" = 1 ] && c1ok=$((c1ok + 1))
      printf '  cat1 %-28s %-56s deny %-6s PRE=%s POST=%s %s\n' "$name" "${fn:0:56}" "$eff" "$a" "$b" \
        "$([ "$a" = 0 ] && [ "$b" = 1 ] && echo OK || echo "MISPREDICTED")"
    else
      echo "deny $eff $fn" > "$t/p.pol"
      chain_gate "$jar" "$pre"  "$work" "$t/p.pol"; local a=$?
      chain_gate "$jar" "$post" "$work" "$t/p.pol"; local b=$?
      echo "deny $eff Unknown $fn" > "$t/q.pol"
      chain_gate "$jar" "$pre"  "$work" "$t/q.pol"; local c=$?
      chain_gate "$jar" "$post" "$work" "$t/q.pol"; local d=$?
      c2=$((c2 + 1)); [ "$a" = 0 ] && [ "$b" = 0 ] && [ "$d" = 1 ] && c2ok=$((c2ok + 1))
      printf '  cat2 %-28s %-56s bare PRE=%s POST=%s | +Unknown PRE=%s POST=%s %s\n' "$name" "${fn:0:56}" \
        "$a" "$b" "$c" "$d" "$([ "$a" = 0 ] && [ "$b" = 0 ] && [ "$d" = 1 ] && echo OK || echo "MISPREDICTED")"
    fi
  done < "$t/plan.tsv"
  rm -rf "$t"
  echo "validate: category 1 (bare scoped deny moves 0->1) $c1ok/$c1 ; category 2 (bare does NOT move, +Unknown does) $c2ok/$c2"
  [ "$c1" -gt 0 ] || { echo "validate: NO bucket-1 sample — nothing was validated"; return 1; }
  return 0
}

# ── CALIBRATION (brief §1b: a gate lands with its calibration, and a gate that has never failed has
# not been shown to be a gate).  Two chained fixtures, each with a ONE-VARIABLE control:
#   R595   library holds `public static Hook afterStage = () -> { };`; the consumer reassigns it to
#          an effectful lambda and calls into the library.  Control: delete only the initialiser.
#   R530b  library returns a LAMBDA implementing its own interface, beside one PURE sibling
#          implementor; the consumer dispatches on the interface and holds no implementor at all.
#          Control: `new Handler(){…}` in place of `() -> {…}`, one variable.
# Each must read a PASS (exit 0 — a positive purity claim, whether the row is pure or ABSENT) on the
# PRE engine and a FAIL (exit 1) on the POST engine.  Anything else and the arm is not built. ────────
cal_fixture_r595() {
  local g="$1"
  mkdir -p "$g/lib/lib" "$g/lib0/lib" "$g/app/app"
  cat > "$g/lib/lib/Hooks.java" <<'JAVA'
package lib;
import java.io.IOException;
public class Hooks {
  public interface Hook { void run() throws IOException; }
  public static Hook afterStage = () -> { };
  public static void firePublic() throws IOException { afterStage.run(); }
}
JAVA
  sed 's/ = () -> { };/;/' "$g/lib/lib/Hooks.java" > "$g/lib0/lib/Hooks.java"
  cat > "$g/app/app/Main.java" <<'JAVA'
package app;
import lib.Hooks;
import java.io.FileWriter;
import java.io.IOException;
public class Main {
  public static void main(String[] a) throws IOException {
    Hooks.afterStage = () -> { new FileWriter("/tmp/candor-chained-r595").close(); };
    Hooks.firePublic();
  }
}
JAVA
  echo 'deny Fs Unknown app.Main.main' > "$g/scoped.pol"
  mkdir -p "$g/libcls" "$g/lib0cls" "$g/appcls"
  javac -nowarn -d "$g/libcls"  "$g/lib/lib"/*.java  || return 1
  javac -nowarn -d "$g/lib0cls" "$g/lib0/lib"/*.java || return 1
  javac -nowarn -cp "$g/libcls" -d "$g/appcls" "$g/app/app"/*.java || return 1
  cmp -s "$g/libcls/lib/Hooks.class" "$g/lib0cls/lib/Hooks.class" && return 1   # the arms must differ
  return 0
}

cal_fixture_r530b() {
  local g="$1"
  mkdir -p "$g/libL/lib" "$g/libA/lib" "$g/app/app"
  for v in L A; do
    cat > "$g/lib$v/lib/Handler.java" <<'JAVA'
package lib;
public interface Handler { void handle(); }
JAVA
    cat > "$g/lib$v/lib/PureImpl.java" <<'JAVA'
package lib;
public class PureImpl implements Handler { public static int n; public void handle() { n++; } }
JAVA
  done
  cat > "$g/libL/lib/Factory.java" <<'JAVA'
package lib;
public class Factory {
  public static Handler make() {
    return () -> { try { new java.net.Socket("127.0.0.1", 9).close(); } catch (Exception e) { } };
  }
}
JAVA
  cat > "$g/libA/lib/Factory.java" <<'JAVA'
package lib;
public class Factory {
  public static Handler make() {
    return new Handler() { public void handle() {
      try { new java.net.Socket("127.0.0.1", 9).close(); } catch (Exception e) { } } };
  }
}
JAVA
  cat > "$g/app/app/App.java" <<'JAVA'
package app;
import lib.Handler;
public class App { public void go(Handler h) { h.handle(); } }
JAVA
  echo 'deny Net Unknown app.App.go' > "$g/scoped.pol"
  mkdir -p "$g/libLcls" "$g/libAcls" "$g/appcls"
  javac -nowarn -d "$g/libLcls" "$g/libL/lib"/*.java || return 1
  javac -nowarn -d "$g/libAcls" "$g/libA/lib"/*.java || return 1
  javac -nowarn -cp "$g/libLcls" -d "$g/appcls" "$g/app/app"/*.java || return 1
  cmp -s "$g/libLcls/lib/Factory.class" "$g/libAcls/lib/Factory.class" && return 1
  return 0
}

cal_run() {   # libdir enginejar appdir polfile qual  ->  prints "exit=N verdict=…"
  local libdir="$1" eng="$2" appdir="$3" pol="$4" qual="$5" t
  t="$(mktemp -d "${TMPDIR:-/tmp}/ccal.XXXXXX")"
  java -jar "$eng" "$libdir" --json "$t/lib.json" >/dev/null 2>&1
  CANDOR_DEPS="$t/lib.json" java -jar "$eng" "$appdir" --json "$t/app.json" --policy "$pol" >/dev/null 2>&1
  local rc=$?
  python3 - "$t/app.json" "$qual" "$rc" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); qual, rc = sys.argv[2], sys.argv[3]
rows = [r for r in d.get("functions", []) if r.get("fn") == qual]
if not rows:
    # ABSENT IS NOT PURE (R636): a missing row is a POSITIVE purity claim and is labelled as one.
    print("exit=%s ABSENT inferred=- unresolved=-" % rc)
else:
    r = rows[0]
    print("exit=%s %s inferred=%s unresolved=%s why=%s" % (
        rc, "ROW", r.get("inferred"), r.get("unresolved"), r.get("unknownWhy")))
PY
  rm -rf "$t"
}

cmd_calibrate() {
  local r595="" r530b="" work="$WORK_DEFAULT/cal"
  while [ $# -gt 0 ]; do
    case "$1" in
      --r595)  r595="$2";  shift 2 ;;
      --r530b) r530b="$2"; shift 2 ;;
      --work)  work="$2";  shift 2 ;;
      *) die "calibrate: unknown argument $1" ;;
    esac
  done
  [ -n "$r595" ] && [ -n "$r530b" ] || die "calibrate: --r595 PRE,POST and --r530b PRE,POST are both required"
  command -v javac >/dev/null || die "calibrate: no javac — the fixtures MUST compile (brief §E3)"
  rm -rf "$work"; mkdir -p "$work"
  local fail=0

  local a="${r595%%,*}" b="${r595##*,}"
  [ -f "$a" ] && [ -f "$b" ] || die "calibrate: --r595 wants two readable engine jars"
  cal_fixture_r595 "$work/r595" || die "calibrate: the R595 fixture did not compile, or its two arms are identical"
  echo "== R595 — a consumer reassigns a library's public static callback field"
  local pre_main post_main pre_ctl post_ctl
  pre_main="$(cal_run  "$work/r595/libcls"  "$a" "$work/r595/appcls" "$work/r595/scoped.pol" app.Main.main)"
  post_main="$(cal_run "$work/r595/libcls"  "$b" "$work/r595/appcls" "$work/r595/scoped.pol" app.Main.main)"
  pre_ctl="$(cal_run   "$work/r595/lib0cls" "$a" "$work/r595/appcls" "$work/r595/scoped.pol" app.Main.main)"
  post_ctl="$(cal_run  "$work/r595/lib0cls" "$b" "$work/r595/appcls" "$work/r595/scoped.pol" app.Main.main)"
  printf '   %-26s PRE  %s\n' "library WITH default" "$pre_main"
  printf '   %-26s POST %s\n' "library WITH default" "$post_main"
  printf '   %-26s PRE  %s\n' "control: NO default" "$pre_ctl"
  printf '   %-26s POST %s\n' "control: NO default" "$post_ctl"
  case "$pre_main"  in exit=0*) ;; *) echo "   FAIL — the PRE engine does not PASS this consumer; the arm cannot see R595"; fail=1 ;; esac
  case "$post_main" in exit=1*) ;; *) echo "   FAIL — the POST engine does not FAIL this consumer"; fail=1 ;; esac
  case "$pre_ctl"   in exit=1*) ;; *) echo "   FAIL — the one-variable control passes on PRE; the fixture is not pinning the initialiser"; fail=1 ;; esac
  [ "$fail" = 0 ] && echo "   OK — PRE passes, POST fails, and the control is red on both."

  a="${r530b%%,*}"; b="${r530b##*,}"
  [ -f "$a" ] && [ -f "$b" ] || die "calibrate: --r530b wants two readable engine jars"
  cal_fixture_r530b "$work/r530b" || die "calibrate: the R530b fixture did not compile, or its two arms are identical"
  echo "== R530b — a consumer dispatches on a dependency's interface, holding no implementor"
  local pre_l post_l pre_a post_a f2=0
  pre_l="$(cal_run  "$work/r530b/libLcls" "$a" "$work/r530b/appcls" "$work/r530b/scoped.pol" app.App.go)"
  post_l="$(cal_run "$work/r530b/libLcls" "$b" "$work/r530b/appcls" "$work/r530b/scoped.pol" app.App.go)"
  pre_a="$(cal_run  "$work/r530b/libAcls" "$a" "$work/r530b/appcls" "$work/r530b/scoped.pol" app.App.go)"
  post_a="$(cal_run "$work/r530b/libAcls" "$b" "$work/r530b/appcls" "$work/r530b/scoped.pol" app.App.go)"
  printf '   %-26s PRE  %s\n' "dep implementor: LAMBDA" "$pre_l"
  printf '   %-26s POST %s\n' "dep implementor: LAMBDA" "$post_l"
  printf '   %-26s PRE  %s\n' "control: ANON CLASS" "$pre_a"
  printf '   %-26s POST %s\n' "control: ANON CLASS" "$post_a"
  case "$pre_l"  in exit=0*) ;; *) echo "   FAIL — the PRE engine does not PASS the lambda arm; the arm cannot see R530b"; f2=1 ;; esac
  case "$post_l" in exit=1*) ;; *) echo "   FAIL — the POST engine does not FAIL the lambda arm"; f2=1 ;; esac
  case "$pre_a"  in exit=1*) ;; *) echo "   FAIL — the one-variable control passes on PRE; the fixture is not pinning the lambda"; f2=1 ;; esac
  case "$post_a" in exit=1*) ;; *) echo "   FAIL — the control is not red on POST"; f2=1 ;; esac
  [ "$f2" = 0 ] && echo "   OK — PRE passes, POST fails, and the anon-class control is red on both."
  fail=$((fail + f2))

  echo
  if [ "$fail" != 0 ]; then
    echo "corpus-chained calibrate: FAILED — the arm is not calibrated, so its numbers are not evidence."
    return 1
  fi
  echo "corpus-chained calibrate: OK — both rows reproduce PRE exit 0 / POST exit 1 through the chain,"
  echo "  and both one-variable controls behave."
  return 0
}

case "${1:-}" in
  scan)      shift; cmd_scan "$@" ;;
  validate)  shift; cmd_validate "$@" ;;
  build)     shift; cmd_build "$@" ;;
  measure)   shift; cmd_measure "$@" ;;
  calibrate) shift; cmd_calibrate "$@" ;;
  *) sed -n '2,10p' "${BASH_SOURCE[0]}"; exit 2 ;;
esac
