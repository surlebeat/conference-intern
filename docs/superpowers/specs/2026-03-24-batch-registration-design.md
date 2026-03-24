# Batch Registration

**Date:** 2026-03-24
**Status:** Draft
**Problem:** With 65+ events, the registration script never finishes pass 1 before timing out or hitting Luma rate limits. It never reaches the custom fields prompt. Most events have custom fields, so the two-pass approach (register all, then ask) doesn't work in practice.

## Solution: Batch Processing

Process events in batches of 10. After each batch, the script exits and writes a status file. The agent reads the status, asks the user about any new custom fields, then runs the next batch. After all batches, a final retry pass processes events that needed input using the accumulated answers.

## Flow

```
Agent: runs register.sh ethcc2026
  → Script processes 10 events, writes registration-status.json, exits

Agent: reads registration-status.json
  → Sees 3 needs-input events with new fields (Company, Telegram)
Agent: "These fields are needed: Company, Telegram. What are yours?"
User: "f(x) Protocol, @cyrille_fx"
Agent: writes to custom-answers.json

Agent: runs register.sh ethcc2026
  → Script processes next 10 events (uses custom-answers.json for known fields), exits

Agent: reads status, sees 1 new field (LinkedIn)
Agent: "New field: LinkedIn?"
User: "linkedin.com/in/cyrille"
Agent: updates custom-answers.json

...repeat until all batches done...

Agent: "All events processed. 5 still need input — retrying with your answers..."
Agent: runs register.sh ethcc2026 --retry-pending
  → Processes only ⏳ events with accumulated answers

Agent: "Done. 4 more registered, 1 has a field you can't answer."
```

## Changes to register.sh

### New flag: `--batch-size <n>`

Default: 10. Controls how many events to process per run.

### Batch processing

Instead of processing all events in one run:
1. Parse registerable events (same as before)
2. Take only the first `batch-size` events
3. Process them (CLI registration)
4. Write `registration-status.json` to conference dir
5. Exit

### Remove interactive prompt

Delete the `read -r answer` loop (lines 189-194 in current code). The agent handles custom field collection conversationally between batch runs.

### Remove pass 2

The two-pass flow within a single run is removed. Instead:
- Normal runs process the next batch of unprocessed events
- `--retry-pending` processes only `⏳ Needs input` events using `custom-answers.json`

### Idempotency

Each run skips events already marked with terminal status (`✅`, `❌`, `🚫`, `🔗`) in curated.md. The script picks up where the last batch left off automatically.

## registration-status.json

Written to conference dir after each batch:

```json
{
  "batch": 3,
  "batch_size": 10,
  "processed_this_batch": 10,
  "total_processed": 30,
  "remaining": 35,
  "results_this_batch": {
    "registered": 5,
    "needs_input": 3,
    "failed": 1,
    "closed": 1
  },
  "new_fields": ["Company", "Telegram"],
  "all_needs_input_fields": ["Company", "Telegram", "LinkedIn"],
  "done": false
}
```

- `new_fields`: custom field labels found in THIS batch that aren't already in `custom-answers.json`
- `all_needs_input_fields`: cumulative list of all unanswered fields across all batches
- `done`: true when `remaining` is 0

## SKILL.md Changes

Update registration instructions to tell the agent:

```markdown
### Registration (batch flow)

Registration processes events in batches of 10. After each batch:
1. Run `bash scripts/register.sh <conference-id>`
2. Read `conferences/<id>/registration-status.json`
3. If `new_fields` is not empty: ask the user for answers, write to `custom-answers.json`
4. If `done` is false: run `register.sh` again for the next batch
5. When `done` is true and there are needs-input events: run `register.sh --retry-pending`
```

## Files Changed

| File | Change |
|------|--------|
| `scripts/register.sh` | Add `--batch-size`, write status JSON, remove interactive prompt, remove pass 2 |
| `SKILL.md` | Update registration instructions for batch flow |

**Per-conference runtime (gitignored):**
- `conferences/{id}/registration-status.json`
