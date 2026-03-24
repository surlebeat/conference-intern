# Hybrid CLI + Agent Registration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace agent-based registration (120s+ per event, frequent timeouts) with CLI browser commands + minimal agent calls for fuzzy field matching only.

**Architecture:** The registration loop stays the same (bash iterates events, two-pass flow for custom fields). The inner per-event logic changes: CLI opens page, checks status, clicks register, extracts form fields, fills, submits. Agent is only called for fuzzy-matching custom field labels to answers (~5-10s text-only call).

**Tech Stack:** Bash, jq, OpenClaw browser CLI (`openclaw browser open/evaluate/close/fill/click`), OpenClaw agent CLI (text-only calls)

**Spec:** `docs/superpowers/specs/2026-03-24-hybrid-registration-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/common.sh` | Modify | Add `cli_register_event()` function — the hybrid per-event registration logic |
| `scripts/register.sh` | Modify | Replace agent call in main loop with `cli_register_event()` call |
| `templates/register-field-match-prompt.md` | Create | Minimal text-only prompt for fuzzy field matching |
| `templates/register-single-prompt.md` | Keep | Kept as agent fallback reference, no longer primary |

---

### Task 1: Add `cli_register_event()` to `common.sh`

**Files:**
- Modify: `scripts/common.sh` (append)

- [ ] **Step 1: Add the function**

Append to `scripts/common.sh`:

```bash
# Register for a single Luma event using CLI browser commands.
# Agent is only called for fuzzy field matching when custom fields are present.
# Args: $1=rsvp_url, $2=result_file, $3=custom_answers_json (or empty), $4=knowledge_file
# Writes JSON result to $2.
cli_register_event() {
  local rsvp_url="$1"
  local result_file="$2"
  local custom_answers="${3:-}"
  local knowledge_file="${4:-}"

  # Load known patterns from knowledge file
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
  sleep 3  # let page load

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
    # Don't close tab — user needs to solve captcha
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
    # Fallback: call agent to find the button
    local agent_result
    agent_result=$(timeout 60 openclaw agent --session-id "regbtn-$(date +%s)-$RANDOM" --message "Open the browser tab with target ID $target_id. Find and click the registration/RSVP button on this Luma event page. Just click it and reply with 'clicked' or 'not found'. Do not fill any forms." 2>&1 | tail -1)
    if [[ "$agent_result" != *"clicked"* ]]; then
      echo '{"status": "failed", "fields": [], "message": "Could not find register button"}' > "$result_file"
      openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi
  fi

  sleep 2  # wait for form to appear

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
    # No form fields found — might already be registered or form didn't load
    echo '{"status": "failed", "fields": [], "message": "No form fields found after clicking register"}' > "$result_file"
    openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi

  # Step 5: Check for empty required fields
  local empty_required
  empty_required=$(echo "$fields_json" | jq '[.[] | select(.required == true and .value == "")]' 2>/dev/null)
  local empty_count
  empty_count=$(echo "$empty_required" | jq 'length' 2>/dev/null)

  if [ "$empty_count" -eq 0 ] || [ "$empty_count" = "null" ]; then
    # All required fields pre-filled — submit directly
    :
  elif [ -n "$custom_answers" ] && [ "$custom_answers" != "(none)" ]; then
    # Have custom answers — call agent to fuzzy-match field labels to answers
    local match_prompt
    match_prompt=$(read_template "register-field-match-prompt.md")
    local empty_labels
    empty_labels=$(echo "$empty_required" | jq -r '.[].label' 2>/dev/null)

    local match_result
    match_result=$(timeout 30 openclaw agent --session-id "regmatch-$(date +%s)-$RANDOM" --message "$(printf '%s\n\nEMPTY REQUIRED FIELDS:\n%s\n\nAVAILABLE ANSWERS:\n%s' "$match_prompt" "$empty_labels" "$custom_answers")" 2>/dev/null | tail -1)

    # Try to parse the match result as JSON
    local matches
    matches=$(echo "$match_result" | jq '.matches // {}' 2>/dev/null || echo '{}')
    local unknown
    unknown=$(echo "$match_result" | jq '.unknown // []' 2>/dev/null || echo '[]')

    if [ "$(echo "$unknown" | jq 'length' 2>/dev/null)" -gt 0 ]; then
      local unknown_fields
      unknown_fields=$(echo "$unknown" | jq -r 'join(",")')
      echo "{\"status\": \"needs-input\", \"fields\": $(echo "$unknown" | jq '.'), \"message\": \"Custom fields need answers\"}" > "$result_file"
      openclaw browser close --target-id "$target_id" 2>/dev/null || true
      return
    fi

    # Fill matched fields via CLI
    echo "$matches" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null | while IFS=$'\t' read -r label value; do
      # Find the field by label and fill it
      openclaw browser evaluate --target-id "$target_id" --fn "(function() {
        const inputs = document.querySelectorAll('input, select, textarea');
        for (const el of inputs) {
          const lbl = (el.labels && el.labels[0] ? el.labels[0].textContent : '') ||
                      el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.name || '';
          if (lbl.trim() === '$label') {
            el.value = '$value';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return true;
          }
        }
        return false;
      })()" 2>/dev/null > /dev/null
    done
  else
    # No custom answers available — report needs-input
    local field_labels
    field_labels=$(echo "$empty_required" | jq '[.[].label]')
    echo "{\"status\": \"needs-input\", \"fields\": $field_labels, \"message\": \"Custom fields need answers\"}" > "$result_file"
    openclaw browser close --target-id "$target_id" 2>/dev/null || true
    return
  fi

  # Step 7: Click submit
  openclaw browser evaluate --target-id "$target_id" --fn '() => {
    const patterns = ["submit", "confirm", "envoyer", "join event", "register", "rsvp", "request to join"];
    const btns = [...document.querySelectorAll("button[type=submit], button, input[type=submit]")];
    for (const btn of btns) {
      const text = (btn.textContent || btn.value || "").trim().toLowerCase();
      if (patterns.some(p => text.includes(p))) { btn.click(); return true; }
    }
    // Last resort: click the first submit-type button
    const submit = document.querySelector("button[type=submit], input[type=submit]");
    if (submit) { submit.click(); return true; }
    return false;
  }' 2>/dev/null > /dev/null

  sleep 3  # wait for submission

  # Step 8: Check confirmation
  local confirm_check
  confirm_check=$(openclaw browser evaluate --target-id "$target_id" --fn '() => {
    const text = document.body.innerText.toLowerCase();
    const confirmed = ["you'\''re registered", "registration confirmed", "successfully registered",
                       "inscription confirmée", "you'\''re going", "you'\''re on the waitlist"];
    if (confirmed.some(p => text.includes(p))) return "registered";
    return "unknown";
  }' 2>/dev/null)

  confirm_check=$(echo "$confirm_check" | tr -d '"' 2>/dev/null)

  if [ "$confirm_check" = "registered" ]; then
    echo '{"status": "registered", "fields": [], "message": "Successfully registered"}' > "$result_file"
  else
    echo '{"status": "registered", "fields": [], "message": "Form submitted, confirmation unclear"}' > "$result_file"
  fi

  # Step 9: Close tab
  openclaw browser close --target-id "$target_id" 2>/dev/null || true
}
```

- [ ] **Step 2: Syntax check**

Run: `bash -n scripts/common.sh && echo "OK"`
Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add scripts/common.sh
git commit -m "feat: add cli_register_event() hybrid registration function

CLI browser commands handle all mechanical work (open, check status,
click register, extract fields, fill, submit, confirm). Agent only
called for fuzzy field matching (~5-10s text-only) or button fallback.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Create `register-field-match-prompt.md`

**Files:**
- Create: `templates/register-field-match-prompt.md`

- [ ] **Step 1: Create the prompt**

Create `templates/register-field-match-prompt.md`:

```markdown
# Match Form Fields to Answers

You are matching registration form field labels to available answers. This is a text-only task — no browser needed.

Form fields may use different wording than the answer keys. Use your judgment to match them. For example:
- "What company do you work for?" matches "Company"
- "Your role" matches "Role"
- "Telegram handle" matches "Telegram"

## Instructions

1. For each EMPTY REQUIRED FIELD label below, check if any AVAILABLE ANSWER matches it (even if the wording differs).
2. Return a JSON object with:
   - `matches`: object mapping field labels to their matched answer values
   - `unknown`: array of field labels that couldn't be matched to any answer

## Example

EMPTY REQUIRED FIELDS:
- What company do you work for?
- Your role in the organization

AVAILABLE ANSWERS:
{"Company": "f(x) Protocol", "Role": "Engineer"}

Response:
{"matches": {"What company do you work for?": "f(x) Protocol", "Your role in the organization": "Engineer"}, "unknown": []}

## Your task

Return ONLY the JSON object. No explanation, no markdown.
```

- [ ] **Step 2: Commit**

```bash
git add templates/register-field-match-prompt.md
git commit -m "feat: add text-only prompt for fuzzy field matching

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Update `register.sh` to use CLI registration

**Files:**
- Modify: `scripts/register.sh`

- [ ] **Step 1: Replace the agent call in the main loop**

In `scripts/register.sh`, replace the inner event processing block (from `# Build the agent message` through the `if timeout 120 openclaw agent` block and result parsing) with a call to `cli_register_event`.

Replace lines 105-144 (from `# Build the agent message` to the closing `fi` of the agent timeout check):

```bash
  # Clear previous result
  echo '{}' > "$RESULT_FILE"

  # Register using CLI browser commands (agent only for fuzzy field matching)
  cli_register_event "$RSVP_URL" "$RESULT_FILE" "$CUSTOM_ANSWERS" "$KNOWLEDGE_FILE"
```

- [ ] **Step 2: Do the same for Pass 2**

In the Pass 2 loop (around line 260), replace the same agent-call block with:

```bash
    echo '{}' > "$RESULT_FILE"

    # Register using CLI browser commands with custom answers
    cli_register_event "$RSVP_URL" "$RESULT_FILE" "$CUSTOM_ANSWERS" "$KNOWLEDGE_FILE"
```

- [ ] **Step 3: Remove the PROMPT_TEMPLATE variable**

Delete the line:
```bash
PROMPT_TEMPLATE=$(read_template "register-single-prompt.md")
```

The old prompt template is no longer used by the main flow.

- [ ] **Step 4: Syntax check**

Run:
```bash
bash -n scripts/register.sh && echo "OK"
```
Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/register.sh
git commit -m "feat: use CLI hybrid registration instead of agent-per-event

Replaces 120s+ agent calls with fast CLI browser commands.
Agent only called for fuzzy field matching (~5-10s text-only).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Test and sync

**Files:** None (testing + deployment)

- [ ] **Step 1: Syntax check all scripts**

```bash
cd ~/Dev/conference-intern
bash -n scripts/common.sh && echo "common OK"
bash -n scripts/register.sh && echo "register OK"
bash -n scripts/discover.sh && echo "discover OK"
bash -n scripts/curate.sh && echo "curate OK"
```

- [ ] **Step 2: Test argument parsing**

```bash
bash scripts/register.sh test-conf 2>&1 | head -1
```

Expected: `[conference-intern] ERROR: Conference 'test-conf' not found...`

- [ ] **Step 3: Sync to installed skill**

```bash
DEST=/home/germaine/.npm-global/lib/node_modules/openclaw/skills/conference-intern
cp scripts/common.sh "$DEST/scripts/common.sh"
cp scripts/register.sh "$DEST/scripts/register.sh"
cp templates/register-field-match-prompt.md "$DEST/templates/register-field-match-prompt.md"
echo "Synced"
```

- [ ] **Step 4: Also sync to clawhub copy**

```bash
CLAWHUB=~/Dev/conference-intern-clawhub
cp scripts/common.sh "$CLAWHUB/scripts/common.sh"
cp scripts/register.sh "$CLAWHUB/scripts/register.sh"
cp templates/register-field-match-prompt.md "$CLAWHUB/templates/register-field-match-prompt.md"
echo "Clawhub synced"
```

- [ ] **Step 5: Restart gateway**

```bash
systemctl --user restart openclaw-gateway
sleep 2
openclaw health
```

- [ ] **Step 6: Push, PR, merge**

```bash
cd ~/Dev/conference-intern
git push
gh pr create --title "feat: hybrid CLI + agent registration" --body "$(cat <<'PREOF'
## Summary

Replaces 120s+ agent-per-event registration with CLI browser commands.
Agent only called for fuzzy field matching (~5-10s, text-only).

- CLI: open page, check registered/closed/captcha, click register, extract form, fill, submit, confirm
- Agent: fuzzy-match custom field labels to answers (text only, no browser)
- 15-30s per event instead of 80-130s

🤖 Generated with [Claude Code](https://claude.com/claude-code)
PREOF
)"
gh pr merge --merge
```
