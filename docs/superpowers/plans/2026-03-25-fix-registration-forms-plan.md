# Fix Registration Form Handling — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix false registrations (Luma forms are custom React, CLI can't fill them), duplicate event loops, and hand form-filling to the agent while CLI handles open/close/status checks.

**Architecture:** CLI opens page, checks status, clicks register. Agent fills the form visually (90s timeout). CLI reads result, closes tab. Duplicate events fixed in both `update_event_status` and `parse_registerable_events`. New `submitted` status for ambiguous confirmations.

**Tech Stack:** Bash, jq, OpenClaw browser CLI, OpenClaw agent CLI

**Spec:** `docs/superpowers/specs/2026-03-25-fix-registration-forms-design.md`

---

## File Map

| File | Action | What changes |
|------|--------|-------------|
| `templates/register-single-prompt.md` | Rewrite | Form-fill-only prompt (no page opening, no button finding) |
| `scripts/common.sh` | Modify | Rewrite `cli_register_event()`, fix `update_event_status()`, fix `parse_registerable_events()` |
| `scripts/register.sh` | Modify | Add `submitted` status to case statement |

---

### Task 1: Rewrite `register-single-prompt.md` as form-fill-only

**Files:**
- Rewrite: `templates/register-single-prompt.md`

- [ ] **Step 1: Write the new prompt**

Replace entire contents of `templates/register-single-prompt.md` with:

```markdown
# Conference Intern — Fill Registration Form

A Luma event registration page is already open in the browser. The Register button has already been clicked. Your ONLY job is to fill the form and submit it.

## Context (provided by script)

- **Browser tab target ID:** {TARGET_ID}
- **User name:** {USER_NAME}
- **User email:** {USER_EMAIL}
- **Custom answers:** {CUSTOM_ANSWERS}
- **Result file:** {RESULT_FILE}

## CONSTRAINTS

- Do NOT open any pages or navigate anywhere — the tab is already open.
- Do NOT read knowledge files or session files — just look at the form.
- Do NOT close the tab — the script handles that.
- Be fast — you have 90 seconds.

## Steps

1. **Take a snapshot** of the browser tab (target ID: {TARGET_ID}) to see the current form.

2. **Check if already registered** — if the page shows confirmation text (e.g., "You're registered", "You're going", "Vous êtes inscrit"), write `{"status": "registered", "fields": [], "message": "Already registered"}` to `{RESULT_FILE}` and stop.

3. **Check if no form is visible** — some events are one-click RSVP or approval-only. If there's a confirmation or "request sent" message with no form fields, write `{"status": "submitted", "fields": [], "message": "One-click registration, no form"}` to `{RESULT_FILE}` and stop.

4. **Read the form** — identify all visible fields. Luma uses custom React components, NOT native HTML inputs. Look at the page visually, not the DOM.

5. **Fill mandatory fields:**
   - Name → use `{USER_NAME}`
   - Email → use `{USER_EMAIL}`
   - Fields matching answers in `{CUSTOM_ANSWERS}` → use the matching answer (fuzzy match by meaning, not exact label)
   - **Promotional/marketing dropdowns** (newsletter signup, "interested in our services?", audit offers, etc.) → always select "No" or the negative/opt-out option
   - Required fields you can't fill and aren't promotional → these are real custom fields, report as needs-input

6. **If there are unfillable required fields** → write `{"status": "needs-input", "fields": ["Field Label 1", "Field Label 2"], "message": "Custom fields need answers"}` to `{RESULT_FILE}` and stop. Do NOT submit an incomplete form.

7. **Submit the form** — click the submit/confirm/register button.

8. **Check confirmation:**
   - If you see clear confirmation text ("You're registered!", "Registration confirmed", "Inscription confirmée") → status: `registered`
   - If confirmation is unclear or you're not sure → status: `submitted` (NOT "registered")

9. **Write result** to `{RESULT_FILE}` and stop.

## Result Format

Write ONLY a JSON object to `{RESULT_FILE}`:

```json
{
  "status": "registered|submitted|needs-input|failed|closed|captcha|session-expired",
  "fields": [],
  "message": "Brief note"
}
```

**Write the JSON and stop. No summary, no follow-up.**
```

- [ ] **Step 2: Verify readable**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
read_template "register-single-prompt.md" | head -3
```

- [ ] **Step 3: Commit**

```bash
git add templates/register-single-prompt.md
git commit -m "feat: rewrite register prompt as form-fill-only (no page navigation)

Agent gets an already-open tab and just fills/submits the form.
Promotional dropdowns default to No. Ambiguous confirmation
reports 'submitted' not 'registered' to avoid false positives.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Fix `parse_registerable_events()` deduplication

**Files:**
- Modify: `scripts/common.sh` (lines 110-152)

- [ ] **Step 1: Add deduplication**

In `parse_registerable_events()`, add a `declare -A seen` array at the top, and wrap the `_resolve_and_output` calls with a dedup check.

Replace the function (lines 110-152) with:

```bash
parse_registerable_events() {
  local curated_file="$1"
  local events_file="$2"
  local mode="${3:-all}"

  local current_event=""
  local skip_event=false
  local found_pending=false
  local -A seen=()

  while IFS= read -r line; do
    if [[ "$line" =~ ^-\ \*\*(.+)\*\*\ — ]]; then
      if [ -n "$current_event" ] && [ "$skip_event" = false ]; then
        if [ "$mode" = "all" ] || [ "$found_pending" = true ]; then
          if [ -z "${seen[$current_event]+x}" ]; then
            _resolve_and_output "$current_event" "$events_file"
            seen["$current_event"]=1
          fi
        fi
      fi
      current_event="${BASH_REMATCH[1]}"
      skip_event=false
      found_pending=false
    elif [ -n "$current_event" ] && [ "$skip_event" = false ]; then
      if [[ "$line" =~ ✅|❌|🚫|🔗 ]]; then
        skip_event=true
      fi
      if [[ "$line" =~ ⏳ ]]; then
        found_pending=true
      fi
    fi
  done < "$curated_file"

  if [ -n "$current_event" ] && [ "$skip_event" = false ]; then
    if [ "$mode" = "all" ] || [ "$found_pending" = true ]; then
      if [ -z "${seen[$current_event]+x}" ]; then
        _resolve_and_output "$current_event" "$events_file"
      fi
    fi
  fi
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/common.sh && echo "OK"`

- [ ] **Step 3: Test dedup**

Run:
```bash
cd ~/Dev/conference-intern
source scripts/common.sh
parse_registerable_events tests/fixtures/curated-sample.md tests/fixtures/events-sample.json all | sort | uniq -d
```

Expected: no output (no duplicates).

- [ ] **Step 4: Commit**

```bash
git add scripts/common.sh
git commit -m "fix: deduplicate parse_registerable_events output

Prevents infinite loop when same event appears multiple times
in curated.md (from Luma + Sheets sources).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Fix `update_event_status()` for duplicates

**Files:**
- Modify: `scripts/common.sh` (lines 172-239)

- [ ] **Step 1: Change `done` state to continue scanning**

Replace the `update_event_status` function (lines 172-239) with a version that resets to `scanning` after writing status, so it finds and updates ALL occurrences:

```bash
update_event_status() {
  local curated_file="$1"
  local event_name="$2"
  local new_status="$3"
  local tmp_file
  tmp_file=$(mktemp)

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
        if [[ "$line" =~ ^[[:space:]]+Host: ]]; then
          echo "$line" >> "$tmp_file"
          state="past_host"
        elif [[ "$line" =~ ^[[:space:]]+(✅|❌|🚫|🔗|🛑|🔒|⏳) ]]; then
          echo "  $new_status" >> "$tmp_file"
          state="scanning"  # continue scanning for more occurrences
        elif [[ "$line" == -* ]] || [[ ! "$line" =~ ^[[:space:]] ]]; then
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="scanning"
        else
          echo "$line" >> "$tmp_file"
        fi
        ;;
      past_host)
        if [[ "$line" =~ ^[[:space:]]+(✅|❌|🚫|🔗|🛑|🔒|⏳) ]]; then
          echo "  $new_status" >> "$tmp_file"
          state="scanning"
        elif [[ "$line" == -* ]] || [[ ! "$line" =~ ^[[:space:]] ]] || [ -z "$line" ]; then
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="scanning"
        else
          echo "  $new_status" >> "$tmp_file"
          echo "$line" >> "$tmp_file"
          state="scanning"
        fi
        ;;
    esac
  done < "$curated_file"

  if [ "$state" != "scanning" ]; then
    echo "  $new_status" >> "$tmp_file"
  fi

  mv "$tmp_file" "$curated_file"
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/common.sh && echo "OK"`

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "fix: update_event_status marks ALL duplicate occurrences

Resets state to scanning after writing status instead of stopping
at the first match. Prevents duplicate events from being unmarked.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Rewrite `cli_register_event()` for CLI+agent hybrid

**Files:**
- Modify: `scripts/common.sh` (lines 339-546)

- [ ] **Step 1: Replace the function**

Replace the entire `cli_register_event()` function with the new hybrid version. The CLI handles open/status/button, the agent handles form fill:

```bash
cli_register_event() {
  local rsvp_url="$1"
  local result_file="$2"
  local custom_answers="${3:-}"
  local knowledge_file="${4:-}"

  # Known patterns
  local registered_patterns='["You'\''re registered", "You'\''re going", "Vous êtes inscrit", "View your ticket", "Voir votre billet", "You'\''re on the waitlist", "Vous êtes sur la liste"]'
  local register_btn_patterns='["register", "rsvp", "join", "participer", "s'\''inscrire", "request to join", "join waitlist", "request access", "demander"]'
  local closed_patterns='["sold out", "full", "closed", "registration closed", "complet", "event is full", "capacity reached"]'
  local captcha_patterns='["recaptcha", "hcaptcha"]'

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
    const body = document.body;
    const text = (body && body.innerText ? body.innerText : '').toLowerCase();
    const registered = $registered_patterns;
    const closed = $closed_patterns;
    const captcha = $captcha_patterns;
    if (document.querySelector('iframe[src*=captcha], iframe[src*=recaptcha], iframe[src*=hcaptcha], [class*=captcha], [class*=recaptcha], [class*=hcaptcha]') || captcha.some(p => text.includes(p.toLowerCase()))) return {status: 'captcha'};
    if (registered.some(p => text.includes(p.toLowerCase()))) return {status: 'registered'};
    if (closed.some(p => text.includes(p.toLowerCase()))) return {status: 'closed'};
    return {status: 'open'};
  }" 2>/dev/null)

  local page_status
  page_status=$(echo "$page_check" | jq -r '.status // "open"' 2>/dev/null)

  if [ "$page_status" = "registered" ]; then
    echo '{"status": "registered", "fields": [], "message": "Already registered"}' > "$result_file"
    openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true; sleep 1; openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi
  if [ "$page_status" = "closed" ]; then
    echo '{"status": "closed", "fields": [], "message": "Event full or registration closed"}' > "$result_file"
    openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true; sleep 1; openclaw browser close --target-id "$target_id" 2>/dev/null || true
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
    if [[ "$agent_result" != *"clicked"* ]] && [[ "$agent_result" != *"Clicked"* ]]; then
      echo '{"status": "failed", "fields": [], "message": "Could not find register button"}' > "$result_file"
      openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true; sleep 1; openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi
  fi

  sleep 2  # wait for form to appear

  # Step 4: Hand off to agent for form filling
  local form_prompt
  form_prompt=$(read_template "register-single-prompt.md")

  local user_name="${USER_NAME:-}"
  local user_email="${USER_EMAIL:-}"

  local message="Fill and submit this Luma registration form.

TARGET_ID: $target_id
USER_NAME: $user_name
USER_EMAIL: $user_email
CUSTOM_ANSWERS: ${custom_answers:-(none)}
RESULT_FILE: $result_file

$form_prompt"

  if timeout 90 openclaw agent --session-id "regform-$(date +%s)-$RANDOM" --message "$message" > /dev/null 2>&1; then
    log_info "  Form agent completed"
  else
    local exit_code=$?
    if [ "$exit_code" -eq 124 ]; then
      log_warn "  Form agent timed out (90s)"
    else
      log_warn "  Form agent exited with code $exit_code"
    fi
  fi

  # Check if agent wrote a valid result
  local result_status
  result_status=$(jq -r '.status // ""' "$result_file" 2>/dev/null)
  if [ -z "$result_status" ] || [ "$result_status" = "" ] || [ "$result_status" = "null" ]; then
    echo '{"status": "failed", "fields": [], "message": "Agent did not write result"}' > "$result_file"
  fi

  # Step 5: Close tab (agent doesn't handle this)
  openclaw browser navigate --target-id "$target_id" "about:blank" 2>/dev/null || true
  sleep 1
  openclaw browser close --target-id "$target_id" 2>/dev/null || true
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/common.sh && echo "OK"`

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: CLI+agent hybrid registration — agent fills forms visually

CLI handles open/status-check/button-click/close. Agent handles
form reading and filling (custom React components). 90s timeout.
Promotional dropdowns default to No. Tab cleanup always by CLI.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Add `submitted` status to `register.sh`

**Files:**
- Modify: `scripts/register.sh` (case statement around line 133)

- [ ] **Step 1: Add submitted case**

In `register.sh`, find the `case "$STATUS" in` block and add `submitted)` as a new non-terminal status. It should be treated like a successful attempt that needs verification on next run:

After the `registered)` case and before `needs-input)`, add:

```bash
    submitted)
      update_event_status "$CURATED_FILE" "$EVENT_NAME" "📝 Submitted"
      REGISTERED=$((REGISTERED + 1))  # count as progress
      ;;
```

Also add `📝` to the terminal markers check in `parse_registerable_events` — actually NO: `submitted` is non-terminal. The event should be retried on next run, where it will either show "already registered" or the form again.

But we need to make sure `📝` is NOT in the terminal markers regex in `parse_registerable_events`. Check that the terminal markers are: `✅|❌|🚫|🔗`. `📝` is not there, so submitted events will be retried. Good.

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/register.sh && echo "OK"`

- [ ] **Step 3: Commit**

```bash
git add scripts/register.sh
git commit -m "feat: add 'submitted' status for ambiguous confirmations

Non-terminal — event gets retried on next run. If actually
registered, retry detects 'already registered' text.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Sync, push, merge, publish

- [ ] **Step 1: Syntax check all**

```bash
cd ~/Dev/conference-intern
bash -n scripts/common.sh && echo "common OK"
bash -n scripts/register.sh && echo "register OK"
```

- [ ] **Step 2: Sync**

```bash
DEST=/home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern
cp scripts/common.sh "$DEST/scripts/common.sh"
cp scripts/register.sh "$DEST/scripts/register.sh"
cp templates/register-single-prompt.md "$DEST/templates/register-single-prompt.md"
cp scripts/common.sh ~/Dev/conference-intern-clawhub/scripts/common.sh
cp scripts/register.sh ~/Dev/conference-intern-clawhub/scripts/register.sh
cp templates/register-single-prompt.md ~/Dev/conference-intern-clawhub/templates/register-single-prompt.md
echo "Synced"
```

- [ ] **Step 3: Clean stale data**

```bash
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/custom-answers.json
rm -f /home/germaine/.openclaw/workspace/conferences/ethcc2026/registration-status.json
echo "Cleaned"
```

- [ ] **Step 4: Restart gateway**

```bash
systemctl --user restart openclaw-gateway
sleep 2
openclaw health
```

- [ ] **Step 5: Push, PR, merge**

```bash
cd ~/Dev/conference-intern
git push
gh pr create --title "fix: agent fills Luma forms, dedup events, submitted status" --body "$(cat <<'PREOF'
## Summary

- Agent fills forms visually (Luma uses custom React, CLI can't)
- CLI still handles open/status-check/button-click/close
- New 'submitted' status for ambiguous confirmations (non-terminal)
- Fix duplicate events: update_event_status marks ALL occurrences
- Fix infinite loop: parse_registerable_events deduplicates output
- Promotional dropdowns default to No

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PREOF
)"
gh pr merge --merge
```

- [ ] **Step 6: Publish to ClawHub**

```bash
clawhub publish ~/Dev/conference-intern-clawhub --slug conference-intern --name "Conference Intern" --version 1.3.0 --changelog "Agent fills Luma forms visually, fix duplicate events, submitted status, promotional dropdowns default No"
```
