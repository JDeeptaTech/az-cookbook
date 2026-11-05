#requires -Version 7.2
# Thin, testable wrappers around the Azure CLI for the Pester suites.

function Invoke-AzJson {
    <#
      Runs az with -o json --only-show-errors, returns parsed JSON.
      -AllowNotFound: return $null instead of throwing for ResourceNotFound / exit code 3.
      Throws an exception whose .Data['code'] holds the ARM error code (e.g. RequestDisallowedByPolicy).
    #>
    param([Parameter(Mandatory, Position = 0)][string[]]$Arguments, [switch]$AllowNotFound)
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & az @Arguments --only-show-errors -o json 2> $errFile
        $code = $LASTEXITCODE
        $err = (Get-Content -Raw $errFile -ErrorAction SilentlyContinue) ?? ''
    } finally { Remove-Item $errFile -Force -ErrorAction SilentlyContinue }
    if ($code -eq 0) {
        $txt = ($out -join "`n").Trim()
        if (-not $txt) { return $null }
        return ($txt | ConvertFrom-Json -Depth 50)
    }
    if ($AllowNotFound -and ($code -eq 3 -or $err -match 'ResourceNotFound|NotFound|was not found|could not be found|does not exist')) { return $null }
    $armCode = if ($err -match '\(([A-Za-z]+)\)') { $Matches[1] } elseif ($err -match 'Code:\s*([A-Za-z]+)') { $Matches[1] } else { $null }
    $ex = [System.Exception]::new("az $($Arguments[0..([math]::Min(3, $Arguments.Count - 1))] -join ' ') failed ($code): $($err.Trim())")
    $ex.Data['code'] = $armCode; $ex.Data['exit'] = $code
    throw $ex
}

function Invoke-AzRest {
    # az rest against ARM with a relative URL; body is written to a temp file to avoid shell quoting issues.
    param([ValidateSet('get', 'post', 'put', 'delete')][string]$Method = 'get', [Parameter(Mandatory)][string]$Url, $Body, [string[]]$UriParameters)
    $a = @('rest', '--method', $Method, '--url', $Url)
    if ($UriParameters) { $a += '--uri-parameters'; $a += $UriParameters }
    $tmp = $null
    if ($null -ne $Body) {
        $tmp = [IO.Path]::GetTempFileName()
        $Body | ConvertTo-Json -Depth 50 -Compress | Set-Content -Path $tmp -Encoding utf8NoBOM
        $a += @('--body', "@$tmp", '--headers', 'Content-Type=application/json')
    }
    try { Invoke-AzJson $a } finally { if ($tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

function Get-AzProp {
    # az output is usually flattened; fall back to .properties.<name> for REST-shaped objects.
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $v = $Object.$Name
    if ($null -eq $v -and $Object.PSObject.Properties['properties']) { $v = $Object.properties.$Name }
    $v
}

function Get-AzArgRows {
    # Resource Graph via az rest (no resource-graph extension needed), paged.
    param([Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)][string]$ManagementGroup)
    $rows = [System.Collections.Generic.List[object]]::new(); $skip = $null
    do {
        $opts = @{ '$top' = 1000 }; if ($skip) { $opts['$skipToken'] = $skip }
        $r = Invoke-AzRest post '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body @{ query = $Query; managementGroups = @($ManagementGroup); options = $opts }
        if ($r.data) { $rows.AddRange([object[]]@($r.data)) }
        $skip = $r.'$skipToken'
    } while ($skip)
    , $rows.ToArray()
}

function ConvertTo-AzTagArgs([hashtable]$Tags) { @($Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) }

Export-ModuleMember -Function Invoke-AzJson, Invoke-AzRest, Get-AzProp, Get-AzArgRows, ConvertTo-AzTagArgs
