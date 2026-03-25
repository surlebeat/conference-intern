# Fix Registration Form Handling

**Date:** 2026-03-25
**Status:** Draft
**Problem:** Luma forms use custom React components with zero native HTML inputs. The CLI can't detect or fill any form fields. Events are falsely marked as "registered" when the submit button is clicked on an unfilled form. Duplicate events in curated.md cause infinite loops.

## Root Causes

1. **Custom React forms:** Luma renders all form elements (name, email, custom fields, ticket selectors, dropdowns) as custom React components — not native `<input>`, `<select>`, or `<textarea>`. The CLI `evaluate` that queries these selectors finds nothing.

2. **False registrations:** When the CLI finds no form fields, it clicks submit on an empty form and marks it as "registered" even though nothing was actually filled.

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
CLI: wait for form to appear

AGENT: receive open tab target ID + user info + custom answers
AGENT: read the form visually (snapshot)
AGENT: fill all mandatory fields (standard + custom) using provided info
AGENT: if unknown required fields exist → report needs-input
AGENT: submit the form
AGENT: check confirmation
AGENT: write result JSON to result file

CLI: read result, close tab
```

### Agent prompt (form-fill only)

The agent gets a focused task — no page navigation, no button finding:

- Browser tab target ID (already on the form)
- User name and email
- Custom answers JSON
- Result file path
- Simple instruction: "Fill mandatory fields, submit, report result"

**Timeout:** 60s (just filling a form)

### Fix duplicate events

**`update_event_status()`:** Don't stop after first match. Continue scanning and update ALL occurrences of the event name.

**`parse_registerable_events()`:** Track already-output event names. Skip duplicates — only return each event name once.

## Files Changed

| File | Change |
|------|--------|
| `scripts/common.sh` | Rewrite `cli_register_event()` for CLI+agent hybrid, fix `update_event_status()` for duplicates, fix `parse_registerable_events()` to deduplicate |
| `templates/register-single-prompt.md` | Rewrite as form-fill-only prompt (no page opening, no button finding) |
