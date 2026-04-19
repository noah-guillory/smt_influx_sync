# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
mix deps.get          # Install dependencies
mix compile           # Compile project
mix test              # Run all tests
mix test test/path/to/file_test.exs  # Run a single test file
mix format            # Format code
mix compile --warnings-as-errors  # Strict compile (used in CI)
```

Docker:
```bash
docker build -t smt_influx_sync .
docker run --env-file .env -v smt_data:/data smt_influx_sync
```

## Architecture

**Purpose:** Syncs electricity usage data from the Smart Meter Texas (SMT) API into InfluxDB v2 on a configurable schedule.

### OTP Supervision Tree

`SmtInfluxSync.Application` uses `:one_for_one` and starts:
- `SmtInfluxSync.Repo` — Ecto/SQLite (meters, sync logs, metadata)
- `SmtInfluxSync.ConfigManager` — Runtime config wrapper
- `Oban` — Job scheduler for periodic sync workers
- `SmtInfluxSyncWeb.Endpoint` — Phoenix/Bandit web server
- `SmtInfluxSync.InfluxWriter` — GenServer managing InfluxDB writes with DETS-backed queue
- `SmtInfluxSync.SMT.Session` — Supervisor (`:rest_for_one`) for SMT auth + workers

### SMT Session Supervisor

`:rest_for_one` strategy means if `Session.Manager` crashes, all workers restart.
- `Session.Manager` — Handles SMT authentication, token persistence to disk, meter discovery
- Oban Workers: `ODR`, `Interval`, `Daily`, `Monthly`, `StaleCheck`, `YnabSyncWorker`

### Key Design Patterns

**Resilient InfluxDB writes:** `InfluxWriter` queues failed writes to a DETS file on disk. On recovery, it retries and batch-flushes up to 5,000 points per request.

**Session token persistence:** SMT auth tokens are saved to `/data/smt_token` to survive restarts. Discovered meters are stored in SQLite.

**Sync deduplication:** `SyncMetadata` and `SyncLog` tables track last successful sync per meter. Workers fetch only new data (24-month sliding window). ODR requests are gated by a configurable freshness threshold to respect the 24/day rate limit.

**Multi-meter support:** Each meter gets its own Oban job instance. Meters are auto-discovered from the SMT account and stored in the `Meter` table.

### InfluxDB Measurements

Four measurements written using InfluxDB v2 Line Protocol:
- `electricity_usage` — ODR on-demand reads (tags: `esiid`, `meter_number`, `source=odr`)
- `electricity_interval` — 15-minute interval data (fields: `consumption`, `generation`)
- `electricity_daily` — Daily totals (fields: `reading`, `startreading`, `endreading`)
- `electricity_monthly` — Billing period data (fields: `actl_kwh_usg`, `mtrd_kwh_usg`, `blld_kwh_usg`)

### Configuration

All config is environment-driven via `config/runtime.exs`. Key env vars:
- SMT: `SMT_USERNAME`, `SMT_PASSWORD`, `SMT_ESIID`, `SMT_METER_NUMBER`
- InfluxDB: `INFLUX_URL`, `INFLUX_TOKEN`, `INFLUX_ORG`, `INFLUX_BUCKET`
- Sync times (cron-style): `ODR_SYNC_TIME` (default 02:00), `INTERVAL_SYNC_TIME` (02:30), etc.
- `DATA_DIR` — base path for DETS queue and token file (default `/tmp/smt_influx_sync_data`)
- YNAB (optional): `YNAB_ACCESS_TOKEN`, `YNAB_BUDGET_ID`, `YNAB_CATEGORY_ID`, `KWH_RATE`
- Monitoring: `HEALTHCHECKS_PING_URL`, `DISCORD_WEBHOOK_URL` (or Slack)

See `.env.example` for all variables.

### Web UI

Phoenix LiveView dashboard at `/` with real-time PubSub updates:
- `StatusLive` — sync status, meter data recency, system health
- `SettingsLive` — meter management, config display, clear sync data

### Testing

Uses `Bypass` for HTTP mocking. Tests are in `test/smt_influx_sync/`. Config in `config/test.exs` disables Oban workers.
