#!/usr/bin/env bash
#
# audit.sh - Read-only inventory of agent skills across known roots.
#
# This script NEVER mutates anything. It only reads. It produces two outputs:
#   1. A table (one row per skill) sorted stalest-first, with modified date,
#      scope, plugin flag, SKILL.md line count, folder size, name, and a
#      truncated description.
#   2. A duplicate-name report, since name collisions across roots are the
#      main cause of Claude silently routing to the wrong skill.
#   3. A full-descriptions block, so the triage layer can read complete
#      descriptions to spot trigger-space overlap between differently-named
#      skills (the table truncates them for human scanning).
#
# Usage:
#   audit.sh [--agent NAME] [--all-agents]
#            [--personal DIR] [--project DIR] [--plugins DIR] [--add-dir DIR]...
#
# Defaults to --all-agents when no roots or agents are specified.
#
# Agent presets:
#   --agent claude-code  ~/.claude/skills, ./.claude/skills, ~/.claude/plugins
#   --agent codex        ~/.codex/skills, ./.codex/skills, ~/.codex/plugins/cache
#   --agent agents       ~/.agents/skills, ./.agents/skills
#
# Pass --add-dir one or more times for extra roots supplied via Claude Code's
# --add-dir flag. Each --add-dir is treated as a skills root whose immediate
# children are skill folders.

set -uo pipefail

PERSONAL_ROOT="${HOME}/.claude/skills"
PROJECT_ROOT="./.claude/skills"
PLUGINS_ROOT="${HOME}/.claude/plugins"
ADD_DIRS=()
AGENTS=()
ALL_AGENTS=0
LEGACY_ROOTS_SET=0
TSV=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --personal) PERSONAL_ROOT="$2"; LEGACY_ROOTS_SET=1; shift 2 ;;
    --project)  PROJECT_ROOT="$2";  LEGACY_ROOTS_SET=1; shift 2 ;;
    --plugins)  PLUGINS_ROOT="$2";  LEGACY_ROOTS_SET=1; shift 2 ;;
    --add-dir)  ADD_DIRS+=("$2");   shift 2 ;;
    --agent)    AGENTS+=("$2");     shift 2 ;;
    --all-agents) ALL_AGENTS=1; shift ;;
    --tsv)      TSV=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Portable mtime: try GNU stat, fall back to BSD/macOS stat.
mtime_epoch() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

fmt_date() {
  # epoch -> YYYY-MM-DD, portable across GNU and BSD date.
  date -d "@$1" '+%Y-%m-%d' 2>/dev/null || date -r "$1" '+%Y-%m-%d' 2>/dev/null || echo "????-??-??"
}

# Pull a top-level frontmatter value for KEY from a SKILL.md, reading only the
# block between the first two '---' fences. Handles three real-world cases:
#   1. inline scalar         description: Foo bar
#   2. quoted inline scalar  description: "Foo bar"
#   3. YAML block scalars    description: >   (or |, >-, |-, etc.)
#                              folded across following indented lines
# CRLF line endings are tolerated. Folded/literal blocks collapse to one line
# (newlines become spaces) so the value is safe for a single table cell.
# Returns empty string if the key is absent.
frontmatter_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN { fences=0; infm=0; capturing=0; out="" }
    {
      line=$0; sub(/\r$/,"",line)            # tolerate CRLF
    }
    line ~ /^---[[:space:]]*$/ {
      fences++
      if (fences==1){ infm=1; next }
      if (fences==2){ if(capturing){ print trim(out) } exit }
    }
    infm==1 {
      if (capturing==1) {
        # A new top-level key (no leading indent) ends the block scalar.
        if (line ~ /^[A-Za-z0-9_-]+[[:space:]]*:/) { print trim(out); exit }
        out = (out=="" ? trim(line) : out " " trim(line))
        next
      }
      if (line ~ "^"key"[[:space:]]*:") {
        rest=line
        sub("^"key"[[:space:]]*:[[:space:]]*","",rest)
        rest=trim(rest)
        # Block scalar indicator (>, |, with optional chomp/indent suffix)?
        if (rest=="" || rest ~ /^[|>][+-]?[0-9]*$/) { capturing=1; out=""; next }
        gsub(/^"|"$/, "", rest)                # strip surrounding quotes
        gsub(/^'"'"'|'"'"'$/, "", rest)
        print rest; exit
      }
    }
  ' "$file"
}

truncate_str() {
  local s="$1" max="$2"
  if (( ${#s} > max )); then
    printf '%s...' "${s:0:max-3}"
  else
    printf '%s' "$s"
  fi
}

# Collect one record per skill into a temp file, tab-separated:
#   epoch date scope plugin lines size name dir description health
RECORDS="$(mktemp)"
HEALTH="$(mktemp)"
SEEN="$(mktemp)"
trap 'rm -f "$RECORDS" "$HEALTH" "$SEEN"' EXIT

# scan_root SCOPE_LABEL PLUGIN_FLAG ROOT
# Treats each child dir of ROOT that contains SKILL.md as one skill. The default
# is immediate children. Pass "recursive" for bundle-style roots such as
# ~/.codex/skills, where packages may contain skills/<skill>/SKILL.md.
scan_root() {
  local scope="$1" plugin="$2" root="$3" mode="${4:-immediate}"
  [[ -d "$root" ]] || return 0
  local skill_md dir base fm_name name desc lines size epoch d health
  local find_args=(-mindepth 2 -maxdepth 2 -name SKILL.md)
  [[ "$mode" == "recursive" ]] && find_args=(-mindepth 2 -name SKILL.md)
  while IFS= read -r skill_md; do
    [[ -n "$skill_md" ]] || continue
    dir="$(dirname "$skill_md")"
    dir="$(cd "$dir" 2>/dev/null && pwd -P)"
    [[ -n "$dir" ]] || continue
    grep -Fxq "$dir" "$SEEN" && continue
    printf '%s\n' "$dir" >> "$SEEN"
    base="$(basename "$dir")"
    fm_name="$(frontmatter_value "$skill_md" name)"
    name="${fm_name:-$base}"
    desc="$(frontmatter_value "$skill_md" description)"
    lines="$(wc -l < "$skill_md" 2>/dev/null | tr -d ' ')"
    size="$(du -sh "$dir" 2>/dev/null | cut -f1)"
    epoch="$(mtime_epoch "$skill_md")"
    d="$(fmt_date "$epoch")"

    # Deterministic health checks (the script can do these; triage need not).
    health=""
    head -1 "$skill_md" | grep -q '^---' || health="${health}no-frontmatter;"
    [[ -z "$desc" ]] && health="${health}no-description;"
    [[ -n "$fm_name" && "$fm_name" != "$base" ]] && health="${health}name!=folder($fm_name);"
    [[ -n "$health" ]] && printf '%s\t%s\t%s\n' "$name" "${health%;}" "$dir" >> "$HEALTH"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$d" "$scope" "$plugin" "${lines:-0}" "${size:-?}" "$name" "$dir" "$desc" >> "$RECORDS"
  done < <(find "$root" "${find_args[@]}" 2>/dev/null)

  # Misnamed primary file: a child dir with a .md but no SKILL.md. Such a
  # "skill" never loads, so it would be invisible to the SKILL.md scan above.
  local child
  while IFS= read -r child; do
    [[ -n "$child" ]] || continue
    if [[ ! -f "$child/SKILL.md" ]] && compgen -G "$child/*.md" >/dev/null 2>&1; then
      printf '%s\t%s\t%s\n' "$(basename "$child")" "no-SKILL.md(has other .md)" "$child" >> "$HEALTH"
    fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
}

# Plugins: each plugin may bundle skills under <plugin>/skills/<skill>/SKILL.md.
# Plugin roots are deeply nested and the depth varies by install layout:
#   <plugins>/<plugin>/skills                                  (flat/legacy)
#   <plugins>/marketplaces/<mp>/external_plugins/<p>/skills     (marketplace)
#   <plugins>/cache/<mp>/<p>/<version>/.claude/skills           (versioned cache)
# So search for any 'skills' dir below the root rather than capping the depth.
scan_plugins_root() {
  local scope="$1" root="$2"
  [[ -d "$root" ]] || return 0
  while IFS= read -r skills_dir; do
    [[ -n "$skills_dir" ]] && scan_root "$scope" "yes" "$skills_dir"
  done < <(find "$root" -mindepth 2 -type d -name skills 2>/dev/null)
}

scan_agent() {
  local agent="$1"
  case "$agent" in
    claude-code|claude)
      scan_root "claude-personal" "no" "${HOME}/.claude/skills" "recursive"
      scan_root "claude-project" "no" "./.claude/skills" "recursive"
      scan_plugins_root "claude-plugin" "${HOME}/.claude/plugins"
      ;;
    codex)
      scan_root "codex-personal" "no" "${HOME}/.codex/skills" "recursive"
      scan_root "codex-project" "no" "./.codex/skills" "recursive"
      scan_plugins_root "codex-plugin" "${HOME}/.codex/plugins/cache"
      ;;
    agents|agent)
      scan_root "agents-personal" "no" "${HOME}/.agents/skills" "recursive"
      scan_root "agents-project" "no" "./.agents/skills" "recursive"
      ;;
    *)
      echo "Unknown agent preset: $agent" >&2
      exit 2
      ;;
  esac
}

if [[ "$LEGACY_ROOTS_SET" -eq 0 && "$ALL_AGENTS" -eq 0 && "${#AGENTS[@]}" -eq 0 && "${#ADD_DIRS[@]}" -eq 0 ]]; then
  ALL_AGENTS=1
fi

if [[ "$ALL_AGENTS" -eq 1 ]]; then
  scan_agent "claude-code"
  scan_agent "codex"
  scan_agent "agents"
fi

for agent in "${AGENTS[@]:-}"; do
  [[ -n "$agent" ]] && scan_agent "$agent"
done

if [[ "$LEGACY_ROOTS_SET" -eq 1 ]]; then
  scan_root "personal" "no" "$PERSONAL_ROOT" "recursive"
  scan_root "project"  "no" "$PROJECT_ROOT" "recursive"
  scan_plugins_root "plugin" "$PLUGINS_ROOT"
fi

for d in "${ADD_DIRS[@]:-}"; do
  [[ -n "$d" ]] && scan_root "added" "no" "$d" "recursive"
done

TOTAL="$(wc -l < "$RECORDS" | tr -d ' ')"

# Machine-readable mode: dump records (stalest-first) and exit. Consumed by
# usage.sh so skill enumeration has a single source of truth.
# Fields: epoch date scope plugin lines size name dir description
if [[ "$TSV" -eq 1 ]]; then
  sort -t$'\t' -k1,1n "$RECORDS"
  exit 0
fi

echo "============================================================================"
echo " AGENT SKILL INVENTORY"
echo " Roots scanned:"
if [[ "$ALL_AGENTS" -eq 1 ]]; then echo "   agents   : claude-code, codex, agents"; fi
for agent in "${AGENTS[@]:-}"; do [[ -n "$agent" ]] && echo "   agent    : $agent"; done
if [[ "$LEGACY_ROOTS_SET" -eq 1 ]]; then
  echo "   personal : $PERSONAL_ROOT"
  echo "   project  : $PROJECT_ROOT"
  echo "   plugins  : $PLUGINS_ROOT"
fi
for d in "${ADD_DIRS[@]:-}"; do [[ -n "$d" ]] && echo "   added    : $d"; done
echo " Skills found: ${TOTAL:-0}"
echo "============================================================================"
echo

if [[ "${TOTAL:-0}" -eq 0 ]]; then
  echo "No skills found in any root. Nothing to audit."
  exit 0
fi

# ---- Table: stalest first (ascending epoch) -------------------------------
printf '%-12s %-9s %-7s %6s %7s  %-28s %s\n' \
  "MODIFIED" "SCOPE" "PLUGIN" "LINES" "SIZE" "NAME" "DESCRIPTION"
printf '%-12s %-9s %-7s %6s %7s  %-28s %s\n' \
  "------------" "---------" "-------" "------" "-------" "----------------------------" "-----------"

sort -t$'\t' -k1,1n "$RECORDS" | while IFS=$'	' read -r epoch d scope plugin lines size name dir desc; do
  printf '%-12s %-9s %-7s %6s %7s  %-28s %s\n' \
    "$d" "$scope" "$plugin" "$lines" "$size" \
    "$(truncate_str "$name" 28)" "$(truncate_str "$desc" 70)"
done

echo
echo "Sorted stalest-first. The skills at the top are the oldest and the first"
echo "triage candidates. LINES is SKILL.md body size (startup-context cost)."

# ---- Duplicate-name report -------------------------------------------------
echo
echo "----------------------------------------------------------------------------"
echo " DUPLICATE NAMES ACROSS ROOTS"
echo "----------------------------------------------------------------------------"
DUPES="$(cut -f7 "$RECORDS" | sort | uniq -d)"
if [[ -z "$DUPES" ]]; then
  echo "None. No name collisions detected."
else
  echo "These names appear in more than one place. Your agent may route to the wrong"
  echo "one. Pick a single owner per name during triage:"
  echo
  while IFS= read -r dn; do
    [[ -n "$dn" ]] || continue
    echo "  * $dn"
    awk -F'\t' -v n="$dn" '$7==n { printf "      [%s] %s (%s, %s lines)\n", $3, $2, $6, $5 }' "$RECORDS"
  done <<< "$DUPES"
fi

# ---- Health problems -------------------------------------------------------
echo
echo "----------------------------------------------------------------------------"
echo " HEALTH PROBLEMS"
echo "----------------------------------------------------------------------------"
if [[ -s "$HEALTH" ]]; then
  echo "Fix or quarantine these regardless of usage. A broken skill either fails"
  echo "to load or misroutes:"
  echo
  sort -u "$HEALTH" | while IFS=$'\t' read -r hn hissue hdir; do
    printf '  %-26s %s\n' "$hn" "$hissue"
    printf '      %s\n' "$hdir"
  done
else
  echo "None. Frontmatter, names, and filenames look well-formed."
fi

# ---- Full descriptions (for overlap triage) --------------------------------
echo
echo "----------------------------------------------------------------------------"
echo " FULL DESCRIPTIONS (read these to find trigger-space overlap)"
echo "----------------------------------------------------------------------------"
sort -t$'\t' -k7,7 "$RECORDS" | while IFS=$'	' read -r epoch d scope plugin lines size name dir desc; do
  echo "[$scope] $name"
  echo "    ${desc:-(no description)}"
done

echo
echo "Audit complete. This was read-only. No files were changed."
