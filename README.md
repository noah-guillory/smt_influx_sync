# smt_influx_sync

Syncs electricity usage data from [Smart Meter Texas](https://www.smartmetertexas.com) into InfluxDB v2 on a configurable interval. On each cycle it requests an on-demand read (ODR) from the SMT API, polls until the reading is complete, and writes the result to InfluxDB using the line protocol.

Features:
- Auto-discovers your ESIID and meter number from your SMT account
- Persists the SMT auth token across restarts (avoids redundant logins)
- Queues failed InfluxDB writes to SQLite and retries automatically
- Skips duplicate ODR requests when a recent read already exists

## Configuration

All configuration is via environment variables. Copy `.env.example` to `.env` and fill in your values:

```
SMT_USERNAME=your@email.com
SMT_PASSWORD=yourpassword

# Optional: specific ESIID, or leave as "*" to auto-discover
SMT_ESIID=*

# Optional: meter number — if both ESIID and METER_NUMBER are set, skips the /meter API lookup
SMT_METER_NUMBER=

INFLUX_URL=http://localhost:8086
INFLUX_TOKEN=your-influxdb-token
INFLUX_ORG=your-org
INFLUX_BUCKET=your-bucket

# Optional: Healthchecks.io ping URL for uptime monitoring (e.g. https://hc-ping.com/<uuid>)
# HEALTHCHECKS_PING_URL=

# Optional: sync intervals in milliseconds (defaults: ODR/Interval=1h, Daily/Monthly=24h)
# ODR_SYNC_INTERVAL_MS=3600000
# INTERVAL_SYNC_INTERVAL_MS=3600000
# DAILY_SYNC_INTERVAL_MS=86400000
# MONTHLY_SYNC_INTERVAL_MS=86400000

# Optional: HTTP timeout for SMT API requests in milliseconds (default: 120000 = 2 minutes)
# Interval data fetches over a 24-month window can be slow.
# SMT_REQUEST_TIMEOUT_MS=120000

# Optional: timezone for interpreting SMT timestamps (default: America/Chicago)
# TZ=America/Chicago

# Optional: base directory for all persisted state (token, pending writes, last sync dates).
# Mount this as a Docker volume to survive container restarts.
# DATA_DIR=/data

# Optional: override the SMT token file path within DATA_DIR.
# TOKEN_PATH=/data/smt_token
```

## Running with Docker Compose

Create a `docker-compose.yml`:

```yaml
services:
  smt_influx_sync:
    image: ghcr.io/noah-guillory/smt_influx_sync:latest
    restart: unless-stopped
    env_file: .env
    volumes:
      - smt_data:/data

volumes:
  smt_data:
```

Then start it:

```bash
docker compose up -d
```

The `/data` volume persists the SMT auth token, the SQLite database (including any queued InfluxDB writes), and sync state files across container restarts.

### Running alongside InfluxDB

If you don't already have InfluxDB running, you can add it to the same Compose file:

```yaml
services:
  influxdb:
    image: influxdb:2
    restart: unless-stopped
    ports:
      - "8086:8086"
    volumes:
      - influxdb_data:/var/lib/influxdb2
    environment:
      DOCKER_INFLUXDB_INIT_MODE: setup
      DOCKER_INFLUXDB_INIT_USERNAME: admin
      DOCKER_INFLUXDB_INIT_PASSWORD: adminpassword
      DOCKER_INFLUXDB_INIT_ORG: your-org
      DOCKER_INFLUXDB_INIT_BUCKET: your-bucket
      DOCKER_INFLUXDB_INIT_ADMIN_TOKEN: your-influxdb-token

  smt_influx_sync:
    image: ghcr.io/noah-guillory/smt_influx_sync:latest
    restart: unless-stopped
    env_file: .env
    volumes:
      - smt_data:/data
    depends_on:
      - influxdb

volumes:
  influxdb_data:
  smt_data:
```

Set `INFLUX_URL=http://influxdb:8086` in your `.env` to reach the InfluxDB container by service name.

## Building from source

```bash
# Build the image locally
docker build -t smt_influx_sync .

# Run it
docker run --rm --env-file .env -v smt_data:/data smt_influx_sync
```

## InfluxDB data

Four measurements are written, all tagged with `esiid`, `meter_number`, and `source`:

### `electricity_usage` — on-demand reads (ODR)

| Type  | Key            | Description                          |
|-------|----------------|--------------------------------------|
| Tag   | `esiid`        | Electric Service Identifier          |
| Tag   | `meter_number` | Meter number                         |
| Tag   | `source`       | Always `odr`                         |
| Field | `value`        | Cumulative meter read (kWh)          |
| Field | `usage`        | Usage since last read (kWh)          |

Timestamps come from the SMT `odrdate` field.

### `electricity_interval` — 15-minute interval reads

| Type  | Key            | Description                          |
|-------|----------------|--------------------------------------|
| Tag   | `source`       | Always `interval`                    |
| Field | `consumption`  | Energy consumed in interval (kWh)    |
| Field | `generation`   | Energy generated in interval (kWh)   |

### `electricity_daily` — daily totals

| Type  | Key            | Description                          |
|-------|----------------|--------------------------------------|
| Tag   | `source`       | Always `daily`                       |
| Field | `reading`      | Total consumption for the day (kWh)  |
| Field | `startreading` | Cumulative meter at start of day     |
| Field | `endreading`   | Cumulative meter at end of day       |

### `electricity_monthly` — billing period totals

| Type  | Key             | Description                         |
|-------|-----------------|-------------------------------------|
| Tag   | `source`        | Always `monthly`                    |
| Field | `actl_kwh_usg`  | Actual usage for the period (kWh)   |
| Field | `mtrd_kwh_usg`  | Metered usage (kWh)                 |
| Field | `blld_kwh_usg`  | Billed usage (kWh)                  |

All timestamps are interpreted as Central Time (`America/Chicago`).

Interval, daily, and monthly data are fetched over a sliding 24-month window. After each successful sync the last-fetched date is persisted to disk so subsequent syncs only request new data.

## Sample queries

All examples use [Flux](https://docs.influxdata.com/flux/v0/). Replace `"your-bucket"` with your bucket name.

### Usage over the last 24 hours (ODR reads)

```flux
from(bucket: "your-bucket")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "electricity_usage" and r._field == "usage")
```

### 15-minute interval consumption for today

```flux
from(bucket: "your-bucket")
  |> range(start: today())
  |> filter(fn: (r) => r._measurement == "electricity_interval" and r._field == "consumption")
```

### Daily kWh totals for the last 30 days

```flux
from(bucket: "your-bucket")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "electricity_daily" and r._field == "reading")
```

### Monthly usage for the last 24 months

```flux
from(bucket: "your-bucket")
  |> range(start: -730d)
  |> filter(fn: (r) => r._measurement == "electricity_monthly" and r._field == "actl_kwh_usg")
```

### Average 15-minute consumption by hour of day (last 30 days)

```flux
from(bucket: "your-bucket")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "electricity_interval" and r._field == "consumption")
  |> hourSelection(start: 0, stop: 24)
  |> aggregateWindow(every: 1h, fn: mean)
```

### Peak daily usage this year

```flux
from(bucket: "your-bucket")
  |> range(start: -365d)
  |> filter(fn: (r) => r._measurement == "electricity_daily" and r._field == "reading")
  |> max()
```

### Total kWh consumed per month (aggregated from daily reads)

```flux
from(bucket: "your-bucket")
  |> range(start: -365d)
  |> filter(fn: (r) => r._measurement == "electricity_daily" and r._field == "reading")
  |> aggregateWindow(every: 1mo, fn: sum, createEmpty: false)
```

### Budget / average billing — current monthly estimate

Utilities calculate budget billing as the sum of the last 12 months of usage divided by 12. This query returns that single value:

```flux
from(bucket: "your-bucket")
  |> range(start: -12mo)
  |> filter(fn: (r) => r._measurement == "electricity_monthly" and r._field == "actl_kwh_usg")
  |> sum()
  |> map(fn: (r) => ({r with _value: r._value / 12.0}))
```

### Budget / average billing — rolling 12-month average over time

Shows how your budget billing amount would have changed each month — useful as a Grafana panel to track the trend:

```flux
from(bucket: "your-bucket")
  |> range(start: -24mo)
  |> filter(fn: (r) => r._measurement == "electricity_monthly" and r._field == "actl_kwh_usg")
  |> movingAverage(n: 12)
```

> Note: billing periods in `electricity_monthly` are actual billing cycles (e.g. Apr 15 – May 14), not calendar months, so there may occasionally be 13 records in a 12-month window. This mirrors how your utility calculates it. The rolling query requires 24 months of history in the range so the first full 12-point window can form.

### All sources overlaid — compare granularity levels

```flux
from(bucket: "your-bucket")
  |> range(start: -30d)
  |> filter(fn: (r) =>
      (r._measurement == "electricity_interval" and r._field == "consumption") or
      (r._measurement == "electricity_daily"    and r._field == "reading") or
      (r._measurement == "electricity_monthly"  and r._field == "actl_kwh_usg")
  )
  |> group(columns: ["_measurement", "source"])
```
