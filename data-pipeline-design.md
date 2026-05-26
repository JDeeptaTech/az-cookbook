# Data Pipeline & Data Model — Design Specification

> **Medallion Architecture · dlt → dbt → Grafana**
> Template. Replace every `«token»`. Keep this file version-controlled alongside the code.

| | |
|---|---|
| **Project** | «project name» |
| **Owner** | «team / author» |
| **Status** | Draft / In Review / Approved |
| **Version** | «0.1» |
| **Last updated** | «date» |

---

## 1. Document Control

### Revision history

| Version | Date | Author | Summary of change |
|---|---|---|---|
| 0.1 | «date» | «author» | Initial draft |
| | | | |

### Approvers & stakeholders

| Role | Name | Sign-off / date |
|---|---|---|
| Data / Platform lead | «name» | |
| Product / Business owner | «name» | |
| Reviewer | «name» | |

---

## 2. Overview & Scope

### 2.1 Purpose

State, in one or two sentences, the business question this pipeline answers.
*e.g. consolidate server inventory across N projects to report coverage, cross-project overlap, and lifecycle drift.*

### 2.2 In scope / out of scope

| In scope | Out of scope |
|---|---|
| «data domains, sources, reports delivered» | «real-time streaming, PII handling, ML, etc.» |

### 2.3 Stack

| Concern | Tool | Notes / version |
|---|---|---|
| Ingestion | dlt (data load tool) | Python; lands raw → bronze |
| Transformation | dbt | silver + gold; tests, docs, lineage |
| Warehouse | «Postgres / BigQuery / Snowflake» | schemas: `bronze` / `silver` / `gold` |
| Visualization | Grafana | reads gold marts; provisioned dashboards |
| Orchestration | «cron / Airflow / GitHub Actions» | schedule + retries + alerting |

---

## 3. Medallion Architecture

Data flows left-to-right through three quality tiers. Each tier has a single owner tool and a strict contract: **a layer may only read from the layer immediately upstream of it.**

| Layer | Role |
|---|---|
| 🥉 **Bronze** | Raw, immutable, append-only. Exact copy of source as landed by dlt, plus ingestion metadata. No cleaning, no typing, no joins. |
| 🥈 **Silver** | Cleaned & conformed. Typecast, de-duplicated, standardised keys; one staging model per source, then conformed/integrated (intermediate) models. Business logic lives here. |
| 🥇 **Gold** | Curated marts. Aggregated, report-ready facts and dimensions consumed directly by Grafana and analysts. Wide, denormalised, stable interfaces. |

### 3.1 Layer responsibilities

| Layer | Owner | Materialization | Rules |
|---|---|---|---|
| Bronze | dlt | Tables (append / replace) | No transforms. Keep `_ingested_at`, `_source_file`, `_file_hash`, `_load_date`. |
| Silver | dbt | Views (staging) / views or tables (intermediate) | 1:1 staging per source; clean, cast, rename, key-standardise; conform across sources. |
| Gold | dbt | Tables | Aggregations, facts & dims. Stable column contract for BI. No source-specific quirks leak through. |

### 3.2 Data flow

```text
sources (csv / xlsx / api)
        │   dlt pipeline (extract + normalize + load)
        ▼
[ bronze ]  raw.* tables  ── append-only, hashed
        │   dbt: staging models (stg_*)
        ▼
[ silver ]  stg_* → int_*  ── clean, conform, integrate
        │   dbt: marts
        ▼
[ gold ]    dim_* / fct_*  ── report-ready
        │   Grafana datasource (read-only)
        ▼
    dashboards / alerts
```

---

## 4. Source Inventory

One row per source system / file. This is the contract between you and the upstream owners — fill every column.

| Source | Format | Owner | Cadence | Grain | Bronze table |
|---|---|---|---|---|---|
| «source A» | CSV | «team» | Daily | «1 row per…» | `bronze.«a»` |
| «source B» | XLSX | «team» | Daily | «1 row per…» | `bronze.«b»` |
| «source C» | API | «team» | Hourly | «1 row per…» | `bronze.«c»` |

### 4.1 Identifiers & join keys

> ⚠️ **Critical:** verify join keys with match-rate profiling **before** building any cross-source model. If sources use different identifier namespaces, document the bridge explicitly and note that transitive joins inherit the bridge's coverage gaps.

| Key | Sources it links | Verified match rate |
|---|---|---|
| «key 1» | «source A ↔ source B» | «__%  (date)» |
| «bridge key» | «source B ↔ source C» | «__%  (date)» |

---

## 5. Ingestion Layer — dlt → Bronze

### 5.1 Conventions

- One dlt resource per source; one pipeline lands all resources into the `bronze` dataset.
- Bronze is raw. No business logic in ingestion — only extraction, dlt's schema normalization, and metadata enrichment.
- Every row carries lineage metadata: `_ingested_at`, `_source_file`, `_file_hash`, `_load_date`.
- Write disposition is deliberate per source:
  - `replace` — full snapshot extracts where only the latest state matters (e.g. master inventory).
  - `append` — point-in-time / event sources where history matters (e.g. daily status). Partition on `_load_date`.
  - `merge` — when the source provides a reliable primary key and you want upsert semantics.

### 5.2 Write-disposition decision

| Disposition | When to use | Trade-off |
|---|---|---|
| `replace` | Latest-state-only full extracts | Simple; loses history (recover via dbt snapshot). |
| `append` | Daily/periodic snapshots, events | Keeps history; bronze grows; needs dedup downstream. |
| `merge` | Source has stable PK; want upsert | Idempotent; requires trustworthy key + merge config. |

### 5.3 Idempotency & re-runs

Re-running the pipeline on an unchanged file must be a no-op. Use `_file_hash` to detect identical loads; use `_load_date` to make append loads idempotent per day.

### 5.4 Pipeline reference

| Item | Value |
|---|---|
| Pipeline name | «pipeline_name» |
| Destination | «postgres / bigquery / …» |
| Bronze dataset / schema | `bronze` |
| Secrets location | «.dlt/secrets.toml / env / vault» |
| Schedule | «cron expression» |

---

## 6. Transformation Layer — dbt → Silver & Gold

### 6.1 Project structure

```text
models/
  staging/      (silver)  stg_<source>.sql        — view, 1:1, clean+cast
    _staging__sources.yml  _staging__models.yml
  intermediate/ (silver)  int_<concept>.sql       — conform / integrate
  marts/        (gold)    dim_<entity>.sql
                          fct_<process>.sql
    _marts__models.yml
snapshots/                <source>_snapshot.sql   — SCD2 for history
tests/                    assert_<rule>.sql       — singular tests
macros/                   reusable SQL / checks
```

### 6.2 Layer materialization policy

| Folder | Materialized as | Why |
|---|---|---|
| `staging` | view | Cheap, always-fresh thin wrappers over bronze. |
| `intermediate` | view / ephemeral | Composition layer; persist as table only if reused heavily. |
| `marts` | table | Fast BI reads; stable, queried often by Grafana. |
| `snapshots` | table (SCD2) | Captures change history dbt manages via `dbt snapshot`. |

### 6.3 Naming conventions

| Object | Pattern | Example |
|---|---|---|
| Staging model | `stg_<source>` | `stg_master` |
| Intermediate | `int_<concept>` | `int_server_xref` |
| Dimension | `dim_<entity>` | `dim_server` |
| Fact | `fct_<process>` | `fct_project_overlap` |
| Boolean column | `is_` / `has_` / `in_<x>` | `in_master`, `is_active` |
| Surrogate key | `<entity>_key` | `server_key` |
| Timestamp | `<event>_at` | `ingested_at` |

### 6.4 Join strategy

- Integration models that drive coverage/overlap reporting use **FULL OUTER** joins — orphan rows are the report, not noise. Inner joins silently delete the very rows you want to count.
- Anchor surrogate keys on `coalesce()` of the candidate keys so rows present in only one source still get a stable key.
- Pick **one source as system-of-record** for any attribute duplicated across sources (e.g. `lifecycle_state`). Keep the others for drift/staleness reporting.

---

## 7. Data Model

### 7.1 Model catalog

Catalogue every silver and gold model. This is the map maintainers read first.

| Model | Layer | Materialized | Purpose |
|---|---|---|---|
| `stg_«source»` | Silver | view | «clean 1:1 of source» |
| `int_«concept»` | Silver | view | «conformed spine / bridge» |
| `dim_«entity»` | Gold | table | «conformed dimension» |
| `fct_«process»` | Gold | table | «aggregate fact for BI» |

### 7.2 Lineage

```text
bronze.<source_a>  ─► stg_a ─┐
bronze.<source_b>  ─► stg_b ─┼─► int_<concept> ─┬─► dim_<entity>
bronze.<source_c>  ─► stg_c ─┘                  ├─► fct_<process_1>
                                                 └─► fct_<process_2>
```

### 7.3 Key model contract

*(repeat per gold model)*

| Column | Type | Key? | Nullable | Description |
|---|---|---|---|---|
| «col» | varchar | PK | No | «…» |
| «col» | boolean | — | No | «…» |
| «col» | timestamp | — | Yes | «…» |

---

## 8. Data Quality & Testing

### 8.1 Test coverage policy

- Every model exposes a primary/surrogate key tested `unique` + `not_null`.
- Source freshness tests on every bronze table (warn / error thresholds).
- Relationship tests across the bridge key; a singular test asserting **minimum match rate** so a broken join fails the build instead of silently shipping.
- `accepted_values` tests on low-cardinality status/lifecycle columns.

### 8.2 Test register

| Test | Type | Threshold / expectation |
|---|---|---|
| Key uniqueness | schema (`unique`) | 0 duplicates |
| Bridge match rate | singular | «≥ __%» |
| Source freshness | freshness | warn «__h» / error «__h» |
| Status domain | `accepted_values` | «list valid values» |

### 8.3 Data-quality reports as marts

Treat DQ as a first-class output: surface orphan rows, null keys, duplicates, and cross-source disagreement (e.g. system-of-record says retired, project still tracks active) as their own gold marts/panels rather than hiding them.

---

## 9. Reporting Layer — Grafana

### 9.1 Conventions

- Grafana reads **gold only**, via a read-only warehouse role. Never query silver/bronze from dashboards.
- Datasources and dashboards are provisioned **as code** (YAML + JSON in the repo), not hand-built in the UI.
- One panel = one gold model query where possible; keep SQL in the mart, not the panel.

### 9.2 Report catalogue

| Report / panel | Backing gold model | Audience |
|---|---|---|
| «overview / counts» | `fct_«…»` | «…» |
| «overlap matrix» | `fct_«…»` | «…» |
| «coverage gaps» | `fct_«…»` | «…» |
| «trend over time» | «snapshot» | «…» |

---

## 10. Operations

### 10.1 Orchestration & schedule

| Stage | Command / trigger |
|---|---|
| Ingest | `python ingestion/pipeline.py` |
| Snapshot | `dbt snapshot` |
| Build + test | `dbt build` |
| Schedule | «cron / Airflow DAG / Actions workflow» |
| Run order | `ingest → snapshot → build` |

### 10.2 Monitoring & alerting

- Alert on pipeline failure, failed dbt tests, and stale source freshness.
- Route alerts to «channel / on-call».

### 10.3 SLAs

| Metric | Target | Owner |
|---|---|---|
| Freshness (data age) | «≤ __h» | «…» |
| Pipeline runtime | «≤ __min» | «…» |
| Availability | «__%» | «…» |

### 10.4 Access & security

- Warehouse roles: `ingest` (write bronze), `transform` (write silver/gold), `report` (read gold only).
- Secrets via «vault / env / .dlt secrets»; never committed.
- PII handling: «classify, mask, or confirm none present».

---

## 11. Glossary & Open Items

### 11.1 Glossary

| Term | Definition |
|---|---|
| Medallion | Bronze/silver/gold tiering of data by progressive quality and refinement. |
| Bridge table | A source carrying two identifier namespaces, used to join sources that share no direct key. |
| SCD2 | Slowly-changing dimension type 2 — retains history with valid-from/valid-to rows. |
| Orphan | A row present in one source but not its expected counterpart; a coverage signal. |
| «term» | «…» |

### 11.2 Assumptions, risks & open questions

1. «Assumption / risk — e.g. join key X unverified against source Y»
2. «Open question — owner — due date»
3. «Known limitation — e.g. transitive joins inherit bridge coverage gaps»
