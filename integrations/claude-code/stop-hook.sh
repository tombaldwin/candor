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
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat 2>/dev/null || true)
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
    edited=$(jq -cs '(map(.type=="user" and ((.message.content|type)=="string"))|rindex(true)) as $h
      | (if $h==null then . else .[$h+1:] end)
      | [ .[] | select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use" and ((.name//"")|test("^(Edit|MultiEdit|Write|NotebookEdit)$")))
          | (.input.file_path // .input.notebook_path) ] | map(select(.!=null)) | unique' "$tx" 2>/dev/null)
  fi
  [ -z "$edited" ] && edited=null
  candor_log_activity "$rc" "$review" "$edited" "$sid"
}

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
