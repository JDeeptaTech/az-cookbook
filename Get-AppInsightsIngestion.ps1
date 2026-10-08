#Requires -Version 7.2
<#
.SYNOPSIS
  Billable ingestion per Application Insights resource per day (workspace-based + classic) for cost showback.

.DESCRIPTION
  1. Inventory every microsoft.insights/components via Resource Graph (tenant scope or -SubscriptionId).
  2. Workspace-based: one query per Log Analytics workspace (chunked by -ChunkDays):
       union App* | where _IsBillable | sum(_BilledSize) by day, _ResourceId, table
     -> splits the *workspace* bill by AI resource (Cost Management cannot do this; it only sees the workspace meter).
  3. Classic: per component via the ARM query proxy, using systemEvents 'Billing' records (Microsoft's documented
     classic billing query).
  4. Writes three CSVs and prints a console summary.

  Outputs (prefix = -OutputPrefix):
    <prefix>-summary.csv    one row per AI resource: status, total/avg/last-7d GB, trend, top table, est. cost, owner, config
    <prefix>-daily.csv      one row per AI resource / day / table (for pivoting / Power BI)
    <prefix>-inventory.csv  normalised inventory + query state (lets -ReuseFrom re-price/re-summarise without re-querying)

  Permissions: Reader (Resource Graph) + Log Analytics Reader on each workspace + Reader on classic components.
  Workspaces/components you can't query are reported as NoAccess/QueryFailed, never silently as zero.

.EXAMPLE
  Connect-AzAccount
  ./Get-AppInsightsIngestion.ps1 -Days 30 -PricePerGB 2.30 -Currency GBP

.EXAMPLE
  # Re-price an earlier run with your commitment-tier effective rate, no Azure calls
  ./Get-AppInsightsIngestion.ps1 -ReuseFrom .\appinsights-ingestion-20261008 -PricePerGB 1.85
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)][int]$Days = 30,
    [ValidateRange(1, 30)][int]$ChunkDays = 7,       # lower this if big workspaces time out
    [double]$PricePerGB,                             # your *effective* Analytics Logs price/GB (after commitment tier)
    [string]$Currency = 'GBP',
    [string[]]$OwnerTags = @('owner', 'team', 'costcenter', 'cost-center', 'application', 'app'),
    [string[]]$SubscriptionId,
    [string]$OutputPrefix = ".\appinsights-ingestion-$(Get-Date -Format yyyyMMdd)",
    [int]$QueryTimeoutSec = 600,
    [string]$ReuseFrom                               # prefix of an earlier run; skips all Azure calls
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$fmt = "yyyy-MM-dd'T'HH:mm:ss'Z'"

# ---------------------------------------------------------------------------------------------------------
function Invoke-Arg([string]$Query) {
    $rows = [System.Collections.Generic.List[object]]::new(); $token = $null
    do {
        $p = @{ Query = $Query; First = 1000 }
        if ($SubscriptionId) { $p.Subscription = $SubscriptionId } else { $p.UseTenantScope = $true }
        if ($token) { $p.SkipToken = $token }
        $r = Search-AzGraph @p
        $data = if ($r.PSObject.Properties['Data']) { $r.Data } else { $r }
        foreach ($x in $data) { $rows.Add($x) }
        $token = if ($r.PSObject.Properties['SkipToken']) { $r.SkipToken } else { $null }
    } while ($token)
    $rows
}

function Get-Owner($Tags) {
    if (-not $Tags) { return '' }
    foreach ($t in $OwnerTags) {
        $p = $Tags.PSObject.Properties[$t]          # PSObject member lookup is case-insensitive
        if ($p -and $p.Value) { return [string]$p.Value }
    }
    ''
}

function Short([string]$s, [int]$n = 200) { if ($s.Length -gt $n) { $s.Substring(0, $n) + '...' } else { $s } }

function SumOf($Items, [string]$Prop) { $t = 0.0; foreach ($x in $Items) { $t += [double]$x.$Prop }; $t }

# ---------------------------------------------------------------------------------------------------------
if ($ReuseFrom) {
    $inventory = @(Import-Csv "$ReuseFrom-inventory.csv")
    $daily     = [System.Collections.Generic.List[object]]::new()
    foreach ($d in Import-Csv "$ReuseFrom-daily.csv") {
        $daily.Add([pscustomobject]@{ Day = $d.Day; ResourceId = $d.ResourceId; Table = $d.Table
                                      Bytes = [double]$d.Bytes; Items = $d.Items; Workspace = $d.Workspace })
    }
    if (-not $inventory) { throw "Empty inventory in $ReuseFrom-inventory.csv" }
    $start = [datetime]::Parse($inventory[0].PeriodStart, [cultureinfo]::InvariantCulture, 'AdjustToUniversal')
    $end   = [datetime]::Parse($inventory[0].PeriodEnd,   [cultureinfo]::InvariantCulture, 'AdjustToUniversal')
    $Days  = [int]($end - $start).TotalDays
    if ($OutputPrefix -like '*appinsights-ingestion-*' -and -not $PSBoundParameters.ContainsKey('OutputPrefix')) {
        $OutputPrefix = "$ReuseFrom-repriced"
    }
}
else {
    Import-Module Az.Accounts, Az.ResourceGraph, Az.OperationalInsights
    if (-not (Get-AzContext)) { throw 'Run Connect-AzAccount first.' }

    # Full UTC days only, so averages are honest (today's partial day excluded)
    $end   = [datetime]::UtcNow.Date
    $start = $end.AddDays(-$Days)
    $windows = for ($s = $start; $s -lt $end; $s = $s.AddDays($ChunkDays)) {
        $e = $s.AddDays($ChunkDays); if ($e -gt $end) { $e = $end }
        [pscustomobject]@{ S = $s; E = $e }
    }

    #region inventory
    $raw = Invoke-Arg @'
resources
| where type =~ 'microsoft.insights/components'
| extend wsId = tolower(tostring(properties.WorkspaceResourceId)), mode = tostring(properties.IngestionMode)
| project id = tolower(id), name, resourceGroup, subscriptionId, location, tags, wsId,
          kind      = iff(mode =~ 'LogAnalytics' and isnotempty(wsId), 'WorkspaceBased', 'Classic'),
          sampling  = todouble(properties.SamplingPercentage),
          retention = toint(properties.RetentionInDays)
| join kind=leftouter (
    resources | where type =~ 'microsoft.operationalinsights/workspaces'
    | project wsId = tolower(id), wsName = name, wsCustomerId = tostring(properties.customerId),
              wsSku = tostring(properties.sku.name), wsCapGB = todouble(properties.workspaceCapping.dailyQuotaGb)
) on wsId
| project-away wsId1
'@
    $inventory = foreach ($c in $raw) {
        [pscustomobject]@{
            id = $c.id; name = $c.name; resourceGroup = $c.resourceGroup; subscriptionId = $c.subscriptionId
            location = $c.location; kind = $c.kind; Owner = Get-Owner $c.tags
            wsId = $c.wsId; wsName = $c.wsName; wsCustomerId = $c.wsCustomerId; wsSku = $c.wsSku; wsCapGB = $c.wsCapGB
            sampling = $c.sampling; retention = $c.retention
            QueryState = 'Pending'; PeriodStart = $start.ToString($fmt); PeriodEnd = $end.ToString($fmt)
        }
    }
    $inventory = @($inventory)
    $wb      = @($inventory | Where-Object kind -eq 'WorkspaceBased')
    $classic = @($inventory | Where-Object kind -eq 'Classic')
    $wsGroups = @($wb | Group-Object wsId)
    Write-Host ("Inventory: {0} App Insights ({1} workspace-based in {2} workspaces, {3} classic). Window {4:yyyy-MM-dd} .. {5:yyyy-MM-dd} UTC" -f `
        $inventory.Count, $wb.Count, $wsGroups.Count, $classic.Count, $start, $end.AddDays(-1))
    #endregion

    $daily = [System.Collections.Generic.List[object]]::new()

    #region workspace-based
    $wsQuery = @'
union withsource = SourceTable App*
| where TimeGenerated >= datetime(__S__) and TimeGenerated < datetime(__E__)
| where _IsBillable == true
| summarize Bytes = sum(_BilledSize), Items = count()
    by Day = startofday(TimeGenerated), ResourceId = tolower(_ResourceId), Table = SourceTable
'@
    $span = New-TimeSpan -Days ($Days + 2)
    $i = 0
    foreach ($g in $wsGroups) {
        $i++; $ws = $g.Group[0]
        Write-Progress -Activity 'Workspace-based App Insights' -Status "$($ws.wsName) ($i/$($wsGroups.Count))" -PercentComplete (100 * $i / $wsGroups.Count)
        $state = 'OK'
        if (-not $ws.wsCustomerId) { $state = "NoAccess: workspace not visible in Resource Graph ($($g.Name))" }
        else {
            try {
                foreach ($w in $windows) {
                    $q = $wsQuery.Replace('__S__', $w.S.ToString($fmt)).Replace('__E__', $w.E.ToString($fmt))
                    $r = Invoke-AzOperationalInsightsQuery -WorkspaceId $ws.wsCustomerId -Query $q -Timespan $span -Wait $QueryTimeoutSec
                    if ($r.PSObject.Properties['Error'] -and $r.Error) { throw "Partial/failed: $($r.Error.Message)" }
                    foreach ($row in $r.Results) {
                        $daily.Add([pscustomobject]@{
                            Day = ([datetimeoffset]$row.Day).UtcDateTime.ToString('yyyy-MM-dd')
                            ResourceId = $row.ResourceId; Table = $row.Table
                            Bytes = [double]$row.Bytes; Items = [long]$row.Items; Workspace = $ws.wsName })
                    }
                }
            } catch { $state = "QueryFailed: $(Short $_.Exception.Message)" }
        }
        foreach ($c in $g.Group) { $c.QueryState = $state }
        if ($state -ne 'OK') { Write-Warning "$($ws.wsName): $state" }
    }
    #endregion

    #region classic
    $classicQuery = @'
systemEvents
| where type == 'Billing'
| extend Table = tostring(dimensions['BillingTelemetryType']), Bytes = todouble(measurements['BillingTelemetrySize'])
| summarize Bytes = sum(Bytes) by Day = startofday(timestamp), Table
'@
    $i = 0
    foreach ($c in $classic) {
        $i++
        Write-Progress -Activity 'Classic App Insights' -Status "$($c.name) ($i/$($classic.Count))" -PercentComplete (100 * $i / [math]::Max(1, $classic.Count))
        $state = 'OK'
        try {
            foreach ($w in $windows) {
                $body = @{ query = $classicQuery; timespan = "$($w.S.ToString($fmt))/$($w.E.ToString($fmt))" } | ConvertTo-Json -Compress
                $resp = Invoke-AzRestMethod -Method POST -Path "$($c.id)/api/query?api-version=2018-04-20" -Payload $body
                if ($resp.StatusCode -ne 200) { throw "HTTP $($resp.StatusCode): $(Short $resp.Content)" }
                $t = @(($resp.Content | ConvertFrom-Json).tables)[0]
                $cols = @($t.columns | ForEach-Object name)
                foreach ($row in $t.rows) {
                    $o = @{}; for ($k = 0; $k -lt $cols.Count; $k++) { $o[$cols[$k]] = $row[$k] }
                    $daily.Add([pscustomobject]@{
                        Day = ([datetimeoffset]$o.Day).UtcDateTime.ToString('yyyy-MM-dd')
                        ResourceId = $c.id; Table = $o.Table; Bytes = [double]$o.Bytes; Items = ''; Workspace = '(classic)' })
                }
            }
        } catch { $state = "QueryFailed: $(Short $_.Exception.Message)" }
        $c.QueryState = $state
        if ($state -ne 'OK') { Write-Warning "$($c.name): $state" }
    }
    Write-Progress -Activity 'Classic App Insights' -Completed
    #endregion
}

# ---------------------------------------------------------------------------------------------------------
#region summarise
$byId = @{}; foreach ($c in $inventory) { $byId[$c.id] = $c }
$byRes = @{}
foreach ($d in $daily) {
    if (-not $byRes.ContainsKey($d.ResourceId)) { $byRes[$d.ResourceId] = [System.Collections.Generic.List[object]]::new() }
    $byRes[$d.ResourceId].Add($d)
}
$ids = @($byId.Keys) + @($byRes.Keys | Where-Object { -not $byId.ContainsKey($_) })   # data from AI not in inventory (deleted / other tenant)

$last7From = $end.AddDays(-7).ToString('yyyy-MM-dd')
$prev7From = $end.AddDays(-14).ToString('yyyy-MM-dd')
$GB = [math]::Pow(1024, 3)
$hasPrice = $PSBoundParameters.ContainsKey('PricePerGB') -and $PricePerGB -gt 0

$summary = foreach ($id in $ids) {
    $c    = $byId[$id]
    $rows = if ($byRes.ContainsKey($id)) { @($byRes[$id]) } else { @() }

    $total  = SumOf $rows Bytes
    $perDay = @($rows | Group-Object Day | ForEach-Object { [pscustomobject]@{ Day = $_.Name; B = SumOf $_.Group Bytes } })
    $last7  = SumOf @($perDay | Where-Object { $_.Day -ge $last7From }) B
    $prev7  = SumOf @($perDay | Where-Object { $_.Day -ge $prev7From -and $_.Day -lt $last7From }) B
    $peak   = $perDay | Sort-Object B -Descending | Select-Object -First 1
    $top    = @($rows | Group-Object Table | ForEach-Object { [pscustomobject]@{ T = $_.Name; B = SumOf $_.Group Bytes } }) |
              Sort-Object B -Descending | Select-Object -First 1
    $lastDay = if ($perDay) { ($perDay | Sort-Object Day | Select-Object -Last 1).Day } else { '' }

    $state  = if ($c) { $c.QueryState } else { 'OK' }
    $status = if ($state -ne 'OK')        { ($state -split ':')[0] }
              elseif ($total -eq 0)       { 'NoIngestion' }
              elseif ($lastDay -lt $last7From) { 'Stale(>7d)' }
              else                         { 'Active' }

    $avgGB = $total / $GB / $Days
    [pscustomobject]@{
        Status           = $status
        Name             = if ($c) { $c.name } else { ($id -split '/')[-1] }
        Kind             = if ($c) { $c.kind } else { 'NotInInventory' }
        Owner            = if ($c) { $c.Owner } else { '' }
        Subscription     = if ($c) { $c.subscriptionId } else { ($id -split '/')[2] }
        ResourceGroup    = if ($c) { $c.resourceGroup } else { ($id -split '/')[4] }
        Location         = if ($c) { $c.location } else { '' }
        Workspace        = if ($c -and $c.kind -eq 'WorkspaceBased') { $c.wsName } elseif ($rows) { $rows[0].Workspace } else { '' }
        WorkspaceSku     = if ($c) { $c.wsSku } else { '' }
        TotalGB          = [math]::Round($total / $GB, 3)
        AvgGBPerDay      = [math]::Round($avgGB, 3)
        Last7dAvgGB      = [math]::Round($last7 / $GB / 7, 3)
        TrendPctVsPrev7d = if ($prev7 -gt 0) { [math]::Round(100 * ($last7 - $prev7) / $prev7, 0) } else { $null }
        PeakDay          = if ($peak) { $peak.Day } else { '' }
        PeakGB           = if ($peak) { [math]::Round($peak.B / $GB, 3) } else { 0 }
        TopTable         = if ($top) { $top.T } else { '' }
        TopTablePct      = if ($top -and $total -gt 0) { [math]::Round(100 * $top.B / $total, 0) } else { $null }
        LastIngestionDay = $lastDay
        "EstCostPeriod_$Currency"  = if ($hasPrice) { [math]::Round($total / $GB * $PricePerGB, 2) } else { $null }
        "EstMonthly_$Currency"     = if ($hasPrice) { [math]::Round($avgGB * 30.4 * $PricePerGB, 2) } else { $null }
        SamplingPct      = if ($c) { $c.sampling } else { $null }
        RetentionDays    = if ($c) { $c.retention } else { $null }
        QueryState       = $state
        ResourceId       = $id
    }
}
$summary = @($summary | Sort-Object TotalGB -Descending)

# daily export enriched with names
$dailyOut = foreach ($d in $daily) {
    $c = $byId[$d.ResourceId]
    [pscustomobject]@{
        Day = $d.Day; Name = if ($c) { $c.name } else { ($d.ResourceId -split '/')[-1] }
        Kind = if ($c) { $c.kind } else { 'NotInInventory' }; Owner = if ($c) { $c.Owner } else { '' }
        Table = $d.Table; GB = [math]::Round($d.Bytes / $GB, 4); Bytes = $d.Bytes; Items = $d.Items
        Workspace = $d.Workspace; ResourceId = $d.ResourceId
    }
}

$summary   | Export-Csv "$OutputPrefix-summary.csv" -NoTypeInformation -Encoding utf8
@($dailyOut) | Sort-Object Day, Name, Table | Export-Csv "$OutputPrefix-daily.csv" -NoTypeInformation -Encoding utf8
if (-not $ReuseFrom) { $inventory | Export-Csv "$OutputPrefix-inventory.csv" -NoTypeInformation -Encoding utf8 }
#endregion

#region console
$totGB = (SumOf $summary TotalGB)
Write-Host ''
Write-Host ("{0} of {1} App Insights ingested data in the last {2} days. Total {3:N1} GB ({4:N2} GB/day){5}" -f `
    @($summary | Where-Object TotalGB -gt 0).Count, $summary.Count, $Days, $totGB, ($totGB / $Days),
    $(if ($hasPrice) { " ~ {0:N0} {1}/month" -f ($totGB / $Days * 30.4 * $PricePerGB), $Currency } else { '' }))

$summary | Group-Object Status | Sort-Object Count -Descending |
    Format-Table @{ n = 'Status'; e = { $_.Name } }, Count,
                 @{ n = 'GB'; e = { [math]::Round((SumOf $_.Group TotalGB), 1) } } -AutoSize |
    Out-String -Width 200 | Write-Host

$cols = @('Name', 'Kind', 'Owner', 'AvgGBPerDay', 'Last7dAvgGB', 'TrendPctVsPrev7d', 'TopTable', 'TopTablePct')
if ($hasPrice) { $cols += "EstMonthly_$Currency" }
Write-Host 'Top 15 by volume:'
$summary | Select-Object -First 15 | Format-Table $cols -AutoSize | Out-String -Width 250 | Write-Host
Write-Host "Files: $OutputPrefix-summary.csv, -daily.csv$(if (-not $ReuseFrom) { ', -inventory.csv' })"
#endregion
