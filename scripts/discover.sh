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
    if timeout 300 openclaw agent --session-id "discover-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
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
# Phase 2: Google Sheets (secondary source — browser extraction)
# ==========================================================
SHEETS=$(config_get "$CONFIG" '.sheets // [] | .[]' 2>/dev/null || true)

if [ -n "$SHEETS" ] && [ "$SHEETS" != "null" ]; then
  log_info "--- Google Sheets sources ---"
  SHEETS_EVENTS=0

  while IFS= read -r sheet_url; do
    [ -z "$sheet_url" ] || [ "$sheet_url" = "null" ] && continue
    log_info "Sheet: $sheet_url"

    echo '[]' > "$RESULT_FILE"

    SHEET_MSG="Open this Google Sheet in the browser and extract all event data.

URL: $sheet_url
RESULT_FILE: $RESULT_FILE

Read the spreadsheet and extract events. For each row, capture: name, date, time, location, description, host, rsvp_url, rsvp_count. Write a JSON array to the result file. Set source to \"sheets\" for all events. You MUST write to the exact path $RESULT_FILE. Close the tab when done."

    if timeout 300 openclaw agent --session-id "discover-$(date +%s)-$RANDOM" --message "$SHEET_MSG" > /dev/null 2>&1; then
      if [ -f "$RESULT_FILE" ] && jq 'type == "array"' "$RESULT_FILE" > /dev/null 2>&1; then
        SHEET_EVENTS=$(cat "$RESULT_FILE")
        SHEET_COUNT=$(echo "$SHEET_EVENTS" | jq 'length')
        log_info "  Found $SHEET_COUNT events"
      else
        log_warn "  Invalid or empty result — skipping"
        continue
      fi
    else
      EXIT_CODE=$?
      if [ "$EXIT_CODE" -eq 124 ]; then
        log_warn "  Agent timed out (300s) — skipping this sheet"
      else
        log_warn "  Agent exited with code $EXIT_CODE — skipping this sheet"
      fi
      continue
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
