# 🎪 Conference Intern

**Your AI-powered side event concierge for crypto conferences.**

Conference Intern discovers, curates, and auto-registers you for side events at crypto conferences. It scrapes events from [Luma](https://lu.ma) pages and community-curated Google Sheets, filters them using your preferences with LLM intelligence, and handles Luma RSVP via browser automation — so you spend less time juggling event pages and more time networking.

> An [OpenClaw](https://openclaw.com) skill — requires an OpenClaw agent with browser access.

---

## How It Works

Conference Intern runs a four-stage pipeline, each stage independent and re-runnable:

```
Setup → Discover → Curate → Register
                ↑                 │
                └── Monitor ──────┘
```

1. **Setup** — interactive walkthrough to configure your conference: event source URLs, interest topics, avoid list, registration strategy
2. **Discover** — fetches events from Luma and Google Sheets, normalizes them into a unified `events.json`
3. **Curate** — LLM scores and ranks events based on your preferences, outputs a tiered schedule (`curated.md`)
4. **Register** — auto-RSVPs on Luma for recommended events via browser automation
5. **Monitor** — re-runs discover + curate on a schedule, flags newly added events

## Getting Started

Once the skill is installed in your OpenClaw agent, just talk to it. Here are some example prompts:

> **"Set me up for EthCC 2026"**
> Kicks off the interactive setup — the agent will ask you for Luma URLs, Google Sheet links, your interests, and registration preferences.

> **"Find side events for ethcc-2026"**
> Discovers events from all your configured sources.

> **"Curate my ethcc-2026 events"**
> Scores and ranks discovered events based on your preferences, outputs a tiered schedule.

> **"Register me for the recommended ethcc-2026 events"**
> Auto-RSVPs on Luma for your curated picks via browser automation.

> **"Check for new ethcc-2026 events"**
> Re-runs discovery and curation, flags anything new since last time.

## What You Get

After running the pipeline, you get a `curated.md` schedule like this:

```markdown
# EthCC 2026 — Side Events

Last updated: 2026-07-08 14:00 UTC
Strategy: aggressive | Events: 47 found, 31 recommended

## July 8 (Wednesday)

### Must Attend
- **ZK Privacy Summit** — 14:00-18:00 @ Maison de la Mutualité
  Host: PrivacyDAO | RSVPs: 234
  ✅ Registered

### Recommended
- **DeFi Builders Happy Hour** — 18:00-21:00 @ Le Comptoir
  Host: DeFi Alliance | RSVPs: 89
  ⏳ Needs input: [Company name, Role]

### Optional
- **Infra Roundtable** — 10:00-12:00 @ Hotel Conf Room
  Host: InfraDAO
  🔗 Register manually

## Blocked / Filtered Out
- ~~NFT Minting Party~~ — matched avoid list: "NFT minting parties"
```

## Configuration

Setup creates a `config.json` per conference where you define:

- **Source URLs** — Luma event pages and Google Sheets links
- **Interests** — topics you care about (e.g., "DeFi", "ZK proofs", "MEV")
- **Avoid list** — topics to filter out (e.g., "token launches")
- **Blocked organizers** — specific hosts to exclude
- **Strategy** — `aggressive` (register broadly) or `conservative` (only top-tier events)
- **Monitoring** — `scheduled` (automatic), `on-demand`, or `both`
- **Luma auth** — optional login via email 2FA for faster RSVPs

## Project Structure

```
conference-intern/
├── SKILL.md               # Skill metadata + agent instructions
├── scripts/
│   ├── common.sh          # Shared helpers
│   ├── setup.sh           # Interactive setup
│   ├── discover.sh        # Event discovery
│   ├── curate.sh          # LLM-powered curation
│   ├── register.sh        # Browser-based RSVP
│   └── monitor.sh         # New event detection
├── templates/
│   ├── setup-prompt.md    # Agent prompt for setup flow
│   ├── curate-prompt.md   # Agent prompt for event scoring
│   └── register-prompt.md # Agent prompt for RSVP automation
└── conferences/
    └── {conference-id}/   # Per-conference runtime data (gitignored)
        ├── config.json
        ├── events.json
        ├── curated.md
        └── luma-session.json
```

## Event Sources

### Luma
The agent navigates Luma pages using browser automation and reads event listings the way a human would — no hardcoded CSS selectors or DOM paths. This makes the skill resilient to Luma UI changes.

### Google Sheets
Community-curated spreadsheets (commonly shared on Telegram/Twitter before conferences) are fetched via a three-tier fallback:

1. [`gog`](https://github.com/jonfriesen/gog) CLI (fastest, if installed)
2. CSV export URL via `curl`
3. Browser fallback (last resort)

## Smart Registration

- Fills only **mandatory** fields — never guesses optional or custom fields
- Custom fields (company, wallet address, etc.) are flagged as **"needs input"** for you to fill manually
- CAPTCHA, full events, and closed registration are detected and marked accordingly
- Session cookies are persisted so you don't re-authenticate every run

## Requirements

- [OpenClaw](https://openclaw.com) with browser capability
- [`jq`](https://jqlang.github.io/jq/) for JSON processing
- [`gog`](https://github.com/jonfriesen/gog) (optional) for Google Sheets access

## Design Principles

- **Evergreen** — LLM reads pages like a human; no brittle selectors
- **Agent-agnostic** — works with any agent that has browser access
- **Re-runnable** — every pipeline stage is idempotent
- **User in control** — never guesses answers for custom fields; always defers to you

## Contributing

Pull requests are welcome! If you have ideas for new event sources, better curation heuristics, or support for additional conference platforms, feel free to open a PR.

## License

MIT
