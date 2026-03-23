# Workspace Paths and Isolated Session IDs

**Date:** 2026-03-23
**Status:** Draft
**Problem:** Scripts use `$SKILL_DIR/conferences/` for data but the agent operates from `~/.openclaw/workspace/conferences/`. Nested `openclaw agent --message` calls deadlock because they target the same session as the parent agent turn.

## Root Causes

1. **Data path mismatch:** `common.sh` sets `CONFERENCES_DIR=$SKILL_DIR/conferences` (npm install path). The agent reads/writes `~/.openclaw/workspace/conferences/`. Scripts and agent never see each other's data.

2. **Session deadlock:** Scripts call `openclaw agent --message` without specifying a session ID. This targets the parent agent's session, causing a deadlock — parent waits for script, script waits for child agent, child agent waits for parent session.

3. **Runtime data in git:** `luma-knowledge.md` is agent-written runtime data but lives in the skill install directory (tracked by git).

## Fix 1: Workspace-based data paths

Read the workspace path from `openclaw.json` and use it for all runtime data.

**`common.sh` changes:**

```bash
# Workspace detection — read from openclaw config, fallback to default
WORKSPACE_DIR=$(jq -r '.agents.defaults.workspace // empty' ~/.openclaw/openclaw.json 2>/dev/null)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

# Conference data lives in workspace, not skill install dir
CONFERENCES_DIR="$WORKSPACE_DIR/conferences"

# Runtime data that the agent writes goes to workspace
KNOWLEDGE_FILE="$WORKSPACE_DIR/luma-knowledge.md"
```

`$SKILL_DIR` continues to point to the skill install location for scripts, templates, and code.

**What lives where:**

| Location | Contents |
|----------|----------|
| `$SKILL_DIR` (install dir) | SKILL.md, scripts/, templates/, README — code only, from git |
| `$WORKSPACE_DIR` (openclaw workspace) | conferences/{id}/, luma-knowledge.md — runtime data, agent-written |

## Fix 2: Isolated session IDs for nested agent calls

All `openclaw agent` calls in scripts use `--session-id` with a unique ID to get their own session instead of deadlocking on the parent's.

**Before:**
```bash
timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1
```

**After:**
```bash
timeout 120 openclaw agent --session-id "register-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1
```

Session ID prefixes by script:
- `discover.sh` → `discover-<timestamp>-<random>`
- `curate.sh` → `curate-<timestamp>-<random>`
- `register.sh` → `register-<timestamp>-<random>`

Calls remain **sequential** — no parallelism. The unique ID only prevents session deadlocking, not for running multiple agents concurrently. This is important because Luma would flag rapid parallel requests.

**Verified working:** Tested nested `openclaw agent --session-id` from within a running agent turn — successfully accessed the browser and returned results.

## Fix 3: Clean up .gitignore

Remove dev artifacts and runtime data from the published skill.

**Published (on GitHub):**
```
SKILL.md
README.md
.gitignore
scripts/
templates/
conferences/.gitkeep
```

**Excluded from GitHub (.gitignore):**
```
docs/
tests/
luma-knowledge.md
conferences/*/
```

`luma-knowledge.md` is deleted from the skill root. The agent recreates it in the workspace on first run.

## Files Changed

| File | Change |
|------|--------|
| `scripts/common.sh` | Add `WORKSPACE_DIR` detection, move `CONFERENCES_DIR` and `KNOWLEDGE_FILE` to workspace |
| `scripts/discover.sh` | Use `--session-id "discover-..."`, use `$KNOWLEDGE_FILE` from common.sh |
| `scripts/curate.sh` | Use `--session-id "curate-..."` |
| `scripts/register.sh` | Use `--session-id "register-..."`, use `$KNOWLEDGE_FILE` from common.sh |
| `luma-knowledge.md` | Delete from skill root |
| `.gitignore` | Add `docs/`, `tests/`, `luma-knowledge.md`; keep `conferences/*/` entries |

## Migration

No migration script needed. On first run after the update:
- Scripts read workspace path from openclaw.json
- If `conferences/ethcc2026/` already exists in the workspace (from previous agent runs), scripts find it immediately
- If `luma-knowledge.md` doesn't exist in workspace, agent creates it on first registration
- The stale copy at the npm install path is ignored
