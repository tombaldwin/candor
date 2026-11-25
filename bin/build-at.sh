#!/usr/bin/env bash
# bin/build-at.sh — build ENGINE <repo> at COMMIT <commit>, and print where the binary is.
#
#   bin/build-at.sh [--debug] [--rebuild] [--keep-work] [--root DIR] <repo> <commit>
#   bin/build-at.sh --verify <build-dir>      re-hash a finished build against its MANIFEST (exit 1 on mismatch)
#   bin/build-at.sh --list [--root DIR]       every build under the root, with its size
#   bin/build-at.sh --prune N [--root DIR]    keep the newest N builds per repo, delete the rest
#   bin/build-at.sh --selftest                the calibration proofs (fixture repos; no engine checkout needed)
#
# <repo> is candor-rust (builds candor-scan), candor-swift, candor-java (the shadow jar) or candor-ts (a tree with
# node_modules), as a name under $CANDOR_GIT_ROOT (default: the umbrella's parent directory) or as a path whose
# basename is one of those names.  STDOUT IS EXACTLY ONE LINE: the absolute path of the engine artefact.  Everything
# else goes to stderr.
#
# WHY THIS EXISTS (efficiency plan step 6, measured 2026-11-17).  Lanes built "the 0.42.0 arm" or "main" and got a
# binary that was not that commit: a `git archive` carries commit-time mtimes, older than an existing target dir's
# dep-info, so cargo reused stale artefacts and reported a fresh build; a root `cargo build` in candor-rust did not
# rebuild candor-scan; swift and java have equivalents.  Every lane re-solved it by hand, and kill switches stayed
# the bisect instrument because building an old commit was unreliable.
#
# WHAT MAKES THE BINARY PROVABLY THE COMMIT'S
#   1. SOURCE.  The tree is materialised into a FRESH directory from the commit's own objects (a private `.git` that
#      borrows the engine repo's object store read-only through `objects/info/alternates`; `read-tree` + checkout, so
#      every file's mtime is NOW, never commit time).  It is then checked: the index must equal `<commit>^{tree}`, and
#      every regular file on disk must hash (`git hash-object --no-filters`) to the blob the commit holds, with nothing extra.  The engine repo's working tree, index, refs and
#      worktrees are never touched, so a dirty tree or a lane's worktree cannot leak in.  A repo with submodules is
#      refused (their content is not in the commit's tree).
#   2. NO REUSE ACROSS COMMITS.  The target/scratch/project-cache directory is created fresh inside the build's own
#      work dir, and `CARGO_TARGET_DIR`, `RUSTC_WRAPPER` (sccache) and friends are unset.  A finished build lives at
#      <root>/<repo>/<full 40-char sha>[.debug] and carries a MANIFEST naming that sha; a later request for the same
#      sha reuses it only after re-hashing the artefact against the MANIFEST, and a MANIFEST that names a DIFFERENT
#      sha than its directory is refused (exit 1), never rebuilt over and never trusted.
#   3. STAMPS.  candor-java bakes `git rev-parse --short HEAD` into the jar (candor/build-info.properties); this
#      script checks the baked id equals the commit's short sha and fails the build if not (the poisoned-daemon case,
#      CLAUDE.md "Gradle daemon").  candor-scan and candor-swift carry no commit stamp, so for them (1) and (2) are
#      the proof, plus a check that cargo's dep-info lists the source files under THIS build dir and none from
#      another checkout.
#
# REPRODUCIBILITY, stated per toolchain rather than assumed (measured in the report for this lane):
#   rust   RUSTFLAGS remaps the build dir and CARGO_INCREMENTAL=0, so two builds of one commit are compared by
#          sha256.  swift/java: compared by sha256 where the toolchain is deterministic; where it is not the
#          selftest/report says so and the honest equivalence is behavioural (the same report bytes over a fixed
#          fixture).  ts has no compile step: the artefact's identity is the git tree sha plus package-lock sha256.
#
# CONCURRENCY / DISK.  Safe beside lanes that build: a private target dir, `--no-daemon` Gradle, a per-sha lock, and
# an atomic move into place, so a partial build is never visible.  `bin/disk-guard.sh` runs first and the work dir is
# deleted on exit (its size is printed first); `--keep-work` keeps it.  The total size of the root is printed on every
# run and `--prune N` bounds it.
#
# EXIT: 0 built or verified-reused; 1 build/verification failed; 2 usage or refused (disk, unknown commit, submodules).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UMBRELLA="$(cd "$HERE/.." && pwd)"
# shellcheck source=disk-guard.sh
. "$HERE/disk-guard.sh"

log() { printf 'build-at: %s\n' "$*" >&2; }
die() { local rc="$1"; shift; log "$*"; exit "$rc"; }

ROOT="${CANDOR_BUILD_AT_ROOT:-$HOME/.cache/candor/build-at}"
# The engines are siblings of the MAIN umbrella checkout; resolve through the git common dir so this also works
# from a lane worktree of the umbrella (whose own parent directory holds no engines).
_ucommon="$(git -C "$UMBRELLA" rev-parse --git-common-dir 2>/dev/null)"
case "$_ucommon" in /*) ;; *) _ucommon="$UMBRELLA/$_ucommon" ;; esac
GIT_ROOT="${CANDOR_GIT_ROOT:-$(cd "$_ucommon/../.." && pwd)}"

sha256_of() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The artefact identity, ONE definition used by build and verify.  A file: its sha256.  A directory (ts): the
# sha256 of the sorted per-file hashes of the tracked tree plus the lockfile (node_modules is covered by the
# lockfile's integrity hashes, which `npm ci` enforces).
artefact_id() { # $1 build dir ; $2 kind ; $3 relative artefact path
  local f="$1/$3"
  case "$2" in
    ts) ( cd "$f" && find . -path ./node_modules -prune -o -type f -print | LC_ALL=C sort \
            | while read -r p; do shasum -a 256 "$p"; done | shasum -a 256 | cut -d' ' -f1 ) ;;
    *) sha256_of "$f" ;;
  esac
}

kind_of() { # basename -> kind or empty
  case "$1" in
    candor-rust) echo rust ;; candor-swift) echo swift ;; candor-java) echo java ;; candor-ts) echo ts ;;
    *) echo "" ;;
  esac
}

manifest_get() { sed -n "s/^$2=//p" "$1/MANIFEST" | head -1; }

root_size() { du -sk "$ROOT" 2>/dev/null | awk '{printf "%.0f MiB", $1/1024}'; }

do_verify() { # $1 build dir
  local d want got kind rel dirsha base
  d="$(cd "$1" 2>/dev/null && pwd)" || die 1 "verify: no such directory: $1"
  [ -f "$d/MANIFEST" ] || die 1 "verify: no MANIFEST in $d"
  kind="$(manifest_get "$d" kind)"; rel="$(manifest_get "$d" artefact)"; want="$(manifest_get "$d" artefact_sha256)"
  dirsha="$(manifest_get "$d" commit)"; base="$(basename "$d")"
  case "$base" in
    "$dirsha"|"$dirsha".debug) ;;
    *) die 1 "verify: this directory is named $base but its MANIFEST says commit $dirsha — a build of another commit in this place. Refusing." ;;
  esac
  [ -e "$d/$rel" ] || die 1 "verify: artefact $d/$rel is missing"
  got="$(artefact_id "$d" "$kind" "$rel")"
  [ "$got" = "$want" ] || die 1 "verify: MISMATCH — $d/$rel hashes to $got, MANIFEST says $want"
  if [ "$kind" = java ]; then
    local stamp short
    stamp="$(unzip -p "$d/$rel" candor/build-info.properties 2>/dev/null | sed -n 's/^version=//p')"
    short="$(printf '%s' "$dirsha" | cut -c1-"${#stamp}")"
    [ -n "$stamp" ] && [ "$stamp" = "$short" ] || die 1 "verify: jar stamp '$stamp' is not commit $dirsha"
  fi
  log "verify OK: $d/$rel (commit $dirsha, sha256 $got)"
}

if [ "${1:-}" = "--selftest" ]; then
  exec bash "$HERE/build-at.test.sh"
fi

MODE=build; VARIANT=release; REBUILD=0; KEEP_WORK=0; PRUNE_N=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --debug) VARIANT=debug ;;
    --rebuild) REBUILD=1 ;;
    --keep-work) KEEP_WORK=1 ;;
    --root) shift; ROOT="${1:?--root wants a directory}" ;;
    --verify) MODE=verify ;;
    --list) MODE=list ;;
    --prune) MODE=prune; shift; PRUNE_N="${1:?--prune wants N}" ;;
    -h|--help) sed -n '2,12p' "$0" >&2; exit 0 ;;
    -*) die 2 "unknown option $1" ;;
    *) POS+=("$1") ;;
  esac
  shift
done

case "$MODE" in
  verify) [ "${#POS[@]}" = 1 ] || die 2 "usage: build-at.sh --verify <build-dir>"; do_verify "${POS[0]}"; exit 0 ;;
  list)
    [ -d "$ROOT" ] || { log "no builds under $ROOT"; exit 0; }
    for d in "$ROOT"/*/*/; do
      [ -f "${d}MANIFEST" ] || continue
      printf '%s\t%s\t%s\n' "$(du -sk "$d" | awk '{printf "%.0fMiB", $1/1024}')" "${d%/}" "$(sed -n 's/^built=//p' "${d}MANIFEST")"
    done
    log "total $(root_size)"; exit 0 ;;
  prune)
    case "$PRUNE_N" in ''|*[!0-9]*) die 2 "--prune wants a number" ;; esac
    for r in "$ROOT"/*/; do
      [ -d "$r" ] || continue
      i=0
      while read -r d; do
        [ -f "$d/MANIFEST" ] || continue            # never delete (or count) something that is not a finished build
        i=$((i + 1))
        [ "$i" -le "$PRUNE_N" ] && continue
        log "prune $d"; rm -rf "${d:?}"
      done < <(ls -1dt "$r"*/ 2>/dev/null | sed 's|/$||')
    done
    log "total $(root_size)"; exit 0 ;;
esac

[ "${#POS[@]}" = 2 ] || die 2 "usage: build-at.sh [--debug] [--rebuild] [--keep-work] [--root DIR] <repo> <commit>"
REPO_ARG="${POS[0]}"; COMMIT_ARG="${POS[1]}"
case "$REPO_ARG" in
  */*) REPO="$REPO_ARG" ;;
  *) REPO="$GIT_ROOT/$REPO_ARG" ;;
esac
[ -d "$REPO" ] || die 2 "no such repo: $REPO"
NAME="$(basename "$REPO")"
KIND="$(kind_of "$NAME")"
[ -n "$KIND" ] || die 2 "$NAME is not one of candor-rust, candor-swift, candor-java, candor-ts"
SHA="$(git -C "$REPO" rev-parse --verify --quiet "$COMMIT_ARG^{commit}")" || die 2 "$COMMIT_ARG is not a commit in $REPO"
[ "${#SHA}" = 40 ] || die 2 "could not resolve $COMMIT_ARG to a full sha (got '$SHA')"
TREE="$(git -C "$REPO" rev-parse --verify "$SHA^{tree}")"
if git -C "$REPO" ls-tree -r "$SHA" | grep -q '^160000 '; then
  die 2 "$NAME at $SHA has submodules; their content is not in the commit's tree, so a build here could not be proven to be that commit"
fi
[ "$KIND" = ts ] && VARIANT=release     # no debug/release split for ts
SUFFIX=""; [ "$VARIANT" = debug ] && SUFFIX=".debug"

# --- disk ------------------------------------------------------------------------------------------------
mkdir -p "$ROOT/$NAME" || die 2 "cannot create $ROOT/$NAME"
bash "$HERE/disk-guard.sh" --quiet || { bash "$HERE/disk-guard.sh" >&2; die 2 "REFUSING: disk-guard says the disk is unhappy (a full disk fakes a FAIL)"; }

OUT="$ROOT/$NAME/$SHA$SUFFIX"
# --- reuse, only after re-proof -----------------------------------------------------------------------------
if [ -e "$OUT" ] && [ "$REBUILD" = 0 ]; then
  [ -f "$OUT/MANIFEST" ] || die 1 "$OUT exists without a MANIFEST — not a finished build; remove it or pass --rebuild"
  [ "$(manifest_get "$OUT" commit)" = "$SHA" ] || die 1 "$OUT's MANIFEST names commit $(manifest_get "$OUT" commit), not $SHA — a build of ANOTHER commit sits here; refusing to reuse it (--rebuild replaces it)"
  do_verify "$OUT" || exit 1
  log "REUSED the verified build of $SHA ($(root_size) under $ROOT)"
  printf '%s\n' "$OUT/$(manifest_get "$OUT" artefact)"
  exit 0
fi

# --- per-sha lock ------------------------------------------------------------------------------------------
LOCK="$ROOT/$NAME/.lock-$SHA$SUFFIX"
if ! mkdir "$LOCK" 2>/dev/null; then
  holder="$(cat "$LOCK/pid" 2>/dev/null || echo '?')"
  if [ "$holder" != '?' ] && kill -0 "$holder" 2>/dev/null; then die 1 "another build-at (pid $holder) is building $SHA; wait for it"; fi
  log "stale lock from pid $holder — taking it"; rm -rf "${LOCK:?}"; mkdir "$LOCK" || die 1 "cannot take $LOCK"
fi
echo "$$" > "$LOCK/pid"
WORK="$ROOT/$NAME/.work-$SHA$SUFFIX"      # no pid: the path is baked into debug symbols (N_OSO), and the per-sha lock already makes it exclusive
cleanup() {
  if [ "$KEEP_WORK" = 0 ] && [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then rm -rf "${WORK:?}"; fi
  rm -rf "${LOCK:?}"
}
trap cleanup EXIT
rm -rf "${WORK:?}"; mkdir -p "$WORK"
SRC="$WORK/src"

# --- 1. SOURCE: materialise from the commit's own objects, then PROVE it ----------------------------------
COMMON="$(git -C "$REPO" rev-parse --git-common-dir)"; case "$COMMON" in /*) ;; *) COMMON="$REPO/$COMMON" ;; esac
mkdir -p "$SRC"
git init -q "$SRC" || die 1 "git init failed in $SRC"
echo "$COMMON/objects" > "$SRC/.git/objects/info/alternates"
git -C "$SRC" config core.autocrlf false
git -C "$SRC" config gc.auto 0
git -C "$SRC" update-ref --no-deref HEAD "$SHA" || die 1 "could not point the private HEAD at $SHA"
git -C "$SRC" read-tree --reset -u HEAD || die 1 "read-tree failed"
# TEST INJECTION POINT (the same kind CANDOR_DISK_FAKE_FREE_MB is): a check nobody has watched fail is not a check.
if [ "${CANDOR_BUILD_AT_FAULT:-}" = corrupt-source ]; then
  echo "corrupted after checkout" >> "$SRC/$(git -C "$SRC" ls-files | head -1)"
fi
# (a) the index is the commit's tree; (b) every regular file ON DISK hashes to the blob the commit holds, which is
# what a stat-based `git status` can miss; (c) nothing extra is on disk.
GOT_TREE="$(git -C "$SRC" write-tree)"
[ "$GOT_TREE" = "$TREE" ] || die 1 "SOURCE CHECK FAILED: the materialised index is tree $GOT_TREE, the commit's is $TREE"
git -C "$SRC" ls-tree -r "$SHA" | awk '$1 ~ /^100/ {print $3 "\t" substr($0, index($0, "\t") + 1)}' | LC_ALL=C sort > "$WORK/tree.blobs"
( cd "$SRC" && git ls-tree -r -z --name-only "$SHA" | while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue; printf '%s\t%s\n' "$(git hash-object --no-filters -- "$f")" "$f"
  done ) | LC_ALL=C sort > "$WORK/disk.blobs"
# (symlinks, mode 120000, are skipped on both sides: hash-object would hash their TARGET)
cmp -s "$WORK/tree.blobs" "$WORK/disk.blobs" || die 1 "SOURCE CHECK FAILED: files on disk differ from the commit's blobs: $(diff "$WORK/tree.blobs" "$WORK/disk.blobs" | head -4 | tr '\n' ' ')"
[ -z "$(git -C "$SRC" ls-files --others)" ] || die 1 "SOURCE CHECK FAILED: untracked files are present in the fresh tree"
log "source verified: $NAME @ $SHA, tree $TREE ($(find "$SRC" -path "$SRC/.git" -prune -o -type f -print | wc -l | tr -d ' ') files, fresh mtimes)"

# --- 2. BUILD, in a private environment ------------------------------------------------------------------
BUILDLOG="$WORK/build.log"
ART=""; TOOLCHAIN=""
benv() { env -u CARGO_TARGET_DIR -u CARGO_BUILD_TARGET_DIR -u RUSTFLAGS -u CARGO_ENCODED_RUSTFLAGS -u CARGO_BUILD_RUSTFLAGS \
             -u RUSTC_WRAPPER -u CARGO_BUILD_RUSTC_WRAPPER -u RUSTC_WORKSPACE_WRAPPER "$@"; }
run_build() { # runs "$@" in $SRC, log to $BUILDLOG; fail the whole build on nonzero
  ( cd "$SRC" && "$@" ) >>"$BUILDLOG" 2>&1 || { tail -25 "$BUILDLOG" >&2; die 1 "BUILD FAILED ($*) — nothing is advertised; full log: $BUILDLOG (kept: --keep-work)"; }
}
mkdir -p "$WORK/stage"
case "$KIND" in
  rust)
    PROFILE_FLAG="--release"; PDIR=release
    [ "$VARIANT" = debug ] && { PROFILE_FLAG=""; PDIR=debug; }
    TOOLCHAIN="$(cd "$SRC" && rustc -V 2>/dev/null) / $(cd "$SRC" && cargo -V 2>/dev/null)"
    log "building candor-scan ($VARIANT) with $TOOLCHAIN"
    # shellcheck disable=SC2086  # PROFILE_FLAG is deliberately empty-or-one-word
    run_build benv env CARGO_INCREMENTAL=0 CARGO_TARGET_DIR="$WORK/target" \
      RUSTFLAGS="--remap-path-prefix=$SRC=/candor-build-at/src" cargo build --locked -p candor-scan $PROFILE_FLAG
    BIN="$WORK/target/$PDIR/candor-scan"
    [ -x "$BIN" ] || die 1 "cargo exited 0 but $BIN does not exist (the root-build trap: -p candor-scan was asked for explicitly)"
    # dep-info: what cargo actually compiled came from THIS build dir
    DEP="$WORK/depinfo.all"; cat "$WORK/target/$PDIR/deps/"candor_scan-*.d > "$DEP" 2>/dev/null
    if [ -s "$DEP" ]; then
      # cargo writes workspace members RELATIVE to the workspace root (= $SRC, the build's cwd); an ABSOLUTE
      # candor-scan source path would mean another checkout was compiled.
      inside="$(grep -oE '(^|[ :])crates/candor-scan/src/[^ :]+' "$DEP" | sort -u | wc -l | tr -d ' ')"
      foreign="$(grep -oE '/[^ :]*crates/candor-scan/src/[^ :]+' "$DEP" | grep -vc "^$SRC/")"
      [ "$inside" -gt 0 ] && [ "$foreign" = 0 ] || die 1 "DEP-INFO CHECK FAILED: $DEP names $inside candor-scan source file(s) relative to the build dir and $foreign absolute path(s) elsewhere"
      log "dep-info: $inside candor-scan source file(s), all relative to this build dir, none absolute elsewhere"
    else
      die 1 "no dep-info for candor-scan under $WORK/target/$PDIR/deps — cannot show what was compiled"
    fi
    mkdir -p "$WORK/stage/bin"; cp "$BIN" "$WORK/stage/bin/candor-scan"; ART="bin/candor-scan" ;;
  swift)
    PRODUCT_CFG="release"; [ "$VARIANT" = debug ] && PRODUCT_CFG="debug"
    TOOLCHAIN="$(swift --version 2>&1 | head -1)"
    log "building candor-swift ($VARIANT) with $TOOLCHAIN"
    run_build swift build -c "$PRODUCT_CFG" --product candor-swift --scratch-path "$WORK/scratch" --only-use-versions-from-resolved-file
    BIN="$(cd "$SRC" && swift build -c "$PRODUCT_CFG" --product candor-swift --scratch-path "$WORK/scratch" --only-use-versions-from-resolved-file --show-bin-path 2>/dev/null)/candor-swift"
    [ -x "$BIN" ] || die 1 "swift build exited 0 but $BIN does not exist"
    mkdir -p "$WORK/stage/bin"; cp "$BIN" "$WORK/stage/bin/candor-swift"; ART="bin/candor-swift" ;;
  java)
    TOOLCHAIN="$(java -version 2>&1 | head -1)"
    log "building candor-java shadowJar with $TOOLCHAIN (--no-daemon, private project cache)"
    run_build env GRADLE_OPTS="-Dorg.gradle.daemon=false" ./gradlew --no-daemon --project-cache-dir "$WORK/gradle-project" -q shadowJar
    n="$(ls "$SRC"/build/libs/*-all.jar 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" = 1 ] || die 1 "expected exactly one build/libs/*-all.jar in a FRESH tree, found $n"
    JAR="$(ls "$SRC"/build/libs/*-all.jar)"
    stamp="$(unzip -p "$JAR" candor/build-info.properties 2>/dev/null | sed -n 's/^version=//p')"
    [ -n "$stamp" ] && [ "$stamp" = "$(printf '%s' "$SHA" | cut -c1-"${#stamp}")" ] \
      || die 1 "JAR STAMP CHECK FAILED: build-info says version='$stamp', the commit is $SHA (a poisoned daemon or a wrong tree)"
    log "jar stamp: version=$stamp is the short sha of $SHA"
    mkdir -p "$WORK/stage/lib"; cp "$JAR" "$WORK/stage/lib/candor-java-all.jar"; ART="lib/candor-java-all.jar" ;;
  ts)
    TOOLCHAIN="node $(node -v) / npm $(npm -v)"
    log "installing candor-ts dependencies with $TOOLCHAIN (npm ci: lockfile-exact)"
    [ -f "$SRC/package-lock.json" ] || die 1 "no package-lock.json at $SHA; npm ci cannot be lockfile-exact"
    run_build npm ci --ignore-scripts --no-fund --no-audit
    rm -rf "${SRC:?}/.git"
    mv "$SRC" "$WORK/stage/ts"; ART="ts" ;;
esac

# --- 3. record, then move into place atomically -----------------------------------------------------------
WORK_KB="$(du -sk "$WORK" | awk '{print $1}')"
ARTID="$(artefact_id "$WORK/stage" "$KIND" "$ART")"
{
  echo "repo=$NAME"; echo "kind=$KIND"; echo "variant=$VARIANT"; echo "commit=$SHA"; echo "tree=$TREE"
  echo "short=$(printf '%s' "$SHA" | cut -c1-9)"
  echo "source_verified=index-tree-equal+disk-blobs-equal"; echo "artefact=$ART"; echo "artefact_sha256=$ARTID"
  echo "toolchain=$TOOLCHAIN"; echo "host=$(uname -srm)"; echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "work_dir_kib=$WORK_KB"
} > "$WORK/stage/MANIFEST"
cp "$BUILDLOG" "$WORK/stage/build.log" 2>/dev/null || true
if [ -e "$OUT" ]; then rm -rf "${OUT:?}"; fi    # only reachable with --rebuild, or a dir already refused above
mv "$WORK/stage" "$OUT" || die 1 "could not move the finished build into $OUT"
log "built $NAME @ $SHA ($VARIANT): artefact sha256 $ARTID"
if [ "$KEEP_WORK" = 0 ]; then rm -rf "${WORK:?}"; fi      # before the size line, so it reports what REMAINS
log "disk: work dir was $((WORK_KB / 1024)) MiB ($( [ "$KEEP_WORK" = 1 ] && echo kept || echo deleted )); kept build $(du -sk "$OUT" | awk '{printf "%.0f MiB", $1/1024}'); $ROOT is now $(root_size) — bound it with --prune N"
printf '%s\n' "$OUT/$ART"
