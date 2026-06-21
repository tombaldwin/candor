#!/usr/bin/env bash
# candor — Claude Code STOP hook. Runs candor-review at the end of the agent's turn; if an edit breached the
# architecture (a CANDOR_POLICY violation) or introduced a new effect vs the baseline, it BLOCKS the stop
# once and hands the verdict back so the agent can fix it before yielding to you (or refresh the baseline if
# intended). This is the "edit-time blast-radius feedback" loop: the delta reaches the agent automatically.
#
# Wire it (~/.claude/settings.json or .claude/settings.json), with your project's env:
#   {
#     "hooks": { "Stop": [ { "hooks": [ {
#       "type": "command",
#       "command": "CANDOR_CLASSES=target/classes CANDOR_POLICY=arch.policy /abs/path/to/stop-hook.sh"
#     } ] } ] }
#   }
# (CANDOR_CLASSES must be ALREADY BUILT — add your build to the command, e.g. `mvn -q compile && ...`, or
#  point at a watch-built output. See README.md.)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
input=$(cat 2>/dev/null || true)

# Re-invoked after a previous block → allow the stop, never loop (Claude Code sets stop_hook_active).
active=false
if command -v jq >/dev/null 2>&1; then active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false); fi
[ "$active" = "true" ] && { echo '{}'; exit 0; }

review=$("$HERE/candor-review.sh" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then
  echo '{}'                                   # clean — let the turn end
else
  # rc 1 (violation / new effect) or 2 (setup) → surface it to the agent, blocking the stop once.
  if command -v jq >/dev/null 2>&1; then
    reason=$(printf '%s' "$review" | jq -Rs .)
  else
    reason="\"$(printf '%s' "$review" | tr '\n' ' ' | sed 's/"/\\"/g')\""
  fi
  printf '{"decision":"block","reason":%s}\n' "$reason"
fi
exit 0
