#requires -Version 7.2
<#
.SYNOPSIS
  Inventory of Azure Policy: which policies / initiatives are assigned at which level, and what each subscription
  effectively inherits. Read-only. PowerShell 7 + Azure CLI (az login).

.DESCRIPTION
  Walks the whole management group tree from the Tenant Root Group and collects assignments and exemptions at
  every level: tenant root, management groups, subscriptions, resource groups. Effects are resolved through
  assignment, initiative and definition parameters (e.g. an initiative whose storage policy is set to Deny by the
  assignment shows as Deny, not as the definition's default Audit).

  Outputs (-OutDir):
    policy-assignments.csv    one row per assignment: level, scope, path, policy/initiative, built-in or custom
                              (and where the custom definition is stored), effects, enforcement mode, identity,
                              excluded scopes, non-compliant resources, parameters
    effective-policies.csv    one row per subscription x assignment that reaches it, with where it is inherited
                              from and whether it Applies / is Excluded (notScopes) / Exempted / partly so
    policy-exemptions.csv     exemptions at every level
    policy-inventory.md       findings, the tree with assignments under each level, per-subscription summary

  Needs Reader at the Tenant Root Group (Policy Insights read for compliance numbers).

.EXAMPLE
  az login
  ./00-Export-PolicyInventory.ps1
  ./00-Export-PolicyInventory.ps1 -SkipCompliance -OutDir ./out/policy
#>
[CmdletBinding()]
param(
    [string]$OutDir = './out',
    [string]$IntermediateRootId,
    [switch]$SkipCompliance,
    [switch]$SkipEffects
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'AzCliHelpers.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'MgHierarchy.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '..' 'lib' 'PolicyEffects.psm1') -Force
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$tenantId = (Invoke-AzJson @('account', 'show')).tenantId
$flat = ConvertTo-FlatHierarchy -Tree (Get-MgTreeLive -TenantId $tenantId)
$names = @{}; foreach ($g in $flat.Groups) { $names[$g.Id] = $g.DisplayName }; foreach ($s in $flat.Subscriptions) { $names[$s.Id] = $s.Name }
$mgScope = { param($id) "/providers/Microsoft.Management/managementGroups/$id" }
function Get-PathText([string]$id) {
    $chain = [string[]](Get-AncestorChain -Id $id -ParentMap $flat.Parent); [array]::Reverse($chain)
    (@($chain | ForEach-Object { $names[$_] ?? $_ }) + @($names[$id] ?? $id)) -join ' > '
}
function Get-ScopeInfo([string]$scope) {
    switch -Regex ($scope) {
        '/managementGroups/([^/]+)$' { $id = $Matches[1]; return @{ Level = $(if ($id -eq $tenantId) { 'TenantRoot' } else { 'ManagementGroup' }); Name = $names[$id] ?? $id; Path = Get-PathText $id; Node = $id } }
        '^/subscriptions/([^/]+)/resourceGroups/([^/]+)$' { $sid = $Matches[1]; return @{ Level = 'ResourceGroup'; Name = "$($names[$sid] ?? $sid) / $($Matches[2])"; Path = "$(Get-PathText $sid) > $($Matches[2])"; Node = $sid } }
        '^/subscriptions/([^/]+)$' { $sid = $Matches[1]; return @{ Level = 'Subscription'; Name = $names[$sid] ?? $sid; Path = Get-PathText $sid; Node = $sid } }
        default { return @{ Level = 'Other'; Name = $scope; Path = $scope; Node = $null } }
    }
}

# ---------------- collect ----------------
Write-Host "Tenant ${tenantId}: $(@($flat.Groups).Count) management groups, $(@($flat.Subscriptions).Count) subscriptions" -ForegroundColor Cyan
$assignments = [System.Collections.Generic.List[object]]::new(); $seen = @{}
$exemptions = [System.Collections.Generic.List[object]]::new(); $seenEx = @{}
$addA = { param($a) $k = $a.id.ToLower(); if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $assignments.Add($a) } }
$addE = { param($e) $k = $e.id.ToLower(); if (-not $seenEx.ContainsKey($k)) { $seenEx[$k] = 1; $exemptions.Add($e) } }
foreach ($g in $flat.Groups) {
    $sc = & $mgScope $g.Id
    Write-Host "  management group $($g.DisplayName)"
    Invoke-AzJson @('policy', 'assignment', 'list', '--scope', $sc) | Where-Object { (Get-AzProp $_ 'scope') -eq $sc } | ForEach-Object { & $addA $_ }
    try { Invoke-AzJson @('policy', 'exemption', 'list', '--scope', $sc) | Where-Object { $_.id -like "$sc/providers/*" } | ForEach-Object { & $addE $_ } } catch { Write-Verbose $_ }
}
foreach ($s in $flat.Subscriptions) {
    $sc = "/subscriptions/$($s.Id)"
    Write-Host "  subscription $($s.Name)"
    try {
        Invoke-AzJson @('policy', 'assignment', 'list', '--subscription', $s.Id, '--disable-scope-strict-match') | Where-Object { (Get-AzProp $_ 'scope') -like "$sc*" } | ForEach-Object { & $addA $_ }
        Invoke-AzJson @('policy', 'exemption', 'list', '--subscription', $s.Id, '--disable-scope-strict-match') | Where-Object { $_.id -like "$sc/*" } | ForEach-Object { & $addE $_ }
    } catch { Write-Warning "$($s.Name): $($_.Exception.Message)" }
}

$nc = @{}
if (-not $SkipCompliance) {
    try {
        $sum = Invoke-AzRest post "$(& $mgScope $tenantId)/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01"
        foreach ($p in @($sum.value[0].policyAssignments)) { $nc[$p.policyAssignmentId.ToLower()] = [int]$p.results.nonCompliantResources }
    } catch { Write-Warning "Compliance summary unavailable: $($_.Exception.Message)" }
}

# ---------------- assignment rows ----------------
$rows = foreach ($a in $assignments) {
    $scope = Get-AzProp $a 'scope'; $si = Get-ScopeInfo $scope
    $defId = Get-AzProp $a 'policyDefinitionId'
    $eff = if ($SkipEffects) { @{} } else { Get-EffectsCached $a }
    $params = Get-AzProp $a 'parameters'
    [pscustomobject]@{
        Level = $si.Level; Scope = $si.Name; Path = $si.Path; AssignmentName = $a.name
        DisplayName = ($a.displayName ?? (Get-AzProp $a 'displayName') ?? $a.name)
        Kind = $(if ($defId -match '/policySetDefinitions/') { 'Initiative' } else { 'Policy' })
        Source = Get-DefinitionSource $defId; Definition = ($defId -replace '.*/', '')
        Effects = $(if ($SkipEffects) { '' } else { Format-Effects $eff })
        Enforcement = (Get-AzProp $a 'enforcementMode') ?? 'Default'
        Identity = $(if ($a.identity.type) { "$($a.identity.type) $($a.identity.principalId)" } else { '' })
        NotScopes = (@(Get-AzProp $a 'notScopes') -join '; ')
        NonCompliant = $(if ($nc.ContainsKey($a.id.ToLower())) { $nc[$a.id.ToLower()] } else { '' })
        Parameters = $(if ($params) { ($params | ConvertTo-Json -Depth 10 -Compress) } else { '' })
        ScopeId = $scope; AssignmentId = $a.id; DefinitionId = $defId
        _Eff = $eff; _Node = $si.Node
    }
}
$rows = @($rows)
$levelOrder = @{ TenantRoot = 0; ManagementGroup = 1; Subscription = 2; ResourceGroup = 3; Other = 4 }
$rows = @($rows | Sort-Object { $levelOrder[$_.Level] }, Path, DisplayName)
$rows | Select-Object * -ExcludeProperty _* | Export-Csv (Join-Path $OutDir 'policy-assignments.csv') -NoTypeInformation

$exRows = @($exemptions | ForEach-Object {
        $esc = $_.id -replace '/providers/Microsoft\.Authorization/policyExemptions/.*$', ''; $si = Get-ScopeInfo $esc
        [pscustomobject]@{ Level = $si.Level; Scope = $si.Name; Path = $si.Path; Exemption = ($_.displayName ?? $_.name)
            Category = (Get-AzProp $_ 'exemptionCategory'); Assignment = ((Get-AzProp $_ 'policyAssignmentId') -replace '.*/', '')
            AssignmentId = (Get-AzProp $_ 'policyAssignmentId'); Expires = $(($x = Get-AzProp $_ 'expiresOn') ? ([datetime]$x).ToString('yyyy-MM-dd') : ''); ScopeId = $esc }
    })
$exRows | Export-Csv (Join-Path $OutDir 'policy-exemptions.csv') -NoTypeInformation

# ---------------- effective per subscription ----------------
$eff = foreach ($s in $flat.Subscriptions) {
    $sc = "/subscriptions/$($s.Id)"
    $chain = [string[]](Get-AncestorChain -Id $s.Id -ParentMap $flat.Parent)
    $chainScopes = @($chain | ForEach-Object { & $mgScope $_ })
    $reach = $rows | Where-Object { $_.ScopeId -in $chainScopes -or $_.ScopeId -eq $sc -or $_.ScopeId -like "$sc/resourceGroups/*" }
    foreach ($r in $reach) {
        $ns = @(($r.NotScopes -split '; ') | Where-Object { $_ })
        $status = if ($ns | Where-Object { $_ -eq $sc -or $_ -in $chainScopes }) { 'Excluded' }
                  elseif ($ns | Where-Object { $_ -like "$sc/*" }) { 'PartiallyExcluded' }
                  else { 'Applies' }
        if ($status -ne 'Excluded') {
            $ex = @($exRows | Where-Object { $_.AssignmentId -eq $r.AssignmentId })
            if ($ex | Where-Object { $_.ScopeId -eq $sc -or $_.ScopeId -in $chainScopes }) { $status = 'Exempted' }
            elseif ($ex | Where-Object { $_.ScopeId -like "$sc/*" }) { $status = if ($status -eq 'Applies') { 'PartiallyExempted' } else { $status } }
        }
        [pscustomobject]@{ Subscription = $s.Name; SubscriptionId = $s.Id; SubscriptionPath = Get-PathText $s.Id
            Assignment = $r.DisplayName; Kind = $r.Kind; Effects = $r.Effects; Enforcement = $r.Enforcement
            InheritedFrom = $(if ($r.Level -in 'TenantRoot', 'ManagementGroup') { "$($r.Level): $($r.Scope)" } else { "$($r.Level): $($r.Scope)" })
            Inherited = ($r.Level -in 'TenantRoot', 'ManagementGroup'); Status = $status; Source = $r.Source; DefinitionId = $r.DefinitionId; AssignmentId = $r.AssignmentId; _Eff = $r._Eff }
    }
}
$eff = @($eff)
$eff | Select-Object * -ExcludeProperty _* | Export-Csv (Join-Path $OutDir 'effective-policies.csv') -NoTypeInformation

# ---------------- findings ----------------
$find = [System.Collections.Generic.List[string]]::new()
$atRoot = @($rows | Where-Object Level -eq 'TenantRoot')
if ($atRoot) { $find.Add("$($atRoot.Count) assignment(s) at the Tenant Root Group apply to every subscription, including new ones: $($atRoot.DisplayName -join ', '). Keep root assignments to a minimum; prefer the intermediate root.") }
$subsAtRoot = @($flat.Subscriptions | Where-Object Parent -eq $tenantId)
if ($subsAtRoot) { $find.Add("$($subsAtRoot.Count) subscription(s) sit directly under the Tenant Root Group: $($subsAtRoot.Name -join ', ').") }
$dupes = $eff | Where-Object Status -ne 'Excluded' | Group-Object SubscriptionId, DefinitionId | Where-Object Count -gt 1
foreach ($d in $dupes | Select-Object -First 15) {
    $find.Add("Same definition assigned $($d.Count)x to $($d.Group[0].Subscription): $($d.Group[0].Assignment) (from $(($d.Group.InheritedFrom | Sort-Object -Unique) -join ' and ')). Duplicate evaluation and conflicting parameters.")
}
$dne = @($rows | Where-Object Enforcement -eq 'DoNotEnforce')
if ($dne) { $find.Add("$($dne.Count) assignment(s) in DoNotEnforce (report only): $(($dne | ForEach-Object { "$($_.DisplayName) @ $($_.Scope)" }) -join '; ').") }
if (-not $SkipEffects) {
    $disabled = @($rows | Where-Object { $_._Eff.Keys.Count -and -not ($_._Eff.Keys | Where-Object { $_ -ne 'Disabled' }) })
    if ($disabled) { $find.Add("$($disabled.Count) assignment(s) where every policy resolves to Disabled: $($disabled.DisplayName -join ', ').") }
    $noId = @($rows | Where-Object { ($_._Eff.DeployIfNotExists -or $_._Eff.Modify) -and -not $_.Identity })
    if ($noId) { $find.Add("$($noId.Count) DeployIfNotExists/Modify assignment(s) without a managed identity (cannot remediate): $($noId.DisplayName -join ', ').") }
    $unk = @($rows | Where-Object { $_._Eff.Unknown })
    if ($unk) { $find.Add("$($unk.Count) assignment(s) with effects that could not be resolved (definition not readable or missing): $($unk.DisplayName -join ', ').") }
}
$lowCustom = @($rows | Where-Object { $_.Source -match 'Custom @ mg:(.+)$' -and $Matches[1] -ne $tenantId -and (-not $IntermediateRootId -or $Matches[1] -ne $IntermediateRootId) } | Select-Object -ExpandProperty Source -Unique)
if ($lowCustom) { $find.Add("Custom definitions stored below the root$(if ($IntermediateRootId) { " / '$IntermediateRootId'" }): $($lowCustom -join ', '). Subscriptions moved out of that branch break assignments that use them.") }
$top = @($rows | Where-Object { $_.NonCompliant -ne '' -and [int]$_.NonCompliant -gt 0 } | Sort-Object { [int]$_.NonCompliant } -Descending | Select-Object -First 5)
if ($top) { $find.Add("Most non-compliant: $(($top | ForEach-Object { "$($_.DisplayName) @ $($_.Scope) ($($_.NonCompliant))" }) -join '; ').") }

# ---------------- markdown ----------------
$md = [System.Text.StringBuilder]::new()
$null = $md.AppendLine("# Azure Policy inventory`n`nTenant ``$tenantId`` · $(Get-Date -Format 'yyyy-MM-dd HH:mm') · $($rows.Count) assignments ($(@($rows | Where-Object Kind -eq 'Initiative').Count) initiatives) · $($exRows.Count) exemptions`n")
$null = $md.AppendLine("| Level | Assignments | Deny | DeployIfNotExists / Modify | Audit only |`n|---|---|---|---|---|")
foreach ($lv in 'TenantRoot', 'ManagementGroup', 'Subscription', 'ResourceGroup') {
    $l = @($rows | Where-Object Level -eq $lv)
    $null = $md.AppendLine("| $lv | $($l.Count) | $(@($l | Where-Object { $_._Eff.Deny -or $_._Eff.DenyAction }).Count) | $(@($l | Where-Object { $_._Eff.DeployIfNotExists -or $_._Eff.Modify }).Count) | $(@($l | Where-Object { $_._Eff.Keys.Count -and -not ($_._Eff.Keys | Where-Object { $_ -notin 'Audit','AuditIfNotExists','Disabled','Manual' }) }).Count) |")
}
$null = $md.AppendLine("`n## Findings`n"); if ($find.Count) { $find | ForEach-Object { $null = $md.AppendLine("- $_") } } else { $null = $md.AppendLine('None.') }

$null = $md.AppendLine("`n## Assignments by level`n`n``````text")
$children = @{}; foreach ($k in $flat.Parent.Keys) { $p = $flat.Parent[$k]; if (-not $children[$p]) { $children[$p] = [System.Collections.Generic.List[string]]::new() }; $children[$p].Add($k) }
$isSub = @{}; foreach ($s in $flat.Subscriptions) { $isSub[$s.Id] = $true }
$fmt = { param($r) $nct = if ($r.NonCompliant -ne '') { " · NC $($r.NonCompliant)" } else { '' }; $dn = if ($r.Enforcement -eq 'DoNotEnforce') { ' · DoNotEnforce' } else { '' }; "$($r.Kind -eq 'Initiative' ? '[I]' : '[P]') $($r.DisplayName) · $($r.Source) · $($r.Effects)$dn$nct" }
$render = {
    param($id, $indent)
    $label = if ($isSub[$id]) { "[sub] $($names[$id])" } else { "$($names[$id] ?? $id) ($id)" }
    $own = @($rows | Where-Object { $_._Node -eq $id -and $_.Level -ne 'ResourceGroup' })
    $rgs = @($rows | Where-Object { $_._Node -eq $id -and $_.Level -eq 'ResourceGroup' })
    $null = $md.AppendLine("$indent$label$(if ($own -or $rgs) { "  — $($own.Count + $rgs.Count) assignment(s)" })")
    foreach ($r in $own) { $null = $md.AppendLine("$indent    • $(& $fmt $r)") }
    foreach ($r in $rgs) { $null = $md.AppendLine("$indent    • rg $($r.Scope -replace '^.*/ ', ''): $(& $fmt $r)") }
    foreach ($c in @($children[$id] | Sort-Object { [int][bool]$isSub[$_] }, { $names[$_] })) { & $render $c "$indent    " }
}
& $render $flat.RootId ''
$null = $md.AppendLine('```')
$null = $md.AppendLine("`n[P] policy · [I] initiative · NC = non-compliant resources · effects resolved through parameters (Deny:3 = three policies with Deny)")

$null = $md.AppendLine("`n## Effective policies per subscription`n`n| Subscription | Path | Applies | Inherited | Own (sub/RG) | Deny | DINE / Modify | Excluded | Exempted |`n|---|---|---|---|---|---|---|---|---|")
foreach ($g in $eff | Group-Object SubscriptionId | Sort-Object { $_.Group[0].SubscriptionPath }) {
    $x = $g.Group; $ap = @($x | Where-Object { $_.Status -notin 'Excluded', 'Exempted' })
    $null = $md.AppendLine("| $($x[0].Subscription) | $($x[0].SubscriptionPath -replace '\|', '/') | $($ap.Count) | $(@($ap | Where-Object Inherited).Count) | $(@($ap | Where-Object { -not $_.Inherited }).Count) | $(@($ap | Where-Object { $_._Eff.Deny -or $_._Eff.DenyAction }).Count) | $(@($ap | Where-Object { $_._Eff.DeployIfNotExists -or $_._Eff.Modify }).Count) | $(@($x | Where-Object Status -like '*Excluded').Count) | $(@($x | Where-Object Status -like '*Exempted').Count) |")
}
$none = @($flat.Subscriptions | Where-Object { $_.Id -notin $eff.SubscriptionId })
foreach ($s in $none) { $null = $md.AppendLine("| $($s.Name) | $(Get-PathText $s.Id) | 0 | 0 | 0 | 0 | 0 | 0 | 0 |") }
if ($exRows) {
    $null = $md.AppendLine("`n## Exemptions`n`n| Level | Scope | Exemption | Category | Assignment | Expires |`n|---|---|---|---|---|---|")
    foreach ($e in $exRows) { $null = $md.AppendLine("| $($e.Level) | $($e.Scope) | $($e.Exemption) | $($e.Category) | $($e.Assignment) | $($e.Expires) |") }
}
$md.ToString() | Set-Content (Join-Path $OutDir 'policy-inventory.md')

# ---------------- console ----------------
Write-Host "`nAssignments by level" -ForegroundColor Cyan
$rows | Group-Object Level | Sort-Object { $levelOrder[$_.Name] } | ForEach-Object { Write-Host ("  {0,-16} {1}" -f $_.Name, $_.Count) }
$rows | Format-Table Level, Scope, DisplayName, Kind, Source, Effects, Enforcement, NonCompliant -AutoSize | Out-String -Width 250 | Write-Host
if ($find.Count) { Write-Host 'Findings' -ForegroundColor Cyan; $find | ForEach-Object { Write-Host "  - $_" } }
Write-Host "`nOutputs: $((Resolve-Path $OutDir).Path) (policy-assignments.csv, effective-policies.csv, policy-exemptions.csv, policy-inventory.md)"
