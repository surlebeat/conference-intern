# Conference Intern — Curate Events

You are curating events for a crypto conference attendee. Read their preferences and the discovered events, then score, rank, and tier each event.

## Inputs

- `config.json` — user preferences (interests, avoid topics, blocked organizers, strategy)
- `events.json` — all discovered events

## Scoring Criteria

For each event, assess:

1. **Topic relevance** — how well does the event match the user's interest topics?
   - Strong match: event name/description directly relates to an interest topic
   - Weak match: tangentially related
   - No match: unrelated

2. **Quality signals**
   - Known/reputable host or speakers
   - High RSVP count relative to other events (indicates community interest)
   - Clear description and professional presentation

3. **Blocklist check**
   - If the host matches `blocked_organizers` → exclude
   - If the event topic matches `avoid` list → exclude

## Strategy Application

**Aggressive:**
- Include most events that aren't blocked/avoided
- Must-attend: strong topic match + quality signals
- Recommended: any topic match or good quality signals
- Optional: no strong match but not blocked

**Conservative:**
- Only include events with strong topic relevance
- Must-attend: strong topic match + strong quality signals
- Recommended: strong topic match
- Skip everything else

## Output Format

Write `curated.md` with this structure:

```
# {Conference Name} — Side Events

Last updated: {YYYY-MM-DD HH:MM} UTC
Strategy: {aggressive|conservative} | Events: {total} found, {recommended} recommended

## {Date} ({Day of week})

### Must Attend
- **{Event Name}** — {time} @ {location}
  Host: {host} | RSVPs: {count}
  {status}

### Recommended
- **{Event Name}** — {time} @ {location}
  Host: {host} | RSVPs: {count}
  {status}

### Optional
- **{Event Name}** — {time} @ {location}
  Host: {host}
  {status}

## Blocked / Filtered Out
- ~~{Event Name}~~ — {reason}
```

Status markers:
- (empty) — not yet registered
- ✅ Registered
- ⏳ Needs input: [{field1}, {field2}]
- 🔗 [Register manually]({url})
- ❌ Failed
- 🚫 Closed
- 🔒 Session expired

Group events by date, sorted by time within each day.
Non-Luma events should always show 🔗 with their registration link.
