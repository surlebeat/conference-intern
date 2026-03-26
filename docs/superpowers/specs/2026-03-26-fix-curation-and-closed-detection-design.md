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
1. Look for register/RSVP button (existing heuristic patterns)
2. If button found → event is open, proceed to form filling
3. If NO button → look for waitlist button ("Join waitlist", "Liste d'attente", etc.)
4. If waitlist button found → click it, proceed (treat like registration)
5. If NO button at all → check the registration section of the page for specific
   closed phrases: "Cet événement affiche complet", "This event is sold out",
   "Sold out", "Registration closed", "Complet" — but ONLY in the context of
   event status text, not in descriptions or profile text
6. If closed phrase found → status: "closed"
7. If still unclear → status: "failed" (not "closed") so it gets retried
```

Key change: **never search the full page text for generic words.** Only check the registration/button area, and only after confirming there's no button to click.

Remove `closed_patterns` text matching entirely. The closed check becomes a fallback when no button is found, not a first-pass filter.

## Fix 2: Batch curation — 50 events per agent call

`curate.sh` splits `events.json` into batches of 50 events:

1. Read all events from `events.json`
2. Split into chunks of 50
3. For each chunk: call `openclaw agent --session-id "curate-..."` with the chunk + preferences + curate prompt
4. Agent writes a partial curated output for that chunk
5. Script merges all partial outputs into one `curated.md` with proper headers

Each agent call gets 50 events max — well within context limits. With 207 events, that's 5 agent calls.

The curate prompt is simplified: agent receives a subset of events and outputs tiered markdown for just that subset. The script handles merging and headers.

## Fix 3: Script handles 🔗 markers based on URL, not source

Remove all `🔗` instructions from the curate prompt. The agent only tiers events — it never decides link markers.

Post-processing in `curate.sh` after merging:
1. For each event in curated.md, look up its `rsvp_url` in events.json
2. If URL contains `luma.com` or `lu.ma` → no marker (registration script handles it)
3. If URL is external (anything else) → add `🔗 [Register manually](url)`
4. If URL is null/empty → add `🔗 No registration link`

## Manual registration list

`register.sh` collects non-Luma events during parsing and includes them in `registration-status.json`:

```json
{
  "manual_registration": [
    {"name": "Rekt Security Summit", "url": "https://tickets.rekt.news/"},
    {"name": "Vault Summit", "url": "https://tickets.vaultsummit.xyz/"}
  ]
}
```

SKILL.md tells the agent: after all registration batches are done, present the manual registration list to the user as a checklist with clickable URLs.

## Files Changed

| File | Change |
|------|--------|
| `scripts/common.sh` | Rewrite closed detection in `cli_register_event()` — button-based logic, remove `closed_patterns` text matching |
| `scripts/curate.sh` | Batch curation (50 per call) + post-process `🔗` based on URL, not source |
| `scripts/register.sh` | Add `manual_registration` to status file |
| `templates/curate-prompt.md` | Remove `🔗` instructions, simplify for batched event subsets |
| `SKILL.md` | Add step for presenting manual registration list to user |
