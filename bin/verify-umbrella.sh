#!/usr/bin/env bash
# verify-umbrella.sh — run what the UMBRELLA's own workflows run, before pushing.
#
# WHY THIS EXISTS (2026-08-25). `bin/verify-local.sh` walks the ENGINE repos — candor-rust's clippy,
# candor-ts's node suite, candor-java's gradle. Nothing ran candor's own workflows, and it showed, three
# times in one day:
#
#   1. An agent ran `release-test.sh`, `candor.test.sh`, `shellcheck` and `bash -n` in a clean worktree and
#      called it "the union of what the three workflows run". It was not: `integrations.yml` runs NINE
#      steps and four of them were not in that list. main went red on the push.
#   2. `release-test.sh` said 148/148 locally while CI said 8 FAILED on the same script — because local ran
#      against a WORKING TREE that CI never checks out.
#   3. A reproduction attempt on arm64 Linux reported 18 failures where CI reported 2. Twelve were pure
#      architecture artefacts. A faithless reproduction manufactures work.
#
# So this script answers those three, in that order:
#
#   * NOTHING IS TRANSCRIBED. The step list comes from `.github/workflows/*.yml` via `bin/wf-steps.py`.
#     Add a step to a workflow and it runs here on the next invocation with no edit to this file. That is
#     the whole point: a hand-kept list of what CI runs drifts from CI silently, in the direction of
#     running less, and its shortfall looks exactly like a pass.
#   * IT RUNS A COMMIT, NOT YOUR DESK. A throwaway `git worktree` at the rev under test, so uncommitted
#     files cannot make it pass and untracked ones cannot make it fail. The sha is printed on every run.
#   * PLATFORM IS DECLARED, NOT ASSUMED. Every job carries `runs-on:`. Running an ubuntu job on macOS is
#     an APPROXIMATION and each such row says so; `--docker` runs them on `linux/amd64` — explicitly
#     amd64, because arm64 Linux is not what CI runs and produced those twelve phantom failures.
#
# AND WHAT IT DID NOT RUN IS PART OF THE REPORT, always, with a count and a reason each. A check that
# silently skips is the failure mode this whole exercise is about.
#
# USAGE
#   bash bin/verify-umbrella.sh                 # what GitHub would trigger for HEAD, on this host
#   bash bin/verify-umbrella.sh --all           # every push/PR workflow, path filters ignored
#   bash bin/verify-umbrella.sh --docker        # the ubuntu jobs on linux/amd64, faithfully
#   bash bin/verify-umbrella.sh --rev <sha>     # some other commit
#   bash bin/verify-umbrella.sh --workflow integrations.yml   # one workflow, for iterating
#   bash bin/verify-umbrella.sh --list          # enumerate and classify; run nothing
#
# Exit 0 only if every step it RAN passed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The record separator `wf-steps.py` emits. It is 0x1f and NOT a tab on purpose: a tab is IFS
# WHITESPACE, so `IFS=$'\t' read` collapses runs of them and every empty field silently disappears,
# shifting every later column left. That bug's first appearance here read the shell name as the working
# directory and reported two passing steps as failures.
SEP=$'\x1f'

REV=HEAD; ALL=0; DOCKER=0; LIST=0; ONLY_WF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rev)      REV="${2:?--rev needs a git rev}"; shift 2 ;;
    --workflow) ONLY_WF="${2:?--workflow needs a file name, e.g. integrations.yml}"; shift 2 ;;
    --all)      ALL=1; shift ;;
    --docker)   DOCKER=1; shift ;;
    --list)     LIST=1; shift ;;
    -h|--help)  sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "verify-umbrella: unknown argument '$1'"; echo "  try --help"; exit 2 ;;
  esac
done

SHA="$(git -C "$REPO" rev-parse --verify "$REV" 2>/dev/null)" \
  || { echo "verify-umbrella: '$REV' is not a rev in $REPO"; exit 2; }
SHORT="${SHA:0:7}"

TMP="$(mktemp -d)"
WT="$TMP/wt"
cleanup() {
  [ -d "$WT" ] && git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

git -C "$REPO" worktree add --detach --quiet "$WT" "$SHA" \
  || { echo "verify-umbrella: could not create a worktree at $SHORT"; exit 2; }

# ── the platform question ────────────────────────────────────────────────────────────────────────────
HOST_OS="linux"; [ "$(uname -s)" = "Darwin" ] && HOST_OS="darwin"
HOST_ARCH="$(uname -m)"
IMAGE="candor-verify-umbrella:bookworm-amd64"
if [ "$DOCKER" = 1 ]; then
  command -v docker >/dev/null 2>&1 || { echo "verify-umbrella: --docker but no docker on PATH"; exit 2; }
  docker info >/dev/null 2>&1 || { echo "verify-umbrella: --docker but the docker daemon is not running"; exit 2; }
  TARGET_OS="linux"
else
  TARGET_OS="$HOST_OS"
fi

# ── enumerate ────────────────────────────────────────────────────────────────────────────────────────
STEPS="$TMP/steps.tsv"
python3 "$HERE/wf-steps.py" "$WT" --event push --os "$TARGET_OS" > "$STEPS" || {
  echo "verify-umbrella: could not enumerate workflow steps — see the message above"; exit 2; }

# WHICH WORKFLOWS WOULD GITHUB ACTUALLY START? That question already has an owner — `bin/wf-expected.py`,
# whose header records what happens when a second copy of trigger logic exists. So it is asked, not
# re-implemented, once per commit in the range about to be pushed (GitHub path-filters a push on the
# union of its commits' files, not on the tip's alone).
REQUIRED="$TMP/required"; : > "$REQUIRED"
RANGE_DESC="commit $SHORT alone"
# THE BRANCH THE PUSH WILL LAND ON, stated rather than discovered. The worktree is DETACHED by
# construction, so asking git inside it returns the literal "HEAD" — which matches no `branches:` filter
# and silently dropped three of the five push-triggered workflows on this script's own first green
# control. Ask the real repo; fall back to main when that is detached too, and print whichever it was.
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
BRANCH_NOTE=""
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
  BRANCH=main; BRANCH_NOTE=" (assumed — $REPO is on a detached HEAD)"
fi
if [ "$ALL" = 0 ]; then
  base=""
  if up="$(git -C "$REPO" rev-parse --verify --quiet "$SHA@{u}" 2>/dev/null)"; then base="$up"; fi
  [ -z "$base" ] && up="$(git -C "$REPO" rev-parse --verify --quiet origin/main 2>/dev/null)" && base="$up"
  revs="$SHA"
  if [ -n "$base" ] && git -C "$REPO" merge-base --is-ancestor "$base" "$SHA" 2>/dev/null; then
    n="$(git -C "$REPO" rev-list --count "$base..$SHA")"
    if [ "$n" -gt 0 ] && [ "$n" -le 50 ]; then
      revs="$(git -C "$REPO" rev-list "$base..$SHA")"
      RANGE_DESC="the $n commit(s) in ${base:0:7}..$SHORT"
    elif [ "$n" -gt 50 ]; then
      RANGE_DESC="commit $SHORT alone ($n commits ahead of ${base:0:7} — too many to union, so this UNDER-selects)"
    fi
  fi
  for r in $revs; do
    # NOT `2>/dev/null`: this call's only failure mode is one that makes it answer "nothing is
    # required", and swallowing that turns a broken selector into a silent, plausible-looking pass.
    if ! python3 "$HERE/wf-expected.py" "$WT" "$r" "$BRANCH" > "$TMP/exp.$$" 2>"$TMP/experr.$$"; then
      echo "verify-umbrella: wf-expected.py failed for $r — the selection cannot be trusted:"
      sed 's/^/    /' "$TMP/experr.$$"
      exit 2
    fi
    awk -F'\t' '$2=="required"{print $1}' "$TMP/exp.$$" >> "$REQUIRED"
  done
  sort -u -o "$REQUIRED" "$REQUIRED"
fi

wf_required() {  # $1 = workflow display name
  [ "$ALL" = 1 ] && return 0
  grep -qxF "$1" "$REQUIRED"
}

# ── provisioning stand-ins for the `uses:` steps, disclosed rather than assumed ───────────────────────
# `actions/setup-python` puts a FRESH, ISOLATED interpreter on PATH as both `python` and `python3` — and
# `integrations.yml` calls `python`, which does not exist on macOS at all. So the stand-in is a venv: same
# two names, same isolation, and `pip install jsonschema` lands in it rather than failing against a
# system interpreter that is externally managed. Every stand-in made is printed in the ledger; a step
# running against something other than what CI gave it must never be indistinguishable from one that was.
SHIMS="$TMP/shims"; mkdir -p "$SHIMS"
PROVISIONED=""; MISSING_TOOLS=""
provision_native() {
  local tools; tools="$(awk -F"$SEP" -v ok="$INSCOPE" '
      BEGIN { while ((getline l < ok) > 0) live[l] = 1 }
      $1=="PROVISION" && $8!="" && (($2 "|" $4) in live) { print $8 }' "$STEPS" | sort -u)"
  local t
  for t in $tools; do
    case "$t" in
      python3)
        if python3 -m venv "$TMP/venv" >/dev/null 2>&1; then
          ln -sf "$TMP/venv/bin/python3" "$SHIMS/python"
          ln -sf "$TMP/venv/bin/python3" "$SHIMS/python3"
          ln -sf "$TMP/venv/bin/pip" "$SHIMS/pip" 2>/dev/null
          PROVISIONED="$PROVISIONED
    actions/setup-python  -> a throwaway venv on \$PATH as both python and python3 ($("$TMP/venv/bin/python3" -V 2>&1))"
        else
          MISSING_TOOLS="$MISSING_TOOLS python(venv-failed)"
        fi ;;
      *)
        if command -v "$t" >/dev/null 2>&1; then
          PROVISIONED="$PROVISIONED
    a \`uses:\` providing \`$t\`   -> this machine's $t ($(command -v "$t"))"
        else
          MISSING_TOOLS="$MISSING_TOOLS $t"
        fi ;;
    esac
  done
}

# WHICH JOBS ARE ACTUALLY IN SCOPE — decided once, before anything runs, so that the provisioning ledger
# and the run itself cannot disagree about what this invocation covers.
INSCOPE="$TMP/inscope"; : > "$INSCOPE"
while IFS=$'\x1f' read -r status file wfname job _rest; do
  [ "$status" = "RUN" ] || continue
  [ -n "$ONLY_WF" ] && [ "$file" != "$ONLY_WF" ] && continue
  wf_required "$wfname" && printf '%s|%s\n' "$file" "$job" >> "$INSCOPE"
done < "$STEPS"
sort -u -o "$INSCOPE" "$INSCOPE"

[ "$DOCKER" = 0 ] && provision_native

# ── the linux/amd64 image, for --docker ──────────────────────────────────────────────────────────────
# NOT the GitHub runner image, and this says so on every run. It is Debian bookworm with the toolchains
# the workflows' `uses:` steps provision. What it DOES reproduce faithfully is the thing that generated
# twelve phantom failures: the platform. `--platform linux/amd64` is explicit and non-negotiable — arm64
# Linux is not what CI runs, and on this host a bare `docker run` would give exactly that.
build_image() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  echo "  building $IMAGE (linux/amd64, one time)…"
  docker build --platform linux/amd64 -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE'
FROM node:22-bookworm-slim
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash ca-certificates curl git jq python3 python3-venv python3-pip shellcheck unzip zip procps \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m venv /opt/venv && /opt/venv/bin/pip install --quiet jsonschema
ENV PATH=/opt/venv/bin:$PATH
DOCKERFILE
}
[ "$DOCKER" = 1 ] && { build_image || { echo "verify-umbrella: image build failed"; exit 2; }; }

# ── run ──────────────────────────────────────────────────────────────────────────────────────────────
RESULTS="$TMP/results"; SKIPS="$TMP/skips"; : > "$RESULTS"; : > "$SKIPS"
ran=0; failed=0; skipped=0; provision=0; approx=0

run_step() {  # $1 file $2 job $3 label $4 workdir $5 shell $6 env_b64 $7 script_b64 $8 advisory
  local file="$1" job="$2" label="$3" wd="$4" sh="$5" envb="$6" scriptb="$7" advisory="$8"
  local dir="$WT"; [ -n "$wd" ] && dir="$WT/$wd"
  local sf="$TMP/step.$$.$ran.sh"
  printf '%s' "$scriptb" | base64 -d > "$sf"
  local shellcmd=(bash --noprofile --norc -e)
  [ "$sh" = "bash" ] && shellcmd=(bash --noprofile --norc -e -o pipefail)
  local envfile="$TMP/env.$$.$ran"; printf '%s' "$envb" | base64 -d > "$envfile"
  # The step's own `env:` block, one NAME=VALUE per line, carried as an ARRAY. Splitting a string on
  # spaces here would corrupt any value containing one, and a corrupted environment produces a failure
  # that looks like the code's rather than the harness's.
  local -a stepenv=()
  while IFS= read -r line; do [ -n "$line" ] && stepenv+=("$line"); done < "$envfile"

  local t0 t1 out rc mark note=""
  t0=$(date +%s)
  if [ "$DOCKER" = 1 ]; then
    local -a dargs=(run --rm --platform linux/amd64
                    -v "$WT:$WT" -v "$REPO/.git:$REPO/.git" -v "$TMP:$TMP"
                    -w "$dir" -e CI=true -e GITHUB_ACTIONS=true -e "GITHUB_WORKSPACE=$WT")
    local e
    for e in ${stepenv[@]+"${stepenv[@]}"}; do dargs+=(-e "$e"); done
    out="$(docker "${dargs[@]}" "$IMAGE" "${shellcmd[@]}" "$sf" 2>&1)"; rc=$?
  else
    out="$(cd "$dir" && env PATH="$SHIMS:$PATH" CI=true GITHUB_ACTIONS=true GITHUB_WORKSPACE="$WT" \
             ${stepenv[@]+"${stepenv[@]}"} "${shellcmd[@]}" "$sf" 2>&1)"; rc=$?
  fi
  t1=$(date +%s)

  # An ubuntu job run natively on macOS is an approximation, and the ROW says so rather than the footer
  # alone — a caveat that lives only in a summary is read once and then never again. The advisory is the
  # enumerator's, derived from the job's own `runs-on:`; nothing here re-decides it.
  [ -n "$advisory" ] && { note="   ~ $advisory"; approx=$((approx + 1)); }

  if [ "$rc" -eq 0 ]; then mark="✔"; else mark="✘ FAILED"; failed=$((failed+1)); fi
  { printf "  %-15s %-18s %-54s %-9s (%ss)%s\n" "${file%.yml}" "$job" "${label:0:54}" "$mark" "$((t1-t0))" "$note"
    if [ "$rc" -ne 0 ]; then
      # THE FAILING LINE FIRST, THEN THE TAIL. A bare `tail` was the first version and it was useless
      # on exactly the run that mattered: candor.test.sh prints a per-row ledger and ends with a summary,
      # so the last 25 lines of a failing run were 25 rows reading `ok`. A failure excerpt that does not
      # contain the failure is worse than none — it invites the reader to conclude the harness is broken.
      local hits
      hits="$(printf '%s\n' "$out" | grep -nE '✘|✗|FAIL|not ok|^error|error\[|panicked|Error:' | head -12)"
      [ -n "$hits" ] && printf '%s\n' "$hits" | sed 's/^/        /'
      printf '%s\n' "$out" | tail -8 | sed 's/^/        · /'
      printf "        ── re-run: bash bin/verify-umbrella.sh %s--workflow %s\n" \
             "$( [ "$DOCKER" = 1 ] && echo '--docker ' )" "$file"
    fi
  } >> "$RESULTS"
  ran=$((ran+1))
}

echo
echo "verify-umbrella — the umbrella's OWN workflows, derived from .github/workflows/*.yml"
echo "  commit under test : $SHORT  ($(git -C "$REPO" log -1 --format=%s "$SHA" | cut -c1-60))"
echo "  tree              : a throwaway worktree — your uncommitted changes are NOT in this run"
echo "  platform          : $( [ "$DOCKER" = 1 ] && echo "docker linux/amd64 ($IMAGE)" || echo "$HOST_OS/$HOST_ARCH, native")"
echo "  selection         : $( [ "$ALL" = 1 ] && echo "--all (every push/PR workflow, path filters ignored)" || echo "what GitHub would trigger for $RANGE_DESC")"
[ "$ALL" = 0 ] && echo "  target branch     : $BRANCH$BRANCH_NOTE  — \`branches:\` filters are judged against this"
[ -n "$ONLY_WF" ] && echo "  filter            : --workflow $ONLY_WF"
echo

while IFS=$'\x1f' read -r status file wfname job runson label reason wd sh envb scriptb; do
  [ -n "$ONLY_WF" ] && [ "$file" != "$ONLY_WF" ] && continue
  case "$status" in
    PROVISION)
      # Only the provisioning of jobs actually in scope is reported. Listing cargo and the JDK because
      # a SCHEDULED corpus job names them would be a stand-in claimed for work nobody is doing.
      grep -qxF "$file|$job" "$INSCOPE" && provision=$((provision+1)) ;;
    SKIP)
      skipped=$((skipped+1))
      printf "  %-15s %-18s %-46s %s\n" "${file%.yml}" "$job" "${label:0:46}" "$reason" >> "$SKIPS" ;;
    RUN)
      if ! wf_required "$wfname"; then
        skipped=$((skipped+1))
        printf "  %-15s %-18s %-46s %s\n" "${file%.yml}" "$job" "${label:0:46}" \
          "GitHub would not trigger \`$wfname\` for this push (no changed file matches its path filter) — --all overrides" >> "$SKIPS"
        continue
      fi
      if [ "$LIST" = 1 ]; then
        printf "  %-15s %-18s %-54s WOULD RUN on %s%s\n" "${file%.yml}" "$job" "${label:0:54}" \
          "$runson" "${reason:+   ~ $reason}" >> "$RESULTS"
        ran=$((ran+1)); continue
      fi
      run_step "$file" "$job" "$label" "$wd" "$sh" "$envb" "$scriptb" "$reason" ;;
  esac
done < "$STEPS"

cat "$RESULTS"
echo
echo "  DID NOT RUN — $skipped step(s), each with its reason (this list is never empty in a healthy run):"
if [ -s "$SKIPS" ]; then sort "$SKIPS"; else echo "    (none)"; fi
echo
echo "  ENVIRONMENT the runner would have provisioned ($provision \`uses:\` steps, none of them executable here):"
if [ "$DOCKER" = 1 ]; then
  echo "    the linux/amd64 image above carries node/python+jsonschema/jq/shellcheck/git in place of them"
  echo "    it is Debian bookworm, NOT the GitHub ubuntu-24.04 runner image — the platform is reproduced, the image is not"
else
  [ -n "$PROVISIONED" ] && printf '%s\n' "$PROVISIONED" || echo "    (nothing to stand in for)"
fi
[ -n "$MISSING_TOOLS" ] && echo "    ✘ NOT AVAILABLE LOCALLY:$MISSING_TOOLS — steps needing these can only be trusted from CI or --docker"
echo
echo "  ONE DELIBERATE DIVERGENCE FROM GITHUB: a real job STOPS at its first failed step. This runs every"
echo "    step of the job anyway, because the point is N problems in one pass — so a ✘ below may be a"
echo "    CONSEQUENCE of a ✘ above it (a failed build makes the assertion on its artifact fail too)."
echo
echo "  WHAT A LOCAL RUN CANNOT ANSWER, whatever it prints:"
echo "    · the runner IMAGE — preinstalled tool versions on ubuntu-24.04 differ from anything here"
echo "    · anything needing repository secrets, an OIDC token, or \`gh\` auth as the workflow's identity"
echo "    · concurrency, caching and artifact upload (\`actions/cache\`, \`upload-artifact\`) behaviour"
echo "    · whether the workflow FILE itself is valid to GitHub — this reads it, GitHub validates it"
[ "$approx" -gt 0 ] && [ "$DOCKER" = 0 ] && \
  echo "    · $approx step(s) above ran on $HOST_OS/$HOST_ARCH for a job declaring ubuntu — re-run with --docker to remove this caveat"
echo
if [ "$LIST" = 1 ]; then
  echo "verify-umbrella: LISTED $ran runnable step(s); nothing was executed"; exit 0
fi
if [ "$failed" -eq 0 ]; then
  echo "verify-umbrella: OK — $ran step(s) ran, $failed failed, $skipped not run (see above)"
  exit 0
fi
echo "verify-umbrella: FAILED — $failed of $ran step(s); $skipped not run (see above)"
exit 1
