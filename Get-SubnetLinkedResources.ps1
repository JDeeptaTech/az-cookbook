<#
.SYNOPSIS
  Lists every resource linked to every subnet in one or more subscriptions (read-only).

  Covers:
    - IP configurations: NICs (resolved to VM / private endpoint / private link service / orphan NIC),
      load balancer frontends, VPN/ER gateways, Azure Firewall, Bastion, etc.
    - Application Gateway IP configurations
    - Private endpoints
    - Service association links and resource navigation links (SQL MI, App Service VNet integration,
      DNS Private Resolver, APIM, Databricks, ...)
    - Delegations
    - Container group network profiles
    - Optionally (-IncludeAssociations): NSG, route table, NAT gateway, service endpoints

.EXAMPLE
  # Everything in Prod, exported to CSV
  ./Get-SubnetLinkedResources.ps1 -SubscriptionId 50fd3e3b-7896-430c-97c0-27aa4984f50a

  # Only subnets inside the overlapping range, on one VNet
  ./Get-SubnetLinkedResources.ps1 -SubscriptionId 50fd3e3b-7896-430c-97c0-27aa4984f50a `
      -VnetName Brewin-Azure-Prod-Vnet -OverlapsCidr 10.250.192.0/20 -IncludeEmptySubnets

  # Several subscriptions, including NSG / route table associations
  ./Get-SubnetLinkedResources.ps1 -SubscriptionId sub1,sub2 -IncludeAssociations
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$SubscriptionId,
    [string]$VnetName,                 # optional: limit to one VNet
    [string]$OverlapsCidr,             # optional: only subnets overlapping this CIDR
    [switch]$IncludeAssociations,      # NSG, route table, NAT gateway, service endpoints
    [switch]$IncludeEmptySubnets,      # emit a row for subnets with nothing attached
    [switch]$PassThru,                 # also return the objects to the pipeline
    [string]$OutCsv = (Join-Path (Get-Location) "subnet-linked-resources-$(Get-Date -Format yyyyMMdd-HHmm).csv")
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region helpers ----------------------------------------------------------------
function Write-Step([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Wn([string]$m)   { Write-Host "    [WARN] $m" -ForegroundColor Yellow }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & az @AzArgs --only-show-errors -o json 2>$errFile; $code = $LASTEXITCODE; $err = Get-Content $errFile -Raw
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw "az $($AzArgs -join ' ') failed (exit $code): $err" }
    $text = ($out -join "`n")
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Json)
}

# Null-safe property read (az omits empty properties; StrictMode would throw).
function P($Obj, [string]$Name) {
    if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

# Parse an ARM ID into its top-level resource (child segments are ignored).
function Split-ArmId([string]$Id) {
    $p = $Id.Trim('/') -split '/'
    [pscustomobject]@{
        Subscription  = $p[1]
        ResourceGroup = $p[3]
        Type          = if ($p.Count -ge 7) { "$($p[5])/$($p[6])" } else { $null }
        Name          = if ($p.Count -ge 8) { $p[7] } else { $null }
        Child         = if ($p.Count -ge 10) { $p[9] } else { $null }
    }
}

function Get-CidrRange([string]$Cidr) {
    $ip, $len = $Cidr.Split('/')
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes(); [array]::Reverse($b)
    $a = [uint64][BitConverter]::ToUInt32($b, 0); $s = [uint64][math]::Pow(2, 32 - [int]$len)
    $st = [uint64]([math]::Floor($a / $s) * $s)
    [pscustomobject]@{ Start = $st; End = $st + $s - 1 }
}
function Test-CidrOverlap([string]$A, [string]$B) {
    $x = Get-CidrRange $A; $y = Get-CidrRange $B
    return ($x.Start -le $y.End -and $y.Start -le $x.End)
}
#endregion

$rows = [System.Collections.Generic.List[object]]::new()

foreach ($sub in $SubscriptionId) {
    $subName = (Invoke-Az -AzArgs @('account','show','--subscription',$sub))[0].name
    Write-Step "Subscription: $subName ($sub)"

    # One call for all NICs in the subscription, indexed by IP config ID.
    # This avoids one az call per NIC, which is slow on large subscriptions.
    Write-Host '    Loading NICs...'
    $nicByIpConfig = @{}
    foreach ($nic in Invoke-Az -AzArgs @('network','nic','list','--subscription',$sub)) {
        $vm  = P (P $nic 'virtualMachine') 'id'
        $pe  = P (P $nic 'privateEndpoint') 'id'
        $pls = P (P $nic 'privateLinkService') 'id'
        foreach ($ipc in @(P $nic 'ipConfigurations')) {
            if (-not $ipc) { continue }
            $nicByIpConfig[$ipc.id.ToLower()] = [pscustomobject]@{
                NicName = $nic.name; NicRg = $nic.resourceGroup; PrivateIp = (P $ipc 'privateIPAddress')
                OwnerId = if ($vm) { $vm } elseif ($pe) { $pe } elseif ($pls) { $pls } else { $null }
            }
        }
    }

    $vnets = Invoke-Az -AzArgs @('network','vnet','list','--subscription',$sub,'--query','[].{name:name,rg:resourceGroup}')
    if ($VnetName) { $vnets = @($vnets | Where-Object { $_.name -eq $VnetName }) }
    if (-not $vnets) { Write-Wn 'No matching VNets'; continue }

    foreach ($vnet in $vnets) {
        Write-Host "    VNet: $($vnet.name)"
        $subnets = Invoke-Az -AzArgs @('network','vnet','subnet','list','--subscription',$sub,'-g',$vnet.rg,'--vnet-name',$vnet.name)

        foreach ($sn in $subnets) {
            $prefixes = @(@(P $sn 'addressPrefix') + @(P $sn 'addressPrefixes') | Where-Object { $_ } | Select-Object -Unique)
            if ($OverlapsCidr) {
                $hit = $prefixes | Where-Object { $_ -notmatch ':' -and (Test-CidrOverlap $_ $OverlapsCidr) }
                if (-not $hit) { continue }
            }

            $base = [ordered]@{
                Subscription = $subName; VNet = $vnet.name; Subnet = $sn.name; SubnetPrefix = ($prefixes -join ';')
            }
            $seenOwners = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $before = $rows.Count

            $add = {
                param($LinkType, $ResourceType, $ResourceName, $ResourceGroup, $PrivateIp, $Detail, $ResourceId)
                $o = [ordered]@{}
                foreach ($k in $base.Keys) { $o[$k] = $base[$k] }
                $o.LinkType = $LinkType; $o.ResourceType = $ResourceType; $o.ResourceName = $ResourceName
                $o.ResourceGroup = $ResourceGroup; $o.PrivateIp = $PrivateIp; $o.Detail = $Detail; $o.ResourceId = $ResourceId
                $rows.Add([pscustomobject]$o)
            }

            # 1. IP configurations (NICs, LB frontends, gateways, firewall, bastion, ...)
            foreach ($ipc in @(P $sn 'ipConfigurations')) {
                if (-not $ipc) { continue }
                $id = $ipc.id
                $parsed = Split-ArmId $id
                $nicInfo = $nicByIpConfig[$id.ToLower()]
                if ($parsed.Type -ieq 'Microsoft.Network/networkInterfaces') {
                    if ($nicInfo -and $nicInfo.OwnerId) {
                        $owner = Split-ArmId $nicInfo.OwnerId
                        [void]$seenOwners.Add($nicInfo.OwnerId)
                        & $add 'NIC' $owner.Type $owner.Name $owner.ResourceGroup $nicInfo.PrivateIp "NIC: $($nicInfo.NicName)" $nicInfo.OwnerId
                    } else {
                        $ip = if ($nicInfo) { $nicInfo.PrivateIp } else { $null }
                        & $add 'NIC' 'Microsoft.Network/networkInterfaces' $parsed.Name $parsed.ResourceGroup $ip 'Unattached NIC (no VM/PE/PLS)' ($id -replace '/ipConfigurations/.*$','')
                    }
                } else {
                    $parentId = "/subscriptions/$($parsed.Subscription)/resourceGroups/$($parsed.ResourceGroup)/providers/$($parsed.Type)/$($parsed.Name)"
                    [void]$seenOwners.Add($parentId)
                    & $add 'IPConfiguration' $parsed.Type $parsed.Name $parsed.ResourceGroup $null "ipconfig: $($parsed.Child)" $parentId
                }
            }

            # 2. Application Gateway
            foreach ($agw in @(P $sn 'applicationGatewayIPConfigurations')) {
                if (-not $agw) { continue }
                $parsed = Split-ArmId $agw.id
                & $add 'AppGatewayIPConfig' $parsed.Type $parsed.Name $parsed.ResourceGroup $null $null ($agw.id -replace '/gatewayIPConfigurations/.*$','')
            }

            # 3. Private endpoints not already reported through their NIC
            foreach ($pe in @(P $sn 'privateEndpoints')) {
                if (-not $pe -or $seenOwners.Contains($pe.id)) { continue }
                $parsed = Split-ArmId $pe.id
                & $add 'PrivateEndpoint' $parsed.Type $parsed.Name $parsed.ResourceGroup $null $null $pe.id
            }

            # 4. Service association / resource navigation links (SQL MI, App Service, DNS resolver, ...)
            foreach ($kind in 'serviceAssociationLinks','resourceNavigationLinks') {
                foreach ($l in @(P $sn $kind)) {
                    if (-not $l) { continue }
                    $linked = P $l 'link'
                    $parsed = if ($linked) { Split-ArmId $linked } else { $null }
                    & $add $kind (P $l 'linkedResourceType') (P $parsed 'Name') (P $parsed 'ResourceGroup') $null $l.name $linked
                }
            }

            # 5. Delegations
            foreach ($d in @(P $sn 'delegations')) {
                if (-not $d) { continue }
                & $add 'Delegation' (P $d 'serviceName') $null $null $null 'Subnet delegated' $null
            }

            # 6. Container group network profiles
            foreach ($cp in @(P $sn 'ipConfigurationProfiles')) {
                if (-not $cp) { continue }
                $parsed = Split-ArmId $cp.id
                & $add 'NetworkProfile' $parsed.Type $parsed.Name $parsed.ResourceGroup $null $null $cp.id
            }

            # 7. Optional associations
            if ($IncludeAssociations) {
                foreach ($pair in @(@('networkSecurityGroup','NSG'), @('routeTable','RouteTable'), @('natGateway','NatGateway'))) {
                    $aid = P (P $sn $pair[0]) 'id'
                    if ($aid) { $parsed = Split-ArmId $aid; & $add $pair[1] $parsed.Type $parsed.Name $parsed.ResourceGroup $null $null $aid }
                }
                foreach ($se in @(P $sn 'serviceEndpoints')) {
                    if ($se) { & $add 'ServiceEndpoint' (P $se 'service') $null $null $null (@(P $se 'locations') -join ',') $null }
                }
            }

            if ($rows.Count -eq $before -and $IncludeEmptySubnets) {
                & $add '(empty)' $null $null $null $null 'Nothing attached' $null
            }
        }
    }
}

#region output -----------------------------------------------------------------
if ($rows.Count -eq 0) { Write-Wn 'No linked resources found for the given filters.'; return }

$rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8
Write-Step "Exported $($rows.Count) rows to $OutCsv"

Write-Step 'Per-subnet summary (excluding NSG/route table/service endpoint/empty rows)'
$rows | Where-Object { $_.LinkType -notin 'NSG','RouteTable','NatGateway','ServiceEndpoint','(empty)' } |
    Group-Object VNet, Subnet, SubnetPrefix |
    Sort-Object Count -Descending |
    Select-Object @{n='VNet/Subnet/Prefix';e={$_.Name}}, Count |
    Format-Table -AutoSize

$rows | Select-Object VNet, Subnet, SubnetPrefix, LinkType, ResourceType, ResourceName, PrivateIp, Detail |
    Format-Table -AutoSize -Wrap

# -PassThru returns the objects for piping, e.g. ... -PassThru | Where-Object ResourceType -like '*virtualMachines'
if ($PassThru) { $rows }
#endregion
