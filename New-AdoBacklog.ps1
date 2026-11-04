#requires -Version 7.2
<#
.SYNOPSIS
  Create the AMPLS / DNS migration backlog (Epic > Features > Stories > Tasks) in Azure DevOps from backlog.json.

.DESCRIPTION
  - Uses the ADO REST API (7.1). Auth: -Pat, $env:ADO_PAT, or the signed-in Azure CLI account (az login).
  - Idempotent: items are matched on work item type + exact title + the backlog tag. Re-running creates only what is
    missing, so you can fix a failure and run again.
  - Process aware: detects Agile / Scrum / CMMI / Basic from the project and maps types and fields
    (User Story / Product Backlog Item / Requirement / Issue; Story Points / Effort / Size).
  - Templates: one Feature per wave in backlog.json "waves"; one Story per entry in "workloadSubscriptions".
  - -WhatIf prints the tree without calling write APIs. -ValidateOnly asks ADO to validate every item
    (field names, area/iteration paths, required rules) without saving anything.

.PARAMETER OrganizationUrl  https://dev.azure.com/<org>
.PARAMETER Project          ADO project name
.PARAMETER AreaPath         Defaults to the project root. Example: 'Platform\Networking'
.PARAMETER IterationPath    Defaults to the project root. Example: 'Platform\2026 Q4\Sprint 22'
.PARAMETER Process          Override process detection (Agile, Scrum, CMMI, Basic)
.PARAMETER Pat              PAT with Work Items (Read & Write). Prefer $env:ADO_PAT over passing on the command line.

.EXAMPLE
  $env:ADO_PAT = '<pat>'
  ./New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Platform -AreaPath 'Platform\Networking' -WhatIf
  ./New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Platform -AreaPath 'Platform\Networking' -ValidateOnly
  ./New-AdoBacklog.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Platform -AreaPath 'Platform\Networking' -IterationPath 'Platform\Sprint 22'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$OrganizationUrl,
    [Parameter(Mandatory)][string]$Project,
    [string]$BacklogPath = (Join-Path $PSScriptRoot 'backlog.json'),
    [string]$AreaPath,
    [string]$IterationPath,
    [ValidateSet('Agile', 'Scrum', 'CMMI', 'Basic')][string]$Process,
    [string]$Pat = $env:ADO_PAT,
    [string]$AssignTo,
    [switch]$ValidateOnly,
    [string]$OutCsv = './ado-backlog-result.csv'
)
$ErrorActionPreference = 'Stop'
$OrganizationUrl = $OrganizationUrl.TrimEnd('/')
$api = 'api-version=7.1'
$projEnc = [uri]::EscapeDataString($Project)

# ---------------- auth ----------------
$headers = @{ Accept = 'application/json' }
if ($Pat) {
    $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
} elseif (-not $WhatIfPreference) {
    # 499b84ac-... is the Azure DevOps resource ID
    $tok = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>$null
    if (-not $tok) { throw 'No PAT ($env:ADO_PAT / -Pat) and no Azure CLI token. Run az login or set ADO_PAT.' }
    $headers.Authorization = "Bearer $tok"
}

function Invoke-Ado {
    param([string]$Method, [string]$Uri, $Body, [string]$ContentType = 'application/json')
    $json = if ($null -ne $Body) { ConvertTo-Json -InputObject $Body -Depth 20 -Compress } else { $null }
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $r = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType $ContentType -SkipHttpErrorCheck
        $code = [int]$r.StatusCode
        if ($code -lt 300) { return ($r.Content | ConvertFrom-Json -Depth 50) }
        if ($code -in 429, 500, 502, 503, 504) {
            $wait = [int]($r.Headers['Retry-After'] | Select-Object -First 1); if (-not $wait) { $wait = [math]::Pow(2, $attempt) }
            Write-Verbose "HTTP $code, retrying in ${wait}s"; Start-Sleep -Seconds $wait; continue
        }
        if ($code -in 401, 203) { throw 'Authentication failed (PAT expired / wrong org, or token lacks vso.work_write).' }
        $msg = try { ($r.Content | ConvertFrom-Json).message } catch { $r.Content }
        throw "ADO $Method $Uri -> HTTP ${code}: $msg"
    }
    throw "ADO $Method $Uri failed after retries"
}

# ---------------- process mapping ----------------
if (-not $Process -and -not $WhatIfPreference) {
    $p = Invoke-Ado GET "$OrganizationUrl/_apis/projects/${projEnc}?includeCapabilities=true&$api"
    $Process = $p.capabilities.processTemplate.templateName
    if ($Process -notin 'Agile', 'Scrum', 'CMMI', 'Basic') {
        Write-Warning "Inherited process '$Process' - assuming Agile types. Pass -Process if it derives from Scrum/CMMI/Basic."
        $Process = 'Agile'
    }
}
if (-not $Process) { $Process = 'Agile' }
$map = @{
    Agile = @{ epic = 'Epic'; feature = 'Feature'; story = 'User Story';            task = 'Task'; size = 'Microsoft.VSTS.Scheduling.StoryPoints'; ac = $true;  orig = $true }
    Scrum = @{ epic = 'Epic'; feature = 'Feature'; story = 'Product Backlog Item';  task = 'Task'; size = 'Microsoft.VSTS.Scheduling.Effort';      ac = $true;  orig = $false }
    CMMI  = @{ epic = 'Epic'; feature = 'Feature'; story = 'Requirement';           task = 'Task'; size = 'Microsoft.VSTS.Scheduling.Size';        ac = $false; orig = $true }
    Basic = @{ epic = 'Epic'; feature = 'Issue';   story = 'Issue';                 task = 'Task'; size = $null;                                   ac = $false; orig = $false }
}[$Process]
Write-Host "Process: $Process  (story type: $($map.story))"

# ---------------- expand backlog.json into a flat, ordered list ----------------
$raw = Get-Content -Raw $BacklogPath
$bl = $raw | ConvertFrom-Json -Depth 50
$tag = $bl.tag

function Expand-Node($node, [hashtable]$tokens) {
    $j = $node | ConvertTo-Json -Depth 50
    foreach ($k in $tokens.Keys) { $j = $j.Replace("{{$k}}", ($tokens[$k] -replace '\\', '\\' -replace '"', '\"')) }
    $j | ConvertFrom-Json -Depth 50
}

$items = [System.Collections.Generic.List[object]]::new()
function Add-Item($kind, $node, $parentKey, $key) {
    $items.Add([pscustomobject]@{
        Key = $key; Kind = $kind; ParentKey = $parentKey; Title = $node.title
        Description = @($node.description | Where-Object { $_ }); Ac = @($node.ac | Where-Object { $_ }); Points = $node.points; Hours = $node.hours
        Type = $map[$kind]; Id = $null; Action = $null; Url = $null
    })
}
Add-Item 'epic' $bl.epic $null 'E'
$fi = 0
foreach ($f in $bl.features) {
    $instances = if ($f.template -eq 'wave') {
        foreach ($w in $bl.waves) { Expand-Node $f @{ 'wave.n' = "$($w.n)"; 'wave.name' = $w.name; 'wave.zones' = $w.zones; 'wave.forwarders' = $w.forwarders } }
    } else { , $f }
    foreach ($fx in $instances) {
        $fi++; $fk = "F$fi"
        Add-Item 'feature' $fx 'E' $fk
        $si = 0
        foreach ($s in $fx.stories) {
            $sInst = if ($s.forEachSubscription) {
                foreach ($sub in $bl.workloadSubscriptions) { Expand-Node $s @{ 'sub.name' = $sub.name; 'sub.id' = $sub.id } }
            } else { , $s }
            foreach ($sx in $sInst) {
                $si++; $sk = "$fk.S$si"
                Add-Item 'story' $sx $fk $sk
                $ti = 0
                foreach ($t in $sx.tasks) { $ti++; Add-Item 'task' $t $sk "$sk.T$ti" }
            }
        }
    }
}
$dupes = $items | Group-Object Type, Title | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate type+title in backlog (idempotency needs unique titles): $($dupes.Name -join '; ')" }
$byKey = @{}; $items | ForEach-Object { $byKey[$_.Key] = $_ }
Write-Host ("Backlog: {0} epic, {1} features, {2} stories, {3} tasks" -f
    @($items | ? Kind -eq epic).Count, @($items | ? Kind -eq feature).Count, @($items | ? Kind -eq story).Count, @($items | ? Kind -eq task).Count)

# ---------------- find what already exists (one WIQL + batch read) ----------------
$existing = @{}
if (-not $WhatIfPreference) {
    $wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS '$tag' AND [System.State] <> 'Removed'" }
    $ids = @((Invoke-Ado POST "$OrganizationUrl/$projEnc/_apis/wit/wiql?$api" $wiql).workItems | Where-Object { $_ } | ForEach-Object { $_.id })
    for ($i = 0; $i -lt $ids.Count; $i += 200) {
        $chunk = $ids[$i..([math]::Min($i + 199, $ids.Count - 1))]
        $res = Invoke-Ado POST "$OrganizationUrl/_apis/wit/workitemsbatch?$api" @{ ids = $chunk; fields = @('System.Id', 'System.Title', 'System.WorkItemType') }
        foreach ($w in $res.value) { $existing["$($w.fields.'System.WorkItemType')|$($w.fields.'System.Title')"] = $w.id }
    }
    Write-Host "Existing tagged work items: $($ids.Count)"
}

# ---------------- create ----------------
function ConvertTo-Html([string[]]$lines, [string]$heading) {
    $lines = @($lines | Where-Object { $_ })
    if (-not $lines) { return '' }
    $enc = $lines | ForEach-Object { [System.Net.WebUtility]::HtmlEncode($_) }
    $h = if ($heading) { "<b>$heading</b>" } else { '' }
    if ($enc.Count -eq 1) { "$h<div>$($enc[0])</div>" } else { "$h<ul>" + (($enc | ForEach-Object { "<li>$_</li>" }) -join '') + '</ul>' }
}

foreach ($it in $items) {
    $label = '{0,-12} {1,-22} {2}' -f $it.Key, $it.Type, $it.Title
    $k = "$($it.Type)|$($it.Title)"
    if ($existing.ContainsKey($k)) { $it.Id = $existing[$k]; $it.Action = 'Exists'; Write-Host "  = $label (#$($it.Id))"; continue }
    if ($WhatIfPreference) { $it.Action = 'WhatIf'; Write-Host "  + $label"; continue }

    $desc = ConvertTo-Html $it.Description
    $ops = [System.Collections.Generic.List[object]]::new()
    $add = { param($path, $value) if ($null -ne $value -and "$value" -ne '') { $ops.Add(@{ op = 'add'; path = $path; value = $value }) } }
    & $add '/fields/System.Title' $it.Title
    & $add '/fields/System.Tags' $tag
    if ($AreaPath) { & $add '/fields/System.AreaPath' $AreaPath }
    if ($IterationPath) { & $add '/fields/System.IterationPath' $IterationPath }
    if ($AssignTo) { & $add '/fields/System.AssignedTo' $AssignTo }
    if ($it.Ac.Count -and $it.Kind -eq 'story' -and $map.ac) {
        & $add '/fields/Microsoft.VSTS.Common.AcceptanceCriteria' (ConvertTo-Html $it.Ac)
    } elseif ($it.Ac.Count) {
        $desc += (ConvertTo-Html $it.Ac 'Acceptance criteria')
    }
    & $add '/fields/System.Description' $desc
    if ($it.Kind -eq 'story' -and $it.Points -and $map.size) { & $add "/fields/$($map.size)" $it.Points }
    if ($it.Kind -eq 'task' -and $it.Hours) {
        & $add '/fields/Microsoft.VSTS.Scheduling.RemainingWork' $it.Hours
        if ($map.orig) { & $add '/fields/Microsoft.VSTS.Scheduling.OriginalEstimate' $it.Hours }
    }
    $parent = if ($it.ParentKey) { $byKey[$it.ParentKey] } else { $null }
    if ($parent -and $parent.Id -and -not $ValidateOnly) {
        $ops.Add(@{ op = 'add'; path = '/relations/-'; value = @{ rel = 'System.LinkTypes.Hierarchy-Reverse'; url = "$OrganizationUrl/_apis/wit/workItems/$($parent.Id)" } })
    }

    $typeEnc = [uri]::EscapeDataString($it.Type)
    $vo = if ($ValidateOnly) { '&validateOnly=true' } else { '' }
    try {
        $r = Invoke-Ado POST "$OrganizationUrl/$projEnc/_apis/wit/workitems/`$$typeEnc`?$api$vo" @($ops) 'application/json-patch+json'
        if ($ValidateOnly) { $it.Action = 'Valid'; Write-Host "  ✓ $label" }
        else {
            $it.Id = $r.id; $it.Url = $r._links.html.href; $it.Action = 'Created'
            Write-Host "  + $label (#$($r.id))" -ForegroundColor Green
        }
    } catch {
        $it.Action = "Error: $($_.Exception.Message)"
        Write-Host "  ! $label -> $($_.Exception.Message)" -ForegroundColor Red
        if (-not $ValidateOnly) { Write-Warning 'Stopping so children are not created without a parent. Fix and re-run; existing items are skipped.'; break }
    }
}

$items | Select-Object Key, Kind, Type, Id, Action, Title, Url | Export-Csv $OutCsv -NoTypeInformation -WhatIf:$false
$items | Group-Object Action | Format-Table Name, Count -AutoSize | Out-String | Write-Host
$epic = $byKey['E']
if ($epic.Id) { Write-Host "Epic: $OrganizationUrl/$projEnc/_workitems/edit/$($epic.Id)" }
if ($items.Action -like 'Error*') { exit 1 }
