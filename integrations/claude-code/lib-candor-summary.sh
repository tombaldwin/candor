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
