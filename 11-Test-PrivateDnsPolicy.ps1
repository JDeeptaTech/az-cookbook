#requires -Version 7.2
#requires -Modules Az.Accounts
<#
.SYNOPSIS
  Test the central private DNS zones and the policy that registers private endpoints in them.

.DESCRIPTION
  Mode Audit (read-only, safe to run any time):
    Zones     every zone in zone-map.json exists in the central RG, RG has a delete lock
    Links     each zone is linked to every -HubVnetId, link Succeeded/Completed, auto-registration off
    Shadow    privatelink.* zones anywhere else under the management group
    Policy    one DINE assignment per groupId, enforcement on, effect not Disabled, zone IDs point at the
              central zones, managed identity present with the right roles; Deny assignment present
    Compliance non-compliant private endpoints per DINE assignment (= PEs with no central zone group)

  Mode E2E (creates and deletes throwaway resources in -TestResourceGroup):
    1. Deploy a test Key Vault / storage account / SQL server with public access disabled and a private
       endpoint for each -Services groupId, WITHOUT a DNS zone group.
    2. Wait for the DINE policy to add 'deployedByPolicy' (time-to-register is reported). If nothing after
       -RemediateAfterMinutes, start a remediation task and report that the on-create path failed.
    3. Check the zone group points at the central zone and the A record holds the PE NIC IP.
    4. Resolve the public FQDN through -ResolverIp / -DnsServer (and optionally from -TestVmId).
    5. -ExpectDenyEffect: try to create a privatelink zone in the test RG and check Deny/Audit behaviour.
    6. Delete the PEs and check the A records are removed from the central zone (no stale records),
       then delete the RG and purge the soft-deleted Key Vault.

  Only depends on Az.Accounts (Invoke-AzRestMethod) with pinned API versions, so it behaves the same
  across Az module versions. Results go to the console and a JUnit file for pipelines. Exit code 1 on any Fail.

.EXAMPLE
  # read-only audit
  ./11-Test-PrivateDnsPolicy.ps1 -ManagementGroup contoso-landingzones -ZoneSubscriptionId <conn-sub> `
      -HubVnetId /subscriptions/<conn-sub>/resourceGroups/rg-hub-net/providers/Microsoft.Network/virtualNetworks/vnet-hub-uks

.EXAMPLE
  # full canary in a landing-zone subscription
  ./11-Test-PrivateDnsPolicy.ps1 -Mode All -ManagementGroup contoso-landingzones -ZoneSubscriptionId <conn-sub> `
      -HubVnetId <hub-vnet-id> -TestSubscriptionId <lz-sub> -TestSubnetId <spoke-pe-subnet-id> -Location uksouth `
      -Services vault,blob,file -ResolverIp 10.0.0.4 -DnsServer 10.10.0.10 -ExpectDenyEffect Audit -Tags @{ costCenter = 'platform' }
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'E2E', 'All')][string]$Mode = 'Audit',
    [Parameter(Mandatory)][string]$ManagementGroup,
    [Parameter(Mandatory)][string]$ZoneSubscriptionId,
    [string]$ZoneResourceGroup = 'rg-dns-privatezones',
    [string[]]$HubVnetId,
    [string]$ZoneMapPath = (Join-Path $PSScriptRoot '..' 'config' 'zone-map.json'),
    [string]$DinePolicyDefinitionName = 'dine-pe-central-dns',
    [string]$DenyPolicyDefinitionName = 'deny-privatelink-zones',

    # ---- E2E ----
    [string]$TestSubscriptionId,
    [string]$TestResourceGroup = ('rg-dnspolicy-canary-' + (Get-Date -Format 'yyyyMMddHHmm')),
    [string]$TestSubnetId,
    [string]$Location = 'uksouth',
    [ValidateSet('vault', 'blob', 'file', 'queue', 'table', 'dfs', 'sqlServer')][string[]]$Services = @('vault', 'blob'),
    [double]$TimeoutMinutes = 30,
    [double]$RemediateAfterMinutes = 15,
    [int]$PollSeconds = 30,
    [string[]]$ResolverIp,
    [string[]]$DnsServer,
    [string]$TestVmId,
    [ValidateSet('Linux', 'Windows')][string]$TestVmOs = 'Linux',
    [ValidateSet('Deny', 'Audit', 'Skip')][string]$ExpectDenyEffect = 'Skip',
    [hashtable]$Tags = @{},
    [switch]$KeepResources,

    [string]$JUnitPath = './out/dns-policy-tests.xml',
    [switch]$WarnAsFail
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DnsMigration.psm1') -Force
$zoneMap = Get-ZoneMap -Path $ZoneMapPath
$sfxIndex = Get-SuffixIndex -ZoneMap $zoneMap

# ======================= helpers =======================
$Results = [System.Collections.Generic.List[object]]::new()
function Add-Result([string]$Area, [string]$Name, [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string]$Status, [string]$Detail = '', [double]$Seconds = 0) {
    $Results.Add([pscustomobject]@{ Area = $Area; Name = $Name; Status = $Status; Detail = $Detail; Seconds = [math]::Round($Seconds, 1) })
    $c = @{ Pass = 'Green'; Fail = 'Red'; Warn = 'Yellow'; Skip = 'DarkGray' }[$Status]
    Write-Host ("  [{0}] {1,-10} {2}{3}" -f $Status.ToUpper().PadRight(4), $Area, $Name, $(if ($Detail) { " - $Detail" })) -ForegroundColor $c
}

$Api = @{ dns = '2020-06-01'; net = '2023-09-01'; lock = '2020-05-01'; pa = '2023-04-01'; ra = '2022-04-01'
          ps = '2019-10-01'; rem = '2021-10-01'; rg = '2021-04-01'; dep = '2022-09-01'; arg = '2022-10-01'; kv = '2023-07-01'; vm = '2023-09-01' }

function Invoke-Arm {
    <# Thin wrapper over Invoke-AzRestMethod: JSON in/out, 429/5xx retry, throws with ARM error code. -AllowStatus returns $null for e.g. 404. #>
    param([string]$Method = 'GET', [string]$Path, [string]$Uri, $Body, [int[]]$AllowStatus = @(), [switch]$Raw)
    $args2 = @{ Method = $Method }
    if ($Uri) { $args2.Uri = $Uri } else { $args2.Path = $Path }
    if ($null -ne $Body) { $args2.Payload = ($Body | ConvertTo-Json -Depth 50 -Compress) }
    for ($i = 1; $i -le 6; $i++) {
        $r = Invoke-AzRestMethod @args2
        $code = [int]$r.StatusCode
        if ($code -in 429, 500, 502, 503, 504) { Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $i))); continue }
        if ($Raw) { return $r }
        if ($code -lt 300) { return $(if ($r.Content) { $r.Content | ConvertFrom-Json -Depth 50 } else { $null }) }
        if ($code -in $AllowStatus) { return $null }
        $err = try { ($r.Content | ConvertFrom-Json -Depth 20).error } catch { $null }
        $ex = [System.Exception]::new("ARM $Method $($Path ?? $Uri) -> $code $($err.code): $($err.message)")
        $ex.Data['code'] = $err.code; $ex.Data['status'] = $code
        throw $ex
    }
    throw "ARM $Method $($Path ?? $Uri) failed after retries"
}

function Get-ArgRows([string]$Query) {
    $rows = [System.Collections.Generic.List[object]]::new(); $skip = $null
    do {
        $opts = @{ '$top' = 1000 }; if ($skip) { $opts['$skipToken'] = $skip }
        $r = Invoke-Arm POST "/providers/Microsoft.ResourceGraph/resources?api-version=$($Api.arg)" -Body @{ query = $Query; managementGroups = @($ManagementGroup); options = $opts }
        if ($r.data) { $rows.AddRange([object[]]@($r.data)) }
        $skip = $r.'$skipToken'
    } while ($skip)
    $rows
}

$zoneRgPath = "/subscriptions/$ZoneSubscriptionId/resourceGroups/$ZoneResourceGroup"
$zoneRgId = $zoneRgPath.ToLower()
$mgPath = "/providers/Microsoft.Management/managementGroups/$ManagementGroup"
function Get-CentralZoneId([string]$zone) { "$zoneRgPath/providers/Microsoft.Network/privateDnsZones/$zone".ToLower() }
$Role = @{ NetworkContributor = '4d97b98b-1d4f-4787-a291-c67834d212e7'; PrivateDnsZoneContributor = 'b12aa53e-6015-4669-85d0-8515ebb3ae7f'
           Contributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'; Owner = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' }
$dineServices = @($zoneMap | Where-Object groupId -ne 'azuremonitor')
$dineByKey = @{}   # "groupId|resourceType" -> assignment (filled by policy audit, reused by E2E)

# ======================= AUDIT =======================
function Invoke-Audit {
    Write-Host "`n== Central zones ($ZoneResourceGroup)" -ForegroundColor Cyan
    $zones = $zoneMap.zones | Sort-Object -Unique
    foreach ($z in $zones) {
        $zone = Invoke-Arm GET "$zoneRgPath/providers/Microsoft.Network/privateDnsZones/${z}?api-version=$($Api.dns)" -AllowStatus 404
        if (-not $zone) { Add-Result Zones $z Fail 'zone missing'; continue }
        Add-Result Zones $z Pass "$($zone.properties.numberOfRecordSets) record sets"

        $links = @((Invoke-Arm GET "$zoneRgPath/providers/Microsoft.Network/privateDnsZones/$z/virtualNetworkLinks?api-version=$($Api.dns)").value)
        foreach ($hub in $HubVnetId) {
            $l = $links | Where-Object { $_.properties.virtualNetwork.id -eq $hub } | Select-Object -First 1
            $hubName = ($hub -split '/')[-1]
            if (-not $l) { Add-Result Links "$z -> $hubName" Fail 'no VNet link'; continue }
            $bad = @()
            if ($l.properties.provisioningState -ne 'Succeeded') { $bad += "provisioning=$($l.properties.provisioningState)" }
            if ($l.properties.virtualNetworkLinkState -ne 'Completed') { $bad += "state=$($l.properties.virtualNetworkLinkState)" }
            if ($l.properties.registrationEnabled) { $bad += 'auto-registration ON' }
            if ($bad) { Add-Result Links "$z -> $hubName" Fail ($bad -join ', ') } else { Add-Result Links "$z -> $hubName" Pass }
        }
        $extra = $links | Where-Object { $_.properties.virtualNetwork.id -notin $HubVnetId }
        if ($extra -and $HubVnetId) { Add-Result Links "$z extra links" Warn "$(@($extra).Count) non-hub VNet link(s): spokes should resolve via the resolver, not links" }
    }
    $locks = @((Invoke-Arm GET "$zoneRgPath/providers/Microsoft.Authorization/locks?api-version=$($Api.lock)").value)
    if ($locks | Where-Object { $_.properties.level -in 'CanNotDelete', 'ReadOnly' }) { Add-Result Zones 'Resource group lock' Pass } else { Add-Result Zones 'Resource group lock' Warn "no CanNotDelete lock on $ZoneResourceGroup" }

    Write-Host "`n== Shadow privatelink zones under $ManagementGroup" -ForegroundColor Cyan
    $shadow = Get-ArgRows "resources | where type =~ 'microsoft.network/privatednszones' and name startswith 'privatelink.' | where tolower(resourceGroup) != '$($ZoneResourceGroup.ToLower())' or subscriptionId != '$ZoneSubscriptionId' | project id, name, subscriptionId, resourceGroup"
    if ($shadow) {
        Add-Result Shadow 'privatelink.* zones outside the central RG' Warn "$(@($shadow).Count) found, e.g. $((@($shadow) | Select-Object -First 3 | ForEach-Object { "$($_.name) ($($_.resourceGroup))" }) -join '; ')"
    } else { Add-Result Shadow 'privatelink.* zones outside the central RG' Pass 'none' }

    Write-Host "`n== Policy assignments at $ManagementGroup" -ForegroundColor Cyan
    $assignments = @((Invoke-Arm GET "$mgPath/providers/Microsoft.Authorization/policyAssignments?api-version=$($Api.pa)&`$filter=atScope()").value)
    $dine = @($assignments | Where-Object { $_.properties.policyDefinitionId -match "/policyDefinitions/$([regex]::Escape($DinePolicyDefinitionName))$" })
    foreach ($svc in $dineServices) {
        $name = "$($svc.name) ($($svc.groupId))"
        $a = $dine | Where-Object { $_.properties.parameters.groupId.value -eq $svc.groupId -and $_.properties.parameters.resourceType.value -eq $svc.resourceType } | Select-Object -First 1
        if (-not $a) { Add-Result Policy $name Fail "no DINE assignment for groupId '$($svc.groupId)' / $($svc.resourceType)"; continue }
        $dineByKey["$($svc.groupId)|$($svc.resourceType)"] = $a
        $issues = @()
        if ($a.properties.enforcementMode -ne 'Default') { $issues += "enforcementMode=$($a.properties.enforcementMode)" }
        if ($a.properties.parameters.effect.value -eq 'Disabled') { $issues += 'effect=Disabled' }
        $have = @($a.properties.parameters.privateDnsZoneIds.value | ForEach-Object { $_.ToLower() }) | Sort-Object
        $want = @($svc.zones | ForEach-Object { Get-CentralZoneId $_ }) | Sort-Object
        if (($have -join ',') -ne ($want -join ',')) { $issues += "zone IDs differ from central (have: $(($have | ForEach-Object { ($_ -split '/')[4] + '/' + ($_ -split '/')[-1] }) -join ', '))" }
        $principal = $a.identity.principalId
        if (-not $principal) { $issues += 'no managed identity' }
        if ($issues) { Add-Result Policy $name Fail ($issues -join '; ') } else { Add-Result Policy $name Pass $a.name }

        if ($principal) {
            $mgRoles = @((Invoke-Arm GET "$mgPath/providers/Microsoft.Authorization/roleAssignments?api-version=$($Api.ra)&`$filter=principalId eq '$principal'").value) |
                ForEach-Object { ($_.properties.roleDefinitionId -split '/')[-1] }
            $zoneRoles = @((Invoke-Arm GET "$zoneRgPath/providers/Microsoft.Authorization/roleAssignments?api-version=$($Api.ra)&`$filter=principalId eq '$principal'").value) |
                ForEach-Object { ($_.properties.roleDefinitionId -split '/')[-1] }
            $okMg = $mgRoles | Where-Object { $_ -in $Role.NetworkContributor, $Role.Contributor, $Role.Owner }
            $okZone = $zoneRoles | Where-Object { $_ -in $Role.PrivateDnsZoneContributor, $Role.NetworkContributor, $Role.Contributor, $Role.Owner }
            if ($okMg -and $okZone) { Add-Result Identity $name Pass 'PE write at MG + zone join on central RG' }
            else { Add-Result Identity $name Fail ((@(if (-not $okMg) { 'missing Network Contributor at MG' }) + @(if (-not $okZone) { "missing Private DNS Zone Contributor on $ZoneResourceGroup" })) -join '; ') }
        }

        try {
            $sum = Invoke-Arm POST "$mgPath/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=$($Api.ps)&`$filter=policyAssignmentId eq '$($a.id)'"
            $nc = [int]$sum.value[0].results.nonCompliantResources
            if ($nc -eq 0) { Add-Result Compliance $name Pass '0 non-compliant private endpoints' }
            else {
                $q = Invoke-Arm POST "$mgPath/providers/Microsoft.PolicyInsights/policyStates/latest/queryResults?api-version=$($Api.ps)&`$top=5&`$filter=policyAssignmentId eq '$($a.id)' and complianceState eq 'NonCompliant'"
                $eg = (@($q.value) | ForEach-Object { ($_.resourceId -split '/')[-1] }) -join ', '
                Add-Result Compliance $name Warn "$nc non-compliant PE(s) (no central zone group) e.g. $eg - run 04-Set-PeDnsZoneGroup.ps1 or a remediation task"
            }
        } catch { Add-Result Compliance $name Warn "compliance not available yet: $($_.Exception.Message)" }
    }
    $deny = $assignments | Where-Object { $_.properties.policyDefinitionId -match "/policyDefinitions/$([regex]::Escape($DenyPolicyDefinitionName))$" } | Select-Object -First 1
    if ($deny) { Add-Result Policy 'Deny privatelink.* zones' Pass "effect=$($deny.properties.parameters.effect.value ?? 'Deny (default)'), enforcement=$($deny.properties.enforcementMode)" }
    else { Add-Result Policy 'Deny privatelink.* zones' Warn 'no assignment found' }
}

# ======================= E2E =======================
function New-CanaryTemplate([string]$sfx, [string[]]$svcList, [string]$tenantId) {
    $res = [System.Collections.Generic.List[object]]::new(); $targets = @()
    $storageGroups = @($svcList | Where-Object { $_ -in 'blob', 'file', 'queue', 'table', 'dfs' })
    if ('vault' -in $svcList) {
        $kv = "kvdnscan$sfx"
        $res.Add(@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2023-07-01'; name = $kv; location = $Location; tags = $Tags
            properties = @{ tenantId = $tenantId; sku = @{ family = 'A'; name = 'standard' }; enableRbacAuthorization = $true
                softDeleteRetentionInDays = 7; publicNetworkAccess = 'Disabled'; networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices' } } })
        $targets += @{ groupId = 'vault'; type = 'Microsoft.KeyVault/vaults'; name = $kv }
    }
    if ($storageGroups) {
        $st = "stdnscan$sfx"
        $res.Add(@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-01-01'; name = $st; location = $Location; tags = $Tags
            kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
            properties = @{ publicNetworkAccess = 'Disabled'; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
                minimumTlsVersion = 'TLS1_2'; supportsHttpsTrafficOnly = $true; isHnsEnabled = ('dfs' -in $storageGroups) } })
        foreach ($g in $storageGroups) { $targets += @{ groupId = $g; type = 'Microsoft.Storage/storageAccounts'; name = $st } }
    }
    if ('sqlServer' -in $svcList) {
        $sql = "sql-dnscan-$sfx"
        $res.Add(@{ type = 'Microsoft.Sql/servers'; apiVersion = '2021-11-01'; name = $sql; location = $Location; tags = $Tags
            properties = @{ administratorLogin = 'canaryadmin'; administratorLoginPassword = "[parameters('sqlPassword')]"
                publicNetworkAccess = 'Disabled'; minimalTlsVersion = '1.2'; version = '12.0' } })
        $targets += @{ groupId = 'sqlServer'; type = 'Microsoft.Sql/servers'; name = $sql }
    }
    foreach ($t in $targets) {
        $t.pe = "pe-$($t.groupId.ToLower())-dnscan-$sfx"
        $res.Add(@{ type = 'Microsoft.Network/privateEndpoints'; apiVersion = $Api.net; name = $t.pe; location = $Location; tags = $Tags
            dependsOn = @("[resourceId('$($t.type)', '$($t.name)')]")
            properties = @{ subnet = @{ id = $TestSubnetId }
                # deliberately NO privateDnsZoneGroups: the policy must add it
                privateLinkServiceConnections = @(@{ name = $t.groupId; properties = @{ privateLinkServiceId = "[resourceId('$($t.type)', '$($t.name)')]"; groupIds = @($t.groupId) } }) } })
    }
    @{ template = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'; contentVersion = '1.0.0.0'
                     parameters = @{ sqlPassword = @{ type = 'securestring'; defaultValue = '' } }; resources = @($res) }
       targets = $targets }
}

function Wait-Deployment([string]$path, [double]$minutes = 20) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalMinutes -lt $minutes) {
        $d = Invoke-Arm GET "${path}?api-version=$($Api.dep)"
        switch ($d.properties.provisioningState) {
            'Succeeded' { return $d }
            { $_ -in 'Failed', 'Canceled' } {
                $ops = Invoke-Arm GET "$path/operations?api-version=$($Api.dep)"
                $msg = (@($ops.value) | Where-Object { $_.properties.provisioningState -eq 'Failed' } | ForEach-Object {
                    "$($_.properties.targetResource.resourceName): $($_.properties.statusMessage.error.code) $($_.properties.statusMessage.error.message)" }) -join ' | '
                throw "Deployment $($d.properties.provisioningState): $msg"
            }
        }
        Start-Sleep -Seconds ([math]::Max(1, [math]::Min($PollSeconds, 10)))
    }
    throw "Deployment did not finish in $minutes min"
}

function Get-PeDnsTargets([string]$peId) {
    # FQDN + IP from the PE NIC: populated whether or not a zone group exists
    $pe = Invoke-Arm GET "${peId}?api-version=$($Api.net)"
    $nic = Invoke-Arm GET "$($pe.properties.networkInterfaces[0].id)?api-version=$($Api.net)"
    foreach ($ipc in $nic.properties.ipConfigurations) {
        foreach ($f in @($ipc.properties.privateLinkConnectionProperties.fqdns)) {
            $k = ConvertTo-ZoneKey -Fqdn $f -SuffixIndex $sfxIndex
            if ($k) { $rel, $zone = $k -split '\|', 2; [pscustomobject]@{ Fqdn = $f; Ip = $ipc.properties.privateIPAddress; Record = $rel; Zone = $zone } }
        }
    }
}

function Get-CentralRecordIps([string]$zone, [string]$name) {
    $rs = Invoke-Arm GET "$zoneRgPath/providers/Microsoft.Network/privateDnsZones/$zone/A/${name}?api-version=$($Api.dns)" -AllowStatus 404
    if ($rs) { @($rs.properties.aRecords.ipv4Address) } else { @() }
}

function Invoke-VmResolve([string]$fqdn) {
    $p = $TestVmId -split '/'
    $body = if ($TestVmOs -eq 'Linux') { @{ commandId = 'RunShellScript'; script = @("getent ahostsv4 $fqdn | awk 'NR==1{print `$1}'") } }
            else { @{ commandId = 'RunPowerShellScript'; script = @("(Resolve-DnsName $fqdn -Type A -DnsOnly | ? Type -eq 'A' | select -First 1).IPAddress") } }
    $r = Invoke-Arm POST "$TestVmId/runCommand?api-version=$($Api.vm)" -Body $body -Raw
    $op = ($r.Headers | Where-Object Key -eq 'Azure-AsyncOperation' | Select-Object -First 1).Value | Select-Object -First 1
    if (-not $op) { throw 'run command returned no Azure-AsyncOperation header' }
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 5
        $s = Invoke-Arm GET -Uri $op
        if ($s.status -eq 'Succeeded') { return (($s.properties.output.value | Where-Object code -like '*StdOut*').message -split "`n" | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1) }
        if ($s.status -in 'Failed', 'Canceled') { throw "run command $($s.status)" }
    }
    throw 'run command timed out'
}

function Invoke-E2E {
    foreach ($p in 'TestSubscriptionId', 'TestSubnetId') { if (-not (Get-Variable $p -ValueOnly)) { throw "-$p is required for E2E" } }
    if (-not $dineByKey.Count) {
        # E2E without audit: still need the assignments (for remediation + zone ID check)
        $assignments = @((Invoke-Arm GET "$mgPath/providers/Microsoft.Authorization/policyAssignments?api-version=$($Api.pa)&`$filter=atScope()").value)
        foreach ($a in $assignments | Where-Object { $_.properties.policyDefinitionId -match "/policyDefinitions/$([regex]::Escape($DinePolicyDefinitionName))$" }) {
            $dineByKey["$($a.properties.parameters.groupId.value)|$($a.properties.parameters.resourceType.value)"] = $a
        }
    }
    $rgPath = "/subscriptions/$TestSubscriptionId/resourceGroups/$TestResourceGroup"
    $sfx = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $tenantId = (Get-AzContext).Tenant.Id
    $created = @{ rg = $false; kv = $null; pes = @() }
    $state = @()

    Write-Host "`n== E2E canary in $TestResourceGroup (suffix $sfx)" -ForegroundColor Cyan
    try {
        $null = Invoke-Arm PUT "${rgPath}?api-version=$($Api.rg)" -Body @{ location = $Location; tags = ($Tags + @{ purpose = 'dns-policy-canary'; createdBy = '11-Test-PrivateDnsPolicy' }) }
        $created.rg = $true

        $tpl = New-CanaryTemplate $sfx $Services $tenantId
        $sqlPw = if ('sqlServer' -in $Services) { 'Cn!' + [guid]::NewGuid().ToString('N').Substring(0, 20) + 'aZ9' } else { '' }
        $depPath = "$rgPath/providers/Microsoft.Resources/deployments/dns-canary-$sfx"
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Arm PUT "${depPath}?api-version=$($Api.dep)" -Body @{ properties = @{ mode = 'Incremental'; template = $tpl.template; parameters = @{ sqlPassword = @{ value = $sqlPw } } } }
        try { $null = Wait-Deployment $depPath; Add-Result E2E 'Deploy test resources + PEs (no zone group)' Pass ($tpl.targets.pe -join ', ') $sw.Elapsed.TotalSeconds }
        catch { Add-Result E2E 'Deploy test resources + PEs (no zone group)' Fail $_.Exception.Message $sw.Elapsed.TotalSeconds; return }
        if ($tpl.targets | Where-Object groupId -eq 'vault') { $created.kv = ($tpl.targets | Where-Object groupId -eq 'vault')[0].name }

        foreach ($t in $tpl.targets) {
            $peId = "$rgPath/providers/Microsoft.Network/privateEndpoints/$($t.pe)"
            $created.pes += $peId
            $svc = $zoneMap | Where-Object { $_.groupId -eq $t.groupId -and $_.resourceType -eq $t.type } | Select-Object -First 1
            $state += [pscustomobject]@{ T = $t; PeId = $peId; Svc = $svc; Dns = @(Get-PeDnsTargets $peId); Assignment = $dineByKey["$($t.groupId)|$($t.type)"]
                                         ZoneGroupAt = $null; RecordAt = $null; Remediated = $false; Done = $false }
        }

        # ---- wait for policy ----
        $sw = [Diagnostics.Stopwatch]::StartNew(); $remediationStarted = $false
        while (($state | Where-Object { -not $_.Done }) -and $sw.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
            foreach ($s in $state | Where-Object { -not $_.Done }) {
                if (-not $s.ZoneGroupAt) {
                    $zg = @((Invoke-Arm GET "$($s.PeId)/privateDnsZoneGroups?api-version=$($Api.net)").value)
                    if ($zg) {
                        $s.ZoneGroupAt = $sw.Elapsed.TotalSeconds
                        $ids = @($zg.properties.privateDnsZoneConfigs.properties.privateDnsZoneId | ForEach-Object { $_.ToLower() }) | Sort-Object
                        $want = @($s.Svc.zones | ForEach-Object { Get-CentralZoneId $_ }) | Sort-Object
                        $via = if ($s.Remediated) { ' (after remediation task)' } else { '' }
                        if (($ids -join ',') -eq ($want -join ',')) {
                            Add-Result Register "$($s.T.groupId): zone group '$($zg[0].name)'$via" $(if ($s.Remediated) { 'Warn' } else { 'Pass' }) ("{0:n0}s after PE created" -f $s.ZoneGroupAt) $s.ZoneGroupAt
                        } else { Add-Result Register "$($s.T.groupId): zone group targets" Fail "points at $($ids -join ', ')" $s.ZoneGroupAt }
                    }
                }
                if ($s.ZoneGroupAt -and -not $s.RecordAt) {
                    $ok = $true
                    foreach ($d in $s.Dns) { if ($d.Ip -notin (Get-CentralRecordIps $d.Zone $d.Record)) { $ok = $false } }
                    if ($ok) {
                        $s.RecordAt = $sw.Elapsed.TotalSeconds; $s.Done = $true
                        Add-Result Record "$($s.T.groupId): A record in central zone" Pass (($s.Dns | ForEach-Object { "$($_.Record).$($_.Zone) = $($_.Ip)" }) -join '; ') $s.RecordAt
                    }
                }
            }
            if (-not $remediationStarted -and $sw.Elapsed.TotalMinutes -ge $RemediateAfterMinutes) {
                $remediationStarted = $true
                foreach ($s in $state | Where-Object { -not $_.ZoneGroupAt }) {
                    Add-Result Register "$($s.T.groupId): DINE on create" Warn "no zone group after $RemediateAfterMinutes min - starting remediation"
                    if (-not $s.Assignment) { Add-Result Register "$($s.T.groupId): remediation" Fail 'no DINE assignment to remediate with'; $s.Done = $true; continue }
                    $null = Invoke-Arm PUT "$rgPath/providers/Microsoft.PolicyInsights/remediations/canary-$($s.T.groupId.ToLower())-${sfx}?api-version=$($Api.rem)" -Body @{ properties = @{ policyAssignmentId = $s.Assignment.id; resourceDiscoveryMode = 'ReEvaluateCompliance' } }
                    $s.Remediated = $true
                }
            }
            if ($state | Where-Object { -not $_.Done }) { Start-Sleep -Seconds $PollSeconds }
        }
        foreach ($s in $state | Where-Object { -not $_.Done }) {
            if (-not $s.ZoneGroupAt) { Add-Result Register "$($s.T.groupId): zone group" Fail "none after $TimeoutMinutes min (assignment: $($s.Assignment.name ?? 'MISSING'))" }
            else { Add-Result Record "$($s.T.groupId): A record in central zone" Fail "zone group exists but $((@($s.Dns) | ForEach-Object { "$($_.Record).$($_.Zone)" }) -join ', ') does not hold the PE IP" }
        }

        # ---- resolution ----
        $servers = @($ResolverIp | Where-Object { $_ } | ForEach-Object { @{ n = "resolver $_"; s = $_ } }) + @($DnsServer | Where-Object { $_ } | ForEach-Object { @{ n = "dns $_"; s = $_ } })
        foreach ($s in $state | Where-Object RecordAt) {
            foreach ($d in $s.Dns) {
                foreach ($srv in $servers) {
                    $got = @(); $t0 = [Diagnostics.Stopwatch]::StartNew()
                    try {
                        while ($t0.Elapsed.TotalSeconds -lt 180) { $got = @(Resolve-ARecord -Name $d.Fqdn -Server $srv.s); if ($d.Ip -in $got) { break }; Start-Sleep 10 }
                    } catch { Add-Result Resolve "$($d.Fqdn) via $($srv.n)" Fail $_.Exception.Message; continue }
                    if ($d.Ip -in $got) { Add-Result Resolve "$($d.Fqdn) via $($srv.n)" Pass $d.Ip $t0.Elapsed.TotalSeconds }
                    else { Add-Result Resolve "$($d.Fqdn) via $($srv.n)" Fail "got '$($got -join ',')' expected $($d.Ip) (forwarder / ruleset / link?)" $t0.Elapsed.TotalSeconds }
                }
                if ($TestVmId) {
                    try { $ip = Invoke-VmResolve $d.Fqdn; Add-Result Resolve "$($d.Fqdn) from VM $(($TestVmId -split '/')[-1])" $(if ($ip -eq $d.Ip) { 'Pass' } else { 'Fail' }) "got '$ip' expected $($d.Ip)" }
                    catch { Add-Result Resolve "$($d.Fqdn) from VM" Fail $_.Exception.Message }
                }
            }
        }
        if (-not $servers -and -not $TestVmId) { Add-Result Resolve 'DNS resolution' Skip 'pass -ResolverIp / -DnsServer / -TestVmId' }

        # ---- deny shadow zones ----
        if ($ExpectDenyEffect -ne 'Skip') {
            $zPath = "$rgPath/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net"
            try {
                $null = Invoke-Arm PUT "${zPath}?api-version=$($Api.dns)" -Body @{ location = 'global'; tags = $Tags }
                if ($ExpectDenyEffect -eq 'Deny') { Add-Result Deny 'Create privatelink zone in landing zone' Fail 'was allowed; expected RequestDisallowedByPolicy' }
                else { Add-Result Deny 'Create privatelink zone in landing zone' Pass 'allowed (Audit) - will show non-compliant' }
                Start-Sleep -Seconds 5
                $null = Invoke-Arm DELETE "${zPath}?api-version=$($Api.dns)" -AllowStatus 404
            } catch {
                if ($_.Exception.Data['code'] -eq 'RequestDisallowedByPolicy') {
                    Add-Result Deny 'Create privatelink zone in landing zone' $(if ($ExpectDenyEffect -eq 'Deny') { 'Pass' } else { 'Fail' }) 'RequestDisallowedByPolicy'
                } else { Add-Result Deny 'Create privatelink zone in landing zone' Fail $_.Exception.Message }
            }
        }

        # ---- cleanup removes records ----
        if (-not $KeepResources) {
            foreach ($s in $state) { $null = Invoke-Arm DELETE "$($s.PeId)?api-version=$($Api.net)" -AllowStatus 404 }
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            $pending = @($state | Where-Object RecordAt)
            while ($pending -and $t0.Elapsed.TotalMinutes -lt [math]::Min(10.0, $TimeoutMinutes)) {
                Start-Sleep -Seconds ([math]::Min($PollSeconds, 15))
                $pending = @($pending | Where-Object { $s = $_; @($s.Dns | Where-Object { $_.Ip -in (Get-CentralRecordIps $_.Zone $_.Record) }).Count -gt 0 })
            }
            foreach ($s in $state | Where-Object RecordAt) {
                if ($s -in $pending) { Add-Result Cleanup "$($s.T.groupId): record removed with PE" Fail "A record still present $([math]::Min(10.0, $TimeoutMinutes)) min after PE deletion (stale record risk)" }
                else { Add-Result Cleanup "$($s.T.groupId): record removed with PE" Pass '' $t0.Elapsed.TotalSeconds }
            }
            $created.pes = @()
        }
    }
    finally {
        if ($KeepResources) { Write-Host "Kept $TestResourceGroup (-KeepResources)." -ForegroundColor Yellow }
        elseif ($created.rg) {
            try {
                foreach ($pe in $created.pes) { $null = Invoke-Arm DELETE "${pe}?api-version=$($Api.net)" -AllowStatus 404 }
                $null = Invoke-Arm DELETE "${rgPath}?api-version=$($Api.rg)" -AllowStatus 404
                $t0 = [Diagnostics.Stopwatch]::StartNew()
                while ((Invoke-Arm GET "${rgPath}?api-version=$($Api.rg)" -AllowStatus 404) -and $t0.Elapsed.TotalMinutes -lt 15) { Start-Sleep -Seconds ([math]::Min($PollSeconds, 20)) }
                if ($created.kv) {
                    $null = Invoke-Arm POST "/subscriptions/$TestSubscriptionId/providers/Microsoft.KeyVault/locations/$Location/deletedVaults/$($created.kv)/purge?api-version=$($Api.kv)" -AllowStatus 404, 409
                }
                Add-Result Cleanup "Delete $TestResourceGroup" Pass
            } catch { Add-Result Cleanup "Delete $TestResourceGroup" Warn "delete manually: $($_.Exception.Message)" }
        }
    }
}

# ======================= run =======================
$ctx = Get-AzContext
if (-not $ctx) { throw 'Not signed in. Run Connect-AzAccount (or use an AzurePowerShell pipeline task).' }
Write-Host "Account: $($ctx.Account.Id)  Tenant: $($ctx.Tenant.Id)  Mode: $Mode"
if ($Mode -in 'Audit', 'All') {
    try { Invoke-Audit } catch { Add-Result Audit 'Unexpected error' Fail $_.Exception.Message }
}
if ($Mode -in 'E2E', 'All') {
    try { Invoke-E2E } catch { Add-Result E2E 'Unexpected error' Fail "$($_.Exception.Message) (line $($_.InvocationInfo.ScriptLineNumber))" }
}

# ---- summary + JUnit ----
$Results | Group-Object Status | Sort-Object Name | ForEach-Object { "{0,-5} {1}" -f $_.Name, $_.Count } | Write-Host
$dir = Split-Path $JUnitPath -Parent; if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }
$suites = foreach ($g in $Results | Group-Object Area) {
    $fails = @($g.Group | Where-Object { $_.Status -eq 'Fail' -or ($WarnAsFail -and $_.Status -eq 'Warn') }).Count
    $skips = @($g.Group | Where-Object Status -eq 'Skip').Count
    $cases = foreach ($r in $g.Group) {
        $inner = switch ($r.Status) {
            'Fail' { "<failure message=`"$(& $esc $r.Detail)`"/>" }
            'Skip' { "<skipped message=`"$(& $esc $r.Detail)`"/>" }
            'Warn' { if ($WarnAsFail) { "<failure message=`"WARN: $(& $esc $r.Detail)`"/>" } else { "<system-out>WARN: $(& $esc $r.Detail)</system-out>" } }
            default { if ($r.Detail) { "<system-out>$(& $esc $r.Detail)</system-out>" } }
        }
        "<testcase classname=`"dns.$($g.Name)`" name=`"$(& $esc $r.Name)`" time=`"$($r.Seconds)`">$inner</testcase>"
    }
    "<testsuite name=`"$($g.Name)`" tests=`"$($g.Count)`" failures=`"$fails`" skipped=`"$skips`">$($cases -join '')</testsuite>"
}
"<?xml version=`"1.0`" encoding=`"UTF-8`"?><testsuites name=`"private-dns-policy`">$($suites -join '')</testsuites>" | Set-Content -Path $JUnitPath -Encoding utf8
Write-Host "JUnit: $JUnitPath"
if ($Results | Where-Object { $_.Status -eq 'Fail' -or ($WarnAsFail -and $_.Status -eq 'Warn') }) { exit 1 }
