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
