# Fix Curation and Closed Detection

**Date:** 2026-03-26
**Status:** Draft
**Problem:** Only 8 out of 207 events were successfully registered due to three verified root causes: (1) false "closed" detection from generic text matching, (2) curation only covering 97/207 events, (3) curate agent incorrectly marking Luma events as "register manually."

## Verified Root Causes

### 1. False "Closed" detection

The CLI checks page text for generic words: `"full"`, `"closed"`, `"complet"`. These match event descriptions ("a **full**-day program", "beauti**full**y curated") and Luma's own UI text ("profil **complet**" appears on EVERY page for logged-in French users). Result: 30 events falsely marked closed that are actually open.

### 2. Curation only covers 97/207 events

The curate agent processed 207 events in one shot but only output 97 (77 listed + 20 blocked). The remaining 110 events were silently dropped — never entered the registration pipeline at all.

### 3. Curate agent marks Luma events as 🔗 Register manually

The curate prompt says "Non-Luma events should always show 🔗." The agent sees `"source": "sheets"` and assumes non-Luma — but most Sheet-sourced events still have Luma URLs. 23 events were incorrectly marked as manual-only.

## Fix 1: Button-based closed detection

Replace text-based closed detection in `cli_register_event()` with button-based logic:

```
1. Check "already registered" patterns (full-text OK — "You're registered" etc. are
   specific enough to never false-positive from event descriptions)
2. Check captcha elements (existing logic, already reliable)
3. Look for register/RSVP button (existing heuristic patterns)
4. If button found → event is open, proceed to form filling
5. If NO button → look for waitlist button ("Join waitlist", "Liste d'attente", etc.)
6. If waitlist button found → click it, proceed (treat like registration)
7. If NO button at all → look for closed indicator text ONLY in the registration
   section of the page (near where the button would be), not in descriptions:
   - "Cet événement affiche complet"
   - "This event is sold out"
   - "Sold out"
   - "Registration closed"
   - "Inscriptions fermées"
   Note: this list may need expansion for other languages.
8. If closed indicator found → status: "closed"
9. If still unclear → status: "failed" (not "closed") so it gets retried
```

Key change: **never search the full page text for generic words.** Only check the registration/button area, and only after confirming there's no button to click.

Remove `closed_patterns` text matching entirely. The closed check becomes a fallback when no button is found, not a first-pass filter.

## Fix 2: Batch curation — 50 events per agent call

`curate.sh` splits `events.json` into batches of 50 events:

1. Read all events from `events.json`
2. Compute summary stats: total event count, RSVP range (min/median/max), events per day
3. Split into chunks of 50
4. For each chunk: call `openclaw agent --session-id "curate-..."` with:
   - The chunk of events (JSON array)
   - User preferences (interests, avoid, blocked, strategy)
   - Summary stats for cross-batch calibration
   - Curate prompt
5. **Agent outputs JSON** (not markdown) — an array of `{name, tier, reason}` for each event
6. Script collects all JSON outputs and merges into one array
7. Script generates `curated.md` from the merged JSON:
   - Groups events by date, then by tier (Must Attend / Recommended / Optional)
   - Adds event details (time, location, host) from events.json
   - Adds `🔗` markers based on URL (see Fix 3)
   - Adds blocked events section

Each agent call gets 50 events max — well within context limits. With 207 events, that's 5 agent calls. Batch size of 50 may need tuning if events have very long descriptions.

**Why JSON output:** Much easier to merge than markdown. No duplicate headers, no interleaving problems. The script has full control over the final markdown format.

## Fix 3: Script handles 🔗 markers based on URL, not source

Remove all `🔗` instructions from the curate prompt. The agent only tiers events — it never decides link markers.

Post-processing in `curate.sh` when generating markdown from merged JSON:
1. For each event, look up its `rsvp_url` in events.json
2. If URL contains `luma.com` or `lu.ma` → no marker (registration script handles it)
3. If URL is external (anything else) → add `🔗 [Register manually](url)`
4. If URL is null/empty → add `🔗 No registration link`
5. On name lookup failure → default to `🔗 Register manually` (better to show a link than silently drop the event)

## Manual registration list

`register.sh` collects non-Luma events and includes them in `registration-status.json`:

```json
{
  "manual_registration": [
    {"name": "Rekt Security Summit", "url": "https://tickets.rekt.news/"},
    {"name": "Vault Summit", "url": "https://tickets.vaultsummit.xyz/"}
  ]
}
```

New function `collect_non_luma_events()` in `common.sh`: reads events.json, returns events where `rsvp_url` does NOT contain `luma.com` or `lu.ma`. Called by `register.sh` at the end to populate the manual list.

SKILL.md tells the agent: after all registration batches are done, present the manual registration list to the user as a checklist with clickable URLs.

## Files Changed

| File | Change |
|------|--------|
| `scripts/common.sh` | Rewrite closed detection in `cli_register_event()` — button-based logic, remove `closed_patterns`. Add `collect_non_luma_events()`. |
| `scripts/curate.sh` | Rewrite: batch curation (50 per call, JSON output), merge results, generate markdown with `🔗` based on URL |
| `scripts/register.sh` | Add `manual_registration` to status file using `collect_non_luma_events()` |
| `templates/curate-prompt.md` | Rewrite: remove `🔗` instructions, output JSON instead of markdown, accept summary stats for calibration |
| `SKILL.md` | Add step for presenting manual registration list to user after all batches |
