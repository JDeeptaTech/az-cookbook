<#
.SYNOPSIS
  Creates (or rolls back) a bidirectional VNet peering between Brewin-Azure-Prod-Vnet and the CCoE
  transit VNet (p-prod-ccoe-brz8-transit-vnet-weu-1) using az CLI.

  Both modes support -DryRun:
    Deploy   -DryRun : runs every read-only pre-flight check, captures the DC's current route to the
                       resolver as a baseline, prints the exact az commands it would run and the
                       auto-rollback plan. Changes nothing.
    Rollback -DryRun : shows which peerings exist, their state, whether they are safe to delete
                       (remote VNet ID matches), and the exact delete commands. Changes nothing.

.EXAMPLE
  ./Set-ProdTransitPeering.ps1 -TransitResourceGroup <rg> -DryRun
  ./Set-ProdTransitPeering.ps1 -TransitResourceGroup <rg> -DcNicResourceGroup prd-c-bds-dc01-rg -DcNicName PRD-C-BDS-DC01_NIC1
  ./Set-ProdTransitPeering.ps1 -TransitResourceGroup <rg> -Rollback -DryRun
  ./Set-ProdTransitPeering.ps1 -TransitResourceGroup <rg> -Rollback
#>
[CmdletBinding()]
param(
    # Prod (local) side
    [string]$ProdSubscriptionId    = '50fd3e3b-7896-430c-97c0-27aa4984f50a',
    [string]$ProdResourceGroup     = 'ExpressRouteResourceGroup',
    [string]$ProdVnetName          = 'Brewin-Azure-Prod-Vnet',

    # Transit (remote) side
    [string]$TransitSubscriptionId = '20be150d-f08a-4594-9260-958582967ba0',
    [Parameter(Mandatory)]
    [string]$TransitResourceGroup,
    [string]$TransitVnetName       = 'p-prod-ccoe-brz8-transit-vnet-weu-1',

    # Peering names
    [string]$ProdToTransitName     = 'prod-weu-to-ccoe-transit-weu',
    [string]$TransitToProdName     = 'ccoe-transit-weu-to-prod-weu',

    # Optional: DC effective-route check (baseline before, validation after)
    [string]$ResolverIp            = '10.250.192.132',
    [string]$DcNicResourceGroup,
    [string]$DcNicName,

    [switch]$Rollback,
    [switch]$DryRun,
    [switch]$Force,                       # skip the interactive confirmation
    [int]$ConnectTimeoutSeconds    = 300,
    [string]$StateFile             = (Join-Path $PSScriptRoot 'peering-state.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:Plan = [System.Collections.Generic.List[object]]::new()

$ProdVnetId    = "/subscriptions/$ProdSubscriptionId/resourceGroups/$ProdResourceGroup/providers/Microsoft.Network/virtualNetworks/$ProdVnetName"
$TransitVnetId = "/subscriptions/$TransitSubscriptionId/resourceGroups/$TransitResourceGroup/providers/Microsoft.Network/virtualNetworks/$TransitVnetName"

# Rollback order: transit side first, then prod
$PeeringSides = @(
    [pscustomobject]@{ Side = 'transit'; Sub = $TransitSubscriptionId; Rg = $TransitResourceGroup; Vnet = $TransitVnetName; Name = $TransitToProdName; ExpectedRemote = $ProdVnetId }
    [pscustomobject]@{ Side = 'prod';    Sub = $ProdSubscriptionId;    Rg = $ProdResourceGroup;    Vnet = $ProdVnetName;    Name = $ProdToTransitName; ExpectedRemote = $TransitVnetId }
)

#region helpers ----------------------------------------------------------------

function Write-Step([string]$Msg) { Write-Host "`n==> $Msg" -ForegroundColor Cyan }
function Write-Ok([string]$Msg)   { Write-Host "    [OK]   $Msg" -ForegroundColor Green }
function Write-Wn([string]$Msg)   { Write-Host "    [WARN] $Msg" -ForegroundColor Yellow }
function Write-Dry([string]$Msg)  { Write-Host "    [DRY]  $Msg" -ForegroundColor Magenta }

# Read-only az calls. az does not throw on failure, so check the exit code and surface stderr.
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$AzArgs, [switch]$Json)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $out  = & az @AzArgs --only-show-errors 2>$errFile
        $code = $LASTEXITCODE
        $err  = Get-Content $errFile -Raw
    } finally { Remove-Item $errFile -ErrorAction SilentlyContinue }
    if ($code -ne 0) { throw "az $($AzArgs -join ' ') failed (exit $code): $err" }
    $text = ($out -join "`n")
    if ($Json) { if ([string]::IsNullOrWhiteSpace($text)) { return $null }; return $text | ConvertFrom-Json }
    return $text
}

# Every mutating call goes through here, so dry-run cannot accidentally change anything.
function Invoke-Change {
    param([Parameter(Mandatory)][string]$Description, [Parameter(Mandatory)][string[]]$AzArgs)
    $cmd = 'az ' + (($AzArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
    $script:Plan.Add([pscustomobject]@{ Action = $Description; Command = $cmd })
    if ($DryRun) {
        Write-Dry "Would $Description"
        Write-Host "           $cmd" -ForegroundColor DarkGray
        return
    }
    Invoke-Az -AzArgs $AzArgs | Out-Null
    Write-Ok "Done: $Description"
}

function Get-CidrRange([string]$Cidr) {
    $ip, $len = $Cidr.Split('/')
    $bytes = [System.Net.IPAddress]::Parse($ip).GetAddressBytes()
    [array]::Reverse($bytes)
    $addr  = [uint64][BitConverter]::ToUInt32($bytes, 0)
    $size  = [uint64][math]::Pow(2, 32 - [int]$len)
    $start = [uint64]([math]::Floor($addr / $size) * $size)
    [pscustomobject]@{ Start = $start; End = $start + $size - 1 }
}

function Test-IpInCidr([string]$Ip, [string]$Cidr) {
    $r = Get-CidrRange $Cidr
    $i = (Get-CidrRange "$Ip/32").Start
    return ($i -ge $r.Start -and $i -le $r.End)
}

function Get-PeeringList([string]$Sub, [string]$Rg, [string]$Vnet) {
    @(Invoke-Az -Json -AzArgs @('network','vnet','peering','list','--subscription',$Sub,'-g',$Rg,'--vnet-name',$Vnet))
}

function Get-Peering([string]$Sub, [string]$Rg, [string]$Vnet, [string]$Name) {
    Get-PeeringList $Sub $Rg $Vnet | Where-Object { $_.name -eq $Name } | Select-Object -First 1
}

function Get-DcRouteToResolver([string]$Label) {
    if (-not ($DcNicResourceGroup -and $DcNicName)) { return }
    Write-Step "$Label`: DC effective route to $ResolverIp (takes ~30-60s)"
    $routes = Invoke-Az -Json -AzArgs @('network','nic','show-effective-route-table','--subscription',$ProdSubscriptionId,
                                        '-g',$DcNicResourceGroup,'-n',$DcNicName)
    $best = @(foreach ($rt in $routes.value | Where-Object { $_.state -eq 'Active' }) {
        foreach ($p in $rt.addressPrefix) {
            if ($p -notmatch ':' -and (Test-IpInCidr $ResolverIp $p)) {
                [pscustomobject]@{ Prefix = $p; Len = [int]$p.Split('/')[1]; NextHop = $rt.nextHopType
                                   NextHopIp = ($rt.nextHopIpAddress -join ','); Source = $rt.source }
            }
        }
    }) | Sort-Object Len -Descending | Select-Object -First 1

    if ($best) { Write-Ok "Longest match: $($best.Prefix) -> $($best.NextHop) $($best.NextHopIp) [$($best.Source)]" }
    else       { Write-Wn "No active route covers $ResolverIp" }
    return $best
}

function Confirm-Proceed([string]$What) {
    if ($DryRun -or $Force) { return }
    $answer = Read-Host "`nType 'yes' to $What"
    if ($answer -ne 'yes') { Write-Wn 'Aborted by user. Nothing changed.'; exit 1 }
}

# Deletes only peerings whose remote VNet matches what this script would have created.
function Invoke-RollbackPlan([switch]$Automatic) {
    $label = if ($Automatic) { 'AUTO-ROLLBACK' } else { 'ROLLBACK' }
    Write-Step "$label`: transit side first, then prod"
    $failed = $false
    foreach ($p in $PeeringSides) {
        try {
            $peer = Get-Peering $p.Sub $p.Rg $p.Vnet $p.Name
            if (-not $peer) { Write-Ok "[$($p.Side)] '$($p.Name)' not present, nothing to remove"; continue }
            Write-Ok "[$($p.Side)] '$($p.Name)' found: state=$($peer.peeringState) sync=$($peer.peeringSyncLevel)"
            if ($peer.remoteVirtualNetwork.id -ine $p.ExpectedRemote) {
                Write-Wn "[$($p.Side)] '$($p.Name)' points at $($peer.remoteVirtualNetwork.id), not the expected VNet. Skipping it, not deleting."
                $failed = $true; continue
            }
            Invoke-Change -Description "delete peering '$($p.Name)' on '$($p.Vnet)'" `
                -AzArgs @('network','vnet','peering','delete','--subscription',$p.Sub,'-g',$p.Rg,'--vnet-name',$p.Vnet,'-n',$p.Name)
        }
        catch { $failed = $true; Write-Wn "[$($p.Side)] failed on '$($p.Name)': $_" }
    }
    if ($failed) { throw "$label incomplete. Review the warnings and clean up manually." }
    if (-not $DryRun -and (Test-Path $StateFile)) { Remove-Item $StateFile }
}

function Write-PlanSummary([string]$Mode) {
    Write-Step "$Mode summary ($(if ($DryRun) {'DRY RUN: nothing was changed'} else {'EXECUTED'}))"
    if ($script:Plan.Count -eq 0) { Write-Ok 'No changes needed'; return }
    $script:Plan | Format-Table -AutoSize -Wrap | Out-String | Write-Host
}

#endregion

#region common pre-flight ------------------------------------------------------

if ($DryRun) { Write-Host "`n*** DRY RUN: read-only. No resources will be created or deleted. ***" -ForegroundColor Magenta }

Write-Step 'Checking az login and access to both subscriptions'
$acct = Invoke-Az -Json -AzArgs @('account','show')
Write-Ok "Signed in as $($acct.user.name)"
foreach ($s in $ProdSubscriptionId, $TransitSubscriptionId) {
    Write-Ok ("Access to subscription: " + (Invoke-Az -AzArgs @('account','show','--subscription',$s,'--query','name','-o','tsv')))
}

#endregion

#region ROLLBACK mode ----------------------------------------------------------

if ($Rollback) {
    if (Test-Path $StateFile) { Write-Ok "State file: $((Get-Content $StateFile -Raw) -replace '\s+',' ')" }
    else                      { Write-Wn "No state file at $StateFile. Using parameter values." }

    # Show the plan read-only first, then confirm, then execute for real.
    $realDryRun = $DryRun
    $DryRun = $true
    Invoke-RollbackPlan
    $DryRun = $realDryRun

    if ($script:Plan.Count -eq 0) { Write-PlanSummary 'Rollback'; return }
    if ($DryRun) { Write-PlanSummary 'Rollback'; return }

    Confirm-Proceed 'delete the peering(s) listed above'
    $script:Plan.Clear()
    Invoke-RollbackPlan
    Write-PlanSummary 'Rollback'
    Get-DcRouteToResolver 'After rollback' | Out-Null
    return
}

#endregion

#region DEPLOY mode: pre-flight (read-only) -----------------------------------

Write-Step 'Loading VNets'
$prodVnet    = Invoke-Az -Json -AzArgs @('network','vnet','show','--ids',$ProdVnetId)
$transitVnet = Invoke-Az -Json -AzArgs @('network','vnet','show','--ids',$TransitVnetId)
$prodPrefixes    = @($prodVnet.addressSpace.addressPrefixes    | Where-Object { $_ -notmatch ':' })
$transitPrefixes = @($transitVnet.addressSpace.addressPrefixes | Where-Object { $_ -notmatch ':' })
Write-Ok "Prod    : $($prodPrefixes -join ', ')"
Write-Ok "Transit : $($transitPrefixes -join ', ')"

Write-Step 'Checking address space overlap'
$overlaps = @(foreach ($a in $prodPrefixes) { foreach ($b in $transitPrefixes) {
    $ra = Get-CidrRange $a; $rb = Get-CidrRange $b
    if ($ra.Start -le $rb.End -and $rb.Start -le $ra.End) { "$a <-> $b" }
}})
if ($overlaps.Count) { throw "Address space overlap, peering cannot be created: $($overlaps -join '; ')" }
Write-Ok 'No overlap'

if ($prodPrefixes | Where-Object { Test-IpInCidr $ResolverIp $_ }) {
    throw "Resolver IP $ResolverIp is inside the Prod VNet address space. Traffic stays local and is dropped. Fix this first."
}
if (-not ($transitPrefixes | Where-Object { Test-IpInCidr $ResolverIp $_ })) {
    Write-Wn "Resolver IP $ResolverIp is not inside the transit VNet address space. Check -ResolverIp."
}

Write-Step 'Checking for existing peerings between these VNets'
$prodPeerings    = Get-PeeringList $ProdSubscriptionId    $ProdResourceGroup    $ProdVnetName
$transitPeerings = Get-PeeringList $TransitSubscriptionId $TransitResourceGroup $TransitVnetName
$dupes = @($prodPeerings    | Where-Object { $_.remoteVirtualNetwork.id -ieq $TransitVnetId -or $_.name -eq $ProdToTransitName }) +
         @($transitPeerings | Where-Object { $_.remoteVirtualNetwork.id -ieq $ProdVnetId    -or $_.name -eq $TransitToProdName })
if ($dupes.Count) { throw "Existing peering(s) found, not touching them: $(($dupes | ForEach-Object name) -join ', ')" }
Write-Ok 'None found'

Write-Step 'Out-of-sync peerings on Prod VNet (informational, not changed)'
$unsynced = @($prodPeerings | Where-Object { $_.peeringSyncLevel -ne 'FullyInSync' })
if ($unsynced.Count) { $unsynced | ForEach-Object { Write-Wn "$($_.name): $($_.peeringSyncLevel)" } } else { Write-Ok 'All in sync' }

$baseline = Get-DcRouteToResolver 'Baseline (before change)'

#endregion

#region DEPLOY mode: plan / execute -------------------------------------------

$peerArgs = @('--allow-vnet-access','true','--allow-forwarded-traffic','true',
              '--allow-gateway-transit','false','--use-remote-gateways','false')
$createLocal  = @('network','vnet','peering','create','--subscription',$ProdSubscriptionId,'-g',$ProdResourceGroup,
                  '--vnet-name',$ProdVnetName,'-n',$ProdToTransitName,'--remote-vnet',$TransitVnetId) + $peerArgs
$createRemote = @('network','vnet','peering','create','--subscription',$TransitSubscriptionId,'-g',$TransitResourceGroup,
                  '--vnet-name',$TransitVnetName,'-n',$TransitToProdName,'--remote-vnet',$ProdVnetId) + $peerArgs

if ($DryRun) {
    Write-Step 'Deploy plan'
    Invoke-Change "create peering '$ProdToTransitName' on '$ProdVnetName'"       $createLocal
    Invoke-Change "create peering '$TransitToProdName' on '$TransitVnetName'"    $createRemote
    Write-Dry "Would wait up to $ConnectTimeoutSeconds s for both sides to reach Connected / FullyInSync"
    Write-Dry 'On any failure, would auto-rollback by deleting whichever peering(s) were created (transit side first)'
    if ($baseline) { Write-Dry "Expected after deploy: $ResolverIp matched by a transit prefix -> VNetPeering (currently $($baseline.NextHop))" }
    Write-PlanSummary 'Deploy'
    return
}

Confirm-Proceed "create both peerings between '$ProdVnetName' and '$TransitVnetName'"

$created = $false
try {
    Write-Step 'Creating peerings'
    $created = $true          # from here on, any failure triggers rollback (it is safe if nothing exists yet)
    Invoke-Change "create peering '$ProdToTransitName' on '$ProdVnetName'"    $createLocal
    Invoke-Change "create peering '$TransitToProdName' on '$TransitVnetName'" $createRemote

    @{ createdAt = (Get-Date).ToString('o'); by = $acct.user.name
       prod = "$ProdVnetName/$ProdToTransitName"; transit = "$TransitVnetName/$TransitToProdName" } |
        ConvertTo-Json | Set-Content $StateFile

    Write-Step 'Waiting for Connected / FullyInSync on both sides'
    $deadline = (Get-Date).AddSeconds($ConnectTimeoutSeconds)
    do {
        $l = Get-Peering $ProdSubscriptionId    $ProdResourceGroup    $ProdVnetName    $ProdToTransitName
        $r = Get-Peering $TransitSubscriptionId $TransitResourceGroup $TransitVnetName $TransitToProdName
        $ok = $l -and $r -and $l.peeringState -eq 'Connected' -and $r.peeringState -eq 'Connected' -and
              $l.peeringSyncLevel -eq 'FullyInSync' -and $r.peeringSyncLevel -eq 'FullyInSync'
        if (-not $ok) {
            Write-Host "    prod=$($l.peeringState)/$($l.peeringSyncLevel)  transit=$($r.peeringState)/$($r.peeringSyncLevel)"
            Start-Sleep -Seconds 10
        }
    } until ($ok -or (Get-Date) -gt $deadline)
    if (-not $ok) { throw "Peering did not reach Connected/FullyInSync within $ConnectTimeoutSeconds s" }
    Write-Ok 'Both sides Connected and FullyInSync'
}
catch {
    Write-Wn "Deployment failed: $_"
    if ($created) { Invoke-RollbackPlan -Automatic }
    throw
}

Write-PlanSummary 'Deploy'

# Post-validation is informational: a bad route here means a UDR/local prefix problem, not a peering problem.
$after = Get-DcRouteToResolver 'After deploy'
if ($after -and $after.NextHop -ne 'VNetPeering') {
    Write-Wn 'Next hop is not VNetPeering. A UDR or local prefix is overriding the peering route. Investigate before rolling back.'
}

Write-Host "`nFrom the DC:" -ForegroundColor Cyan
Write-Host "  Test-NetConnection $ResolverIp -Port 53"
Write-Host "  Resolve-DnsName <name>.privatelink.database.windows.net -Server $ResolverIp -DnsOnly"
Write-Host "Rollback dry run: ./Set-ProdTransitPeering.ps1 -TransitResourceGroup $TransitResourceGroup -Rollback -DryRun"

#endregion
