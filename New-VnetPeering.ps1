<#
.SYNOPSIS
  Creates a bidirectional VNet peering between any two VNets (same or different subscriptions)
  using az CLI, with pre-flight checks, -DryRun, automatic revert on failure and a manual -Revert mode.

.DESCRIPTION
  Pre-flight (read-only, also runs in -DryRun):
    - az login and access to both subscriptions
    - resolves each VNet by name (pass -VnetXResourceGroup if the name is not unique in the subscription)
    - address space overlap between the two VNets (Azure rejects overlapping peerings)
    - existing peering between the two VNets, or a name clash
    - gateway-mode sanity (the VNet using remote gateways must not have its own; the other must have one)
    - out-of-sync peerings on either VNet (informational)

  Deploy: creates both sides (the gateway-provider side first when gateway transit is used), waits for
  Connected / FullyInSync, writes a state file. Any failure deletes whatever this run created.

  Revert: deletes both peerings, using the state file if present. A peering is only deleted if its
  remote VNet ID matches the expected VNet, so a same-named peering to another VNet is never touched.

.EXAMPLE
  # Prod <-> CCoE transit (DNS Private Resolver)
  ./New-VnetPeering.ps1 `
     -VnetAName Brewin-Azure-Prod-Vnet               -VnetASubscription 50fd3e3b-7896-430c-97c0-27aa4984f50a `
     -VnetBName p-prod-ccoe-brz8-transit-vnet-weu-1  -VnetBSubscription 20be150d-f08a-4594-9260-958582967ba0 `
     -DryRun

.EXAMPLE
  # Revert the same pair (dry run first)
  ./New-VnetPeering.ps1 -VnetAName Brewin-Azure-Prod-Vnet -VnetASubscription <subA> `
     -VnetBName p-prod-ccoe-brz8-transit-vnet-weu-1 -VnetBSubscription <subB> -Revert -DryRun
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VnetAName,
    [Parameter(Mandatory)][string]$VnetASubscription,
    [string]$VnetAResourceGroup,

    [Parameter(Mandatory)][string]$VnetBName,
    [Parameter(Mandatory)][string]$VnetBSubscription,
    [string]$VnetBResourceGroup,

    [string]$PeeringNameAtoB,
    [string]$PeeringNameBtoA,

    # None          : no gateway transit (default, safest)
    # AUsesBGateway : A uses B's VPN/ER gateway  (B: allow-gateway-transit, A: use-remote-gateways)
    # BUsesAGateway : B uses A's VPN/ER gateway
    [ValidateSet('None','AUsesBGateway','BUsesAGateway')]
    [string]$GatewayMode = 'None',

    [bool]$AllowForwardedTraffic = $true,

    [switch]$Revert,
    [switch]$DryRun,
    [switch]$Force,
    [int]$ConnectTimeoutSeconds = 300,
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

# Every mutating call goes through here, so -DryRun cannot change anything.
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
    $x = Get-CidrRange $A; $y = Get-CidrRange $B
    return ($x.Start -le $y.End -and $y.Start -le $x.End)
}

function Resolve-Vnet([string]$Sub, [string]$Name, [string]$Rg) {
    if ($Rg) { return Invoke-Az -Json -AzArgs @('network','vnet','show','--subscription',$Sub,'-g',$Rg,'-n',$Name) }
    $ids = @(Invoke-Az -Json -AzArgs @('network','vnet','list','--subscription',$Sub,'--query',"[?name=='$Name'].id"))
    if ($ids.Count -eq 0) { throw "VNet '$Name' not found in subscription $Sub" }
    if ($ids.Count -gt 1) { throw "Several VNets named '$Name' in $Sub. Pass the resource group: $($ids -join ', ')" }
    Invoke-Az -Json -AzArgs @('network','vnet','show','--ids',$ids[0])
}

function Get-Ipv4Prefixes($Vnet) { @(P (P $Vnet 'addressSpace') 'addressPrefixes' | Where-Object { $_ -and $_ -notmatch ':' }) }

function Test-HasGateway($Vnet) {
    $gs = @(P $Vnet 'subnets') | Where-Object { $_ -and $_.name -eq 'GatewaySubnet' } | Select-Object -First 1
    return [bool]($gs -and (@(P $gs 'ipConfigurations') | Where-Object { $_ }))
}

function Get-PeeringList([string]$Sub, [string]$Rg, [string]$Vnet) {
    @(Invoke-Az -Json -AzArgs @('network','vnet','peering','list','--subscription',$Sub,'-g',$Rg,'--vnet-name',$Vnet)) | Where-Object { $_ }
}
function Get-Peering($Side) {
    Get-PeeringList $Side.Sub $Side.Rg $Side.Vnet | Where-Object { $_.name -eq $Side.Name } | Select-Object -First 1
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

function Get-SafeName([string]$n) { ($n -replace '[^A-Za-z0-9_.-]', '-').Substring(0, [math]::Min(80, $n.Length)) }

# Deletes peerings in the given order, only when the remote VNet ID matches what is expected.
function Invoke-RevertPlan($Sides, [string]$Label) {
    Write-Step "$Label"
    $failed = $false
    foreach ($s in $Sides) {
        try {
            $peer = Get-Peering $s
            if (-not $peer) { Write-Ok "'$($s.Name)' on '$($s.Vnet)' not present, nothing to remove"; continue }
            Write-Ok "'$($s.Name)' on '$($s.Vnet)': state=$($peer.peeringState) sync=$($peer.peeringSyncLevel)"
            if ($peer.remoteVirtualNetwork.id -ine $s.RemoteId) {
                Write-Wn "'$($s.Name)' points at $($peer.remoteVirtualNetwork.id), not $($s.RemoteId). Skipping it."
                $failed = $true; continue
            }
            Invoke-Change "delete peering '$($s.Name)' on '$($s.Vnet)'" `
                @('network','vnet','peering','delete','--subscription',$s.Sub,'-g',$s.Rg,'--vnet-name',$s.Vnet,'-n',$s.Name)
        } catch { $failed = $true; Write-Wn "Failed on '$($s.Name)': $_" }
    }
    if ($failed) { throw "$Label incomplete. Review the warnings and clean up manually." }
}
#endregion

if ($DryRun) { Write-Host "`n*** DRY RUN: read-only. Nothing will be created or deleted. ***" -ForegroundColor Magenta }

#region common pre-flight ------------------------------------------------------
Write-Step 'Checking az login and subscription access'
$me = Invoke-Az -AzArgs @('account','show','--query','user.name','-o','tsv')
Write-Ok "Signed in as $me"
foreach ($s in ($VnetASubscription, $VnetBSubscription | Select-Object -Unique)) {
    Write-Ok ('Access to: ' + (Invoke-Az -AzArgs @('account','show','--subscription',$s,'--query','name','-o','tsv')))
}

Write-Step 'Resolving VNets'
$vA = Resolve-Vnet $VnetASubscription $VnetAName $VnetAResourceGroup
$vB = Resolve-Vnet $VnetBSubscription $VnetBName $VnetBResourceGroup
if ($vA.id -ieq $vB.id) { throw 'VNet A and VNet B are the same VNet.' }
$pA = Get-Ipv4Prefixes $vA; $pB = Get-Ipv4Prefixes $vB
Write-Ok "A: $($vA.name) [$($vA.resourceGroup)] $($pA -join ', ')"
Write-Ok "B: $($vB.name) [$($vB.resourceGroup)] $($pB -join ', ')"

if (-not $PeeringNameAtoB) { $PeeringNameAtoB = Get-SafeName "$($vA.name)-to-$($vB.name)" }
if (-not $PeeringNameBtoA) { $PeeringNameBtoA = Get-SafeName "$($vB.name)-to-$($vA.name)" }

$sideA = [pscustomobject]@{ Sub = $VnetASubscription; Rg = $vA.resourceGroup; Vnet = $vA.name; Name = $PeeringNameAtoB; RemoteId = $vB.id }
$sideB = [pscustomobject]@{ Sub = $VnetBSubscription; Rg = $vB.resourceGroup; Vnet = $vB.name; Name = $PeeringNameBtoA; RemoteId = $vA.id }

$stateFile = Join-Path $StateDir ("peering-{0}--{1}.json" -f $vA.name, $vB.name)
#endregion

#region REVERT -----------------------------------------------------------------
if ($Revert) {
    $sides = @($sideA, $sideB)
    if (Test-Path $stateFile) {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
        Write-Ok "State file: created $($state.createdAt) by $($state.by)"
        # Delete in reverse creation order, using the names that were actually created.
        $sides = @(@($state.sides) | ForEach-Object {
            [pscustomobject]@{ Sub = $_.Sub; Rg = $_.Rg; Vnet = $_.Vnet; Name = $_.Name; RemoteId = $_.RemoteId }
        })
        [array]::Reverse($sides)
    } else {
        Write-Wn "No state file ($stateFile). Using peering names: '$PeeringNameAtoB' / '$PeeringNameBtoA'"
    }

    # Read-only plan first, then confirm, then execute.
    $real = $DryRun; $DryRun = $true
    Invoke-RevertPlan $sides 'Revert plan'
    $DryRun = $real
    if ($script:Plan.Count -eq 0 -or $DryRun) { Write-PlanSummary 'Revert'; return }

    Confirm-Proceed 'delete the peering(s) listed above'
    $script:Plan.Clear()
    Invoke-RevertPlan $sides 'Reverting'
    if (Test-Path $stateFile) { Remove-Item $stateFile }
    Write-PlanSummary 'Revert'
    return
}
#endregion

#region DEPLOY pre-flight ------------------------------------------------------
Write-Step 'Checking address space overlap'
$overlaps = @(foreach ($a in $pA) { foreach ($b in $pB) { if (Test-CidrOverlap $a $b) { "$a <-> $b" } } })
if ($overlaps.Count) { throw "Address spaces overlap, peering is not possible: $($overlaps -join '; ')" }
Write-Ok 'No overlap'

Write-Step 'Checking for existing peerings'
$listA = Get-PeeringList $sideA.Sub $sideA.Rg $sideA.Vnet
$listB = Get-PeeringList $sideB.Sub $sideB.Rg $sideB.Vnet
$dupes = @($listA | Where-Object { $_.remoteVirtualNetwork.id -ieq $vB.id -or $_.name -eq $sideA.Name }) +
         @($listB | Where-Object { $_.remoteVirtualNetwork.id -ieq $vA.id -or $_.name -eq $sideB.Name })
if ($dupes.Count) { throw "Existing peering or name clash, not touching it: $(($dupes | ForEach-Object name) -join ', ')" }
Write-Ok 'None found'

Write-Step 'Checking gateway configuration'
$gwA = Test-HasGateway $vA; $gwB = Test-HasGateway $vB
Write-Ok "Gateway in A: $gwA, gateway in B: $gwB, mode: $GatewayMode"
switch ($GatewayMode) {
    'AUsesBGateway' { if (-not $gwB) { throw 'AUsesBGateway: B has no gateway' }; if ($gwA) { throw 'AUsesBGateway: A has its own gateway, so it cannot use a remote one' } }
    'BUsesAGateway' { if (-not $gwA) { throw 'BUsesAGateway: A has no gateway' }; if ($gwB) { throw 'BUsesAGateway: B has its own gateway, so it cannot use a remote one' } }
    'None'          { if ($gwA -or $gwB) { Write-Ok 'Gateway transit off: on-prem routes are not shared over this peering' } }
}

Write-Step 'Out-of-sync peerings (informational, not changed)'
$unsynced = @(@($listA) + @($listB) | Where-Object { $_ -and $_.peeringSyncLevel -ne 'FullyInSync' })
if ($unsynced.Count) { $unsynced | ForEach-Object { Write-Wn "$($_.name): $($_.peeringSyncLevel)" } } else { Write-Ok 'All in sync' }
#endregion

#region DEPLOY plan / execute --------------------------------------------------
$fwd = $AllowForwardedTraffic.ToString().ToLower()
function Get-CreateArgs($Side, [bool]$AllowTransit, [bool]$UseRemote) {
    @('network','vnet','peering','create','--subscription',$Side.Sub,'-g',$Side.Rg,'--vnet-name',$Side.Vnet,'-n',$Side.Name,
      '--remote-vnet',$Side.RemoteId,'--allow-vnet-access','true','--allow-forwarded-traffic',$fwd,
      '--allow-gateway-transit',$AllowTransit.ToString().ToLower(),'--use-remote-gateways',$UseRemote.ToString().ToLower())
}
$argsA = Get-CreateArgs $sideA ($GatewayMode -eq 'BUsesAGateway') ($GatewayMode -eq 'AUsesBGateway')
$argsB = Get-CreateArgs $sideB ($GatewayMode -eq 'AUsesBGateway') ($GatewayMode -eq 'BUsesAGateway')

# The side offering gateway transit must exist before the side that uses remote gateways.
$order = if ($GatewayMode -eq 'AUsesBGateway') { @(@($sideB, $argsB), @($sideA, $argsA)) } else { @(@($sideA, $argsA), @($sideB, $argsB)) }

Write-Step 'Plan'
if ($DryRun) {
    foreach ($o in $order) { Invoke-Change "create peering '$($o[0].Name)' on '$($o[0].Vnet)'" $o[1] }
    Write-Dry "Would wait up to $ConnectTimeoutSeconds s for Connected / FullyInSync on both sides"
    Write-Dry "On failure, would delete whatever this run created; state file: $stateFile"
    Write-PlanSummary 'Deploy'
    return
}
foreach ($o in $order) { Write-Host "    create '$($o[0].Name)' on '$($o[0].Vnet)'" }
Confirm-Proceed "create both peerings between '$($vA.name)' and '$($vB.name)'"

$created = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($o in $order) {
        Invoke-Change "create peering '$($o[0].Name)' on '$($o[0].Vnet)'" $o[1]
        $created.Add($o[0])
    }

    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    @{ createdAt = (Get-Date).ToString('o'); by = $me; gatewayMode = $GatewayMode; sides = $created } |
        ConvertTo-Json -Depth 5 | Set-Content $stateFile
    Write-Ok "State saved: $stateFile"

    Write-Step 'Waiting for Connected / FullyInSync'
    $deadline = (Get-Date).AddSeconds($ConnectTimeoutSeconds)
    do {
        $a = Get-Peering $sideA; $b = Get-Peering $sideB
        $ok = $a -and $b -and $a.peeringState -eq 'Connected' -and $b.peeringState -eq 'Connected' -and
              $a.peeringSyncLevel -eq 'FullyInSync' -and $b.peeringSyncLevel -eq 'FullyInSync'
        if (-not $ok) { Write-Host "    A=$(P $a 'peeringState')/$(P $a 'peeringSyncLevel')  B=$(P $b 'peeringState')/$(P $b 'peeringSyncLevel')"; Start-Sleep 10 }
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { throw "Peering did not reach Connected/FullyInSync within $ConnectTimeoutSeconds s" }
    Write-Ok 'Both sides Connected and FullyInSync'
}
catch {
    Write-Wn "Deployment failed: $_"
    if ($created.Count) {
        $rev = @($created); [array]::Reverse($rev)
        Invoke-RevertPlan $rev 'AUTO-REVERT: deleting peerings created by this run'
        if (Test-Path $stateFile) { Remove-Item $stateFile }
    }
    throw
}

Write-PlanSummary 'Deploy'
Write-Host "Revert: ./New-VnetPeering.ps1 -VnetAName $($vA.name) -VnetASubscription $VnetASubscription -VnetBName $($vB.name) -VnetBSubscription $VnetBSubscription -Revert -DryRun"
#endregion
