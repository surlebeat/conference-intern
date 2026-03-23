# Conference Intern — Register for Single Event

You are registering the user for ONE Luma event. Follow these steps exactly and write the result to the specified file.

## Context (provided by script)

- **User name:** {USER_NAME}
- **User email:** {USER_EMAIL}
- **Event name:** {EVENT_NAME}
- **Event RSVP URL:** {RSVP_URL}
- **Luma knowledge file:** {KNOWLEDGE_FILE} (read for page structure hints)
- **Session cookies:** {SESSION_FILE} (load if exists)
- **Result file:** {RESULT_FILE} (write your JSON result here)
- **Custom answers:** {CUSTOM_ANSWERS} (if provided, use these for custom fields)

## Steps

1. **Read** the Luma knowledge file at `{KNOWLEDGE_FILE}` if it exists. Use it as hints to navigate the page faster. Do not trust it blindly — always verify against the actual page.

2. **Load** session cookies from `{SESSION_FILE}` if the file exists.

3. **Open** `{RSVP_URL}` in the browser.

4. **Check** if the user is already registered:
   - If the page shows a confirmation (e.g., "You're registered!", "You're going!", "View your ticket"), the user is already registered.
   - Write `{"status": "registered", "fields": [], "message": "Already registered"}` to `{RESULT_FILE}` and stop.
   - Do NOT unregister or interact with the form.

5. **Find** the registration form or "Register" / "RSVP" button. Click it if needed to reveal the form.

6. **Identify fields:**
   - Standard fields: name, email → fill with `{USER_NAME}` and `{USER_EMAIL}`
   - Required custom fields: any required field that is NOT name or email
   - Optional fields: leave blank. **Fill only mandatory fields.**

7. **Decide:**
   - **Only standard required fields** → fill them, submit the form.
   - **Required custom fields AND answers provided in `{CUSTOM_ANSWERS}`** → fill all required fields (standard + custom), submit.
   - **Required custom fields, no answers available** → do NOT submit. Write result with status `needs-input` and list the field labels.

8. **After submission:** look for confirmation on the page.
   - Confirmed → status: `registered`
   - Error → status: `failed`

9. **Update knowledge file:** If the page structure differed from what `{KNOWLEDGE_FILE}` describes (or if the file is empty/skeletal), update it with what you learned. Include a mix of natural language description and concrete examples (DOM patterns, button labels, etc.). Update the `Last validated` date. Keep the file under ~100 lines.

## Error Handling

- **CAPTCHA detected** → status: `captcha`
- **Event full / registration closed** → status: `closed`
- **Page won't load** → status: `failed`
- **Login prompt / session expired** → status: `session-expired`

## Result Format

Write a single JSON object to `{RESULT_FILE}`. Nothing else — no markdown, no explanation, just the JSON:

```json
{
  "status": "registered|needs-input|failed|closed|captcha|session-expired",
  "fields": ["FieldLabel1", "FieldLabel2"],
  "message": "Brief human-readable note"
}
```

- `fields`: only populated for `needs-input` status. List the labels of required custom fields.
- `message`: one sentence explaining what happened.

## Tab Cleanup

After writing the result file, **close the browser tab** — unless the status is `captcha`. CAPTCHA tabs must stay open so the user can solve them manually.

- `registered` → close tab
- `needs-input` → close tab
- `failed` → close tab
- `closed` → close tab
- `session-expired` → close tab
- `captcha` → **keep tab open**

**Do not write anything else after writing the result file. No summary, no follow-up questions. Just write the JSON, handle the tab, and stop.**
