``` docs
TestOps Code Audit
Current Codebase Issues & Proposed Framework Migration

Platform Engineering  |  April 2026


1. Executive Summary
A code review of the current testops-jenkins-pipeline codebase was conducted using visual inspection of the active VS Code workspace. The review covers the Jenkinsfile, test_common_module.py (165 lines), and supporting JSON configuration files across five modules.

The current framework has 14 distinct issues ranging from critical security vulnerabilities to architectural anti-patterns that will prevent the platform from scaling to additional test domains, clusters, or team members.

Severity	Count	Primary Impact
CRITICAL	3	TLS verification disabled; infinite polling loop; stdout regex parsing
HIGH	5	God file; no fixtures; pytest_generate_tests in wrong file; hardcoded /api/v2/; no Kafka
MEDIUM	4	print() instead of logging; env vars read inside test; HTML report only; no retries
LOW	2	Missing type annotations; no Makefile for local runs

2. Detailed Issue Report
Issues are listed in order of severity. Each entry shows the file, line numbers observed from the code review, the problem, and the proposed solution in the new framework.

Severity	Issue	File	Lines
CRITICAL	verify=False on all HTTP calls. TLS verification is disabled on every requests.get and requests.post call. Any MITM attacker on the network can intercept AAP tokens, kubeconfig credentials, and test results.	test_common_module.py	L34, 43, 49
CRITICAL	Infinite polling loop with no timeout. while True: ... time.sleep(2) will hang the Jenkins job permanently if the AAP job gets stuck in pending or waiting state. No maximum wait time, no circuit breaker.	test_common_module.py	L42-47
CRITICAL	Regex parsing of Ansible stdout. The entire pass/fail assertion relies on regex matching against freeform Ansible output text. Any Ansible version upgrade, role name change, or whitespace difference silently breaks detection. The ANSI escape regex and task block pattern are fragile and untestable.	test_common_module.py	L56-81
HIGH	God file — all concerns in one 165-line module. launch_ansible_tower_job (AAP client), get_cluster_action_dict (test data), pytest_generate_tests (hook), test_cluster_action (assertion) — all in one file. Adding a new domain (storage, VM, network) means editing this file and risking regressions.	test_common_module.py	L1-165
HIGH	pytest_generate_tests hook placed in test file, not conftest.py. This hook is auto-discovered only when in conftest.py. Placing it in a test file means it only applies to that file. If a second test file is added, it either duplicates this hook (causing conflicts) or loses parametrization.	test_common_module.py	L127-130
HIGH	No pytest fixtures — AAP client created inside test function. launch_ansible_tower_job() creates a new HTTP connection and reads env vars on every single test invocation. With -n auto parallelism, N workers each create N separate HTTP sessions with no reuse. Should be session-scoped fixtures.	test_common_module.py	L16-93
HIGH	Hardcoded /api/v2/ URL path. AAP 2.5+ uses /api/controller/v2/ through the Platform Gateway. The current URL construction (f'https://{tower_server}/api/v2/job_templates/') will fail silently or return 404 on AAP 2.5+.	test_common_module.py	L25
HIGH	No Kafka event streaming. There is no real-time visibility into test execution. When -n auto runs 10 tests in parallel, there is no way to observe progress, detect hung tests, or feed results to Splunk or monitoring dashboards without waiting for the full run to complete.	test_common_module.py	All
HIGH	Single test covers all domains via filter parameter (-k filter in Jenkinsfile). The -k flag is a substring match on test names. There is no structural domain separation. If test_cluster_action is the only test function, -k has nothing meaningful to filter on.	Jenkinsfile	L226
MEDIUM	Environment variables read inside test function body. REQUEST_ID = get_env_var('REQUEST_ID') and ENVIRONMENT = get_env_var('ENVIRONMENT') are called inside test_cluster_action on every test invocation. These should be session-scoped fixtures read once at startup.	test_common_module.py	L137-138
MEDIUM	print() mixed with logging. Lines 40, 78, 86 use print() directly. The root logger is configured with basicConfig but print() bypasses it entirely. Jenkins captures stdout but it is not structured, not filterable, and not routable to Splunk.	test_common_module.py	L40, 78, 86
MEDIUM	pytest-html only — no Allure domain structure. The Jenkinsfile publishes a single pytest-html file per cluster. There is no Epic/Feature/Story hierarchy, no failure categorisation by domain, no environment metadata tab, and no test trend history across builds.	Jenkinsfile	L240-248
MEDIUM	No retry logic on HTTP calls. If the AAP API returns a 429 (rate limit) or transient 503 during polling, the test immediately fails with an unhandled exception rather than retrying. The requests library has a Retry adapter that handles this transparently.	test_common_module.py	L33, 43
LOW	No type annotations on any function. launch_ansible_tower_job, get_cluster_action_dict, test_cluster_action all lack return types and parameter types. This prevents mypy checking, IDE autocomplete, and makes the codebase harder for new team members to navigate.	test_common_module.py	L13-165
LOW	No Makefile or local run targets. Developers must manually construct the long pytest command with all env vars to run tests locally. This creates inconsistency between local and CI runs and slows onboarding.	Jenkinsfile	All

3. Architecture Comparison

Concern	Current Codebase	Proposed Framework
Test file structure	1 file: test_common_module.py handles all domains	1 file per domain under tests/cluster/, tests/vm/, tests/storage/, etc.
AAP client	launch_ansible_tower_job() — 80 lines inside test file	lib/aap_client.py — AAPClient class, session-scoped fixture, proper retry
TLS security	verify=False on all calls	verify=True default, overridable via AAP_VERIFY_TLS env var
Polling	while True (infinite)	poll() with configurable timeout and TimeoutError
API URL	/api/v2/ (AAP 2.x)	/api/controller/v2/ (AAP 2.5+ gateway)
Stdout parsing	Regex on freeform text	Structured AAPJobResult.status — no regex needed
Fixtures	None — everything created per test	session-scoped k8s_core, ocp, aap_client_session
pytest hooks	pytest_generate_tests in test file	All hooks in conftest.py — auto-discovered correctly
Parallelism	-n auto (uncontrolled)	-n N with --dist=loadfile, VM semaphore, Jenkins param
Reporting	pytest-html single file per cluster	Allure: Epic/Feature/Story + categories + env tab
Event streaming	None	Kafka: testops.results, testops.session, testops.ansible
Logging	print() + basicConfig mix	logging.getLogger(__name__) everywhere
Remediation	None — manual re-run	auto_remediate fixture triggers AAP job template on failure
Adding new domain	Edit test_common_module.py — risk regressions	Add new file in tests/<domain>/ — zero impact on others
Adding new cluster	Add env vars + repeat Jenkinsfile branch logic	Add cluster to inventory JSON — framework picks up automatically

4. How the Proposed Framework Scales

4.1 Adding a New Test Domain
Current approach: Edit test_common_module.py, add new logic to get_cluster_action_dict(), risk breaking existing tests.

Proposed approach:
•	Create tests/storage/test_csi.py — zero changes to existing files
•	Add @pytest.mark.storage decorator
•	Add REMEDIATION_TEMPLATES['storage'] = int(os.getenv('AAP_TEMPLATE_STORAGE', '11')) in aap_fixtures.py
•	Allure enricher auto-maps the marker to Platform Health / Storage epic
•	Kafka plugin auto-streams events to testops.results
•	Jenkins PYTEST_MARKERS param is updated in the UI — no Jenkinsfile change

4.2 Adding a New Cluster or Environment
Current approach: Add new env vars, duplicate the createBranch block in Jenkinsfile, add new stash/unstash pair.

Proposed approach:
•	Add cluster entry to automation/clusters.json or inventory file
•	Set KUBECONFIG_<ENV> env var in Jenkins credential store
•	Run pytest --cluster=new-cluster-name — conftest._load_kubeconfig() handles the rest
•	Allure Environment tab automatically shows the new cluster name via generate_env_props.py

4.3 Adding a New Team Member
Current approach: Team member must understand the entire 165-line test_common_module.py and the Ansible Tower API before writing any test.

Proposed approach:
•	conftest.py provides all infrastructure: k8s_core, ocp, aap_client_session as ready-to-use fixtures
•	Fixture documentation explains scope and purpose with inline comments
•	Test file template is: import pytest + decorator + fixture params + one assert
•	Domain conftest.py (e.g. tests/vm/conftest.py) provides VM-specific helpers
•	Makefile targets: make smoke, make cluster, make vm for local runs

4.4 Parallel Execution at Scale
Current: -n auto distributes all tests across all cores with no control. Stateful VM tests running in parallel corrupt shared state. No rate limit protection against the OCP API server.

Proposed:
•	Jenkins WORKER_COUNT and PARALLEL_MODE are explicit Build Parameters
•	--dist=loadfile keeps all tests from one file on the same worker (safe for VM lifecycle)
•	vm_semaphore fixture limits concurrent VM creation to WORKER_COUNT / 2
•	Per-domain tuning: cluster=8 workers, vm=2-3 workers, compliance=4 workers
•	pytest-rerunfailures handles transient AAP API rate limits automatically

4.5 Observability at Scale
Current: A 30-minute test run produces one HTML file at the end. No visibility during execution. No historical trend. No correlation to AAP job IDs.

Proposed:
•	Kafka testops.results topic receives every test event in real time — Splunk and Grafana can alert on failures as they happen
•	Every event carries session_id (Jenkins build), correlation_id (per test), and node_id (pytest path)
•	Allure report shows trend across builds, failure categories, and per-test attachment with full traceback
•	AAP remediation results appear as Kafka events in testops.ansible topic, correlated to the failing test

5. Recommended Migration Path

Phase	Duration	Action	Outcome
1	1 day	Fix CRITICAL issues in current codebase: add verify=True, add timeout to while loop, replace regex with status-only assertion	Production-safe immediately
2	2–3 days	Extract lib/aap_client.py from launch_ansible_tower_job. Add session-scoped fixture. Move pytest_generate_tests to conftest.py	Single responsibility, testable AAP client
3	3–5 days	Split test_common_module.py into domain test files under tests/. Add markers. Add allure-pytest	Domain isolation, Allure reports
4	2–3 days	Add kafka_plugin.py and Kafka producer. Wire into conftest.py	Real-time event streaming
5	2 days	Add auto_remediate fixture. Wire AAP template map. Update Jenkinsfile with Build Parameters	Self-healing tests, scaled parallelism
6	1 day	Move to testops repo (separate from platform GitOps repo). Add Dockerfile for pinned EE	Clean repo separation

6. Immediate Fixes for Current Codebase
Before the full migration, apply these three changes to make the current code production-safe:

Fix 1 — Enable TLS verification
# BEFORE (all three calls):
response = requests.post(url, headers=headers, json=payload, verify=False)

# AFTER:
verify_tls = os.environ.get('AAP_VERIFY_TLS', 'true').lower() != 'false'
response = requests.post(url, headers=headers, json=payload, verify=verify_tls)

Fix 2 — Add timeout to polling loop
# BEFORE:
while True:
    job_resp = requests.get(job_url, headers=headers, verify=False)
    status = job_resp.json().get('status')
    if status in ['successful', 'failed', 'error', 'canceled']:
        break
    time.sleep(2)

# AFTER:
timeout = int(os.environ.get('AAP_POLL_TIMEOUT', '600'))
deadline = time.time() + timeout
while time.time() < deadline:
    job_resp = requests.get(job_url, headers=headers, verify=verify_tls)
    status = job_resp.json().get('status')
    if status in ['successful', 'failed', 'error', 'canceled']:
        break
    time.sleep(10)
else:
    raise TimeoutError(f'AAP job {job_id} timed out after {timeout}s')

Fix 3 — Update API URL for AAP 2.5+
# BEFORE:
url = f'https://{tower_server}/api/v2/job_templates/{template_id}/launch/'

# AFTER (supports both 2.x and 2.5+):
api_base = os.environ.get('AAP_API_BASE', 'api/controller/v2')
url = f'https://{tower_server}/{api_base}/job_templates/{template_id}/launch/'

Appendix: Files Reviewed

File	Lines Visible	Content
testops-jenkins-pipeline/modules/Cluster_Health_and_Core_Services/Jenkinsfile	218-252	Pipeline branch creation, pytest invocation, Allure generate, publishHTML
testops-jenkins-pipeline/test-cases/test_common_module.py	6-165	Full file: all helper functions and test_cluster_action
automation/integration.json	N/A (listed)	Integration config file
automation/monitoring_and_logging.json	N/A (listed)	Monitoring domain config
automation/network_validate.json	N/A (listed)	Network validation config
automation/storage_validate.json	N/A (listed)	Storage validation config

Note: Report/dashboard JS files (app.js, app_broken.js, app_failed.js, app_graph.js, app_passed.js, app_skipped.js, app_total.js) were visible in the file tree and are generated Allure dashboard assets — not reviewed as source code.

```
