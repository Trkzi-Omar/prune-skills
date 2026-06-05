#!/usr/bin/env bash
#
# prune.sh - The destructive half. Snapshot, quarantine (reversible), restore,
#            and purge (irreversible) skills. Every destructive action is
#            guarded: protected paths are refused, and purge requires --yes.
#
# Disable is not delete. Quarantine moves a skill out of the load path into a
# sibling 'skills-quarantine' directory and records where it came from, so it
# stops loading next session but is trivially restorable. Purge only deletes
# what is already quarantined, and only with explicit confirmation. A snapshot
# taken first keeps even a purge recoverable.
#
# Usage:
#   prune.sh snapshot  <skills-root>
#   prune.sh quarantine <skill-dir> [<skill-dir>...]
#   prune.sh list
#   prune.sh restore   <name> [--from <quarantine-dir>]
#   prune.sh purge     [--from <quarantine-dir>] --yes
#
# Guardrails:
#   - Refuses to touch /mnt, /usr, /etc, /bin, /sbin, /lib, or anything that is
#     not under $HOME or the current working directory. This is how it avoids
#     read-only mounts and Anthropic-managed prebuilt skills.
#   - 'purge' deletes only inside a skills-quarantine directory, never a live root.

set -uo pipefail

QUARANTINE_DEFAULT="${HOME}/skills-quarantine"
MANIFEST_NAME=".pruner-manifest.tsv"

die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve to an absolute, symlink-free path (parent-resolved if leaf is missing).
abspath() {
  local p="$1"
  if [[ -d "$p" ]]; then (cd "$p" && pwd -P)
  else echo "$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)/$(basename "$p")"; fi
}

# Refuse protected locations. Returns 0 if SAFE to modify, 1 if protected.
assert_writable() {
  local abs; abs="$(abspath "$1")"
  case "$abs" in
    /mnt/*|/usr/*|/etc/*|/bin/*|/sbin/*|/lib/*|/lib64/*|/opt/*|/var/*)
      die "refusing to touch protected path: $abs" ;;
  esac
  case "$abs" in
    "$HOME"/*|"$PWD"/*) return 0 ;;
    *) die "refusing: $abs is outside \$HOME and the current directory" ;;
  esac
}

cmd_snapshot() {
  local root="${1:-}"; [[ -n "$root" ]] || die "usage: prune.sh snapshot <skills-root>"
  [[ -d "$root" ]] || die "not a directory: $root"
  local abs; abs="$(abspath "$root")"
  local out="${HOME}/skills-snapshot-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$out" -C "$(dirname "$abs")" "$(basename "$abs")" \
    || die "snapshot failed"
  echo "Snapshot written: $out"
  echo "Restore later with: tar -xzf '$out' -C '$(dirname "$abs")'"
}

cmd_quarantine() {
  [[ $# -ge 1 ]] || die "usage: prune.sh quarantine <skill-dir> [...]"
  mkdir -p "$QUARANTINE_DEFAULT"
  local manifest="${QUARANTINE_DEFAULT}/${MANIFEST_NAME}"
  touch "$manifest"
  local d abs name dest
  for d in "$@"; do
    [[ -d "$d" ]] || { echo "skip (not a dir): $d"; continue; }
    [[ -f "$d/SKILL.md" || -f "$d/SKILL.md.disabled" ]] || { echo "skip (no SKILL.md): $d"; continue; }
    assert_writable "$d"
    abs="$(abspath "$d")"
    name="$(basename "$abs")"
    dest="${QUARANTINE_DEFAULT}/${name}"
    [[ -e "$dest" ]] && dest="${dest}.$(date +%s)"
    mv "$abs" "$dest" || { echo "FAILED to move: $abs"; continue; }
    printf '%s\t%s\t%s\n' "$name" "$abs" "$dest" >> "$manifest"
    echo "quarantined: $name"
    echo "   from $abs"
    echo "   to   $dest"
  done
  echo "These stop loading next session. Work normally, then 'restore' anything"
  echo "you reach for, or 'purge --yes' what you do not."
}

cmd_list() {
  local q="${1:-$QUARANTINE_DEFAULT}"
  local manifest="${q}/${MANIFEST_NAME}"
  [[ -f "$manifest" ]] || { echo "Nothing quarantined (no manifest at $manifest)."; return 0; }
  echo "Quarantined skills (in $q):"
  while IFS=$'\t' read -r name origin dest; do
    [[ -n "$name" ]] || continue
    if [[ -e "$dest" ]]; then echo "  $name   (origin: $origin)"; fi
  done < "$manifest"
}

cmd_restore() {
  local name="${1:-}"; shift || true
  [[ -n "$name" ]] || die "usage: prune.sh restore <name> [--from <quarantine-dir>]"
  local q="$QUARANTINE_DEFAULT"
  [[ "${1:-}" == "--from" ]] && { q="$2"; shift 2; }
  local manifest="${q}/${MANIFEST_NAME}"
  [[ -f "$manifest" ]] || die "no manifest at $manifest"
  local row; row="$(awk -F '\t' -v n="$name" '$1 == n { row = $0 } END { print row }' "$manifest")"
  [[ -n "$row" ]] || die "not found in manifest: $name"
  local origin dest
  origin="$(printf '%s' "$row" | cut -f2)"
  dest="$(printf '%s' "$row" | cut -f3)"
  [[ -e "$dest" ]] || die "quarantined copy missing: $dest"
  assert_writable "$origin"
  mkdir -p "$(dirname "$origin")"
  mv "$dest" "$origin" || die "restore failed"
  echo "restored: $name -> $origin"
}

cmd_purge() {
  local q="$QUARANTINE_DEFAULT" yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) q="$2"; shift 2 ;;
      --yes)  yes=1; shift ;;
      *) die "unknown purge arg: $1" ;;
    esac
  done
  local manifest="${q}/${MANIFEST_NAME}"
  [[ -f "$manifest" ]] || die "no manifest at $manifest"
  assert_writable "$q"
  # Only ever delete inside a skills-quarantine directory.
  case "$(basename "$q")" in
    skills-quarantine) : ;;
    *) die "purge only operates on a 'skills-quarantine' directory, got: $q" ;;
  esac
  local count=0 seen
  seen="$(mktemp)"
  trap 'rm -f "$seen"' RETURN
  while IFS=$'\t' read -r name origin dest; do
    [[ -n "$name" && -e "$dest" ]] || continue
    if ! grep -Fxq "$dest" "$seen"; then
      printf '%s\n' "$dest" >> "$seen"
      count=$((count+1))
    fi
  done < "$manifest"
  if (( count == 0 )); then echo "Nothing left to purge in $q."; return 0; fi
  if (( yes == 0 )); then
    echo "Would permanently delete $count quarantined skill(s) from $q."
    echo "Re-run with --yes to confirm. (Your snapshot still protects you.)"
    return 0
  fi
  while IFS=$'\t' read -r name origin dest; do
    [[ -n "$name" && -e "$dest" ]] || continue
    assert_writable "$dest"
    rm -rf "$dest" && echo "purged: $name"
  done < "$manifest"
  echo "Purge complete. Recover from your snapshot if needed."
}

sub="${1:-}"; shift || true
case "$sub" in
  snapshot)   cmd_snapshot "$@" ;;
  quarantine) cmd_quarantine "$@" ;;
  list)       cmd_list "$@" ;;
  restore)    cmd_restore "$@" ;;
  purge)      cmd_purge "$@" ;;
  -h|--help|"") grep '^#' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand: $sub (try --help)" ;;
esac
