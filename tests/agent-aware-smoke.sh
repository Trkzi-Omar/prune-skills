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

mkdir -p "$HOME/.codex/sessions/2026/06/06" "$HOME/.claude/projects/example"
printf '%s\n' "Using \`codex-nested\` skill for this workflow." > "$HOME/.codex/sessions/2026/06/06/session.jsonl"
printf '%s\n' "Using \`claude-one\` skill for this workflow." > "$HOME/.claude/projects/example/session.jsonl"

audit_out="$TMP_REAL/audit.out"
usage_out="$TMP_REAL/usage.out"

"$ROOT/scripts/audit.sh" --all-agents > "$audit_out"
grep -F "Skills found: 5" "$audit_out" >/dev/null
grep -F "claude-one" "$audit_out" >/dev/null
grep -F "codex-direct" "$audit_out" >/dev/null
grep -F "codex-nested" "$audit_out" >/dev/null
grep -F "agent-one" "$audit_out" >/dev/null
grep -F "codex-plugin" "$audit_out" >/dev/null

"$ROOT/scripts/usage.sh" --all-agents --days 7 > "$usage_out"
grep -F "logs    :" "$usage_out" >/dev/null
grep -F "ACTIVE - used within the last 7 day(s), keep:" "$usage_out" >/dev/null
grep -F "claude-one" "$usage_out" >/dev/null
grep -F "codex-nested" "$usage_out" >/dev/null
grep -F "codex-direct" "$usage_out" >/dev/null

echo "agent-aware smoke tests passed"
