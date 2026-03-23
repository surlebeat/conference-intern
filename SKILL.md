---
name: conference-intern
description: Discover, curate, and register for crypto conference side events via Luma and Google Sheets
metadata:
  openclaw:
    emoji: "🎪"
    requires:
      bins: ["jq"]
      capabilities: ["browser"]
    optional:
      bins: ["gog"]
---

# Conference Intern

Discover, curate, and auto-register for crypto conference side events. Fetches events from Luma pages and community-curated Google Sheets, filters them using your preferences with LLM intelligence, and handles Luma RSVP via browser automation.

## Quick Start

```bash
# First time: interactive setup
bash scripts/setup.sh my-conference

# Run the full pipeline
bash scripts/discover.sh my-conference
bash scripts/curate.sh my-conference
bash scripts/register.sh my-conference

# Or all at once
bash scripts/discover.sh my-conference && bash scripts/curate.sh my-conference && bash scripts/register.sh my-conference

# Monitor for new events
bash scripts/monitor.sh my-conference
```

## Commands

| Command | Script | Description |
|---------|--------|-------------|
| setup | `bash scripts/setup.sh <name>` | Interactive config — walks you through preferences, URLs, auth |
| discover | `bash scripts/discover.sh <id>` | Fetch events from Luma + Google Sheets → `events.json` |
| curate | `bash scripts/curate.sh <id>` | LLM-driven filtering and ranking → `curated.md` |
| register | `bash scripts/register.sh <id>` | Auto-RSVP on Luma for recommended events |
| monitor | `bash scripts/monitor.sh <id>` | Re-discover + re-curate, flag new events |

## File Locations

Per-conference data lives in `conferences/{conference-id}/`:

- `config.json` — user preferences, URLs, strategy, user info
- `events.json` — all discovered events (normalized schema)
- `events-previous.json` — snapshot from last run (for monitoring diff)
- `curated.md` — the curated schedule output (grouped by day, tiered)
- `luma-session.json` — persisted Luma browser session cookies
- `custom-answers.json` — user answers to custom RSVP fields (reused across registrations)

Skill-level shared files:

- `luma-knowledge.md` — shared Luma page patterns (learned by agent, speeds up registration)

## Agent Instructions

### Browser Usage

Use your browser capability to interact with Luma pages. **Do not hardcode CSS selectors or DOM paths.** Instead:
- Navigate to URLs and read the page content
- Interpret the page like a human — find event listings, registration forms, buttons
- This approach is evergreen — it works regardless of Luma UI changes

### Registration Rules

- Fill only **mandatory/required** fields on RSVP forms. Leave optional fields blank.
- If you encounter required fields you cannot fill (custom fields like company, wallet address, etc.), mark the event as "needs-input" in `curated.md` with the field labels listed.
- Never guess answers for custom fields — always defer to the user.

### Error Handling

**Discover:**
- Luma page fails to load → log error, skip URL, continue with remaining sources. Notify user.
- Google Sheets: try `gog` → try CSV export (`/pub?output=csv`) → try browser → skip and notify if all fail.
- Zero events across all sources → stop pipeline, notify user.

**Curate:**
- Zero events → skip, notify user.
- All events filtered out → notify user, suggest loosening criteria.

**Register:**
- RSVP page fails → mark "failed" in curated.md, continue to next event.
- CAPTCHA detected → stop registration loop (session likely flagged), notify user.
- Event full/closed → mark "closed", continue.
- Session expired → stop registration loop, notify user to re-authenticate.
- Custom required fields → mark "needs-input", collect all such fields, ask user once per unique field after pass 1.
- Already registered → mark "registered" without interacting with the form.

**Pipeline short-circuiting:**
- Zero events discovered → skip curate and register.
- Zero events curated → skip register.

### Stop Conditions

The registration script stops the loop and asks the user when:
- CAPTCHA is detected (Luma likely flagged the session)
- Session expires mid-run
- Luma 2FA code is needed (user must paste from email)

The script pauses between passes to collect custom field answers:
- After pass 1 completes, unique custom field labels are collected and the user is prompted once per field
- Answers are saved and reused across re-runs

Other stop conditions:
- Zero events are found (may indicate bad URLs)
- All events are filtered out (preferences may be too restrictive)
