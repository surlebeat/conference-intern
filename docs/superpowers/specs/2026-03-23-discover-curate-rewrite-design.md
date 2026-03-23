# Discover & Curate Script Rewrite

**Date:** 2026-03-23
**Status:** Draft
**Problem:** `discover.sh` and `curate.sh` are prompt emitters — they print instructions to stdout but do no actual work. When the agent runs them (per SKILL.md), the scripts exit successfully without discovering or curating anything.

## Root Cause

Both scripts were designed for an older model where the agent read its own script output as instructions. After updating SKILL.md to tell the agent "run the scripts, don't do it yourself", the scripts exit 0 and the agent considers the job done — never acting on the printed instructions.

`register.sh` was already converted to the new pattern (bash loop calling `openclaw agent --message` per event). `discover.sh` and `curate.sh` need the same treatment.

## Solution Overview

Rewrite both scripts as bash orchestrators that call `openclaw agent --message` for tasks requiring LLM/browser, and handle mechanical work (CSV fetching, URL validation, deduplication) in bash.

## discover.sh

```
discover.sh (bash — orchestrator)
  │
  ├── For each Luma URL in config:
  │     ├── openclaw agent --message (scroll page, extract events, 180s timeout)
  │     │     ├── Reads luma-knowledge.md for hints
  │     │     ├── Navigates to Luma URL
  │     │     ├── Scrolls to load all events (infinite scroll loop)
  │     │     ├── Extracts event data from fully-loaded page
  │     │     ├── Writes JSON array to temp file
  │     │     └── Closes tab
  │     ├── Bash reads temp file, merges into working set
  │     └── Delay between URLs (if multiple)
  │
  ├── For each Google Sheet URL in config:
  │     ├── Try gog CLI if available
  │     ├── Fallback: curl CSV export URL
  │     ├── Fallback: openclaw agent --message (browser, read spreadsheet)
  │     ├── Parse rows into events
  │     └── Add events not already in Luma set (match by name+date)
  │
  ├── Validate RSVP URLs (HEAD check via validate_luma_url)
  ├── Deduplicate, generate IDs
  └── Write events.json
```

### Luma Discovery

For each Luma URL in `config.json`:

1. Initialize empty `events.json` (`[]`) if it doesn't exist.
2. Load Luma session cookies path (`luma-session.json`) if available — some Luma pages may require auth.
3. Create temp result file. Clean up with trap.
4. Build message (same shape as register.sh):
   ```
   Discover events from this Luma page using the conference-intern discover prompt.

   LUMA_URL: <url>
   KNOWLEDGE_FILE: $SKILL_DIR/luma-knowledge.md
   SESSION_FILE: <path to luma-session.json>
   RESULT_FILE: <temp file path>

   <contents of discover-luma-prompt.md>
   ```
5. Call `timeout 180 openclaw agent --message "<message>" > /dev/null 2>&1`. Longer timeout than registration — scrolling a full page with infinite scroll takes time.
4. Read JSON array from result file. Each element follows the event schema:
   ```json
   {
     "name": "Event Name",
     "date": "YYYY-MM-DD",
     "time": "HH:MM-HH:MM",
     "location": "Venue",
     "description": "Brief description",
     "host": "Organizer",
     "rsvp_url": "https://lu.ma/...",
     "rsvp_count": 123,
     "source": "luma"
   }
   ```
5. Merge into working event set.
6. If agent times out or result file is empty/invalid, log error but continue with other URLs.

### Google Sheets Discovery

For each Google Sheet URL in `config.json`:

1. Extract Sheet ID from URL.
2. **Try `gog` CLI** if available: `gog sheets get "<url>"`. Parse output.
3. **Fallback: CSV export** via `curl -sL "https://docs.google.com/spreadsheets/d/$SHEET_ID/pub?output=csv"`. Parse with `parse_sheets_csv()`.
4. **Fallback: browser** — call `openclaw agent --message` with the Sheet URL and a "read this spreadsheet" prompt. Agent writes events JSON to temp file.
5. For each parsed event: check if name+date already exists in the Luma set. If yes, skip (Luma is authoritative). If no, add it with `"source": "sheets"`.

### Post-processing (bash)

1. Validate all RSVP URLs using `validate_luma_url()`:
   - 2xx/3xx → `rsvp_status: "ok"`
   - 404/error → `rsvp_url: null`, `rsvp_status: "dead-link"`
   - Timeout → keep URL, `rsvp_status: "timeout"`
2. Generate event IDs: SHA-256 of name+date+time, truncated to 12 chars.
3. Compare with existing `events.json` to set `is_new` flags.
4. Write final `events.json`.

## curate.sh

```
curate.sh (bash — orchestrator)
  │
  ├── Read events.json (exit if empty)
  ├── Read config.json (preferences, strategy)
  ├── Build message: events + preferences + curate prompt template
  ├── openclaw agent --message (single call, 120s timeout)
  │     ├── Agent scores and ranks events
  │     ├── Agent writes curated.md directly to conf dir
  │     └── Agent stops
  ├── Verify curated.md was created and is non-empty
  └── Log summary (event counts per tier)
```

1. Read `events.json` — exit if file missing or empty.
2. Read `config.json` — extract preferences (interests, avoid, blocked organizers, strategy).
3. Build message (agent stdout suppressed, same as register.sh):
   ```
   Curate events for this conference using the conference-intern curate prompt.

   CONFERENCE: <name>
   STRATEGY: <aggressive|conservative>
   INTERESTS: <comma-separated>
   AVOID: <comma-separated>
   BLOCKED_ORGANIZERS: <comma-separated>
   OUTPUT_FILE: <path to curated.md>

   EVENTS:
   <full events.json contents>

   <contents of curate-prompt.md>
   ```
4. Call `timeout 120 openclaw agent --message "<message>" > /dev/null 2>&1`.
5. Verify `curated.md` was created and is non-empty.
6. Log summary: count events per tier (Must Attend, Recommended, Optional, Blocked).
7. If agent times out or curated.md not created: log error, exit non-zero.

## New Prompt Template: `templates/discover-luma-prompt.md`

Single Luma page extraction prompt. The agent receives:
- One Luma URL
- Path to `luma-knowledge.md` (`$SKILL_DIR/luma-knowledge.md` — shared with register)
- Path to session cookies file
- Path to result file

Agent instructions:
1. Read `luma-knowledge.md` for page structure hints.
2. Open the Luma URL.
3. Scroll to load all events (infinite scroll loop: scroll → wait → snapshot → repeat until no new events).
4. Extract all events from the fully-loaded page.
5. Write a JSON array of events to the result file.
6. Update `luma-knowledge.md` if page structure differs from what's described.
7. Close the tab.
8. Stop.

Result format — JSON array written to result file:
```json
[
  {
    "name": "Event Name",
    "date": "YYYY-MM-DD",
    "time": "HH:MM-HH:MM",
    "location": "Venue",
    "description": "Brief description",
    "host": "Organizer",
    "rsvp_url": "https://lu.ma/...",
    "rsvp_count": 123,
    "source": "luma"
  }
]
```

## New Helper: `parse_sheets_csv()` in `common.sh`

Parses a Google Sheets CSV into event JSON. Uses `python3 -c` for robust CSV parsing (handles quoted fields, commas in values, etc.). Bash CSV parsing is too fragile for real-world spreadsheets.

**Limitation:** Google Sheets CSV export only works if the sheet is published. Community sheets are best-effort — users should publish as CSV for reliable results.

The function:
1. Reads CSV from stdin.
2. Uses `python3` csv module to parse rows properly.
3. Detects column headers from the first row (case-insensitive matching for common variations: "event name"/"name"/"event", "date", "time", "url"/"link"/"rsvp", etc.).
4. Maps each row into the event schema.
5. Outputs JSON array to stdout.
6. Skips rows with missing name or date.

**Requires:** `python3` (standard on most systems).

## Idempotency

**discover.sh:** Re-running merges new events with existing `events.json`. Events matched by name+date are updated (not duplicated). New events get `is_new: true`. This means re-running is safe and additive.

**curate.sh:** Re-running overwrites `curated.md` entirely. This is intentional — the curated output should reflect the latest events and preferences.

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `scripts/discover.sh` | Rewrite | Bash orchestrator: agent per Luma URL, bash CSV for Sheets, merge, validate |
| `scripts/curate.sh` | Rewrite | Bash orchestrator: single agent call, verify output |
| `templates/discover-luma-prompt.md` | Create | Single Luma page extraction prompt |
| `templates/curate-prompt.md` | Keep | No changes — passed in agent message |
| `scripts/common.sh` | Modify | Add `parse_sheets_csv()` helper |

## Error Handling

**discover.sh:**
- Luma agent times out (180s) → log error, continue with remaining URLs
- Luma agent returns empty/invalid JSON → log warning, continue
- Google Sheets curl fails → try browser fallback (agent call)
- Browser fallback also fails → log error, skip this sheet, continue
- All sources return zero events → log error, exit non-zero
- URL validation failure → mark as dead-link, continue

**curate.sh:**
- Agent times out (120s) → log error, exit non-zero
- curated.md not created → log error, exit non-zero
- curated.md empty → log warning, exit non-zero

## Design Principles

- **Bash controls the flow** — agent only does browser/LLM tasks it's uniquely suited for
- **Luma is primary source** — Google Sheets supplements, never overrides
- **Mechanical work in bash** — CSV parsing, URL validation, deduplication, ID generation
- **Same pattern as register.sh** — agent writes results to temp files, not stdout
- **Resilient** — one failing source doesn't block others
