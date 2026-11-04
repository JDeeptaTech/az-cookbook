[[_TOC_]]

# AMPLS + DNS Private Resolver: central Private Link DNS

| | |
|---|---|
| **Status** | Proposed: awaiting approval |
| **Owner** | Platform Engineering (Cloud Automation) |
| **Stakeholders** | DNS / Network Operations, Security, Monitoring, application teams |
| **ADO Epic** | #EPIC-ID _(filled in after running `New-AdoBacklog.ps1`)_ |
| **Repo** | `ampls-dns-migration/` (Terraform, scripts, this page) |
| **Last updated** | 31 Oct 2026 |

## Summary

Today the `privatelink.*` DNS zones for Storage, Key Vault, SQL and Azure Monitor are hosted directly on the enterprise DNS servers and maintained by hand. This plan moves them into **central Azure Private DNS zones** in the connectivity subscription. The enterprise DNS servers forward the public Azure zones to an **Azure DNS Private Resolver**. A **single Azure Monitor Private Link Scope (AMPLS)** carries monitoring traffic privately.

**Outcome:** private endpoints register their own DNS records through policy. On-prem and Azure clients get the same answer. Nobody raises DNS tickets for new private endpoints.

## Why we are changing

| Today | Impact |
|---|---|
| Every new private endpoint needs a manual DNS ticket | Lead time, human error |
| Records go stale when a private endpoint IP changes | Silent outages: clients hit the wrong IP or fall back to public |
| On-prem and Azure VNets can resolve the same name differently | Hard-to-diagnose, environment-specific failures |
| AMPLS needs 5 zones kept in sync by hand | Agents fall back to public ingestion or fail |
| Workload teams create their own `privatelink.*` zones | Fragmented, conflicting DNS |

## Target architecture

![Target architecture](/.attachments/ampls-dns-architecture.png)

> Upload the two PNGs from `ado/.attachments/` with the wiki editor (Insert image), or commit them to the wiki repo's `.attachments` folder, so the image paths above resolve.
> The editable source is `ampls-dns-architecture.drawio` (draw.io, official Azure icons).

### How a lookup flows

::: mermaid
sequenceDiagram
    participant C as On-prem client
    participant D as Enterprise DNS
    participant R as Resolver inbound 10.0.0.4
    participant A as Azure DNS 168.63.129.16
    participant Z as Central zone privatelink.blob
    C->>D: st1.blob.core.windows.net?
    D->>R: conditional forwarder blob.core.windows.net
    R->>A: recursive query from hub VNet
    A-->>A: public CNAME st1.privatelink.blob.core.windows.net
    A->>Z: hub VNet is linked to zone
    Z-->>R: A 10.0.1.x
    R-->>D: 10.0.1.x
    D-->>C: 10.0.1.x (traffic over ExpressRoute to the private endpoint)
:::

Spoke VNets skip the enterprise DNS step. Their VNet DNS setting is the resolver inbound IP.

## Who does what, by subscription

| Layer | Owns | Configuration |
|---|---|---|
| **Enterprise DNS servers** (DCs / Infoblox) | DNS / Network Ops | Conditional forwarders for the **public** zones (`blob.core.windows.net`, `vault.azure.net`, `monitor.azure.com` …) → resolver inbound IPs (primary + DR). **No `privatelink.*` zones.** |
| **Network / connectivity subscription** | Platform Networking | DNS Private Resolver (static inbound IP, outbound endpoint, ruleset for on-prem domains only). Central `privatelink.*` zones in `rg-dns-privatezones` (CanNotDelete lock), linked to the hub VNet (and DR hub) only. Shared private-endpoint subnet. |
| **Shared production / management subscription** | Monitoring / Platform | One AMPLS (Open/Open during migration), shared Log Analytics, DCE, App Insights. AMPLS private endpoint resource with its NIC in the hub subnet and a zone group pointing at the 5 central monitor/blob zones. |
| **Workload subscriptions** | Application teams | Spoke VNet DNS = resolver inbound IP. Create private endpoints only: zone groups are added by policy. No private DNS zones. Add workspaces/App Insights to the central AMPLS; never create a second AMPLS. |
| **Management group** | Platform Governance | DINE policy: private endpoint → central zone group (per `groupId`). Deny `privatelink.*` zones in landing zones (Audit during migration, Deny after). |

## Key design rules

1. **One AMPLS per DNS namespace.** Azure Monitor endpoints such as `api.monitor.azure.com` are global. A second AMPLS on networks that share this resolver overwrites the shared records.
2. **Blob storage moves with AMPLS.** The AMPLS private endpoint writes into `privatelink.blob.core.windows.net`, so the blob zone and AMPLS cut over in the same wave.
3. **Forward the public zone, never `privatelink.*`.** Delete the local `privatelink.*` zone at cutover. A leftover zone is more specific and keeps winning.
4. **The resolver's outbound ruleset forwards on-prem names only.** Forwarding Azure public zones back to on-prem creates a loop.
5. **AMPLS stays in Open mode until every workspace/component is scoped.** Private Only blocks every network on this DNS from anything outside the AMPLS.

## Migration plan

Zones leave the DNS servers one wave at a time, lowest blast radius first.

![Migration flow](/.attachments/ampls-dns-migration-flow.png)

| Wave | Scope | Zones | Forwarders added |
|---|---|---|---|
| 0 | Build | None moved: resolver, zones, AMPLS, policies (Audit) | None |
| 1 | Key Vault | `privatelink.vaultcore.azure.net` | `vault.azure.net`, `vaultcore.azure.net` |
| 2 | Databases and messaging | SQL, PostgreSQL, Cosmos DB, Service Bus | `database.windows.net`, `postgres.database.azure.com`, `documents.azure.com`, `servicebus.windows.net` |
| 3 | Apps and non-blob storage | ACR, App Service, file / queue / table / dfs | `azurecr.io`, `azurewebsites.net`, `file\|queue\|table\|dfs.core.windows.net` |
| 4 | Blob + AMPLS | blob + 4 Azure Monitor zones | `blob.core.windows.net`, `monitor.azure.com`, `oms\|ods.opinsights.azure.com`, `agentsvc.azure-automation.net`, `applicationinsights.azure.com` |
| 5 | Lock down | Deny policy → Deny; AMPLS → PrivateOnly; workspace public ingestion off | None |

### Indicative timeline

_Proposed dates, subject to CAB slots and DNS team availability._

::: mermaid
gantt
    title AMPLS / Private Link DNS migration (proposed)
    dateFormat YYYY-MM-DD
    axisFormat %d %b
    section Build
    Resolver, zones, AMPLS, policies   :b1, 2026-11-09, 10d
    Discovery and reconcile            :b2, after b1, 5d
    Spoke DNS changes                  :b3, after b1, 10d
    section Cutover waves
    Wave 1 Key Vault                   :w1, after b2, 5d
    Wave 2 Databases and messaging     :w2, after w1, 5d
    Wave 3 Apps and storage            :w3, after w2, 5d
    Wave 4 Blob and AMPLS              :w4, after w3, 5d
    section Close
    Lock down and handover             :l1, after w4, 5d
:::

### Per-wave procedure

Each wave is one change record, so the same tooling runs every time.

1. **Prepare.** Raise the change and lower record TTLs 24 hours ahead.
2. **Reconcile.** Run `03-Compare-DnsInventory.ps1` for the wave's zones. It must exit 0.
3. **Parity gate.** Run `06-Test-ResolverParity.ps1`. Current DNS and the resolver must return the same answers. **No-go if it fails.**
4. **Cut over.** Run `07-Invoke-ZoneCutover.ps1 -WhatIf`, then live with `-AutoRollback`. It adds the forwarders, removes the local zone, flushes caches and validates. Force AD replication afterwards.
5. **Validate clients.** Run `09-Test-AmplsConnectivity.ps1` / `test-resolution.sh` from an on-prem host, a spoke VM and an ARO node.
6. **Soak.** Wait 48 hours, then close the change.

### Before the first wave

| Step | Script | Exit criteria |
|---|---|---|
| Export and back up on-prem zones | `01-Export-OnPremPrivatelinkZones.ps1` / `export-zone-axfr.sh` | Backups stored with the change record |
| Inventory every private endpoint | `02-Get-AzPrivateEndpointInventory.ps1` | `azure-pe.csv` complete |
| Reconcile on-prem vs Azure vs central | `03-Compare-DnsInventory.ps1` | Reviewed. `NewPrivatePath` rows have routes/NSGs checked |
| Backfill zone groups on existing PEs | `04-Set-PeDnsZoneGroup.ps1` | No `NeedsZoneGroup` / `CentralIpDrift` |
| Import confirmed orphan records | `05-Import-OrphanRecords.ps1` | Every orphan marked keep / drop by its owner |

## Testing and validation

| Test | Where it runs | Pass criteria |
|---|---|---|
| Resolver parity (`06`) | On-prem host | All `Match` or expected change; every answer in the private range |
| Cutover validation (`07`) | DNS server | Every migrated name resolves the same via the DNS server and via the resolver |
| AMPLS client check (`09`) | On-prem server, spoke VM, ARO node | Every Monitor endpoint resolves to the PE subnet and TCP 443 connects |
| Resolution matrix (`test-resolution.sh`) | Linux / ARO nodes | `OK` for KV, Storage, SQL, ACR, Monitor FQDNs |
| AMPLS scope + heartbeats (`10`) | Admin workstation | All workspaces/components scoped; no agent stale > 15 min |
| Policy | Landing zone | A test PE gets a `deployedByPolicy` zone group within 30 min |

## Rollback

* `07-Invoke-ZoneCutover.ps1 -AutoRollback` restores automatically if validation fails.
* Manual rollback: `08-Undo-ZoneCutover.ps1 -LogPath <cutover log>`. It removes the forwarders it added, recreates the zone with its original replication scope and records, then flushes caches.
* Rollback affects only the zones in that wave. Earlier waves stay on the new path.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Clients that resolve public today switch to the private IP at cutover (`NewPrivatePath`) | Reconcile flags them. Routes and NSGs are checked before the wave |
| A second AMPLS created by a team overwrites the shared Monitor records | Design rule 1, team guidance, review in policy/PR |
| Orphan records (partner or other-tenant endpoints) stop resolving | Reconcile flags them. Owners confirm, then they are imported as static records |
| AD replication lag leaves some DNS servers on the old zone | Force replication and flush caches as part of the procedure |
| Terraform in workload repos fights the policy-added zone group | Module update: `ignore_changes` on the private endpoint zone group |
| Resolver unavailable | Resolver in two regions. Forwarders list both inbound IPs |

## Decisions and approvals needed

- [ ] Approve the target architecture and wave plan
- [ ] CAB windows for waves 1–4 (one per week)
- [ ] DNS / Network Ops time for each cutover window and for the on-prem forwarder changes
- [ ] Approval to assign DINE + Deny (Audit) policies at the landing-zones management group
- [ ] App team communication: spoke DNS change, "no private DNS zones" rule, Terraform module update

## Delivery tracking

The backlog (1 Epic, 10 Features, 26 User Stories, 56 Tasks) is generated from `ado/backlog.json`:

```powershell
$env:ADO_PAT = '<PAT with Work Items: Read & write>'
./ado/New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/<org> -Project <project> -AreaPath '<project>\Networking' -WhatIf
./ado/New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/<org> -Project <project> -AreaPath '<project>\Networking' -ValidateOnly
./ado/New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/<org> -Project <project> -AreaPath '<project>\Networking'
```

Query for every item: `Tags Contains ampls-dns-migration`.

## Repository layout

| Path | Contents |
|---|---|
| `config/zone-map.json` | groupId → privatelink zone(s) → public zone to forward; wave assignment |
| `infra/terraform/` | Connectivity (resolver, zones, links, ruleset), management (AMPLS, DCE, PE), policy |
| `infra/policy/` | DINE zone-group policy, Deny `privatelink.*` zones |
| `infra/workload-spoke.tf.example` | What a workload subscription owns afterwards |
| `scripts/01–10` | Inventory → reconcile → backfill → parity → cutover / rollback → validation |
| `ado/` | This page, diagrams, backlog definition, ADO creation script |

## References

* [Design Azure Monitor private link configuration](https://learn.microsoft.com/azure/azure-monitor/logs/private-link-design)
* [Azure Private Endpoint DNS integration](https://learn.microsoft.com/azure/private-link/private-endpoint-dns-integration)
* [Azure Private Endpoint private DNS zone values](https://learn.microsoft.com/azure/private-link/private-endpoint-dns)
* [What is Azure DNS Private Resolver?](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview)
