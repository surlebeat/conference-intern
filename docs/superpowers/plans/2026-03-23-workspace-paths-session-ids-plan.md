# Workspace Paths & Session IDs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix data path mismatch and session deadlocking so scripts and the agent share the same conference data and nested agent calls work.

**Architecture:** Move `CONFERENCES_DIR` and `KNOWLEDGE_FILE` from `$SKILL_DIR` to the OpenClaw workspace (read from `openclaw.json`). Add `--session-id` with unique IDs to all nested `openclaw agent` calls. Clean `.gitignore` to exclude dev artifacts.

**Tech Stack:** Bash, jq, OpenClaw CLI

**Spec:** `docs/superpowers/specs/2026-03-23-workspace-paths-and-session-ids-design.md`

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `scripts/common.sh` | Modify | Add `WORKSPACE_DIR` detection, move `CONFERENCES_DIR` and `KNOWLEDGE_FILE` to workspace |
| `scripts/register.sh` | Modify | Add `--session-id` to 2 `openclaw agent` calls, remove local `KNOWLEDGE_FILE` assignment |
| `scripts/discover.sh` | Modify | Add `--session-id` to 2 `openclaw agent` calls, remove local `KNOWLEDGE_FILE` assignment |
| `scripts/curate.sh` | Modify | Add `--session-id` to 1 `openclaw agent` call |
| `luma-knowledge.md` | Delete | Runtime data, will be recreated by agent in workspace |
| `.gitignore` | Rewrite | Exclude dev artifacts (docs/, tests/), keep conferences/*/ exclusions |

---

### Task 1: Update `common.sh` with workspace paths

**Files:**
- Modify: `scripts/common.sh:5-8`

- [ ] **Step 1: Replace the path block**

In `scripts/common.sh`, replace lines 5-8:

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
TEMPLATES_DIR="$SKILL_DIR/templates"
CONFERENCES_DIR="$SKILL_DIR/conferences"
```

With:

```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
TEMPLATES_DIR="$SKILL_DIR/templates"

# Workspace detection — conference data and runtime files live here
WORKSPACE_DIR=$(jq -r '.agents.defaults.workspace // empty' ~/.openclaw/openclaw.json 2>/dev/null)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
CONFERENCES_DIR="$WORKSPACE_DIR/conferences"
KNOWLEDGE_FILE="$WORKSPACE_DIR/luma-knowledge.md"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/common.sh && echo "OK"`
Expected: `OK`

- [ ] **Step 3: Verify paths resolve correctly**

Run:
```bash
source scripts/common.sh 2>/dev/null
echo "SKILL_DIR=$SKILL_DIR"
echo "WORKSPACE_DIR=$WORKSPACE_DIR"
echo "CONFERENCES_DIR=$CONFERENCES_DIR"
echo "KNOWLEDGE_FILE=$KNOWLEDGE_FILE"
```

Expected: `WORKSPACE_DIR` should be `/home/germaine/.openclaw/workspace`, `CONFERENCES_DIR` should end with `/workspace/conferences`, `KNOWLEDGE_FILE` should end with `/workspace/luma-knowledge.md`.

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh
git commit -m "fix: use openclaw workspace for conference data and knowledge file

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Add `--session-id` to all nested agent calls

**Files:**
- Modify: `scripts/register.sh:134,267`
- Modify: `scripts/discover.sh:63,148`
- Modify: `scripts/curate.sh:59`

- [ ] **Step 1: Fix register.sh — pass 1 agent call (line 134)**

Replace:
```bash
  if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
```

With:
```bash
  if timeout 120 openclaw agent --session-id "register-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
```

- [ ] **Step 2: Fix register.sh — pass 2 agent call (line 267)**

Replace the second occurrence of:
```bash
    if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
```

With:
```bash
    if timeout 120 openclaw agent --session-id "register-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
```

- [ ] **Step 3: Fix register.sh — remove local KNOWLEDGE_FILE (line 38)**

Delete this line:
```bash
KNOWLEDGE_FILE="$SKILL_DIR/luma-knowledge.md"
```

`KNOWLEDGE_FILE` is now set in `common.sh`.

- [ ] **Step 4: Fix discover.sh — Luma agent call (line 63)**

Replace:
```bash
    if timeout 180 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
```

With:
```bash
    if timeout 180 openclaw agent --session-id "discover-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
```

- [ ] **Step 5: Fix discover.sh — Sheets browser fallback (line 148)**

Replace:
```bash
      if timeout 120 openclaw agent --message "$SHEET_MSG" > /dev/null 2>&1; then
```

With:
```bash
      if timeout 120 openclaw agent --session-id "discover-$(date +%s)-$RANDOM" --message "$SHEET_MSG" > /dev/null 2>&1; then
```

- [ ] **Step 6: Fix discover.sh — remove local KNOWLEDGE_FILE (line 17)**

Delete this line:
```bash
KNOWLEDGE_FILE="$SKILL_DIR/luma-knowledge.md"
```

- [ ] **Step 7: Fix curate.sh (line 59)**

Replace:
```bash
if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
```

With:
```bash
if timeout 120 openclaw agent --session-id "curate-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
```

- [ ] **Step 8: Syntax check all scripts**

Run:
```bash
bash -n scripts/common.sh && echo "common OK"
bash -n scripts/register.sh && echo "register OK"
bash -n scripts/discover.sh && echo "discover OK"
bash -n scripts/curate.sh && echo "curate OK"
```

Expected: All four print OK.

- [ ] **Step 9: Commit**

```bash
git add scripts/register.sh scripts/discover.sh scripts/curate.sh
git commit -m "fix: add --session-id to all nested openclaw agent calls

Prevents session deadlocking when scripts invoke the agent from
within a running agent turn. Each call gets a unique session ID.
Also removes local KNOWLEDGE_FILE overrides (now in common.sh).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Delete luma-knowledge.md and clean .gitignore

**Files:**
- Delete: `luma-knowledge.md`
- Rewrite: `.gitignore`

- [ ] **Step 1: Delete luma-knowledge.md from skill root**

```bash
cd ~/Dev/conference-intern
git rm luma-knowledge.md
```

- [ ] **Step 2: Rewrite .gitignore**

Replace entire contents of `.gitignore` with:

```
# Runtime data — lives in openclaw workspace, not in skill install dir
conferences/*/

# Dev artifacts — not part of the published skill
docs/
tests/
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore
git commit -m "chore: clean gitignore, remove luma-knowledge.md from repo

Runtime data (conferences/*, luma-knowledge.md) lives in the openclaw
workspace. Dev artifacts (docs/, tests/) excluded from published skill.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Sync and verify

**Files:** None (testing + deployment)

- [ ] **Step 1: Sync to installed skill**

```bash
DEST=/home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern
cp scripts/common.sh "$DEST/scripts/common.sh"
cp scripts/register.sh "$DEST/scripts/register.sh"
cp scripts/discover.sh "$DEST/scripts/discover.sh"
cp scripts/curate.sh "$DEST/scripts/curate.sh"
rm -f "$DEST/luma-knowledge.md"
echo "Synced"
```

- [ ] **Step 2: Verify workspace data is accessible**

```bash
source ~/Dev/conference-intern/scripts/common.sh 2>/dev/null
ls "$CONFERENCES_DIR/ethcc2026/config.json" && echo "Config found at workspace path"
```

Expected: `Config found at workspace path`

- [ ] **Step 3: Clean stale data from npm install path**

```bash
rm -rf /home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern/conferences/ethcc2026/events.json
rm -rf /home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern/conferences/ethcc2026/curated.md
echo "Cleaned npm path stale data"
```

- [ ] **Step 4: Restart gateway**

```bash
systemctl --user restart openclaw-gateway
sleep 2
openclaw health
```

- [ ] **Step 5: Push and merge**

```bash
cd ~/Dev/conference-intern
git push
gh pr create --title "fix: workspace paths and isolated session IDs" --body "$(cat <<'PREOF'
## Summary

- Scripts now read conference data from the OpenClaw workspace (not the skill install dir)
- Nested `openclaw agent` calls use `--session-id` to prevent deadlocking
- `luma-knowledge.md` removed from repo (runtime data, lives in workspace)
- `.gitignore` cleaned: dev artifacts (docs/, tests/) excluded from published skill

## Root cause

Scripts used `$SKILL_DIR/conferences/` but the agent operates from `~/.openclaw/workspace/conferences/`. They never saw each other's data. Nested agent calls deadlocked because they targeted the parent's session.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PREOF
)"
gh pr merge --merge
```
