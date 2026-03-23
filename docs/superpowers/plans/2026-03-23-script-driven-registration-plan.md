# Script-Driven Registration Loop — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make event registration reliable by moving loop control from the OpenClaw agent to bash, so every event gets attempted regardless of agent behavior.

**Architecture:** `register.sh` iterates over events in bash, calling `openclaw agent --message` once per event. A shared `luma-knowledge.md` file lets the agent learn Luma page structure over time. Two-pass flow: register what you can, then batch-collect user answers for custom fields and retry. Discovery step gets link validation to filter out 404s before they reach registration.

**Tech Stack:** Bash, jq, curl, OpenClaw CLI (`openclaw agent --message`)

**Spec:** `docs/superpowers/specs/2026-03-23-script-driven-registration-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/common.sh` | Modify | Add 4 new helpers: `validate_luma_url`, `parse_registerable_events`, `update_event_status`, `collect_unique_fields` |
| `scripts/discover.sh` | Modify | Add link validation + Luma-source preference in post-processing instructions |
| `scripts/register.sh` | Rewrite | Bash loop controller: parse events, iterate with `openclaw agent`, two-pass flow, CLI flags |
| `templates/register-single-prompt.md` | Create | Single-event agent prompt with structured JSON result |
| `luma-knowledge.md` | Create | Minimal skeleton for Luma page patterns |
| `SKILL.md` | Modify | Update Register section, add `luma-knowledge.md` reference, update error handling |
| `.gitignore` | Modify | Add `conferences/*/custom-answers.json` |

---

### Task 1: Add `validate_luma_url` to `common.sh`

**Files:**
- Modify: `scripts/common.sh:84` (append after `read_template`)

- [ ] **Step 1: Add the function**

Append to `scripts/common.sh`:

```bash
# Validate a Luma URL with a HEAD request
# Returns 0 if reachable (2xx/3xx), 1 if dead (4xx/5xx), 2 if timeout
validate_luma_url() {
  local url="$1"
  local status
  status=$(curl -sI -o /dev/null -w "%{http_code}" --max-time 5 "$url" 2>/dev/null) || true
  if [ "$status" = "000" ]; then
    return 2  # timeout / connection failed
  elif [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
    return 0  # reachable
  else
    return 1  # dead link
  fi
}
```

- [ ] **Step 2: Test manually**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
validate_luma_url "https://lu.ma/ethcc" && echo "OK" || echo "FAIL: $?"
validate_luma_url "https://lu.ma/this-does-not-exist-404-test" && echo "OK" || echo "FAIL: $?"
```

Expected: First should print `OK`, second should print `FAIL: 1`.

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add validate_luma_url helper to common.sh"
```

---

### Task 2: Add `parse_registerable_events` to `common.sh`

**Files:**
- Modify: `scripts/common.sh` (append after `validate_luma_url`)

This function parses `curated.md` to extract events without terminal status markers, then cross-references `events.json` to resolve RSVP URLs.

The `curated.md` format (from `curate-prompt.md`) is:
```
- **{Event Name}** — {time} @ {location}
  Host: {host} | RSVPs: {count}
  {status}
```

Terminal markers to skip: `✅`, `❌`, `🚫`, `🔗`
Non-terminal (include): `⏳`, `🛑`, `🔒`, no marker

- [ ] **Step 1: Add the function**

Append to `scripts/common.sh`:

```bash
# Parse curated.md for events needing registration.
# Cross-references events.json to resolve RSVP URLs.
# Outputs tab-separated lines: event_name\trsvp_url
# Args: $1 = curated.md path, $2 = events.json path, $3 = mode ("all" or "pending-only")
parse_registerable_events() {
  local curated_file="$1"
  local events_file="$2"
  local mode="${3:-all}"

  local current_event=""
  local skip_event=false
  local found_pending=false

  while IFS= read -r line; do
    # Match event lines: - **Event Name** — ...
    if [[ "$line" =~ ^-\ \*\*(.+)\*\*\ — ]]; then
      # If we had a previous event that wasn't skipped, output it
      if [ -n "$current_event" ] && [ "$skip_event" = false ]; then
        # In pending-only mode, only output if we found ⏳
        if [ "$mode" = "all" ] || [ "$found_pending" = true ]; then
          _resolve_and_output "$current_event" "$events_file"
        fi
      fi
      current_event="${BASH_REMATCH[1]}"
      skip_event=false
      found_pending=false
      # In pending-only mode, default to skipping unless ⏳ found
    # Check status lines for markers
    elif [ -n "$current_event" ] && [ "$skip_event" = false ]; then
      # Terminal markers — skip these events in all modes
      if [[ "$line" =~ ✅|❌|🚫|🔗 ]]; then
        skip_event=true
      fi
      # Track if this event has ⏳ marker (for pending-only mode)
      if [[ "$line" =~ ⏳ ]]; then
        found_pending=true
      fi
    fi
  done < "$curated_file"

  # Handle the last event
  if [ -n "$current_event" ] && [ "$skip_event" = false ]; then
    if [ "$mode" = "all" ] || [ "$found_pending" = true ]; then
      _resolve_and_output "$current_event" "$events_file"
    fi
  fi
}

# Internal: look up an event's RSVP URL from events.json, filter to lu.ma only
_resolve_and_output() {
  local event_name="$1"
  local events_file="$2"
  local rsvp_url
  rsvp_url=$(jq -r --arg name "$event_name" '
    .[] | select(.name == $name) | .rsvp_url // empty
  ' "$events_file" | head -1)

  # Only output lu.ma URLs
  if [ -n "$rsvp_url" ] && [[ "$rsvp_url" == *"lu.ma"* ]]; then
    printf '%s\t%s\n' "$event_name" "$rsvp_url"
  fi
}
```

- [ ] **Step 2: Create a test fixture**

Create `tests/fixtures/curated-sample.md`:

```markdown
# Test Conference — Side Events

Last updated: 2026-07-08 14:00 UTC
Strategy: aggressive | Events: 5 found, 4 recommended

## July 8 (Wednesday)

### Must Attend
- **ZK Privacy Summit** — 14:00-18:00 @ Maison
  Host: PrivacyDAO | RSVPs: 234

### Recommended
- **DeFi Builders Happy Hour** — 18:00-21:00 @ Le Comptoir
  Host: DeFi Alliance | RSVPs: 89
  ✅ Registered

- **Infra Roundtable** — 10:00-12:00 @ Hotel
  Host: InfraDAO
  ⏳ Needs input: [Company, Role]

### Optional
- **NFT Mixer** — 20:00-23:00 @ Club
  Host: NFTCo
  ❌ Failed

- **MEV Workshop** — 09:00-12:00 @ Lab
  Host: Flashbots
```

Create `tests/fixtures/events-sample.json`:

```json
[
  {"name": "ZK Privacy Summit", "rsvp_url": "https://lu.ma/zk-privacy"},
  {"name": "DeFi Builders Happy Hour", "rsvp_url": "https://lu.ma/defi-happy"},
  {"name": "Infra Roundtable", "rsvp_url": "https://lu.ma/infra-rt"},
  {"name": "NFT Mixer", "rsvp_url": "https://lu.ma/nft-mixer"},
  {"name": "MEV Workshop", "rsvp_url": "https://eventbrite.com/mev"}
]
```

- [ ] **Step 3: Test the parser**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
echo "--- all mode (should show: ZK Privacy Summit, Infra Roundtable) ---"
parse_registerable_events tests/fixtures/curated-sample.md tests/fixtures/events-sample.json all
echo ""
echo "--- pending-only mode (should show: Infra Roundtable only) ---"
parse_registerable_events tests/fixtures/curated-sample.md tests/fixtures/events-sample.json pending-only
```

Expected output:
```
--- all mode (should show: ZK Privacy Summit, Infra Roundtable) ---
ZK Privacy Summit	https://lu.ma/zk-privacy
Infra Roundtable	https://lu.ma/infra-rt
--- pending-only mode (should show: Infra Roundtable only) ---
Infra Roundtable	https://lu.ma/infra-rt
```

Note: "DeFi Builders Happy Hour" skipped (✅ terminal), "NFT Mixer" skipped (❌ terminal), "MEV Workshop" skipped (not lu.ma URL).

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh tests/
git commit -m "feat: add parse_registerable_events helper with test fixtures"
```

---

### Task 3: Add `update_event_status` and `collect_unique_fields` to `common.sh`

**Files:**
- Modify: `scripts/common.sh` (append)

- [ ] **Step 1: Add `update_event_status`**

Append to `scripts/common.sh`:

```bash
# Update an event's status in curated.md in-place.
# Finds the event by name, replaces or adds the status line below it.
# Args: $1 = curated.md path, $2 = event name, $3 = new status (e.g., "✅ Registered")
update_event_status() {
  local curated_file="$1"
  local event_name="$2"
  local new_status="$3"
  local tmp_file
  tmp_file=$(mktemp)

  # States: "scanning" (looking for event), "found" (saw event line),
  #         "past_host" (saw Host: line, looking for status), "done" (status written)
  local state="scanning"

  while IFS= read -r line; do
    case "$state" in
      scanning)
        echo "$line" >> "$tmp_file"
        if [[ "$line" == *"**${event_name}**"* ]]; then
          state="found"
        fi
        ;;
      found)
        # Expect Host: line next
        if [[ "$line" =~ ^[[:space:]]+Host: ]]; then
          echo "$line" >> "$tmp_file"
          state="past_host"
        elif [[ "$line" =~ ^[[:space:]]+(✅|❌|🚫|🔗|🛑|🔒|⏳) ]]; then
          # Status line directly after event (no Host line) — replace it
          echo "  $new_status" >> "$tmp_file"
          state="done"
        elif [[ "$line" == -* ]] || [[ ! "$line" =~ ^[[:space:]] ]]; then
          # Next event or section — insert status before this line
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="done"
        else
          echo "$line" >> "$tmp_file"
        fi
        ;;
      past_host)
        # After Host: line — next indented line is existing status or insertion point
        if [[ "$line" =~ ^[[:space:]]+(✅|❌|🚫|🔗|🛑|🔒|⏳) ]]; then
          # Replace existing status
          echo "  $new_status" >> "$tmp_file"
          state="done"
        elif [[ "$line" == -* ]] || [[ ! "$line" =~ ^[[:space:]] ]] || [ -z "$line" ]; then
          # Next event, section header, or blank line — insert status before
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="done"
        else
          # Other indented line (description?) — insert status before it
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="done"
        fi
        ;;
      done)
        echo "$line" >> "$tmp_file"
        ;;
    esac
  done < "$curated_file"

  # Handle end of file — if event was found but no status written
  if [ "$state" != "done" ] && [ "$state" != "scanning" ]; then
    echo "  $new_status" >> "$tmp_file"
  fi

  mv "$tmp_file" "$curated_file"
}
```

- [ ] **Step 2: Add `collect_unique_fields`**

Append to `scripts/common.sh`:

```bash
# Collect unique custom field labels from needs-input results,
# excluding fields already answered in custom-answers.json.
# Args: $1 = newline-separated list of "field1,field2" per event, $2 = custom-answers.json path (may not exist)
# Outputs: one field label per line
collect_unique_fields() {
  local fields_list="$1"
  local answers_file="${2:-}"
  local -A seen=()

  # Load existing answers
  local -A answered=()
  if [ -n "$answers_file" ] && [ -f "$answers_file" ]; then
    while IFS= read -r key; do
      answered["$key"]=1
    done < <(jq -r 'keys[]' "$answers_file" 2>/dev/null)
  fi

  # Deduplicate and filter
  while IFS= read -r fields_csv; do
    IFS=',' read -ra fields <<< "$fields_csv"
    for field in "${fields[@]}"; do
      field=$(echo "$field" | xargs)  # trim whitespace
      if [ -n "$field" ] && [ -z "${seen[$field]+x}" ] && [ -z "${answered[$field]+x}" ]; then
        seen["$field"]=1
        echo "$field"
      fi
    done
  done <<< "$fields_list"
}
```

- [ ] **Step 3: Test `update_event_status`**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
cp tests/fixtures/curated-sample.md /tmp/test-curated.md
update_event_status /tmp/test-curated.md "ZK Privacy Summit" "✅ Registered"
grep -A3 "ZK Privacy" /tmp/test-curated.md
```

Expected: Should show the event line followed by `  ✅ Registered`.

- [ ] **Step 4: Test `collect_unique_fields`**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
echo '{"Company": "f(x) Protocol"}' > /tmp/test-answers.json
FIELDS=$(printf "Company,Role\nCompany,Wallet Address\n")
collect_unique_fields "$FIELDS" /tmp/test-answers.json
```

Expected output (Company already answered, so only new fields):
```
Role
Wallet Address
```

- [ ] **Step 5: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add update_event_status and collect_unique_fields helpers"
```

---

### Task 4: Add link validation to `discover.sh`

**Files:**
- Modify: `scripts/discover.sh:88-115` (post-processing section)

- [ ] **Step 1: Update post-processing instructions**

Replace the post-processing section in `discover.sh` (lines 88-115) with:

```bash
# --- Post-processing instructions ---
echo "=== POST-PROCESSING ==="
echo ""
echo "After collecting events from all sources:"
echo ""
echo "1. Deduplicate: generate ID for each event using SHA-256 of name+date+time (truncated to 12 chars)"
echo "   Use: echo -n \"\${name}\${date}\${time}\" | sha256sum | cut -c1-12"
echo ""
echo "2. Source preference: if the same event (matched by name + date) appears from both Luma and Sheets,"
echo "   prefer the Luma-sourced RSVP URL. Luma's own pages are authoritative."
echo ""
echo "3. Normalize each event to this schema:"
echo '   {'
echo '     "id": "<12-char-hash>",'
echo '     "name": "<event name>",'
echo '     "date": "<YYYY-MM-DD>",'
echo '     "time": "<HH:MM-HH:MM or empty>",'
echo '     "location": "<venue name or empty>",'
echo '     "description": "<brief description>",'
echo '     "host": "<organizer name>",'
echo '     "source": "<luma|sheets>",'
echo '     "rsvp_url": "<registration URL or null if dead link>",'
echo '     "rsvp_status": "<ok|dead-link|timeout>",'
echo '     "rsvp_count": <number or null>,'
echo '     "is_new": <true if not in previous events.json>'
echo '   }'
echo ""
echo "4. Validate each RSVP URL before storing:"
echo "   For each lu.ma URL, run: curl -sI -o /dev/null -w '%{http_code}' --max-time 5 <url>"
echo "   - 2xx/3xx → set rsvp_status: ok"
echo "   - 404 or other error → set rsvp_url: null, rsvp_status: dead-link"
echo "   - Timeout (000) → keep URL, set rsvp_status: timeout (may work in browser)"
echo ""
echo "5. Compare with existing $EVENTS_FILE to set is_new flags"
echo "6. Save merged results to $EVENTS_FILE"
echo ""

log_info "Agent: after completing the above steps, save all events to: $EVENTS_FILE"
```

- [ ] **Step 2: Verify the script still runs**

Run:
```bash
cd ~/Dev/conference-intern
bash -n scripts/discover.sh  # syntax check only
echo $?
```

Expected: `0` (no syntax errors).

- [ ] **Step 3: Commit**

```bash
git add scripts/discover.sh
git commit -m "feat: add link validation and source preference to discover post-processing"
```

---

### Task 5: Create `luma-knowledge.md` skeleton

**Files:**
- Create: `luma-knowledge.md` (skill root)

- [ ] **Step 1: Write the skeleton**

Create `luma-knowledge.md`:

```markdown
# Luma Page Knowledge

Last validated: (not yet validated — agent will fill this in after first registration)

> This file contains learned patterns about Luma's event page structure.
> The agent reads it before each registration as hints to speed up navigation.
> Treat everything here as hints — always validate against the actual page.
> Update this file if the page differs from what's described.
> Keep this file under ~100 lines. Prune redundant entries when updating.

## RSVP Flow

(Agent: describe the typical RSVP flow after your first registration — where the button is, what happens when you click it, how the form appears)

## Form Fields

(Agent: describe how standard fields (name, email) and custom required fields appear — what marks a field as required, where custom fields show up relative to standard ones)

## Confirmation

(Agent: describe what a successful registration looks like — confirmation messages, page changes, URL changes)

## Known Variations

(Agent: note any variations you encounter across events — different form layouts, waitlists, external registration pages)
```

- [ ] **Step 2: Commit**

```bash
git add luma-knowledge.md
git commit -m "feat: add luma-knowledge.md skeleton for page pattern learning"
```

---

### Task 6: Create `templates/register-single-prompt.md`

**Files:**
- Create: `templates/register-single-prompt.md`

- [ ] **Step 1: Write the prompt template**

Create `templates/register-single-prompt.md`:

```markdown
# Conference Intern — Register for Single Event

You are registering the user for ONE Luma event. Follow these steps exactly and write the result to the specified file.

## Context (provided by script)

- **User name:** {USER_NAME}
- **User email:** {USER_EMAIL}
- **Event name:** {EVENT_NAME}
- **Event RSVP URL:** {RSVP_URL}
- **Luma knowledge file:** {KNOWLEDGE_FILE} (read for page structure hints)
- **Session cookies:** {SESSION_FILE} (load if exists)
- **Result file:** {RESULT_FILE} (write your JSON result here)
- **Custom answers:** {CUSTOM_ANSWERS} (if provided, use these for custom fields)

## Steps

1. **Read** the Luma knowledge file at `{KNOWLEDGE_FILE}` if it exists. Use it as hints to navigate the page faster. Do not trust it blindly — always verify against the actual page.

2. **Load** session cookies from `{SESSION_FILE}` if the file exists.

3. **Open** `{RSVP_URL}` in the browser.

4. **Check** if the user is already registered:
   - If the page shows a confirmation (e.g., "You're registered!", "You're going!", "View your ticket"), the user is already registered.
   - Write `{"status": "registered", "fields": [], "message": "Already registered"}` to `{RESULT_FILE}` and stop.
   - Do NOT unregister or interact with the form.

5. **Find** the registration form or "Register" / "RSVP" button. Click it if needed to reveal the form.

6. **Identify fields:**
   - Standard fields: name, email → fill with `{USER_NAME}` and `{USER_EMAIL}`
   - Required custom fields: any required field that is NOT name or email
   - Optional fields: leave blank. **Fill only mandatory fields.**

7. **Decide:**
   - **Only standard required fields** → fill them, submit the form.
   - **Required custom fields AND answers provided in `{CUSTOM_ANSWERS}`** → fill all required fields (standard + custom), submit.
   - **Required custom fields, no answers available** → do NOT submit. Write result with status `needs-input` and list the field labels.

8. **After submission:** look for confirmation on the page.
   - Confirmed → status: `registered`
   - Error → status: `failed`

9. **Update knowledge file:** If the page structure differed from what `{KNOWLEDGE_FILE}` describes (or if the file is empty/skeletal), update it with what you learned. Include a mix of natural language description and concrete examples (DOM patterns, button labels, etc.). Update the `Last validated` date. Keep the file under ~100 lines.

## Error Handling

- **CAPTCHA detected** → status: `captcha`
- **Event full / registration closed** → status: `closed`
- **Page won't load** → status: `failed`
- **Login prompt / session expired** → status: `session-expired`

## Result Format

Write a single JSON object to `{RESULT_FILE}`. Nothing else — no markdown, no explanation, just the JSON:

```json
{
  "status": "registered|needs-input|failed|closed|captcha|session-expired",
  "fields": ["FieldLabel1", "FieldLabel2"],
  "message": "Brief human-readable note"
}
```

- `fields`: only populated for `needs-input` status. List the labels of required custom fields.
- `message`: one sentence explaining what happened.

**Do not write anything else after writing the result file. No summary, no follow-up questions. Just write the JSON and stop.**
```

- [ ] **Step 2: Verify the template is readable**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
read_template "register-single-prompt.md" | head -5
```

Expected: First 5 lines of the template printed.

- [ ] **Step 3: Commit**

```bash
git add templates/register-single-prompt.md
git commit -m "feat: add single-event registration prompt template"
```

---

### Task 7: Rewrite `scripts/register.sh` — core loop

This is the main task. Rewrite `register.sh` as the bash loop controller.

**Files:**
- Rewrite: `scripts/register.sh`

- [ ] **Step 1: Write the new register.sh**

Replace the entire contents of `scripts/register.sh` with:

```bash
#!/usr/bin/env bash
# Conference Intern — Register for Events (Script-Driven Loop)
# Usage: bash scripts/register.sh <conference-id> [--retry-pending] [--delay <seconds>]
#
# Iterates over events from curated.md, calling the OpenClaw agent once per event.
# Two-pass flow: register what you can, then collect user answers for custom fields.

set -euo pipefail
source "$(dirname "$0")/common.sh"

# --- Parse arguments ---
CONFERENCE_ID=""
RETRY_PENDING=false
DELAY=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --retry-pending) RETRY_PENDING=true; shift ;;
    --delay)
      if [ -z "${2:-}" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        log_error "--delay requires a positive integer (seconds)"
        exit 1
      fi
      DELAY="$2"; shift 2 ;;
    -*) log_error "Unknown flag: $1"; exit 1 ;;
    *) CONFERENCE_ID="$1"; shift ;;
  esac
done

CONFERENCE_ID=$(require_conference_id "$CONFERENCE_ID")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

CURATED_FILE="$CONF_DIR/curated.md"
EVENTS_FILE="$CONF_DIR/events.json"
SESSION_FILE="$CONF_DIR/luma-session.json"
ANSWERS_FILE="$CONF_DIR/custom-answers.json"
KNOWLEDGE_FILE="$SKILL_DIR/luma-knowledge.md"
PROMPT_TEMPLATE=$(read_template "register-single-prompt.md")

USER_NAME=$(config_get "$CONFIG" '.user_info.name')
USER_EMAIL=$(config_get "$CONFIG" '.user_info.email')

if [ ! -f "$CURATED_FILE" ]; then
  log_error "No curated.md found. Run curate first: bash scripts/curate.sh $CONFERENCE_ID"
  exit 1
fi

if [ ! -f "$EVENTS_FILE" ]; then
  log_error "No events.json found. Run discover first: bash scripts/discover.sh $CONFERENCE_ID"
  exit 1
fi

log_info "Registering for events: $(config_get "$CONFIG" '.name')"
log_info "Delay between events: ${DELAY}s"

# --- Determine parse mode ---
PARSE_MODE="all"
if [ "$RETRY_PENDING" = true ]; then
  PARSE_MODE="pending-only"
  log_info "Retry-pending mode: processing only ⏳ Needs input events"
fi

# --- Build event list ---
EVENTS_LIST=""
while IFS=$'\t' read -r name url; do
  EVENTS_LIST+="${name}"$'\t'"${url}"$'\n'
done < <(parse_registerable_events "$CURATED_FILE" "$EVENTS_FILE" "$PARSE_MODE")

if [ -z "$EVENTS_LIST" ]; then
  log_info "No events to register. All events already have terminal status."
  exit 0
fi

EVENT_COUNT=$(echo -n "$EVENTS_LIST" | grep -c '.' || true)
log_info "Found $EVENT_COUNT events to process"

# --- Load existing custom answers ---
CUSTOM_ANSWERS=""
if [ -f "$ANSWERS_FILE" ]; then
  CUSTOM_ANSWERS=$(cat "$ANSWERS_FILE")
  log_info "Loaded existing custom answers from $ANSWERS_FILE"
fi

# --- Counters ---
REGISTERED=0
NEEDS_INPUT=0
FAILED=0
CLOSED=0
NEEDS_INPUT_FIELDS=""
NEEDS_INPUT_EVENTS=""

# --- Temp file cleanup ---
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT

# --- Main loop ---
EVENT_NUM=0
while IFS=$'\t' read -r EVENT_NAME RSVP_URL; do
  [ -z "$EVENT_NAME" ] && continue
  EVENT_NUM=$((EVENT_NUM + 1))

  log_info "[$EVENT_NUM/$EVENT_COUNT] $EVENT_NAME"
  log_info "  URL: $RSVP_URL"

  # Build the agent message
  MESSAGE="Register for this event using the conference-intern single-event registration prompt.

USER_NAME: $USER_NAME
USER_EMAIL: $USER_EMAIL
EVENT_NAME: $EVENT_NAME
RSVP_URL: $RSVP_URL
KNOWLEDGE_FILE: $KNOWLEDGE_FILE
SESSION_FILE: $SESSION_FILE
RESULT_FILE: $RESULT_FILE"

  # Add custom answers if available
  if [ -n "$CUSTOM_ANSWERS" ]; then
    MESSAGE+="
CUSTOM_ANSWERS: $CUSTOM_ANSWERS"
  else
    MESSAGE+="
CUSTOM_ANSWERS: (none)"
  fi

  MESSAGE+="

$PROMPT_TEMPLATE"

  # Clear previous result
  echo '{}' > "$RESULT_FILE"

  # Call the agent with timeout
  if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
    log_info "  Agent completed"
  else
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 124 ]; then
      log_warn "  Agent timed out (120s)"
      echo '{"status": "failed", "fields": [], "message": "Agent timed out"}' > "$RESULT_FILE"
    else
      log_warn "  Agent exited with code $EXIT_CODE"
      echo '{"status": "failed", "fields": [], "message": "Agent crashed"}' > "$RESULT_FILE"
    fi
  fi

  # Parse result
  STATUS=$(jq -r '.status // "failed"' "$RESULT_FILE" 2>/dev/null || echo "failed")
  FIELDS=$(jq -r '.fields // [] | join(",")' "$RESULT_FILE" 2>/dev/null || echo "")
  MSG=$(jq -r '.message // ""' "$RESULT_FILE" 2>/dev/null || echo "")

  log_info "  Status: $STATUS${MSG:+ — $MSG}"

  case "$STATUS" in
    registered)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "✅ Registered"
      REGISTERED=$((REGISTERED + 1))
      ;;
    needs-input)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "⏳ Needs input: [$FIELDS]"
      NEEDS_INPUT=$((NEEDS_INPUT + 1))
      NEEDS_INPUT_FIELDS+="${FIELDS}"$'\n'
      NEEDS_INPUT_EVENTS+="${EVENT_NAME}"$'\t'"${RSVP_URL}"$'\n'
      ;;
    closed)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "🚫 Closed"
      CLOSED=$((CLOSED + 1))
      ;;
    captcha)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "🛑 CAPTCHA"
      log_error "CAPTCHA detected — Luma likely flagged this session."
      log_error "Stopping registration. $((EVENT_COUNT - EVENT_NUM)) events remaining."
      log_error "Solve the CAPTCHA manually on Luma, then re-run this script."
      break
      ;;
    session-expired)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "🔒 Session expired"
      log_error "Session expired. $((EVENT_COUNT - EVENT_NUM)) events remaining."
      log_error "Re-authenticate on Luma, then re-run this script."
      break
      ;;
    failed|*)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "❌ Failed${MSG:+: $MSG}"
      FAILED=$((FAILED + 1))
      ;;
  esac

  # Delay between events (skip after last event)
  if [ "$EVENT_NUM" -lt "$EVENT_COUNT" ]; then
    sleep "$DELAY"
  fi

done <<< "$EVENTS_LIST"

# --- Pass 1 Summary ---
echo ""
log_info "=== Registration Summary ==="
log_info "  ✅ Registered: $REGISTERED"
log_info "  ⏳ Needs input: $NEEDS_INPUT"
log_info "  🚫 Closed: $CLOSED"
log_info "  ❌ Failed: $FAILED"

# --- Pass 2: Handle needs-input events ---
if [ "$NEEDS_INPUT" -gt 0 ]; then
  echo ""
  log_info "=== Custom Fields Needed ==="

  # Collect unique unanswered fields
  UNIQUE_FIELDS=$(collect_unique_fields "$NEEDS_INPUT_FIELDS" "$ANSWERS_FILE")

  if [ -z "$UNIQUE_FIELDS" ]; then
    log_info "All custom fields already answered in $ANSWERS_FILE"
  else
    log_info "Please provide answers for the following fields:"
    echo ""

    # Initialize or load answers
    if [ -f "$ANSWERS_FILE" ]; then
      ANSWERS_JSON=$(cat "$ANSWERS_FILE")
    else
      ANSWERS_JSON="{}"
    fi

    while IFS= read -r field; do
      [ -z "$field" ] && continue
      echo -n "  $field: "
      read -r answer
      ANSWERS_JSON=$(echo "$ANSWERS_JSON" | jq --arg k "$field" --arg v "$answer" '. + {($k): $v}')
    done <<< "$UNIQUE_FIELDS"

    # Save answers
    echo "$ANSWERS_JSON" > "$ANSWERS_FILE"
    log_info "Answers saved to $ANSWERS_FILE"
    CUSTOM_ANSWERS=$(cat "$ANSWERS_FILE")
  fi

  # Re-run for needs-input events
  echo ""
  log_info "=== Pass 2: Retrying needs-input events ==="

  PASS2_REGISTERED=0
  PASS2_FAILED=0
  PASS2_NUM=0
  PASS2_COUNT=$(echo -n "$NEEDS_INPUT_EVENTS" | grep -c '^' || true)

  while IFS=$'\t' read -r EVENT_NAME RSVP_URL; do
    [ -z "$EVENT_NAME" ] && continue
    PASS2_NUM=$((PASS2_NUM + 1))

    log_info "[$PASS2_NUM/$PASS2_COUNT] $EVENT_NAME (retry with answers)"

    MESSAGE="Register for this event using the conference-intern single-event registration prompt.

USER_NAME: $USER_NAME
USER_EMAIL: $USER_EMAIL
EVENT_NAME: $EVENT_NAME
RSVP_URL: $RSVP_URL
KNOWLEDGE_FILE: $KNOWLEDGE_FILE
SESSION_FILE: $SESSION_FILE
RESULT_FILE: $RESULT_FILE
CUSTOM_ANSWERS: $CUSTOM_ANSWERS

$PROMPT_TEMPLATE"

    echo '{}' > "$RESULT_FILE"

    if timeout 120 openclaw agent --message "$MESSAGE" > /dev/null 2>&1; then
      log_info "  Agent completed"
    else
      EXIT_CODE=$?
      if [ "$EXIT_CODE" -eq 124 ]; then
        log_warn "  Agent timed out (120s)"
        echo '{"status": "failed", "fields": [], "message": "Agent timed out"}' > "$RESULT_FILE"
      else
        log_warn "  Agent exited with code $EXIT_CODE"
        echo '{"status": "failed", "fields": [], "message": "Agent crashed"}' > "$RESULT_FILE"
      fi
    fi

    STATUS=$(jq -r '.status // "failed"' "$RESULT_FILE" 2>/dev/null || echo "failed")
    MSG=$(jq -r '.message // ""' "$RESULT_FILE" 2>/dev/null || echo "")

    log_info "  Status: $STATUS${MSG:+ — $MSG}"

    case "$STATUS" in
      registered)
        update_event_status "$CURATED_FILE" "$EVENT_NAME" "✅ Registered"
        PASS2_REGISTERED=$((PASS2_REGISTERED + 1))
        ;;
      captcha)
        update_event_status "$CURATED_FILE" "$EVENT_NAME" "🛑 CAPTCHA"
        log_error "CAPTCHA detected — stopping pass 2."
        break
        ;;
      session-expired)
        update_event_status "$CURATED_FILE" "$EVENT_NAME" "🔒 Session expired"
        log_error "Session expired — stopping pass 2."
        break
        ;;
      *)
        update_event_status "$CURATED_FILE" "$EVENT_NAME" "❌ Failed${MSG:+: $MSG}"
        PASS2_FAILED=$((PASS2_FAILED + 1))
        ;;
    esac

    if [ "$PASS2_NUM" -lt "$PASS2_COUNT" ]; then
      sleep "$DELAY"
    fi

  done <<< "$NEEDS_INPUT_EVENTS"

  echo ""
  log_info "=== Pass 2 Summary ==="
  log_info "  ✅ Registered: $PASS2_REGISTERED"
  log_info "  ❌ Failed: $PASS2_FAILED"
fi

log_info "Done. Updated curated.md at: $CURATED_FILE"
```

- [ ] **Step 2: Syntax check**

Run:
```bash
bash -n ~/Dev/conference-intern/scripts/register.sh
echo $?
```

Expected: `0` (no syntax errors).

- [ ] **Step 3: Commit**

```bash
cd ~/Dev/conference-intern
git add scripts/register.sh
git commit -m "feat: rewrite register.sh as script-driven loop controller

Replaces agent-driven event loop with bash-controlled iteration.
Each event gets its own openclaw agent call with 120s timeout.
Two-pass flow: register what you can, then collect custom field
answers and retry. Supports --retry-pending and --delay flags."
```

---

### Task 8: Update `SKILL.md` and `.gitignore`

**Files:**
- Modify: `SKILL.md:55-99` (File Locations, Agent Instructions, Error Handling sections)
- Modify: `.gitignore` (add custom-answers.json)

- [ ] **Step 1: Add `custom-answers.json` to `.gitignore`**

Add to `.gitignore`:

```
conferences/*/custom-answers.json
```

- [ ] **Step 2: Update SKILL.md File Locations section**

Add to the File Locations list after `luma-session.json`:

```markdown
- `custom-answers.json` — user answers to custom RSVP fields (reused across registrations)
```

And add to the top-level file list:

```markdown
- `luma-knowledge.md` — shared Luma page patterns (learned by agent, speeds up registration)
```

- [ ] **Step 3: Update SKILL.md Register error handling**

Replace the Register error handling section:

```markdown
**Register:**
- RSVP page fails → mark "failed" in curated.md, continue to next event.
- CAPTCHA detected → stop registration loop (session likely flagged), notify user.
- Event full/closed → mark "closed", continue.
- Session expired → stop registration loop, notify user to re-authenticate.
- Custom required fields → mark "needs-input", collect all such fields, ask user once per unique field after pass 1.
- Already registered → mark "registered" without interacting with the form.
```

- [ ] **Step 4: Update SKILL.md Stop Conditions**

Replace the Stop Conditions section:

```markdown
### Stop Conditions

The registration script stops the loop and asks the user when:
- CAPTCHA is detected (Luma likely flagged the session)
- Session expires mid-run
- Luma 2FA code is needed (user must paste from email)

The script pauses between passes to collect custom field answers:
- After pass 1 completes, unique custom field labels are collected and the user is prompted once per field
- Answers are saved and reused across re-runs
```

- [ ] **Step 5: Commit**

```bash
cd ~/Dev/conference-intern
git add SKILL.md .gitignore
git commit -m "docs: update SKILL.md for script-driven registration and add gitignore entry"
```

---

### Task 9: End-to-end dry run

**Files:** None (testing only)

- [ ] **Step 1: Syntax check all scripts**

Run:
```bash
cd ~/Dev/conference-intern
bash -n scripts/common.sh && echo "common.sh OK"
bash -n scripts/register.sh && echo "register.sh OK"
bash -n scripts/discover.sh && echo "discover.sh OK"
```

Expected: All three print `OK`.

- [ ] **Step 2: Test helper function integration**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh

# parse_registerable_events with test fixtures
echo "=== Parse test ==="
parse_registerable_events tests/fixtures/curated-sample.md tests/fixtures/events-sample.json all

# update_event_status
echo "=== Update test ==="
cp tests/fixtures/curated-sample.md /tmp/e2e-curated.md
update_event_status /tmp/e2e-curated.md "ZK Privacy Summit" "✅ Registered"
grep -A2 "ZK Privacy" /tmp/e2e-curated.md

# collect_unique_fields
echo "=== Collect fields test ==="
echo '{"Company": "test"}' > /tmp/e2e-answers.json
collect_unique_fields "$(printf 'Company,Role\nWallet Address')" /tmp/e2e-answers.json
```

Expected:
```
=== Parse test ===
ZK Privacy Summit	https://lu.ma/zk-privacy
Infra Roundtable	https://lu.ma/infra-rt
=== Update test ===
- **ZK Privacy Summit** — 14:00-18:00 @ Maison
  Host: PrivacyDAO | RSVPs: 234
  ✅ Registered
=== Collect fields test ===
Role
Wallet Address
```

- [ ] **Step 3: Verify register.sh argument parsing**

Run:
```bash
cd ~/Dev/conference-intern
# This will fail at "conference not found" but proves arg parsing works
bash scripts/register.sh test-conf --delay 10 2>&1 | head -1
bash scripts/register.sh test-conf --retry-pending 2>&1 | head -1
```

Expected: Both should show `[conference-intern] ERROR: Conference 'test-conf' not found...` (confirms args were parsed, just no test conference).

- [ ] **Step 4: Final commit (if any test-driven fixes were needed)**

```bash
cd ~/Dev/conference-intern
git status
# Only commit specific changed files if there are fixes
git diff --cached --quiet || git commit -m "fix: address issues found during end-to-end testing"
```
