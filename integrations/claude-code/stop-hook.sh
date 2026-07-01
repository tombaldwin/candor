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
#     "command": "CANDOR_REVIEW=/abs/.../candor-review-source.sh CANDOR_SCAN='npx -y candor-ts' CANDOR_QUERY='npx -y candor-ts-query' CANDOR_SRC=src CANDOR_POLICY=arch.policy /abs/.../stop-hook.sh"
# (JVM: CANDOR_CLASSES must be ALREADY BUILT — add your build to the command, e.g. `mvn -q compile && ...`.
#  Scan-source: nothing to build; see README.md for the per-engine CANDOR_SCAN/CANDOR_QUERY wiring.)
#
# CANDOR_REVIEW selects the review script — defaults to candor-review.sh (JVM/bytecode); set it to
# candor-review-source.sh for the scan-source engines. Both share the exit contract (0 clean / 1 block / 2 setup).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat 2>/dev/null || true)
have_jq() { command -v jq >/dev/null 2>&1; }

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

# Append one record to the activity log (P2; powers `candor stats`). Best-effort: needs jq, only writes when
# the log's dir already exists (so we never create .candor/), CANDOR_ACTIVITY_LOG=off disables. session_id +
# the turn's edited files come from the hook input; blast/gained/violations are parsed from the review's
# output (stats-only — if a field doesn't parse it logs 0/[], the notice and gate are unaffected).
log_activity() {
  local rc=$1 review=$2
  local log=${CANDOR_ACTIVITY_LOG:-.candor/activity.jsonl}
  [ "$log" = "off" ] && return
  have_jq || return
  [ -d "$(dirname "$log")" ] || return
  local verdict; case "$rc" in 0) verdict=clean;; 1) verdict=blocked;; *) verdict=setup;; esac
  local engine=java
  if [ -n "${CANDOR_SCAN:-}" ]; then engine=$(printf '%s' "$CANDOR_SCAN" | grep -oE 'candor-ts|candor-swift|candor-scan' | head -1); [ -z "$engine" ] && engine=source; fi
  local ts sid edited blast gained viol
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sid=$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || echo "")
  # The turn's edited files. The Stop hook stdin does NOT carry tool_calls (only Pre/PostToolUse do —
  # verified against the docs), so read the transcript: Edit/Write/MultiEdit/NotebookEdit file_paths since
  # the last human (string-content) message. null = couldn't determine (no transcript / parse failed); [] =
  # genuinely no edits this turn. (Never a misleading [] when we simply don't know.)
  local tx; tx=$(printf '%s' "$input" | jq -r '.transcript_path // ""' 2>/dev/null)
  edited=
  if [ -n "$tx" ] && [ -f "$tx" ]; then
    edited=$(jq -cs '(map(.type=="user" and ((.message.content|type)=="string"))|rindex(true)) as $h
      | (if $h==null then . else .[$h+1:] end)
      | [ .[] | select(.type=="assistant") | .message.content[]?
          | select(.type=="tool_use" and ((.name//"")|test("^(Edit|MultiEdit|Write|NotebookEdit)$")))
          | (.input.file_path // .input.notebook_path) ] | map(select(.!=null)) | unique' "$tx" 2>/dev/null)
  fi
  [ -z "$edited" ] && edited=null
  blast=$(printf '%s' "$review" | sed -nE 's/.*blast radius: ([0-9]+) function.*/\1/p' | head -1); [ -z "$blast" ] && blast=0
  gained=$(printf '%s' "$review" | sed -nE 's/.*introduces \{([^}]*)\}.*/\1/p' | tr ',' '\n' | sed 's/ //g' | grep -v '^$' | jq -R . | jq -sc 'unique' 2>/dev/null); [ -z "$gained" ] && gained='[]'
  viol=$(printf '%s' "$review" | grep -oE 'AS-EFF-[0-9]+' | jq -R . | jq -sc 'unique' 2>/dev/null); [ -z "$viol" ] && viol='[]'
  # richer fields from the review's CANDOR_SUMMARY trailer (P2.1): Unknown count, effects present, wall-time.
  local summ unknowns effects reviewms
  summ=$(printf '%s' "$review" | grep '^CANDOR_SUMMARY ' | tail -1 | sed 's/^CANDOR_SUMMARY //')
  unknowns=$(printf '%s' "$summ" | jq -r '.unknowns // empty' 2>/dev/null); [ -z "$unknowns" ] && unknowns=null
  effects=$(printf '%s' "$summ" | jq -c '.effects // empty' 2>/dev/null); [ -z "$effects" ] && effects='[]'
  reviewms=$(printf '%s' "$summ" | jq -r '.reviewMs // empty' 2>/dev/null); [ -z "$reviewms" ] && reviewms=null
  jq -nc --arg ts "$ts" --arg sid "$sid" --arg engine "$engine" --arg verdict "$verdict" \
     --argjson edited "$edited" --argjson gained "$gained" --argjson viol "$viol" --argjson blast "$blast" \
     --argjson unknowns "$unknowns" --argjson effects "$effects" --argjson reviewms "$reviewms" \
     '{ts:$ts, sessionId:(if $sid=="" then null else $sid end), engine:$engine, edited:$edited,
       gained:$gained, blastRadius:$blast, verdict:$verdict, violations:$viol,
       unknowns:$unknowns, effects:$effects, reviewMs:$reviewms}' >> "$log" 2>/dev/null || true
  # cap the log (keep the last N lines) so it can't grow without bound — best-effort.
  local cap=${CANDOR_ACTIVITY_CAP:-5000} n
  case "$cap" in ''|*[!0-9]*) cap=5000 ;; esac   # non-numeric cap → default, never error the -gt test
  n=$(wc -l < "$log" 2>/dev/null || echo 0)
  if [ "$n" -gt "$cap" ]; then tail -n "$cap" "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log" 2>/dev/null || true; fi
}

review=$(CANDOR_EMIT_SUMMARY=1 "${CANDOR_REVIEW:-$HERE/candor-review.sh}" 2>&1); rc=$?
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
