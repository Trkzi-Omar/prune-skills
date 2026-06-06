#!/usr/bin/env bash
#
# usage.sh - Read-only "stale skills" report based on real usage, not file dates.
#
# Claude Code records sessions under ~/.claude/projects. Codex records sessions
# under ~/.codex/sessions and archived sessions under ~/.codex/archived_sessions.
# When a skill is used, assistant messages commonly include text like
# "Using `skill-name` ...". This script treats the modified time of any
# transcript that contains that marker as the skill's "last used" signal, then
# flags skills not seen in the last N days (default 7) and skills with no log
# hits at all.
#
# This is best-effort, and honest about it: Claude Code compacts and rotates
# old transcripts, Codex logs can be large, and a fresh machine has no history,
# so "no log hits" means "not seen in the logs we scanned", NOT "never used".
# Never delete on this signal alone. It is a prioritization aid for triage, not proof.
#
# It NEVER mutates anything. Read-only.
#
# Usage:
#   usage.sh [--days N] [--log-history-days N] [--logs DIR] [--audit PATH]
#            [--agent NAME] [--all-agents] [audit-root-flags...]
#
# Defaults:
#   --days 7
#   --log-history-days <days> defaults to --days; pass 0 to scan all readable logs
#   --logs  agent-aware defaults: ~/.claude/projects, ~/.codex/sessions,
#           ~/.codex/archived_sessions
#   --audit <this script's dir>/audit.sh
# Any other flags (--personal/--project/--plugins/--add-dir/--agent/
# --all-agents) pass through to audit.sh, which enumerates the skills.

set -uo pipefail

DAYS=7
LOG_HISTORY_DAYS=""
LOG_ROOTS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT="${SCRIPT_DIR}/audit.sh"
PASSTHRU=()
AGENTS=()
ALL_AGENTS=0
CUSTOM_LOGS=0

add_agent_logs() {
  local agent="$1"
  case "$agent" in
    claude-code|claude)
      LOG_ROOTS+=("${HOME}/.claude/projects")
      ;;
    codex)
      LOG_ROOTS+=("${HOME}/.codex/sessions" "${HOME}/.codex/archived_sessions")
      ;;
    agents|agent)
      ;;
    *)
      echo "Unknown agent preset: $agent" >&2
      exit 2
      ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)  DAYS="$2"; shift 2 ;;
    --log-history-days) LOG_HISTORY_DAYS="$2"; shift 2 ;;
    --logs)  LOG_ROOTS+=("$2"); CUSTOM_LOGS=1; shift 2 ;;
    --audit) AUDIT="$2"; shift 2 ;;
    --agent)
      AGENTS+=("$2")
      PASSTHRU+=("--agent" "$2")
      shift 2
      ;;
    --all-agents)
      ALL_AGENTS=1
      PASSTHRU+=("--all-agents")
      shift
      ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) PASSTHRU+=("$1"); shift ;;
  esac
done

if [[ -z "$LOG_HISTORY_DAYS" ]]; then
  LOG_HISTORY_DAYS="$DAYS"
fi

if [[ "$CUSTOM_LOGS" -eq 0 ]]; then
  if [[ "$ALL_AGENTS" -eq 1 || "${#AGENTS[@]}" -eq 0 ]]; then
    add_agent_logs "claude-code"
    add_agent_logs "codex"
  else
    for agent in "${AGENTS[@]:-}"; do
      [[ -n "$agent" ]] && add_agent_logs "$agent"
    done
  fi
fi

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
for logs_root in "${LOG_ROOTS[@]:-}"; do
  [[ -d "$logs_root" ]] || continue
  if [[ "$LOG_HISTORY_DAYS" -eq 0 ]]; then
    while IFS= read -r f; do [[ -n "$f" ]] && LOG_FILES+=("$f"); done \
      < <(find "$logs_root" -type f -name '*.jsonl' 2>/dev/null)
  else
    while IFS= read -r f; do [[ -n "$f" ]] && LOG_FILES+=("$f"); done \
      < <(find "$logs_root" -type f -name '*.jsonl' -mtime "-${LOG_HISTORY_DAYS}" 2>/dev/null)
  fi
done

echo "============================================================================"
echo " SKILL USAGE REPORT (last-used from transcript logs)"
echo "   logs    : ${LOG_ROOTS[*]:-(none)}"
echo "   history : last ${LOG_HISTORY_DAYS} day(s) of logs (0 means all)"
echo "   window  : last ${DAYS} day(s)  (cutoff $(fmt_date "$CUTOFF"))"
echo "   sessions: ${#LOG_FILES[@]} transcript file(s) scanned"
echo "============================================================================"

if [[ "${#LOG_FILES[@]}" -eq 0 ]]; then
  echo
  echo "No transcripts found under configured log roots."
  echo "Cannot derive usage. Fall back to quarantine-and-observe (see SKILL.md)."
  exit 0
fi

# For each skill, find the newest transcript that mentions its name.
# last_seen = max mtime over matching transcripts; 0 if none. Use one fixed-
# string grep over the logs; Codex installs can have hundreds of transcripts,
# so per-skill grep is too slow in practice.
NAMES_FILE="$(mktemp)"
PATTERNS_FILE="$(mktemp)"
MTIMES_FILE="$(mktemp)"
HITS_FILE="$(mktemp)"
trap 'rm -f "$NAMES_FILE" "$PATTERNS_FILE" "$MTIMES_FILE" "$HITS_FILE"' EXIT

while IFS=$'\t' read -r epoch d scope plugin lines size name dir desc; do
  [[ -n "$name" ]] || continue
  printf '%s\t%s\n' "$name" "$scope"
done <<< "$SKILLS" > "$NAMES_FILE"
while IFS=$'\t' read -r name scope; do
  [[ -n "$name" ]] && printf 'Using `%s`\n' "$name"
done < "$NAMES_FILE" > "$PATTERNS_FILE"

for f in "${LOG_FILES[@]}"; do
  printf '%s\t%s\n' "$f" "$(mtime_epoch "$f")"
done > "$MTIMES_FILE"

if command -v rg >/dev/null 2>&1; then
  rg --no-messages --with-filename --only-matching --fixed-strings \
    --file "$PATTERNS_FILE" "${LOG_FILES[@]}" > "$HITS_FILE" || true
else
  grep -FHo -f "$PATTERNS_FILE" "${LOG_FILES[@]}" 2>/dev/null > "$HITS_FILE" || true
fi

HIT_COUNT="$(wc -l < "$HITS_FILE" | tr -d '[:space:]')"
if [[ "$HIT_COUNT" -eq 0 ]]; then
  echo
  echo "No explicit skill-use markers matched in the scanned transcripts."
  echo
  echo "What this means:"
  echo "  - Usage cannot be ranked from these logs."
  echo "  - This does not mean every skill is unused."
  echo "  - Older, compacted, or differently formatted sessions may omit the marker."
  echo
  echo "Next actions:"
  echo "  1. Re-run with --log-history-days 0 to scan all readable logs."
  echo "  2. Use audit.sh for duplicate names, health issues, and large-skill triage."
  echo "  3. Quarantine and observe before deleting anything."
  echo
  echo "Read-only. No files were changed."
  exit 0
fi

report="$(
  awk -v namesfile="$NAMES_FILE" -v mtimesfile="$MTIMES_FILE" -v hitsfile="$HITS_FILE" -F '\t' '
    FILENAME == namesfile {
      names[++n] = $1
      scopes[$1] = $2
      last[$1] = 0
      next
    }
    FILENAME == mtimesfile {
      mtimes[$1] = $2 + 0
      next
    }
    FILENAME == hitsfile {
      file = $0
      sub(/:.*/, "", file)
      hit = substr($0, length(file) + 2)
      if (match(hit, /Using `[^`]+`/)) {
        name = substr(hit, RSTART + 7, RLENGTH - 8)
      } else {
        next
      }
      if ((name in last) && mtimes[file] > last[name]) {
        last[name] = mtimes[file]
      }
      next
    }
    {
    }
    END {
      for (i = 1; i <= n; i++) {
        name = names[i]
        printf "%s\t%s\t%s\n", last[name], name, scopes[name]
      }
    }
  ' "$NAMES_FILE" "$MTIMES_FILE" "$HITS_FILE"
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
echo "Caveat: matching looks for explicit 'Using \`skill-name\`' markers in scanned"
echo "transcripts, and 'last used' is that transcript's modified time. Older agents"
echo "or compacted logs may omit that marker. Use as a triage signal, not a delete"
echo "trigger."
echo "Read-only. No files were changed."
