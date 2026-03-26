# Fix Curation and Closed Detection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix three root causes that prevented registration of 199/207 events: false closed detection, incomplete curation, and incorrect link markers.

**Architecture:** Button-based closed detection replaces text matching. Curation batches events into groups of 50 with JSON output for easy merging. Script (not agent) handles link markers based on URL. Manual registration list added to status file.

**Tech Stack:** Bash, jq, OpenClaw browser CLI, OpenClaw agent CLI

**Spec:** `docs/superpowers/specs/2026-03-26-fix-curation-and-closed-detection-design.md`

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `scripts/common.sh` | Modify | Rewrite closed detection in `cli_register_event()`, add `collect_non_luma_events()` |
| `scripts/curate.sh` | Rewrite | Batch curation with JSON output, merge, generate markdown with URL-based markers |
| `templates/curate-prompt.md` | Rewrite | JSON output format, no link markers, accept summary stats |
| `scripts/register.sh` | Modify | Add `manual_registration` to status file |
| `SKILL.md` | Modify | Add manual registration presentation step |

---

### Task 1: Rewrite `curate-prompt.md` for JSON output

**Files:**
- Rewrite: `templates/curate-prompt.md`

- [ ] **Step 1: Write the new prompt**

Replace entire contents of `templates/curate-prompt.md`:

```markdown
# Conference Intern — Curate Events (Batch)

You are curating a BATCH of events for a crypto conference attendee. Score, rank, and tier each event based on the provided preferences.

## Context (provided by script)

- **Strategy:** {STRATEGY}
- **Interests:** {INTERESTS}
- **Avoid:** {AVOID}
- **Blocked organizers:** {BLOCKED}
- **Summary stats:** {STATS} (use for calibration — you only see a subset of all events)
- **Result file:** {RESULT_FILE}

## Scoring Criteria

For each event, assess:

1. **Topic relevance** — how well does the event match the interest topics?
   - Strong match: event name/description directly relates to an interest topic
   - Weak match: tangentially related
   - No match: unrelated

2. **Quality signals**
   - Known/reputable host or speakers
   - High RSVP count (use the summary stats to calibrate — the stats show the range across ALL events, not just this batch)
   - Clear description and professional presentation

3. **Blocklist check**
   - If the host matches blocked organizers → tier: "blocked"
   - If the event topic matches avoid list → tier: "blocked"

## Strategy

**Aggressive:** Include most events that aren't blocked/avoided.
- must_attend: strong topic match + quality signals
- recommended: any topic match or good quality signals
- optional: no strong match but not blocked

**Conservative:** Only include events with strong topic relevance.
- must_attend: strong topic match + strong quality signals
- recommended: strong topic match
- Everything else → blocked

## Output Format

Write a JSON array to `{RESULT_FILE}`. Each element:

```json
[
  {
    "name": "Event Name (exact match from input)",
    "tier": "must_attend|recommended|optional|blocked",
    "reason": "One sentence why"
  }
]
```

**IMPORTANT:**
- You MUST include EVERY event from the input — do not skip any
- Use the exact event name from the input (do not rename or truncate)
- Write ONLY the JSON array to the result file, nothing else
- Do NOT write markdown — the script generates markdown from your JSON
```

- [ ] **Step 2: Verify readable**

```bash
source scripts/common.sh && read_template "curate-prompt.md" | head -3
```

- [ ] **Step 3: Commit**

```bash
git add templates/curate-prompt.md
git commit -m "feat: rewrite curate prompt for JSON batch output

Agent outputs JSON array of {name, tier, reason} instead of markdown.
No link markers — script handles those. Accepts summary stats for
cross-batch calibration. Must include every event.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Rewrite `curate.sh` for batch curation

**Files:**
- Rewrite: `scripts/curate.sh`

- [ ] **Step 1: Write the new curate.sh**

Replace entire contents of `scripts/curate.sh`:

```bash
#!/usr/bin/env bash
# Conference Intern — Curate Events (Batch Processing)
# Usage: bash scripts/curate.sh <conference-id>
#
# Splits events into batches of 50, calls agent per batch for JSON scoring,
# merges results, generates curated.md with URL-based link markers.

set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFERENCE_ID=$(require_conference_id "${1:-}")
CONF_DIR=$(get_conf_dir "$CONFERENCE_ID")
CONFIG=$(load_config "$CONF_DIR")

EVENTS_FILE="$CONF_DIR/events.json"
CURATED_FILE="$CONF_DIR/curated.md"
CURATE_PROMPT=$(read_template "curate-prompt.md")

BATCH_SIZE=50

if [ ! -f "$EVENTS_FILE" ]; then
  log_error "No events.json found. Run discover first: bash scripts/discover.sh $CONFERENCE_ID"
  exit 1
fi

EVENT_COUNT=$(jq 'length' "$EVENTS_FILE")
if [ "$EVENT_COUNT" -eq 0 ]; then
  log_warn "No events found in events.json. Nothing to curate."
  exit 0
fi

CONF_NAME=$(config_get "$CONFIG" '.name')
STRATEGY=$(config_get "$CONFIG" '.preferences.strategy')
INTERESTS=$(config_get "$CONFIG" '.preferences.interests | join(", ")')
AVOID=$(config_get "$CONFIG" '.preferences.avoid | join(", ")')
BLOCKED=$(config_get "$CONFIG" '.preferences.blocked_organizers | join(", ")')

log_info "Curating $EVENT_COUNT events for: $CONF_NAME"
log_info "Strategy: $STRATEGY | Batch size: $BATCH_SIZE"

# Compute summary stats for cross-batch calibration
STATS=$(jq '{
  total_events: length,
  rsvp_min: ([.[].rsvp_count | select(. != null)] | if length > 0 then min else 0 end),
  rsvp_max: ([.[].rsvp_count | select(. != null)] | if length > 0 then max else 0 end),
  rsvp_median: ([.[].rsvp_count | select(. != null)] | sort | if length > 0 then .[length/2 | floor] else 0 end),
  dates: ([.[].date] | unique | sort)
}' "$EVENTS_FILE")

log_info "Stats: $(echo "$STATS" | jq -c '{total: .total_events, rsvp_range: "\(.rsvp_min)-\(.rsvp_max)"}')"

# --- Batch curation ---
RESULT_FILE=$(mktemp)
ALL_RESULTS="[]"
trap 'rm -f "$RESULT_FILE"' EXIT

BATCH_NUM=0
OFFSET=0

while [ "$OFFSET" -lt "$EVENT_COUNT" ]; do
  BATCH_NUM=$((BATCH_NUM + 1))
  BATCH_END=$((OFFSET + BATCH_SIZE))
  [ "$BATCH_END" -gt "$EVENT_COUNT" ] && BATCH_END="$EVENT_COUNT"
  BATCH_COUNT=$((BATCH_END - OFFSET))

  log_info "Batch $BATCH_NUM: events $((OFFSET + 1))-$BATCH_END of $EVENT_COUNT"

  # Extract batch
  BATCH_JSON=$(jq ".[$OFFSET:$BATCH_END]" "$EVENTS_FILE")

  # Build message
  echo '[]' > "$RESULT_FILE"

  MESSAGE="Curate this batch of events. Write the JSON result to the specified file.

STRATEGY: $STRATEGY
INTERESTS: $INTERESTS
AVOID: $AVOID
BLOCKED_ORGANIZERS: $BLOCKED
STATS: $STATS
RESULT_FILE: $RESULT_FILE

EVENTS ($BATCH_COUNT in this batch, $EVENT_COUNT total):
$BATCH_JSON

$CURATE_PROMPT"

  if timeout 300 openclaw agent --session-id "curate-$(date +%s)-$RANDOM" --message "$MESSAGE" > /dev/null 2>&1; then
    log_info "  Agent completed"
  else
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 124 ]; then
      log_error "  Batch $BATCH_NUM timed out (300s)"
    else
      log_error "  Batch $BATCH_NUM failed with exit code $EXIT_CODE"
    fi
    OFFSET=$BATCH_END
    continue
  fi

  # Read and validate batch result
  if [ -f "$RESULT_FILE" ] && jq 'type == "array"' "$RESULT_FILE" > /dev/null 2>&1; then
    BATCH_RESULT_COUNT=$(jq 'length' "$RESULT_FILE")
    log_info "  Scored $BATCH_RESULT_COUNT events"
    ALL_RESULTS=$(echo "$ALL_RESULTS" | jq --slurpfile batch "$RESULT_FILE" '. + $batch[0]')
  else
    log_warn "  Invalid result — skipping batch"
  fi

  OFFSET=$BATCH_END
  sleep 5  # delay between batches
done

TOTAL_SCORED=$(echo "$ALL_RESULTS" | jq 'length')
log_info "Total scored: $TOTAL_SCORED / $EVENT_COUNT"

if [ "$TOTAL_SCORED" -eq 0 ]; then
  log_error "No events were scored. Curation failed."
  exit 1
fi

# --- Generate curated.md from merged JSON ---
log_info "Generating curated.md..."

python3 -c "
import json, sys
from datetime import datetime

events_file = '$EVENTS_FILE'
results_json = sys.stdin.read()
conf_name = '$CONF_NAME'
strategy = '$STRATEGY'

with open(events_file) as f:
    events = json.load(f)

results = json.loads(results_json)
events_by_name = {e['name']: e for e in events}
results_by_name = {r['name']: r for r in results}

# Merge: for each result, attach event details
merged = []
for r in results:
    e = events_by_name.get(r['name'], {})
    merged.append({**e, 'tier': r.get('tier', 'optional'), 'reason': r.get('reason', '')})

# Add events not in results (agent dropped them) as 'optional'
scored_names = set(r['name'] for r in results)
for e in events:
    if e['name'] not in scored_names:
        merged.append({**e, 'tier': 'optional', 'reason': 'Not scored by curation agent'})

# Group by date then tier
from collections import defaultdict
by_date = defaultdict(lambda: defaultdict(list))
blocked = []
for e in merged:
    if e['tier'] == 'blocked':
        blocked.append(e)
    else:
        date = e.get('date', 'Unknown')
        by_date[date][e['tier']].append(e)

# Determine link marker based on URL
def link_marker(e):
    url = e.get('rsvp_url', '') or ''
    if 'luma.com' in url or 'lu.ma' in url:
        return ''
    elif url:
        return f'  🔗 [Register manually]({url})'
    else:
        return '  🔗 No registration link'

# Render markdown
tier_order = ['must_attend', 'recommended', 'optional']
tier_labels = {'must_attend': 'Must Attend', 'recommended': 'Recommended', 'optional': 'Optional'}

lines = []
lines.append(f'# {conf_name} — Side Events')
lines.append(f'')
now = datetime.utcnow().strftime('%Y-%m-%d %H:%M')
total = len(merged)
recommended = sum(1 for e in merged if e['tier'] in ('must_attend', 'recommended'))
lines.append(f'Last updated: {now} UTC')
lines.append(f'Strategy: {strategy} | Events: {total} found, {recommended} recommended')
lines.append('')

for date in sorted(by_date.keys()):
    lines.append(f'## {date}')
    lines.append('')
    tiers = by_date[date]
    for tier in tier_order:
        if tier in tiers and tiers[tier]:
            lines.append(f'### {tier_labels[tier]}')
            for e in sorted(tiers[tier], key=lambda x: x.get('time', '')):
                name = e.get('name', '?')
                time = e.get('time', '')
                location = e.get('location', '')
                host = e.get('host', '')
                rsvp_count = e.get('rsvp_count')
                at_loc = f' @ {location}' if location else ''
                lines.append(f'- **{name}** — {time}{at_loc}')
                host_line = f'  Host: {host}' if host else ''
                if rsvp_count:
                    host_line += f' | RSVPs: {rsvp_count}'
                if host_line:
                    lines.append(host_line)
                marker = link_marker(e)
                if marker:
                    lines.append(marker)
            lines.append('')

if blocked:
    lines.append('## Blocked / Filtered Out')
    for e in blocked:
        lines.append(f'- ~~{e.get(\"name\", \"?\")}~~ — {e.get(\"reason\", \"blocked\")}')
    lines.append('')

print('\n'.join(lines))
" <<< "$ALL_RESULTS" > "$CURATED_FILE"

# Verify
TOTAL_LISTED=$(grep -c "^- \*\*" "$CURATED_FILE" 2>/dev/null || echo "0")
BLOCKED_COUNT=$(grep -c "^- ~~" "$CURATED_FILE" 2>/dev/null || echo "0")
MANUAL_COUNT=$(grep -c "🔗" "$CURATED_FILE" 2>/dev/null || echo "0")

log_info "=== Curation Complete ==="
log_info "  Events listed: $TOTAL_LISTED"
log_info "  Blocked/filtered: $BLOCKED_COUNT"
log_info "  Manual registration: $MANUAL_COUNT"
log_info "  Saved to: $CURATED_FILE"
```

- [ ] **Step 2: Syntax check**

```bash
bash -n scripts/curate.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/curate.sh
git commit -m "feat: batch curation with JSON output and URL-based link markers

Splits events into batches of 50, agent outputs JSON per batch,
script merges and generates markdown. Link markers based on URL
(not source). Events dropped by agent default to 'optional'.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Rewrite closed detection in `cli_register_event()`

**Files:**
- Modify: `scripts/common.sh` (lines 335-380 of `cli_register_event`)

- [ ] **Step 1: Replace the detection block**

In `cli_register_event()`, replace the patterns and steps 2-3 (lines 335-400) with button-based logic. Remove `closed_patterns`. The new flow: check registered → check captcha → look for register button → look for waitlist → check for closed indicator → fail if unclear.

Replace from `# Known patterns` through the end of `# Step 3: Find and click Register button` section (up to `sleep 2  # wait for form to appear`) with:

```bash
  # Known patterns
  local registered_patterns='["You'\''re registered", "You'\''re going", "Vous êtes inscrit", "View your ticket", "Voir votre billet", "You'\''re on the waitlist", "Vous êtes sur la liste"]'
  local register_btn_patterns='["register", "rsvp", "join", "participer", "s'\''inscrire", "request to join", "join waitlist", "request access", "demander", "liste d'\''attente"]'
  local captcha_patterns='["recaptcha", "hcaptcha"]'

  # Step 1: Open page
  local target_id
  target_id=$(openclaw browser open "$rsvp_url" --json 2>/dev/null | jq -r '.targetId // empty')
  if [ -z "$target_id" ]; then
    echo '{"status": "failed", "fields": [], "message": "Failed to open page"}' > "$result_file"
    return
  fi
  sleep 3

  # Step 2: Check already registered + captcha (full-text OK — these patterns are specific enough)
  local page_check
  page_check=$(openclaw browser evaluate --target-id "$target_id" --fn "() => {
    const body = document.body;
    const text = (body && body.innerText ? body.innerText : '').toLowerCase();
    const registered = $registered_patterns;
    const captcha = $captcha_patterns;
    if (document.querySelector('iframe[src*=captcha], iframe[src*=recaptcha], iframe[src*=hcaptcha], [class*=captcha], [class*=recaptcha], [class*=hcaptcha]') || captcha.some(p => text.includes(p.toLowerCase()))) return {status: 'captcha'};
    if (registered.some(p => text.includes(p.toLowerCase()))) return {status: 'registered'};
    return {status: 'open'};
  }" 2>/dev/null)

  local page_status
  page_status=$(echo "$page_check" | jq -r '.status // "open"' 2>/dev/null)

  if [ "$page_status" = "registered" ]; then
    echo '{"status": "registered", "fields": [], "message": "Already registered"}' > "$result_file"
    openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true; sleep 1; openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi
  if [ "$page_status" = "captcha" ]; then
    echo '{"status": "captcha", "fields": [], "message": "CAPTCHA detected"}' > "$result_file"
    return
  fi

  # Step 3: Find and click Register/RSVP/Waitlist button
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
    # No button found — try agent fallback
    local agent_result
    agent_result=$(timeout 60 openclaw agent --session-id "regbtn-$(date +%s)-$RANDOM" --message "Open the browser tab with target ID $target_id. Find and click the registration/RSVP/waitlist button on this Luma event page. Just click it and reply with 'clicked' or 'not found'. Do not fill any forms." 2>&1 | tail -1)
    if [[ "$agent_result" != *"clicked"* ]] && [[ "$agent_result" != *"Clicked"* ]]; then
      # No button even with agent help — check if event is closed
      local closed_check
      closed_check=$(openclaw browser evaluate --target-id "$target_id" --fn '() => {
        const body = document.body;
        if (!body) return {closed: false};
        const text = body.innerText || "";
        const closedPhrases = [
          "cet événement affiche complet",
          "this event is sold out",
          "sold out",
          "registration closed",
          "inscriptions fermées",
          "event is full",
          "capacity reached"
        ];
        const lowerText = text.toLowerCase();
        for (const phrase of closedPhrases) {
          if (lowerText.includes(phrase)) return {closed: true, phrase: phrase};
        }
        return {closed: false};
      }' 2>/dev/null)

      local is_closed
      is_closed=$(echo "$closed_check" | jq -r '.closed // false' 2>/dev/null)

      if [ "$is_closed" = "true" ]; then
        echo '{"status": "closed", "fields": [], "message": "Event is full or registration closed"}' > "$result_file"
      else
        echo '{"status": "failed", "fields": [], "message": "Could not find register button"}' > "$result_file"
      fi
      openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true; sleep 1; openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi
  fi

  sleep 2  # wait for form to appear
```

- [ ] **Step 2: Syntax check**

```bash
bash -n scripts/common.sh && echo "OK"
```

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "fix: button-based closed detection, remove generic text matching

No longer searches full page text for 'full', 'closed', 'complet'.
Instead: look for register button → agent fallback → check specific
closed phrases only when no button found at all. Prevents false
'closed' on events with 'full-day' or 'profil complet' text.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Add `collect_non_luma_events()` and manual registration list

**Files:**
- Modify: `scripts/common.sh` (append function)
- Modify: `scripts/register.sh` (add to status file)

- [ ] **Step 1: Add function to common.sh**

Append to `scripts/common.sh`:

```bash
# Collect events with non-Luma URLs from events.json.
# Returns JSON array of {name, url} for manual registration.
# Args: $1 = events.json path
collect_non_luma_events() {
  local events_file="$1"
  jq '[.[] | select(.rsvp_url != null and .rsvp_url != "" and (.rsvp_url | (contains("luma.com") or contains("lu.ma")) | not)) | {name: .name, url: .rsvp_url}]' "$events_file" 2>/dev/null || echo "[]"
}
```

- [ ] **Step 2: Add to register.sh status file**

In `scripts/register.sh`, find the `jq -n` block that writes the status file (around line 200). Add `manual_registration` to the JSON. Replace the entire `jq -n` block:

Find:
```bash
jq -n \
  --argjson batch_size "$BATCH_SIZE" \
```

Add before the `jq -n` line:

```bash
# Collect non-Luma events for manual registration
MANUAL_REG=$(collect_non_luma_events "$EVENTS_FILE")
```

Then add to the jq command, after `--argjson done "$DONE"`:

```bash
  --argjson manual "$MANUAL_REG" \
```

And add to the JSON template body, after `done: $done`:

```bash
    manual_registration: $manual,
```

- [ ] **Step 3: Syntax check**

```bash
bash -n scripts/common.sh && echo "common OK"
bash -n scripts/register.sh && echo "register OK"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh scripts/register.sh
git commit -m "feat: collect non-Luma events for manual registration list

New collect_non_luma_events() returns events with non-Luma URLs.
register.sh includes them in registration-status.json so the agent
can present them to the user as a checklist.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Update SKILL.md + sync + push + publish

**Files:**
- Modify: `SKILL.md`

- [ ] **Step 1: Add manual registration step to SKILL.md**

In `SKILL.md`, find the registration batch flow section (around line 85). After step 6 (`run register.sh --retry-pending`), add:

```markdown
7. Read `registration-status.json` — if `manual_registration` is not empty, present the list to the user:
   "These events need manual registration (not on Luma):"
   - [Event Name](url)
   - [Event Name](url)
8. Report final results to the user
```

(Renumber old step 7 to 8)

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "docs: add manual registration list presentation step

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 3: Sync to installed skill + clawhub**

```bash
DEST=/home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern
cp scripts/common.sh "$DEST/scripts/common.sh"
cp scripts/curate.sh "$DEST/scripts/curate.sh"
cp scripts/register.sh "$DEST/scripts/register.sh"
cp templates/curate-prompt.md "$DEST/templates/curate-prompt.md"
cp SKILL.md "$DEST/SKILL.md"
CLAWHUB=~/Dev/conference-intern-clawhub
cp scripts/common.sh "$CLAWHUB/scripts/common.sh"
cp scripts/curate.sh "$CLAWHUB/scripts/curate.sh"
cp scripts/register.sh "$CLAWHUB/scripts/register.sh"
cp templates/curate-prompt.md "$CLAWHUB/templates/curate-prompt.md"
cp SKILL.md "$CLAWHUB/SKILL.md"
echo "Synced"
```

- [ ] **Step 4: Clean stale data + restart**

```bash
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/events.json
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/curated.md
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/custom-answers.json
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/registration-status.json
systemctl --user restart openclaw-gateway
sleep 2
openclaw health
echo "Ready for fresh pipeline run"
```

- [ ] **Step 5: Push, PR, merge**

```bash
cd ~/Dev/conference-intern
git push
gh pr create --title "fix: batch curation, button-based closed detection, manual registration list" --body "$(cat <<'PREOF'
## Summary

Three verified root causes fixed:

1. **False closed detection** — removed generic text matching ("full", "complet").
   Now button-based: only marks closed when no register button exists AND
   specific closed phrases found.

2. **Curation dropping events** — split into batches of 50 with JSON output.
   Script merges and generates markdown. Events dropped by agent default
   to "optional".

3. **Incorrect link markers** — script determines 🔗 based on URL, not the
   agent. Non-Luma URLs get manual registration links.

Plus: manual registration list in status file for non-Luma events.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PREOF
)"
gh pr merge --merge
```

- [ ] **Step 6: Publish to ClawHub**

```bash
clawhub publish ~/Dev/conference-intern-clawhub --slug conference-intern --name "Conference Intern" --version 2.0.0 --changelog "Batch curation (50/call), button-based closed detection, URL-based link markers, manual registration list"
```
