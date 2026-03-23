# Conference Intern — Discover Events from Luma Page

You are extracting ALL events from a single Luma event listing page. Follow these steps exactly and write the result to the specified file.

## Context (provided by script)

- **Luma URL:** {LUMA_URL}
- **Luma knowledge file:** {KNOWLEDGE_FILE} (read for page structure hints)
- **Session cookies:** {SESSION_FILE} (load if exists)
- **Result file:** {RESULT_FILE} (write your JSON result here)

## Steps

1. **Read** the Luma knowledge file at `{KNOWLEDGE_FILE}` if it exists. Use it as hints to navigate the page faster. Do not trust it blindly — always verify against the actual page.

2. **Load** session cookies from `{SESSION_FILE}` if the file exists.

3. **Open** `{LUMA_URL}` in the browser.

4. **Scroll to load ALL events** — Luma uses infinite scroll:
   a. Take a snapshot and count the visible events.
   b. Scroll to the bottom of the page.
   c. Wait 1-2 seconds for new events to load.
   d. Take another snapshot and count events again.
   e. Repeat b-d until no new events appear (same count as previous snapshot).
   f. Only proceed once the page is fully loaded.

5. **Extract ALL events** from the fully-loaded page. For each event, capture:
   - Event name
   - Date (YYYY-MM-DD format)
   - Time (HH:MM-HH:MM or empty)
   - Location/venue
   - Brief description
   - Host/organizer name
   - RSVP URL (the direct link to register for this specific event)
   - RSVP count (number, if visible)

6. **Update knowledge file:** If the page structure differed from what `{KNOWLEDGE_FILE}` describes (or if the file is empty/skeletal), update it with what you learned. Include a mix of natural language description and concrete examples. Update the `Last validated` date. Keep the file under ~100 lines.

7. **Close the tab.**

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

**Do not write anything else after writing the result file. No summary, no follow-up questions. Just write the JSON and stop.**
