#!/usr/bin/env bash
# corpus-census.sh — acquire a PINNED census corpus.  SOUNDNESS R663.
#
#     bash bin/corpus-census.sh java     # every jar in bin/corpus-census-java.tsv, sha1-verified
#     bash bin/corpus-census.sh rust     # every crate in bin/corpus-census-rust.tsv, at its pinned version
#     bash bin/corpus-census.sh ts       # every repo in bin/corpus-census-ts.tsv, at its pinned COMMIT
#     bash bin/corpus-census.sh <arm> --check    # report what is missing; acquire nothing
#     bash bin/corpus-census.sh ts --measure     # …and ASK THE ENGINE what it analyses (R744)
#
# THE SIZE IS NOT WRITTEN HERE, ON PURPOSE. These lines said "118 Maven artifacts" while the java
# roster held 452 — a count copied into a comment on the day the roster was created and stale by the
# time it grew, which is the same failure CLAUDE.md records for the gate count ("the count is a
# function of HEAD, so print it"). The run prints `roster N` from the file itself; for the number
# without acquiring anything:  awk 'NF && $0 !~ /^#/' bin/corpus-census-<arm>.tsv | wc -l
#
# WHY THIS EXISTS, and why it is separate from `corpus.sh`.  R662 priced what a month of soundness
# work changes for a user of a gate, over "1,626 crates" — which were not a corpus but whatever cargo
# had happened to download onto one laptop.  Nothing owned it, nothing pinned it, it is absent from the
# second machine, and so THE PROJECT'S HEADLINE MEASUREMENT WAS UNREPEATABLE BY ANYONE INCLUDING US.
# The java side was worse: no standing corpus at all, while the register cites 325-395-jar runs whose
# rosters died with their scratchpads.
#
# `corpus.sh` keeps its own small roster and MUST keep it: those entries are chosen for the SHAPES they
# expose, one filter or one defect class each.  This tool is for SCALE — so that a percentage has a
# denominator and a census can be re-run on another box and get the same answer.
#
# THE ACQUISITION IS VERIFIED, because an unverified corpus fails in the flattering direction: a
# truncated jar or a hollow crate directory contributes ZERO rows, and zero rows is indistinguishable
# from a change that is correctly inert (R242, and the hollow /tmp/candor-corpus that printed 0/0/0).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARM="${1:-}"; MODE="${2:-}"
# --measure is the ts arm's engine-run fitness pass (R744). Treated as a checking mode everywhere a
# mode is tested, so it never acquires.
[ "$MODE" = "--measure" ] && [ "$ARM" != "ts" ] && { echo "corpus-census: --measure is the ts arm only"; exit 2; }
HOME_DIR="${CANDOR_CENSUS_HOME:-$HOME/.candor/census}"

case "$ARM" in
  java|rust|ts) ;;
  *) echo "usage: corpus-census.sh java|rust|ts [--check]"; exit 2 ;;
esac
ROSTER="$HERE/bin/corpus-census-$ARM.tsv"
[ -f "$ROSTER" ] || { echo "corpus-census: REFUSING — no roster at $ROSTER"; exit 2; }

if ! bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1; then
  echo "corpus-census: REFUSING — disk-guard is unhappy.  A full disk fakes an empty result and says"
  echo "  neither; a half-acquired corpus then prints a number that looks like a finding."
  bash "$HERE/bin/disk-guard.sh"; exit 2
fi

DEST="$HOME_DIR/$ARM"
case "$MODE" in --check|--measure) ;; *) mkdir -p "$DEST" ;; esac
want=0; have=0; got=0; miss=0; bad=0

if [ "$ARM" = "java" ]; then
  M=https://repo1.maven.org/maven2
  while IFS=$'\t' read -r coord sha; do
    case "$coord" in ''|\#*) continue ;; esac
    want=$((want + 1))
    g="${coord%%:*}"; rest="${coord#*:}"; a="${rest%%:*}"; v="${rest##*:}"
    f="$DEST/$a-$v.jar"
    if [ -f "$f" ]; then
      actual="$(shasum -a 1 "$f" 2>/dev/null | cut -d' ' -f1)"
      if [ "$actual" = "$sha" ]; then
        # SHA1 PROVES INTEGRITY, NOT FITNESS — SOUNDNESS R666, found on this roster's FIRST use.
        # `com.squareup.okio:okio:3.9.0` verified, downloaded and sha1-matched PERFECTLY, and holds
        # ZERO `.class` files: it is the Kotlin Multiplatform *metadata* artifact. Every engine
        # refused it at exit 2, so it contributed nothing to the denominator and the census silently
        # compared 117 of 118. A coordinate can be real, current, popular and still be a BOM, a
        # `-sources`, or a `-metadata` jar. That is the R242 hollow-corpus class one layer up,
        # defeated by an entry that is not corrupt at all — so integrity is checked above and
        # FITNESS is checked here, and an unfit jar counts as BAD rather than present.
        if [ "$(unzip -l "$f" 2>/dev/null | grep -c '\.class$')" -eq 0 ]; then
          echo "  UNFIT $a-$v.jar — sha1 correct, ZERO .class files (BOM/-sources/-metadata?)"
          bad=$((bad + 1)); continue
        fi
        have=$((have + 1)); continue
      fi
      echo "  CORRUPT $a-$v.jar — sha1 $actual != roster $sha"
      bad=$((bad + 1)); [ "$MODE" = "--check" ] && continue; rm -f "$f"
    fi
    [ "$MODE" = "--check" ] && { miss=$((miss + 1)); continue; }
    url="$M/$(echo "$g" | tr '.' '/')/$a/$v/$a-$v.jar"
    if curl -fsSL --max-time 120 -o "$f" "$url"; then
      actual="$(shasum -a 1 "$f" 2>/dev/null | cut -d' ' -f1)"
      if [ "$actual" != "$sha" ]; then
        echo "  SHA MISMATCH $a-$v.jar — got $actual want $sha"; rm -f "$f"; bad=$((bad + 1))
      elif [ "$(unzip -l "$f" 2>/dev/null | grep -c '\.class$')" -eq 0 ]; then
        echo "  UNFIT $a-$v.jar — sha1 correct, ZERO .class files (R666)"; bad=$((bad + 1))
      else got=$((got + 1)); fi
    else
      echo "  MISS $coord"; miss=$((miss + 1))
    fi
  done < "$ROSTER"
elif [ "$ARM" = "ts" ]; then
  # TS: the roster pins REPOSITORIES at a COMMIT, not npm packages, and the roster header records the
  # measurement that decided it — 4 of 5 widely-used npm tarballs ship ZERO non-declaration TypeScript.
  #
  # THE TAG IS HOW WE FETCH; THE SHA IS WHAT WE VERIFY.  A shallow clone of a tag is cheap, and a tag
  # can be force-moved, so `rev-parse HEAD` must equal the pinned sha or the entry is BAD rather than
  # present.  That is this arm's sha1.
  #
  # AND FITNESS IS CHECKED SEPARATELY, because integrity does not imply analysable content — R666, the
  # 16 jars with a correct sha1 and no `.class` files.  The rule is candor-ts's OWN (`scan.mjs:1496`):
  # `/\.[mc]?tsx?$/` and NOT `.d.ts`.  It is a copy, and the copy is PINNED rather than trusted:
  # `ci/ts-fitness-pin.sh` fails if that predicate changes in candor-ts without this one changing too.
  while IFS=$'\t' read -r repo tag sha target want_src want_an want_rows; do
    case "$repo" in ''|\#*) continue ;; esac
    want=$((want + 1))
    name="${repo##*/}"
    d="$DEST/$name"
    fit() { find "$1" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.mts' -o -name '*.cts' \) \
              -not -name '*.d.ts' -not -path '*/node_modules/*' 2>/dev/null | wc -l | tr -d ' '; }
    # ASK GIT, NOT THE FILESYSTEM. `-d "$d/.git"` is false for a git WORKTREE, where `.git` is a FILE —
    # so the first cut of this arm would have read a worktree as absent and re-cloned over it. The
    # umbrella's release-test has a standing assertion against that spelling and it caught this on the
    # first CI run after the push; `rev-parse` is the authority and answers for every layout.
    if actual="$(git -C "$d" rev-parse HEAD 2>/dev/null)" && [ -n "$actual" ]; then
      if [ "$actual" != "$sha" ]; then
        echo "  BAD  $repo — HEAD $actual, roster pins $sha"; bad=$((bad + 1)); continue
      fi
      n="$(fit "$d")"
      if [ "$n" -lt 5 ]; then
        echo "  UNFIT $repo at the pinned sha — $n analysable .ts file(s), fewer than the 5-file floor"
        bad=$((bad + 1)); continue
      fi
      if [ "$n" != "$want_src" ]; then
        echo "  NOTE $repo — $n analysable .ts files, roster recorded $want_src at this sha"
      fi
      # --measure: ASK THE ENGINE. This is the only check that catches the R744 class — a repository
      # whose on-disk `.ts` count is healthy while candor-ts analyses almost nothing, because file
      # selection runs through the TypeScript project rather than the filesystem. Three of the first
      # thirty entries were that shape (execa 119 files -> 1 unit; apollo-server 110 -> 0, refused).
      if [ "$MODE" = "--measure" ]; then
        tdir="$d"; [ "$target" != "." ] && tdir="$d/$target"
        if [ ! -d "$tdir" ]; then
          echo "  BAD  $repo — target '$target' does not exist at the pinned sha"; bad=$((bad + 1)); continue
        fi
        node "$HERE/../candor-ts/scan.mjs" "$tdir" --out "$DEST/.m-$name" >/dev/null 2>&1
        if [ ! -f "$DEST/.m-$name.json" ]; then
          echo "  BAD  $repo — candor-ts wrote no report for target '$target'"; bad=$((bad + 1)); continue
        fi
        measured="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print((d.get('analyzed') or {}).get('count') or 0, len(d.get('functions') or []))" "$DEST/.m-$name.json" 2>/dev/null)"
        got_an="${measured%% *}"; got_rows="${measured##* }"
        rm -f "$DEST/.m-$name.json" "$DEST/.m-$name.callgraph.json"
        # A COLLAPSE, not a wobble. The roster's number is the denominator every percentage divides by,
        # so the floor is generous on drift and unforgiving on a collapse to nothing.
        if [ "${got_an:-0}" -lt $(( want_an / 2 )) ] || [ "${got_an:-0}" -lt 20 ]; then
          echo "  BAD  $repo — candor-ts analysed ${got_an:-0} units, roster records $want_an. A"
          echo "       collapsed entry contributes nothing while still counting toward the roster size,"
          echo "       which moves every percentage the flattering way and says nothing about it."
          bad=$((bad + 1)); continue
        fi
        [ "${got_an:-0}" != "$want_an" ] && \
          echo "  NOTE $repo — analysed ${got_an:-0}, roster records $want_an (within the drift floor)"
        # ROWS are what an A/B actually diffs, so a roster that records units and not rows would let the
        # denominator hold while the thing being compared moved underneath it.
        [ "${got_rows:-0}" != "$want_rows" ] && \
          echo "  NOTE $repo — ${got_rows:-0} rows, roster records $want_rows"
      fi
      have=$((have + 1)); continue
    fi
    case "$MODE" in --check|--measure) echo "  MISS $repo@$tag"; miss=$((miss + 1)); continue ;; esac
    rm -rf "$d"
    if ! git clone -q --depth 1 --branch "$tag" "https://github.com/$repo" "$d" 2>/dev/null; then
      echo "  MISS $repo@$tag (clone failed)"; miss=$((miss + 1)); continue
    fi
    actual="$(git -C "$d" rev-parse HEAD 2>/dev/null)"
    if [ "$actual" != "$sha" ]; then
      echo "  BAD  $repo@$tag — clone gave $actual, roster pins $sha.  A MOVED TAG is exactly what this"
      echo "       check exists for; do not edit the roster to match, work out which commit is right."
      bad=$((bad + 1)); rm -rf "$d"; continue
    fi
    n="$(fit "$d")"
    if [ "$n" -lt 5 ]; then
      echo "  UNFIT $repo@$tag — sha correct, $n analysable .ts file(s) (R666's shape in TypeScript)"
      bad=$((bad + 1)); rm -rf "$d"; continue
    fi
    got=$((got + 1))
  done < "$ROSTER"
else
  # Rust: the pinned crates come from the local cargo registry cache if present, and are otherwise
  # fetched as .crate tarballs from static.crates.io and unpacked.  A crate DIRECTORY that exists and
  # holds no .rs file is HOLLOW and is treated as missing — R242, and the /tmp/candor-corpus that
  # printed 0/0/0 for an hour before anyone noticed it held nothing.
  REG="$(ls -d "$HOME"/.cargo/registry/src/index.crates.io-*/ 2>/dev/null | head -1)"
  while IFS=$'\t' read -r name ver; do
    case "$name" in ''|\#*) continue ;; esac
    want=$((want + 1))
    d="$DEST/$name-$ver"
    if [ -d "$d" ] && [ -n "$(find "$d" -name '*.rs' -print -quit 2>/dev/null)" ]; then
      have=$((have + 1)); continue
    fi
    [ -d "$d" ] && { echo "  HOLLOW $name-$ver — directory present, no .rs inside"; bad=$((bad + 1)); }
    [ "$MODE" = "--check" ] && { miss=$((miss + 1)); continue; }
    if [ -n "$REG" ] && [ -d "$REG/$name-$ver" ] && \
       [ -n "$(find "$REG/$name-$ver" -name '*.rs' -print -quit 2>/dev/null)" ]; then
      cp -R "$REG/$name-$ver" "$d" && got=$((got + 1)) || miss=$((miss + 1))
    elif curl -fsSL --max-time 120 -o "$DEST/.t.crate" \
           "https://static.crates.io/crates/$name/$name-$ver.crate" 2>/dev/null; then
      mkdir -p "$d" && tar xzf "$DEST/.t.crate" -C "$d" --strip-components=1 2>/dev/null \
        && got=$((got + 1)) || { echo "  MISS $name@$ver (unpack)"; miss=$((miss + 1)); }
      rm -f "$DEST/.t.crate"
    else
      echo "  MISS $name@$ver"; miss=$((miss + 1))
    fi
  done < "$ROSTER"
fi

echo
echo "corpus-census $ARM: roster $want, already present $have, acquired $got, missing $miss, bad $bad"
echo "  corpus at $DEST"
# A CENSUS OVER A PARTIAL CORPUS IS NOT THE CENSUS THE ROSTER NAMES, and the difference is invisible
# in the output: a smaller denominator moves every percentage in the flattering direction.
present=$((have + got))
if [ "$MODE" = "--check" ] || [ "$MODE" = "--measure" ]; then
  [ "$miss" -eq 0 ] && [ "$bad" -eq 0 ] && { echo "  COMPLETE."; exit 0; }
  echo "  INCOMPLETE — $miss missing, $bad corrupt/hollow.  Run without --check to acquire."; exit 1
fi
if [ "$present" -lt "$want" ]; then
  echo "  INCOMPLETE — $present of $want.  Quote the ACTUAL denominator in any figure derived from"
  echo "  this corpus, or re-run until it is whole: a partial corpus moves every percentage the"
  echo "  flattering way and says nothing about it."
  exit 1
fi
echo "  COMPLETE — $present of $want."
