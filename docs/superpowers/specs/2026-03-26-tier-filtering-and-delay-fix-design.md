# Tier Filtering, Delay Fix, and Tab Check

**Date:** 2026-03-26
**Status:** Draft
**Problem:** Agent overrode --delay to 1s causing tab crashes. Registration processed all events including Optional/Blocked instead of filtering by curation tier. Tabs disappearing mid-form-fill wasted 90s on agent timeouts.

## Fix 1: Remove --delay flag, hardcode 15s

Delete `--delay` from `register.sh` argument parsing. Hardcode `DELAY=15`. The agent was overriding it to 1s for speed, causing browser stress, tab conflicts, and Luma rate limiting.

## Fix 2: Filter registration by tier + strategy

`parse_registerable_events()` currently returns all events without terminal status markers. It needs to also filter by curation tier based on the conference strategy:

- **Aggressive:** register Must Attend + Recommended + Optional (skip Blocked)
- **Conservative:** register Must Attend + Recommended (skip Optional + Blocked)

Implementation: `parse_registerable_events()` takes a 4th argument for strategy. It tracks which section header (`### Must Attend`, `### Recommended`, `### Optional`, `## Blocked`) each event is under. Events under excluded sections are skipped.

`register.sh` reads the strategy from config and passes it to the parser.

## Fix 3: Tab-alive check before agent handoff

In `cli_register_event()`, after clicking the register button and before calling the form-fill agent, verify the tab still exists:

```bash
# Quick tab-alive check
if ! openclaw browser evaluate --target-id "$target_id" --fn '() => true' > /dev/null 2>&1; then
  echo '{"status": "failed", "fields": [], "message": "Tab died before form fill"}' > "$result_file"
  return
fi
```

Saves 90s of agent timeout when the tab is already dead.

## Files Changed

| File | Change |
|------|--------|
| `scripts/register.sh` | Remove `--delay` flag, hardcode 15s. Pass strategy to parser. |
| `scripts/common.sh` | `parse_registerable_events()`: add tier filtering by strategy. `cli_register_event()`: add tab-alive check. |
| `SKILL.md` | Remove `--delay` from command examples. |
