# Discover & Curate Rewrite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rewrite discover.sh and curate.sh from prompt emitters to bash orchestrators that call `openclaw agent --message` for browser/LLM tasks.

**Architecture:** discover.sh loops over Luma URLs calling the agent once per page, fetches Google Sheets CSV in bash, then merges/validates/deduplicates. curate.sh makes a single agent call with events + preferences and verifies the output.

**Tech Stack:** Bash, jq, curl, python3 (CSV parsing), OpenClaw CLI

**Spec:** `docs/superpowers/specs/2026-03-23-discover-curate-rewrite-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/common.sh` | Modify | Add `parse_sheets_csv()` helper |
| `templates/discover-luma-prompt.md` | Create | Single Luma page extraction prompt |
| `scripts/discover.sh` | Rewrite | Bash orchestrator for event discovery |
| `scripts/curate.sh` | Rewrite | Bash orchestrator for event curation |

---

### Task 1: Add `parse_sheets_csv()` to `common.sh`

**Files:**
- Modify: `scripts/common.sh` (append after `collect_unique_fields`)

- [ ] **Step 1: Add the function**

Append to `scripts/common.sh`:

```bash
# Parse Google Sheets CSV into event JSON array.
# Uses python3 for robust CSV handling (quoted fields, commas in values).
# Reads CSV from stdin, outputs JSON array to stdout.
# Skips rows with missing name or date.
parse_sheets_csv() {
  python3 -c '
import csv, json, sys

# Read CSV from stdin
reader = csv.DictReader(sys.stdin)

# Map common header variations to our schema fields
HEADER_MAP = {
    "name": ["name", "event name", "event", "title", "event title"],
    "date": ["date", "event date", "start date", "day"],
    "time": ["time", "event time", "start time", "hours"],
    "location": ["location", "venue", "place", "address"],
    "description": ["description", "desc", "details", "about", "summary"],
    "host": ["host", "organizer", "organiser", "hosted by", "org"],
    "rsvp_url": ["url", "link", "rsvp", "rsvp url", "rsvp link", "registration", "register", "luma", "event url", "event link"],
    "rsvp_count": ["rsvps", "rsvp count", "attendees", "count", "going"],
}

def find_column(fieldnames, target_names):
    """Find the CSV column matching any of the target names (case-insensitive)."""
    for fn in fieldnames:
        if fn.strip().lower() in target_names:
            return fn
    return None

if not reader.fieldnames:
    print("[]")
    sys.exit(0)

col_map = {}
for schema_field, variations in HEADER_MAP.items():
    col = find_column(reader.fieldnames, variations)
    if col:
        col_map[schema_field] = col

events = []
for row in reader:
    name = row.get(col_map.get("name", ""), "").strip()
    date = row.get(col_map.get("date", ""), "").strip()
    if not name or not date:
        continue

    rsvp_count_str = row.get(col_map.get("rsvp_count", ""), "").strip()
    try:
        rsvp_count = int(rsvp_count_str) if rsvp_count_str else None
    except ValueError:
        rsvp_count = None

    events.append({
        "name": name,
        "date": date,
        "time": row.get(col_map.get("time", ""), "").strip() or "",
        "location": row.get(col_map.get("location", ""), "").strip() or "",
        "description": row.get(col_map.get("description", ""), "").strip() or "",
        "host": row.get(col_map.get("host", ""), "").strip() or "",
        "rsvp_url": row.get(col_map.get("rsvp_url", ""), "").strip() or "",
        "rsvp_count": rsvp_count,
        "source": "sheets",
    })

print(json.dumps(events))
'
}
```

- [ ] **Step 2: Create a test CSV fixture**

Create `tests/fixtures/sheets-sample.csv`:

```csv
Event Name,Date,Time,Location,URL,Host,Description
ZK Privacy Summit,2026-07-08,14:00-18:00,Maison,https://lu.ma/zk-privacy,PrivacyDAO,ZK privacy talks
DeFi Happy Hour,2026-07-08,18:00-21:00,Le Comptoir,https://lu.ma/defi-happy,DeFi Alliance,Networking drinks
,,,,,,
Bad Row Missing Date,,10:00,,https://example.com,Someone,No date
```

- [ ] **Step 3: Test the parser**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
cat tests/fixtures/sheets-sample.csv | parse_sheets_csv | jq length
```

Expected: `2` (ZK Privacy Summit + DeFi Happy Hour. Empty row and missing-date row skipped.)

```bash
cat tests/fixtures/sheets-sample.csv | parse_sheets_csv | jq '.[0].name'
```

Expected: `"ZK Privacy Summit"`

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh tests/fixtures/sheets-sample.csv
git commit -m "feat: add parse_sheets_csv helper using python3 CSV module"
```

---

### Task 2: Create `templates/discover-luma-prompt.md`

**Files:**
- Create: `templates/discover-luma-prompt.md`

- [ ] **Step 1: Write the prompt template**

Create `templates/discover-luma-prompt.md`:

```markdown
# Conference Intern — Discover Events from Luma Page

You are extracting ALL events from a single Luma event listing page. Follow these steps exactly and write the result to the specified file.

## Context (provided by script)

- **Luma URL:** {LUMA_URL}
- **Luma knowledge file:** {KNOWLEDGE_FILE} (read for page structure hints)
- **Session cookies:** {SESSION_FILE} (load if exists)
- **Result file:** {RESULT_FILE} (write your JSON result here)

## Steps

1. **Read** the Luma knowledge file at `{KNOWLEDGE_FILE}` if it exists. Use it as hints to navigate the page faster. Do not trust it blindly — always verify against the actual page.

2. **Load** session cookies from `{SESSION_FILE}` if the file exists.

3. **Open** `{LUMA_URL}` in the browser.

4. **Scroll to load ALL events** — Luma uses infinite scroll:
   a. Take a snapshot and count the visible events.
   b. Scroll to the bottom of the page.
   c. Wait 1-2 seconds for new events to load.
   d. Take another snapshot and count events again.
   e. Repeat b-d until no new events appear (same count as previous snapshot).
   f. Only proceed once the page is fully loaded.

5. **Extract ALL events** from the fully-loaded page. For each event, capture:
   - Event name
   - Date (YYYY-MM-DD format)
   - Time (HH:MM-HH:MM or empty)
   - Location/venue
   - Brief description
   - Host/organizer name
   - RSVP URL (the direct link to register for this specific event)
   - RSVP count (number, if visible)

6. **Update knowledge file:** If the page structure differed from what `{KNOWLEDGE_FILE}` describes (or if the file is empty/skeletal), update it with what you learned. Include a mix of natural language description and concrete examples. Update the `Last validated` date. Keep the file under ~100 lines.

7. **Close the tab.**

## Result Format

Write a JSON array to `{RESULT_FILE}`. Nothing else — no markdown, no explanation, just the JSON array:

```json
[
  {
    "name": "Event Name",
    "date": "YYYY-MM-DD",
    "time": "HH:MM-HH:MM",
    "location": "Venue name",
    "description": "Brief description",
    "host": "Organizer name",
    "rsvp_url": "https://lu.ma/...",
    "rsvp_count": 123,
    "source": "luma"
  }
]
```

**Do not write anything else after writing the result file. No summary, no follow-up questions. Just write the JSON and stop.**
```

- [ ] **Step 2: Verify readable**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
read_template "discover-luma-prompt.md" | head -3
```

Expected: First 3 lines of the template.

- [ ] **Step 3: Commit**

```bash
git add templates/discover-luma-prompt.md
git commit -m "feat: add discover-luma-prompt.md for single page extraction"
```

---

### Task 3: Rewrite `scripts/discover.sh`

**Files:**
- Rewrite: `scripts/discover.sh`

- [ ] **Step 1: Write the new discover.sh**

Replace the entire contents of `scripts/discover.sh` with:

```bash
#!/usr/bin/env bash
# Conference Intern — Discover Events (Script-Driven)
# Usage: bash scripts/discover.sh <conference-id>
#
# Fetches events from Luma pages (via agent) and Google Sheets (via curl/gog),
# merges, validates URLs, deduplicates, and writes events.json.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"
SESSION_FILE="$CONF_DIR/luma-session.json"
KNOWLEDGE_FILE="$SKILL_DIR/luma-knowledge.md"
DISCOVER_PROMPT=$(read_template "discover-luma-prompt.md")

# Initialize empty events array if no existing file
if [ ! -f "$EVENTS_FILE" ]; then
  echo "[]" > "$EVENTS_FILE"
fi

# Working set: accumulate all discovered events
WORKING_SET="[]"

log_info "Discovering events for: $(config_get "$CONFIG" '.name')"

# --- Temp file cleanup ---
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT

# ==========================================================
# Phase 1: Luma URLs (primary source — agent browses pages)
# ==========================================================
LUMA_URLS=$(config_get "$CONFIG" '.luma_urls // [] | .[]' 2>/dev/null || true)

if [ -n "$LUMA_URLS" ] && [ "$LUMA_URLS" != "null" ]; then
  log_info "--- Luma sources ---"
  LUMA_COUNT=0
  LUMA_EVENTS=0

  while IFS= read -r luma_url; do
    [ -z "$luma_url" ] || [ "$luma_url" = "null" ] && continue
    LUMA_COUNT=$((LUMA_COUNT + 1))
    log_info "[$LUMA_COUNT] Luma page: $luma_url"

    # Build agent message
    MESSAGE="Discover events from this Luma page using the conference-intern discover prompt.

LUMA_URL: $luma_url
KNOWLEDGE_FILE: $KNOWLEDGE_FILE
SESSION_FILE: $SESSION_FILE
RESULT_FILE: $RESULT_FILE

$DISCOVER_PROMPT"

    # Clear previous result
    echo '[]' > "$RESULT_FILE"

    # Call agent with timeout
    if timeout 180 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
      log_info "  Agent completed"
    else
      EXIT_CODE=$?
      if [ "$EXIT_CODE" -eq 124 ]; then
        log_warn "  Agent timed out (180s) — skipping this URL"
      else
        log_warn "  Agent exited with code $EXIT_CODE — skipping this URL"
      fi
      continue
    fi

    # Read and validate result
    if [ -f "$RESULT_FILE" ] && jq 'type == "array"' "$RESULT_FILE" > /dev/null 2>&1; then
      PAGE_COUNT=$(jq 'length' "$RESULT_FILE")
      log_info "  Found $PAGE_COUNT events"
      LUMA_EVENTS=$((LUMA_EVENTS + PAGE_COUNT))

      # Merge into working set
      WORKING_SET=$(echo "$WORKING_SET" | jq --slurpfile new "$RESULT_FILE" '. + $new[0]')
    else
      log_warn "  Invalid or empty result — skipping"
    fi

    # Delay between URLs
    sleep 5
  done <<< "$LUMA_URLS"

  log_info "Luma total: $LUMA_EVENTS events from $LUMA_COUNT pages"
else
  log_info "No Luma URLs configured — skipping Luma discovery"
fi

# ==========================================================
# Phase 2: Google Sheets (secondary source — bash fetches CSV)
# ==========================================================
SHEETS=$(config_get "$CONFIG" '.sheets // [] | .[]' 2>/dev/null || true)

if [ -n "$SHEETS" ] && [ "$SHEETS" != "null" ]; then
  log_info "--- Google Sheets sources ---"
  SHEETS_EVENTS=0

  while IFS= read -r sheet_url; do
    [ -z "$sheet_url" ] || [ "$sheet_url" = "null" ] && continue
    log_info "Sheet: $sheet_url"
    SHEET_EVENTS="[]"

    # Extract Sheet ID
    SHEET_ID=$(echo "$sheet_url" | sed 's|.*/d/\([^/]*\).*|\1|' || true)

    # Try gog CLI first
    if has_gog && [ -n "$SHEET_ID" ]; then
      log_info "  Trying gog CLI..."
      if GOG_OUT=$(gog sheets get "$sheet_url" 2>/dev/null); then
        SHEET_EVENTS=$(echo "$GOG_OUT" | parse_sheets_csv)
        log_info "  gog: parsed $(echo "$SHEET_EVENTS" | jq 'length') events"
      else
        log_info "  gog failed, trying CSV export..."
      fi
    fi

    # Fallback: CSV export via curl
    if [ "$(echo "$SHEET_EVENTS" | jq 'length')" -eq 0 ] && [ -n "$SHEET_ID" ]; then
      CSV_URL="https://docs.google.com/spreadsheets/d/$SHEET_ID/pub?output=csv"
      log_info "  Trying CSV export: $CSV_URL"
      if CSV_OUT=$(curl -sL --max-time 15 "$CSV_URL" 2>/dev/null) && [ -n "$CSV_OUT" ]; then
        SHEET_EVENTS=$(echo "$CSV_OUT" | parse_sheets_csv)
        log_info "  CSV: parsed $(echo "$SHEET_EVENTS" | jq 'length') events"
      else
        log_info "  CSV export failed"
      fi
    fi

    # Fallback: browser (agent call)
    if [ "$(echo "$SHEET_EVENTS" | jq 'length')" -eq 0 ]; then
      log_info "  Trying browser fallback..."
      echo '[]' > "$RESULT_FILE"

      SHEET_MSG="Open this Google Sheet in the browser and extract all event data.

URL: $sheet_url
RESULT_FILE: $RESULT_FILE

Read the spreadsheet and extract events. For each row, capture: name, date, time, location, description, host, rsvp_url, rsvp_count. Write a JSON array to the result file. Set source to \"sheets\" for all events. Close the tab when done."

      if timeout 120 openclaw agent --message "$SHEET_MSG" > /dev/null 2>&1; then
        if [ -f "$RESULT_FILE" ] && jq 'type == "array"' "$RESULT_FILE" > /dev/null 2>&1; then
          SHEET_EVENTS=$(cat "$RESULT_FILE")
          log_info "  Browser: parsed $(echo "$SHEET_EVENTS" | jq 'length') events"
        fi
      else
        log_warn "  Browser fallback failed — skipping this sheet"
      fi
    fi

    # Merge sheets events: skip any that already exist in Luma set (by name+date)
    BEFORE=$(echo "$WORKING_SET" | jq 'length')
    WORKING_SET=$(echo "$WORKING_SET" | jq --argjson sheet "$SHEET_EVENTS" '
      . as $existing |
      ($existing | map({key: (.name + "|" + .date), value: true}) | from_entries) as $luma_keys |
      $sheet | map(select((.name + "|" + .date) as $k | $luma_keys[$k] != true)) |
      $existing + .
    ')
    ADDED=$(($(echo "$WORKING_SET" | jq 'length') - BEFORE))
    SHEETS_EVENTS=$((SHEETS_EVENTS + ADDED))
    log_info "  Added $ADDED new events (skipped duplicates from Luma)"
  done <<< "$SHEETS"

  log_info "Sheets total: $SHEETS_EVENTS new events"
else
  log_info "No Google Sheets configured — skipping Sheets discovery"
fi

# ==========================================================
# Phase 3: Post-processing
# ==========================================================
TOTAL=$(echo "$WORKING_SET" | jq 'length')
log_info "Total events before validation: $TOTAL"

if [ "$TOTAL" -eq 0 ]; then
  log_error "No events found from any source. Check your Luma URLs and Google Sheet links."
  exit 1
fi

# Validate RSVP URLs
log_info "Validating RSVP URLs..."
# Write working set to temp file to avoid O(n^2) shell variable accumulation
WORK_FILE=$(mktemp)
echo "$WORKING_SET" > "$WORK_FILE"
VALID=0
DEAD=0
TIMEOUT_COUNT=0

for i in $(seq 0 $((TOTAL - 1))); do
  URL=$(jq -r ".[$i].rsvp_url // \"\"" "$WORK_FILE")

  if [ -n "$URL" ] && [[ "$URL" == *"lu.ma"* ]]; then
    validate_luma_url "$URL" && RET=0 || RET=$?
    if [ "$RET" -eq 0 ]; then
      WORK_FILE_TMP=$(jq ".[$i].rsvp_status = \"ok\"" "$WORK_FILE")
      echo "$WORK_FILE_TMP" > "$WORK_FILE"
      VALID=$((VALID + 1))
    elif [ "$RET" -eq 2 ]; then
      WORK_FILE_TMP=$(jq ".[$i].rsvp_status = \"timeout\"" "$WORK_FILE")
      echo "$WORK_FILE_TMP" > "$WORK_FILE"
      TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
    else
      WORK_FILE_TMP=$(jq ".[$i].rsvp_url = null | .[$i].rsvp_status = \"dead-link\"" "$WORK_FILE")
      echo "$WORK_FILE_TMP" > "$WORK_FILE"
      DEAD=$((DEAD + 1))
    fi
  else
    WORK_FILE_TMP=$(jq ".[$i].rsvp_status = \"ok\"" "$WORK_FILE")
    echo "$WORK_FILE_TMP" > "$WORK_FILE"
    VALID=$((VALID + 1))
  fi
done

log_info "  Valid: $VALID | Dead links: $DEAD | Timeouts: $TIMEOUT_COUNT"

# Generate IDs and set is_new flags
log_info "Generating IDs and checking for new events..."
EXISTING_IDS=""
if [ -f "$EVENTS_FILE" ] && [ "$(jq 'length' "$EVENTS_FILE")" -gt 0 ]; then
  EXISTING_IDS=$(jq -r '.[].id // empty' "$EVENTS_FILE" | sort -u)
fi

NEW_COUNT=0
VALIDATED_COUNT=$(jq 'length' "$WORK_FILE")
for i in $(seq 0 $((VALIDATED_COUNT - 1))); do
  NAME=$(jq -r ".[$i].name // \"\"" "$WORK_FILE")
  DATE=$(jq -r ".[$i].date // \"\"" "$WORK_FILE")
  TIME=$(jq -r ".[$i].time // \"\"" "$WORK_FILE")

  ID=$(generate_event_id "$NAME" "$DATE" "$TIME")

  IS_NEW=true
  if echo "$EXISTING_IDS" | grep -q "^${ID}$" 2>/dev/null; then
    IS_NEW=false
  else
    NEW_COUNT=$((NEW_COUNT + 1))
  fi

  WORK_FILE_TMP=$(jq --arg id "$ID" --argjson is_new "$IS_NEW" ".[$i].id = \$id | .[$i].is_new = \$is_new" "$WORK_FILE")
  echo "$WORK_FILE_TMP" > "$WORK_FILE"
done

# Write final events.json
cp "$WORK_FILE" "$EVENTS_FILE"
rm -f "$WORK_FILE"

FINAL_COUNT=$(jq 'length' "$EVENTS_FILE")
log_info "=== Discovery Complete ==="
log_info "  Total events: $FINAL_COUNT"
log_info "  New events: $NEW_COUNT"
log_info "  Saved to: $EVENTS_FILE"
```

- [ ] **Step 2: Syntax check**

Run:
```bash
bash -n ~/Dev/conference-intern/scripts/discover.sh
echo $?
```

Expected: `0`

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/conference-intern
git add scripts/discover.sh
git commit -m "feat: rewrite discover.sh as bash orchestrator

Replaces prompt-emitting discover.sh with a bash orchestrator that:
- Calls openclaw agent per Luma URL for browser-based extraction
- Fetches Google Sheets CSV via curl/gog with browser fallback
- Merges with Luma preference, validates URLs, deduplicates
- Generates event IDs and is_new flags

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewrite `scripts/curate.sh`

**Files:**
- Rewrite: `scripts/curate.sh`

- [ ] **Step 1: Write the new curate.sh**

Replace the entire contents of `scripts/curate.sh` with:

```bash
#!/usr/bin/env bash
# Conference Intern — Curate Events (Script-Driven)
# Usage: bash scripts/curate.sh <conference-id>
#
# Reads events.json and config.json, calls the OpenClaw agent to score,
# rank, and tier events into curated.md.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"
CURATED_FILE="$CONF_DIR/curated.md"
CURATE_PROMPT=$(read_template "curate-prompt.md")

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

CONF_NAME=$(config_get "$CONFIG" '.name')
STRATEGY=$(config_get "$CONFIG" '.preferences.strategy')
INTERESTS=$(config_get "$CONFIG" '.preferences.interests | join(", ")')
AVOID=$(config_get "$CONFIG" '.preferences.avoid | join(", ")')
BLOCKED=$(config_get "$CONFIG" '.preferences.blocked_organizers | join(", ")')

log_info "Curating $EVENT_COUNT events for: $CONF_NAME"
log_info "Strategy: $STRATEGY"

# Build agent message
EVENTS_JSON=$(cat "$EVENTS_FILE")

MESSAGE="Curate events for this conference using the conference-intern curate prompt.

CONFERENCE: $CONF_NAME
STRATEGY: $STRATEGY
INTERESTS: $INTERESTS
AVOID: $AVOID
BLOCKED_ORGANIZERS: $BLOCKED
OUTPUT_FILE: $CURATED_FILE

EVENTS ($EVENT_COUNT total):
$EVENTS_JSON

$CURATE_PROMPT"

# Call agent
log_info "Calling agent to curate events..."
if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
  log_info "Agent completed"
else
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 124 ]; then
    log_error "Agent timed out (120s). Try re-running."
  else
    log_error "Agent exited with code $EXIT_CODE."
  fi
  exit 1
fi

# Verify output
if [ ! -f "$CURATED_FILE" ]; then
  log_error "curated.md was not created. Agent may have failed silently."
  exit 1
fi

if [ ! -s "$CURATED_FILE" ]; then
  log_error "curated.md is empty. Agent may have failed silently."
  exit 1
fi

# Log summary — count events per tier by counting "- **" lines between section headers
TOTAL_LISTED=$(grep -c "^- \*\*" "$CURATED_FILE" 2>/dev/null || echo "0")
BLOCKED_COUNT=$(grep -c "^- ~~" "$CURATED_FILE" 2>/dev/null || echo "0")

log_info "=== Curation Complete ==="
log_info "  Events listed: $TOTAL_LISTED"
log_info "  Blocked/filtered: $BLOCKED_COUNT"
log_info "  Saved to: $CURATED_FILE"
```

- [ ] **Step 2: Syntax check**

Run:
```bash
bash -n ~/Dev/conference-intern/scripts/curate.sh
echo $?
```

Expected: `0`

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/conference-intern
git add scripts/curate.sh
git commit -m "feat: rewrite curate.sh as bash orchestrator

Replaces prompt-emitting curate.sh with a bash orchestrator that:
- Reads events.json and config.json
- Calls openclaw agent once with events + preferences + curate prompt
- Verifies curated.md was created and is non-empty
- Logs summary

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: End-to-end verification

**Files:** None (testing only)

- [ ] **Step 1: Syntax check all scripts**

Run:
```bash
cd ~/Dev/conference-intern
bash -n scripts/common.sh && echo "common.sh OK"
bash -n scripts/discover.sh && echo "discover.sh OK"
bash -n scripts/curate.sh && echo "curate.sh OK"
bash -n scripts/register.sh && echo "register.sh OK"
```

Expected: All four print OK.

- [ ] **Step 2: Test parse_sheets_csv**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
cat tests/fixtures/sheets-sample.csv | parse_sheets_csv | jq '.[].name'
```

Expected:
```
"ZK Privacy Summit"
"DeFi Happy Hour"
```

- [ ] **Step 3: Test discover.sh argument parsing**

Run:
```bash
cd ~/Dev/conference-intern
bash scripts/discover.sh test-conf 2>&1 | head -1
```

Expected: `[conference-intern] ERROR: Conference 'test-conf' not found...`

- [ ] **Step 4: Test curate.sh argument parsing**

Run:
```bash
cd ~/Dev/conference-intern
bash scripts/curate.sh test-conf 2>&1 | head -1
```

Expected: `[conference-intern] ERROR: Conference 'test-conf' not found...`

- [ ] **Step 5: Sync to installed skill**

```bash
DEST=/home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern
cp scripts/common.sh "$DEST/scripts/common.sh"
cp scripts/discover.sh "$DEST/scripts/discover.sh"
cp scripts/curate.sh "$DEST/scripts/curate.sh"
cp templates/discover-luma-prompt.md "$DEST/templates/discover-luma-prompt.md"
cp templates/curate-prompt.md "$DEST/templates/curate-prompt.md"
echo "Synced"
```

- [ ] **Step 6: Restart gateway**

```bash
systemctl --user restart openclaw-gateway
sleep 2
openclaw health
```
