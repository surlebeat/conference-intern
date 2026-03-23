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
