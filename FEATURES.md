# Feature Backlog

Potential enhancements for the SMT InfluxDB syncer and Phoenix dashboard.

---

## Dashboard / Web UI

### InfluxDB Connection Test Button
**Area:** Settings page
Add a "Test Connection" button on the settings page that fires a lightweight Flux query (e.g., `buckets()`) against the configured InfluxDB instance and displays success/failure inline. This would use the existing `Req` client with the configured `INFLUX_URL`, `INFLUX_TOKEN`, and `INFLUX_ORG`. Result should show HTTP status and a human-readable message (unauthorized, unreachable, bucket not found, etc.). Useful after changing InfluxDB credentials without needing to trigger a full sync to discover a misconfiguration.

---

### Live Sync Progress Indicator
**Area:** Status page
Currently when a manual "Sync Now" is triggered, the user has no feedback until a new `SyncLog` entry appears via PubSub. Add a per-source loading state to the status card that activates on `force_sync` and clears when a `sync_completed` or `sync_failed` PubSub event arrives for that source. A simple spinner or "Syncing…" badge on the source row would suffice. The `sync_started` event is already broadcast by `SyncMetadata.log_start/2` and subscribed to in `StatusLive`, so the plumbing is mostly in place.

---

### Inline Consumption Charts
**Area:** Status page or new Charts tab
Embed a small sparkline or bar chart of recent electricity consumption directly in the dashboard. The data would come from querying InfluxDB via the `/api/v2/query` endpoint using a Flux query scoped to the last N days. Consider using a lightweight JS charting library (Chart.js via a Phoenix hook, or a LiveView-native SVG chart). Suggested charts:
- Last 14 days of `electricity_daily` readings per meter
- Last 24 hours of `electricity_interval` (15-min) consumption
- Monthly billing period comparison (current vs. prior month)

---

### Sync Gap Detector
**Area:** Gap Filler section on status page
Query InfluxDB for the time range of available data per measurement and compare against expected daily coverage. Highlight missing date ranges in a table or calendar heatmap view. Pairs well with the existing "Gap Filler" historical sync UI — instead of the user manually entering dates, the UI could pre-populate the start/end date fields based on detected gaps. Implementation would issue a Flux `count()` grouped by day and flag any day with zero records.

---

### ODR Daily Limit Gauge
**Area:** Status page, ODR row
Show a `X / 24` usage counter for the ODR daily read limit, sourced from the per-ESIID file written by `increment_odr_daily_count/1` in `Workers.ODR`. Display it as a small progress bar or fraction badge alongside the ODR sync row. Should reset visually at midnight (local timezone). This gives operators visibility into how much of the daily quota has been consumed before manually triggering additional ODR syncs.

---

### Runtime Settings Editor
**Area:** Settings page
Add a form that allows editing key runtime config values without a container restart. These would be persisted via the existing `ConfigManager` overlay mechanism. Suggested editable fields:
- Sync times (`ODR_SYNC_TIME`, `INTERVAL_SYNC_TIME`, `DAILY_SYNC_TIME`, `MONTHLY_SYNC_TIME`, `YNAB_SYNC_TIME`)
- kWh rate and tier configuration for YNAB cost calculation
- ODR daily limit override
- Stale data thresholds

Changes should take effect on the next scheduled run. Requires adding a `PUT /api/config` or equivalent LiveView event handler backed by `ConfigManager.put/2`.

---

## Sync Enhancements

### Retry Queue Trend Visualization
**Area:** InfluxDB Writer status card
The `buffer_growth` field is already computed in `InfluxWriter.get_status/0` using a 30-sample rolling history. Expose this as a mini sparkline chart in the InfluxDB Writer card showing pending write count over the last 5 minutes. Color-code: green if draining, red if growing, gray if stable at zero. This makes it obvious when InfluxDB is recovering from an outage and whether the backlog is clearing.

---

### Per-Meter Manual Sync Trigger
**Area:** Meter Management table
The current "Sync Now" button triggers a sync for all active meters for a given source. Add per-meter sync buttons in the Meter Management table that insert an Oban job scoped to a specific `esiid`. This requires passing meter identity through the Oban job args and filtering `list_active()` to only that meter in each worker's `perform/1`. Useful when one meter has stale data but you don't want to trigger unnecessary API calls for other meters.

---

### Configurable Stale Thresholds
**Area:** Config / Settings
The staleness thresholds are currently hardcoded in `StatusLive.fetch_sync_status/0` (e.g., `interval: 120`, `daily: 48 * 60`). Move these to application config with env var overrides (`STALE_INTERVAL_MINUTES`, `STALE_DAILY_MINUTES`, etc.) and expose them in the runtime settings editor. This allows operators to tune alerting sensitivity based on their sync schedule without a code change.

---

### YNAB Sync Audit Log
**Area:** YNAB / Sync History
When a YNAB budget target is updated, log the input values that drove the calculation: the trailing average kWh, the computed cost, the tier breakdown, and the final milliunits value sent to YNAB. Currently only a generic "Sync completed" message is stored. This audit trail would be surfaced in the sync history table as an expandable detail row, making it easier to verify the kWh rate and tier configuration is producing correct results.

---

### Stale Data Webhook Alert
**Area:** Notifier / Workers
Extend the existing `StaleCheck` worker (or add a new check) to send a Discord/Slack notification when data for any source exceeds its stale threshold. The `Notifier` module already supports both webhook targets. The alert message should include: which source is stale, when the last successful sync was, and how long ago the last data point was recorded. Should be rate-limited (e.g., at most one alert per source per hour) to avoid notification spam during extended outages.

---

## Observability

### Persistent System Log
**Area:** System Logs tab
The system log panel currently holds at most 50 entries in LiveView socket state, which are lost on page refresh or reconnect. Add a `SystemLog` Ecto schema backed by a SQLite table that the `Logger` backend writes to. The System Logs tab would query this table with pagination instead of relying on in-memory state. Suggested retention: keep the last 1,000 entries, pruned by an Oban job or on-insert trigger. Include filtering by log level (info/warning/error) and source/worker.

---

### Sync Duration History
**Area:** Sync History table
The `elapsed` milliseconds are already computed in each worker and included in the `SyncLog` message string, but not stored as a structured field. Add an `elapsed_ms` integer column to `SyncLog` and populate it from workers. Surface p50/p95 duration statistics in the sync history UI per source (e.g., "avg 3.2s, p95 8.1s over last 7 days"). Slowdowns in SMT API response times would become visible before they cause timeouts.

---

### InfluxDB Write Latency Tracking
**Area:** InfluxDB Writer status card
Record how long each `do_write_lines/1` HTTP call takes and store the last N samples in `InfluxWriter` GenServer state alongside the existing `buffer_history`. Surface min/avg/max latency in the InfluxDB Writer status card. This helps distinguish between InfluxDB being slow (high latency, low error rate) vs. unreachable (errors), which have different remediation paths.

---

### `/healthz` JSON Endpoint
**Area:** Phoenix router
Add a `GET /healthz` endpoint that returns a JSON payload suitable for uptime monitors and container orchestrators. Suggested response fields:
```json
{
  "status": "ok" | "degraded" | "unhealthy",
  "influx_healthy": true,
  "influx_pending_writes": 0,
  "session_ready": true,
  "last_sync": {
    "daily": "2026-04-19T02:45:00Z",
    "interval": "2026-04-19T02:30:00Z",
    ...
  }
}
```
Returns HTTP 200 when healthy, 503 when degraded or unhealthy. Aggregates data from `InfluxWriter.get_status/0`, `Session.get_token/0`, and `SyncMetadata.get_latest_sync/1`.

---

## Reliability

### Graceful ODR Daily-Limit Scheduling
**Area:** `Workers.ODR`
When the ODR daily limit is hit, the worker currently returns `:ok` and waits for the next scheduled run. Instead, calculate the time until midnight in the configured timezone and insert an Oban job scheduled for `00:01` the following day. This ensures the ODR sync resumes as early as possible the next day rather than waiting for the next regularly-scheduled sync window, which could be many hours later.

---

### Proactive SMT Token Refresh
**Area:** `SMT.Session.Manager`
SMT bearer tokens likely have a fixed expiry. Rather than waiting for a `401` response to trigger a refresh, decode the token (if it is a JWT) or track the time of last successful authentication and proactively refresh before expiry. Add a `refresh_before_expiry_ms` config value (default: 5 minutes before expected expiry). This eliminates the retry-after-401 pattern in every worker and reduces failed sync attempts caused by token expiry mid-sync.

---

### Remove DETS / Audit Pending Writes Storage
**Area:** `InfluxWriter` / config
The `CLAUDE.md` architecture note mentions a "DETS-backed queue" for pending writes, but `InfluxWriter` actually uses the SQLite `PendingWrite` table via Ecto. The `pending_writes_path` config key still references a `.dets` file path. Audit whether DETS is still referenced anywhere, remove dead config keys and documentation references, and confirm the SQLite-backed queue is the sole persistence mechanism. This reduces confusion for future contributors.

---

### Multi-Account Support
**Area:** Config / Session / Workers
The `Meter` schema already stores `esiid` and `meter_number` per meter, and all workers iterate over `Meter.list_active()`. The main blocker is that SMT credentials (`SMT_USERNAME`, `SMT_PASSWORD`) are global singletons. Extending to multiple accounts would require:
1. A `credentials` field or associated table on `Meter`
2. Per-account `Session.Manager` instances under a dynamic supervisor
3. Workers routing each meter to the correct session token

This is a significant architectural change but the per-meter iteration pattern already in place makes it more tractable than a full rewrite.
