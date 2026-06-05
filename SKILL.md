---
name: skill-library-pruner
description: Read-first, reversible workflow for pruning an overgrown Claude Code skills library. Inventories every skill, spots duplicates and dead weight, reports what has not been used, disables safely, then deletes only what goes unmissed. Use when the user wants to prune, declutter, audit, consolidate, or shrink their skills, or says "I have too many skills", "clean up my skills", "which of my skills are redundant", "my skills directory is a mess", "audit my skills", or "which skills haven't I used lately". Trigger on library-overload and skill-review intents even when the user does not say the word "prune" or "delete".
---

# Skill Library Pruner

## Philosophy

The only failure that matters is deleting a skill the user relied on. Every step is
biased toward reversibility. Read before you write. Disable before you delete. Prefer
real usage data over guesses. The user confirms every destructive action.

This is a workflow-enforcement skill: run the procedure, do not improvise deletions.

## Tools (bundled, in `scripts/`)

- `audit.sh` - read-only. Inventory across all roots, stalest-first, plus duplicate-name
  and health reports. Spots collisions, missing descriptions, name/folder mismatches,
  and primary files not named `SKILL.md`. Never mutates.
- `usage.sh` - read-only. Last-used per skill, derived from Claude Code transcript logs
  under `~/.claude/projects`. Flags skills not seen within N days (default 7). Never mutates.
- `prune.sh` - the destructive half. `snapshot`, `quarantine`, `list`, `restore`, `purge`.
  Guarded: refuses read-only mounts and anything outside `$HOME`/cwd; `purge` needs `--yes`.

## Workflow

### 1. Locate and snapshot

- [ ] Identify roots: personal `~/.claude/skills`, project `.claude/skills`, any
      `--add-dir` roots, plugin skills under `~/.claude/plugins`.
- [ ] `bash scripts/prune.sh snapshot <root>` for each user-writable root. Report the path.
- [ ] Do not snapshot or touch read-only mounts or Anthropic-managed prebuilt skills.

Nothing destructive happens before a snapshot exists.

### 2. Inventory (read-only)

- [ ] `bash scripts/audit.sh --personal ~/.claude/skills --project ./.claude/skills --plugins ~/.claude/plugins`
- [ ] Read the duplicate-name and health sections aloud to the user. These are the first cuts.
- [ ] If the user only wanted to look, stop here. This satisfies a pure-audit request.

### 3. Usage (read-only)

- [ ] `bash scripts/usage.sh --days 7` to see what has not been invoked recently.
- [ ] Treat "no log hits" as a triage signal, never proof. Logs compact and rotate, and a
      fresh machine has no history.

### 4. Triage

Bucket each skill as **keep**, **merge**, or **quarantine** using four signals:

- [ ] **Collisions** (from audit duplicates): pick one owner per name. Resolve first.
- [ ] **Overlap**: two differently-named skills competing for the same triggers. Read the
      full-descriptions block to find these. Merge candidates.
- [ ] **Staleness**: stale in `usage.sh` plus deprecated APIs/patterns inside the SKILL.md.
- [ ] **Bloat**: high SKILL.md line count for a rarely-hit skill. It costs startup context.
- [ ] Carry every health problem from audit into a bucket too (broken skills misroute).
- [ ] Present the buckets as a proposal. Wait for confirmation. The user overrules you.

### 5. Quarantine (reversible)

- [ ] `bash scripts/prune.sh quarantine <skill-dir>...` for everything approved.
- [ ] Confirm via `audit.sh` that they no longer appear. They stop loading next session.

### 6. Observe and confirm

- [ ] If usage logs were thin, have the user work normally for about a week.
- [ ] On return, ask per skill: did you miss it? Restore anything reached for:
      `bash scripts/prune.sh restore <name>`.

### 7. Purge and commit

- [ ] `bash scripts/prune.sh purge` (dry run) then `purge --yes` to delete the unmissed.
- [ ] Commit if the root is under git.
- [ ] Remind the user everything is still recoverable from the Phase 1 snapshot.

## Anti-patterns

- **DO NOT delete in the same session you propose it.** Quarantine, then observe, then purge.
- **DO NOT treat "no log hits" as proof of disuse.** It is a hint. Snapshot and confirm anyway.
- **DO NOT touch read-only mounts or prebuilt skills.** User-writable roots only.
- **DO NOT author new skills here.** That is `write-a-skill` / `skill-creator` territory.

## Merge (optional power move)

When triage finds two overlapping skills, draft one merged `SKILL.md` (union of triggers,
deduplicated body, the stronger sections of each). Quarantine both originals, do not delete
them, until the merged skill is confirmed working.

## Change summary (optional)

At the end, report counts kept / merged / quarantined / purged, and the startup-context
reduction (sum the removed SKILL.md line counts from the audit table).
