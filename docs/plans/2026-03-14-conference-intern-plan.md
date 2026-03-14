# Conference Intern Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a generic OpenClaw skill that discovers, curates, and auto-registers for crypto conference side events via Luma and Google Sheets.

**Architecture:** Shell scripts orchestrate a 4-stage pipeline (setup → discover → curate → register + monitor). LLM prompt templates drive agent behavior at each stage. Browser interactions use natural language instructions (no hardcoded selectors). All config/data is per-conference in `conferences/{id}/`.

**Tech Stack:** Bash scripts, jq, LLM prompt templates (markdown), browser capability (agent-agnostic), optional gog CLI.

**Spec:** `docs/specs/2026-03-13-conference-intern-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `SKILL.md` | Frontmatter metadata + agent instructions (single entry point) |
| `.gitignore` | Exclude user data (config, events, sessions) |
| `conferences/.gitkeep` | Preserve directory in repo |
| `scripts/setup.sh` | Interactive setup — creates config.json via agent Q&A |
| `scripts/discover.sh` | Fetch events from Luma + Sheets, normalize to events.json |
| `scripts/curate.sh` | LLM-driven filtering/ranking → curated.md |
| `scripts/register.sh` | Browser RSVP automation for Luma events |
| `scripts/monitor.sh` | Re-run discover+curate, diff for new events |
| `scripts/common.sh` | Shared helpers (config loading, logging, validation) |
| `templates/setup-prompt.md` | LLM prompt for interactive setup questions |
| `templates/curate-prompt.md` | LLM prompt for event scoring/ranking |
| `templates/register-prompt.md` | LLM prompt for RSVP form navigation |

---

## Chunk 1: Scaffold & SKILL.md

### Task 1: Create project scaffold

**Files:**
- Create: `.gitignore`
- Create: `conferences/.gitkeep`

- [ ] **Step 1: Create .gitignore**

```
# User data — per-conference runtime files
conferences/*/config.json
conferences/*/events.json
conferences/*/events-previous.json
conferences/*/curated.md
conferences/*/luma-session.json
```

- [ ] **Step 2: Create conferences/.gitkeep**

Empty file to preserve directory structure in git.

- [ ] **Step 3: Commit**

```bash
git add .gitignore conferences/.gitkeep
git commit -m "feat: add project scaffold with .gitignore"
```

---

### Task 2: Create SKILL.md

**Files:**
- Create: `SKILL.md`

This is the single entry point — frontmatter metadata for ClawhHub + full agent instructions below.

- [ ] **Step 1: Write SKILL.md**

```markdown
---
name: conference-intern
description: Discover, curate, and register for crypto conference side events via Luma and Google Sheets
metadata:
  openclaw:
    emoji: "🎪"
    requires:
      bins: ["jq"]
      capabilities: ["browser"]
    optional:
      bins: ["gog"]
---

# Conference Intern

Discover, curate, and auto-register for crypto conference side events. Fetches events from Luma pages and community-curated Google Sheets, filters them using your preferences with LLM intelligence, and handles Luma RSVP via browser automation.

## Quick Start

```bash
# First time: interactive setup
bash scripts/setup.sh my-conference

# Run the full pipeline
bash scripts/discover.sh my-conference
bash scripts/curate.sh my-conference
bash scripts/register.sh my-conference

# Or all at once
bash scripts/discover.sh my-conference && bash scripts/curate.sh my-conference && bash scripts/register.sh my-conference

# Monitor for new events
bash scripts/monitor.sh my-conference
```

## Commands

| Command | Script | Description |
|---------|--------|-------------|
| setup | `bash scripts/setup.sh <name>` | Interactive config — walks you through preferences, URLs, auth |
| discover | `bash scripts/discover.sh <id>` | Fetch events from Luma + Google Sheets → `events.json` |
| curate | `bash scripts/curate.sh <id>` | LLM-driven filtering and ranking → `curated.md` |
| register | `bash scripts/register.sh <id>` | Auto-RSVP on Luma for recommended events |
| monitor | `bash scripts/monitor.sh <id>` | Re-discover + re-curate, flag new events |

## File Locations

Per-conference data lives in `conferences/{conference-id}/`:

- `config.json` — user preferences, URLs, strategy, user info
- `events.json` — all discovered events (normalized schema)
- `events-previous.json` — snapshot from last run (for monitoring diff)
- `curated.md` — the curated schedule output (grouped by day, tiered)
- `luma-session.json` — persisted Luma browser session cookies

## Agent Instructions

### Browser Usage

Use your browser capability to interact with Luma pages. **Do not hardcode CSS selectors or DOM paths.** Instead:
- Navigate to URLs and read the page content
- Interpret the page like a human — find event listings, registration forms, buttons
- This approach is evergreen — it works regardless of Luma UI changes

### Registration Rules

- Fill only **mandatory/required** fields on RSVP forms. Leave optional fields blank.
- If you encounter required fields you cannot fill (custom fields like company, wallet address, etc.), mark the event as "needs-input" in `curated.md` with the field labels listed.
- Never guess answers for custom fields — always defer to the user.

### Error Handling

**Discover:**
- Luma page fails to load → log error, skip URL, continue with remaining sources. Notify user.
- Google Sheets: try `gog` → try CSV export (`/pub?output=csv`) → try browser → skip and notify if all fail.
- Zero events across all sources → stop pipeline, notify user.

**Curate:**
- Zero events → skip, notify user.
- All events filtered out → notify user, suggest loosening criteria.

**Register:**
- RSVP page fails → mark "failed" in curated.md, continue.
- CAPTCHA detected → mark "manual" with link, notify user.
- Event full/closed → mark "closed", continue.
- Session expired → attempt re-auth if interactive, otherwise mark "session-expired" and stop.

**Pipeline short-circuiting:**
- Zero events discovered → skip curate and register.
- Zero events curated → skip register.

### Stop Conditions

Always pause and ask the user when:
- Custom RSVP fields are detected that you cannot fill
- Luma 2FA code is needed (user must paste from email)
- Zero events are found (may indicate bad URLs)
- All events are filtered out (preferences may be too restrictive)
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat: add SKILL.md with metadata and agent instructions"
```

---

## Chunk 2: Shared Helpers & Setup Pipeline

### Task 3: Create common.sh shared helpers

**Files:**
- Create: `scripts/common.sh`

Shared functions used by all scripts: config loading, validation, logging, conference directory management.

- [ ] **Step 1: Write common.sh**

```bash
#!/usr/bin/env bash
# Shared helpers for conference-intern scripts
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
TEMPLATES_DIR="$SKILL_DIR/templates"
CONFERENCES_DIR="$SKILL_DIR/conferences"

# Logging
log_info()  { echo "[conference-intern] $*"; }
log_error() { echo "[conference-intern] ERROR: $*" >&2; }
log_warn()  { echo "[conference-intern] WARN: $*" >&2; }

# Validate conference-id argument
require_conference_id() {
  local id="${1:-}"
  if [ -z "$id" ]; then
    log_error "Usage: $0 <conference-id>"
    exit 1
  fi
  echo "$id"
}

# Get conference directory, ensure it exists
get_conf_dir() {
  local id="$1"
  local dir="$CONFERENCES_DIR/$id"
  if [ ! -d "$dir" ]; then
    log_error "Conference '$id' not found. Run setup first: bash scripts/setup.sh $id"
    exit 1
  fi
  echo "$dir"
}

# Get conference directory for setup (creates it)
init_conf_dir() {
  local id="$1"
  local dir="$CONFERENCES_DIR/$id"
  mkdir -p "$dir"
  echo "$dir"
}

# Load and validate config.json
load_config() {
  local conf_dir="$1"
  local config_file="$conf_dir/config.json"
  if [ ! -f "$config_file" ]; then
    log_error "No config.json found in $conf_dir. Run setup first."
    exit 1
  fi
  cat "$config_file"
}

# Read a field from config JSON
config_get() {
  local config="$1"
  local field="$2"
  echo "$config" | jq -r "$field"
}

# Check if gog CLI is available
has_gog() {
  command -v gog &>/dev/null
}

# Generate event ID: SHA-256 hash of name+date+time, truncated to 12 chars
generate_event_id() {
  local name="$1"
  local date="$2"
  local time="$3"
  echo -n "${name}${date}${time}" | sha256sum | cut -c1-12
}

# Read a prompt template
read_template() {
  local template_name="$1"
  local template_file="$TEMPLATES_DIR/$template_name"
  if [ ! -f "$template_file" ]; then
    log_error "Template not found: $template_file"
    exit 1
  fi
  cat "$template_file"
}
```

- [ ] **Step 2: Verify syntax** (common.sh is sourced, not executed directly — no chmod needed)

```bash
bash -n scripts/common.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add shared helper functions (common.sh)"
```

---

### Task 4: Create setup-prompt.md template

**Files:**
- Create: `templates/setup-prompt.md`

The LLM prompt template that guides the agent through interactive setup.

- [ ] **Step 1: Write setup-prompt.md**

```markdown
# Conference Intern — Setup

You are setting up a new conference for the Conference Intern skill. Walk the user through the following questions one at a time. After collecting all answers, generate and save `config.json`.

## Questions

Ask these in order. Use the user's answers to build the config.

1. **Conference name** — "What conference are you attending?" (e.g., "EthDenver 2026")
   - Generate a slug ID from the name (e.g., "ethdenver-2026")

2. **Luma URLs** — "Share the Luma page URLs where side events are listed (one per line, or comma-separated)"
   - These are typically calendar pages or event listing pages on lu.ma
   - Validate: must start with https://lu.ma/ or https://luma.com/

3. **Google Sheet links** — "Any Google Sheets with curated event lists? (paste URLs, or 'none')"
   - These are community-curated lists often shared on Telegram/Twitter before conferences
   - Optional — user can skip

4. **Interest topics** — "What topics are you interested in? (comma-separated)"
   - e.g., "DeFi, ZK proofs, infrastructure, MEV"

5. **Avoid topics** — "Any topics you want to avoid? (comma-separated, or 'none')"
   - e.g., "NFT minting parties, token launches"

6. **Blocked organizers** — "Any organizers you want to block? (comma-separated, or 'none')"

7. **Registration strategy** — "How aggressively should I register you?"
   - **Aggressive**: register for most events that match your interests
   - **Conservative**: only register for top-tier, must-attend events
   - Default: aggressive

8. **Monitoring** — "How should I check for new events?"
   - **Scheduled**: check automatically on an interval (ask for interval, default 6h)
   - **On-demand**: only when you ask
   - **Both**: scheduled + manual trigger anytime
   - Default: on-demand

9. **User info for RSVP** — "What name and email should I use for registrations?"
   - Both required for Luma RSVP

10. **Luma authentication** (optional) — "Do you have a Luma account? Logging in pre-fills RSVP forms and saves time."
    - If yes: initiate the email 2FA flow
      1. Open https://lu.ma/signin in the browser
      2. Enter the user's email
      3. Ask user to paste the verification code from their email
      4. Complete login
      5. Export and save cookies to `luma-session.json`
      6. Set `luma_session.authenticated` to `true` in config
    - If no: set `luma_session.authenticated` to `false`

## Output

Save the config to `conferences/{conference-id}/config.json` with this structure:

```json
{
  "name": "<conference name>",
  "id": "<slug-id>",
  "luma_urls": ["<url1>", "<url2>"],
  "sheets": ["<url1>"],
  "user_info": {
    "name": "<name>",
    "email": "<email>"
  },
  "preferences": {
    "interests": ["<topic1>", "<topic2>"],
    "avoid": ["<topic1>"],
    "blocked_organizers": ["<org1>"],
    "strategy": "aggressive|conservative"
  },
  "monitoring": {
    "mode": "scheduled|on-demand|both",
    "interval": "6h"
  },
  "luma_session": {
    "authenticated": true|false
  }
}
```

## Scheduled Monitoring Setup

If the user chose `scheduled` or `both` monitoring mode, create the cron job:

```bash
openclaw cron edit --message "Run conference-intern monitor {conference-id}" --interval "{interval}"
```

Use the interval from the user's answer (default: 6h). The agent's heartbeat cycle will pick this up and run `monitor.sh` automatically.

## Confirmation

After saving, confirm to the user:
- Config saved to `conferences/{id}/config.json`
- If scheduled monitoring was set up: mention the cron job and interval
- Next step: run `bash scripts/discover.sh {id}` to fetch events
```

- [ ] **Step 2: Commit**

```bash
git add templates/setup-prompt.md
git commit -m "feat: add setup prompt template"
```

---

### Task 5: Create setup.sh script

**Files:**
- Create: `scripts/setup.sh`

The setup script creates the conference directory and outputs the prompt template for the agent to follow.

- [ ] **Step 1: Write setup.sh**

```bash
#!/usr/bin/env bash
# Conference Intern — Interactive Setup
# Usage: bash scripts/setup.sh <conference-name>
#
# This script prepares the conference directory and prints the setup prompt
# for the agent to follow interactively with the user.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_NAME="${1:-}"
if [ -z "$CONFERENCE_NAME" ]; then
  log_error "Usage: bash scripts/setup.sh <conference-name>"
  log_error "Example: bash scripts/setup.sh ethdenver-2026"
  exit 1
fi

# Slugify the conference name
CONFERENCE_ID=$(echo "$CONFERENCE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

CONF_DIR=$(init_conf_dir "$CONFERENCE_ID")
log_info "Conference directory: $CONF_DIR"

# Check if config already exists
if [ -f "$CONF_DIR/config.json" ]; then
  log_warn "Config already exists at $CONF_DIR/config.json"
  log_warn "Re-running setup will overwrite it."
fi

# Output the setup prompt for the agent
echo "---"
echo "CONFERENCE_ID=$CONFERENCE_ID"
echo "CONF_DIR=$CONF_DIR"
echo "---"
echo ""
read_template "setup-prompt.md"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/setup.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/setup.sh
```

Expected: no output (no syntax errors).

- [ ] **Step 4: Commit**

```bash
git add scripts/setup.sh
git commit -m "feat: add setup script"
```

---

## Chunk 3: Discover Pipeline

### Task 6: Create discover.sh script

**Files:**
- Create: `scripts/discover.sh`

Fetches events from configured Luma URLs and Google Sheets, normalizes into events.json.

- [ ] **Step 1: Write discover.sh**

```bash
#!/usr/bin/env bash
# Conference Intern — Discover Events
# Usage: bash scripts/discover.sh <conference-id>
#
# Fetches events from Luma pages and Google Sheets, normalizes into events.json.
# The agent reads this script's output and uses its browser to extract event data.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"

# Initialize empty events array if no existing file
if [ ! -f "$EVENTS_FILE" ]; then
  echo "[]" > "$EVENTS_FILE"
fi

log_info "Discovering events for: $(config_get "$CONFIG" '.name')"

# --- Google Sheets ---
SHEETS=$(config_get "$CONFIG" '.sheets // [] | .[]' 2>/dev/null || true)

if [ -n "$SHEETS" ]; then
  log_info "--- Google Sheets sources ---"
  for sheet_url in $SHEETS; do
    log_info "Sheet: $sheet_url"

    # Try gog CLI first
    if has_gog; then
      log_info "Attempting gog CLI..."
      echo "GOG_COMMAND: gog sheets get \"$sheet_url\""
      echo "If gog succeeds, parse the output into events and merge into $EVENTS_FILE"
      echo "If gog fails, fall through to CSV export."
    fi

    # CSV export fallback
    # Convert Google Sheets URL to CSV export format
    SHEET_ID=$(echo "$sheet_url" | sed 's|.*/d/\([^/]*\).*|\1|' || true)
    if [ -n "$SHEET_ID" ]; then
      CSV_URL="https://docs.google.com/spreadsheets/d/$SHEET_ID/pub?output=csv"
      log_info "CSV export URL: $CSV_URL"
      echo "FETCH_CSV: curl -sL \"$CSV_URL\""
      echo "If CSV fetch succeeds, parse rows into events and merge into $EVENTS_FILE"
      echo "If CSV fetch fails, fall back to browser."
    fi

    echo "BROWSER_FALLBACK: Open $sheet_url in browser and read event data from the spreadsheet."
    echo "Note: Google Sheets UI is complex — this is a last resort."
    echo ""
  done
fi

# --- Luma URLs ---
LUMA_URLS=$(config_get "$CONFIG" '.luma_urls // [] | .[]' 2>/dev/null || true)

if [ -n "$LUMA_URLS" ]; then
  log_info "--- Luma sources ---"

  # Load session cookies if available
  SESSION_FILE="$CONF_DIR/luma-session.json"
  if [ -f "$SESSION_FILE" ]; then
    log_info "Luma session found — load cookies from: $SESSION_FILE"
    echo "LOAD_COOKIES: $SESSION_FILE"
  fi

  for luma_url in $LUMA_URLS; do
    log_info "Luma page: $luma_url"
    echo "BROWSE: Navigate to $luma_url"
    echo "READ: Take a snapshot of the page. Extract all events listed:"
    echo "  - Event name"
    echo "  - Date and time"
    echo "  - Location/venue"
    echo "  - Description (brief)"
    echo "  - Host/organizer"
    echo "  - RSVP URL (the link to register for this specific event)"
    echo "  - RSVP count (if visible)"
    echo "  - Source: luma"
    echo ""
    echo "If the page has pagination or 'load more', navigate through all pages."
    echo ""
  done
fi

# --- Post-processing instructions ---
echo "=== POST-PROCESSING ==="
echo ""
echo "After collecting events from all sources:"
echo ""
echo "1. Deduplicate: generate ID for each event using SHA-256 of name+date+time (truncated to 12 chars)"
echo "   Use: echo -n \"\${name}\${date}\${time}\" | sha256sum | cut -c1-12"
echo ""
echo "2. Normalize each event to this schema:"
echo '   {'
echo '     "id": "<12-char-hash>",'
echo '     "name": "<event name>",'
echo '     "date": "<YYYY-MM-DD>",'
echo '     "time": "<HH:MM-HH:MM or empty>",'
echo '     "location": "<venue name or empty>",'
echo '     "description": "<brief description>",'
echo '     "host": "<organizer name>",'
echo '     "source": "<luma|sheets>",'
echo '     "rsvp_url": "<registration URL>",'
echo '     "rsvp_count": <number or null>,'
echo '     "is_new": <true if not in previous events.json>'
echo '   }'
echo ""
echo "3. Compare with existing $EVENTS_FILE to set is_new flags"
echo "4. Save merged results to $EVENTS_FILE"
echo ""

log_info "Agent: after completing the above steps, save all events to: $EVENTS_FILE"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/discover.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/discover.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/discover.sh
git commit -m "feat: add discover script for fetching events from Luma and Sheets"
```

---

## Chunk 4: Curate Pipeline

### Task 7: Create curate-prompt.md template

**Files:**
- Create: `templates/curate-prompt.md`

- [ ] **Step 1: Write curate-prompt.md**

```markdown
# Conference Intern — Curate Events

You are curating events for a crypto conference attendee. Read their preferences and the discovered events, then score, rank, and tier each event.

## Inputs

- `config.json` — user preferences (interests, avoid topics, blocked organizers, strategy)
- `events.json` — all discovered events

## Scoring Criteria

For each event, assess:

1. **Topic relevance** — how well does the event match the user's interest topics?
   - Strong match: event name/description directly relates to an interest topic
   - Weak match: tangentially related
   - No match: unrelated

2. **Quality signals**
   - Known/reputable host or speakers
   - High RSVP count relative to other events (indicates community interest)
   - Clear description and professional presentation

3. **Blocklist check**
   - If the host matches `blocked_organizers` → exclude
   - If the event topic matches `avoid` list → exclude

## Strategy Application

**Aggressive:**
- Include most events that aren't blocked/avoided
- Must-attend: strong topic match + quality signals
- Recommended: any topic match or good quality signals
- Optional: no strong match but not blocked

**Conservative:**
- Only include events with strong topic relevance
- Must-attend: strong topic match + strong quality signals
- Recommended: strong topic match
- Skip everything else

## Output Format

Write `curated.md` with this structure:

```
# {Conference Name} — Side Events

Last updated: {YYYY-MM-DD HH:MM} UTC
Strategy: {aggressive|conservative} | Events: {total} found, {recommended} recommended

## {Date} ({Day of week})

### Must Attend
- **{Event Name}** — {time} @ {location}
  Host: {host} | RSVPs: {count}
  {status}

### Recommended
- **{Event Name}** — {time} @ {location}
  Host: {host} | RSVPs: {count}
  {status}

### Optional
- **{Event Name}** — {time} @ {location}
  Host: {host}
  {status}

## Blocked / Filtered Out
- ~~{Event Name}~~ — {reason}
```

Status markers:
- (empty) — not yet registered
- ✅ Registered
- ⏳ Needs input: [{field1}, {field2}]
- 🔗 [Register manually]({url})
- ❌ Failed
- 🚫 Closed
- 🔒 Session expired

Group events by date, sorted by time within each day.
Non-Luma events should always show 🔗 with their registration link.
```

- [ ] **Step 2: Commit**

```bash
git add templates/curate-prompt.md
git commit -m "feat: add curate prompt template with scoring criteria"
```

---

### Task 8: Create curate.sh script

**Files:**
- Create: `scripts/curate.sh`

- [ ] **Step 1: Write curate.sh**

```bash
#!/usr/bin/env bash
# Conference Intern — Curate Events
# Usage: bash scripts/curate.sh <conference-id>
#
# Reads events.json and config.json, outputs the curate prompt for the agent
# to score, rank, and tier events into curated.md.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"
CURATED_FILE="$CONF_DIR/curated.md"

if [ ! -f "$EVENTS_FILE" ]; then
  log_error "No events.json found. Run discover first: bash scripts/discover.sh $CONFERENCE_ID"
  exit 1
fi

EVENT_COUNT=$(jq 'length' "$EVENTS_FILE")
if [ "$EVENT_COUNT" -eq 0 ]; then
  log_warn "No events found in events.json. Nothing to curate."
  log_warn "Check your Luma URLs and Google Sheet links, then re-run discover."
  exit 0
fi

log_info "Curating $EVENT_COUNT events for: $(config_get "$CONFIG" '.name')"
log_info "Strategy: $(config_get "$CONFIG" '.preferences.strategy')"

# Output context for the agent
echo "=== CURATE ==="
echo ""
echo "CONFERENCE: $(config_get "$CONFIG" '.name')"
echo "STRATEGY: $(config_get "$CONFIG" '.preferences.strategy')"
echo ""
echo "INTERESTS: $(config_get "$CONFIG" '.preferences.interests | join(", ")')"
echo "AVOID: $(config_get "$CONFIG" '.preferences.avoid | join(", ")')"
echo "BLOCKED ORGANIZERS: $(config_get "$CONFIG" '.preferences.blocked_organizers | join(", ")')"
echo ""
echo "EVENTS ($EVENT_COUNT total):"
jq '.' "$EVENTS_FILE"
echo ""
echo "OUTPUT FILE: $CURATED_FILE"
echo ""
echo "--- PROMPT ---"
read_template "curate-prompt.md"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/curate.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/curate.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/curate.sh
git commit -m "feat: add curate script"
```

---

## Chunk 5: Register Pipeline

### Task 9: Create register-prompt.md template

**Files:**
- Create: `templates/register-prompt.md`

- [ ] **Step 1: Write register-prompt.md**

```markdown
# Conference Intern — Register for Events

You are registering the user for Luma events from the curated list. Use the browser to navigate RSVP pages and fill forms.

## Pre-flight

1. Load Luma session cookies from `luma-session.json` if it exists (authenticated session pre-fills forms)
2. Read `curated.md` to identify events that need registration (no status marker yet, or events the user has specifically asked to register for)
3. Read `config.json` for user info (name, email)

## For Each Luma Event

1. **Open** the event's RSVP URL in the browser
2. **Read** the page — find the registration form or "Register" / "RSVP" button
3. **Click** the register/RSVP button if needed to reveal the form
4. **Identify fields:**
   - Standard fields: name, email (fill from config)
   - Required custom fields: any field marked as required that is not name or email
   - Optional fields: leave blank
5. **Decision:**
   - If only standard required fields → fill them, submit, confirm success
   - If required custom fields are present → do NOT submit. Instead:
     - Note the event name and list all required custom field labels
     - Mark the event as "needs-input" in `curated.md`: `⏳ Needs input: [field1, field2]`
     - Move to the next event
6. **After submission:**
   - Look for a confirmation message on the page
   - If confirmed → mark as `✅ Registered` in `curated.md`
   - If error → mark as `❌ Failed` with brief reason

## Error Handling

- **CAPTCHA detected** → mark as `🔗 [Register manually](url)`, notify user
- **Event full / registration closed** → mark as `🚫 Closed`
- **Page won't load** → mark as `❌ Failed`, continue to next event
- **Session expired** (login prompt appears unexpectedly):
  - If the user is available interactively: re-do the email 2FA flow
  - Otherwise: mark remaining events as `🔒 Session expired` and stop

## After All Events

1. Update `curated.md` with all status changes
2. Summarize results:
   - X events registered successfully
   - X events need user input (list them with their custom fields)
   - X events failed or need manual registration
3. If any events need input, ask the user to provide the answers
   - When the user provides answers, re-run registration for just those events
```

- [ ] **Step 2: Commit**

```bash
git add templates/register-prompt.md
git commit -m "feat: add register prompt template"
```

---

### Task 10: Create register.sh script

**Files:**
- Create: `scripts/register.sh`

- [ ] **Step 1: Write register.sh**

```bash
#!/usr/bin/env bash
# Conference Intern — Register for Events
# Usage: bash scripts/register.sh <conference-id>
#
# Reads curated.md and config.json, outputs the register prompt for the agent
# to RSVP to Luma events via browser automation.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

CURATED_FILE="$CONF_DIR/curated.md"
SESSION_FILE="$CONF_DIR/luma-session.json"

if [ ! -f "$CURATED_FILE" ]; then
  log_error "No curated.md found. Run curate first: bash scripts/curate.sh $CONFERENCE_ID"
  exit 1
fi

log_info "Registering for events: $(config_get "$CONFIG" '.name')"

# Output context for the agent
echo "=== REGISTER ==="
echo ""
echo "USER INFO:"
echo "  Name: $(config_get "$CONFIG" '.user_info.name')"
echo "  Email: $(config_get "$CONFIG" '.user_info.email')"
echo ""

if [ -f "$SESSION_FILE" ]; then
  echo "LUMA SESSION: $SESSION_FILE (load cookies before browsing)"
  echo "AUTHENTICATED: true"
else
  AUTHENTICATED=$(config_get "$CONFIG" '.luma_session.authenticated')
  echo "LUMA SESSION: none"
  echo "AUTHENTICATED: $AUTHENTICATED"
  if [ "$AUTHENTICATED" = "false" ]; then
    echo "Note: No session — will use email-based RSVP (name + email fields)"
  fi
fi
echo ""

echo "CURATED EVENTS:"
cat "$CURATED_FILE"
echo ""

echo "OUTPUT FILE: $CURATED_FILE (update status markers in-place)"
echo ""
echo "--- PROMPT ---"
read_template "register-prompt.md"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/register.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/register.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/register.sh
git commit -m "feat: add register script for Luma RSVP automation"
```

---

## Chunk 6: Monitor Pipeline

### Task 11: Create monitor.sh script

**Files:**
- Create: `scripts/monitor.sh`

- [ ] **Step 1: Write monitor.sh**

```bash
#!/usr/bin/env bash
# Conference Intern — Monitor for New Events
# Usage: bash scripts/monitor.sh <conference-id>
#
# Re-runs discover + curate, diffs against previous events.json to flag new events.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"
PREVIOUS_FILE="$CONF_DIR/events-previous.json"

log_info "Monitoring for new events: $(config_get "$CONFIG" '.name')"

# Save current events as previous (for diffing)
if [ -f "$EVENTS_FILE" ]; then
  cp "$EVENTS_FILE" "$PREVIOUS_FILE"
  PREV_COUNT=$(jq 'length' "$PREVIOUS_FILE")
  log_info "Previous events snapshot: $PREV_COUNT events"
else
  echo "[]" > "$PREVIOUS_FILE"
  log_info "No previous events — first run, all events will be marked as new."
fi

# Run discover
log_info "--- Running discover ---"
bash "$SCRIPTS_DIR/discover.sh" "$CONFERENCE_ID"

# Check for new events
if [ -f "$EVENTS_FILE" ]; then
  NEW_COUNT=$(jq 'length' "$EVENTS_FILE")
  log_info "Events after discover: $NEW_COUNT"

  if [ "$NEW_COUNT" -eq 0 ]; then
    log_warn "No events found. Skipping curate."
    exit 0
  fi

  # Diff: find event IDs in current but not in previous
  NEW_IDS=$(jq -r '.[].id' "$EVENTS_FILE" | sort)
  OLD_IDS=$(jq -r '.[].id' "$PREVIOUS_FILE" 2>/dev/null | sort)
  ADDED=$(comm -23 <(echo "$NEW_IDS") <(echo "$OLD_IDS") | wc -l | tr -d ' ')
  REMOVED=$(comm -13 <(echo "$NEW_IDS") <(echo "$OLD_IDS") | wc -l | tr -d ' ')

  log_info "New events: $ADDED"
  log_info "Removed events: $REMOVED"

  if [ "$ADDED" -gt 0 ]; then
    echo ""
    echo "NEW EVENTS DETECTED:"
    # List new event names
    for id in $(comm -23 <(echo "$NEW_IDS") <(echo "$OLD_IDS")); do
      NAME=$(jq -r ".[] | select(.id == \"$id\") | .name" "$EVENTS_FILE")
      echo "  + $NAME"
    done
    echo ""
  fi
else
  log_error "events.json not found after discover."
  exit 1
fi

# Run curate
log_info "--- Running curate ---"
bash "$SCRIPTS_DIR/curate.sh" "$CONFERENCE_ID"

log_info "Monitor complete."
```

- [ ] **Step 2: Make executable**

```bash
chmod +x scripts/monitor.sh
```

- [ ] **Step 3: Verify syntax**

```bash
bash -n scripts/monitor.sh
```

Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add scripts/monitor.sh
git commit -m "feat: add monitor script for detecting new events"
```

---

## Chunk 7: Final Integration

### Task 12: Clean up existing spec-only files and final commit

**Files:**
- Modify: verify all scripts are executable
- Verify: .gitignore is correct
- Verify: directory structure matches spec

- [ ] **Step 1: Verify all scripts are executable**

```bash
ls -la scripts/
```

Expected: all `.sh` files have `x` permission.

- [ ] **Step 2: Verify directory structure**

```bash
find . -not -path './.git/*' | sort
```

Expected structure should match the spec's file tree.

- [ ] **Step 3: Run syntax check on all scripts**

```bash
for f in scripts/*.sh; do bash -n "$f" && echo "OK: $f" || echo "FAIL: $f"; done
```

Expected: all OK.

- [ ] **Step 4: Final commit and push**

```bash
git add -A
git status
git commit -m "feat: conference-intern skill complete — all pipeline stages implemented"
git push
```

---

## Execution Notes

**Testing approach:** This skill is primarily shell scripts + LLM prompt templates. There is no traditional unit test suite. Testing is done by:

1. Running `bash scripts/setup.sh test-conf` and verifying config.json is created
2. Running each pipeline stage with a real conference and verifying the outputs
3. The agent's LLM intelligence handles the complex logic (curation, form navigation) — the scripts are thin orchestration layers

**Key invariant:** Scripts never make decisions — they load data, print context, and output prompt templates. The agent (LLM) makes all intelligent decisions by reading the prompts and data.
