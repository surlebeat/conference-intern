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
    echo ""
    echo "IMPORTANT — Luma uses infinite scroll. You MUST scroll to load ALL events:"
    echo "  1. Take a snapshot and note how many events are visible"
    echo "  2. Scroll to the bottom of the page"
    echo "  3. Wait 1-2 seconds for new events to load"
    echo "  4. Take another snapshot and check if new events appeared"
    echo "  5. Repeat steps 2-4 until no new events load (same count as previous snapshot)"
    echo "  6. Only then extract events from the fully-loaded page"
    echo ""
    echo "READ: Extract ALL events from the fully-loaded page:"
    echo "  - Event name"
    echo "  - Date and time"
    echo "  - Location/venue"
    echo "  - Description (brief)"
    echo "  - Host/organizer"
    echo "  - RSVP URL (the link to register for this specific event)"
    echo "  - RSVP count (if visible)"
    echo "  - Source: luma"
    echo ""
    echo "After extracting all events from this page, close the tab."
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
