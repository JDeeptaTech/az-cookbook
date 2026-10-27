<#
.SYNOPSIS
  Removes one or more address prefixes from a VNet's address space using az CLI, then re-syncs all
  peerings (both ends). Supports -DryRun and -Revert (re-adds the original address space from the state file).

.DESCRIPTION
  Pre-flight (read-only, also runs in -DryRun):
    - VNet exists and the prefixes are on it
    - not removing every prefix
    - no subnet uses any of the prefixes (Azure rejects the update otherwise)
    - VPN/ER gateway present -> warning: the change is re-advertised to on-prem
    - activity log: who wrote to the VNet recently (helps confirm why the prefix was added)

  Revert pre-flight:
    - blocks if a peered VNet now uses an overlapping range (Azure would reject the re-add). Revert that
      peering first, e.g. ./New-VnetPeering.ps1 ... -Revert

.EXAMPLE
  ./Remove-VnetAddressPrefix.ps1 -VnetName Brewin-Azure-Prod-Vnet `
      -SubscriptionId 50fd3e3b-7896-430c-97c0-27aa4984f50a -Prefix 10.250.192.0/20 -DryRun

  ./Remove-VnetAddressPrefix.ps1 -VnetName Brewin-Azure-Prod-Vnet `
      -SubscriptionId 50fd3e3b-7896-430c-97c0-27aa4984f50a -Revert -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VnetName,
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$ResourceGroup,
    [string[]]$Prefix,                 # required for removal, ignored for -Revert
    [switch]$SkipPeeringSync,
    [int]$ActivityLogDays = 90,
    [switch]$Revert,
    [switch]$DryRun,
    [switch]$Force,
    [string]$StateDir = (Join-Path $PSScriptRoot 'state')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:Plan = [System.Collections.Generic.List[object]]::new()

#region helpers ----------------------------------------------------------------
function Write-Step([string]$m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "    [OK]   $m" -ForegroundColor Green }
function Write-Wn([string]$m)   { Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Dry([string]$m)  { Write-Host "    [DRY]  $m" -ForegroundColor Magenta }

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$Json)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out = & az @AzArgs --only-show-errors 2>$errFile; $code = $LASTEXITCODE; $err = Get-Content $errFile -Raw
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw "az $($AzArgs -join ' ') failed (exit $code): $err" }
    $text = ($out -join "`n")
    if ($Json) { if ([string]::IsNullOrWhiteSpace($text)) { return $null }; return ($text | ConvertFrom-Json) }
    $text
}

function Invoke-Change([string]$Description, [string[]]$AzArgs) {
    $cmd = 'az ' + (($AzArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
    $script:Plan.Add([pscustomobject]@{ Action = $Description; Command = $cmd })
    if ($DryRun) { Write-Dry "Would $Description"; Write-Host "           $cmd" -ForegroundColor DarkGray; return }
    Invoke-Az -AzArgs $AzArgs | Out-Null
    Write-Ok "Done: $Description"
}

function P($Obj, [string]$Name) { if ($null -ne $Obj -and $Obj.PSObject.Properties[$Name]) { $Obj.$Name } }

function Get-CidrRange([string]$Cidr) {
    $ip, $len = $Cidr.Split('/')
    $b = [System.Net.IPAddress]::Parse($ip).GetAddressBytes(); [array]::Reverse($b)
    $a = [uint64][BitConverter]::ToUInt32($b, 0); $s = [uint64][math]::Pow(2, 32 - [int]$len)
    $st = [uint64]([math]::Floor($a / $s) * $s)
    [pscustomobject]@{ Start = $st; End = $st + $s - 1 }
}
function Test-CidrOverlap([string]$A, [string]$B) {
    if ($A -match ':' -or $B -match ':') { return $false }
    $x = Get-CidrRange $A; $y = Get-CidrRange $B
    return ($x.Start -le $y.End -and $y.Start -le $x.End)
}

function Confirm-Proceed([string]$What) {
    if ($DryRun -or $Force) { return }
    if ((Read-Host "`nType 'yes' to $What") -ne 'yes') { Write-Wn 'Aborted. Nothing changed.'; exit 1 }
}

function Write-PlanSummary([string]$Mode) {
    Write-Step "$Mode summary: $(if ($DryRun) { 'DRY RUN, nothing was changed' } else { 'executed' })"
    if ($script:Plan.Count -eq 0) { Write-Ok 'No changes'; return }
    $script:Plan | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}

function Get-Peerings {
    @(Invoke-Az -Json -AzArgs @('network','vnet','peering','list','--ids',$vnet.id)) | Where-Object { $_ }
}

# Sync every peering on this VNet, and the matching peering on each remote VNet.
function Sync-AllPeerings {
    if ($SkipPeeringSync) { Write-Wn 'Peering sync skipped (-SkipPeeringSync)'; return }
    Write-Step 'Syncing peerings (local side, then remote side)'
    $failures = @()
    foreach ($p in Get-Peerings) {
        try {
            Invoke-Change "sync local peering '$($p.name)'" @('network','vnet','peering','sync','--subscription',$SubscriptionId,
                '-g',$vnet.resourceGroup,'--vnet-name',$vnet.name,'-n',$p.name)
        } catch { $failures += "local '$($p.name)': $_" }

        $rid = $p.remoteVirtualNetwork.id -split '/'
        $rSub, $rRg, $rVnet = $rid[2], $rid[4], $rid[8]
        try {
            $back = @(Invoke-Az -Json -AzArgs @('network','vnet','peering','list','--subscription',$rSub,'-g',$rRg,'--vnet-name',$rVnet)) |
                    Where-Object { $_ -and $_.remoteVirtualNetwork.id -ieq $vnet.id } | Select-Object -First 1
            if (-not $back) { $failures += "remote '$rVnet': no peering back to this VNet"; continue }
            Invoke-Change "sync remote peering '$($back.name)' on '$rVnet'" @('network','vnet','peering','sync','--subscription',$rSub,
                '-g',$rRg,'--vnet-name',$rVnet,'-n',$back.name)
        } catch { $failures += "remote '$rVnet' (sub $rSub): $_" }
    }
    if ($failures) {
        Write-Wn 'Some syncs failed. They need Network Contributor on that side (e.g. cross-tenant VNets):'
        $failures | ForEach-Object { Write-Wn "  $_" }
    } elseif (-not $DryRun) { Write-Ok 'All peerings synced' }
}
#endregion

if ($DryRun) { Write-Host "`n*** DRY RUN: read-only. Nothing will be changed. ***" -ForegroundColor Magenta }

#region load -------------------------------------------------------------------
Write-Step 'Loading VNet'
$me = Invoke-Az -AzArgs @('account','show','--query','user.name','-o','tsv')
if ($ResourceGroup) {
    $vnet = Invoke-Az -Json -AzArgs @('network','vnet','show','--subscription',$SubscriptionId,'-g',$ResourceGroup,'-n',$VnetName)
} else {
    $ids = @(Invoke-Az -Json -AzArgs @('network','vnet','list','--subscription',$SubscriptionId,'--query',"[?name=='$VnetName'].id"))
    if ($ids.Count -ne 1) { throw "Expected 1 VNet named '$VnetName' in $SubscriptionId, found $($ids.Count). Pass -ResourceGroup." }
    $vnet = Invoke-Az -Json -AzArgs @('network','vnet','show','--ids',$ids[0])
}
$current   = @($vnet.addressSpace.addressPrefixes)
$stateFile = Join-Path $StateDir ("addressspace-{0}.json" -f $vnet.name)
Write-Ok "$($vnet.name) [$($vnet.resourceGroup)] signed in as $me"
Write-Ok "Current address space: $($current -join ', ')"
#endregion

#region REVERT -----------------------------------------------------------------
if ($Revert) {
    if (-not (Test-Path $stateFile)) { throw "No state file at $stateFile, so the original address space is unknown." }
    $state    = Get-Content $stateFile -Raw | ConvertFrom-Json
    $original = @($state.originalPrefixes)
    Write-Ok "State: changed $($state.changedAt) by $($state.by). Original: $($original -join ', ')"

    $toReAdd = @($original | Where-Object { $_ -notin $current })
    if (-not $toReAdd.Count) { Write-Ok 'Already matches the original. Nothing to revert.'; return }
    Write-Ok "Would re-add: $($toReAdd -join ', ')"

    Write-Step 'Checking peered VNets for ranges that now overlap'
    $blockers = foreach ($p in Get-Peerings) {
        $remote = @(P (P $p 'remoteVirtualNetworkAddressSpace') 'addressPrefixes') + @(P (P $p 'remoteAddressSpace') 'addressPrefixes') |
                  Where-Object { $_ } | Select-Object -Unique
        foreach ($r in $remote) { foreach ($x in $toReAdd) { if (Test-CidrOverlap $r $x) { "$($p.name) -> $r overlaps $x" } } }
    }
    if ($blockers) {
        throw "Cannot re-add. Peered VNets use overlapping ranges: $($blockers -join '; '). Revert those peerings first (New-VnetPeering.ps1 -Revert)."
    }
    Write-Ok 'No conflicts'

    $target = @($current + $toReAdd | Select-Object -Unique)
    Confirm-Proceed "set the address space of $($vnet.name) to: $($target -join ', ')"
    Invoke-Change "restore address space to: $($target -join ', ')" (@('network','vnet','update','--ids',$vnet.id,'--address-prefixes') + $target)
    Sync-AllPeerings
    if (-not $DryRun) { Remove-Item $stateFile; Write-Ok 'Revert complete' }
    Write-PlanSummary 'Revert'
    return
}
#endregion

#region REMOVE pre-flight ------------------------------------------------------
if (-not $Prefix) { throw '-Prefix is required (unless using -Revert).' }

$toRemove = @($Prefix | Where-Object { $_ -in $current })
$Prefix | Where-Object { $_ -notin $current } | ForEach-Object { Write-Wn "$_ is not on the VNet, skipping" }
if (-not $toRemove.Count) { Write-Ok 'Nothing to remove.'; return }

$remaining = @($current | Where-Object { $_ -notin $toRemove })
if (-not $remaining.Count) { throw 'Refusing to remove every prefix from the VNet.' }

Write-Step "Checking that no subnet uses $($toRemove -join ', ')"
$blocking = foreach ($s in @($vnet.subnets)) {
    if (-not $s) { continue }
    $sp = @(@(P $s 'addressPrefix') + @(P $s 'addressPrefixes') | Where-Object { $_ })
    foreach ($x in $sp) { foreach ($r in $toRemove) { if (Test-CidrOverlap $x $r) { "$($s.name) ($x)" } } }
}
if ($blocking) { throw "Subnets use the prefix(es) and must be migrated or deleted first: $($blocking -join ', ')" }
Write-Ok 'No subnets in range'

$gw = @($vnet.subnets) | Where-Object { $_ -and $_.name -eq 'GatewaySubnet' } | Select-Object -First 1
if ($gw -and (@(P $gw 'ipConfigurations') | Where-Object { $_ })) {
    Write-Wn 'This VNet has a VPN/ER gateway. The removed prefix(es) will be withdrawn from on-prem BGP. Tell the network team.'
}

Write-Step "Recent writes to this VNet (last $ActivityLogDays days)"
try {
    $writes = @(Invoke-Az -Json -AzArgs @('monitor','activity-log','list','--resource-id',$vnet.id,'--offset',"$($ActivityLogDays)d",
        '--query',"[?operationName.value=='Microsoft.Network/virtualNetworks/write' && status.value=='Succeeded'].{time:eventTimestamp,caller:caller}"))
    if (@($writes | Where-Object { $_ }).Count) { $writes | Sort-Object time | ForEach-Object { Write-Host "    $($_.time)  $($_.caller)" } }
    else { Write-Wn 'None in the window' }
} catch { Write-Wn "Could not read activity log: $_" }

Write-Step 'Plan'
Write-Host "    Before : $($current -join ', ')"
Write-Host "    After  : $($remaining -join ', ')"
#endregion

#region REMOVE execute ---------------------------------------------------------
Confirm-Proceed "remove $($toRemove -join ', ') from $($vnet.name)"

if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    @{ changedAt = (Get-Date).ToString('o'); by = $me; vnetId = $vnet.id; originalPrefixes = $current; removed = $toRemove } |
        ConvertTo-Json | Set-Content $stateFile
    Write-Ok "State saved: $stateFile"
}

# Set the full desired list; removing by index is fragile.
Invoke-Change "set address space to: $($remaining -join ', ')" (@('network','vnet','update','--ids',$vnet.id,'--address-prefixes') + $remaining)
Sync-AllPeerings
Write-PlanSummary 'Remove'
if (-not $DryRun) {
    Write-Host "Revert: ./Remove-VnetAddressPrefix.ps1 -VnetName $($vnet.name) -SubscriptionId $SubscriptionId -Revert -DryRun"
}
#endregion
