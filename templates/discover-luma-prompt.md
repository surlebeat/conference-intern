# Conference Intern — Discover Events from Luma Page

You are extracting ALL events from a single Luma event listing page. Follow these steps exactly and write the result to the specified file.

## Context (provided by script)

- **Luma URL:** {LUMA_URL}
- **Luma knowledge file:** {KNOWLEDGE_FILE} (read for page structure hints)
- **Session cookies:** {SESSION_FILE} (load if exists)
- **Result file:** {RESULT_FILE} (write your JSON result here)

## CONSTRAINTS — Read these first

- Do NOT call any Luma API endpoints (api2.luma.com, public-api.luma.com, etc.)
- Do NOT write Python scripts — use browser tools only, then write the JSON file directly
- Do NOT explore `__NEXT_DATA__`, window objects, or internal data structures
- Do NOT over-engineer — extract the data and write it. Stay focused.
- You MUST write to the exact path `{RESULT_FILE}` — do not create your own temp file.

## Steps

1. **Read** the Luma knowledge file at `{KNOWLEDGE_FILE}` if it exists. Use it as hints. Do not trust blindly — verify against the actual page.

2. **Load** session cookies from `{SESSION_FILE}` if the file exists.

3. **Open** `{LUMA_URL}` in the browser.

4. **Check for JSON-LD structured data** — look for `<script type="application/ld+json">` on the page. Luma typically embeds event data in this format for SEO. If found, parse the `"events"` array to get the initial event list with names, dates, URLs, and locations.

5. **Scroll to load ALL events** — Luma uses infinite scroll:
   a. Take a snapshot and count the visible event cards.
   b. Scroll to the bottom of the page.
   c. Wait 1-2 seconds for new events to load.
   d. Take another snapshot and count events again.
   e. Repeat b-d until no new events appear (same count as previous snapshot).

6. **Verify count** — compare the JSON-LD event count vs the visible DOM event count. If the DOM shows more events than JSON-LD, extract the additional ones from the page content. Merge into a single list (deduplicate by name + date).

7. **Extract event details** — for each event in the merged list, capture:
   - Event name
   - Date (YYYY-MM-DD format)
   - Time (HH:MM-HH:MM or empty)
   - Location/venue
   - Brief description
   - Host/organizer name
   - RSVP URL (the direct link to register — typically `https://lu.ma/<slug>`)
   - RSVP count (number, if visible)

8. **Write the result** — write the JSON array directly to `{RESULT_FILE}`. Use the `exec` tool with a simple `cat` heredoc or `echo` if needed. Do not write a Python script.

9. **Update knowledge file** at `{KNOWLEDGE_FILE}` if the page structure differed from what's described (or if the file is empty). Keep under ~100 lines. Update the `Last validated` date.

10. **Close the tab.**

## Result Format

Write a JSON array to `{RESULT_FILE}`. Nothing else — no markdown, no explanation, just the JSON array:

```json
[
  {
    "name": "Event Name",
    "date": "YYYY-MM-DD",
    "time": "HH:MM-HH:MM",
    "location": "Venue name",
    "description": "Brief description",
    "host": "Organizer name",
    "rsvp_url": "https://lu.ma/...",
    "rsvp_count": 123,
    "source": "luma"
  }
]
```

**Write to `{RESULT_FILE}`, close the tab, and stop. No summary, no follow-up questions.**
