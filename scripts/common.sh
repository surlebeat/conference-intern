#!/usr/bin/env bash
# Shared helpers for conference-intern scripts
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"
TEMPLATES_DIR="$SKILL_DIR/templates"

# Workspace detection — conference data and runtime files live here
WORKSPACE_DIR=$(jq -r '.agents.defaults.workspace // empty' ~/.openclaw/openclaw.json 2>/dev/null)
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/.openclaw/workspace}"
CONFERENCES_DIR="$WORKSPACE_DIR/conferences"
KNOWLEDGE_FILE="$WORKSPACE_DIR/luma-knowledge.md"

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

# Internal: look up an event's RSVP URL from events.json, filter to Luma URLs only
_resolve_and_output() {
  local event_name="$1"
  local events_file="$2"
  local rsvp_url
  rsvp_url=$(jq -r --arg name "$event_name" '
    .[] | select(.name == $name) | .rsvp_url // empty
  ' "$events_file" | head -1)

  # Only output Luma URLs (lu.ma or luma.com)
  if [ -n "$rsvp_url" ] && [[ "$rsvp_url" == *"lu.ma"* || "$rsvp_url" == *"luma.com"* ]]; then
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

# Register for a single Luma event using CLI browser commands.
# Agent is only called for fuzzy field matching when custom fields are present.
# Args: $1=rsvp_url, $2=result_file, $3=custom_answers_json (or empty), $4=knowledge_file
# Writes JSON result to $2.
cli_register_event() {
  local rsvp_url="$1"
  local result_file="$2"
  local custom_answers="${3:-}"
  local knowledge_file="${4:-}"

  # Known patterns
  local registered_patterns='["You'\''re registered", "You'\''re going", "Vous êtes inscrit", "View your ticket", "Voir votre billet", "You'\''re on the waitlist", "Vous êtes sur la liste"]'
  local register_btn_patterns='["register", "rsvp", "join", "participer", "s'\''inscrire", "request to join", "join waitlist", "request access"]'
  local closed_patterns='["sold out", "full", "closed", "registration closed", "complet", "event is full", "capacity reached"]'
  local captcha_patterns='["captcha", "recaptcha", "hcaptcha", "challenge"]'

  # Step 1: Open page
  local target_id
  target_id=$(openclaw browser open "$rsvp_url" --json 2>/dev/null | jq -r '.targetId // empty')
  if [ -z "$target_id" ]; then
    echo '{"status": "failed", "fields": [], "message": "Failed to open page"}' > "$result_file"
    return
  fi
  sleep 3

  # Step 2: Check already registered / closed / captcha
  local page_check
  page_check=$(openclaw browser evaluate --target-id "$target_id" --fn "() => {
    const text = document.body.innerText.toLowerCase();
    const registered = $registered_patterns;
    const closed = $closed_patterns;
    const captcha = $captcha_patterns;
    if (captcha.some(p => text.includes(p.toLowerCase()) || document.querySelector('iframe[src*=captcha], [class*=captcha], [class*=recaptcha]'))) return {status: 'captcha'};
    if (registered.some(p => text.includes(p.toLowerCase()))) return {status: 'registered'};
    if (closed.some(p => text.includes(p.toLowerCase()))) return {status: 'closed'};
    return {status: 'open'};
  }" 2>/dev/null)

  local page_status
  page_status=$(echo "$page_check" | jq -r '.status // "open"' 2>/dev/null)

  if [ "$page_status" = "registered" ]; then
    echo '{"status": "registered", "fields": [], "message": "Already registered"}' > "$result_file"
    openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi
  if [ "$page_status" = "closed" ]; then
    echo '{"status": "closed", "fields": [], "message": "Event full or registration closed"}' > "$result_file"
    openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi
  if [ "$page_status" = "captcha" ]; then
    echo '{"status": "captcha", "fields": [], "message": "CAPTCHA detected"}' > "$result_file"
    return
  fi

  # Step 3: Find and click Register button
  local btn_result
  btn_result=$(openclaw browser evaluate --target-id "$target_id" --fn "() => {
    const patterns = $register_btn_patterns;
    const btns = [...document.querySelectorAll('button, a[role=button], [class*=btn], [class*=button], a.action-button')];
    for (const btn of btns) {
      const text = (btn.textContent || '').trim().toLowerCase();
      if (patterns.some(p => text.includes(p))) {
        btn.click();
        return {found: true, text: btn.textContent.trim()};
      }
    }
    return {found: false};
  }" 2>/dev/null)

  local btn_found
  btn_found=$(echo "$btn_result" | jq -r '.found // false' 2>/dev/null)

  if [ "$btn_found" != "true" ]; then
    local agent_result
    agent_result=$(timeout 60 openclaw agent --session-id "regbtn-$(date +%s)-$RANDOM" --message "Open the browser tab with target ID $target_id. Find and click the registration/RSVP button on this Luma event page. Just click it and reply with 'clicked' or 'not found'. Do not fill any forms." 2>&1 | tail -1)
    if [[ "$agent_result" != *"clicked"* ]]; then
      echo '{"status": "failed", "fields": [], "message": "Could not find register button"}' > "$result_file"
      openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi
  fi

  sleep 2

  # Step 4: Extract form fields
  local fields_json
  fields_json=$(openclaw browser evaluate --target-id "$target_id" --fn '() => {
    const fields = [];
    document.querySelectorAll("input, select, textarea").forEach(el => {
      if (el.type === "hidden" || el.type === "submit") return;
      const label = (el.labels && el.labels[0] ? el.labels[0].textContent : "") ||
                    el.getAttribute("aria-label") ||
                    el.getAttribute("placeholder") ||
                    el.name || "";
      fields.push({
        label: label.trim(),
        type: el.type || el.tagName.toLowerCase(),
        required: el.required || el.getAttribute("aria-required") === "true",
        value: el.value || "",
        name: el.name || "",
        id: el.id || ""
      });
    });
    return fields;
  }' 2>/dev/null)

  if [ -z "$fields_json" ] || [ "$(echo "$fields_json" | jq 'length' 2>/dev/null)" = "0" ]; then
    echo '{"status": "failed", "fields": [], "message": "No form fields found after clicking register"}' > "$result_file"
    openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi

  # Step 5: Check for empty required fields
  local empty_required
  empty_required=$(echo "$fields_json" | jq '[.[] | select(.required == true and .value == "")]' 2>/dev/null)
  local empty_count
  empty_count=$(echo "$empty_required" | jq 'length' 2>/dev/null)
  [ -z "$empty_count" ] && empty_count=0

  if [ "$empty_count" -gt 0 ]; then
    if [ -n "$custom_answers" ] && [ "$custom_answers" != "(none)" ]; then
      # Step 6: Call agent for fuzzy field matching (text only)
      local match_prompt
      match_prompt=$(read_template "register-field-match-prompt.md")
      local empty_labels
      empty_labels=$(echo "$empty_required" | jq -r '.[].label' 2>/dev/null)

      local match_result
      match_result=$(timeout 30 openclaw agent --session-id "regmatch-$(date +%s)-$RANDOM" --message "$(printf '%s\n\nEMPTY REQUIRED FIELDS:\n%s\n\nAVAILABLE ANSWERS:\n%s' "$match_prompt" "$empty_labels" "$custom_answers")" 2>/dev/null | tail -1)

      local matches
      matches=$(echo "$match_result" | jq '.matches // {}' 2>/dev/null || echo '{}')
      local unknown
      unknown=$(echo "$match_result" | jq '.unknown // []' 2>/dev/null || echo '[]')

      if [ "$(echo "$unknown" | jq 'length' 2>/dev/null)" -gt 0 ]; then
        echo "{\"status\": \"needs-input\", \"fields\": $(echo "$unknown" | jq '.'), \"message\": \"Custom fields need answers\"}" > "$result_file"
        openclaw browser close --target-id "$target_id" 2>/dev/null || true
        return
      fi

      # Fill matched fields via CLI
      echo "$matches" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null | while IFS=$'\t' read -r label value; do
        openclaw browser evaluate --target-id "$target_id" --fn "(function() {
          const inputs = document.querySelectorAll('input, select, textarea');
          for (const el of inputs) {
            const lbl = (el.labels && el.labels[0] ? el.labels[0].textContent : '') ||
                        el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.name || '';
            if (lbl.trim() === $(jq -n --arg l "$label" '$l')) {
              el.value = $(jq -n --arg v "$value" '$v');
              el.dispatchEvent(new Event('input', {bubbles: true}));
              el.dispatchEvent(new Event('change', {bubbles: true}));
              return true;
            }
          }
          return false;
        })()" 2>/dev/null > /dev/null
      done
    else
      # No custom answers — report needs-input
      local field_labels
      field_labels=$(echo "$empty_required" | jq '[.[].label]')
      echo "{\"status\": \"needs-input\", \"fields\": $field_labels, \"message\": \"Custom fields need answers\"}" > "$result_file"
      openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi
  fi

  # Step 7: Click submit
  openclaw browser evaluate --target-id "$target_id" --fn '() => {
    const patterns = ["submit", "confirm", "envoyer", "join event", "register", "rsvp", "request to join"];
    const btns = [...document.querySelectorAll("button[type=submit], button, input[type=submit]")];
    for (const btn of btns) {
      const text = (btn.textContent || btn.value || "").trim().toLowerCase();
      if (patterns.some(p => text.includes(p))) { btn.click(); return true; }
    }
    const submit = document.querySelector("button[type=submit], input[type=submit]");
    if (submit) { submit.click(); return true; }
    return false;
  }' 2>/dev/null > /dev/null

  sleep 3

  # Step 8: Check confirmation
  local confirm_check
  confirm_check=$(openclaw browser evaluate --target-id "$target_id" --fn "() => {
    const text = document.body.innerText.toLowerCase();
    const confirmed = $registered_patterns;
    if (confirmed.some(p => text.includes(p.toLowerCase()))) return 'registered';
    return 'unknown';
  }" 2>/dev/null)

  confirm_check=$(echo "$confirm_check" | tr -d '"' 2>/dev/null)

  if [ "$confirm_check" = "registered" ]; then
    echo '{"status": "registered", "fields": [], "message": "Successfully registered"}' > "$result_file"
  else
    echo '{"status": "registered", "fields": [], "message": "Form submitted, confirmation unclear"}' > "$result_file"
  fi

  # Step 9: Close tab
  openclaw browser close --target-id "$target_id" 2>/dev/null || true
}
