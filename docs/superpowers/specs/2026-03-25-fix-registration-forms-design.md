# Fix Registration Form Handling

**Date:** 2026-03-25
**Status:** Draft
**Problem:** Luma forms use custom React components with zero native HTML inputs. The CLI can't detect or fill any form fields. Events are falsely marked as "registered" when the submit button is clicked on an unfilled form. Duplicate events in curated.md cause infinite loops.

## Root Causes

1. **Custom React forms:** Luma renders all form elements (name, email, custom fields, ticket selectors, dropdowns) as custom React components — not native `<input>`, `<select>`, or `<textarea>`. The CLI `evaluate` that queries these selectors finds nothing.

2. **False registrations:** When the CLI finds no form fields, it clicks submit on an empty form and marks it as "registered" even though nothing was actually filled. The confirmation check also defaults to "registered" when unclear.

3. **Duplicate events:** Same event appears multiple times in curated.md (from Luma + Sheets). `update_event_status()` only updates the first match. `parse_registerable_events()` returns the unmarked second copy, causing infinite re-processing.

## Solution

### CLI + Agent hybrid (revised)

CLI handles mechanical browser tasks. Agent handles form reading/filling (requires visual understanding of custom React components).

**Per-event flow:**

```
CLI: open page, wait for load
CLI: check already-registered / closed / captcha
  → if detected: write result, close tab, done
CLI: find and click Register button (heuristic + agent fallback)
  → button fallback agent call stays as-is (60s timeout, "find and click" prompt)
CLI: wait for form to appear

AGENT: receive open tab target ID + user info + custom answers
AGENT: read the form visually (snapshot)
AGENT: if no form visible (one-click RSVP / approval flow) → check if already confirmed, report result
AGENT: fill all mandatory fields (standard + custom) using provided info
AGENT: if unknown required fields exist → report needs-input with field labels
AGENT: submit the form
AGENT: check confirmation — MUST see actual confirmation text to report "registered"
AGENT: if confirmation is ambiguous → report "submitted" (NOT "registered")
AGENT: write result JSON to result file

CLI: read result, close tab
```

### Agent invocation

The CLI constructs the agent call:

```bash
timeout 90 openclaw agent --session-id "regform-$(date +%s)-$RANDOM" --message \
  "Fill and submit this Luma registration form.

TARGET_ID: $target_id
USER_NAME: $USER_NAME
USER_EMAIL: $USER_EMAIL
CUSTOM_ANSWERS: $CUSTOM_ANSWERS
RESULT_FILE: $RESULT_FILE

<contents of register-single-prompt.md>"
```

**Timeout:** 90s — form filling with dropdowns/selectors may take longer than simple field entry.

**If agent times out or crashes:** Result file will still contain `{}` from pre-seeding. CLI detects this and writes `{"status": "failed", "message": "Agent timed out on form fill"}`.

### Agent prompt (form-fill only)

Rewrite `register-single-prompt.md` as a focused form-fill prompt:

1. Take a snapshot of the open tab (target ID provided)
2. Read the form — identify all fields, which are pre-filled, which are empty
3. Fill mandatory empty fields using provided user info and custom answers
4. If there are required fields you can't fill → write `needs-input` result with field labels, stop
5. Click submit
6. Check for confirmation text (e.g., "You're registered", "Inscription confirmée")
7. **If confirmed → status: `registered`**
8. **If unclear / no confirmation text → status: `submitted`** (NOT registered — avoids false positives)
9. Write result JSON to result file, stop

The `register-field-match-prompt.md` is no longer needed — the agent handles fuzzy field matching visually as part of form filling.

### Result statuses

| Status | Meaning | Terminal? |
|--------|---------|-----------|
| `registered` | Agent saw confirmation text | Yes |
| `submitted` | Form submitted but confirmation unclear | No — retried on next run |
| `needs-input` | Unknown required fields | No — retried with answers |
| `closed` | Event full or closed | Yes |
| `captcha` | Captcha detected | No — stops batch |
| `session-expired` | Login prompt | No — stops batch |
| `failed` | Page error, timeout, crash | Yes |

**New status `submitted`:** Treated as non-terminal so the event gets retried. If it was actually registered, the retry will detect "already registered" text and mark it properly. This eliminates false positives.

### Fix duplicate events

**`update_event_status()`:** After writing the status for the first match, reset state back to `scanning` instead of staying in `done`. This way the state machine finds and updates all occurrences of the same event name.

**`parse_registerable_events()`:** Add a `declare -A seen` associative array. Before calling `_resolve_and_output`, check if the event name has already been output. If yes, skip it. This requires bash 4+ (already used elsewhere in the codebase).

## Files Changed

| File | Change |
|------|--------|
| `scripts/common.sh` | Rewrite `cli_register_event()` for CLI+agent hybrid, fix `update_event_status()` for duplicates, fix `parse_registerable_events()` to deduplicate |
| `templates/register-single-prompt.md` | Rewrite as form-fill-only prompt |
| `scripts/register.sh` | Add `submitted` to the status case statement (treat as non-terminal) |
