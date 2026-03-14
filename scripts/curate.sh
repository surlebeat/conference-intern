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
