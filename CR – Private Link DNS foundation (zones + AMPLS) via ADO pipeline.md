# CR – Private Link DNS foundation (zones + AMPLS) via ADO pipeline

Nov 18, 2026 · @Pradeep Toluganti

This change deploys the central Private Link DNS foundation through the PlatformShared.IaC Terraform pipeline. It changes no name resolution for any client: the zones are linked only to the transit hub, and on-prem DNS is untouched until the separate Key Vault cutover change.

## CHG record set-up

Raise this as a Normal Change in ServiceNow with risk Low, so it doesn't need enterprise CAB. Create the CHG at least 24 hours before the planned start.

| CHG field | Value |
| --- | --- |
| Short description | Platform Engineering – Deploy central Azure Private DNS zones and Azure Monitor Private Link Scope (CR-1 of Private Link DNS migration) |
| Category | Business application |
| Configuration Item | Brewin Dolphin – Platform Engineering (Terraform-delivered change) |
| LOB Approver | WMI Europe & Asia Jurisdiction (confirm on the LeanIX Fact tab for Platform Engineering); remove any other LOB approvers |
| Risk | Low: additive resources only, no change to on-prem DNS, rollback tested in non-prod. If P3 finds clients resolving through the resolver and `privatelink.vaultcore.azure.net` is held back, the risk stays Low |
| Planned start | At least 24h after CHG creation, in the team's normal change window |
| Duration | 45 minutes |
| CTASKs | Assigned to yourself first. Otherwise updating them fails because the start/end times don't line up with the CHG |
| Approvals | After requesting approval, allow a few minutes for the approvers to appear |

If the risk assessment comes out above Low (for example, P3 shows resolver clients and you still want vaultcore linked), it goes to enterprise CAB. Submit by the deadline on the Enterprise CAB Schedule and Deadlines page.

## Description field (paste as is)

**1. Brief description and business/operational reason**

This change deploys, through the Platform Engineering Terraform pipeline, the central Azure Private DNS zones for Key Vault and Azure Monitor and an Azure Monitor Private Link Scope (AMPLS) in subscription p0004ss. It also adds one private endpoint subnet (10.250.192.160/27) to the transit hub VNet p-prod-ccoe-brz8-transit-vnet-weu-1.

Today, private endpoint DNS records are maintained by hand in privatelink zones on the on-premises Windows DNS servers. The records drift from the real endpoint IPs, which causes connection failures, and new endpoints are not registered automatically. The new central zones let private endpoints register their own DNS records, resolved through the existing DNS Private Resolver (10.250.192.132). This change is the foundation only. Moving Key Vault name resolution to the new zones is a separate change (CR-2).

**2. Impacts during implementation**

No impacts to business or operations during implementation.

No on-premises DNS server is changed, so all on-premises name resolution continues unchanged. The new zones are linked only to the transit hub VNet. Pre-check P3 confirms that no workload currently resolves through the DNS Private Resolver; if any does, the Key Vault zone is created but not linked until CR-2. Adding a subnet to the hub VNet does not interrupt existing subnets, peerings or ExpressRoute traffic.

**3. Worst case scenario and backout plan**

Worst case: an Azure workload that resolves through the transit hub or the DNS Private Resolver receives "not found" for a Key Vault or Azure Monitor name once the new zones are linked, causing that workload's Key Vault or telemetry calls to fail. On-premises clients are not affected in any scenario.

Backout: delete the affected zone's link to the hub VNet with one Azure CLI command. This takes effect within minutes and restores the previous resolution. Full backout is the same pipeline run with action "destroy", which removes every resource created by this change in about 15 minutes. Both backout methods were tested in non-production (see Test Plan).

If the backout itself fails (for example, a permissions error on the link delete), the Network Owner removes the link in the Azure portal with their own rights. As a stop-gap, the affected workload's VNet DNS setting can be pointed back to the on-premises DNS servers. Either action restores service in under 15 minutes.

## Implementation Plan field (paste as is)

Deployment is a single Azure DevOps pipeline run of azure-pipelines-platform-dns.yml (repo PlatformShared.IaC, branch main, target prod, action apply). The run has four stages: Plan, Approval, Apply, Verify.

1. Pre-checks P1–P7 are re-confirmed on the day (CTASK 1). The evidence is in CR1\_Prerequisite\_Evidence.docx: identity roles, free address space 10.250.192.160/27, no workloads resolving through the DNS Private Resolver, no other AMPLS, hub VNet ownership confirmed, policy check, ADO set-up.
2. The Plan stage output is compared with the approved plan in CR1\_tfplan\_prod\_\<BuildNumber>.txt. It must show 16 resources to add, 0 to change and 0 to delete. Any difference stops the change.
3. The implementer approves the platform-shared-prd environment gate. The Apply stage deploys exactly the reviewed plan file (CTASK 2).
4. The Verify stage runs Test-DnsFoundation.ps1, and the manual checks M1–M4 are completed (CTASK 3). The checks prove that the zones, links, AMPLS and private endpoint are correct and that on-premises Key Vault and Azure Monitor resolution is unchanged.
5. The pipeline run URL, the Verify log (CR1\_Prod\_Verify\_Log.txt) and the AMPLS private endpoint IPs are attached and the CHG is closed (CTASK 5).

The detailed step-by-step procedure, with timings, commands and pass criteria, is in CR1\_PrivateLinkDNS\_Implementation\_Plan\_v1.0.docx, sections "Implementation steps" and "Verification".

## Test Plan field (testing evidence)

The same pipeline and Terraform code are deployed and rolled back in the Non-Production subscription before the CHG is submitted. ECM no longer accepts earlier change records as evidence, so this run is the evidence. Answer "Yes" to the risk question "Was there any Pre-Production testing performed prior to deployment?".

**Non-prod set-up (once).** Create an isolated test VNet that no workload uses. A linked zone takes over name resolution for that VNet, so never point the test at a VNet with workloads.

```bash
az group create -n rg-dnstest-nonprod -l westeurope --subscription <Non-Production subscription id>
az network vnet create -g rg-dnstest-nonprod -n vnet-dnstest-nonprod --address-prefixes 10.254.250.0/24 \
  --subscription <Non-Production subscription id> -l westeurope
```

Variable group `platform-dns-tf-nonprod`:

- SHARED\_SUBSCRIPTION\_ID and PRODUCTION\_SUBSCRIPTION\_ID = Non-Production subscription id
- HUB\_VNET\_RG = rg-dnstest-nonprod, HUB\_VNET\_NAME = vnet-dnstest-nonprod
- PE\_SUBNET\_PREFIX = 10.254.250.0/27
- TF\_STATE\_KEY = platform-dns-nonprod.tfstate (state separate from prod)

**Tests and evidence**

| # | Test | Pipeline run / command | Pass | Evidence file |
| --- | --- | --- | --- | --- |
| T1 | Implementation | target nonprod, action apply | Plan 0 to change / 0 to delete; Verify stage green | CR1\_tfplan\_nonprod\_\<BuildNumber>.txt, CR1\_NonProd\_Deploy\_Verify\_Log.txt |
| T2 | Idempotency | Same run again | Plan reports no changes; Apply stage skipped | CR1\_NonProd\_Rerun\_NoChanges.txt |
| T3 | Fast backout (Option A) | `az network private-dns link vnet delete` on `privatelink.monitor.azure.com` | Link gone; next plan shows exactly 1 to add (the link) | CR1\_NonProd\_Unlink\_Backout.txt |
| T4 | Full backout (Option B) | target nonprod, action destroy | Destroy completes; `az group show` on both RGs returns not found; test subnet removed | CR1\_NonProd\_Rollback\_Log.txt |
| T5 | Redeploy after backout | target nonprod, action apply | Verify stage green again | Included in CR1\_NonProd\_Rollback\_Log.txt |

After T5, run the destroy once more and delete `rg-dnstest-nonprod`, so nothing is left in non-prod.

The guard that refuses deleting plans (`allowDestroyInPlan=false`) is also shown working in T3: the plan to re-add the link is an add, not a delete. Note the limit of the test: the non-prod VNet has no on-prem DNS or resolver in front of it, so checks M2 and M3 can only be run in production. They are read-only checks.

## Attachments and change tasks

Attach every file below to the CHG and refer to each by its exact filename, never as "see attached". Approvals and sign-offs go on as the original emails.

| Filename | Contents | Produced by |
| --- | --- | --- |
| CR1\_PrivateLinkDNS\_Implementation\_Plan\_v1.0.docx | Detailed plan: everything below the line in this doc (export to Word) | You |
| CR1\_Prerequisite\_Evidence.docx | Screenshots or command output for P1–P7 | You, CTASK 1 |
| CR1\_tfplan\_nonprod\_\<BuildNumber>.txt | Non-prod plan output | Pipeline artifact chg-evidence-plan |
| CR1\_NonProd\_Deploy\_Verify\_Log.txt | T1 Verify stage log | Pipeline log download |
| CR1\_NonProd\_Rerun\_NoChanges.txt | T2 plan log | Pipeline log download |
| CR1\_NonProd\_Unlink\_Backout.txt | T3 command output and follow-up plan | You |
| CR1\_NonProd\_Rollback\_Log.txt | T4 destroy and T5 redeploy logs | Pipeline log download |
| CR1\_tfplan\_prod\_\<BuildNumber>.txt | Prod plan from the PR or main run, reviewed before approval | Pipeline artifact chg-evidence-plan |
| CR1\_NetworkOwner\_Signoff.msg | Network owner agrees to the new hub subnet and confirms the hub VNet isn't managed with inline subnets (P5) | Email |
| CR1\_DNS\_AD\_Team\_Notification.msg | DNS/AD team informed; confirms no on-prem change (P3 forwarder check) | Email |
| CR1\_Prod\_Verify\_Log.txt | Production Verify stage log plus M1–M4 output | Pipeline / you, CTASK 5 |

**Change tasks.** Create these on the CHG and assign them to yourself first.

| CTASK | Task | When |
| --- | --- | --- |
| 1 | Pre-implementation checks: re-run P2–P4, confirm the prod plan matches CR1\_tfplan\_prod\_\<BuildNumber>.txt | Start of window |
| 2 | Approve the environment gate and monitor the Apply stage | T+5 |
| 3 | Post-implementation verification: Verify stage plus M1–M4 | T+15 |
| 4 | Backout, only if triggered: Option A or B in the attachment's Backout section | If needed |
| 5 | Upload CR1\_Prod\_Verify\_Log.txt and the AMPLS endpoint IPs, then close | T+40 |

---

**Detailed implementation plan.** Everything below this line is exported as the attachment `CR1_PrivateLinkDNS_Implementation_Plan_v1.0.docx`.

## Change summary

| Field | Value |
| --- | --- |
| Title | Deploy central private DNS zones and AMPLS (Private Link DNS foundation) |
| Type | Normal change, risk Low (additive, no client traffic change) |
| Method | ADO pipeline `pipelines/azure-pipelines-platform-dns.yml`: plan → approval → apply of the reviewed plan file |
| Subscriptions | p0004ss (20be150d-f08a-4594-9260-958582967ba0); Production Subscription (transit hub VNet only) |
| New resources | 2 RGs, 5 private DNS zones + hub links, AMPLS `ampls-iep-prd-shd`, subnet `snet-iep-prd-pe` 10.250.192.160/27, private endpoint `pe-ampls-iep-prd-shd` |
| Changed resources | Transit VNet `p-prod-ccoe-brz8-transit-vnet-weu-1`: one subnet added |
| Duration | 45 min including checks (apply itself about 10 min) |
| Service impact | None expected |
| Backout | Unlink zones (minutes) or pipeline destroy run (about 15 min) |
| Follow-on | CR-2: Key Vault DNS cutover on the on-prem DNS servers (normal change, separate window) |

## Reason and scope

Private endpoint names are held today as hand-made privatelink zones on the on-prem Windows DNS servers. Records drift from the real endpoint IPs, and nothing registers new endpoints automatically. This CR builds the Azure side: central zones in p0004ss that endpoints register into, reached through the DNS Private Resolver inbound endpoint 10.250.192.132. It also adds the Azure Monitor Private Link Scope (AMPLS) so Log Analytics and App Insights traffic can move to private connectivity later.

**In scope**

- Resource groups `rg-iep-prd-pdnsz-shd` (zones; no resource lock, see R8) and `rg-iep-prd-mon-shd` (AMPLS) in p0004ss
- Private DNS zones `privatelink.vaultcore.azure.net`, `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`, each linked to the transit hub VNet only, with auto-registration off
- AMPLS `ampls-iep-prd-shd` with ingestion and query access modes **Open**
- Subnet `snet-iep-prd-pe` 10.250.192.160/27 in `p-prod-ccoe-brz8-transit-vnet-weu-1`, and private endpoint `pe-ampls-iep-prd-shd` with its DNS zone group
- ADO pipeline and environment approval used to deploy it

**Out of scope (later CRs)**

- CR-2: Key Vault migration: zone-group backfill, conditional forwarders on on-prem DNS, removal of the on-prem `privatelink.vaultcore.azure.net` zone
- Linking Log Analytics workspaces and App Insights components to the AMPLS, and switching it to PrivateOnly
- `privatelink.blob.core.windows.net` and other storage, SQL and service zones
- Azure Policy assignments (DINE zone groups, Deny shadow zones)

## Impact and risk

Impact is nil for on-prem clients: their DNS answers from the local privatelink zones until CR-2. The one group that can be affected is anything already resolving **through the resolver or the hub VNet's Azure DNS**. A linked zone takes over its whole namespace for those clients, so pre-check P3 decides which zones are linked in this CR.

| # | Risk | Effect if it happens | Mitigation |
| --- | --- | --- | --- |
| R1 | Clients already resolve via 10.250.192.132 or the hub (spoke DNS set to the resolver, or a DC forwarder to it) | Linked empty `privatelink.vaultcore.azure.net` returns NXDOMAIN for every vault with a private endpoint, including vendor vaults | P3. If any such client exists, set `hub_link_zones` to the 4 monitor zones; vaultcore is created but linked in CR-2 after zone-group backfill |
| R2 | Same clients send Azure Monitor traffic to the AMPLS endpoint once the monitor zones are linked | Telemetry routes over the private endpoint; Open mode keeps every workspace reachable, so data still flows | Open/Open in this CR; NSG on the subnet must allow 443 from those clients |
| R3 | Another AMPLS endpoint already exists on a network sharing this DNS | Global monitor records overwritten; telemetry for the other scope breaks | P4: `az monitor private-link-scope list` across subscriptions must return none outside this CR |
| R4 | Policy denies a subnet without an NSG / route table | Apply stops part way; resources created so far stay | Pass `pe_subnet_nsg_id`; partial applies are safe to re-run |
| R5 | 10.250.192.160/27 overlaps an existing subnet or reservation | Subnet create fails; no impact | P2: IPAM / `az network vnet subnet list` on the hub |
| R6 | Hub VNet subnets are also managed by another Terraform state with inline subnets | The other state removes `snet-iep-prd-pe` on its next apply | P5: confirm with the network owner; if inline, add the subnet in that repo instead |
| R7 | The pipeline identity lacks lock or cross-subscription rights | Apply fails; no impact | P1 role table |
| R8 | A CanNotDelete lock on the zones RG is inherited by record sets | Deleting a private endpoint can fail to remove its A record (ScopeLocked), leaving stale records | No lock in this CR. Protection: the pipeline refuses plans with deletes, RBAC on the RG, and a denyAction (DELETE) policy on private DNS zones in the policy CR |

## Prerequisites

All of P1–P7 are done and evidenced in the CR before approval. P3 decides the `hub_link_zones` value.

**P1 – Pipeline identity** (service connection `sc-platformshared-iac-oidc`, workload identity federation, no secret)

| Scope | Role | Why |
| --- | --- | --- |
| p0004ss subscription | Contributor | Create RGs, zones, AMPLS, private endpoint |
| p0004ss subscription | `Only if enable_zone_delete_lock is turned on: custom role with locks/*` | Contributor cannot create or delete locks |
| Hub VNet `p-prod-ccoe-brz8-transit-vnet-weu-1` | Network Contributor | Subnet write, plus `virtualNetworks/join/action` for the zone links and the private endpoint |
| Hub NSG / route table (if passed) | Network Contributor | `join/action` for the subnet association |
| Terraform state container | Storage Blob Data Contributor | Entra ID auth to state; no storage keys |

**P2 – Address space.** 10.250.192.160/27 is free and inside the hub address space: `az network vnet subnet list -g <hub rg> --vnet-name p-prod-ccoe-brz8-transit-vnet-weu-1 --subscription <prod> -o table`

**P3 – Who resolves through the resolver today.** List VNet DNS servers tenant-wide, and DC forwarders to the inbound IP:

```bash
az graph query -q "resources | where type =~ 'microsoft.network/virtualnetworks' | project subscriptionId, name, dns = properties.dhcpOptions.dnsServers" --first 1000 -o table
```

```powershell
Get-DnsServerZone -ComputerName <DC> | Where-Object { $_.ZoneType -eq 'Forwarder' -and $_.MasterServers.IPAddressToString -contains '10.250.192.132' }
```

If any VNet uses 10.250.192.132 (or the hub VNet hosts VMs on Azure DNS), or any forwarder exists, set `hub_link_zones` to the four monitor zones. vaultcore is then linked in CR-2.

**P4 – No other AMPLS.** `az graph query -q "resources | where type =~ 'microsoft.insights/privatelinkscopes'"` returns nothing, or only scopes on networks that never share this DNS.

**P5 – Hub VNet ownership.** The network owner confirms the hub VNet is not managed with inline `subnet {}` blocks in another state.

**P6 – Policy.** Check the deny assignments that reach the hub RG and p0004ss (NSG required on subnets, allowed locations, required tags): `az policy assignment list --scope <hub rg id> --query "[].displayName"`. Set `pe_subnet_nsg_id` if needed.

**P7 – ADO setup**

- [ ] Variable group`s platform-dns-tf-prod / -nonprod`: TF\_STATE\_RG, TF\_STATE\_SA, TF\_STATE\_CONTAINER, TF\_STATE\_KEY, PRODUCTION\_SUBSCRIPTION\_ID, HUB\_VNET\_RG, plus optional PE\_SUBNET\_NSG\_ID and HUB\_LINK\_ZONES. Create two groups, platform-dns-tf-prod and platform-dns-tf-nonprod (non-prod values in the Test Plan section), each with its own TF\_STATE\_KEY
- [ ] Environments platform-shared-nonprod (no check) and `platform-shared-prd` with an Approvals check: CAB implementer + network owner, requester can't approve
- [ ] Branch policy on `main`: PR required, and the pipeline's plan stage as a build validation
- [ ] Pipeline created from `pipelines/azure-pipelines-platform-dns.yml`, with permission granted to the service connection, variable group and environment

## Implementation steps

The change is one pipeline run: Plan → Approval → Apply → Verify. The approver signs off on the exact plan file that is applied; Terraform refuses the apply if state has moved since the plan.

**Before the window (T-2 days)**

1. Run tests T1–T5 in non-prod (pipeline target nonprod, from the feature branch) and collect the evidence files. Then raise a PR to `main` with `terraform/`, `pipelines/` and `scripts/Test-DnsFoundation.ps1`. The PR build runs fmt, validate and plan; there is no apply on PRs.
2. Review the plan output (step log "Plan output"). Expected: 16 to add (2 RGs, 5 zones, 5 hub links, AMPLS, subnet, private endpoint); 17 with the NSG association, 1 fewer per zone held back in HUB\_LINK\_ZONES, **0 to change, 0 to destroy**. Attach `plan.txt` to the CR.
3. Set `HUB_LINK_ZONES` in the variable group from the P3 result (empty = link all 5).
4. Merge the PR after the CHG is approved, then run the pipeline on main with target prod. The `main` run plans again and waits at the `platform-shared-prd` approval.

**In the window (about 45 min)**

1. **T+0:** open the waiting run. Compare its Plan stage summary line (`N to add, 0 to change, 0 to delete/replace`) with the plan attached to the CR. Any change or delete means stop and reject.
2. **T+5:** approve. The Apply stage runs `terraform apply tfplan`; the private endpoint takes 2–5 min.
3. **T+15:** the Verify stage runs `Test-DnsFoundation.ps1` and must be green (see Verification).
4. **T+20:** run the manual checks in Verification.
5. **T+40:** record the run URL, the `ampls_pe_ips` output and the Verify log in the CR, and close as successful.

**If the apply fails part way:** fix the cause (usually a role or a policy deny), then re-run the pipeline. Terraform creates only what is missing; nothing already created is replaced.

## Verification

The change is successful when the Verify stage is green and the four manual checks match. Each check proves either that the foundation works or that nothing changed for on-prem clients.

**Automated** (pipeline Verify stage, `scripts/Test-DnsFoundation.ps1`, exits 1 on any failure)

| Check | Pass |
| --- | --- |
| Each linked zone | Link to the hub VNet is `Completed`, auto-registration off |
| Each held-back zone | Zone exists, 0 links |
| Zones RG | No CanNotDelete lock (R8) |
| AMPLS `ampls-iep-prd-shd` | Ingestion Open, query Open |
| `pe-ampls-iep-prd-shd` | Provisioning Succeeded, connection Approved, in `snet-iep-prd-pe` |
| AMPLS zone group | 4 zone configs, at least 8 record sets |
| `privatelink.monitor.azure.com` | `api` A record points to an IP in 10.250.192.160/27 |

**Manual** (from an on-prem admin host)

| # | Command | Expected |
| --- | --- | --- |
| M1 | `Resolve-DnsName api.privatelink.monitor.azure.com -Server 10.250.192.132` | An IP in 10.250.192.160/27: the resolver serves the new zone |
| M2 | `Resolve-DnsName api.monitor.azure.com -Server <DC>` | Same public answer as before the change: on-prem is unaffected |
| M3 | `Resolve-DnsName <a prod vault>.vault.azure.net -Server <DC>` | Same private IP as before: on-prem Key Vault resolution is unaffected |
| M4 | Spoke VM (if P3 found resolver clients): `nslookup api.monitor.azure.com` then `Test-NetConnection api.monitor.azure.com -Port 443` | Private IP and port open; otherwise allow 443 on the NSG |

## Backout

Back out if the Verify stage fails and can't be fixed in the window, or if M2, M3 or M4 show a resolution change nobody expected. The fast option removes the impact in minutes and keeps the resources for a retry; full removal is a pipeline destroy.

**Option A – unlink (about 5 min, for resolution impact).** Removing a hub link stops that zone answering for anyone resolving through the hub:

```bash
az network private-dns link vnet delete -g rg-iep-prd-pdnsz-shd -z <zone> -n lnk-p-prod-ccoe-brz8-transit-vnet-weu-1 \
  --subscription 20be150d-f08a-4594-9260-958582967ba0 --yes
```

Then remove that zone from `HUB_LINK_ZONES` (or set it) so the next pipeline run doesn't recreate the link.

**Option B – full removal (about 15 min).** Run the pipeline from `main` with `action = destroy`. It plans the destroy, waits at the same approval, then applies it. This removes the private endpoint, subnet, AMPLS, links, zones and RGs. Nothing else depends on them yet: no workspaces are linked and on-prem DNS isn't pointing at them.

**Backout verification:** M2 and M3 return the same answers as before the change, and `az network vnet subnet list` on the hub no longer shows `snet-iep-prd-pe` (Option B).

## Follow-on changes and communication

CR-2 can be raised once this CR closes. It needs the zone-group backfill evidence (`Test-KvDnsMigration.ps1 -Stage Pre` exiting 0) attached, and its own window, because it changes on-prem DNS.

| CR | Change | Type | Depends on |
| --- | --- | --- | --- |
| CR-2 | Key Vault migration: backfill zone groups, link vaultcore (if held back), on-prem forwarders `vault.azure.net` / `vaultcore.azure.net` → 10.250.192.132, remove the on-prem `privatelink.vaultcore.azure.net` zone | Normal | CR-1 closed; Pre check exit 0; TTL lowered 2 days before |
| CR-3 | Azure Policy: DINE zone groups for Key Vault, Deny (Audit first) on shadow zones, denyAction on zone deletes | Normal | CR-2 |
| CR-4 | AMPLS wave: link workspaces and App Insights, forwarders for monitor namespaces, then PrivateOnly | Normal | CR-1 |

**Communication**

- Before: network owner and DNS/AD team (P3, P5 evidence); platform channel notice 24h ahead ("no expected impact")
- After: CR closure with the run URL, the Verify log and the AMPLS endpoint IPs; DNS/AD team told that CR-2 planning starts
