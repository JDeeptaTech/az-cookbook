#requires -Version 7.2
<#
  Pester 5 suite: central private DNS zones + the DINE policy that registers private endpoints in them.
  Uses the Azure CLI only (az, az rest). Run through scripts/11-Test-PrivateDnsPolicy.ps1, or directly:

    $c = New-PesterContainer -Path ./tests/PrivateDnsPolicy.Tests.ps1 -Data @{ ManagementGroup = 'contoso-landingzones'; ZoneSubscriptionId = '<id>'; HubVnetId = @('<hub-vnet-id>') }
    Invoke-Pester -Container $c -Output Detailed -TagFilter Audit

  Tags:  Audit = read-only checks.  E2E = creates a canary resource group, private endpoints without a zone group,
         waits for the policy, checks records + resolution + cleanup, then deletes everything.
  Inconclusive = warning (e.g. shadow zones, non-compliant PEs, zone group only after remediation).
#>
param(
    [Parameter(Mandatory)][string]$ManagementGroup,
    [Parameter(Mandatory)][string]$ZoneSubscriptionId,
    [string]$ZoneResourceGroup = 'rg-dns-privatezones',
    [string[]]$HubVnetId = @(),
    [string]$ZoneMapPath = (Join-Path $PSScriptRoot '..' 'config' 'zone-map.json'),
    [string]$DinePolicyDefinitionName = 'dine-pe-central-dns',
    [string]$DenyPolicyDefinitionName = 'deny-privatelink-zones',
    [bool]$StrictShadow = $false,

    [string]$TestSubscriptionId,
    [string]$TestResourceGroup = ('rg-dnspolicy-canary-' + (Get-Date -Format 'yyyyMMddHHmm')),
    [string]$TestSubnetId,
    [string]$Location = 'uksouth',
    [string[]]$Services = @('vault', 'blob'),
    [double]$TimeoutMinutes = 30,
    [double]$RemediateAfterMinutes = 15,
    [int]$PollSeconds = 30,
    [string[]]$ResolverIp = @(),
    [string[]]$DnsServer = @(),
    [string]$TestVmId,
    [ValidateSet('Linux', 'Windows')][string]$TestVmOs = 'Linux',
    [ValidateSet('Deny', 'Audit', 'Skip')][string]$ExpectDenyEffect = 'Skip',
    [hashtable]$Tags = @{},
    [bool]$KeepResources = $false
)

BeforeDiscovery {
    $zoneMap = (Get-Content -Raw $ZoneMapPath | ConvertFrom-Json).services
    $zones = @($zoneMap.zones | Sort-Object -Unique)
    $ZoneCases = @($zones | ForEach-Object { @{ Zone = $_ } })
    $LinkCases = @(foreach ($z in $zones) { foreach ($h in $HubVnetId) { @{ Zone = $z; HubId = $h; HubName = ($h -split '/')[-1] } } })
    $DineCases = @($zoneMap | Where-Object groupId -ne 'azuremonitor' | ForEach-Object {
            @{ Name = $_.name; GroupId = $_.groupId; ResourceType = $_.resourceType; Zones = @($_.zones) } })
    $SvcCases = @($Services | ForEach-Object { @{ GroupId = $_ } })
    $servers = @($ResolverIp | Where-Object { $_ } | ForEach-Object { @{ ServerName = "resolver $_"; Server = $_ } }) +
               @($DnsServer | Where-Object { $_ } | ForEach-Object { @{ ServerName = "DNS server $_"; Server = $_ } })
    $ResolveCases = @(foreach ($s in $Services) { foreach ($srv in $servers) { @{ GroupId = $s; ServerName = $srv.ServerName; Server = $srv.Server } } })
    $VmCases = if ($TestVmId) { @($Services | ForEach-Object { @{ GroupId = $_; VmName = ($TestVmId -split '/')[-1] } }) } else { @() }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'AzCliHelpers.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' 'scripts' 'DnsMigration.psm1') -Force
    $zoneMap = Get-ZoneMap -Path $ZoneMapPath
    $sfxIndex = Get-SuffixIndex -ZoneMap $zoneMap
    $zoneRgId = "/subscriptions/$ZoneSubscriptionId/resourceGroups/$ZoneResourceGroup"
    $mgId = "/providers/Microsoft.Management/managementGroups/$ManagementGroup"
    function Get-CentralZoneId([string]$Zone) { "$zoneRgId/providers/Microsoft.Network/privateDnsZones/$Zone".ToLower() }
    $cache = @{}
    function Get-Cached([string]$Key, [scriptblock]$Get) { if (-not $cache.ContainsKey($Key)) { $cache[$Key] = & $Get }; $cache[$Key] }
    function Get-Assignments {
        Get-Cached 'assignments' { @(Invoke-AzJson @('policy', 'assignment', 'list', '--scope', $mgId, '--disable-scope-strict-match')) }
    }
    function Get-ZoneLinks([string]$Zone) {
        Get-Cached "links|$Zone" { @(Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '-g', $ZoneResourceGroup, '-z', $Zone, '--subscription', $ZoneSubscriptionId)) }
    }
    function Get-CentralRecordIps([string]$Zone, [string]$Name) {
        $rs = Invoke-AzJson @('network', 'private-dns', 'record-set', 'a', 'show', '-g', $ZoneResourceGroup, '-z', $Zone, '-n', $Name, '--subscription', $ZoneSubscriptionId) -AllowNotFound
        @((Get-AzProp $rs 'aRecords') | ForEach-Object { $_.ipv4Address })
    }
}

# =========================== AUDIT ===========================
Describe 'Central private DNS zones' -Tag Audit {
    It 'zone <Zone> exists in the central resource group' -ForEach $ZoneCases {
        $z = Invoke-AzJson @('network', 'private-dns', 'zone', 'show', '-g', $ZoneResourceGroup, '-n', $Zone, '--subscription', $ZoneSubscriptionId) -AllowNotFound
        $z | Should -Not -BeNullOrEmpty -Because "$Zone must exist in $ZoneResourceGroup"
    }

    It '<Zone> is linked to <HubName> with auto-registration off' -ForEach $LinkCases {
        $link = Get-ZoneLinks $Zone | Where-Object { (Get-AzProp $_ 'virtualNetwork').id -eq $HubId } | Select-Object -First 1
        $link | Should -Not -BeNullOrEmpty -Because "the resolver's VNet must be linked to $Zone"
        Get-AzProp $link 'provisioningState' | Should -Be 'Succeeded'
        Get-AzProp $link 'virtualNetworkLinkState' | Should -Be 'Completed'
        Get-AzProp $link 'registrationEnabled' | Should -BeFalse -Because 'auto-registration is for VM records, not private endpoints'
    }

    It '<Zone> has no links to spoke VNets' -ForEach $ZoneCases {
        if (-not $HubVnetId) { Set-ItResult -Skipped -Because 'no -HubVnetId given' }
        $extra = @(Get-ZoneLinks $Zone | Where-Object { (Get-AzProp $_ 'virtualNetwork').id -notin $HubVnetId })
        if ($extra) { Set-ItResult -Inconclusive -Because "$($extra.Count) non-hub link(s): spokes should resolve through the resolver" }
    }

    It 'central resource group has a delete lock' {
        $locks = @(Invoke-AzJson @('lock', 'list', '-g', $ZoneResourceGroup, '--subscription', $ZoneSubscriptionId))
        @($locks | Where-Object { (Get-AzProp $_ 'level') -in 'CanNotDelete', 'ReadOnly' }) | Should -Not -BeNullOrEmpty -Because 'deleting a privatelink zone breaks resolution for every PE'
    }
}

Describe 'Shadow privatelink zones' -Tag Audit {
    It 'no privatelink.* zones exist outside the central resource group' {
        $q = "resources | where type =~ 'microsoft.network/privatednszones' and name startswith 'privatelink.' | where tolower(resourceGroup) != '$($ZoneResourceGroup.ToLower())' or subscriptionId != '$ZoneSubscriptionId' | project name, resourceGroup, subscriptionId"
        $rows = Get-AzArgRows -Query $q -ManagementGroup $ManagementGroup
        $eg = ($rows | Select-Object -First 3 | ForEach-Object { "$($_.name) ($($_.resourceGroup))" }) -join '; '
        if ($rows -and -not $StrictShadow) { Set-ItResult -Inconclusive -Because "$(@($rows).Count) shadow zone(s), e.g. $eg" }
        $rows | Should -BeNullOrEmpty -Because "shadow zones found: $eg"
    }
}

Describe 'DINE assignment: <Name> (<GroupId>)' -ForEach $DineCases -Tag Audit {
    BeforeAll {
        $a = Get-Assignments | Where-Object {
            (Get-AzProp $_ 'policyDefinitionId') -match "/policyDefinitions/$([regex]::Escape($DinePolicyDefinitionName))$" -and
            (Get-AzProp $_ 'parameters').groupId.value -eq $GroupId -and (Get-AzProp $_ 'parameters').resourceType.value -eq $ResourceType
        } | Select-Object -First 1
        $principal = $a.identity.principalId
    }

    It 'is assigned to the management group' {
        $a | Should -Not -BeNullOrEmpty -Because "no '$DinePolicyDefinitionName' assignment for groupId '$GroupId' / $ResourceType"
    }

    It 'is enforced and its effect is not Disabled' {
        if (-not $a) { Set-ItResult -Skipped -Because 'not assigned' }
        Get-AzProp $a 'enforcementMode' | Should -Be 'Default'
        (Get-AzProp $a 'parameters').effect.value | Should -Not -Be 'Disabled'
    }

    It 'targets the central zone(s)' {
        if (-not $a) { Set-ItResult -Skipped -Because 'not assigned' }
        $have = @((Get-AzProp $a 'parameters').privateDnsZoneIds.value | ForEach-Object { $_.ToLower() }) | Sort-Object
        $want = @($Zones | ForEach-Object { Get-CentralZoneId $_ }) | Sort-Object
        $have | Should -Be $want
    }

    It 'has a managed identity' {
        if (-not $a) { Set-ItResult -Skipped -Because 'not assigned' }
        $principal | Should -Not -BeNullOrEmpty -Because 'DINE needs an identity to deploy the zone group'
    }

    It 'identity can write zone groups on private endpoints (Network Contributor at the MG)' {
        if (-not $principal) { Set-ItResult -Skipped -Because 'no identity' }
        $roles = @(Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $principal, '--scope', $mgId, '--include-inherited', '--fill-principal-name', 'false')).roleDefinitionName
        $roles | Where-Object { $_ -in 'Network Contributor', 'Contributor', 'Owner' } | Should -Not -BeNullOrEmpty -Because "roles at the MG: $($roles -join ', ')"
    }

    It 'identity can join the central zones (Private DNS Zone Contributor on the zones RG)' {
        if (-not $principal) { Set-ItResult -Skipped -Because 'no identity' }
        $roles = @(Invoke-AzJson @('role', 'assignment', 'list', '--assignee', $principal, '--scope', $zoneRgId, '--include-inherited', '--fill-principal-name', 'false')).roleDefinitionName
        $roles | Where-Object { $_ -in 'Private DNS Zone Contributor', 'Network Contributor', 'Contributor', 'Owner' } | Should -Not -BeNullOrEmpty -Because 'without privateDnsZones/join/action the deployment fails and the PE stays non-compliant'
    }

    It 'has no non-compliant private endpoints' {
        if (-not $a) { Set-ItResult -Skipped -Because 'not assigned' }
        $filter = "`$filter=policyAssignmentId eq '$($a.id)'"
        $sum = Invoke-AzRest post "$mgId/providers/Microsoft.PolicyInsights/policyStates/latest/summarize?api-version=2019-10-01" -UriParameters $filter
        $nc = [int]$sum.value[0].results.nonCompliantResources
        if ($nc -gt 0) {
            $q = Invoke-AzRest post "$mgId/providers/Microsoft.PolicyInsights/policyStates/latest/queryResults?api-version=2019-10-01" -UriParameters "$filter and complianceState eq 'NonCompliant'", '$top=5'
            $eg = (@($q.value) | ForEach-Object { ($_.resourceId -split '/')[-1] }) -join ', '
            Set-ItResult -Inconclusive -Because "$nc PE(s) without a central zone group, e.g. $eg. Backfill with 04-Set-PeDnsZoneGroup.ps1 or a remediation task"
        }
    }
}

Describe 'Deny privatelink.* zones assignment' -Tag Audit {
    It 'is assigned to the management group' {
        $d = Get-Assignments | Where-Object { (Get-AzProp $_ 'policyDefinitionId') -match "/policyDefinitions/$([regex]::Escape($DenyPolicyDefinitionName))$" } | Select-Object -First 1
        $d | Should -Not -BeNullOrEmpty
    }
}

# =========================== E2E ===========================
Describe 'Policy auto-registration canary' -Tag E2E {
    BeforeAll {
        if (-not $TestSubscriptionId -or -not $TestSubnetId) { throw 'E2E needs -TestSubscriptionId and -TestSubnetId' }
        $sfx = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $sub = @('--subscription', $TestSubscriptionId)
        $E2E = @{ DeployError = $null; State = @{}; RgCreated = $false; KeyVault = $null; Cleaned = @{}; Sfx = $sfx }
        Write-Host "  canary: $TestResourceGroup (suffix $sfx)"

        # --- resources + PEs WITHOUT a zone group ---
        $res = [System.Collections.Generic.List[object]]::new(); $targets = @()
        $storage = @($Services | Where-Object { $_ -in 'blob', 'file', 'queue', 'table', 'dfs' })
        if ('vault' -in $Services) {
            $kv = "kvdnscan$sfx"; $E2E.KeyVault = $kv
            $res.Add(@{ type = 'Microsoft.KeyVault/vaults'; apiVersion = '2023-07-01'; name = $kv; location = $Location; tags = $Tags
                properties = @{ tenantId = '[subscription().tenantId]'; sku = @{ family = 'A'; name = 'standard' }; enableRbacAuthorization = $true
                    softDeleteRetentionInDays = 7; publicNetworkAccess = 'Disabled'; networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices' } } })
            $targets += @{ groupId = 'vault'; type = 'Microsoft.KeyVault/vaults'; name = $kv }
        }
        if ($storage) {
            $st = "stdnscan$sfx"
            $res.Add(@{ type = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-01-01'; name = $st; location = $Location; tags = $Tags
                kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
                properties = @{ publicNetworkAccess = 'Disabled'; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
                    minimumTlsVersion = 'TLS1_2'; supportsHttpsTrafficOnly = $true; isHnsEnabled = ('dfs' -in $storage) } })
            foreach ($g in $storage) { $targets += @{ groupId = $g; type = 'Microsoft.Storage/storageAccounts'; name = $st } }
        }
        if ('sqlServer' -in $Services) {
            $sql = "sql-dnscan-$sfx"
            $res.Add(@{ type = 'Microsoft.Sql/servers'; apiVersion = '2021-11-01'; name = $sql; location = $Location; tags = $Tags
                properties = @{ administratorLogin = 'canaryadmin'; administratorLoginPassword = "[parameters('sqlPassword')]"
                    publicNetworkAccess = 'Disabled'; minimalTlsVersion = '1.2'; version = '12.0' } })
            $targets += @{ groupId = 'sqlServer'; type = 'Microsoft.Sql/servers'; name = $sql }
        }
        foreach ($t in $targets) {
            $t.pe = "pe-$($t.groupId.ToLower())-dnscan-$sfx"
            $res.Add(@{ type = 'Microsoft.Network/privateEndpoints'; apiVersion = '2023-09-01'; name = $t.pe; location = $Location; tags = $Tags
                dependsOn = @("[resourceId('$($t.type)', '$($t.name)')]")
                properties = @{ subnet = @{ id = $TestSubnetId }
                    privateLinkServiceConnections = @(@{ name = $t.groupId; properties = @{ privateLinkServiceId = "[resourceId('$($t.type)', '$($t.name)')]"; groupIds = @($t.groupId) } }) } })
        }
        $tplFile = Join-Path ([IO.Path]::GetTempPath()) "dns-canary-$sfx.json"
        @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'; contentVersion = '1.0.0.0'
           parameters = @{ sqlPassword = @{ type = 'securestring'; defaultValue = '' } }; resources = @($res) } | ConvertTo-Json -Depth 50 | Set-Content $tplFile

        try {
            $null = Invoke-AzJson (@('group', 'create', '-n', $TestResourceGroup, '-l', $Location, '--tags') + (ConvertTo-AzTagArgs ($Tags + @{ purpose = 'dns-policy-canary' })) + $sub)
            $E2E.RgCreated = $true
            $pw = 'Cn!' + [guid]::NewGuid().ToString('N').Substring(0, 20) + 'aZ9'
            $null = Invoke-AzJson (@('deployment', 'group', 'create', '-g', $TestResourceGroup, '-n', "dns-canary-$sfx", '--template-file', $tplFile, '--parameters', "sqlPassword=$pw") + $sub)
        } catch { $E2E.DeployError = $_.Exception.Message }
        finally { Remove-Item $tplFile -Force -ErrorAction SilentlyContinue }

        if (-not $E2E.DeployError) {
            $assignments = Get-Assignments
            foreach ($t in $targets) {
                $peId = "/subscriptions/$TestSubscriptionId/resourceGroups/$TestResourceGroup/providers/Microsoft.Network/privateEndpoints/$($t.pe)"
                $pe = Invoke-AzJson @('network', 'private-endpoint', 'show', '--ids', $peId)
                $nic = Invoke-AzJson @('network', 'nic', 'show', '--ids', (Get-AzProp $pe 'networkInterfaces')[0].id)
                $dns = foreach ($ipc in (Get-AzProp $nic 'ipConfigurations')) {
                    foreach ($f in @((Get-AzProp $ipc 'privateLinkConnectionProperties').fqdns)) {
                        $k = ConvertTo-ZoneKey -Fqdn $f -SuffixIndex $sfxIndex
                        if ($k) { $rel, $z = $k -split '\|', 2; [pscustomobject]@{ Fqdn = $f; Ip = (Get-AzProp $ipc 'privateIPAddress'); Record = $rel; Zone = $z } }
                    }
                }
                $svc = $zoneMap | Where-Object { $_.groupId -eq $t.groupId -and $_.resourceType -eq $t.type } | Select-Object -First 1
                $asg = $assignments | Where-Object { (Get-AzProp $_ 'parameters').groupId.value -eq $t.groupId -and (Get-AzProp $_ 'parameters').resourceType.value -eq $t.type } | Select-Object -First 1
                $E2E.State[$t.groupId] = [pscustomobject]@{ GroupId = $t.groupId; PeId = $peId; PeName = $t.pe; Svc = $svc; Dns = @($dns); Assignment = $asg
                    ZoneGroup = $null; ZoneGroupAt = $null; RecordAt = $null; Remediated = $false }
            }

            # --- wait for the policy (remediation fallback) ---
            $sw = [Diagnostics.Stopwatch]::StartNew(); $remediated = $false
            $pending = { @($E2E.State.Values | Where-Object { -not $_.RecordAt }) }
            while ((& $pending) -and $sw.Elapsed.TotalMinutes -lt $TimeoutMinutes) {
                foreach ($s in & $pending) {
                    if (-not $s.ZoneGroupAt) {
                        $zg = @(Invoke-AzJson (@('network', 'private-endpoint', 'dns-zone-group', 'list', '-g', $TestResourceGroup, '--endpoint-name', $s.PeName) + $sub))
                        if ($zg) { $s.ZoneGroup = $zg[0]; $s.ZoneGroupAt = $sw.Elapsed.TotalSeconds; Write-Host ("  {0}: zone group '{1}' after {2:n0}s" -f $s.GroupId, $zg[0].name, $s.ZoneGroupAt) }
                    }
                    if ($s.ZoneGroupAt -and $s.Dns -and -not @($s.Dns | Where-Object { $_.Ip -notin (Get-CentralRecordIps $_.Zone $_.Record) })) { $s.RecordAt = $sw.Elapsed.TotalSeconds }
                }
                if (-not $remediated -and $sw.Elapsed.TotalMinutes -ge $RemediateAfterMinutes) {
                    $remediated = $true
                    foreach ($s in $E2E.State.Values | Where-Object { -not $_.ZoneGroupAt -and $_.Assignment }) {
                        Write-Host "  $($s.GroupId): no zone group after $RemediateAfterMinutes min, starting remediation"
                        $null = Invoke-AzJson (@('policy', 'remediation', 'create', '-n', "canary-$($s.GroupId.ToLower())-$sfx", '-g', $TestResourceGroup,
                                '--policy-assignment', $s.Assignment.id, '--resource-discovery-mode', 'ReEvaluateCompliance') + $sub)
                        $s.Remediated = $true
                    }
                }
                if (& $pending) { Start-Sleep -Seconds $PollSeconds }
            }
        }
    }

    AfterAll {
        if ($KeepResources) { Write-Host "  kept $TestResourceGroup"; return }
        if ($E2E.RgCreated) {
            try {
                $null = Invoke-AzJson (@('group', 'delete', '-n', $TestResourceGroup, '--yes') + $sub) -AllowNotFound
                if ($E2E.KeyVault) { $null = Invoke-AzJson (@('keyvault', 'purge', '-n', $E2E.KeyVault, '--location', $Location) + $sub) -AllowNotFound }
                Write-Host "  deleted $TestResourceGroup"
            } catch { Write-Warning "Delete $TestResourceGroup manually: $($_.Exception.Message)" }
        }
    }

    It 'deploys test resources and private endpoints without a zone group' {
        $E2E.DeployError | Should -BeNullOrEmpty
    }

    Context '<GroupId> private endpoint' -ForEach $SvcCases {
        BeforeAll { $s = $E2E.State[$GroupId] }

        It 'gets a zone group from the policy when it is created' {
            if ($E2E.DeployError) { Set-ItResult -Skipped -Because 'deployment failed' }
            $s.Assignment | Should -Not -BeNullOrEmpty -Because "no DINE assignment for $GroupId"
            $s.ZoneGroupAt | Should -Not -BeNullOrEmpty -Because "no zone group within $TimeoutMinutes min"
            if ($s.Remediated) { Set-ItResult -Inconclusive -Because "zone group appeared only after a remediation task ($([math]::Round($s.ZoneGroupAt))s): the on-create path did not fire within $RemediateAfterMinutes min" }
        }

        It 'zone group points at the central zone' {
            if (-not $s.ZoneGroup) { Set-ItResult -Skipped -Because 'no zone group' }
            $ids = @((Get-AzProp $s.ZoneGroup 'privateDnsZoneConfigs') | ForEach-Object { (Get-AzProp $_ 'privateDnsZoneId').ToLower() }) | Sort-Object
            $ids | Should -Be (@($s.Svc.zones | ForEach-Object { Get-CentralZoneId $_ }) | Sort-Object)
        }

        It 'A record in the central zone holds the private endpoint IP' {
            if (-not $s.ZoneGroup) { Set-ItResult -Skipped -Because 'no zone group' }
            $s.Dns | Should -Not -BeNullOrEmpty -Because 'the PE NIC reported no FQDNs'
            foreach ($d in $s.Dns) { Get-CentralRecordIps $d.Zone $d.Record | Should -Contain $d.Ip -Because "$($d.Record).$($d.Zone)" }
        }
    }

    Context 'Name resolution' {
        It '<GroupId> resolves to the private endpoint via <ServerName>' -ForEach $ResolveCases {
            $s = $E2E.State[$GroupId]
            if (-not $s.RecordAt) { Set-ItResult -Skipped -Because 'no central record' }
            foreach ($d in $s.Dns) {
                $got = @(); $t0 = [Diagnostics.Stopwatch]::StartNew()
                while ($t0.Elapsed.TotalSeconds -lt 180) { $got = @(Resolve-ARecord -Name $d.Fqdn -Server $Server); if ($d.Ip -in $got) { break }; Start-Sleep 10 }
                $got | Should -Contain $d.Ip -Because "$($d.Fqdn) via $Server (forwarder, ruleset or VNet link?)"
            }
        }

        It '<GroupId> resolves from VM <VmName>' -ForEach $VmCases {
            $s = $E2E.State[$GroupId]
            if (-not $s.RecordAt) { Set-ItResult -Skipped -Because 'no central record' }
            foreach ($d in $s.Dns) {
                $script = if ($TestVmOs -eq 'Linux') { "getent ahostsv4 $($d.Fqdn) | awk 'NR==1{print `$1}'" } else { "(Resolve-DnsName $($d.Fqdn) -Type A -DnsOnly | ? Type -eq 'A' | select -First 1).IPAddress" }
                $cmd = if ($TestVmOs -eq 'Linux') { 'RunShellScript' } else { 'RunPowerShellScript' }
                $r = Invoke-AzJson @('vm', 'run-command', 'invoke', '--ids', $TestVmId, '--command-id', $cmd, '--scripts', $script)
                $ip = "$($r.value.message -split "`n" | Where-Object { $_ -match '^\s*\d+\.\d+\.\d+\.\d+\s*$' } | Select-Object -First 1)".Trim()
                $ip | Should -Be $d.Ip -Because "$($d.Fqdn) from $VmName"
            }
        }

        It 'has a DNS server or VM to resolve from' -Skip:($ResolveCases.Count -gt 0 -or $VmCases.Count -gt 0) {
            Set-ItResult -Skipped -Because 'pass -ResolverIp, -DnsServer or -TestVmId'
        }
    }

    Context 'Shadow zone policy' {
        It 'creating a privatelink zone in a landing zone is handled as <ExpectDenyEffect>' -Skip:($ExpectDenyEffect -eq 'Skip') -TestCases @(@{ ExpectDenyEffect = $ExpectDenyEffect }) {
            if (-not $E2E.RgCreated) { Set-ItResult -Skipped -Because 'no canary RG' }
            $code = 'Allowed'
            try {
                $null = Invoke-AzJson (@('network', 'private-dns', 'zone', 'create', '-g', $TestResourceGroup, '-n', 'privatelink.blob.core.windows.net', '--tags') + (ConvertTo-AzTagArgs ($Tags + @{ purpose = 'dns-policy-canary' })) + $sub)
                $null = Invoke-AzJson (@('network', 'private-dns', 'zone', 'delete', '-g', $TestResourceGroup, '-n', 'privatelink.blob.core.windows.net', '--yes') + $sub) -AllowNotFound
            } catch { $code = $_.Exception.Data['code'] ?? $_.Exception.Message }
            $expected = if ($ExpectDenyEffect -eq 'Deny') { 'RequestDisallowedByPolicy' } else { 'Allowed' }
            $code | Should -Be $expected
        }
    }

    Context 'Cleanup' -Skip:$KeepResources {
        BeforeAll {
            foreach ($s in $E2E.State.Values) { $null = Invoke-AzJson @('network', 'private-endpoint', 'delete', '--ids', $s.PeId) -AllowNotFound }
            $t0 = [Diagnostics.Stopwatch]::StartNew()
            $left = @($E2E.State.Values | Where-Object RecordAt)
            while ($left -and $t0.Elapsed.TotalMinutes -lt [math]::Min(10.0, $TimeoutMinutes)) {
                Start-Sleep -Seconds ([math]::Min($PollSeconds, 15))
                $left = @($left | Where-Object { $st = $_; @($st.Dns | Where-Object { $_.Ip -in (Get-CentralRecordIps $_.Zone $_.Record) }).Count -gt 0 })
            }
            $leftIds = @($left.GroupId)
        }

        It '<GroupId>: deleting the private endpoint removes its A record' -ForEach $SvcCases {
            if (-not $E2E.State[$GroupId].RecordAt) { Set-ItResult -Skipped -Because 'record was never created' }
            $leftIds | Should -Not -Contain $GroupId -Because 'a record left behind after PE deletion becomes a stale answer'
        }
    }
}
