<#
.SYNOPSIS
    Probe every Defender API endpoint declared in Functions/datasets.json from your
    local workstation, using a token issued to your interactive `az login` identity.
    No Function App deploy required.

.DESCRIPTION
    Mirrors what the in-process `/api/healthcheck` function does, but runs locally so
    you can compare commercial vs. Gov coverage without a redeploy. Reports per-
    endpoint status, elapsed time, and a short error snippet for failures.

    Two surfaces are tested:
      - Advanced Hunting POST {hunting_base}/api/advancedqueries/run
            commercial: https://api.security.microsoft.com
            gov:        https://api-gov.security.microsoft.us
      - Defender REST GET  {security_center_base}/api/<endpoint>?$top=1
            commercial: https://api.security.microsoft.com
            gov:        https://api-gov.securitycenter.microsoft.us

    All REST endpoints from datasets.json that begin with '/' are probed (NIST
    https endpoints are skipped — those don't use a Defender token).

.PARAMETER DatasetsPath
    Path to datasets.json. Defaults to ../Functions/datasets.json relative to this
    script.

.PARAMETER Cloud
    'auto' (default) reads the current `az cloud show` context. Override with
    'AzureCloud' or 'AzureUSGovernment' to force a specific cloud.

.PARAMETER HuntingBaseUrl
    Override the Advanced Hunting host. Otherwise derived from -Cloud.

.PARAMETER SecurityCenterBaseUrl
    Override the Defender REST host. Otherwise derived from -Cloud.

.PARAMETER Top
    $top value for REST probes (default 1 — we only care about HTTP status).

.EXAMPLE
    # Test against whatever `az login` is currently pointed at
    pwsh ./scripts/Test-DefenderEndpoints.ps1

.EXAMPLE
    # Force commercial cloud regardless of current az context
    pwsh ./scripts/Test-DefenderEndpoints.ps1 -Cloud AzureCloud

.NOTES
    Required permissions on the *user* running this:
      - Advanced Hunting probe needs AdvancedHunting.Read or AdvancedQuery.Read
      - REST probes need Machine.Read / Vulnerability.Read / Software.Read /
        SecurityRecommendation.Read / SecurityConfiguration.Read (delegated
        scopes are enough for an interactive user).
    A 403 from this script means YOUR user lacks the role, not that the
    endpoint is missing on this cloud. A 404 means the endpoint isn't available.
#>

[CmdletBinding()]
param(
    [string]$DatasetsPath = (Join-Path $PSScriptRoot ".." "Functions" "datasets.json"),
    [ValidateSet("auto", "AzureCloud", "AzureUSGovernment")]
    [string]$Cloud = "auto",
    [string]$HuntingBaseUrl = "",
    [string]$SecurityCenterBaseUrl = "",
    [int]$Top = 1
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

# Resolve cloud
$effectiveCloud = $Cloud
if ($effectiveCloud -eq "auto") {
    $effectiveCloud = (& az cloud show --query name -o tsv).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($effectiveCloud)) {
        throw "Unable to read current cloud from 'az cloud show'."
    }
}

# Default hosts per cloud
$defaultHunting = switch ($effectiveCloud) {
    "AzureUSGovernment" { "https://api-gov.security.microsoft.us" }
    default             { "https://api.security.microsoft.com" }
}
$defaultRest = switch ($effectiveCloud) {
    "AzureUSGovernment" { "https://api-gov.securitycenter.microsoft.us" }
    default             { "https://api.security.microsoft.com" }
}
if ([string]::IsNullOrWhiteSpace($HuntingBaseUrl))        { $HuntingBaseUrl = $defaultHunting }
if ([string]::IsNullOrWhiteSpace($SecurityCenterBaseUrl)) { $SecurityCenterBaseUrl = $defaultRest }

$HuntingBaseUrl        = $HuntingBaseUrl.TrimEnd('/')
$SecurityCenterBaseUrl = $SecurityCenterBaseUrl.TrimEnd('/')

# Account context
$account = (& az account show -o json | ConvertFrom-Json)
Write-Host ""
Write-Host "--- Test context ---"
Write-Host "  Cloud           : $effectiveCloud"
Write-Host "  Subscription    : $($account.id)  ($($account.name))"
Write-Host "  Tenant          : $($account.tenantId)"
Write-Host "  User            : $($account.user.name)"
Write-Host "  Hunting base    : $HuntingBaseUrl"
Write-Host "  REST base       : $SecurityCenterBaseUrl"
Write-Host "  Datasets file   : $DatasetsPath"
Write-Host "--------------------"
Write-Host ""

if (-not (Test-Path $DatasetsPath)) {
    throw "datasets.json not found at: $DatasetsPath"
}

function Get-Token {
    param([Parameter(Mandatory)][string]$Resource)
    $token = (& az account get-access-token --resource $Resource --query accessToken -o tsv 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
        throw "Failed to acquire token for resource '$Resource'. Are you logged in with 'az login'?"
    }
    return $token.Trim()
}

function Invoke-Probe {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Token,
        [string]$Body = $null,
        [string]$ContentType = "application/json"
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $headers = @{ Authorization = "Bearer $Token" }
        if ($Method -eq "POST") {
            $resp = Invoke-WebRequest -Method POST -Uri $Url -Headers $headers `
                -ContentType $ContentType -Body $Body -UseBasicParsing -ErrorAction Stop
        } else {
            $resp = Invoke-WebRequest -Method GET -Uri $Url -Headers $headers `
                -UseBasicParsing -ErrorAction Stop
        }
        $sw.Stop()
        return [PSCustomObject]@{
            Status      = [int]$resp.StatusCode
            Ok          = $true
            ElapsedMs   = [int]$sw.ElapsedMilliseconds
            Error       = $null
        }
    }
    catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        $sw.Stop()
        $status = $null
        $body = $null
        try {
            $r = $_.Exception.Response
            if ($r) {
                try { $status = [int]$r.StatusCode } catch { $status = $null }
                try {
                    $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
                    $body = $reader.ReadToEnd()
                    $reader.Dispose()
                } catch { }
            }
        } catch { }
        if (-not $body) { $body = $_.Exception.Message }
        if ($body.Length -gt 400) { $body = $body.Substring(0, 400) + "..." }
        return [PSCustomObject]@{
            Status     = $status
            Ok         = $false
            ElapsedMs  = [int]$sw.ElapsedMilliseconds
            Error      = ($body -replace "\s+", " ").Trim()
        }
    }
    catch {
        $sw.Stop()
        return [PSCustomObject]@{
            Status     = $null
            Ok         = $false
            ElapsedMs  = [int]$sw.ElapsedMilliseconds
            Error      = $_.Exception.Message
        }
    }
}

# Acquire tokens
Write-Host "Acquiring tokens..."
$huntingToken = Get-Token -Resource $HuntingBaseUrl
$restToken    = Get-Token -Resource $SecurityCenterBaseUrl
Write-Host "  Hunting token  : OK"
Write-Host "  REST    token  : OK"
Write-Host ""

# Load datasets
$ds = (Get-Content $DatasetsPath -Raw | ConvertFrom-Json).datasets

# Build the probe list
$probes = @()

# Advanced Hunting baseline
$probes += [PSCustomObject]@{
    Surface  = "AdvancedHunting"
    Dataset  = "(baseline)"
    Method   = "POST"
    Url      = "$HuntingBaseUrl/api/advancedqueries/run"
    Body     = '{"Query":"DeviceInfo | take 1"}'
    Token    = $huntingToken
}

# REST baseline
$probes += [PSCustomObject]@{
    Surface  = "REST"
    Dataset  = "(baseline)"
    Method   = "GET"
    Url      = "$SecurityCenterBaseUrl/api/machines?`$top=$Top"
    Body     = $null
    Token    = $restToken
}

# All REST endpoints from datasets.json (skip NIST https:// entries)
foreach ($d in $ds) {
    if ($d.endpoint -and $d.endpoint.StartsWith("/")) {
        $sep = if ($d.endpoint.Contains("?")) { "&" } else { "?" }
        $url = "$SecurityCenterBaseUrl$($d.endpoint)$sep`$top=$Top"
        $probes += [PSCustomObject]@{
            Surface  = "REST"
            Dataset  = $d.name
            Method   = "GET"
            Url      = $url
            Body     = $null
            Token    = $restToken
        }
    }
    elseif ($d.query) {
        $bodyObj = @{ Query = "$($d.query) | take 1" } | ConvertTo-Json -Compress
        $probes += [PSCustomObject]@{
            Surface  = "AdvancedHunting"
            Dataset  = $d.name
            Method   = "POST"
            Url      = "$HuntingBaseUrl/api/advancedqueries/run"
            Body     = $bodyObj
            Token    = $huntingToken
        }
    }
}

# Run probes
$results = @()
Write-Host "Probing $($probes.Count) endpoints..."
Write-Host ""
foreach ($p in $probes) {
    $r = Invoke-Probe -Method $p.Method -Url $p.Url -Token $p.Token -Body $p.Body
    $results += [PSCustomObject]@{
        Surface   = $p.Surface
        Dataset   = $p.Dataset
        Status    = $r.Status
        Ok        = $r.Ok
        ElapsedMs = $r.ElapsedMs
        Url       = $p.Url
        Error     = $r.Error
    }
}

# Summarize
$ok      = ($results | Where-Object Ok).Count
$failed  = ($results | Where-Object { -not $_.Ok }).Count
$na404   = ($results | Where-Object { -not $_.Ok -and $_.Status -eq 404 }).Count
$forbid  = ($results | Where-Object { -not $_.Ok -and $_.Status -eq 403 }).Count

Write-Host ""
Write-Host "--- Results ($effectiveCloud) ---"
$results | Sort-Object Surface, Dataset | Format-Table Surface, Dataset, Status, ElapsedMs -AutoSize | Out-Host

if ($failed -gt 0) {
    Write-Host "--- Failure details ---"
    $results | Where-Object { -not $_.Ok } | Sort-Object Surface, Dataset |
        Format-List Surface, Dataset, Status, Url, Error | Out-Host
}

Write-Host ""
Write-Host "Summary: OK=$ok  Failed=$failed  (403=$forbid  404=$na404)"
Write-Host ""
if ($forbid -gt 0) {
    Write-Host "NOTE: 403 means your interactive user lacks the delegated role — not that the endpoint is unavailable in this cloud."
}
if ($na404 -gt 0) {
    Write-Host "NOTE: 404 typically means the endpoint isn't surfaced in this cloud (MDVM premium gaps on Gov)."
}
