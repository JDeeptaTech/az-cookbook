#requires -Version 7.2
<#
.SYNOPSIS
  Run the Pester suite (tests/PrivateDnsPolicy.Tests.ps1) that tests the central private DNS zones and the
  policy that registers private endpoints in them. Uses the Azure CLI; sign in first with `az login`.

.DESCRIPTION
  -Mode Audit   read-only: zones, hub links, delete lock, shadow zones, DINE assignments, identity roles,
                non-compliant PEs, Deny assignment
  -Mode E2E     canary: creates a resource group with a Key Vault / storage / SQL server and private endpoints
                WITHOUT a zone group, waits for the policy, checks the A record, resolution, Deny/Audit and
                record cleanup, then deletes everything
  -Mode All     both

  Pester results: Passed / Failed / Inconclusive (= warning) / Skipped. Exit code 1 on any failure,
  or on any inconclusive result with -Strict.

.EXAMPLE
  az login
  ./11-Test-PrivateDnsPolicy.ps1 -ManagementGroup contoso-landingzones -ZoneSubscriptionId <conn-sub> -HubVnetId <hub-vnet-id>

.EXAMPLE
  ./11-Test-PrivateDnsPolicy.ps1 -Mode All -ManagementGroup contoso-landingzones -ZoneSubscriptionId <conn-sub> -HubVnetId <hub-vnet-id> `
      -TestSubscriptionId <lz-sub> -TestSubnetId <spoke-pe-subnet-id> -Location uksouth -Services vault,blob `
      -ResolverIp 10.0.0.4 -DnsServer 10.10.0.10 -ExpectDenyEffect Audit -Tags @{ costCenter = 'platform' }
#>
[CmdletBinding()]
param(
    [ValidateSet('Audit', 'E2E', 'All')][string]$Mode = 'Audit',
    [Parameter(Mandatory)][string]$ManagementGroup,
    [Parameter(Mandatory)][string]$ZoneSubscriptionId,
    [string]$ZoneResourceGroup = 'rg-dns-privatezones',
    [string[]]$HubVnetId = @(),
    [string]$DinePolicyDefinitionName = 'dine-pe-central-dns',
    [string]$DenyPolicyDefinitionName = 'deny-privatelink-zones',
    [switch]$StrictShadow,

    [string]$TestSubscriptionId,
    [string]$TestResourceGroup = ('rg-dnspolicy-canary-' + (Get-Date -Format 'yyyyMMddHHmm')),
    [string]$TestSubnetId,
    [string]$Location = 'uksouth',
    [ValidateSet('vault', 'blob', 'file', 'queue', 'table', 'dfs', 'sqlServer')][string[]]$Services = @('vault', 'blob'),
    [double]$TimeoutMinutes = 30,
    [double]$RemediateAfterMinutes = 15,
    [int]$PollSeconds = 30,
    [string[]]$ResolverIp = @(),
    [string[]]$DnsServer = @(),
    [string]$TestVmId,
    [ValidateSet('Linux', 'Windows')][string]$TestVmOs = 'Linux',
    [ValidateSet('Deny', 'Audit', 'Skip')][string]$ExpectDenyEffect = 'Skip',
    [hashtable]$Tags = @{},
    [switch]$KeepResources,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')][string]$Output = 'Detailed',
    [switch]$Strict
)
$ErrorActionPreference = 'Stop'

# ---- prerequisites ----
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) not found on PATH.' }
$null = & az account show --only-show-errors -o none 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Not signed in to the Azure CLI. Run az login (or use an AzureCLI pipeline task).' }
$pester = Get-Module Pester -ListAvailable | Where-Object Version -ge '5.5.0' | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5.5+ required: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -Force' }
Import-Module $pester -Force
if (($ResolverIp -or $DnsServer) -and -not (Get-Command Resolve-DnsName, dig -ErrorAction SilentlyContinue)) {
    Write-Warning 'Resolution tests need Resolve-DnsName (Windows) or dig (dnsutils / bind-utils).'
}

# ---- run ----
$data = @{}
foreach ($k in $PSBoundParameters.Keys | Where-Object { $_ -notin 'Mode', 'Output', 'Strict' }) {
    $v = $PSBoundParameters[$k]; $data[$k] = if ($v -is [switch]) { [bool]$v } else { $v }
}
if (-not $data.ContainsKey('TestResourceGroup')) { $data.TestResourceGroup = $TestResourceGroup }

$cfg = New-PesterConfiguration
$cfg.Run.Container = New-PesterContainer -Path (Join-Path $PSScriptRoot '..' 'tests' 'PrivateDnsPolicy.Tests.ps1') -Data $data
$cfg.Run.PassThru = $true
$cfg.Filter.Tag = if ($Mode -eq 'All') { @('Audit', 'E2E') } else { @($Mode) }
$cfg.Output.Verbosity = $Output
$cfg.Should.ErrorAction = 'Stop'

$r = Invoke-Pester -Configuration $cfg
Write-Host ("`nPassed {0}  Failed {1}  Inconclusive {2}  Skipped {3}" -f $r.PassedCount, $r.FailedCount, $r.InconclusiveCount, $r.SkippedCount)
if ($r.FailedCount -gt 0 -or $r.FailedBlocksCount -gt 0 -or $r.FailedContainersCount -gt 0 -or ($Strict -and $r.InconclusiveCount -gt 0)) { exit 1 }
