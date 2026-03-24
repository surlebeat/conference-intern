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

  # Clear previous result
  echo '{}' > "$RESULT_FILE"

  # Register using CLI browser commands (agent only for fuzzy field matching)
  cli_register_event "$RSVP_URL" "$RESULT_FILE" "$CUSTOM_ANSWERS" "$KNOWLEDGE_FILE"

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
  PASS2_COUNT=$(echo -n "$NEEDS_INPUT_EVENTS" | grep -c '.' || true)

  while IFS=$'\t' read -r EVENT_NAME RSVP_URL; do
    [ -z "$EVENT_NAME" ] && continue
    PASS2_NUM=$((PASS2_NUM + 1))

    log_info "[$PASS2_NUM/$PASS2_COUNT] $EVENT_NAME (retry with answers)"

    echo '{}' > "$RESULT_FILE"

    # Register using CLI browser commands with custom answers
    cli_register_event "$RSVP_URL" "$RESULT_FILE" "$CUSTOM_ANSWERS" "$KNOWLEDGE_FILE"

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
