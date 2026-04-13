# Gemini Context: `smt_influx_sync`

This project is a resilient synchronization bridge between **Smart Meter Texas (SMT)** and **InfluxDB v2**, with optional **YNAB** integration.

## Project Overview

- **Purpose**: Automatically fetches electricity usage data (real-time ODR, historical interval, daily, and monthly) from SMT and stores it in InfluxDB for visualization and analysis.
- **Main Technologies**:
  - **Language**: Elixir
  - **Web Framework**: Phoenix (LiveView for UI)
  - **Database**: SQLite (via Ecto) for metadata and sync logs.
  - **Background Jobs**: Oban for scheduled synchronization tasks.
  - **HTTP Client**: Req for API interactions.
  - **Time Series**: InfluxDB v2 (external).

## Architecture

The application uses a supervision tree for fault tolerance:
- **`SmtInfluxSync.InfluxWriter`**: Manages writes to InfluxDB with a local DETS buffer for resilience when InfluxDB is unreachable.
- **`SmtInfluxSync.SMT.Session`**: Manages the authentication token and meter discovery for SMT.
- **`SmtInfluxSync.Workers`**: Scheduled Oban jobs for different data sources:
  - `ODR`: On-demand real-time reads.
  - `Interval`: 15-minute granularity historical data.
  - `Daily`: Daily usage totals.
  - `Monthly`: Billing cycle usage totals.
  - `YnabSyncWorker`: Updates YNAB budget targets based on trailing 12-month average usage.
- **Web UI**:
  - `/`: Status dashboard showing sync history and meter status.
  - `/settings`: Configuration management for SMT, InfluxDB, and YNAB credentials.

## Building and Running

### Key Commands
- **Install dependencies**: `mix deps.get`
- **Run the server**: `mix phx.server`
- **Run tests**: `mix test`
- **Database Migrations**: Handled automatically on startup, but can be run via `mix ecto.migrate`.

### Environment Variables
Key configuration options (see `.env.example` for a full list):
- `SMT_USERNAME`, `SMT_PASSWORD`: SMT credentials.
- `INFLUX_URL`, `INFLUX_TOKEN`, `INFLUX_ORG`, `INFLUX_BUCKET`: InfluxDB connection info.
- `DATA_DIR`: Base directory for persisted state (defaults to `/data`).

## Development Conventions

- **Data Persistence**: All local state (SQLite DB, tokens, DETS buffers) is stored in the `DATA_DIR`. When running locally, ensure this directory is writable (e.g., `DATA_DIR=./data mix phx.server`).
- **Configuration**: Managed via `SmtInfluxSync.Config` and can be updated at runtime through the Settings UI, which persists overrides to `config_overrides.json` in the `DATA_DIR`.
- **Worker Management**: Workers are scheduled at specific times of day (configured in Settings). Initial syncs are triggered on startup if data is missing.
- **Multi-Meter Support**: The system auto-discovers all meters associated with the SMT account. They can be labeled and individually enabled/disabled in the Settings UI.
- **Testing**: Use `mix test`. Some tests use `Bypass` to mock external API responses.

## SQLite Compatibility
- **Oban Engine**: Uses `Oban.Engines.Lite` for SQLite compatibility to avoid `JOIN` errors during job pruning.
