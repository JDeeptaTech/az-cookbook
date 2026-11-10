# Azure Policy inventory

Tenant `tenant-0000` · 2026-11-10 18:43 · 9 assignments (1 initiatives) · 2 exemptions

| Level | Assignments | Deny | DeployIfNotExists / Modify | Audit only |
|---|---|---|---|---|
| TenantRoot | 1 | 1 | 0 | 0 |
| ManagementGroup | 6 | 3 | 3 | 1 |
| Subscription | 1 | 0 | 1 | 0 |
| ResourceGroup | 1 | 1 | 0 | 0 |

## Findings

- 1 assignment(s) at the Tenant Root Group apply to every subscription, including new ones: Allowed locations. Keep root assignments to a minimum; prefer the intermediate root.
- 3 subscription(s) sit directly under the Tenant Root Group: Design Subscription, Non-Production Subscription, Production Subscription.
- Same definition assigned 2x to p0001app: Allowed locations (from ManagementGroup: Legacy Prod and TenantRoot: Tenant Root Group). Duplicate evaluation and conflicting parameters.
- Same definition assigned 2x to p0002data: Allowed locations (from ManagementGroup: Legacy Prod and TenantRoot: Tenant Root Group). Duplicate evaluation and conflicting parameters.
- 1 assignment(s) in DoNotEnforce (report only): Deploy diagnostic settings (report only) @ Default.
- 4 DeployIfNotExists/Modify assignment(s) without a managed identity (cannot remediate): Azure Security Benchmark, Deploy diagnostic settings, Deploy diagnostic settings (report only), AKS tag inheritance.
- Custom definitions stored below the root / 'bd': Custom @ mg:Default. Subscriptions moved out of that branch break assignments that use them.
- Most non-compliant: AKS tag inheritance @ p0005aks (9); Deploy diagnostic settings (report only) @ Default (7); Audit VMs without managed disks @ Default (5); Allowed locations @ Tenant Root Group (4); Azure Security Benchmark @ Brewin Dolphin (3).

## Assignments by level

```text
Tenant Root Group (tenant-0000)  — 1 assignment(s)
    • [P] Allowed locations · BuiltIn · Deny:1 · NC 4
    Brewin Dolphin (bd)  — 2 assignment(s)
        • [I] Azure Security Benchmark · BuiltIn · Deny:1 DeployIfNotExists:1 Audit:1 · NC 3
        • [P] Deny public IPs · Custom @ mg:bd · Deny:1 · NC 1
        Archive (bd-archive)
        Legacy Dev (bd-legacy-dev)
            [sub] n0002app
            [sub] n0003data
        Legacy Prod (bd-legacy-prod)  — 2 assignment(s)
            • [P] Allowed locations (prod copy) · BuiltIn · Deny:1
            • [P] Deploy diagnostic settings · BuiltIn · DeployIfNotExists:1
            [sub] p0001app  — 1 assignment(s)
                • rg rg-web: [P] Storage HTTPS only (rg-web) · BuiltIn · Deny:1 · NC 2
            [sub] p0002data
        Shared (bd-shared)
            [sub] p0001hub
            [sub] s0001lab
    Default (Default)  — 2 assignment(s)
        • [P] Audit VMs without managed disks · BuiltIn · Audit:1 · NC 5
        • [P] Deploy diagnostic settings (report only) · BuiltIn · DeployIfNotExists:1 · DoNotEnforce · NC 7
        [sub] n0001aks
        [sub] n0004ss
        [sub] n00bs66
        [sub] Non-Production Subscription 2
        [sub] p0004ss
        [sub] p0005aks  — 1 assignment(s)
            • [P] AKS tag inheritance · Custom @ mg:Default · Modify:1 · NC 9
    [sub] Design Subscription
    [sub] Non-Production Subscription
    [sub] Production Subscription
```

[P] policy · [I] initiative · NC = non-compliant resources · effects resolved through parameters (Deny:3 = three policies with Deny)

## Effective policies per subscription

| Subscription | Path | Applies | Inherited | Own (sub/RG) | Deny | DINE / Modify | Excluded | Exempted |
|---|---|---|---|---|---|---|---|---|
| n0002app | Tenant Root Group > Brewin Dolphin > Legacy Dev > n0002app | 3 | 3 | 0 | 3 | 1 | 0 | 0 |
| n0003data | Tenant Root Group > Brewin Dolphin > Legacy Dev > n0003data | 3 | 3 | 0 | 3 | 1 | 0 | 0 |
| p0001app | Tenant Root Group > Brewin Dolphin > Legacy Prod > p0001app | 6 | 5 | 1 | 5 | 2 | 0 | 0 |
| p0002data | Tenant Root Group > Brewin Dolphin > Legacy Prod > p0002data | 5 | 5 | 0 | 4 | 2 | 0 | 1 |
| p0001hub | Tenant Root Group > Brewin Dolphin > Shared > p0001hub | 3 | 3 | 0 | 3 | 1 | 0 | 0 |
| s0001lab | Tenant Root Group > Brewin Dolphin > Shared > s0001lab | 2 | 2 | 0 | 2 | 1 | 1 | 0 |
| n0001aks | Tenant Root Group > Default > n0001aks | 2 | 2 | 0 | 0 | 1 | 0 | 1 |
| n0004ss | Tenant Root Group > Default > n0004ss | 2 | 2 | 0 | 0 | 1 | 0 | 1 |
| n00bs66 | Tenant Root Group > Default > n00bs66 | 2 | 2 | 0 | 0 | 1 | 0 | 1 |
| Non-Production Subscription 2 | Tenant Root Group > Default > Non-Production Subscription 2 | 2 | 2 | 0 | 0 | 1 | 0 | 1 |
| p0004ss | Tenant Root Group > Default > p0004ss | 2 | 2 | 0 | 0 | 1 | 0 | 1 |
| p0005aks | Tenant Root Group > Default > p0005aks | 3 | 2 | 1 | 0 | 2 | 0 | 1 |
| Design Subscription | Tenant Root Group > Design Subscription | 1 | 1 | 0 | 1 | 0 | 0 | 0 |
| Non-Production Subscription | Tenant Root Group > Non-Production Subscription | 1 | 1 | 0 | 1 | 0 | 0 | 0 |
| Production Subscription | Tenant Root Group > Production Subscription | 1 | 1 | 0 | 1 | 0 | 0 | 0 |

## Exemptions

| Level | Scope | Exemption | Category | Assignment | Expires |
|---|---|---|---|---|---|
| ManagementGroup | Default | AKS outside allowed regions |  | allowed-loc |  |
| ResourceGroup | p0002data / rg-legacy | Legacy RG in North Europe | Waiver | allowed-loc | 2027-03-31 |

