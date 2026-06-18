# VM Platform — Ansible Scheduler

Distributed, event-driven Ansible job scheduler built on **FastAPI + Gunicorn + PostgreSQL**.  
Designed for Kubernetes multi-pod deployments with **zero polling** and **no shared filesystem**.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Database Schema](#database-schema)
- [Process Diagrams](#process-diagrams)
  - [Kubernetes Pod and Worker Layout](#1-kubernetes-pod-and-worker-layout)
  - [Startup Sequence](#2-startup-sequence)
  - [Plugin Save and Hot-Reload](#3-plugin-save-and-hot-reload)
  - [Schedule Execution Flow](#4-schedule-execution-flow)
  - [Stale Lock Recovery](#5-stale-lock-recovery)
- [Plugin Contract](#plugin-contract)
- [User Workflow](#user-workflow)
- [API Reference](#api-reference)
- [Configuration](#configuration)
- [Local Development](#local-development)
- [Trigger Reference](#trigger-reference)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Kubernetes Cluster                          │
│                                                                     │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐         │
│   │    Pod 1     │    │    Pod 2     │    │    Pod N     │         │
│   │  4 workers   │    │  4 workers   │    │  4 workers   │         │
│   └──────┬───────┘    └──────┬───────┘    └──────┬───────┘         │
│          │                   │                   │                  │
│          └───────────────────┼───────────────────┘                  │
│                              │ asyncpg connections                  │
│                 ┌────────────▼────────────┐                         │
│                 │       PostgreSQL        │                         │
│                 │                        │                         │
│                 │  platform.plugins      │                         │
│                 │  platform.plugin_test_ │                         │
│                 │    runs               │                         │
│                 │  platform.schedules   │ ← job store              │
│                 │                        │                         │
│                 │  NOTIFY channels:      │                         │
│                 │    vm_scheduler        │ ← schedule events        │
│                 │    vm_plugin_reload    │ ← plugin hot-reload      │
│                 └────────────────────────┘                         │
│                                                                     │
│   ┌────────────────────────────────────────────────────────────┐   │
│   │  Ansible Automation Platform (AAP)  or  local playbooks   │   │
│   └────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Key design decisions

| Concern | Solution |
|---|---|
| No duplicate job fires across pods/workers | `SELECT FOR UPDATE SKIP LOCKED` |
| No shared filesystem between pods | Plugin source stored in `platform.plugins` |
| Zero polling overhead | PostgreSQL `LISTEN/NOTIFY` + `asyncio.sleep(δt)` |
| No request lifecycle interference | Scheduler runs as two background asyncio Tasks |
| Pod crash recovery | Boot recovery re-populates heap from DB on restart |
| Hot-reload plugins without restart | `pg_notify('vm_plugin_reload')` on every save |

---

## Project Structure

```
.
├── main.py                          # FastAPI app — wires everything together
├── gunicorn.conf.py                 # Gunicorn config
├── requirements.txt
│
├── scheduler/
│   ├── models.py                    # SQLAlchemy ORM — Plugin, PluginTestRun, Schedule
│   ├── schemas.py                   # Pydantic v2 request/response schemas
│   ├── trigger_calc.py              # next_run_at computation (cron/interval/date)
│   ├── notify.py                    # pg_notify helpers (inside transactions)
│   │
│   ├── plugin_loader.py             # DB-backed registry, exec() sandbox, NOTIFY listener
│   ├── plugin_service.py            # Plugin CRUD business logic
│   ├── plugin_router.py             # Plugin API endpoints
│   │
│   ├── schedule_service.py          # Schedule CRUD business logic
│   ├── schedule_router.py           # Schedule API endpoints
│   │
│   └── scheduler.py                 # LISTEN/NOTIFY dispatcher + heapq + ThreadPoolExecutor
│
├── migrations/
│   └── V001__platform_schema.sql    # All three tables + indexes + triggers
│
└── plugins/
    └── examples.py                  # Example plugin source code snippets
```

---

## Database Schema

```
platform.plugins
┌─────────────────────────────────────────────────────────────────┐
│ id            UUID PK                                           │
│ name          TEXT UNIQUE       ← stable FK target for schedules│
│ description   TEXT                                              │
│ source_code   TEXT              ← Python plugin code (in DB)   │
│ trigger_type  TEXT              ← cron | interval | date        │
│ trigger_args  JSONB             ← default trigger for schedules │
│ is_active     BOOLEAN                                           │
│ version       INT               ← incremented on each update   │
│ last_tested_at     TIMESTAMPTZ                                  │
│ last_test_status   TEXT                                         │
│ last_test_output   TEXT                                         │
│ created_by    TEXT                                              │
│ updated_by    TEXT                                              │
│ created_at    TIMESTAMPTZ                                       │
│ updated_at    TIMESTAMPTZ                                       │
└─────────────────────────────────────────────────────────────────┘

platform.plugin_test_runs
┌─────────────────────────────────────────────────────────────────┐
│ id            UUID PK                                           │
│ plugin_name   TEXT              ← snapshot; survives deletion   │
│ plugin_id     UUID FK → plugins.id (SET NULL on delete)        │
│ ran_by        TEXT                                              │
│ extra_vars    JSONB                                             │
│ status        TEXT              ← success | failure | error     │
│ output        TEXT                                              │
│ error         TEXT                                              │
│ duration_ms   INT                                               │
│ ran_at        TIMESTAMPTZ                                       │
└─────────────────────────────────────────────────────────────────┘

platform.schedules
┌─────────────────────────────────────────────────────────────────┐
│ id            UUID PK                                           │
│ name          TEXT                                              │
│ description   TEXT                                              │
│ plugin_name   TEXT FK → plugins.name                           │
│               ON UPDATE CASCADE   ← rename plugin, FK follows  │
│               ON DELETE RESTRICT  ← can't delete plugin with   │
│                                     active schedules           │
│ trigger_type  TEXT              ← overrides plugin default      │
│ trigger_args  JSONB                                             │
│ extra_vars    JSONB             ← passed to plugin.run()        │
│ enabled       BOOLEAN                                           │
│                                                                 │
│ ── Scheduler state (this IS the job store) ──────────────────── │
│ next_run_at       TIMESTAMPTZ  ← primary dispatch key           │
│ last_run_at       TIMESTAMPTZ                                   │
│ last_run_status   TEXT         ← success | failure | running    │
│ last_run_output   TEXT                                          │
│ run_count         BIGINT                                        │
│ failure_count     BIGINT                                        │
│                                                                 │
│ ── Distributed lock ─────────────────────────────────────────── │
│ locked_at     TIMESTAMPTZ     ← set when worker claims the row  │
│ locked_by     TEXT            ← 'hostname:pid' of that worker   │
│                                                                 │
│ created_by    TEXT                                              │
│ updated_by    TEXT                                              │
│ created_at    TIMESTAMPTZ                                       │
│ updated_at    TIMESTAMPTZ                                       │
└─────────────────────────────────────────────────────────────────┘

Indexes:
  idx_schedules_poll     (next_run_at, locked_at) WHERE enabled = TRUE
  idx_schedules_plugin   (plugin_name)
  idx_plugins_is_active  (is_active)
  idx_test_runs_plugin   (plugin_id)
  idx_test_runs_ran_at   (ran_at DESC)
```

---

## Process Diagrams

### 1. Kubernetes Pod and Worker Layout

Each Kubernetes pod runs one Gunicorn **master** and N **UvicornWorker** processes.  
Every worker is an independent OS process with its own event loop and DB connections.

```
┌──────────────────────────────────────────────────────────────────────┐
│  Kubernetes Pod  (e.g. replicas: 3)                                  │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  Gunicorn Master Process                                     │   │
│  │  (manages worker lifecycle only — no requests handled here)  │   │
│  └──────────────────────────────────────────────────────────────┘   │
│        │ fork()          │ fork()           │ fork()                 │
│        ▼                 ▼                  ▼                        │
│  ┌───────────┐    ┌───────────┐    ┌─────────────┐                  │
│  │ Worker 1  │    │ Worker 2  │    │  Worker N   │                  │
│  │ (uvicorn) │    │ (uvicorn) │    │  (uvicorn)  │                  │
│  │           │    │           │    │             │                  │
│  │ asyncio   │    │ asyncio   │    │  asyncio    │                  │
│  │ event loop│    │ event loop│    │  event loop │                  │
│  │           │    │           │    │             │                  │
│  │ ┌───────┐ │    │ ┌───────┐ │    │  ┌───────┐  │                  │
│  │ │FastAPI│ │    │ │FastAPI│ │    │  │FastAPI│  │                  │
│  │ │routes │ │    │ │routes │ │    │  │routes │  │                  │
│  │ └───────┘ │    │ └───────┘ │    │  └───────┘  │                  │
│  │           │    │           │    │             │                  │
│  │ ┌───────┐ │    │ ┌───────┐ │    │  ┌───────┐  │                  │
│  │ │Plugin │ │    │ │Plugin │ │    │  │Plugin │  │                  │
│  │ │Loader │ │    │ │Loader │ │    │  │Loader │  │                  │
│  │ │LISTEN │ │    │ │LISTEN │ │    │  │LISTEN │  │                  │
│  │ │Task   │ │    │ │Task   │ │    │  │Task   │  │                  │
│  │ └───────┘ │    │ └───────┘ │    │  └───────┘  │                  │
│  │           │    │           │    │             │                  │
│  │ ┌───────┐ │    │ ┌───────┐ │    │  ┌───────┐  │                  │
│  │ │Sched. │ │    │ │Sched. │ │    │  │Sched. │  │                  │
│  │ │Listen │ │    │ │Listen │ │    │  │Listen │  │                  │
│  │ │Task   │ │    │ │Task   │ │    │  │Task   │  │                  │
│  │ └───────┘ │    │ └───────┘ │    │  └───────┘  │                  │
│  │           │    │           │    │             │                  │
│  │ ┌───────┐ │    │ ┌───────┐ │    │  ┌───────┐  │                  │
│  │ │Sched. │ │    │ │Sched. │ │    │  │Sched. │  │                  │
│  │ │Dispatch│ │   │ │Dispatch│ │   │  │Dispatch│  │                 │
│  │ │Task   │ │    │ │Task   │ │    │  │Task   │  │                  │
│  │ └───────┘ │    │ └───────┘ │    │  └───────┘  │                  │
│  │           │    │           │    │             │                  │
│  │ ┌───────┐ │    │ ┌───────┐ │    │  ┌───────┐  │                  │
│  │ │Thread │ │    │ │Thread │ │    │  │Thread │  │                  │
│  │ │Pool   │ │    │ │Pool   │ │    │  │Pool   │  │                  │
│  │ │Ansible│ │    │ │Ansible│ │    │  │Ansible│  │                  │
│  │ └───────┘ │    │ └───────┘ │    │  └───────┘  │                  │
│  └───────────┘    └───────────┘    └─────────────┘                  │
└──────────────────────────────────────────────────────────────────────┘

Each worker has:
  • Its own asyncio event loop
  • Its own in-memory plugin registry (dict)
  • Its own asyncpg LISTEN connection (one per channel)
  • Its own min-heap of pending schedule fire times
  • Its own ThreadPoolExecutor (Ansible never blocks the event loop)

Workers do NOT share memory — deduplication is handled by PostgreSQL.
```

---

### 2. Startup Sequence

```
Gunicorn starts
      │
      ├─ fork() → Worker 1
      │              │
      │         lifespan() begins
      │              │
      │         ① create_async_engine()
      │              └─ asyncpg connection pool opened
      │
      │         ② init_plugin_loader(session_factory)
      │              │
      │              ├─ SELECT * FROM platform.plugins
      │              │  WHERE is_active = TRUE
      │              │         │
      │              │  for each row:
      │              │    compile(source_code)       ← SyntaxError caught
      │              │    exec(code, namespace)      ← isolated dict
      │              │    validate interface         ← checks METADATA + run()
      │              │    _registry[name] = LoadedPlugin
      │              │
      │              └─ asyncpg LISTEN 'vm_plugin_reload'
      │                   └─ _notify_listener_loop() Task ← running
      │
      │         ③ init_scheduler(session_factory)
      │              │
      │              ├─ asyncpg LISTEN 'vm_scheduler'
      │              │    └─ _listener_loop() Task ← running
      │              │
      │              └─ BOOT RECOVERY:
      │                   SELECT id, next_run_at
      │                   FROM platform.schedules
      │                   WHERE enabled = TRUE
      │                     AND next_run_at IS NOT NULL
      │                          │
      │                   heapq.heappush() for each row
      │                   _dispatcher_loop() Task starts
      │                   asyncio.sleep(δt) until soonest job
      │
      │         Worker 1 ready ✓  (serving HTTP + listening + dispatching)
      │
      ├─ fork() → Worker 2  (identical sequence)
      ├─ fork() → Worker 3  (identical sequence)
      └─ fork() → Worker N  (identical sequence)
```

---

### 3. Plugin Save and Hot-Reload

Plugin source is stored in `platform.plugins`. Every worker reloads automatically
via `pg_notify` when any worker saves or updates a plugin.

```
User → POST /api/v1/plugins
            │
            ▼
      plugin_service.create_plugin()
            │
            ├─ validate_source(source_code)
            │    ├─ compile()            fast — catches SyntaxError
            │    ├─ exec(namespace)      isolated dict
            │    └─ validate interface   checks METADATA + run() signature
            │
            │    ── if invalid → raise ValueError → 422, nothing written ──
            │
            ▼
      BEGIN TRANSACTION
        INSERT INTO platform.plugins (source_code, trigger_type, ...)
        SELECT pg_notify('vm_plugin_reload', 'plugin-name')
      COMMIT
            │
            │  PostgreSQL delivers NOTIFY to every active LISTEN connection
            │  (one per worker, across all pods)
            │
     ───────┴──────────────────────────────────────────────────────
     │              │              │              │
     ▼              ▼              ▼              ▼
  Pod1/W1       Pod1/W2       Pod2/W1       Pod N/WN
     │
_on_plugin_notify(plugin_name) called  ← asyncpg sync callback
     │
loop.call_soon_threadsafe(
  asyncio.ensure_future(
    _reload_one_from_db('plugin-name')
  )
)
     │
     ▼
SELECT * FROM platform.plugins
WHERE name = 'plugin-name'
     │
     ▼
compile() → exec(namespace) → validate interface
     │
     ▼
_registry['plugin-name'] = LoadedPlugin(...)  ← thread-safe write
     │
     ▼
All workers updated ✓ — no pod restart required
```

**Plugin update flow** (same path, version incremented):

```
PUT /api/v1/plugins/{name}
  → validate new source
  → UPDATE plugins SET source_code=..., version=version+1
  → pg_notify('vm_plugin_reload', name)
  → all workers reload new version
```

---

### 4. Schedule Execution Flow

This is the core distributed dispatch. Every worker across every pod participates,
but `SELECT FOR UPDATE SKIP LOCKED` guarantees exactly-once execution per job.

```
                     platform.schedules
               ┌──────────────────────────────┐
               │  id   next_run_at  locked_at  │
               │  AAA  02:30 UTC    NULL       │
               │  BBB  06:00 UTC    NULL       │
               │  CCC  08:15 UTC    NULL       │
               └──────────────────────────────┘
                              │
                              │ pg_notify('vm_scheduler',
                              │   '{"id":"AAA","next_run_at":"02:30"}')
                              │ (sent on: schedule create / update /
                              │          post-execution)
                              │
          ────────────────────┼──────────────────────────
          │                   │                   │
          ▼                   ▼                   ▼
     Pod1/W1             Pod1/W2             Pod2/W1
  _listener_task       _listener_task       _listener_task
  asyncpg LISTEN (one dedicated connection per worker per channel)
          │
  _on_notify() → heapq.heappush((02:30, "AAA")) → _heap_event.set()

  ── All workers now have (02:30, "AAA") in their local heaps ──

  _dispatcher_task:
    asyncio.sleep(δt until 02:30)
    OR
    asyncio.wait_for(_heap_event.wait(), timeout=δt)
    (wakes early if an earlier job arrives via NOTIFY)

  ── 02:30:00 UTC arrives ──

  ── All workers wake simultaneously ──

          │                   │                   │
          ▼                   ▼                   ▼
  _claim_and_dispatch()  _claim_and_dispatch()  _claim_and_dispatch()

          │                   │                   │
          ▼                   ▼                   ▼
     BEGIN TX             BEGIN TX             BEGIN TX
     SELECT * FROM        SELECT * FROM        SELECT * FROM
     schedules            schedules            schedules
     WHERE id='AAA'       WHERE id='AAA'       WHERE id='AAA'
     AND enabled=TRUE     AND enabled=TRUE     AND enabled=TRUE
     AND next_run_at<=now AND next_run_at<=now AND next_run_at<=now
     AND locked_at IS NULL AND locked_at IS NULL AND locked_at IS NULL
     FOR UPDATE           FOR UPDATE           FOR UPDATE
     SKIP LOCKED          SKIP LOCKED          SKIP LOCKED

          │                   │                   │
          ▼                   ▼                   ▼
     ✓ ROW ACQUIRED       ✗ ROW LOCKED         ✗ ROW LOCKED
     locked_at = now()       → None returned      → None returned
     locked_by = 'pod1:123'  → return (no-op)     → return (no-op)
     COMMIT TX

          │
          ▼
  run_in_executor(ThreadPool)     ← Ansible never touches the event loop
          │
  plugin_registry['nightly-patch'].run("AAA", extra_vars)
          │
          ▼ (runs in thread)
  ansible-playbook /playbooks/patch_vms.yml   OR   AAP REST launch
          │
          ▼ (complete)
  _on_done():
    BEGIN TX
      UPDATE schedules SET
        last_run_at     = now(),
        last_run_status = 'success',
        last_run_output = '...',
        next_run_at     = <next cron tick>,
        run_count       = run_count + 1,
        locked_at       = NULL,
        locked_by       = NULL
      SELECT pg_notify('vm_scheduler',
        '{"id":"AAA","next_run_at":"<next>"}')
    COMMIT
          │
          └─► All workers update their heaps with new next_run_at ✓
```

---

### 5. Stale Lock Recovery

Handles pod crashes (OOMKill, node failure, eviction) mid-execution.

```
Normal execution timeline:
  02:30:00  locked_at = '02:30:00'  locked_by = 'pod1-abc:1234'
  02:31:45  job completes
            locked_at = NULL        locked_by = NULL   ← cleared
  next_run_at updated to 02:30 tomorrow

Pod killed mid-execution (OOMKill at 02:31:00):
  02:30:00  locked_at = '02:30:00'  locked_by = 'pod1-abc:1234'
  02:31:00  POD KILLED — locked_at never cleared
  ...
  02:40:00  STALE_LOCK_MINUTES (10) elapsed

Next poll by any surviving worker (Pod2/W1 at 02:40:05):
  SELECT * FROM schedules
  WHERE enabled = TRUE
  AND next_run_at <= now()
  AND (
    locked_at IS NULL
    OR locked_at < now() - INTERVAL '10 minutes'   ← stale threshold
  )
  FOR UPDATE SKIP LOCKED
         │
         ▼
  Stale lock detected → row reclaimed → job re-executed

Configure threshold: SCHEDULER_STALE_LOCK_MIN=10 (default)

  ⚠  Set threshold > longest expected job duration to avoid
     re-running a job that is still legitimately running on
     a slow worker.
```

---

## Plugin Contract

Every plugin saved to `platform.plugins` must implement this interface:

```python
# ── Required ──────────────────────────────────────────────────────────────

METADATA = {
    "name":         "my-plugin",          # str, required
    "description":  "What this does",     # str, required
    "trigger_type": "cron",               # default trigger for new schedules
    "trigger_args": {"hour": "2", "minute": "30"},
}

def run(schedule_id: str, extra_vars: dict) -> tuple[str, str]:
    """
    Called by the scheduler dispatcher (in a thread pool thread).
    Returns: ("success" | "failure", output_string)
    """
    ...

# ── Optional ──────────────────────────────────────────────────────────────

def validate_extra_vars(extra_vars: dict) -> list[str]:
    """
    Called before test runs to validate extra_vars.
    Return a list of error strings. Empty list = valid.
    """
    ...
```

---

## User Workflow

```
Step 1 — Validate (instant, no execution, no DB write)
──────────────────────────────────────────────────────
POST /api/v1/plugins/validate
  body: { "source_code": "..." }
  → { "success": true,  "data": { "valid": true } }
  → { "success": false, "data": { "error": "SyntaxError line 5: ..." } }


Step 2 — Test (executes code, saves run record)
────────────────────────────────────────────────
POST /api/v1/plugins/test
  body: { "source_code": "...", "extra_vars": {"env": "dev"}, "timeout_seconds": 30 }
  → {
      "success": true,
      "data": {
        "result":   { "status": "success", "output": "PLAY [all]...", "duration_ms": 1823 },
        "test_run": { "id": "...", "ran_at": "...", "status": "success" }
      }
    }


Step 3 — Save (validates again, writes to DB, NOTIFY sent)
───────────────────────────────────────────────────────────
POST /api/v1/plugins
  body: {
    "name":         "nightly-patch",
    "description":  "OS patching playbook",
    "source_code":  "...",
    "trigger_type": "cron",
    "trigger_args": { "hour": "2", "minute": "30" }
  }
  → { "success": true, "data": { "id": "...", "version": 1 } }
  → all workers hot-reload within milliseconds via NOTIFY


Step 4 — Create schedule (references saved plugin)
───────────────────────────────────────────────────
POST /api/v1/schedules
  body: {
    "name":        "dev-nightly-patch",
    "plugin_name": "nightly-patch",
    "extra_vars":  { "env": "dev", "inventory": "dev-hosts" }
  }
  → trigger_type/trigger_args omitted → inherited from plugin defaults
  → { "success": true, "data": { "id": "...", "next_run_at": "..." } }
```

---

## API Reference

### Plugins

| Method | Path | Description |
|---|---|---|
| `GET`    | `/api/v1/plugins`                  | List all plugins |
| `GET`    | `/api/v1/plugins/registry`         | In-memory registry for this worker |
| `GET`    | `/api/v1/plugins/{name}`           | Get plugin details |
| `POST`   | `/api/v1/plugins/validate`         | Syntax + interface check (no save, no run) |
| `POST`   | `/api/v1/plugins/test`             | Dry-run with extra_vars (saves test record) |
| `POST`   | `/api/v1/plugins`                  | Save plugin to DB |
| `PUT`    | `/api/v1/plugins/{name}`           | Update plugin source (bumps version) |
| `DELETE` | `/api/v1/plugins/{name}`           | Delete (409 if schedules reference it) |
| `POST`   | `/api/v1/plugins/{name}/test`      | Test a saved plugin |
| `GET`    | `/api/v1/plugins/{name}/test-runs` | Test run history |

### Schedules

| Method | Path | Description |
|---|---|---|
| `GET`    | `/api/v1/schedules`             | List schedules (`?plugin_name=`, `?enabled=`, `?mine_only=`) |
| `GET`    | `/api/v1/schedules/{id}`        | Get schedule |
| `POST`   | `/api/v1/schedules`             | Create schedule |
| `PATCH`  | `/api/v1/schedules/{id}`        | Update schedule |
| `DELETE` | `/api/v1/schedules/{id}`        | Delete schedule |
| `POST`   | `/api/v1/schedules/{id}/enable` | Enable |
| `POST`   | `/api/v1/schedules/{id}/disable`| Disable |

### Health

| Method | Path | Description |
|---|---|---|
| `GET` | `/healthz` | Returns status + number of plugins loaded in this worker |

---

## Configuration

### Required

| Variable | Description |
|---|---|
| `DATABASE_URL` | `postgresql+asyncpg://user:pass@host:5432/db` |

### Scheduler

| Variable | Default | Description |
|---|---|---|
| `SCHEDULER_NOTIFY_CHANNEL` | `vm_scheduler`     | pg_notify channel for schedule events |
| `PLUGIN_NOTIFY_CHANNEL`    | `vm_plugin_reload` | pg_notify channel for plugin hot-reload |
| `SCHEDULER_STALE_LOCK_MIN` | `10`               | Minutes before a lock is treated as stale |
| `SCHEDULER_THREAD_WORKERS` | `5`                | Ansible threads per worker process |
| `SCHEDULER_MAX_OUTPUT`     | `4000`             | Max chars of job output stored in DB |
| `SCHEDULER_BOOT_RECOVERY`  | `true`             | Load pending schedules on startup |
| `GUNICORN_WORKERS`         | `4`                | Workers per pod |
| `DB_POOL_SIZE`             | `5`                | asyncpg pool size per worker |
| `DB_MAX_OVERFLOW`          | `10`               | asyncpg pool overflow per worker |
| `LOG_LEVEL`                | `info`             | Gunicorn log level |

### Ansible (used inside plugins)

| Variable | Description |
|---|---|
| `AAP_BASE_URL` | Ansible Automation Platform base URL |
| `AAP_TOKEN`    | AAP bearer token |

---

## Local Development

```bash
# Start PostgreSQL
docker run -d \
  --name pg-scheduler \
  -e POSTGRES_USER=platform \
  -e POSTGRES_PASSWORD=platform \
  -e POSTGRES_DB=platform \
  -p 5432:5432 \
  postgres:15

# Run migration
psql postgresql://platform:platform@localhost/platform \
  -f migrations/V001__platform_schema.sql

# Install dependencies
pip install -r requirements.txt

# Set required environment variable
export DATABASE_URL="postgresql+asyncpg://platform:platform@localhost/platform"

# Single worker (dev / hot-reload)
uvicorn main:app --reload

# Multi-worker (production-like)
gunicorn main:app --config gunicorn.conf.py
```

---

## Trigger Reference

```jsonc
// Cron — every day at 02:30 UTC
{
  "trigger_type": "cron",
  "trigger_args": { "hour": "2", "minute": "30" }
}

// Cron — weekdays at 08:00 UTC
{
  "trigger_type": "cron",
  "trigger_args": { "hour": "8", "minute": "0", "day_of_week": "mon-fri" }
}

// Cron — every Sunday at 01:00 UTC
{
  "trigger_type": "cron",
  "trigger_args": { "hour": "1", "minute": "0", "day_of_week": "sun" }
}

// Interval — every 6 hours
{
  "trigger_type": "interval",
  "trigger_args": { "hours": 6 }
}

// Interval — every 30 minutes
{
  "trigger_type": "interval",
  "trigger_args": { "minutes": 30 }
}

// Date — one-shot; auto-disables after firing
{
  "trigger_type": "date",
  "trigger_args": { "run_date": "2025-09-01T00:00:00", "timezone": "UTC" }
}
```
