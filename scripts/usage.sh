#!/usr/bin/env bash
#
# usage.sh - Read-only "stale skills" report based on real usage, not file dates.
#
# Claude Code records every session as a JSONL transcript under
# ~/.claude/projects/<encoded-path>/*.jsonl. When a skill is loaded its name
# appears in that transcript. This script treats the modified time of any
# transcript that mentions a skill as that skill's "last used" signal, then
# flags skills not seen in the last N days (default 7) and skills with no log
# hits at all.
#
# This is best-effort, and honest about it: Claude Code compacts and rotates
# old transcripts, and a fresh machine has no history, so "no log hits" means
# "not seen in the logs we can read", NOT "never used". Never delete on this
# signal alone. It is a prioritization aid for triage, not proof.
#
# It NEVER mutates anything. Read-only.
#
# Usage:
#   usage.sh [--days N] [--logs DIR] [--audit PATH] [audit-root-flags...]
#
# Defaults:
#   --days 7
#   --logs  ~/.claude/projects
#   --audit <this script's dir>/audit.sh
# Any other flags (--personal/--project/--plugins/--add-dir) pass through to
# audit.sh, which enumerates the skills.

set -uo pipefail

DAYS=7
LOGS_ROOT="${HOME}/.claude/projects"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${SCRIPT_DIR}/audit.sh"
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)  DAYS="$2"; shift 2 ;;
    --logs)  LOGS_ROOT="$2"; shift 2 ;;
    --audit) AUDIT="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

mtime_epoch() { stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0; }
fmt_date()    { date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d' 2>/dev/null || echo "never"; }

NOW="$(date +%s)"
CUTOFF=$(( NOW - DAYS * 86400 ))

# Enumerate skills via audit.sh --tsv (single source of truth).
# Fields: epoch date scope plugin lines size name dir description
# Guard the array expansion: under `set -u`, "${PASSTHRU[@]:-}" on an empty
# array yields one empty-string argument, which audit.sh rejects as an unknown
# flag (exit 2) -> no skills enumerated. Only pass the flags when we have some.
if [[ ${#PASSTHRU[@]} -gt 0 ]]; then
  SKILLS="$(bash "$AUDIT" --tsv "${PASSTHRU[@]}" 2>/dev/null)"
else
  SKILLS="$(bash "$AUDIT" --tsv 2>/dev/null)"
fi
if [[ -z "$SKILLS" ]]; then
  echo "No skills found to check. (Is audit.sh reachable at: $AUDIT ?)"
  exit 0
fi

# Pre-list transcripts once.
LOG_FILES=()
if [[ -d "$LOGS_ROOT" ]]; then
  while IFS= read -r f; do [[ -n "$f" ]] && LOG_FILES+=("$f"); done \
    < <(find "$LOGS_ROOT" -type f -name '*.jsonl' 2>/dev/null)
fi

echo "============================================================================"
echo " SKILL USAGE REPORT (last-used from transcript logs)"
echo "   logs    : $LOGS_ROOT"
echo "   window  : last ${DAYS} day(s)  (cutoff $(fmt_date "$CUTOFF"))"
echo "   sessions: ${#LOG_FILES[@]} transcript file(s) scanned"
echo "============================================================================"

if [[ "${#LOG_FILES[@]}" -eq 0 ]]; then
  echo
  echo "No transcripts found under $LOGS_ROOT."
  echo "Cannot derive usage. Fall back to quarantine-and-observe (see SKILL.md)."
  exit 0
fi

# For each skill, find the newest transcript that mentions its name.
# last_seen = max mtime over matching transcripts; 0 if none.
report="$(
  while IFS=$'\t' read -r epoch d scope plugin lines size name dir desc; do
    [[ -n "$name" ]] || continue
    last=0
    # grep -lF: list files containing the fixed-string skill name.
    while IFS= read -r hit; do
      [[ -n "$hit" ]] || continue
      m="$(mtime_epoch "$hit")"
      (( m > last )) && last="$m"
    done < <(grep -lF -- "$name" "${LOG_FILES[@]}" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$last" "$name" "$scope"
  done <<< "$SKILLS"
)"

echo
echo "STALE - not seen in logs within the window (review these first):"
echo "----------------------------------------------------------------------------"
stale_n=0
while IFS=$'\t' read -r last name scope; do
  [[ -n "$name" ]] || continue
  if (( last == 0 )); then continue; fi
  if (( last < CUTOFF )); then
    printf '  %-28s last used %s  (%s)\n' "$name" "$(fmt_date "$last")" "$scope"
    stale_n=$((stale_n+1))
  fi
done < <(printf '%s\n' "$report" | sort -t$'\t' -k1,1n)
(( stale_n == 0 )) && echo "  (none)"

echo
echo "NO LOG HITS - never seen in readable transcripts (NOT proof of disuse):"
echo "----------------------------------------------------------------------------"
nohit_n=0
while IFS=$'\t' read -r last name scope; do
  [[ -n "$name" ]] || continue
  if (( last == 0 )); then
    printf '  %-28s (%s)\n' "$name" "$scope"
    nohit_n=$((nohit_n+1))
  fi
done < <(printf '%s\n' "$report")
(( nohit_n == 0 )) && echo "  (none)"

echo
echo "ACTIVE - used within the last ${DAYS} day(s), keep:"
echo "----------------------------------------------------------------------------"
active_n=0
while IFS=$'\t' read -r last name scope; do
  [[ -n "$name" ]] || continue
  if (( last >= CUTOFF )); then
    printf '  %-28s last used %s  (%s)\n' "$name" "$(fmt_date "$last")" "$scope"
    active_n=$((active_n+1))
  fi
done < <(printf '%s\n' "$report" | sort -t$'\t' -k1,1nr)
(( active_n == 0 )) && echo "  (none)"

echo
echo "Caveat: matching is by skill name appearing in a transcript, and 'last used'"
echo "is that transcript's modified time. Generic names may over-match; rotated or"
echo "compacted logs may under-match. Use as a triage signal, not a delete trigger."
echo "Read-only. No files were changed."
