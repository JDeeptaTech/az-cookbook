# Wave 1: Key Vault + AMPLS foundation

**Scope:** move `privatelink.vaultcore.azure.net` from on-prem Windows DNS to the central Azure Private DNS zone in p0004ss, resolved through the DNS Private Resolver inbound endpoint `10.250.192.132`. Also deploy the AMPLS and its 4 monitor zones (Open/Open, so there's no client impact yet).

| Item | Value |
|---|---|
| Central zone | `privatelink.vaultcore.azure.net` in `rg-iep-prd-pdnsz-shd` (p0004ss) |
| Zone VNet link | `p-prod-ccoe-brz8-transit-vnet-weu-1` only (registration off) |
| On-prem forwarders | `vault.azure.net` and `vaultcore.azure.net` → `10.250.192.132` |
| AMPLS | `ampls-iep-prd-shd`, PE `pe-ampls-iep-prd-shd` in `snet-iep-prd-pe` 10.250.192.160/27 |
| Rollback | Restore the on-prem zone from backup and remove the forwarders (kit script 08) |

> **Why forward the public zones, not `privatelink.vaultcore.azure.net`:** clients query `kv.vault.azure.net`. The CNAME chain then goes to `kv.privatelink.vaultcore.azure.net`. The CNAME has to be answered by Azure DNS, so the public zone must go to the resolver. Forwarding only the privatelink zone works while the local zone exists, but it breaks vaults whose PE isn't in your zone and makes the cutover non-atomic.
>
> **Effect after the cutover:** every Key Vault in the world resolves through Azure from on-prem. Vaults without a PE in your central zone (including third-party and Microsoft-owned vaults) resolve to their public IP, exactly as today. Vaults that **do** have a PE but no record in the central zone also resolve public. That's the failure mode this runbook guards against.

---

## T-5 days: pre-checks

| # | Check | Command / where | Pass |
|---|---|---|---|
| 1 | Resolver inbound reachable from every DC (UDP+TCP 53) | `Resolve-DnsName login.microsoftonline.com -Server 10.250.192.132` on each DC | answers |
| 2 | NSG `nsg-iep-prd` on the inbound subnet allows 53 from the on-prem DC ranges | portal / `az network nsg rule list` | allow rule |
| 3 | ER/VPN routes the DC subnets to 10.250.192.128/28 (no FastPath on that gateway path) | effective routes | present |
| 4 | Spoke VNets use the resolver (or a DC that forwards) as DNS, **not** 168.63.129.16 directly | `az network vnet show --query dhcpOptions` | consistent |
| 5 | No conditional forwarder or stub for `vault.azure.net` / `vaultcore.azure.net` already exists on any DC | `Get-DnsServerZone` on all DCs | none |
| 6 | Zone replication scope of `privatelink.vaultcore.azure.net` on-prem (Forest/Domain/Custom) | `Get-DnsServerZone -Name privatelink.vaultcore.azure.net` | noted for rollback |
| 7 | Any non-domain DNS servers (DMZ, Linux BIND, appliances) holding their own copy | DNS owners | listed, in the change |
| 8 | Managed HSM in use? It uses `privatelink.managedhsm.azure.net`: separate wave, not covered here | `az resource list --resource-type Microsoft.KeyVault/managedHSMs` | noted |

## T-5 days: deploy the foundation (Terraform)

```bash
cd terraform
# Deployed by CR-1 through pipelines/azure-pipelines-platform-dns.yml (plan -> approval -> apply -> verify).
# Local equivalent for a dry run only:
cp terraform.tfvars.example terraform.tfvars   # fill production_subscription_id + hub_vnet_resource_group
terraform init -backend=false && terraform validate
```

This creates:
- the zones RG (no delete lock: it is inherited by record sets and can block PE record clean-up)
- the 5 zones, linked to the hub only; `hub_link_zones` can hold vaultcore back until its zone groups are backfilled
- the AMPLS (Open/Open), the hub subnet and the AMPLS PE with its 4-zone group

**No client impact:** on-prem still answers from its local zones. The spokes only see the new zones if their DNS is the resolver. Check the result of pre-check 4 first. If spokes already use the resolver and their PEs have zone groups to *spoke-local* zones, nothing changes for them. If spokes already use the resolver **and** rely on the on-prem zone via forwarding, that goes away now, so reconcile first (next step).

**Permissions:**
- The identity running Terraform needs `Microsoft.Network/virtualNetworks/join/action` and `subnets/write` on the hub VNet (Production subscription), plus Owner or Contributor on p0004ss.
- If the hub VNet is defined with inline `subnet {}` blocks in another state, add `snet-iep-prd-pe` there instead.

## T-4 days: reconcile the on-prem list against Azure

```powershell
az login
./scripts/Test-KvDnsMigration.ps1 -InputPath .\privatelink.vaultcore.txt -OnPremDns <DC-IP> -Stage Pre
```

The input can be an `Export-DnsServerZone` file, `dnscmd /enumrecords` output, a CSV, or bare names.

| Status | Meaning | Action |
|---|---|---|
| Ready | Central record = PE IP, and the resolver answers it | none |
| NeedsZoneGroup | The PE exists but has no record in the central zone | `-FixZoneGroups -WhatIf`, then without `-WhatIf` |
| ZoneGroupElsewhere | The PE registers into a spoke-local `privatelink.vaultcore` zone | `-FixZoneGroups -ReplaceExisting`. Agree with the spoke owner first, since that removes the record from their zone |
| CentralIpDrift | The central record ≠ PE IP (manual record, old PE) | Delete the stale record and recreate the zone group |
| NoPrivateEndpoint | The vault exists, but the on-prem record has no PE behind it | If the note says *PUBLIC ACCESS DISABLED*: **blocker**. Create a PE first, or exclude the vault. Otherwise it resolves public after the cutover (check the vault firewall allows the on-prem egress IPs) |
| VaultNotFound | The record is for a deleted vault | Owner sign-off, then drop it (the record isn't carried over) |
| note *OnPremStale* | The on-prem IP ≠ PE IP: those clients are broken today | The cutover fixes them. Tell the app owner |
| note *NotInOnPremList* | A PE exists but on-prem resolves public today | The cutover **switches these to private**. Make sure on-prem can route to the PE subnet and the NSG allows 443 |

Repeat until the script exits 0. Keep the CSV as the change evidence.

**Zone group backfill at scale:** `-FixZoneGroups` handles the PEs in the list. Kit flow `01`→`02`→`03` then `04-Set-PeDnsZoneGroup.ps1 -CentralZoneRgId <rg id>` covers every PE in the tenant from the reconcile CSV.

## T-2 days: parity and TTL
- **Parity:** kit `06-Test-ResolverParity.ps1 -CurrentDns <DC-IP> -ResolverInbound 10.250.192.132 -PrivateCidr 10.0.0.0/8 -Zone privatelink.vaultcore.azure.net` (needs `out/reconcile.csv` from kit 01–03; otherwise the Pre stage of `Test-KvDnsMigration.ps1` already does the resolver comparison). Every name the DC answers must get the same answer from the resolver (statuses Ready + OnPremStale only).
- **TTL:** lower the TTL on the on-prem zone records to 60s, so caches drain quickly at the cutover and on rollback. Raise it back after a week.
- **Freeze:** no new KV private endpoints get created by hand-registering in on-prem DNS from here on. Use the zone group only.

## Change window: cutover (≈15 min, low-traffic window)

```powershell
# On a DC, as DNS admin (kit ampls-dns-migration/scripts). It backs up the zone to a JSON log, adds the
# public-zone forwarders (vault.azure.net, vaultcore.azure.net, derived from the zone map), removes the zone,
# clears caches, probes the resolver and rolls back on failure. Run -WhatIf first.
.\07-Invoke-ZoneCutover.ps1 -Zone privatelink.vaultcore.azure.net -InboundIp 10.250.192.132 `
    -ComputerName DC01, DC02, DC03 -ReplicationScope Forest -AutoRollback -WhatIf
.\07-Invoke-ZoneCutover.ps1 -Zone privatelink.vaultcore.azure.net -InboundIp 10.250.192.132 `
    -ComputerName DC01, DC02, DC03 -ReplicationScope Forest -AutoRollback
```

Manual equivalent:
1. `Export-DnsServerZone -Name privatelink.vaultcore.azure.net -FileName kv-backup.dns` (also save `Get-DnsServerResourceRecord ... | Export-Clixml`)
2. `Add-DnsServerConditionalForwarderZone -Name vault.azure.net -MasterServers 10.250.192.132 -ReplicationScope Forest`. Repeat for `vaultcore.azure.net`.
3. `Remove-DnsServerZone -Name privatelink.vaultcore.azure.net -Force`
4. `repadmin /syncall /AdeP`, then `Clear-DnsServerCache` on **every** DC. Client side: `ipconfig /flushdns` on jump hosts and build agents.
5. Any non-AD DNS servers from pre-check 7: apply the same change by hand.

**Order matters:** add the forwarders before removing the zone. A local zone wins over a forwarder for its own names, so nothing changes until the zone is removed. That makes step 3 the actual switch.

## Validation (T+0)

```powershell
./scripts/Test-KvDnsMigration.ps1 -InputPath .\privatelink.vaultcore.txt -OnPremDns <DC-IP> -Stage Post
```

- Exit 0 means every vault with a PE resolves to its PE IP through on-prem DNS.
- From an on-prem client and a VM in each spoke (Prod, Non-Prod, Non-Prod 2):
  - `Resolve-DnsName kv-app1-prd.vault.azure.net` → CNAME `*.privatelink.vaultcore.azure.net` → 10.x
  - `Test-NetConnection kv-app1-prd.vault.azure.net -Port 443`
  - `az keyvault secret list --vault-name kv-app1-prd`
- App smoke tests:
  - AKS Secrets Store CSI or Key Vault references in App Service/Functions: restart a pod or the slot to force a fresh lookup
  - ADO pipelines using AzureKeyVault@2 from self-hosted agents
  - Terraform `azurerm_key_vault_secret` reads from on-prem agents
  - App Gateway/Front Door TLS certificates sourced from KV
  - SQL TDE/CMK and Storage CMK: these use the trusted-service path, not DNS, so they're unaffected. Still worth confirming.
- Watch for 30 min:
  - KV diagnostics: `AzureDiagnostics | where ResourceType == "VAULTS" and httpStatusCode_d == 403` shows calls arriving from public IPs after the cutover. These are clients that didn't flush, or vaults with no PE.

## Rollback (decide within the window)
**Triggers:** the Post stage fails for a production vault that can't be fixed with a zone group in 10 min, or an app smoke test fails on resolution.

Run `.\08-Undo-ZoneCutover.ps1 -LogPath .\cutover-logs\<cutover-log>.json` (the log 07 wrote). It removes the forwarders it added, recreates the zone from the backup and clears the caches. Then run `repadmin /syncall /AdeP`. Because of the 60s TTL, clients recover in about a minute.

## T+1 week: lock it in (policy)
1. Assign the DINE policy *Configure Azure Key Vaults to use private DNS zones* (built-in `ac673a9a-f77d-4846-b2d8-a57f8e1c01dc`) at the landing zones MG, with the central zone id and the MI roles (Network Contributor + Private DNS Zone Contributor on `rg-iep-prd-pdnsz-shd`). Run a remediation task for existing PEs.
2. Assign Deny for `privatelink.vaultcore.azure.net` zone creation outside p0004ss, starting in **Audit**. List the spoke shadow zones, delete them once the PEs register centrally, then switch to Deny.
3. Test with kit `11-Test-PrivateDnsPolicy.ps1 -Mode All -Services vault -ManagementGroup <mg> -ZoneSubscriptionId 20be150d-… -ZoneResourceGroup rg-iep-prd-pdnsz-shd -ResolverIp 10.250.192.132 -TestSubscriptionId … -TestSubnetId … -Location westeurope`: it creates a test KV + PE, waits for the zone group, asserts the record, and cleans up.
4. Raise the TTL back, close the change, and update the wiki/ADO items.

## Known gotchas
- **Hosts files:** on-prem servers with hard-coded `kv.vault.azure.net` entries override DNS. Grep build agents and app servers.
- **Proxies:** clients that go through an explicit web proxy resolve on the proxy, not on their own DNS. The proxy must use the DCs, or bypass `*.vault.azure.net`.
- **Split responsibility:** a vault whose PE sits in another tenant (a vendor) has no record in your zone and will resolve public after the cutover. Before the cutover it resolved through your hand-made on-prem record. Those vaults show up as *VaultNotFound* with an on-prem IP. **Don't drop them blindly.** Add an A record in the central zone by hand (`az network private-dns record-set a add-record`), and tag it.
- **Disabled public access + no PE = outage.** The Pre stage blocks on this.
