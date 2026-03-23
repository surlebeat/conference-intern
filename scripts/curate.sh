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

# Log summary
TOTAL_LISTED=$(grep -c "^- \*\*" "$CURATED_FILE" 2>/dev/null || echo "0")
BLOCKED_COUNT=$(grep -c "^- ~~" "$CURATED_FILE" 2>/dev/null || echo "0")

log_info "=== Curation Complete ==="
log_info "  Events listed: $TOTAL_LISTED"
log_info "  Blocked/filtered: $BLOCKED_COUNT"
log_info "  Saved to: $CURATED_FILE"
