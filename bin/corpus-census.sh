#!/usr/bin/env bash
# corpus-census.sh — acquire a PINNED census corpus.  SOUNDNESS R663.
#
#     bash bin/corpus-census.sh java     # 118 Maven artifacts, sha1-verified against the roster
#     bash bin/corpus-census.sh rust     # 1,626 crates at pinned versions
#     bash bin/corpus-census.sh <arm> --check    # report what is missing; acquire nothing
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
HOME_DIR="${CANDOR_CENSUS_HOME:-$HOME/.candor/census}"

case "$ARM" in
  java|rust) ;;
  *) echo "usage: corpus-census.sh java|rust [--check]"; exit 2 ;;
esac
ROSTER="$HERE/bin/corpus-census-$ARM.tsv"
[ -f "$ROSTER" ] || { echo "corpus-census: REFUSING — no roster at $ROSTER"; exit 2; }

if ! bash "$HERE/bin/disk-guard.sh" >/dev/null 2>&1; then
  echo "corpus-census: REFUSING — disk-guard is unhappy.  A full disk fakes an empty result and says"
  echo "  neither; a half-acquired corpus then prints a number that looks like a finding."
  bash "$HERE/bin/disk-guard.sh"; exit 2
fi

DEST="$HOME_DIR/$ARM"
[ "$MODE" = "--check" ] || mkdir -p "$DEST"
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
if [ "$MODE" = "--check" ]; then
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
