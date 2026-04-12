# TestOps — OpenShift Platform Validation Framework

> **Validate OpenShift Virtualization clusters, networking, storage, VM lifecycle,
> security, compliance, and observability — with real-time Kafka streaming,
> rich Allure reports, and automatic AAP remediation.**

---

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Repository Structure](#repository-structure)
- [Architecture](#architecture)
  - [Jenkins-Led (Default)](#jenkins-led-default)
  - [AAP-Led (Organisation Mandate)](#aap-led-organisation-mandate)
- [conftest.py — How the Framework Is Wired](#conftestpy--how-the-framework-is-wired)
- [Test Domains](#test-domains)
- [Running Tests](#running-tests)
  - [Local Development](#local-development)
  - [Jenkins Pipeline](#jenkins-pipeline)
  - [Parallel Execution Guide](#parallel-execution-guide)
- [Configuration Reference](#configuration-reference)
- [Allure Reports](#allure-reports)
- [Kafka Event Streaming](#kafka-event-streaming)
- [AAP Integration](#aap-integration)
  - [Why Not ansible-runner?](#why-not-ansible-runner)
  - [Remediation Template Map](#remediation-template-map)
- [Writing New Tests](#writing-new-tests)
- [Migration from Legacy Codebase](#migration-from-legacy-codebase)
- [Troubleshooting](#troubleshooting)
- [Jenkins Plugin Requirements](#jenkins-plugin-requirements)

---

## Overview

TestOps is a **pytest-based platform validation framework** for OpenShift
Virtualization environments. It replaces a single `test_common_module.py`
God-file with a structured, domain-separated, observable, and self-healing
test suite.

### What it validates

| Domain | Marker | Scope |
|--------|--------|-------|
| Cluster Health | `cluster` | Node status, etcd, operator CSV, MachineConfig |
| Network | `network` | OVN-K, Multus/Whereabouts IPAM, DNS, egress, NetworkPolicy |
| Storage | `storage` | CSI drivers, StorageClass, PVC binding, CDI DataVolume |
| VM Lifecycle | `vm` | Create/start/stop/delete VMI, live migration, snapshot, guest OS |
| Security | `security` | SCC, RBAC, RoleBindings, NetworkPolicy isolation, Vault |
| Compliance | `compliance` | OPA/Gatekeeper constraints, OpenSCAP, compliance operator |
| Monitoring | `monitoring` | Prometheus alert rules, scrape targets, Splunk HEC forwarding |

### What makes it different from the legacy approach

| Concern | Legacy (`test_common_module.py`) | This Framework |
|---------|----------------------------------|----------------|
| File structure | 1 file, all domains | 1 file per domain, isolated |
| AAP client | 80-line function inside test | `lib/aap_client.py`, session fixture |
| TLS | `verify=False` everywhere | `verify=True` by default |
| Polling | `while True` — hangs forever | Configurable timeout + `TimeoutError` |
| AAP URL | `/api/v2/` (broken on AAP 2.5+) | `/api/controller/v2/` (gateway-aware) |
| Stdout parsing | Fragile regex on freeform text | Structured `AAPJobResult.status` |
| Reporting | Single pytest-html file | Allure: Epic/Feature/Story + trend |
| Observability | None | Real-time Kafka event stream |
| Remediation | Manual re-run | `auto_remediate` fixture — per test |
| Adding new domain | Edit God-file, risk regressions | New file in `tests/<domain>/` |

---

## Quick Start

```bash
# 1. Clone
git clone https://git.corp.internal/platform/testops.git
cd testops

# 2. Install (Python 3.12+)
pip install -e ".[test]"

# 3. Set minimum required env vars
export KUBECONFIG=/path/to/your/kubeconfig
export TEST_ENV=dev
export OCP_CLUSTER=ocp-dev-01

# 4. Run smoke tests (fast, no AAP or Kafka needed)
pytest -m smoke -v

# 5. Run a specific domain
pytest -m cluster -v

# 6. Run full suite (parallel)
pytest -m "cluster or network or storage" -n 4 --dist=loadfile -v
```

---

## Repository Structure

```
testops/
│
├── README.md                           ← you are here
├── Jenkinsfile                         ← full pipeline with Build Parameters
├── pyproject.toml                      ← deps + entry points (no setup.py)
├── pytest.ini                          ← markers, asyncio_mode, log format
├── Makefile                            ← local run shortcuts
│
├── conftest.py                         ← THE most important file (see below)
│
├── tests/                              ← one subdirectory per domain
│   ├── cluster/
│   │   ├── conftest.py                 ← cluster-specific fixtures
│   │   ├── test_nodes.py               ← node health, capacity, taints
│   │   ├── test_operators.py           ← CSV status, operator health
│   │   └── test_etcd.py               ← etcd health, member count
│   ├── network/
│   │   ├── conftest.py
│   │   ├── test_cni.py                 ← OVN-K, Multus, Whereabouts
│   │   ├── test_dns.py                 ← CoreDNS, service resolution
│   │   └── test_egress.py             ← egress IP, network policies
│   ├── storage/
│   │   ├── conftest.py
│   │   ├── test_csi.py                 ← CSI drivers, StorageClass
│   │   ├── test_pvc.py                 ← PVC binding, RWX/RWO
│   │   └── test_cdi.py                ← CDI DataVolume (KubeVirt)
│   ├── vm/
│   │   ├── conftest.py                 ← vm_semaphore, create_vm helpers
│   │   ├── test_vm_lifecycle.py        ← create/start/stop/delete
│   │   ├── test_vm_migration.py        ← live migration
│   │   └── test_vm_os.py              ← guest OS checks via ansible-runner
│   ├── security/
│   │   ├── conftest.py
│   │   ├── test_rbac.py               ← SCC, RoleBindings
│   │   └── test_vault.py              ← Vault secret injection
│   ├── monitoring/
│   │   ├── conftest.py
│   │   ├── test_prometheus.py          ← alert rules, scrape targets
│   │   └── test_logging.py            ← Splunk HEC forwarding
│   └── compliance/
│       ├── conftest.py
│       ├── test_opa_policies.py        ← OPA/Gatekeeper constraints
│       └── test_compliance_op.py      ← OpenSCAP profiles
│
├── plugins/
│   ├── kafka_plugin.py                 ← pytest hooks → Kafka event stream
│   └── allure_enricher.py             ← Epic/Feature/Story metadata
│
├── lib/
│   ├── aap_client.py                   ← AAP 2.5+ REST client (requests)
│   ├── kafka_producer.py               ← non-blocking confluent-kafka producer
│   ├── kafka_events.py                 ← Pydantic event models
│   └── assertions.py                   ← shared assertion helpers
│
├── fixtures/
│   ├── aap_fixtures.py                 ← auto_remediate (Jenkins-led model)
│   ├── cluster_fixtures.py             ← node_list, operator_csv helpers
│   └── vm_fixtures.py                  ← KubeVirt VMI helpers
│
├── scripts/
│   ├── poll_aap_job.py                 ← CLI: poll AAP job to terminal state
│   ├── fetch_aap_artifacts.py          ← CLI: download JUnit/Allure from AAP
│   └── generate_env_props.py           ← Allure environment.properties
│
├── allure-categories.json              ← OCP-specific failure category rules
│
└── docker/
    └── Dockerfile                      ← pinned test runner image
```

---

## Architecture

The framework supports two deployment models. Choose based on your
organisation's tooling mandate.

### Jenkins-Led (Default)

```
Jenkins Pipeline (Jenkinsfile)
    │
    ├── [Stage] Validate parameters
    ├── [Stage] Environment check (oc cluster-info, node list)
    │
    ├── [Stage] Run tests ─────────────────────────────────────────────────┐
    │           pytest -n N --dist=loadfile                                 │
    │               ├── kubernetes Python client → OCP resource state       │
    │               ├── ansible-runner → guest OS SSH checks (local)        │
    │               ├── aap_client.py REST → AAP remediation on failure     │
    │               └── kafka_plugin → streams every event in real time     │
    │                                                                       │
    ├── [Stage] Generate Allure report                                      │
    ├── [Stage] Publish Allure (Jenkins plugin)                             │
    └── [Cleanup] Delete ephemeral test pods                                │
                                                                           ▼
                                                                    Kafka Topics
                                                                    testops.results
                                                                    testops.session
                                                                    testops.ansible
```

**Best for:** Teams with Jenkins expertise, Python-first workflow,
need for xdist parallelism (4–16 workers), full Allure report history.

### AAP-Led (Organisation Mandate)

```
Jenkins (thin trigger)
    │
    └── POST /api/controller/v2/workflow_job_templates/{id}/launch/
              │
              ▼
    AAP Workflow Template
        ├── [Parallel] Job: Cluster + Storage  ─┐
        ├── [Parallel] Job: Network + Security  ─┤──▶ [Job: VM Lifecycle]
        └─────────────────────────────────────────┘         │
                                                            ▼
                                                   [Job: Compliance]
                                                            │
                                                  On failure branch:
                                                   [Job: Remediation]
                                                            │
                                                   [Job: Re-Validation]

Each AAP Job runs:
    pytest inside custom Execution Environment (EE) container
    └── same kafka_plugin, allure_enricher, xdist as Jenkins-led
```

**Best for:** Organisations requiring AAP as the central RBAC and audit
enforcement point. All job executions appear in the AAP audit log.

> **Key difference:** In the AAP-led model, `auto_remediate` pytest fixture
> is replaced by the workflow's failure branch. Per-test AAP job calls
> add 30s+ overhead per test and are not used.

---

## conftest.py — How the Framework Is Wired

`conftest.py` is pytest's **dependency injection and plugin wiring layer**.
It is auto-discovered — no imports needed in test files. It does five jobs:

### 1. Plugin registration

```python
pytest_plugins = [
    "plugins.kafka_plugin",       # must be first — producer needed by aap_fixtures
    "plugins.allure_enricher",    # stamps Epic/Feature/Story on every test
    "fixtures.aap_fixtures",      # auto_remediate (Jenkins-led only)
    "fixtures.cluster_fixtures",
    "fixtures.vm_fixtures",
]
```

Order matters. `kafka_plugin` must register before `aap_fixtures` so the
Kafka producer exists when remediation tries to emit events.

### 2. Session-scoped infrastructure fixtures

These are created **once per run** and shared across all xdist workers.
Never use `function` scope for expensive connections.

```python
@pytest.fixture(scope="session")
def k8s_core(env: str) -> client.CoreV1Api: ...      # nodes, pods, namespaces

@pytest.fixture(scope="session")
def ocp(env: str) -> DynamicClient: ...              # KubeVirt VMI, CDI, CRDs

@pytest.fixture(scope="session")
def aap_client_session() -> AAPClient | None: ...    # AAP REST (None if not configured)

@pytest.fixture(scope="session")
def kafka_producer() -> TestOpsKafkaProducer | None: ...
```

### 3. CLI options → Jenkins Build Parameters

```python
def pytest_addoption(parser):
    parser.addoption("--env",             choices=["dev","test","uat","prod"])
    parser.addoption("--cluster",         help="OCP cluster name")
    parser.addoption("--namespace",       default="testops-runner")
    parser.addoption("--vm-profile",      default="rhel9-small")
    parser.addoption("--kafka-bootstrap", help="host:port, empty=disabled")
    parser.addoption("--kafka-tls",       action="store_true")
```

### 4. Autouse fixtures (run for every test automatically)

```python
@pytest.fixture(autouse=True)
def attach_test_metadata(request):
    request.node._correlation_id = str(uuid.uuid4())  # links Kafka+Allure+AAP
    request.node._session_id     = SESSION_ID          # links to Jenkins build

@pytest.fixture(autouse=True)
def log_test_boundaries(request):
    log.info("━━ START %s", request.node.nodeid)
    yield
    log.info("━━ END   %s", request.node.nodeid)
```

### 5. Hook: capture call report for remediation

```python
@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report  = outcome.get_result()
    if call.when == "call":
        item._last_call_report = report   # read by auto_remediate post-yield
```

### Fixture scope summary

| Scope | Created | Use for |
|-------|---------|---------|
| `session` | Once per run | k8s client, AAP client, Kafka producer |
| `module` | Once per test file | Namespace setup, test data seeding |
| `class` | Once per class | Class-level VM or storage fixtures |
| `function` | Every test | Throwaway resources, test isolation |

### Subdirectory conftest.py files

Each domain has its own `conftest.py` that inherits from root and adds
domain-specific fixtures only:

```
tests/vm/conftest.py      → create_vm, wait_for_running, vm_semaphore
tests/storage/conftest.py → create_pvc, wait_for_bound, storage_class list
tests/compliance/conftest.py → opa_client, gatekeeper constraints query
```

Fixtures in `tests/vm/conftest.py` are only visible to tests under `tests/vm/`.
This prevents namespace pollution across domains.

---

## Test Domains

### Markers and Allure mapping

```python
# pytest.ini markers
cluster     → Epic: Platform Health    / Feature: Cluster
network     → Epic: Platform Health    / Feature: Network
storage     → Epic: Platform Health    / Feature: Storage
vm          → Epic: VM Lifecycle       / Feature: Virtual Machines
security    → Epic: Security           / Feature: Security Controls
compliance  → Epic: Security           / Feature: Compliance Policies
monitoring  → Epic: Observability      / Feature: Monitoring & Logging

# Special markers
smoke       → Fast subset, no external dependencies
slow        → Tests taking >120s
flaky       → Known intermittent tests (auto-retried)
```

### Writing a test — minimum template

```python
# tests/storage/test_csi.py

import pytest
import allure

@pytest.mark.storage
@allure.title("CSI driver DaemonSet is healthy on all nodes")
def test_csi_driver_daemonset_healthy(k8s_apps, target_namespace):
    """
    Validates that the CSI driver DaemonSet has no unavailable pods.
    Uses k8s_apps session fixture — no connection setup needed.
    """
    ds_list = k8s_apps.list_namespaced_daemon_set(namespace="openshift-storage")
    for ds in ds_list.items:
        unavailable = ds.status.number_unavailable or 0
        assert unavailable == 0, (
            f"CSI DaemonSet {ds.metadata.name} has {unavailable} unavailable pods"
        )
```

That is the entire test. No HTTP calls, no env var reads, no fixture setup.
The `k8s_apps` session fixture and `attach_test_metadata` autouse fixture
handle everything else.

---

## Running Tests

### Local Development

Use the `Makefile` targets for consistent local runs:

```bash
# Fast smoke tests — no AAP or Kafka needed
make smoke

# Single domain
make cluster
make network
make storage
make vm
make security
make compliance
make monitoring

# Full suite, 4 parallel workers
make full

# Custom markers
make run MARKERS="vm and not slow" WORKERS=2

# Debug — sequential, full traceback
make debug MARKERS="vm" TEST=test_vm_lifecycle.py::test_create_vm
```

#### Makefile

```makefile
WORKERS  ?= 4
MODE     ?= loadfile
MARKERS  ?= smoke
ENV      ?= dev
CLUSTER  ?= ocp-dev-01

smoke:
	pytest -m smoke -v --timeout=60

cluster:
	pytest -m cluster -n $(WORKERS) --dist=$(MODE) -v

network:
	pytest -m network -n $(WORKERS) --dist=$(MODE) -v

storage:
	pytest -m storage -n $(WORKERS) --dist=$(MODE) -v

vm:
	pytest -m vm -n 2 --dist=loadfile -v

security:
	pytest -m security -n $(WORKERS) --dist=loadscope -v

compliance:
	pytest -m compliance -n $(WORKERS) --dist=loadscope -v

monitoring:
	pytest -m monitoring -n $(WORKERS) --dist=$(MODE) -v

full:
	pytest -m "cluster or network or storage or vm or security or compliance" \
	       -n $(WORKERS) --dist=$(MODE) -v \
	       --alluredir=allure-results --clean-alluredir

run:
	pytest -m "$(MARKERS)" -n $(WORKERS) --dist=$(MODE) -v

debug:
	pytest $(TEST) -m "$(MARKERS)" -n 0 -v --tb=long -s

report:
	python scripts/generate_env_props.py
	cp allure-categories.json allure-results/categories.json
	allure generate allure-results --clean -o allure-report
	allure open allure-report
```

### Jenkins Pipeline

Trigger a run via the Jenkins UI with **Build with Parameters**:

```
TEST_ENV          → dev | test | uat | prod
OCP_CLUSTER       → ocp-dev-01
PYTEST_MARKERS    → cluster or network or storage or vm
PYTEST_KEYWORD    → (optional -k filter, e.g. "migrate or snapshot")
PARALLEL_MODE     → loadfile | load | loadscope | no
WORKER_COUNT      → 4  (1–16)
TEST_TIMEOUT      → 300
RERUN_FAILURES    → 1
VM_PROFILE        → rhel9-small
PUBLISH_ALLURE    → true
```

Or trigger programmatically:

```bash
curl -X POST \
  -H "Authorization: Bearer $JENKINS_TOKEN" \
  "$JENKINS_URL/job/testops/buildWithParameters" \
  --data-urlencode "TEST_ENV=dev" \
  --data-urlencode "PYTEST_MARKERS=cluster or network" \
  --data-urlencode "WORKER_COUNT=6"
```

### Parallel Execution Guide

| Test suite | Workers | Mode | Reason |
|-----------|---------|------|--------|
| Cluster + Storage | 6–8 | `load` | Stateless reads, safe to parallelise |
| Network + Security | 4 | `loadfile` | Some stateful NetworkPolicy tests |
| VM Lifecycle | 2–3 | `loadfile` | OCP API rate limits; stateful VMI |
| Compliance | 4 | `loadscope` | Class-level fixture reuse |
| Full nightly suite | 12 | `loadfile` | Max throughput, off-hours |
| Debug single test | 1 | `no` | Full output, no interleaving |

> **VM semaphore:** `tests/vm/conftest.py` defines a `vm_semaphore` fixture
> that limits concurrent VM creation to `WORKER_COUNT // 2`. This prevents
> API rate limiting when running with many workers.

---

## Configuration Reference

### Environment variables

```bash
# ── Kubernetes ────────────────────────────────────────────────────────────
KUBECONFIG=/path/to/kubeconfig
KUBECONFIG_DEV=/path/to/dev.kubeconfig    # per-env override
KUBECONFIG_TEST=/path/to/test.kubeconfig
KUBECONFIG_UAT=/path/to/uat.kubeconfig
KUBECONFIG_PROD=/path/to/prod.kubeconfig

# ── AAP (2.5+ gateway URL) ────────────────────────────────────────────────
AAP_URL=https://aap.corp.internal          # Platform Gateway base URL
AAP_TOKEN=<oauth2-pat>                     # Personal Access Token (not awxkit)
AAP_VERIFY_TLS=true                        # set false only for self-signed in dev
AAP_REMEDIATION_TIMEOUT=300               # seconds to wait for remediation job

# ── AAP remediation template IDs per domain ──────────────────────────────
AAP_TEMPLATE_VM=10
AAP_TEMPLATE_STORAGE=11
AAP_TEMPLATE_NETWORK=12
AAP_TEMPLATE_SECURITY=13
AAP_TEMPLATE_COMPLIANCE=14
AAP_TEMPLATE_CLUSTER=15

# ── Kafka ─────────────────────────────────────────────────────────────────
KAFKA_BOOTSTRAP=kafka.internal.corp:9092
KAFKA_SASL_USER=<vault-injected>
KAFKA_SASL_PASS=<vault-injected>

# ── Vault ─────────────────────────────────────────────────────────────────
VAULT_TOKEN=<vault-injected>
VAULT_ADDR=https://vault.corp.internal

# ── Runtime (set by Jenkins or AAP) ──────────────────────────────────────
TESTOPS_SESSION_ID=<uuid>                 # Jenkins-led: set in Jenkinsfile
AWX_JOB_ID=<aap-job-id>                  # AAP-led: auto-injected by AAP
BUILD_NUMBER=<jenkins-build>
GIT_COMMIT=<sha>
TEST_ENV=dev
OCP_CLUSTER=ocp-dev-01
TEST_NAMESPACE=testops-runner
VM_PROFILE=rhel9-small
PYTEST_WORKERS=4
```

### pytest.ini reference

```ini
[pytest]
asyncio_mode = auto

markers =
    cluster:    Cluster health checks
    network:    Network validation
    storage:    Storage validation
    vm:         VM lifecycle tests
    security:   RBAC and security checks
    monitoring: Prometheus and logging
    compliance: Policy compliance
    smoke:      Fast subset — runs on every commit
    slow:       Tests taking >120s
    flaky:      Known intermittent (auto-retried)

addopts =
    -v
    --tb=short
    --timeout=300
    --alluredir=allure-results
    --clean-alluredir

log_cli       = true
log_cli_level = INFO
log_format    = %(asctime)s %(levelname)-8s %(name)s  %(message)s
log_date_format = %H:%M:%S

junit_family         = xunit2
junit_suite_name     = TestOps
junit_logging        = all
```

### pyproject.toml dependencies

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

[project.entry-points."pytest11"]
kafka_testops   = "plugins.kafka_plugin"
allure_enricher = "plugins.allure_enricher"
```

---

## Allure Reports

Reports are published by the Jenkins Allure plugin after every run.

### Report structure

```
Allure Report
│
├── Behaviours (domain tree)
│   ├── Platform Health
│   │   ├── Cluster       → test_nodes, test_operators, test_etcd
│   │   ├── Network       → test_cni, test_dns, test_egress
│   │   └── Storage       → test_csi, test_pvc, test_cdi
│   ├── VM Lifecycle
│   │   └── Virtual Machines → test_vm_lifecycle, test_vm_migration
│   ├── Security & Compliance
│   │   ├── Security Controls   → test_rbac, test_vault
│   │   └── Compliance Policies → test_opa_policies, test_compliance_op
│   └── Observability
│       └── Monitoring & Logging → test_prometheus, test_logging
│
├── Categories (failure buckets — allure-categories.json)
│   ├── VM provisioning failures       ← matches VMI/KubeVirt in longrepr
│   ├── Storage failures               ← matches PVC/CSI/CDI
│   ├── Network failures               ← matches NetworkPolicy/Multus/DNS
│   ├── AAP remediation failures       ← matches "AAP Remediation FAILED"
│   ├── Cluster health failures        ← matches Node/etcd/operator
│   ├── Security / RBAC failures       ← matches SCC/RBAC/Vault
│   ├── Compliance violations          ← matches Gatekeeper/OPA
│   ├── Test infrastructure errors     ← all broken tests
│   └── Flaky tests                    ← matches retry/intermittent
│
├── Environment tab (auto-generated by scripts/generate_env_props.py)
│   Environment, Cluster, OCP_Version, Namespace, VM_Profile,
│   Workers, Jenkins_Build, Git_Branch, Git_Commit, Session_ID
│
└── Per-test attachments
    ├── Failure detail (full traceback)
    ├── Test log (captured stdout/stderr)
    └── AAP remediation result (if triggered)
```

### Generating locally

```bash
# After a test run:
python scripts/generate_env_props.py
cp allure-categories.json allure-results/categories.json
allure generate allure-results --clean -o allure-report
allure open allure-report
```

---

## Kafka Event Streaming

Every test lifecycle event is streamed to Kafka in real time. The pytest
process never blocks waiting for broker ACKs — a background thread and
queue handle all produce calls.

### Topics

| Topic | Partition key | Contents |
|-------|--------------|----------|
| `testops.session` | `session_id` | Session start/end, exit code |
| `testops.results` | `node_id` | Per-test pass/fail/skip + duration |
| `testops.ansible` | `node_id` | AAP remediation outcomes |
| `testops.logs` | `session_id` | pytest warnings and log records |

Partitioning by `node_id` means all events for one test arrive in order
on the same partition — consumers can reconstruct the full test timeline
without sorting.

### Event payload (all topics)

```json
{
  "event_id":       "uuid",
  "event_type":     "test.failed",
  "timestamp":      "2026-04-12T12:37:00Z",
  "session_id":     "jenkins-build-uuid",
  "correlation_id": "per-test-uuid",
  "node_id":        "tests/vm/test_lifecycle.py::test_create_vm",
  "markers":        ["vm", "slow"],
  "duration_ms":    14230.5,
  "outcome":        "failed",
  "longrepr":       "AssertionError: VMI did not reach Running ...",
  "extra":          {}
}
```

The `correlation_id` links a Kafka event to its Allure test entry and
to the AAP remediation job — enabling end-to-end trace from test failure
to remediation outcome across all observability tools.

### Enabling Kafka

```bash
# Kafka is opt-in — disabled if --kafka-bootstrap is not set
pytest -m cluster \
    --kafka-bootstrap=kafka.internal.corp:9092 \
    --kafka-tls \
    -v
```

Or set `KAFKA_BOOTSTRAP` env var — the plugin reads it as the default.

---

## AAP Integration

### Why Not ansible-runner?

`ansible-runner` runs Ansible **locally** on the machine where Python
is executing. It cannot invoke AAP job templates.

```
ansible-runner  →  subprocess on THIS machine → runs a playbook locally
AAP REST API    →  HTTPS to AAP gateway       → launches job on execution node
```

The framework uses `lib/aap_client.py` which calls the AAP REST API
directly with `requests`. This is what Red Hat recommends for
programmatic AAP interaction.

> ⚠️ **Do not use `awxkit`** — the project is inactive and broken
> on AAP 2.5+ (`pkg_resources` import error).

### AAP 2.5+ URL structure

AAP 2.5 introduced a Platform Gateway with two API roots:

| API | Base path | Use for |
|-----|-----------|---------|
| Gateway | `/api/gateway/v1/` | Auth, tokens, platform settings |
| Controller | `/api/controller/v2/` | Jobs, templates, inventories, workflows |

The `aap_client.py` handles both. Set `AAP_URL` to the Platform Gateway
base URL — the client appends the correct path automatically.

### Remediation Template Map

When a test fails, `auto_remediate` (in `fixtures/aap_fixtures.py`) reads
the test's markers to find the matching AAP job template and launches it:

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

The original test failure is **always preserved** — auto_remediate never
silences it. The Jenkins ReValidate stage re-runs failed tests after
remediation completes and produces the final clean result.

### Extra vars passed to every remediation job

```python
{
    "failed_test":    "tests/vm/test_lifecycle.py::test_create_vm",
    "correlation_id": "per-test-uuid",
    "session_id":     "jenkins-build-uuid",
    "marker":         "vm",
}
```

---

## Writing New Tests

### Adding a test to an existing domain

```python
# tests/storage/test_new_check.py

import pytest
import allure

@pytest.mark.storage                              # required — domain marker
@allure.title("Human-readable test title")        # appears in Allure Story
def test_storageclass_has_reclaim_policy(k8s_core):
    """Validates that all StorageClasses have an explicit reclaimPolicy."""
    sc_list = k8s_core.list_storage_class()
    missing = [
        sc.metadata.name
        for sc in sc_list.items
        if not sc.reclaim_policy
    ]
    assert not missing, f"StorageClasses with no reclaimPolicy: {missing}"
```

That is all. No imports of aap_client, no env var reads, no fixture setup.
`k8s_core` is session-scoped and ready. `attach_test_metadata` adds
correlation_id automatically. `allure_enricher` maps `storage` marker to
the correct Epic/Feature. `kafka_plugin` streams the result.

### Adding a new test domain

```bash
# 1. Create domain directory
mkdir tests/backup

# 2. Add domain conftest.py (inherits from root)
cat > tests/backup/conftest.py << 'EOF'
import pytest
from kubernetes import client

@pytest.fixture(scope="session")
def backup_client(k8s_custom):
    """OADP/Velero backup CRD client."""
    return k8s_custom   # extend as needed
EOF

# 3. Add marker to pytest.ini
#    backup: Backup and restore validation (OADP/Velero)

# 4. Add to allure_enricher.py DOMAIN_MAP
#    "backup": { "epic": "Data Protection", "feature": "Backup & Restore", ... }

# 5. Add remediation template to aap_fixtures.py REMEDIATION_TEMPLATES
#    "backup": int(os.getenv("AAP_TEMPLATE_BACKUP", "16"))

# 6. Write test files under tests/backup/

# 7. Update PYTEST_MARKERS Jenkins default to include "backup"
```

No other files need to change. Existing tests are completely unaffected.

---

## Migration from Legacy Codebase

The legacy `test_common_module.py` had 14 issues ranging from critical
security problems to architectural anti-patterns. See `docs/audit-report.docx`
for the full findings. The migration phases are:

| Phase | Effort | Action |
|-------|--------|--------|
| **1 — Fix critical** | 1 day | `verify=True`, poll timeout, remove stdout regex |
| **2 — Extract AAP client** | 2–3 days | Move `launch_ansible_tower_job` to `lib/aap_client.py`, session fixture |
| **3 — Split test file** | 3–5 days | One file per domain under `tests/`, add markers |
| **4 — Add Kafka** | 2–3 days | `kafka_plugin.py`, `kafka_producer.py`, wire into conftest |
| **5 — Add Allure** | 1–2 days | `allure_enricher.py`, `allure-categories.json`, Jenkins plugin |
| **6 — Add remediation** | 2 days | `aap_fixtures.py`, `auto_remediate`, Build Parameters |
| **7 — Repo separation** | 1 day | Move to `testops` repo, add Dockerfile, Makefile |

### Immediate fixes (apply today, 30 minutes)

```python
# Fix 1: Enable TLS verification
verify_tls = os.environ.get('AAP_VERIFY_TLS', 'true').lower() != 'false'
# Replace all verify=False with verify=verify_tls

# Fix 2: Add polling timeout
deadline = time.monotonic() + int(os.getenv('AAP_POLL_TIMEOUT', '600'))
while time.monotonic() < deadline:
    ...
    time.sleep(10)
else:
    raise TimeoutError(f"AAP job {job_id} timed out")

# Fix 3: Update API URL for AAP 2.5+
api_base = os.environ.get('AAP_API_BASE', 'api/controller/v2')
url = f"https://{tower_server}/{api_base}/job_templates/{template_id}/launch/"
```

---

## Troubleshooting

### Tests hang indefinitely

**Cause:** Legacy `while True` polling in `launch_ansible_tower_job`.
**Fix:** Use `lib/aap_client.py` which has configurable timeout.
**Workaround (now):** Set `AAP_POLL_TIMEOUT=300` env var.

### `404` when launching AAP job

**Cause:** API URL uses `/api/v2/` — broken on AAP 2.5+.
**Fix:** Set `AAP_API_BASE=api/controller/v2` env var or update `aap_client.py`.

### `SSLError: certificate verify failed`

**Cause:** `verify=True` enabled (correct!) but cluster uses self-signed cert.
**Fix:** Set `AAP_VERIFY_TLS=false` for dev environment only.
**Better fix:** Add your internal CA bundle: `verify=/path/to/ca-bundle.crt`.

### `pytest_generate_tests` not parametrizing tests in new file

**Cause:** Hook is in `test_common_module.py` instead of `conftest.py`.
**Fix:** Move `pytest_generate_tests` to root `conftest.py`.

### Kafka events not appearing

1. Check `--kafka-bootstrap` is set or `KAFKA_BOOTSTRAP` env var is populated
2. Check SASL credentials: `KAFKA_SASL_USER`, `KAFKA_SASL_PASS`
3. Check topic exists: `kafka-topics.sh --list --bootstrap-server $KAFKA_BOOTSTRAP`
4. Kafka is opt-in — if bootstrap is not set, plugin logs a warning and skips silently

### Allure report not showing environment tab

**Cause:** `generate_env_props.py` not run before `allure generate`.
**Fix:** Always run `python scripts/generate_env_props.py` first. The
`Jenkinsfile` does this automatically in the Generate stage.

### xdist workers failing with kubeconfig errors

**Cause:** xdist workers inherit env from the main process but may not
have `KUBECONFIG` set correctly.
**Fix:** Ensure `KUBECONFIG` (or `KUBECONFIG_<ENV>`) is exported before
running pytest, not just set. Use `export KUBECONFIG=...`.

---

## Jenkins Plugin Requirements

| Plugin | Minimum version | Purpose |
|--------|----------------|---------|
| `allure-jenkins-plugin` | 2.30 | Allure report publishing and trend |
| `kubernetes-plugin` | 1.12 | Pod-based ephemeral agents |
| `ansicolor` | 1.0 | Coloured console output |
| `timestamper` | 1.21 | Timestamp every log line |
| `credentials-binding` | bundled | Vault/secret injection |
| `junit-plugin` | bundled | Test trend graphs in Jenkins |
| `build-discarder` | bundled | Log and artifact rotation |

Install via **Manage Jenkins → Plugins → Available plugins**.

---

## Contributing

1. All new tests must have a domain marker (`@pytest.mark.<domain>`)
2. All new tests must have an `@allure.title()` decorator
3. No `print()` — use `log = logging.getLogger(__name__)`
4. No `verify=False` — use `AAP_VERIFY_TLS=false` env var for dev
5. No env var reads inside test functions — use CLI option fixtures
6. Session-scoped fixtures for all external connections
7. Add the new test's domain to the `PYTEST_MARKERS` Jenkins param default

---

*Platform Engineering — TestOps Framework*
*For questions: raise an issue in the `testops` repository or contact the platform team on Slack `#platform-testops`.*
