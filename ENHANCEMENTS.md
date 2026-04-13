# Proposed Enhancements: SMT Influx Sync

This document outlines potential improvements to the **Operations & Monitoring** and **Data Insights** capabilities of the `smt_influx_sync` system.

## 1. Operations & Monitoring (High Priority)

### Data Freshness Tracking [COMPLETED]
Currently, the UI shows the "Last Sync Time" (when the Oban job ran). However, a job can succeed while fetching zero new records if SMT hasn't published them yet.
*   **Enhancement**: Add a "Latest Data Point" timestamp to the Meter Management and Sync Status tables.
*   **Implementation**: Query InfluxDB or `sync_metadata` for the actual timestamp of the most recent electricity reading.
*   **Benefit**: Distinguishes between "the sync system is working" and "the data is up-to-date."

### Proactive "Stale Data" Warnings [COMPLETED]
Visual cues for when the system isn't keeping up with its expected schedule.
*   **Enhancement**: Highlight sync rows in red or add a "Stale" badge if the `last_sync` is significantly older than the expected interval (e.g., `Interval` hasn't run in > 1 hour).
*   **Benefit**: Immediate visual identification of synchronization gaps without checking logs.

### Real-time Event Streaming (PubSub) [COMPLETED]
The current dashboard polls every 5 seconds. Transitioning to a push-based model makes the UI feel more responsive.
*   **Enhancement**: Use `Phoenix.PubSub` to broadcast `sync_started`, `sync_completed`, and `sync_failed` events from Oban workers.
*   **Benefit**: "Sync Now" clicks will result in immediate UI updates (new log entries appearing instantly) without waiting for the next poll cycle.

### InfluxDB Buffer Growth Trends [COMPLETED]
The `pending_count` is currently a static snapshot.
*   **Enhancement**: Display the growth rate of the DETS buffer (e.g., "+50 messages in the last 1m").
*   **Benefit**: Helps identify "silent" bottlenecks where the writer is healthy but cannot keep up with the incoming data volume.

---

## 2. Advanced Diagnostics

### SMT API Latency Tracking
SMT performance can vary wildly.
*   **Enhancement**: Include the API response time and payload size in the `Sync History` messages (e.g., `"Success: Fetched 96 records in 1.4s"`).
*   **Benefit**: Helps diagnose whether sync failures are due to local networking or SMT portal instability.

### Integrated Log Viewer
The current "Sync History" only shows high-level success/fail events.
*   **Enhancement**: A dedicated "System Logs" tab that streams the last 100 lines of standard application logs, filtered for `SmtInfluxSync` tags.
*   **Benefit**: Eliminates the need for `ssh` or `docker logs` access to diagnose lower-level connection errors or Ecto issues.

---

## 3. External Integrations & Alerts

### Webhook Notifications
Don't rely on the user checking the dashboard.
*   **Enhancement**: Add support for Discord, Slack, or Telegram webhooks.
*   **Trigger**: Send an alert if a meter hasn't successfully synced any new data for > 24 hours.

### Home Assistant MQTT Discovery
Bridge the gap between InfluxDB (storage) and Home Assistant (automation).
*   **Enhancement**: Add an optional MQTT publisher that follows Home Assistant's MQTT Discovery protocol for "Energy" devices.
*   **Benefit**: Automatically populates the HA Energy Dashboard without requiring a separate SMT integration in Home Assistant.

---

## 4. Usage & Cost Insights

### Bill Projection
SMT provides kWh, but users care about $.
*   **Enhancement**: Allow users to input their "Price per kWh" and "Base Charge" in the Settings UI.
*   **Calculation**:
    *   **Estimated Bill to Date**: Sum of costs for the current billing cycle.
    *   **Projected Monthly Bill**: Trailing 30-day average usage multiplied by the rate.
*   **Benefit**: Provides immediate financial context to electricity consumption.

### Peak Demand Analysis
Helpful for users on "Time of Use" or "Free Nights" plans.
*   **Enhancement**: Highlight the hour of the day/week with the highest average usage on the dashboard.
*   **Benefit**: Identifies opportunities for load shifting (e.g., scheduling EV charging or laundry).
