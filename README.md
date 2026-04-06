# smt_influx_sync

Syncs electricity usage data from [Smart Meter Texas](https://www.smartmetertexas.com) into InfluxDB v2 on a configurable interval. On each cycle it requests an on-demand read (ODR) from the SMT API, polls until the reading is complete, and writes the result to InfluxDB using the line protocol.

Features:
- Auto-discovers your ESIID and meter number from your SMT account
- Persists the SMT auth token across restarts (avoids redundant logins)
- Queues failed InfluxDB writes to disk (DETS) and retries automatically
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

# Optional: sync interval in milliseconds (default: 1800000 = 30 minutes)
# SMT enforces a rate limit of 2 reads/hour and 24 reads/day.
# SYNC_INTERVAL_MS=1800000

# Path for the DETS file that persists pending InfluxDB writes across restarts.
# PENDING_WRITES_PATH=/data/influx_pending_writes.dets

# Path to persist the SMT auth token across container restarts.
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

The `/data` volume persists the SMT auth token and any pending InfluxDB writes across container restarts. If you change the `PENDING_WRITES_PATH` or `TOKEN_PATH` env vars, update the volume mount accordingly.

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

Readings are written to the `electricity_usage` measurement with the following schema:

| Type  | Key            | Description                          |
|-------|----------------|--------------------------------------|
| Tag   | `esiid`        | Electric Service Identifier          |
| Tag   | `meter_number` | Meter number                         |
| Field | `value`        | Cumulative meter read (kWh)          |
| Field | `usage`        | Usage since last read (kWh)          |

Timestamps come from the SMT `odrdate` field, interpreted as Central Time (`America/Chicago`). Override with `TZ` if needed.
