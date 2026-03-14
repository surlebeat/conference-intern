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
