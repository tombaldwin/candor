# lib-candor-summary.sh — emit the CANDOR_SUMMARY trailer the stop hook reads. Sourced by the review
# scripts (candor-review.sh / candor-review-source.sh) so this lives in ONE place, not copy-pasted.
#
# candor_emit_summary <report-json>: prints one line IFF CANDOR_EMIT_SUMMARY=1, jq is present, and the
# report exists. Fields: the report's Unknown count, the distinct effects present, and this review's
# wall-time (whole seconds via SECONDS — ms-named but second-granular; 0 for a sub-second review).
# Hardened: jq output is `head -1`'d and validated (numeric / bracketed array) so a multi-line or partial
# jq result can never emit a broken multi-line trailer.
candor_emit_summary() {
  [ "${CANDOR_EMIT_SUMMARY:-}" = "1" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local cur=$1 unk eff
  [ -s "$cur" ] || return 0
  unk=$(jq '[.functions[]?|select(((.inferred//[])|index("Unknown")))]|length' "$cur" 2>/dev/null | head -1)
  case "$unk" in ''|*[!0-9]*) unk=0 ;; esac
  eff=$(jq -c '[.functions[]?.inferred[]?]|unique|map(select(.!="Unknown"))' "$cur" 2>/dev/null | head -1)
  case "$eff" in \[*\]) : ;; *) eff='[]' ;; esac
  printf 'CANDOR_SUMMARY {"unknowns":%s,"effects":%s,"reviewMs":%s}\n' "$unk" "$eff" "$((SECONDS * 1000))"
}

# candor_log_activity <rc> <review-text> [<edited-json>] [<sessionId>]
# Append ONE activity record — the shared writer for both the Stop hook and the standalone/CI review
# scripts, so the record shape (which `candor-agents stats`/`digest` parse) lives in one place and can't
# drift. `edited`/`sessionId` are the ONLY hook-specific inputs (the hook derives them from its stdin +
# the transcript); a standalone/CI run has no transcript, so it passes `null`/`""` — the record is
# path-free by construction (aggregate-safe, committable). Best-effort: needs jq, writes only when the
# log's directory already exists (never creates .candor/), CANDOR_ACTIVITY_LOG=off disables. blast /
# gained / violations / the CANDOR_SUMMARY trailer are parsed from the review text (stats-only — a field
# that doesn't parse logs 0/[]/null; the gate and notice are never affected).
candor_log_activity() {
  local rc=$1 review=$2 edited=${3:-null} sid=${4:-}
  local log=${CANDOR_ACTIVITY_LOG:-.candor/activity.jsonl}
  [ "$log" = "off" ] && return 0
  command -v jq >/dev/null 2>&1 || return 0
  [ -d "$(dirname "$log")" ] || return 0
  local verdict; case "$rc" in 0) verdict=clean;; 1) verdict=blocked;; *) verdict=setup;; esac
  local engine=java
  if [ -n "${CANDOR_SCAN:-}" ]; then engine=$(printf '%s' "$CANDOR_SCAN" | grep -oE 'candor-ts|candor-swift|candor-scan' | head -1); [ -z "$engine" ] && engine=source; fi
  local ts blast gained viol
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  blast=$(printf '%s' "$review" | sed -nE 's/.*blast radius: ([0-9]+) function.*/\1/p' | head -1); [ -z "$blast" ] && blast=0
  gained=$(printf '%s' "$review" | sed -nE 's/.*introduces \{([^}]*)\}.*/\1/p' | tr ',' '\n' | sed 's/ //g' | grep -v '^$' | jq -R . | jq -sc 'unique' 2>/dev/null); [ -z "$gained" ] && gained='[]'
  viol=$(printf '%s' "$review" | grep -oE 'AS-EFF-[0-9]+' | jq -R . | jq -sc 'unique' 2>/dev/null); [ -z "$viol" ] && viol='[]'
  local summ unknowns effects reviewms
  summ=$(printf '%s' "$review" | grep '^CANDOR_SUMMARY ' | tail -1 | sed 's/^CANDOR_SUMMARY //')
  unknowns=$(printf '%s' "$summ" | jq -r '.unknowns // empty' 2>/dev/null); [ -z "$unknowns" ] && unknowns=null
  effects=$(printf '%s' "$summ" | jq -c '.effects // empty' 2>/dev/null); [ -z "$effects" ] && effects='[]'
  reviewms=$(printf '%s' "$summ" | jq -r '.reviewMs // empty' 2>/dev/null); [ -z "$reviewms" ] && reviewms=null
  case "$edited" in ''|null) edited=null ;; esac
  jq -nc --arg ts "$ts" --arg sid "$sid" --arg engine "$engine" --arg verdict "$verdict" \
     --argjson edited "$edited" --argjson gained "$gained" --argjson viol "$viol" --argjson blast "$blast" \
     --argjson unknowns "$unknowns" --argjson effects "$effects" --argjson reviewms "$reviewms" \
     '{ts:$ts, sessionId:(if $sid=="" then null else $sid end), engine:$engine, edited:$edited,
       gained:$gained, blastRadius:$blast, verdict:$verdict, violations:$viol,
       unknowns:$unknowns, effects:$effects, reviewMs:$reviewms}' >> "$log" 2>/dev/null || true
  local cap=${CANDOR_ACTIVITY_CAP:-5000} n
  case "$cap" in ''|*[!0-9]*) cap=5000 ;; esac
  n=$(wc -l < "$log" 2>/dev/null || echo 0)
  if [ "$n" -gt "$cap" ]; then tail -n "$cap" "$log" > "$log.tmp" 2>/dev/null && mv "$log.tmp" "$log" 2>/dev/null || true; fi
}
