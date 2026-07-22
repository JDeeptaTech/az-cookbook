# Skyline

See what's on the horizon for your OpenShift cluster: how far behind the
update channel you are, which releases you can actually reach, and the
shortest upgrade path — constrained to what's really mirrored in your Nexus.

Skyline pulls the [Cincinnati update graph](https://github.com/openshift/cincinnati-graph-data)
on a schedule, stores snapshots as parquet, pushes them to PostgreSQL for
downstream consumers, and serves a Streamlit dashboard on top.

```
Cincinnati API ─┐
Cluster version ─┼─> parquet (/data) ──> PostgreSQL (optional sink)
Nexus tags ─────┘        │
                         └──> Streamlit dashboard (:8501)
```

## Quick start

```bash
docker build -t skyline .
docker run -p 8501:8501 -v skyline-data:/data \
  -e CHANNELS=stable-4.17,stable-4.18 \
  skyline
```

Open http://localhost:8501. First ingest runs on startup, then per
`INGEST_CRON` (default: every 6 hours).

## Configuration

All settings are environment variables. Everything except `CHANNELS` is
optional — unset integrations are skipped, they don't fail.

| Variable | Purpose | Example |
|---|---|---|
| `CHANNELS` | Channels to ingest (empty = all, slow) | `stable-4.18,fast-4.19` |
| `ARCH` | Release architecture | `amd64` (default) |
| `INGEST_CRON` | Ingest schedule, UTC | `0 */6 * * *` |
| `PG_DSN` | Enable Postgres push | `host=pg dbname=ocp user=loader password=...` |
| `OC_API` / `OC_TOKEN` | Snapshot cluster version | `https://api.cluster:6443` / `$(oc whoami -t)` |
| `OC_CA_CERT` | Cluster CA bundle path | `/etc/ssl/cluster-ca.crt` |
| `NEXUS_URL` / `NEXUS_IMAGE` | Mirror availability check | `https://nexus:8443` / `ocp4/ocp-release` |
| `NEXUS_USER` / `NEXUS_PASS` | Nexus basic auth | |

Pass secrets via your orchestrator's secret mechanism, not plain compose files.

## Layout

```
app/ingest.py         Cincinnati / cluster / Nexus -> hive-partitioned parquet
app/push_postgres.py  incremental parquet -> Postgres (DuckDB pg extension)
app/scheduler.py      APScheduler cron: ingest then push
app/streamlit_app.py  dashboard — reads parquet directly, no Postgres dependency
```

Parquet layout: `/data/parquet/{table}/snapshot_date=YYYY-MM-DD/part-*.parquet`.
Snapshots are append-only; the dashboard always shows the latest, history stays
queryable.

## Notes

- **Single replica only.** The scheduler has no distributed locking; two
  replicas means duplicate ingestion. On OpenShift, prefer splitting into a
  Deployment (dashboard) + CronJob (ingest/push) sharing a PVC.
- The Nexus check uses the docker `/v2/tags/list` API and assumes a
  tag-based mirror (`oc adm release mirror`). Digest-only mirrors
  (`oc-mirror`) will report no tags.
- No retention is implemented; prune old parquet partitions when they matter.
