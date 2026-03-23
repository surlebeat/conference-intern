# Script-Driven Registration Loop

**Date:** 2026-03-23
**Status:** Draft
**Problem:** The OpenClaw agent stops partway through the event registration loop when it encounters events with custom required fields, leaving remaining events unprocessed — even with fewer than 10 events.

## Root Cause

The current `register.sh` dumps all events and the prompt template to stdout, then hands full control to the agent for the entire loop. The agent is free to stop iterating at any point — and it does, typically after processing a few events with mixed outcomes (some registered, some needs-input, some failed). There is no script-level mechanism to ensure all events are attempted.

## Solution Overview

Move loop control from the agent to bash. `register.sh` parses `curated.md`, extracts events needing registration, and iterates over them — calling `openclaw agent --message` once per event. Each agent invocation handles exactly one RSVP and returns structured JSON. The script collects results, updates `curated.md`, and orchestrates a two-pass flow for events with custom fields.

A shared `luma-knowledge.md` file at the skill root allows the agent to learn Luma's page structure over time, speeding up subsequent registrations.

## Architecture

```
register.sh (bash — loop controller)
  │
  ├── Parse curated.md + cross-reference events.json → list of events needing registration
  │   (only lu.ma URLs — non-Luma events are skipped)
  │
  ├── Pass 1: For each event (with configurable delay between events)
  │     ├── openclaw agent --message (single-event prompt, 120s timeout)
  │     │     ├── Reads luma-knowledge.md (hints)
  │     │     ├── Opens RSVP URL, identifies form
  │     │     ├── Registers OR marks needs-input
  │     │     ├── Updates luma-knowledge.md if page differs
  │     │     └── Writes result JSON to temp file
  │     ├── Read result JSON from temp file
  │     └── Update curated.md in-place
  │
  ├── Collect needs-input events, deduplicate custom field labels
  ├── Print summary, prompt user for missing answers
  ├── Store answers in custom-answers.json
  │
  └── Pass 2: For each needs-input event
        ├── openclaw agent --message (with custom answers, 120s timeout)
        ├── Read result JSON, update curated.md
        └── Done
```

## Components

### 1. Script-Driven Loop (`register.sh`)

**Current behavior:** Outputs all context (user info, full curated.md, prompt) to stdout. Agent handles the entire loop.

**New behavior:**

1. Parse `curated.md` to extract events needing registration — those without a terminal status marker (see Status Markers table below). Cross-reference `events.json` by event name/date to look up RSVP URLs. Filter to only `lu.ma` URLs — non-Luma events are skipped (they should already be marked `🔗` by the curate step).
2. Load user info from `config.json` (name, email).
3. Check for existing `custom-answers.json` — if present, load previously-provided answers.
4. **Pass 1:** For each event:
   - Create a temp file for the agent's result: `RESULT_FILE=$(mktemp)`. Clean up with `rm -f "$RESULT_FILE"` after reading, and use a trap (`trap 'rm -f "$RESULT_FILE"' EXIT`) to handle crashes.
   - Build a single-event message containing: user info, event details (name, date, URL), session file path, luma-knowledge.md path, result file path, and the single-event prompt template.
   - Call `timeout 120 openclaw agent --message "<message>"`. If timeout fires, treat as `failed`.
   - Read and parse JSON from the result file (not stdout — avoids agent log/thinking contamination).
   - Update `curated.md` with the event's new status.
   - If `needs-input`: accumulate custom field labels.
   - If `session-expired` or `captcha`: stop the loop, report remaining events. CAPTCHA likely means Luma has flagged the session — continuing would produce repeated captcha failures.
   - Sleep for a configurable delay (default 5 seconds) to avoid rate limiting.
5. After pass 1: deduplicate custom field labels across all needs-input events.
6. For each unique field not already in `custom-answers.json`, prompt the user.
7. Save answers to `custom-answers.json`.
8. **Pass 2:** For each needs-input event:
   - Build message including the relevant answers from `custom-answers.json`.
   - Call `timeout 120 openclaw agent --message`.
   - Read result JSON from temp file, update `curated.md`.
   - If pass 2 also fails for an event, mark it `❌ Failed` (terminal).

**Idempotency:** Re-running `register.sh` skips events already marked with terminal status.

**CLI flags:**
- `--retry-pending` — skip pass 1, go straight to pass 2. Processes only events marked `⏳ Needs input`. Requires `custom-answers.json` to exist (prompts for missing answers if needed).
- `--delay <seconds>` — override the default 5-second delay between events.

### 2. Single-Event Prompt (`templates/register-single-prompt.md`)

Focused instructions for one RSVP. The agent receives:
- User name and email
- One event's name, date, and RSVP URL
- Path to `luma-knowledge.md`
- Path to session cookies file
- (Pass 2 only) Custom field answers

**Agent instructions:**

1. Read `luma-knowledge.md` for page structure hints.
2. Load session cookies if available.
3. Open the event RSVP URL.
4. Read the page:
   - If the user is already registered (confirmation visible), return `{"status": "registered"}` without touching the form.
   - Otherwise, find the registration form / button.
5. Click register/RSVP if needed to reveal the form.
6. Identify fields:
   - Standard fields (name, email): fill from provided user info.
   - Required custom fields: any required field that is not name or email.
   - Optional fields: leave blank. Fill only mandatory fields.
7. Decision:
   - Only standard required fields → fill, submit, confirm.
   - Required custom fields present AND answers provided → fill all, submit, confirm.
   - Required custom fields present, no answers → do NOT submit, return needs-input with field labels.
8. If page structure differs from `luma-knowledge.md`, update the file.
9. Write structured JSON to the result file path provided in the message (not stdout — keeps result clean from agent logs):

```json
{
  "status": "registered|needs-input|failed|closed|captcha|session-expired",
  "fields": ["Company", "Role"],
  "message": "brief human-readable note"
}
```

**Constraints:** The agent writes the JSON result file and stops. No summarizing, no follow-up questions, no deciding what to do next.

### 3. Luma Knowledge File (`luma-knowledge.md`)

A shared file at the skill root (not per-conference) containing learned patterns about Luma's page structure. Mix of natural language descriptions and concrete examples.

**Contents:**
- RSVP flow patterns (button location, form reveal behavior)
- Form field identification (standard vs. custom, required markers)
- Confirmation detection (success messages, URL changes)
- Known variations (separate /register pages, waitlists)
- `Last validated` date

**Lifecycle:**
- Agent reads it at the start of each registration.
- Treats contents as hints — always validates against the actual page.
- Updates the file if the page differs from what's described.
- Includes a `Last validated` date so the agent knows staleness.
- On a new conference (weeks/months later), the agent re-validates on the first event and updates as needed.

**Bootstrap:** Starts as a minimal skeleton. The agent fills it in after the first successful registration.

### 4. Custom Answers (`conferences/{id}/custom-answers.json`)

Per-conference file storing the user's answers to custom required fields.

```json
{
  "Company": "f(x) Protocol",
  "Role": "Engineer",
  "Wallet Address": "0x..."
}
```

- Populated between pass 1 and pass 2.
- Deduplicated: if 3 events ask for "Company", the user answers once.
- Persisted: re-runs and future `--retry-pending` calls reuse stored answers.
- New fields not yet in the file trigger a prompt to the user.

### 5. Helper Functions (`scripts/common.sh`)

New functions:
- `parse_registerable_events()` — reads `curated.md`, extracts events without terminal status markers. Cross-references `events.json` to resolve RSVP URLs. Filters to only `lu.ma` domains. Returns a list of event name, date, and RSVP URL.
- `update_event_status()` — takes an event identifier and new status string, updates the corresponding line in `curated.md` in-place.
- `collect_unique_fields()` — takes the accumulated needs-input results, deduplicates field labels, returns the list of fields not yet in `custom-answers.json`.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `scripts/register.sh` | Modified | Rewritten as loop controller |
| `scripts/common.sh` | Modified | Add `parse_registerable_events()`, `update_event_status()`, `collect_unique_fields()` |
| `SKILL.md` | Modified | Update Register section, mention `luma-knowledge.md` |
| `templates/register-single-prompt.md` | Added | Single-event agent prompt |
| `luma-knowledge.md` | Added | Shared Luma page knowledge (minimal skeleton) |
| `templates/register-prompt.md` | Kept | No longer used by script, kept as reference |

**Per-conference runtime (gitignored):**
| File | Description |
|------|-------------|
| `conferences/{id}/custom-answers.json` | User answers to custom fields |

## Status Markers

| Marker | Meaning | Terminal? | Behavior on re-run |
|--------|---------|-----------|-------------------|
| `✅ Registered` | Successfully registered (by script or already registered) | Yes | Skipped |
| `❌ Failed` | Registration failed (page error, pass 2 failure, timeout) | Yes | Skipped |
| `🚫 Closed` | Event full or registration closed | Yes | Skipped |
| `🔗 Register manually` | Non-Luma event | Yes | Skipped |
| `🛑 CAPTCHA` | Luma flagged the session | No | Retried on next run (after user solves CAPTCHA) |
| `🔒 Session expired` | Luma session expired mid-run | No | Retried on next run |
| `⏳ Needs input: [fields]` | Custom required fields need user answers | No | Processed by pass 2 or `--retry-pending` |
| _(no marker)_ | Not yet attempted | No | Processed by pass 1 |

## Error Handling

**Per-event agent errors:**
- `failed` — log, mark `❌ Failed` in curated.md, continue loop.
- `captcha` — stop the loop (CAPTCHA likely means Luma flagged the session; continuing would hit the same wall). Print how many events remain. Suggest the user solve the CAPTCHA manually and re-run.
- `closed` — mark `🚫 Closed`, continue.
- `session-expired` — stop the loop. Print how many events remain. Suggest re-authenticating and re-running.

**Script-level errors:**
- `openclaw agent` times out or crashes — treat as `failed` for that event, continue loop.
- `curated.md` malformed / can't be parsed — exit early with clear error.
- `jq` not found — caught by existing SKILL.md requirement checks.

**Knowledge file errors:**
- `luma-knowledge.md` doesn't exist — agent navigates without hints, creates the file after first successful registration.
- Agent can't update the file — non-fatal, registration works but next event won't benefit from hints.

## Design Principles

- **Bash controls the loop** — the agent can never quit the loop early.
- **One agent call per event** — fresh context, no mid-loop confusion.
- **Mandatory fields only** — optional fields are always left blank.
- **User answers once per field** — deduplicated across events, persisted for re-runs.
- **Knowledge accumulates** — each registration makes the next one faster.
- **Knowledge is hints, not truth** — agent always validates against the actual page.
- **Idempotent** — safe to re-run at any point.
- **Already-registered detection** — agent recognizes existing registrations (including manual registrations done outside this tool) and moves on without touching the form.
- **Luma-only** — parser filters to `lu.ma` URLs only; non-Luma events should already be marked `🔗` by the curate step.
- **Rate-limit aware** — configurable delay between events (default 5s) to avoid triggering Luma's bot detection.

## Edge Cases

- **Partial run interrupted (Ctrl+C, crash):** Events already processed have updated markers. The in-progress event may have been submitted on Luma but not yet marked in `curated.md`. Re-running is safe because the agent checks for existing registrations before interacting with the form.
- **`luma-knowledge.md` grows large:** The file should stay focused on structural patterns, not accumulate per-event details. If it exceeds ~100 lines, the agent should prune older/redundant entries when updating.
- **Concurrent access to `luma-knowledge.md`:** The serial loop design means only one agent writes at a time. If two conference registrations ever run in parallel, they could clobber writes. This is acceptable — the file is hints, not critical state.
