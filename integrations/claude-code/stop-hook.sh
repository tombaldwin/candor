#!/usr/bin/env bash
# candor — Claude Code STOP hook. Runs candor-review at the end of the agent's turn.
#
#  • A policy violation / new effect (review rc=1) → BLOCKS the stop once and hands the verdict back to the
#    agent so it fixes it before yielding to you (the "edit-time blast-radius feedback" loop), and shows the
#    user a one-line ⚠ notice.
#  • A clean turn (rc=0) → ALLOWS, and (unless quiet) shows the user a one-line ✓ notice so candor's work is
#    VISIBLE even when nothing's wrong. (Without this the clean path was silent — you couldn't tell it ran.)
#  • A setup error the agent can't fix (rc=2) → ALLOWS (don't block every turn on a misconfig) and surfaces a
#    one-line notice to the user. (Hook stderr is NOT shown on a clean exit, so the notice goes via JSON.)
#
# User-facing notices use the Stop hook's `systemMessage` field (shown to the human, not fed to the model).
# Verbosity — CANDOR_HOOK_NOTICE:
#   summary  (default) one line every turn  ·  changes  only on a block/new effect  ·  quiet  only on a block
#   off      nothing
#
# Wire it (~/.claude/settings.json or .claude/settings.json), with your project's env.
#   JVM (build first — candor-java reads BYTECODE):
#     "command": "CANDOR_CLASSES=target/classes CANDOR_POLICY=arch.policy /abs/path/to/stop-hook.sh"
#   SCAN-SOURCE engines (ts/swift/rust — NO build step) — point CANDOR_REVIEW at the source variant:
#     "command": "CANDOR_REVIEW=/abs/.../candor-review-source.sh CANDOR_SCAN='npx -y candor-ts' CANDOR_SRC=src CANDOR_POLICY=arch.policy /abs/.../stop-hook.sh"
# (JVM: CANDOR_CLASSES must be ALREADY BUILT — add your build to the command, e.g. `mvn -q compile && ...`.
#  Scan-source: nothing to build; see README.md for the per-engine CANDOR_SCAN wiring.)
#
# CANDOR_REVIEW selects the review script — defaults to candor-review.sh (JVM/bytecode); set it to
# candor-review-source.sh for the scan-source engines. Both share the exit contract (0 clean / 1 block / 2 setup).
#
# STDIN IS READ ONCE, FIRST, AND IT IS CONSUMABLE. Claude Code delivers `session_id` / `transcript_path`
# on stdin, and stdin is a stream: whoever reads it first gets it. This script therefore reads it into
# `$input` before doing anything else, and every later reader uses that variable.
#
# THAT IS NOT ENOUGH IF YOU WRAP THIS SCRIPT. A wrapper that runs ANYTHING which reads stdin before
# calling the hook — `./gradlew`, `mvn`, `npm`, anything interactive-capable — will have drained it, and
# the hook then sees an empty document: no session id, no transcript, so the activity log silently loses
# the turn's edited files. Reported from the field with a `./gradlew` call doing exactly that. Redirect
# stdin away from anything you run first (`./gradlew … </dev/null`), or capture stdin in the wrapper and
# pipe it in yourself.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat 2>/dev/null || true)   # FIRST — see the stdin note above
have_jq() { command -v jq >/dev/null 2>&1; }
# the shared activity-log writer (one record shape for the hook AND the standalone/CI review path)
[ -f "$HERE/lib-candor-summary.sh" ] && . "$HERE/lib-candor-summary.sh"

# Re-invoked after a previous block → allow the stop, never loop (Claude Code sets stop_hook_active).
active=false
if have_jq; then active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false); fi
[ "$active" = "true" ] && { echo '{}'; exit 0; }

notice=${CANDOR_HOOK_NOTICE:-summary}   # summary | changes | quiet | off

# emit {"systemMessage": <msg>} (or {} when empty); jq-encodes for valid JSON, with a safe jq-less fallback.
emit_notice() {
  local m=$1
  if [ -z "$m" ]; then echo '{}'; return; fi
  if have_jq; then printf '{"systemMessage":%s}\n' "$(printf '%s' "$m" | jq -Rs .)"
  else printf '{"systemMessage":"candor checked this turn."}\n'; fi
}

# Log one activity record (P2; powers `candor-agents stats`/`digest`). The RECORD WRITER lives in
# lib-candor-summary.sh (shared with the standalone/CI review path so the shape can't drift); the hook's
# only job is to derive the two hook-specific inputs — the session id and the turn's edited files — and
# hand them to it. The turn's edited files: the Stop hook stdin does NOT carry tool_calls (only Pre/Post
# ToolUse do), so read the transcript for Edit/Write/MultiEdit/NotebookEdit file_paths since the last
# human message. null = couldn't determine (no transcript / parse failed); [] = genuinely no edits.
log_activity() {
  local rc=$1 review=$2
  command -v candor_log_activity >/dev/null 2>&1 || return 0   # lib absent → skip (stats-only)
  have_jq || return
  local sid edited tx
  sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  tx=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
  edited=
  if [ -n "$tx" ] && [ -f "$tx" ]; then
    # BOUNDED, because this is O(session) otherwise. `jq -s` slurps the WHOLE transcript to find the last
    # human message; at 11MB / 5,169 lines that measured 0.10s, and it grows all day — the hook runs every
    # turn, so the cost compounds with session length rather than with the work done. Only the tail can
    # contain the current turn, so the window is read first and the full file is a FALLBACK.
    #
    # ONE QUERY, defined once: the window pass and the fallback pass must not be able to drift apart.
    # `found` reports whether the window actually contained the turn boundary — if it did not, the answer
    # over the window would be a GUESS about which edits belong to this turn, so the full file is read.
    local q win doc
    q='(map(.type=="user" and ((.message.content|type)=="string"))|rindex(true)) as $h
       | { found: ($h != null),
           files: ((if $h==null then . else .[$h+1:] end)
             | [ .[] | select(.type=="assistant") | .message.content[]?
                 | select(.type=="tool_use" and ((.name//"")|test("^(Edit|MultiEdit|Write|NotebookEdit)$")))
                 | (.input.file_path // .input.notebook_path) ] | map(select(.!=null)) | unique) }'
    win=${CANDOR_HOOK_TRANSCRIPT_TAIL:-2000}
    doc=$(tail -n "$win" "$tx" 2>/dev/null | jq -cs "$q" 2>/dev/null)   # -s: the query maps over an ARRAY
    if [ "$(printf '%s' "$doc" | jq -r '.found // false' 2>/dev/null)" != "true" ]; then
      doc=$(jq -cs "$q" "$tx" 2>/dev/null)      # boundary older than the window — read it all
    fi
    edited=$(printf '%s' "$doc" | jq -c '.files' 2>/dev/null)
  fi
  [ -z "$edited" ] && edited=null
  candor_log_activity "$rc" "$review" "$edited" "$sid"
}

# ── SKIP THE SCAN WHEN NOTHING THE VERDICT DEPENDS ON HAS MOVED ────────────────────────────────────
# The Stop hook fires at the END OF EVERY TURN, including turns that only write a reply, and the review
# re-analyses the whole tree each time. Reported from a real project (uflexi, 2,259 classes / 15MB of
# bytecode): 3.30s of a 3.51s hook is the scan — not JVM startup (0.10s), not jq (0.10s). Over a long
# session that is the difference between a loop you keep and one you disable.
#
# WHAT THE VERDICT DEPENDS ON, and therefore what this keys on: the analysed tree, the policy, the
# baseline, the engine command, and the review script. If none of them has changed since the last run
# that PASSED, the verdict cannot have changed either. Anything else — no stamp, an unreadable stamp, a
# missing input, a changed signature — RUNS. A wrong skip is a silent miss, so every uncertainty resolves
# toward running.
#
# THE STAMP IS ONLY WRITTEN ON rc=0. A failing gate therefore keeps failing every turn until it is dealt
# with, which is the property that makes the guard safe to leave on.
#
# TWO TRAPS, both reported from the field, both avoided here:
#  · Do NOT key on `git status --porcelain`. It prints status letters and paths, never CONTENT, so
#    re-editing an already-dirty file leaves the signature identical and the gate silently never re-runs.
#    This keys on the analysed artefacts themselves, which is also more direct: candor-java reads
#    BYTECODE, so bytecode is what has to move, not source.
#  · Do NOT test staleness against the classes DIRECTORY. A directory's mtime only moves when an entry is
#    added or removed, so `find -newer <dir>` is true essentially always. The comparison here is against
#    the STAMP FILE, which is a real file touched after a passing run.
#
# Off with CANDOR_HOOK_SKIP=0.
stamp=${CANDOR_HOOK_STAMP:-.candor/hook-stamp}
skip_inputs() {   # every path whose content can change the verdict
  printf '%s\n' "${CANDOR_CLASSES:-}" "${CANDOR_SRC:-}" "${CANDOR_POLICY:-}" \
                "${CANDOR_REVIEW_BASELINE:-.candor/baseline.json}" \
                "${CANDOR_REVIEW:-$HERE/candor-review.sh}" | grep -v '^$'
}
skip_signature() {   # identity, not mtime: an engine swap or a re-pointed path must re-run
  printf 'cmd=%s scan=%s review=%s policy=%s classes=%s src=%s\n' \
    "${CANDOR_CMD:-}" "${CANDOR_SCAN:-}" "${CANDOR_REVIEW:-}" "${CANDOR_POLICY:-}" \
    "${CANDOR_CLASSES:-}" "${CANDOR_SRC:-}"
  # Size + file count of each input: catches an edit that preserved mtimes (rsync -a, a restoring build
  # cache) but changed the bytes. Cheap — no hashing of a 4.9MB baseline.
  skip_inputs | while IFS= read -r p; do
    [ -e "$p" ] || { printf '%s=absent\n' "$p"; continue; }
    printf '%s=%s/%s\n' "$p" "$(find "$p" -type f 2>/dev/null | wc -l | tr -d ' ')" \
                        "$(du -sk "$p" 2>/dev/null | awk '{print $1}')"
  done
}
should_skip() {
  [ "${CANDOR_HOOK_SKIP:-1}" = "0" ] && return 1
  [ -f "$stamp" ] || return 1
  # An input NEWER than the stamp ⇒ something moved since the last passing run.
  local p newer
  while IFS= read -r p; do
    # A MISSING input is not "changed" — a project with no baseline yet is a legitimate steady state,
    # and bailing here made the guard never skip for them. The signature records absent/present, so a
    # baseline appearing or disappearing still forces a run; only the mtime test is skipped.
    [ -e "$p" ] || continue
    newer=$(find "$p" -newer "$stamp" -type f -print 2>/dev/null | head -1)
    [ -n "$newer" ] && return 1
  done <<EOF
$(skip_inputs)
EOF
  [ "$(skip_signature)" = "$(sed -n '2,$p' "$stamp" 2>/dev/null)" ] || return 1
  return 0
}
if should_skip; then
  msg=""
  [ "$notice" = "summary" ] && msg="candor ✓ nothing the verdict depends on changed since the last clean check — skipped"
  emit_notice "$msg"
  exit 0
fi

# CANDOR_HOOK=1 tells the review script "the hook owns logging" — so it must NOT self-log (else every
# hook-driven turn would log twice: once here, once in the script). Standalone/CI callers leave it unset.
review=$(CANDOR_HOOK=1 CANDOR_EMIT_SUMMARY=1 "${CANDOR_REVIEW:-$HERE/candor-review.sh}" 2>&1); rc=$?
log_activity "$rc" "$review"   # log first — it reads the CANDOR_SUMMARY trailer for richer fields
review=$(printf '%s' "$review" | grep -v '^CANDOR_SUMMARY ' || true)   # then strip the machine line from the human text

if [ "$rc" -eq 1 ]; then
  # A policy violation / new effect → block once, hand the verdict to the agent; show the user a ⚠ line too.
  if have_jq; then
    reason=$(printf '%s' "$review" | jq -Rs .)
  else
    # No jq: hand-escaping a multi-line string risks INVALID JSON (an unescaped `\` in a path/regex would
    # make Claude Code drop the block = FAIL-OPEN). Emit a fixed, always-valid reason so the block still
    # fires (fail-closed); the agent re-runs candor-review.sh for detail.
    reason='"candor flagged this change (a policy violation or a newly-introduced effect). Run integrations/claude-code/candor-review.sh for the verdict; install jq to see it inline here."'
  fi
  if have_jq && [ "$notice" != "quiet" ] && [ "$notice" != "off" ]; then
    # a user-facing ⚠ line that NAMES the cause — not the dangling "...introduced new effects:" header.
    # Prefer a policy AS-EFF line; else the first `• fn introduces {E}` introducer; else a generic notice.
    umsg=$(printf '%s' "$review" | grep -E 'AS-EFF' | head -1 | sed 's/^ *//')
    [ -z "$umsg" ] && umsg=$(printf '%s' "$review" | grep -E 'introduces \{' | head -1 | sed 's/^ *•* *//')
    if [ -n "$umsg" ]; then umsg="candor ⚠ blocked — $umsg"; else umsg="candor ⚠ blocked this change — the agent has the verdict"; fi
    printf '{"decision":"block","reason":%s,"systemMessage":%s}\n' "$reason" "$(printf '%s' "$umsg" | jq -Rs .)"
  else
    printf '{"decision":"block","reason":%s}\n' "$reason"
  fi
  exit 0
fi

# rc 0 = clean (allow) · rc 2 = setup error the agent can't fix (allow — don't block every turn on a misconfig).
# THE STAMP IS WRITTEN HERE AND ONLY HERE: rc=0, i.e. a run that actually passed. rc=1 (a violation) and
# rc=2 (a setup error) deliberately leave the previous stamp alone, so the next turn re-runs and keeps
# reporting until the cause is dealt with. Line 1 is a human marker; the rest is the signature `should_skip`
# compares against. A write failure is not fatal — the only cost is that the next turn re-scans.
if [ "$rc" -eq 0 ] && [ "${CANDOR_HOOK_SKIP:-1}" != "0" ]; then
  mkdir -p "$(dirname "$stamp")" 2>/dev/null
  { printf 'candor stop-hook: last clean check\n'; skip_signature; } > "$stamp" 2>/dev/null || true
fi

msg=""
if [ "$rc" -eq 0 ]; then
  # Clean turn: a one-line ✓ notice in `summary` mode (the point — make candor visible when nothing's wrong).
  if [ "$notice" = "summary" ]; then
    msg=$(printf '%s' "$review" | grep -E '^candor' | tail -1)
    [ -z "$msg" ] && msg="candor ✓ checked this turn — no boundary crossed"
  fi
else
  # Setup error: surface it (stderr is invisible on exit 0), unless notices are off.
  [ "$notice" != "off" ] && msg="candor: review couldn't run (setup, rc=$rc) — check the build/config; not blocking."
fi
emit_notice "$msg"
exit 0
