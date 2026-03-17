# Yonderbook Clubs

![Yonderbook Clubs demo](tour.gif)

A Signal bot that brings structured book club coordination into group chats. Members suggest books via DM, the bot enriches suggestions with metadata, and the group votes using Signal's native poll feature.

## How It Works

1. Add the bot to your Signal group chat
2. Members DM the bot their book suggestions — the group stays quiet
3. Anyone starts a vote — the bot posts a rich summary with cover art and a Signal poll
4. Members vote for their favorites
5. Schedule the winners and start reading

## Commands

### DM Commands (message the bot directly)

| Command | Description |
|---------|-------------|
| `/suggest Title by Author` | Suggest a book by title and author |
| `/suggest Author, Title` | Alternate format (author first) |
| `/suggest 978-1635575996` | Suggest by ISBN |
| `/suggest ai: that infinite house book` | AI-assisted suggestion (opt-in) |
| `/remove` or `/r` | Undo your last suggestion |
| `/suggestions` | See all current suggestions |
| `/schedule` | See the reading schedule |
| `/help` | Show available commands |

Short aliases: `/s` for `/suggest`, `/r` for `/remove`.

### Group Chat Commands (in the book club group)

| Command | Description |
|---------|-------------|
| `/start vote N` | Start a vote — members pick up to N books |
| `/close vote` | End the current vote |
| `/results` | See vote results |
| `/schedule Book for Month` | Add a book to the reading schedule |
| `/schedule Book by Author for Month` | Schedule with author |
| `/schedule` | View the current schedule |
| `/unschedule Book` | Remove a book from the schedule |

### Input Formats

The bot accepts several suggestion formats:

```
/suggest Piranesi by Susanna Clarke       → Title by Author
/suggest Susanna Clarke, Piranesi         → Author, Title
/suggest 978-1635575996                   → ISBN-10 or ISBN-13
/suggest ai: that infinite house book     → AI-assisted (uses Claude)
/suggest Piranesi                         → Free text search
```

The `ai:` prefix is the only path that uses AI — it's explicitly opt-in.

### Multi-Club Support

If you're in multiple book clubs, the bot asks which club you mean. Prefix with a club number to skip the prompt:

```
/suggest #2 Piranesi by Susanna Clarke
```

## Setup

### Prerequisites

- Elixir 1.17+
- PostgreSQL
- [signal-cli](https://github.com/AsamK/signal-cli) running in daemon mode
- An Anthropic API key (only needed for `ai:` suggestions)

### Installation

```bash
git clone <repo-url>
cd signal-bot
mix deps.get
mix ecto.setup
```

### Configuration

All configuration is via environment variables. Use `direnv` + `.env` for local dev.

| Variable | Purpose | Default |
|----------|---------|---------|
| `DATABASE_URL` | PostgreSQL connection string | — |
| `SIGNAL_CLI_HOST` | signal-cli TCP host | `localhost` |
| `SIGNAL_CLI_PORT` | signal-cli TCP port | `7583` |
| `SIGNAL_BOT_NUMBER` | Bot's registered phone number | — |
| `ANTHROPIC_API_KEY` | Claude API key (for `ai:` feature) | — |

### Running

Start signal-cli in daemon mode:

```bash
signal-cli daemon --tcp localhost:7583
```

Start the bot:

```bash
mix run --no-halt
```

## Architecture

### Stack

- **Elixir** — plain OTP app (no Phoenix)
- **PostgreSQL** via Ecto
- **signal-cli** — JSON-RPC over TCP for Signal integration
- **Open Library API** — book metadata, covers, descriptions
- **Claude API** — AI-assisted suggestion extraction (opt-in only)
- **Oban** — background job processing (vote sending)
- **ETS** — in-memory club cache

### Context Modules

```
YonderbookClubs.Clubs        — Club CRUD, voting state, onboarding
YonderbookClubs.Suggestions  — Suggestion lifecycle, deduplication
YonderbookClubs.Polls        — Poll creation, vote recording, results
YonderbookClubs.Readings     — Reading schedule management
YonderbookClubs.Books        — Open Library + AI book search
YonderbookClubs.Bot.Router   — Inbound message routing
YonderbookClubs.Bot.Formatter — Outbound message formatting
YonderbookClubs.Signal.CLI   — signal-cli TCP client (GenServer)
```

### Message Flow

```
Signal → signal-cli (TCP) → Signal.CLI GenServer → Bot.Router
  → has groupInfo? → GroupCommands.handle/2
  → no groupInfo?  → DMCommands.handle/3
```

Group commands manage voting and scheduling. DM commands handle suggestions and book lookups. The bot stays silent in groups for unrecognized messages.

### Data Model

- **clubs** — one per Signal group, tracks voting state and onboarding
- **suggestions** — book suggestions scoped to a club, deduplicated by Open Library work ID
- **polls** — Signal polls with timestamps, linked to suggestion options
- **votes** — individual votes on poll options
- **readings** — scheduled books with time labels

### Key Design Decisions

- **Private suggestions** — members DM their picks so the group chat stays clean during suggestion phase
- **Work-based deduplication** — suggestions are deduplicated on Open Library work ID, so different editions of the same book collapse
- **Honor-system voting** — Signal polls don't enforce vote limits, so the budget is set by convention in the poll question
- **Clean slate** — suggestions are archived after each vote cycle, keeping the pool current
- **AI transparency** — the `ai:` prefix is the only path that touches Claude. No silent AI usage anywhere

## Testing

```bash
mix test                    # Run all tests
mix test --trace            # Verbose output
mix test --only integration # Integration tests (hits Open Library)
```

Signal interactions are mocked via a behaviour (`YonderbookClubs.Signal`) + Mox. Book API calls use real HTTP to Open Library. Database tests use Ecto sandbox.

## Tour Generation

The demo GIF/MP4 is generated from a script:

```bash
mix generate_tour
```

This reads `tour/tour-script.json`, renders SVG frames as a Signal-style chat UI, and produces `tour.gif` and `tour.mp4`. The help scene auto-generates from `Formatter.format_help/0` so the tour stays in sync with the code.

## Deployment

Deployed on Render. Set environment variables in the Render dashboard. signal-cli runs as a companion service.

## License

Private — Yonderbook.
