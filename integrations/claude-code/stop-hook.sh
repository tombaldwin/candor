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
if [ "$rc" -eq 1 ]; then
  # A policy violation / new effect → block once, hand the verdict to the agent.
  if command -v jq >/dev/null 2>&1; then
    reason=$(printf '%s' "$review" | jq -Rs .)
  else
    # No jq: hand-escaping a multi-line string risks INVALID JSON (an unescaped `\` in a path/regex would
    # make Claude Code drop the block = FAIL-OPEN). Emit a fixed, always-valid reason so the block still
    # fires (fail-closed); the agent re-runs candor-review.sh for detail.
    reason='"candor flagged this change (a policy violation or a newly-introduced effect). Run integrations/claude-code/candor-review.sh for the verdict; install jq to see it inline here."'
  fi
  printf '{"decision":"block","reason":%s}\n' "$reason"
else
  # rc 0 = clean → allow. rc 2 = a setup/build error the AGENT can't fix → ALLOW (don't block every turn on
  # a misconfiguration); surface it to the human on stderr instead.
  [ "$rc" -ne 0 ] && printf 'candor stop-hook: review could not run (rc=%s), not blocking:\n%s\n' "$rc" "$review" >&2
  echo '{}'
fi
exit 0
