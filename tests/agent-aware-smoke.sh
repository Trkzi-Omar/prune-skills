#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TMP_REAL="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP_REAL"' EXIT

export HOME="$TMP_REAL/home"

make_skill() {
  local dir="$1" name="$2" desc="$3"
  mkdir -p "$dir"
  cat > "$dir/SKILL.md" <<EOF
---
name: $name
description: $desc
---
# $name
EOF
}

make_skill "$HOME/.claude/skills/claude-one" "claude-one" "Claude skill."
make_skill "$HOME/.codex/skills/codex-direct" "codex-direct" "Codex direct skill."
make_skill "$HOME/.codex/skills/bundle/skills/codex-nested" "codex-nested" "Codex nested bundle skill."
make_skill "$HOME/.agents/skills/agent-one" "agent-one" "Agent skill."
make_skill "$HOME/.codex/plugins/cache/vendor/example/skills/codex-plugin" "codex-plugin" "Codex plugin skill."
make_skill "$HOME/.codex/skills/folder-mismatch" "frontmatter-name" "Folder mismatch note."

mkdir -p "$HOME/.codex/sessions/2026/06/06" "$HOME/.claude/projects/example"
printf '%s\n' "Using \`codex-nested\` skill for this workflow." > "$HOME/.codex/sessions/2026/06/06/session.jsonl"
printf '%s\n' "Using \`claude-one\` skill for this workflow." > "$HOME/.claude/projects/example/session.jsonl"
empty_logs="$TMP_REAL/empty-logs"
mkdir -p "$empty_logs"
printf '%s\n' "This transcript has no explicit skill marker." > "$empty_logs/session.jsonl"

audit_out="$TMP_REAL/audit.out"
usage_out="$TMP_REAL/usage.out"

"$ROOT/scripts/audit.sh" --all-agents --limit 6 > "$audit_out"
grep -F "Skills found: 6" "$audit_out" >/dev/null
grep -F "Snapshot" "$audit_out" >/dev/null
grep -F "Load profile" "$audit_out" >/dev/null
grep -F "Next actions" "$audit_out" >/dev/null
grep -F "Top cleanup candidates" "$audit_out" >/dev/null
grep -F "Metadata notes" "$audit_out" >/dev/null
grep -F "Health issues" "$audit_out" >/dev/null
grep -F "None." "$audit_out" >/dev/null
grep -F "claude-one" "$audit_out" >/dev/null
grep -F "codex-direct" "$audit_out" >/dev/null
grep -F "codex-nested" "$audit_out" >/dev/null
grep -F "agent-one" "$audit_out" >/dev/null
grep -F "codex-plugin" "$audit_out" >/dev/null
grep -F "frontmatter-name" "$audit_out" >/dev/null
! grep -F "Oldest modified dates" "$audit_out" >/dev/null
! grep -F "Full descriptions" "$audit_out" >/dev/null

"$ROOT/scripts/audit.sh" --all-agents --age-table > "$audit_out"
grep -F "Oldest modified dates" "$audit_out" >/dev/null

"$ROOT/scripts/audit.sh" --all-agents --full-descriptions > "$audit_out"
grep -F "Full descriptions" "$audit_out" >/dev/null

"$ROOT/scripts/usage.sh" --all-agents --days 7 > "$usage_out"
grep -F "logs    :" "$usage_out" >/dev/null
grep -F "ACTIVE - used within the last 7 day(s), keep:" "$usage_out" >/dev/null
grep -F "claude-one" "$usage_out" >/dev/null
grep -F "codex-nested" "$usage_out" >/dev/null
grep -F "codex-direct" "$usage_out" >/dev/null

"$ROOT/scripts/usage.sh" --all-agents --days 7 --logs "$empty_logs" > "$usage_out"
grep -F "No explicit skill-use markers matched" "$usage_out" >/dev/null
grep -F "Usage cannot be ranked from these logs." "$usage_out" >/dev/null

echo "agent-aware smoke tests passed"
