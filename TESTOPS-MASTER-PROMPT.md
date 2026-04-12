# TestOps Master Prompt
## Reusable context prompt for all future conversations about this project

---

## HOW TO USE THIS PROMPT

Paste the entire content below the horizontal rule into the **first message**
of any new Claude conversation about this project. Claude will have full
context and can continue exactly where you left off — generating code,
debugging, extending the framework, or producing documentation.

You can append your specific question after the prompt, for example:

> [paste prompt] ... Now help me write the test_vm_migration.py file.

---

---

# PROJECT CONTEXT: TestOps Framework for OpenShift Virtualization Platform

## Who I am and what I am building

I am a platform engineer building an internal developer platform around
**OpenShift Virtualization (KubeVirt)**, **ArgoCD GitOps**, **FastAPI**,
**PostgreSQL**, and **Ansible Automation Platform (AAP)**. My infrastructure
runs across a large **Azure multi-subscription estate** and covers
**VM lifecycle management**, **self-service provisioning**, and
**infrastructure automation** across dev / test / UAT / prod environments.

I am building a **TestOps validation framework** using **pytest** to
validate the OpenShift cluster and all platform components. The framework
must support two deployment models — one led by Jenkins, one led by AAP —
because my organisation may mandate AAP as the central automation hub.

---

## Core technology stack

| Layer | Technology |
|---|---|
| Container platform | OpenShift 4.x (OCP) with KubeVirt / OpenShift Virtualization |
| GitOps | ArgoCD — two-tier approval (auto dev/test, PR-based UAT/prod) |
| VM API | FastAPI + KubeVirt VMI CRDs |
| Database | PostgreSQL (async SQLAlchemy, Alembic migrations) |
| Automation | Ansible Automation Platform (AAP) 2.5+ |
| Secret management | HashiCorp Vault (Vault Agent sidecar injection) |
| Event streaming | Apache Kafka (confluent-kafka Python client) |
| Observability | Prometheus, Splunk HEC, OpenTelemetry |
| CI/CD | Jenkins (primary), Azure DevOps not used |
| Languages | Python 3.12 (primary), Go (secondary), Rust (learning) |
| IaC | Terraform, Azure DevOps, OpenShift GitOps |

---

## TestOps framework — what has been designed and built

### Test domains

The framework validates six platform domains. Each maps to a directory
under `tests/` and a pytest marker:

| Domain | Marker | What it validates |
|---|---|---|
| Cluster | `cluster` | Node health, etcd, operator CSV status, MachineConfig |
| Network | `network` | OVN-K, Multus/Whereabouts IPAM, DNS, egress IP, NetworkPolicy |
| Storage | `storage` | CSI drivers, StorageClass, PVC binding, CDI DataVolume (KubeVirt) |
| VM Lifecycle | `vm` | Create/start/stop/delete VMI, live migration, snapshot, guest OS |
| Security | `security` | SCC, RBAC, RoleBindings, NetworkPolicy isolation, Vault injection |
| Compliance | `compliance` | OPA/Gatekeeper constraints, OpenSCAP profiles, compliance operator |
| Monitoring | `monitoring` | Prometheus alert rules, scrape targets, Splunk HEC log forwarding |

Additional markers: `smoke` (fast subset), `slow` (>120s), `flaky` (known intermittent).

---

## Repository structure

```
testops/
├── Jenkinsfile                        # Pipeline with Build Parameters for scaling
├── pyproject.toml                     # Deps + tool config (no setup.py)
├── pytest.ini                         # Markers, asyncio_mode, log format, junit
├── conftest.py                        # THE most important file — see below
│
├── tests/
│   ├── cluster/
│   ├── network/
│   ├── storage/
│   ├── vm/
│   ├── security/
│   ├── monitoring/
│   └── compliance/
│       └── conftest.py                # Domain-level fixtures (inherit root)
│
├── plugins/
│   ├── kafka_plugin.py                # pytest hooks → Kafka event stream
│   └── allure_enricher.py             # Custom Allure Epic/Feature/Story labels
│
├── lib/
│   ├── aap_client.py                  # AAP 2.5+ REST client (requests, NOT awxkit)
│   ├── kafka_producer.py              # Thread-safe non-blocking Kafka producer
│   ├── kafka_events.py                # Pydantic event models (typed payloads)
│   └── assertions.py                  # Custom assertion helpers
│
├── fixtures/
│   ├── aap_fixtures.py                # auto_remediate (Jenkins-led only)
│   ├── cluster_fixtures.py
│   └── vm_fixtures.py
│
├── scripts/
│   ├── poll_aap_job.py                # CLI: poll AAP job/workflow to terminal state
│   ├── fetch_aap_artifacts.py         # CLI: download JUnit/Allure from AAP artifacts
│   └── generate_env_props.py          # Writes allure environment.properties at runtime
│
├── allure-categories.json             # Custom failure category rules (OCP-specific)
│
└── docker/
    └── Dockerfile                     # Pinned test runner image (avoids dep drift)
```

---

## conftest.py — the most important file

`conftest.py` is pytest's **dependency injection and plugin wiring layer**.
It is auto-discovered — no imports needed in test files. It does five jobs:

1. **Plugin registration** via `pytest_plugins = [...]`
   Order matters: `kafka_plugin` before `aap_fixtures` so the producer
   exists when remediation emits events.

2. **Session-scoped clients** — `k8s_core`, `k8s_custom`, `ocp` (DynamicClient),
   `aap_client_session`, `kafka_producer`. Created once, shared across all
   xdist workers. Never function-scoped — would hammer the OCP API.

3. **CLI options** via `pytest_addoption` — `--env`, `--cluster`,
   `--namespace`, `--vm-profile`, `--kafka-bootstrap`, `--kafka-tls`.
   These map directly to Jenkins Build Parameters.

4. **Autouse fixtures** — `attach_test_metadata` stamps `_correlation_id`
   and `_session_id` on every test item automatically.
   `log_test_boundaries` logs START/END markers for every test.

5. **Hook: `pytest_runtest_makereport`** — captures the call-phase
   `TestReport` onto `item._last_call_report` so `auto_remediate` can
   read the outcome post-yield.

**SESSION_ID source:**
- Jenkins-led: `os.getenv("TESTOPS_SESSION_ID")` — set by Jenkins
- AAP-led: `os.getenv("AWX_JOB_ID")` — auto-injected by AAP

---

## Key architectural decisions already made

### Tool choices

| Concern | Tool chosen | Explicitly rejected |
|---|---|---|
| K8s/OCP resource state | `kubernetes` Python client + `openshift` DynamicClient | kubectl/oc CLI |
| AAP API interaction | `requests` direct to `/api/controller/v2/` | `awxkit` (inactive, broken on AAP 2.5) |
| Guest OS checks (SSH) | `ansible-runner` (local execution) | AAP REST per test (too slow) |
| Parallel execution | `pytest-xdist` | Threading/multiprocessing manually |
| Kafka producer | `confluent-kafka` (librdkafka native) | `kafka-python` (no linger.ms/compression) |
| Allure report | `allure-pytest` + `allure-jenkins-plugin` | Extent reports, custom HTML |

### ansible-runner vs AAP — critical distinction

`ansible-runner` **cannot** invoke AAP job templates. It runs Ansible
**locally** on the machine where Python is executing. The correct tools
for invoking AAP programmatically are:
- `requests` against `/api/controller/v2/` (what `aap_client.py` uses)
- `awxkit` — avoid, project is inactive and broken on AAP 2.5+

AAP 2.5+ uses a Platform Gateway with two API roots:
- Auth/tokens: `/api/gateway/v1/`
- Jobs/templates/workflows: `/api/controller/v2/`

### Two deployment models

**Model A — Jenkins-led (recommended default):**
- Jenkins orchestrates everything via `Jenkinsfile`
- pytest is the assertion engine with full plugin ecosystem
- `ansible-runner` for guest OS checks (local SSH)
- AAP called via `aap_client.py` REST only for post-failure remediation
- `auto_remediate` fixture fires per-test inside pytest session
- xdist worker-level parallelism (N processes, one machine/pod)

**Model B — AAP-led (when organisation mandates AAP):**
- AAP Workflow Template orchestrates job template chain
- pytest runs inside a custom Execution Environment (EE) container
  built with `ansible-builder`
- Jenkins reduced to: launch workflow → poll → fetch artifacts → publish Allure
- No `auto_remediate` fixture — remediation is a workflow failure branch
- Two-level parallelism: domain-level (AAP job nodes) + xdist inside each job
- Session ID = `AWX_JOB_ID` (auto-injected by AAP)

---

## Kafka event streaming

Every test lifecycle event streams to Kafka in real time via a
non-blocking background thread queue. pytest hooks never block on broker ACKs.

**Topics:**
- `testops.session` — session start/end, key: `session_id`
- `testops.results` — per-test pass/fail/skip, key: `node_id` (ordered)
- `testops.ansible` — AAP remediation outcomes, key: `node_id`
- `testops.logs`    — warnings and log records, key: `session_id`

**Event types (Pydantic models):**
`session.start`, `session.end`, `test.start`, `test.passed`,
`test.failed`, `test.error`, `test.skipped`, `ansible.result`, `warning`

**Every event carries:**
- `event_id` — UUID
- `session_id` — ties to Jenkins build / AAP job
- `correlation_id` — UUID per test, links Kafka + Allure + AAP events
- `node_id` — pytest node id (e.g. `tests/vm/test_lifecycle.py::test_create`)
- `markers` — list of pytest markers on the test
- `duration_ms`, `outcome`, `longrepr` (capped at 4 KB)

---

## Allure report structure

**Hierarchy (Epic → Feature → Story):**

| Marker | Epic | Feature |
|---|---|---|
| `cluster`, `network`, `storage` | Platform Health | Cluster / Network / Storage |
| `vm` | VM Lifecycle | Virtual Machines |
| `security`, `compliance` | Security & Compliance | Security Controls / Compliance Policies |
| `monitoring` | Observability | Monitoring & Logging |

**Custom failure categories** (`allure-categories.json`):
VM provisioning failures, Storage failures, Network failures,
AAP remediation failures, Cluster health failures,
Security/RBAC failures, Compliance violations,
Test infrastructure errors, Flaky tests.

**Environment tab** populated at runtime by `scripts/generate_env_props.py`
from Jenkins env vars: cluster name, OCP version, git commit, session ID,
worker count, namespace.

---

## Jenkins pipeline — build parameters for scaling

| Parameter | Default | Description |
|---|---|---|
| `TEST_ENV` | `dev` | choice: dev / test / uat / prod |
| `OCP_CLUSTER` | `ocp-dev-01` | Cluster name (kubeconfig context) |
| `PYTEST_MARKERS` | `cluster or network or storage or vm` | pytest -m expression |
| `PYTEST_KEYWORD` | _(empty)_ | pytest -k filter |
| `PARALLEL_MODE` | `loadfile` | xdist dist: loadfile / load / loadscope / no |
| `WORKER_COUNT` | `4` | xdist workers 1–16 |
| `TEST_TIMEOUT` | `300` | Per-test timeout seconds |
| `RERUN_FAILURES` | `1` | pytest-rerunfailures count |
| `RERUN_DELAY` | `5` | Seconds between retries |
| `VM_PROFILE` | `rhel9-small` | KubeVirt VM profile |
| `WORKER_CPU_REQUEST` | `500m` | Pod CPU request |
| `WORKER_CPU_LIMIT` | `2000m` | Pod CPU limit |
| `WORKER_MEM_REQUEST` | `512Mi` | Pod memory request |
| `WORKER_MEM_LIMIT` | `2Gi` | Pod memory limit |
| `PUBLISH_ALLURE` | `true` | Generate and publish Allure |

**xdist mode guidance:**
- `loadfile` — all tests from one file on same worker. Use for VM tests (stateful).
- `load` — pure round-robin. Fastest. Use for stateless cluster/network checks.
- `loadscope` — group by module/class. Use for compliance (shared session fixtures).
- VM lifecycle: max 2–3 workers (OCP API rate limits).

---

## AAP integration — remediation template map

```python
REMEDIATION_TEMPLATES = {
    "vm":         int(os.getenv("AAP_TEMPLATE_VM",         "10")),
    "storage":    int(os.getenv("AAP_TEMPLATE_STORAGE",    "11")),
    "network":    int(os.getenv("AAP_TEMPLATE_NETWORK",    "12")),
    "security":   int(os.getenv("AAP_TEMPLATE_SECURITY",   "13")),
    "compliance": int(os.getenv("AAP_TEMPLATE_COMPLIANCE", "14")),
    "cluster":    int(os.getenv("AAP_TEMPLATE_CLUSTER",    "15")),
}
```

In Jenkins-led: `auto_remediate` fixture fires per-test, calls
`aap_client.run_job_template()`, emits Kafka event, appends result
to JUnit longrepr. Original failure is preserved — never silenced.

In AAP-led: no per-test AAP call. Workflow failure branch triggers
remediation job template at domain level.

---

## Python dependencies (pyproject.toml)

```toml
[project.optional-dependencies]
test = [
    "pytest==8.2.2",
    "pytest-asyncio==0.23.7",
    "pytest-xdist==3.5.0",
    "pytest-rerunfailures==14.0",
    "pytest-timeout==2.3.1",
    "allure-pytest==2.13.5",
    "kubernetes==30.1.0",
    "openshift==0.13.2",
    "confluent-kafka==2.4.0",
    "httpx==0.27.0",
    "requests==2.32.3",
    "pydantic==2.7.4",
    "ansible-runner==2.4.0",
]
```

Note: `awxkit` is NOT used. AAP interaction is via `requests` directly.

---

## Environment variables reference

```bash
# Kubernetes (per-env overrides supported)
KUBECONFIG=/path/to/kubeconfig
KUBECONFIG_DEV=/path/to/dev-kubeconfig
KUBECONFIG_PROD=/path/to/prod-kubeconfig

# Kafka
KAFKA_BOOTSTRAP=kafka.internal.corp:9092
KAFKA_SASL_USER=<vault-injected>
KAFKA_SASL_PASS=<vault-injected>

# AAP (2.5+ gateway URL)
AAP_URL=https://aap.corp.internal
AAP_TOKEN=<vault-injected OAuth2 PAT>
AAP_VERIFY_TLS=true
AAP_REMEDIATION_TIMEOUT=300
AAP_TEMPLATE_VM=10
AAP_TEMPLATE_STORAGE=11
AAP_TEMPLATE_NETWORK=12
AAP_TEMPLATE_SECURITY=13
AAP_TEMPLATE_COMPLIANCE=14
AAP_TEMPLATE_CLUSTER=15

# Vault
VAULT_TOKEN=<vault-injected>

# Runtime (set by Jenkins or AAP)
TESTOPS_SESSION_ID=<uuid>            # Jenkins-led
AWX_JOB_ID=<aap-job-id>             # AAP-led (auto-injected)
BUILD_NUMBER=<jenkins-build-number>
GIT_COMMIT=<sha>
TEST_ENV=dev
OCP_CLUSTER=ocp-dev-01
TEST_NAMESPACE=testops-runner
VM_PROFILE=rhel9-small
PYTEST_WORKERS=4
```

---

## What has been fully designed and documented

- [x] Full pytest framework architecture with all 7 test domains
- [x] `conftest.py` — full annotated implementation, both models
- [x] `plugins/kafka_plugin.py` — all pytest hooks, background thread queue
- [x] `plugins/allure_enricher.py` — Epic/Feature/Story, custom labels
- [x] `lib/kafka_producer.py` — non-blocking confluent-kafka producer
- [x] `lib/kafka_events.py` — Pydantic event models with topic routing
- [x] `lib/aap_client.py` — AAP 2.5+ REST client (gateway + controller URLs)
- [x] `fixtures/aap_fixtures.py` — auto_remediate with Kafka emit + JUnit annotation
- [x] `scripts/poll_aap_job.py` — CLI poller for both jobs and workflow jobs
- [x] `scripts/generate_env_props.py` — Allure environment tab at runtime
- [x] `allure-categories.json` — OCP-specific failure category rules
- [x] `Jenkinsfile` — full pipeline with all scaling Build Parameters
- [x] `pyproject.toml` + `pytest.ini` — complete configuration
- [x] README: Jenkins-led architecture (full)
- [x] README: AAP-led architecture (full, including EE build + workflow template)
- [x] Repo structure decision: `testops` repo separate from `platform` GitOps repo
- [x] AAP 2.5 API URL structure clarification (`/api/controller/v2/`)
- [x] `awxkit` deprecation — confirmed inactive, use `requests` directly

## What has NOT yet been implemented (next steps)

- [ ] Individual test files (`test_nodes.py`, `test_vm_lifecycle.py`, etc.)
- [ ] `fixtures/cluster_fixtures.py` — node list, operator CSV helpers
- [ ] `fixtures/vm_fixtures.py` — create_vm, wait_for_running, vm_semaphore
- [ ] `scripts/fetch_aap_artifacts.py` — download artifacts from AAP jobs
- [ ] `execution-environment/` — ansible-builder EE for AAP-led model
- [ ] `aap/workflow-template.yml` — full AAP workflow as code
- [ ] Subdirectory `conftest.py` files per domain
- [ ] `Makefile` — local run targets: make smoke, make vm, make full
- [ ] Docker test runner image (`docker/Dockerfile`)

---

## Conventions and standards I follow

- Python 3.12, Pydantic v2 (`model_dump_json()` not `.json()`)
- Async-first where possible (`asyncio_mode = auto`)
- All fixtures use type annotations
- No `print()` — always `log = logging.getLogger(__name__)`
- Kafka events capped: longrepr 4 KB, stdout tail 1 KB
- Correlation IDs are UUIDs, generated per test in `attach_test_metadata`
- OCP API calls use the `DynamicClient` for CRDs, typed clients for core resources
- Secrets always via Vault — never hardcoded, never in env files committed to git
- xdist workers share session fixtures; never put mutable state in session scope
- AAP remediation never silences test failures — original outcome is always preserved

---

## My preferred response style for this project

- Show full working code, not pseudocode or skeleton outlines
- Include type annotations on all functions and fixtures
- Add inline comments explaining *why*, not just *what*
- When showing pytest fixtures, always show the scope and explain the choice
- When showing Kafka events, always include the topic routing logic
- Flag any decision that differs between Jenkins-led and AAP-led models
- If generating test files, follow the domain marker convention strictly
