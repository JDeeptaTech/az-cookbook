#requires -Version 5.1
# Shared helpers for the privatelink DNS migration scripts.

function Get-ZoneMap {
    param([string]$Path = [System.IO.Path]::Combine($PSScriptRoot, '..', 'config', 'zone-map.json'))
    (Get-Content -Raw -Path $Path | ConvertFrom-Json).services
}

function Get-SuffixIndex {
    # Returns suffix -> privatelink zone, longest suffix first so 'vaultcore.azure.net' wins over 'azure.net'-style overlaps.
    param([object[]]$ZoneMap)
    $idx = [ordered]@{}
    foreach ($svc in $ZoneMap) {
        foreach ($s in $svc.publicSuffixes) {
            # vault.azure.net -> privatelink.vaultcore.azure.net (Key Vault is the irregular one)
            $zone = $svc.zones | Where-Object { $_ -eq "privatelink.$s" } | Select-Object -First 1
            if (-not $zone) { $zone = $svc.zones[0] }
            if (-not $idx.Contains($s)) { $idx[$s] = $zone }
        }
        foreach ($z in $svc.zones) { if (-not $idx.Contains($z)) { $idx[$z] = $z } }
    }
    $sorted = [ordered]@{}
    $idx.Keys | Sort-Object { $_.Length } -Descending | ForEach-Object { $sorted[$_] = $idx[$_] }
    $sorted
}

function ConvertTo-ZoneKey {
    <#
      Normalises any FQDN (public, privatelink, or zone-relative) to "<relative>|<privatelink zone>".
      mystg.blob.core.windows.net             -> mystg|privatelink.blob.core.windows.net
      mystg.privatelink.blob.core.windows.net -> mystg|privatelink.blob.core.windows.net
      kv01.vault.azure.net                    -> kv01|privatelink.vaultcore.azure.net
      myacr.uksouth.data.azurecr.io           -> myacr.uksouth.data|privatelink.azurecr.io
    #>
    param([Parameter(Mandatory)][string]$Fqdn, [Parameter(Mandatory)][System.Collections.IDictionary]$SuffixIndex)
    $f = $Fqdn.ToLowerInvariant().TrimEnd('.')
    foreach ($suffix in $SuffixIndex.Keys) {
        if ($f.EndsWith(".$suffix")) {
            $rel = $f.Substring(0, $f.Length - $suffix.Length - 1)
            # strip a 'privatelink' label if the public suffix matched (x.privatelink.blob... -> x)
            $rel = $rel -replace '\.privatelink$', ''
            return "$rel|$($SuffixIndex[$suffix])"
        }
    }
    return $null
}

function Get-PublicFqdn {
    # Inverse of ConvertTo-ZoneKey: what a client actually queries.
    param([Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][object[]]$ZoneMap)
    $rel, $zone = $Key -split '\|', 2
    $public = $zone -replace '^privatelink\.', ''
    if ($zone -eq 'privatelink.vaultcore.azure.net') { $public = 'vault.azure.net' }
    "$rel.$public"
}

function Test-IpInCidr {
    param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string[]]$Cidr)
    $addr = [System.Net.IPAddress]::Parse($Ip)
    if ($addr.AddressFamily -ne 'InterNetwork') { return $false }
    $ipInt = [BitConverter]::ToUInt32(($addr.GetAddressBytes()[3..0]), 0)
    foreach ($c in $Cidr) {
        $net, $bits = $c -split '/'
        $netInt = [BitConverter]::ToUInt32(([System.Net.IPAddress]::Parse($net).GetAddressBytes()[3..0]), 0)
        $mask = if ([int]$bits -eq 0) { [uint32]0 } else { [uint32]::MaxValue -shl (32 - [int]$bits) }
        if (($ipInt -band $mask) -eq ($netInt -band $mask)) { return $true }
    }
    $false
}

function Resolve-ARecord {
    # Cross-platform A-record lookup against a specific server. Returns sorted IP strings (follows CNAMEs).
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Server)
    if (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue) {
        try {
            @(Resolve-DnsName -Name $Name -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop |
              Where-Object Type -eq 'A' | ForEach-Object IPAddress | Sort-Object -Unique)
        } catch { @() }
    } elseif (Get-Command dig -ErrorAction SilentlyContinue) {
        @(& dig +short +time=2 +tries=1 "@$Server" $Name A 2>$null |
          Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Sort-Object -Unique)
    } else {
        throw 'No DNS client: needs Resolve-DnsName (Windows) or dig (apt install dnsutils / dnf install bind-utils)'
    }
}

Export-ModuleMember -Function Get-ZoneMap, Get-SuffixIndex, ConvertTo-ZoneKey, Get-PublicFqdn, Test-IpInCidr, Resolve-ARecord
