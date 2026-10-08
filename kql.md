1. Application Insights: AMPLS and public access status
``` kql
vunion withsource=T App*
| where TimeGenerated > ago(30d) and _IsBillable
| summarize GB = round(sum(_BilledSize)/1024/1024/1024, 2) by bin(TimeGenerated, 1d), _ResourceId
| render columnchart

resources
| where type =~ 'microsoft.insights/components'
| extend ingestPublic  = tostring(properties.publicNetworkAccessForIngestion),
         queryPublic   = tostring(properties.publicNetworkAccessForQuery),
         workspaceId   = tolower(tostring(properties.WorkspaceResourceId)),
         ingestionMode = tostring(properties.IngestionMode),
         amplsCount    = coalesce(array_length(properties.PrivateLinkScopedResources), 0)
| join kind=leftouter (
    resources
    | where type =~ 'microsoft.operationalinsights/workspaces'
    | project workspaceId    = tolower(id),
              wsAmplsCount   = coalesce(array_length(properties.privateLinkScopedResources), 0),
              wsIngestPublic = tostring(properties.publicNetworkAccessForIngestion)
) on workspaceId
| extend status = case(
    ingestionMode =~ 'ApplicationInsights' or isempty(workspaceId), '1-CLASSIC: migrate to workspace-based',
    amplsCount == 0,                                                '2-NOT IN AMPLS: breaks/leaks when zones go live',
    coalesce(wsAmplsCount, 0) == 0,                                 '3-AI in AMPLS, workspace NOT',
    ingestPublic =~ 'Enabled',                                      '4-In AMPLS, public ingestion still open',
    '5-OK')
| project status, subscriptionId, resourceGroup, name, location,
          ingestPublic, queryPublic, amplsCount, workspaceId, wsAmplsCount, wsIngestPublic
| order by status asc, subscriptionId asc
```

2. AMPLS inventory
``` kql
resources
| where type =~ 'microsoft.insights/privatelinkscopes'
| project subscriptionId, resourceGroup, name,
          ingestionMode = tostring(properties.accessModeSettings.ingestionAccessMode),
          queryMode     = tostring(properties.accessModeSettings.queryAccessMode),
          peCount       = array_length(properties.privateEndpointConnections)
```
3. Storage accounts with no blob private endpoint

These are at risk from the privatelink.blob zone.

``` kql
resources
| where type =~ 'microsoft.storage/storageaccounts'
| project saId = tolower(id), name, resourceGroup, subscriptionId,
          publicAccess  = tostring(properties.publicNetworkAccess),
          defaultAction = tostring(properties.networkAcls.defaultAction)
| join kind=leftouter (
    resources
    | where type =~ 'microsoft.network/privateendpoints'
    | mv-expand c = array_concat(
          coalesce(properties.privateLinkServiceConnections, dynamic([])),
          coalesce(properties.manualPrivateLinkServiceConnections, dynamic([])))
    | where tostring(c.properties.groupIds) has 'blob'
    | summarize blobPEs = count() by saId = tolower(tostring(c.properties.privateLinkServiceId))
) on saId
| where coalesce(blobPEs, 0) == 0
| project subscriptionId, resourceGroup, name, publicAccess, defaultAction
```

``` powershell
#Requires -Version 7.2
<#
.SYNOPSIS
  Finds hostnames that on-prem clients resolve which will break (NXDOMAIN) or be mis-routed once the
  AMPLS + blob privatelink zones are served on-prem.

.DESCRIPTION
  Pipeline:
    1. Ingest DNS evidence: Umbrella CSV export, Windows DNS debug log, and/or a plain FQDN list.
    2. Keep only names under the public parents of the five zones.
    3. Public DNS   -> does the name CNAME into *.privatelink.*?  (= the zone will capture it)
    4. Private DNS  -> (optional) what does the on-prem/private path answer? PRIVATE ip / NXDOMAIN / PUBLIC ip
    5. Inventory    -> Resource Graph + AMPLS scoped resources: which in-tenant resource is it, and is it linked / has a PE?

  Verdicts (worst first):
    BREAK             affected by zone, private path returns NXDOMAIN -> clients lose resolution at cutover
    GAP-External      affected, not found in tenant (other tenant / vendor / no read access) -> will break
    GAP-InTenant      affected, in tenant, but not in AMPLS / no blob PE -> add it or it breaks
    PRIVATE-UNLINKED  resolves private, but at least one resource behind it is not in AMPLS (fails if AMPLS is PrivateOnly)
    NOT-YET-PRIVATE   private path still answers with a public IP (zone not live on that resolver yet)
    Covered           affected, resolves to private IP, resource linked
    NoImpact          public CNAME chain doesn't go through privatelink -> zone never sees it
    Review            not enough data (no DNS test or no inventory)

.EXAMPLE
  # Pre-cutover what-if: test against the Azure DNS Private Resolver inbound IP (vnet linked to the zones)
  ./Find-PrivateLinkDnsGap.ps1 -UmbrellaCsv .\umbrella-30d.csv -PrivateResolver 10.20.0.4

.EXAMPLE
  ./Find-PrivateLinkDnsGap.ps1 -DnsDebugLog \\dc01\c$\dnslogs\dns.log,\\dc02\c$\dnslogs\dns.log -PrivateResolver 10.1.1.10
#>
[CmdletBinding()]
param(
    [string[]]$UmbrellaCsv,
    [string[]]$DnsDebugLog,
    [string[]]$FqdnList,

    [string]  $DomainColumn  = 'Domain',
    [string[]]$ClientColumns = @('Internal IP', 'Most Granular Identity', 'Identities'),

    [string]$PublicResolver = '1.1.1.1',
    [string]$PrivateResolver,              # Private Resolver inbound IP, or AD DNS once zones exist there

    [switch]$SkipInventory,
    [int]   $ThrottleLimit = 32,
    [string]$OutputPath = ".\privatelink-gap-$(Get-Date -Format yyyyMMdd-HHmm).csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ($UmbrellaCsv -or $DnsDebugLog -or $FqdnList)) { throw 'Provide at least one of -UmbrellaCsv, -DnsDebugLog, -FqdnList.' }

# Public parents of: privatelink.monitor.azure.com, privatelink.oms/ods.opinsights.azure.com,
# privatelink.agentsvc.azure-automation.net, privatelink.blob.core.windows.net.
# applicationinsights.azure.com / services.visualstudio.com are included because AI ingestion/live
# endpoints CNAME into the monitor zone; the public-DNS test decides what is actually affected.
$ScopeRx = [regex]'(?:^|\.)(?:monitor\.azure\.com|applicationinsights\.azure\.com|(?:ods|oms)\.opinsights\.azure\.com|agentsvc\.azure-automation\.net|blob\.core\.windows\.net|services\.visualstudio\.com)$'

#region 1. Evidence ingestion ---------------------------------------------------------------------------
$hits = @{}
function Add-Hit([string]$Name, [string]$Client) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    # normalise; clients sometimes query the privatelink CNAME target directly
    $f = ($Name.Trim().TrimEnd('.').ToLowerInvariant()) -replace '\.privatelink\.', '.'
    if (-not $ScopeRx.IsMatch($f)) { return }
    $h = $hits[$f]
    if (-not $h) {
        $h = [pscustomobject]@{ Count = 0L; Clients = [System.Collections.Generic.HashSet[string]]::new() }
        $hits[$f] = $h
    }
    $h.Count++
    if ($Client -and $h.Clients.Count -lt 50) { [void]$h.Clients.Add($Client) }
}
function Get-Col($Row, [string]$Name) { $p = $Row.PSObject.Properties[$Name]; if ($p) { $p.Value } }

foreach ($file in $UmbrellaCsv) {
    Write-Verbose "Umbrella: $file"
    Import-Csv -LiteralPath $file | ForEach-Object {
        $row = $_
        $client = foreach ($c in $ClientColumns) { $v = Get-Col $row $c; if ($v) { $v; break } }
        Add-Hit (Get-Col $row $DomainColumn) $client
    }
}

# Windows DNS debug log, inbound queries only ("Rcv ... Q [" - excludes "R Q" responses and Snd)
$DebugRx = [regex]'\s(?:UDP|TCP)\s+Rcv\s+(?<ip>\S+)\s+\S+\s+Q\s+\[.*?\]\s+\S+\s+(?<q>(?:\(\d+\)[^(]+)+)\(0\)'
foreach ($file in $DnsDebugLog) {
    Write-Verbose "Debug log: $file"
    foreach ($line in [System.IO.File]::ReadLines((Resolve-Path -LiteralPath $file).ProviderPath)) {
        $m = $DebugRx.Match($line)
        if ($m.Success) { Add-Hit (($m.Groups['q'].Value -replace '\(\d+\)', '.').Trim('.')) $m.Groups['ip'].Value }
    }
}

foreach ($file in $FqdnList) { Get-Content -LiteralPath $file | ForEach-Object { Add-Hit $_ $null } }

Write-Host "Unique in-scope FQDNs: $($hits.Count)"
if ($hits.Count -eq 0) { Write-Warning 'Nothing in scope - check -DomainColumn / log format.'; return }
#endregion

#region 2. Inventory (Resource Graph + AMPLS) -------------------------------------------------------------
$linked    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$wsByGuid  = @{}; $saByName = @{}; $aiByHost = @{}; $dceByHost = @{}
$amplsMode = 'unknown'

function Invoke-Arg([string]$Query) {
    $rows = [System.Collections.Generic.List[object]]::new(); $token = $null
    do {
        $p = @{ Query = $Query; First = 1000; UseTenantScope = $true }
        if ($token) { $p.SkipToken = $token }
        $r = Search-AzGraph @p
        $data  = if ($r.PSObject.Properties['Data']) { $r.Data } else { $r }
        foreach ($x in $data) { $rows.Add($x) }
        $token = if ($r.PSObject.Properties['SkipToken']) { $r.SkipToken } else { $null }
    } while ($token)
    $rows
}

if (-not $SkipInventory) {
    Import-Module Az.Accounts, Az.ResourceGraph
    $ctx = Get-AzContext
    if (-not $ctx) { throw 'Run Connect-AzAccount first (or use -SkipInventory).' }

    # AMPLS + scoped resources (authoritative linkage, covers DCEs too)
    $ampls = Invoke-Arg @'
resources | where type =~ 'microsoft.insights/privatelinkscopes'
| project id, name, resourceGroup, subscriptionId,
          ingest = tostring(properties.accessModeSettings.ingestionAccessMode)
'@
    $amplsMode = if ($ampls.Count) { ($ampls | ForEach-Object { "$($_.name)=$($_.ingest)" }) -join '; ' } else { 'NO AMPLS FOUND' }
    if ($ampls.Count -gt 1) { Write-Warning "$($ampls.Count) AMPLS found - only one should serve a shared DNS. $amplsMode" }

    if (Get-Command Get-AzInsightsPrivateLinkScopedResource -ErrorAction SilentlyContinue) {
        foreach ($a in $ampls) {
            $null = Set-AzContext -Subscription $a.subscriptionId -WarningAction SilentlyContinue
            Get-AzInsightsPrivateLinkScopedResource -ResourceGroupName $a.resourceGroup -ScopeName $a.name |
                ForEach-Object { [void]$linked.Add($_.LinkedResourceId) }
        }
        $null = Set-AzContext -Context $ctx
    } else {
        Write-Warning 'Az.Monitor not loaded - AMPLS linkage falls back to resource properties (DCE linkage unknown).'
    }

    # Log Analytics workspaces: ods / oms / agentsvc names are keyed by workspace customerId
    foreach ($w in Invoke-Arg @'
resources | where type =~ 'microsoft.operationalinsights/workspaces'
| project id, name, subscriptionId, customerId = tolower(tostring(properties.customerId)),
          scoped = array_length(properties.privateLinkScopedResources),
          ingestPublic = tostring(properties.publicNetworkAccessForIngestion)
'@) {
        if ($w.scoped -gt 0) { [void]$linked.Add($w.id) }
        $wsByGuid[$w.customerId] = $w
    }

    # Storage accounts + blob PE count
    foreach ($s in Invoke-Arg @'
resources | where type =~ 'microsoft.storage/storageaccounts'
| project id = tolower(id), name = tolower(name), subscriptionId, publicAccess = tostring(properties.publicNetworkAccess)
| join kind=leftouter (
    resources | where type =~ 'microsoft.network/privateendpoints'
    | mv-expand c = array_concat(coalesce(properties.privateLinkServiceConnections, dynamic([])),
                                 coalesce(properties.manualPrivateLinkServiceConnections, dynamic([])))
    | where tostring(c.properties.groupIds) has 'blob'
    | summarize blobPEs = count() by id = tolower(tostring(c.properties.privateLinkServiceId))
) on id
| project id, name, subscriptionId, publicAccess, blobPEs = coalesce(blobPEs, 0)
'@) { $saByName[$s.name] = $s }

    # App Insights: index by ingestion/live host from the connection string (shared regional hosts)
    foreach ($ai in Invoke-Arg @'
resources | where type =~ 'microsoft.insights/components'
| project id, name, subscriptionId, conn = tostring(properties.ConnectionString),
          scoped = array_length(properties.PrivateLinkScopedResources)
'@) {
        if ($ai.scoped -gt 0) { [void]$linked.Add($ai.id) }
        $cs = @{}
        foreach ($kv in ($ai.conn -split ';')) { $k, $v = $kv -split '=', 2; if ($v) { $cs[$k] = $v } }
        foreach ($ep in 'IngestionEndpoint', 'LiveEndpoint') {
            if ($cs[$ep]) {
                $h = ([uri]$cs[$ep]).Host.ToLowerInvariant()
                if (-not $aiByHost[$h]) { $aiByHost[$h] = [System.Collections.Generic.List[object]]::new() }
                $aiByHost[$h].Add($ai)
            }
        }
    }

    # Data collection endpoints (AMA / Logs Ingestion API)
    foreach ($d in Invoke-Arg @'
resources | where type =~ 'microsoft.insights/datacollectionendpoints'
| project id, name, subscriptionId,
          e1 = tostring(properties.configurationAccess.endpoint),
          e2 = tostring(properties.logsIngestion.endpoint),
          e3 = tostring(properties.metricsIngestion.endpoint)
'@) {
        foreach ($e in $d.e1, $d.e2, $d.e3) { if ($e) { $dceByHost[([uri]$e).Host.ToLowerInvariant()] = $d } }
    }

    Write-Host "Inventory: $($wsByGuid.Count) workspaces, $($saByName.Count) storage, $($aiByHost.Count) AI hosts, $($dceByHost.Count) DCE hosts, $($linked.Count) AMPLS-linked"
}
#endregion

#region 3. DNS tests -----------------------------------------------------------------------------------------
$dns = @{}
if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
    $results = [string[]]$hits.Keys | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
        $f = $_; $pub = $using:PublicResolver; $priv = $using:PrivateResolver
        $o = [ordered]@{ Fqdn = $f; Affected = $null; PublicChain = $null; Private = $null }
        try {
            $r = Resolve-DnsName -Name $f -Server $pub -DnsOnly -QuickTimeout -ErrorAction Stop
            $chain = @($r | Where-Object Type -eq 'CNAME' | ForEach-Object NameHost)
            $o.PublicChain = $chain -join ' > '
            $o.Affected    = [bool]($chain -match '\.privatelink\.')
        } catch {
            if ($_.FullyQualifiedErrorId -like 'DNS_ERROR_RCODE_NAME_ERROR*') { $o.PublicChain = 'NXDOMAIN (stale/decommissioned)'; $o.Affected = $false }
            else { $o.PublicChain = "ERR: $($_.Exception.Message)" }
        }
        if ($priv) {
            try {
                $r   = Resolve-DnsName -Name $f -Server $priv -DnsOnly -QuickTimeout -ErrorAction Stop
                $ips = @($r | Where-Object Type -eq 'A' | ForEach-Object IP4Address)
                $o.Private = if (-not $ips) { 'NOANSWER' }
                             elseif ($ips -match '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)') { "PRIVATE $($ips -join ',')" }
                             else { "PUBLIC $($ips -join ',')" }
            } catch {
                $o.Private = if ($_.FullyQualifiedErrorId -like 'DNS_ERROR_RCODE_NAME_ERROR*') { 'NXDOMAIN' } else { "ERR: $($_.Exception.Message)" }
            }
        }
        [pscustomobject]$o
    }
    foreach ($r in $results) { $dns[$r.Fqdn] = $r }
} else {
    Write-Warning 'Resolve-DnsName not available (Windows only) - skipping DNS tests; verdicts will rely on inventory.'
}
#endregion

#region 4. Attribution + verdict -----------------------------------------------------------------------------
function Get-Attribution([string]$f) {
    $a = [ordered]@{ Kind = 'MonitorShared'; Resource = ''; Subscription = ''; Gap = $false; External = $false; Note = '' }
    if ($SkipInventory) {
        $a.Kind = switch -Regex ($f) {
            '^[0-9a-f-]{36}\.(?:(?:ods|oms)\.opinsights\.azure\.com|agentsvc\.azure-automation\.net)$' { 'Workspace'; break }
            '\.blob\.core\.windows\.net$'                                                            { 'Storage'; break }
            '\.in\.applicationinsights\.azure\.com$|\.livediagnostics\.monitor\.azure\.com$'           { 'AppInsightsEndpoint'; break }
            '\.(?:handler\.control|ingest|metrics\.ingest)\.monitor\.azure\.com$'                     { 'DCE'; break }
            default                                                                                  { 'MonitorShared' }
        }
        $a.Note = 'inventory skipped'
        return [pscustomobject]$a
    }

    switch -Regex ($f) {
        '^(?<g>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(?:(?:ods|oms)\.opinsights\.azure\.com|agentsvc\.azure-automation\.net)$' {
            $a.Kind = 'Workspace'
            $w = $wsByGuid[$Matches.g]
            if ($w) {
                $a.Resource = $w.name; $a.Subscription = $w.subscriptionId
                $a.Gap  = -not $linked.Contains($w.id)
                $a.Note = "ingestPublic=$($w.ingestPublic)"
            } else { $a.Resource = $Matches.g; $a.Gap = $true; $a.External = $true; $a.Note = 'workspace not in tenant / no read access' }
            break
        }
        '^(?<n>[a-z0-9]{3,24})\.blob\.core\.windows\.net$' {
            $a.Kind = 'Storage'
            if ($Matches.n -eq 'scadvisorcontentpl') { $a.Resource = $Matches.n; $a.Note = 'AMPLS-managed record'; break }
            $s = $saByName[$Matches.n]
            if ($s) {
                $a.Resource = $s.name; $a.Subscription = $s.subscriptionId
                $a.Gap  = $s.blobPEs -eq 0
                $a.Note = "blobPEs=$($s.blobPEs) publicAccess=$($s.publicAccess)"
            } else { $a.Resource = $Matches.n; $a.Gap = $true; $a.External = $true; $a.Note = 'storage not in tenant (vendor/MS-owned/other tenant)' }
            break
        }
        default {
            if ($aiByHost.ContainsKey($f)) {
                $all = $aiByHost[$f]
                $un  = @($all | Where-Object { -not $linked.Contains($_.id) })
                $a.Kind = 'AppInsightsEndpoint'
                $a.Resource = "$($all.Count) AI resources"
                $a.Gap  = $un.Count -gt 0
                $a.Note = "shared host; not in AMPLS ($($un.Count)): $((($un | Select-Object -First 15).name) -join ',')$(if ($un.Count -gt 15) { ',...' }); AMPLS ingestion: $amplsMode"
            } elseif ($dceByHost.ContainsKey($f)) {
                $d = $dceByHost[$f]
                $a.Kind = 'DCE'; $a.Resource = $d.name; $a.Subscription = $d.subscriptionId
                $a.Gap  = -not $linked.Contains($d.id)
            } else {
                $a.Note = 'global/shared endpoint - not attributable to one resource'
            }
        }
    }
    [pscustomobject]$a
}

$rank = @{ 'BREAK' = 0; 'GAP-External' = 1; 'GAP-InTenant' = 2; 'PRIVATE-UNLINKED' = 3; 'NOT-YET-PRIVATE' = 4; 'Review' = 5; 'Covered' = 6; 'NoImpact' = 7 }

$report = foreach ($f in $hits.Keys) {
    $h   = $hits[$f]
    $d   = $dns[$f]
    $att = Get-Attribution $f

    $verdict = switch ($true) {
        { $d -and $d.Affected -eq $false }                    { 'NoImpact'; break }
        { $d -and $d.Private -in 'NXDOMAIN', 'NOANSWER' }     { 'BREAK'; break }
        { $d -and "$($d.Private)" -like 'PUBLIC*' }           { 'NOT-YET-PRIVATE'; break }
        { $d -and "$($d.Private)" -like 'PRIVATE*' -and $att.Gap } { 'PRIVATE-UNLINKED'; break }
        { $d -and "$($d.Private)" -like 'PRIVATE*' }          { 'Covered'; break }
        { $att.Gap -and $att.External }                       { 'GAP-External'; break }
        { $att.Gap }                                          { 'GAP-InTenant'; break }
        default                                               { 'Review' }
    }

    [pscustomobject]@{
        Verdict       = $verdict
        Fqdn          = $f
        Kind          = $att.Kind
        Resource      = $att.Resource
        Subscription  = $att.Subscription
        Note          = $att.Note
        Queries       = $h.Count
        ClientCount   = $h.Clients.Count
        Clients       = (@($h.Clients) | Select-Object -First 10) -join ';'
        PublicChain   = if ($d) { $d.PublicChain } else { '' }
        PrivateAnswer = if ($d) { $d.Private } else { '' }
    }
}

$report = $report | Sort-Object { $rank[$_.Verdict] }, { -$_.Queries }
$report | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8

$report | Group-Object Verdict | Sort-Object { $rank[$_.Name] } |
    Format-Table @{ n = 'Verdict'; e = { $_.Name } }, Count, @{ n = 'Queries'; e = { [long]($_.Group | Measure-Object Queries -Sum).Sum } } -AutoSize |
    Out-String -Width 200 | Write-Host
Write-Host "Report: $((Resolve-Path $OutputPath).ProviderPath)"
#endregion

```
