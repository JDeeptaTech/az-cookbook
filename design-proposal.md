# Design Proposal — Request-Driven OpenShift Content Mirroring

| | |
|---|---|
| **Status** | Draft — for review |
| **Author** | <your name> |
| **Reviewers** | Platform Engineering, <mirror server owner>, <AAP admin> |
| **Scope** | Interim solution using existing mirror server + AAP; target state outlined in §10 |
| **Related** | openshift-image-mirror repo · skyline repo · skyline-aap repo |

## 1. Executive summary

Users need OpenShift platform releases and operator content mirrored from upstream registries into Nexus on demand, per selected update channel. Today this is a manual activity on a single server with no visibility of what is already mirrored, no approval step, and no guarantee of incremental downloads.

This proposal introduces a request-driven workflow orchestrated by Ansible Automation Platform (AAP): a user submits a request (channel, target version, operators), the system computes the **exact delta** of releases missing from Nexus using continuously collected update-graph data ("Skyline"), a reviewer approves the concrete download list, and oc-mirror v2 executes an incremental, serialized mirror run on the existing mirror server. Generated cluster resources (IDMS/ITMS/CatalogSource) flow through Git to clusters via GitOps.

The design reuses all existing components (mirror server, oc-mirror, Nexus, AAP) and requires no new infrastructure.

## 2. Background and problem statement

- Clusters run in a restricted network; all platform and operator images must be mirrored into Nexus before use.
- Mirroring is performed with **oc-mirror v2** (digest-based) from a single existing server, driven manually today.
- There is no systematic answer to: *what is available upstream for a channel, what is already in Nexus, how far behind is a cluster, and what is the supported upgrade path?*
- Without delta awareness, a channel mirror re-evaluates far more content than necessary, consuming bandwidth, disk, and time on a shared server.

## 3. Goals and non-goals

**Goals**

1. Self-service request to mirror content for a selected channel and target version.
2. Download only what is missing (delta), following the supported upgrade path (`shortestPath`).
3. Human approval of the exact release list before any download starts.
4. Serialized, incremental oc-mirror execution (persistent workspace, one run at a time).
5. Visibility: dashboard showing channel state, cluster drift, and Nexus availability.

**Non-goals (this phase)**

- Replacing the single mirror server (addressed in target state, §10).
- Automated cluster upgrades — this design delivers content and cluster resources only.
- Mirroring for fully air-gapped (tar transport) sites; the m2d/d2m workflow remains a documented manual fallback.

## 4. Current state

- One mirror server with oc-mirror installed and egress to quay.io / registry.redhat.io.
- Nexus as the target mirror registry (digest-based content, populated by oc-mirror).
- The `openshift-image-mirror` repository holds current mirroring configuration.
- AAP available for orchestration; Confluence/Git for documentation and cluster configuration.

## 5. Proposed solution (interim)

*Insert diagram: 01-solution-architecture*

### 5.1 Components (numbered as in the diagram)

| # | Component | Responsibility |
|---|---|---|
| 1 | **skyline-ingest** (AAP job template, scheduled 6-hourly, concurrency 1) | Collects the Cincinnati update graph (channels, releases, upgrade edges), current cluster version(s), and the Nexus content inventory into the Skyline data store (Parquet + PostgreSQL). |
| 2 | **mirror-request** (AAP workflow, user-invoked) | Entry point. Survey collects channel, target version, architecture, optional operator list. |
| 3 | **Approval gate** (AAP approval node) | Reviewer sees the computed `plan_delta` — the exact releases to be downloaded — and approves or denies. No content is pulled before approval. |
| 4 | **Execute** (AAP job template, concurrency 1) | Renders an `ImageSetConfiguration` from the approved plan and triggers oc-mirror on the mirror server via `delegate_to`. |
| 5 | **Mirror server** | Runs oc-mirror v2 mirror-to-mirror with a host-level run lock and a **persistent workspace** so runs are incremental. |
| 6 | **Nexus** | Target registry. Its inventory feeds the next scheduled ingest, closing the loop so future deltas stay accurate. |

Supporting components: **Skyline dashboard** (Streamlit, read-only) for channel/drift/path visibility; **Git** receives generated IDMS/ITMS/CatalogSource resources for GitOps delivery to clusters.

### 5.2 Request lifecycle

*Insert diagram: 02-request-sequence*

Steps 1–5: request, delta computation against Skyline data, approval of the concrete release list. Steps 6–10: serialized execution — lock acquisition, incremental mirror, digest confirmation, cluster-resource generation. Steps 11–12: requester notification and the scheduled ingest that refreshes inventory.

### 5.3 Delta computation

The plan step answers "what must actually be downloaded" using three inputs already in Skyline:

1. The channel's upgrade graph (nodes = releases with payload digests, edges = supported upgrades).
2. The current cluster version → shortest upgrade path to the requested target.
3. The Nexus inventory (digest-based) → releases on that path already present are removed.

The result (`plan_delta`) is passed through the workflow via `set_stats`, shown to the approver, and used to render a bounded `ImageSetConfiguration`:

```yaml
kind: ImageSetConfiguration
apiVersion: mirror.openshift.io/v2alpha1
mirror:
  platform:
    channels:
      - name: <channel>
        minVersion: <current cluster version>
        maxVersion: <requested target>
        shortestPath: true
```

## 6. Efficiency measures

| Measure | Effect |
|---|---|
| Delta-before-download | Only releases absent from Nexus are mirrored; repeat requests become no-ops. |
| `shortestPath: true` + bounded `minVersion`/`maxVersion` | Mirrors the upgrade path (typically a handful of releases), not the whole channel (~60+). |
| Persistent oc-mirror workspace | oc-mirror's history metadata makes every run incremental; unchanged images are skipped. |
| Serialized execution | AAP concurrency 1 + host `flock` prevents concurrent runs corrupting workspace metadata. |
| mirror-to-mirror (no tar hop) | Direct registry-to-registry copy; avoids double disk I/O of the archive workflow. |

## 7. Implementation

**AAP objects**

| Object | Type | Notes |
|---|---|---|
| skyline-ingest | Job template | Schedule 6-hourly, concurrency 1 |
| mirror-plan | Job template | Survey: req_channel, req_target_version, req_arch, req_operators |
| mirror-execute | Job template | Concurrency 1; consumes plan via set_stats |
| mirror-request | Workflow | plan → approval node → execute |

**Credentials** (AAP credential types, injected as vars): PostgreSQL DSN, cluster token (read-only, `ClusterVersion` get), Nexus read credentials for inventory; mirror pull secret and Nexus push credentials remain on the mirror server.

**Repositories**: `skyline` (ingest, delta logic, dashboard), `skyline-aap` (playbooks, ISC template, inventory), `openshift-image-mirror` (existing; cluster-resource output target TBD with GitOps repo owners).

## 8. Constraints and known limitations

1. **Single mirror server is a SPOF and bandwidth choke point.** Accepted for the interim; addressed in §10.
2. **Secrets on the mirror server** (pull secret, Nexus push credentials). Mitigated by host access controls; moves to platform secrets in the target state.
3. **Digest-based inventory matching**: Nexus availability is tracked by digest (oc-mirror v2 does not tag releases); the ingest must query digests, not tags.
4. **Cross-minor upgrades chain channels** (e.g. 4.16 → stable-4.17 → stable-4.18). Each hop is a separate request in this phase.
5. **No retention policy yet** for Skyline snapshots or superseded Nexus content; operational task, tracked separately.
6. **Ticket-style intake is asynchronous** — no live progress for the requester beyond AAP job output and the completion notification.

## 9. Security considerations

- Approval gate ensures no upstream download occurs without human review of the exact content list.
- All executions are AAP jobs: authenticated, logged, and auditable (who requested, who approved, what was mirrored, when).
- The requester never accesses the mirror server directly; execution is via AAP with a dedicated service account.
- Generated cluster resources are delivered via Git PR, inheriting branch protection and review.

## 10. Target state (next phase, outline)

- Replace the mirror server with a **Kubernetes Job/CronJob** on a cluster with controlled egress; workspace on a PVC. Removes the SPOF and host-level secrets.
- **Request intake as Git pull request** (`request.yaml`), making the request itself the audit trail; AAP (or a controller) reacts to merge events.
- Skyline delta check as a **required status check** on the request PR.
- Retention automation for Skyline snapshots and superseded Nexus content.

The interim design is structured so only the execution layer (diagram 01, boxes 4–5) changes in this transition; request flow, approval, data model, and dashboard carry over unchanged.

## 11. Decisions requested from reviewers

1. Approve the interim architecture (§5) for implementation.
2. Confirm the approver group for the AAP approval node.
3. Confirm the target Git repository for generated cluster resources.
4. Agree the retention approach (or explicitly defer with an owner named).

## Appendix A — References

- Cincinnati update graph: `api.openshift.com/api/upgrades_info` (graph-data + per-channel graph API)
- oc-mirror v2 documentation and the internal `openshift-image-mirror` repository
- Diagrams: 01-solution-architecture, 02-request-sequence (attached as .gliffy/.drawio source + PNG)
