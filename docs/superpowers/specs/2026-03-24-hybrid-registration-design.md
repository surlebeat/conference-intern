# Hybrid CLI + Agent Registration

**Date:** 2026-03-24
**Status:** Draft
**Problem:** Registration sub-agents time out at 120s. They waste ~30-40s loading workspace context (SOUL.md, USER.md, MEMORY.md), then take multiple snapshots/screenshots before acting. 12 out of 17 events timed out in the last run.

## Root Cause

The sub-agent approach is too slow for registration because:
1. OpenClaw bootstraps every sub-agent with full workspace context (~8 file reads, ~30s)
2. The agent takes multiple snapshots, screenshots, and evaluates to understand the page
3. The actual form-filling is fast, but the overhead pushes past 120s

## Solution: Hybrid CLI + Agent

Do all mechanical browser work via `openclaw browser` CLI commands (fast, no context loading). Only call the agent for judgment tasks (fuzzy field matching) — and when called, pass text only (no browser).

## Registration Flow Per Event

```
register.sh per event:
  │
  ├── 1. CLI: openclaw browser open <url>
  ├── 2. CLI: evaluate — check already-registered text patterns
  │     → match against learned patterns in luma-knowledge.md
  │     → if matched: write "registered", close tab, done
  │
  ├── 3. CLI: evaluate — find Register/RSVP button using heuristics
  │     → search for buttons: "Register", "RSVP", "Join", "Participer", etc.
  │     → if no match: call agent as fallback to find the button
  │     → click it
  │
  ├── 4. CLI: evaluate — wait for form, extract all fields
  │     → returns: [{label, type, required, value}]
  │
  ├── 5. DECISION (bash):
  │     → all required fields filled? → go to step 7
  │     → empty required fields exist? → go to step 6
  │
  ├── 6. AGENT CALL (text only, no browser):
  │     → input: empty field labels + custom-answers.json
  │     → agent fuzzy-matches labels to answers
  │     → returns: {field_label: answer} or flags as needs-input
  │     → if answers: CLI fill fields
  │     → if needs-input: write result, close tab, done
  │
  ├── 7. CLI: click submit button
  ├── 8. CLI: evaluate — check confirmation or error
  ├── 9. CLI: close tab
  └── 10. Write result JSON
```

## Step Details

### Step 2: Already-registered detection

CLI evaluate checks page text against known patterns. Patterns stored in `luma-knowledge.md` and loaded by the script:

```javascript
() => {
  const text = document.body.innerText;
  const patterns = ["You're registered", "You're going", "Vous êtes inscrit",
                     "View your ticket", "Voir votre billet"];
  return patterns.some(p => text.includes(p));
}
```

The pattern list is loaded from `luma-knowledge.md` at script start. New patterns are added when the agent encounters them during fallback operations.

### Step 3: Find and click Register button

CLI evaluate searches for buttons/links matching known patterns:

```javascript
() => {
  const patterns = ["register", "rsvp", "join", "participer", "s'inscrire",
                     "join waitlist", "request to join"];
  const btns = [...document.querySelectorAll("button, a[role=button], [class*=btn]")];
  for (const btn of btns) {
    const text = btn.textContent.trim().toLowerCase();
    if (patterns.some(p => text.includes(p))) {
      btn.click();
      return {found: true, text: btn.textContent.trim()};
    }
  }
  return {found: false};
}
```

If `found: false`, fall back to agent to find the button (rare, first-time-on-new-layout scenario). Agent result is used to update the pattern list.

### Step 4: Extract form fields

After clicking Register, wait briefly for form to appear, then extract:

```javascript
() => {
  const fields = [];
  document.querySelectorAll("input, select, textarea").forEach(el => {
    const label = el.labels?.[0]?.textContent ||
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
}
```

### Step 5: Decision in bash

```bash
# Filter to empty required fields
EMPTY_REQUIRED=$(echo "$FIELDS_JSON" | jq '[.[] | select(.required == true and .value == "")]')
EMPTY_COUNT=$(echo "$EMPTY_REQUIRED" | jq 'length')

if [ "$EMPTY_COUNT" -eq 0 ]; then
  # All required fields pre-filled (user logged in) → submit
  ...
else
  # Need to fill custom fields → call agent for fuzzy matching
  ...
fi
```

### Step 6: Agent fuzzy matching (text only)

The agent receives ONLY text — no browser access needed:

```
Match these form field labels to the answers provided. Return a JSON object mapping each field label to its answer. If you can't match a field, include it in the "unknown" array.

EMPTY REQUIRED FIELDS:
- "What company do you work for?"
- "Your role"
- "Telegram handle"

AVAILABLE ANSWERS:
{"Company": "f(x) Protocol", "Role": "Engineer"}

Return JSON: {"matches": {"What company do you work for?": "f(x) Protocol", "Your role": "Engineer"}, "unknown": ["Telegram handle"]}
```

This is a 5-10 second agent call — pure text reasoning, no browser, minimal context.

### Steps 7-8: Submit and confirm

CLI clicks submit button (found by pattern matching: "Submit", "Confirm", "Envoyer", etc.), then evaluates page for confirmation text patterns.

### Error Detection

All via CLI evaluate:
- **CAPTCHA:** Check for captcha iframes/elements (`[class*=captcha], [class*=recaptcha], iframe[src*=captcha]`)
- **Event full/closed:** Check for text patterns ("sold out", "full", "closed", "complet")
- **Session expired:** Check for login prompts

## What's Learned in luma-knowledge.md

The script reads learned patterns at startup and updates them when new patterns are discovered:

```markdown
## Registration Patterns
already_registered: ["You're registered", "You're going", "Vous êtes inscrit"]
register_button: ["Register", "RSVP", "Join", "Participer"]
submit_button: ["Submit", "Confirm", "Envoyer", "Join Event"]
confirmation: ["You're registered!", "Registration confirmed", "Inscription confirmée"]
captcha: ["captcha", "recaptcha", "hCaptcha"]
closed: ["sold out", "full", "closed", "registration closed", "complet"]
```

## Agent Calls — When and Why

| Situation | Agent needed? | Why |
|-----------|--------------|-----|
| Already registered check | No | Text pattern match |
| Find register button | Usually no. Fallback: yes | Button text varies, heuristic covers 95% |
| Fill standard fields | No | Pre-filled by Luma session |
| Match custom fields to answers | Yes | Labels vary per event, needs fuzzy matching |
| Submit and confirm | No | Pattern match |
| CAPTCHA/closed/expired | No | Pattern match |

## Performance

| Step | Current (agent) | Hybrid (CLI + agent) |
|------|----------------|---------------------|
| Open page | ~5s | ~5s |
| Context loading | ~30-40s | 0s (CLI has no context) |
| Page analysis | ~30-60s (snapshots, thinking) | ~2-3s (one evaluate) |
| Form filling | ~15-30s | ~2-5s (CLI fill) |
| Agent fuzzy match | N/A | ~5-10s (only when needed) |
| **Total** | **80-130s (often timeout)** | **~15-30s** |

## Files Changed

| File | Change |
|------|--------|
| `scripts/register.sh` | Rewrite registration loop to use CLI browser commands + agent fallback |
| `scripts/common.sh` | Add helpers: `load_knowledge_patterns()`, `match_field_answers()` |
| `templates/register-single-prompt.md` | Simplify to text-only fuzzy matching prompt (no browser instructions) |
| `templates/register-button-fallback-prompt.md` | New: minimal agent prompt for finding register button when heuristic fails |

## Migration

- `register-single-prompt.md` is rewritten (not backwards compatible)
- `luma-knowledge.md` gets a new `## Registration Patterns` section — agent updates it on first successful registration
- No changes to discover.sh, curate.sh, SKILL.md
