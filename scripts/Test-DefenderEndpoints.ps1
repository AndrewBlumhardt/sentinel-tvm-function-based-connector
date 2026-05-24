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

.EXAMPLE
    # Call the deployed /api/healthcheck (uses the Function App's MI — no user roles needed)
    pwsh ./scripts/Test-DefenderEndpoints.ps1 -FunctionAppName sentinel-tvm-connector-func-91c358 -ResourceGroup fundemo4

.NOTES
    Two modes:
      1) Default (local): mints a delegated token under YOUR `az login` and probes
         each endpoint from your workstation. Requires Defender delegated scopes
         on your user — most admin accounts do NOT have these by default, so 403s
         are common. Use mode 2 instead if your user can't be granted scopes.
      2) -FunctionAppName + -ResourceGroup (recommended): calls the deployed
         /api/healthcheck?full=1 over HTTPS, which uses the Function App's
         managed identity (already granted the right app roles by deploy.ps1).
         This proves the same code path the scheduled functions use.
    A 403 in mode 1 means YOUR user lacks the role; a 404 means the endpoint
    isn't available in that cloud. Mode 2 surfaces the MI's view, which is
    what actually runs in production.
#>

[CmdletBinding(DefaultParameterSetName = "Local")]
param(
    [Parameter(ParameterSetName = "Local")]
    [Parameter(ParameterSetName = "Healthcheck")]
    [string]$DatasetsPath = (Join-Path $PSScriptRoot ".." "Functions" "datasets.json"),

    [Parameter(ParameterSetName = "Local")]
    [ValidateSet("auto", "AzureCloud", "AzureUSGovernment")]
    [string]$Cloud = "auto",

    [Parameter(ParameterSetName = "Local")]
    [string]$HuntingBaseUrl = "",

    [Parameter(ParameterSetName = "Local")]
    [string]$SecurityCenterBaseUrl = "",

    [Parameter(ParameterSetName = "Local")]
    [int]$Top = 1,

    # ---- Healthcheck mode (calls deployed /api/healthcheck, uses MI) ----
    [Parameter(ParameterSetName = "Healthcheck", Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(ParameterSetName = "Healthcheck", Mandatory = $true)]
    [string]$ResourceGroup
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

# ============================================================================
# Healthcheck mode: just call the deployed /api/healthcheck?full=1 over HTTPS.
# Uses the Function App's managed identity (already permissioned by deploy.ps1).
# ============================================================================
if ($PSCmdlet.ParameterSetName -eq "Healthcheck") {
    Write-Host ""
    Write-Host "--- Healthcheck mode ---"
    Write-Host "  Function App  : $FunctionAppName"
    Write-Host "  ResourceGroup : $ResourceGroup"

    $currentCloud = (& az cloud show --query name -o tsv 2>$null)
    if ($currentCloud) { Write-Host "  az cloud      : $currentCloud" }
    $currentSub = (& az account show --query name -o tsv 2>$null)
    if ($currentSub) { Write-Host "  az subscription: $currentSub" }

    $hostNameRaw = & az functionapp show -n $FunctionAppName -g $ResourceGroup --query defaultHostName -o tsv 2>&1
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$hostNameRaw)) {
        Write-Host ""
        Write-Host "az output: $hostNameRaw"
        throw "Failed to resolve defaultHostName for '$FunctionAppName' in '$ResourceGroup'. Check that your current az context ($currentCloud / $currentSub) actually contains this resource group. If the app is in a different cloud, run: az cloud set --name AzureCloud  (or AzureUSGovernment), then az login."
    }
    $hostName = ([string]$hostNameRaw).Trim()

    $funcKeyRaw = & az functionapp function keys list -n $FunctionAppName -g $ResourceGroup --function-name healthcheck --query default -o tsv 2>$null
    $funcKey = if ($funcKeyRaw) { ([string]$funcKeyRaw).Trim() } else { "" }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($funcKey)) {
        Write-Host "  (function-scope key not found, falling back to host key)"
        $funcKeyRaw = & az functionapp keys list -n $FunctionAppName -g $ResourceGroup --query functionKeys.default -o tsv 2>$null
        $funcKey = if ($funcKeyRaw) { ([string]$funcKeyRaw).Trim() } else { "" }
    }
    if ([string]::IsNullOrWhiteSpace($funcKey)) {
        throw "Failed to resolve a function key for healthcheck. Is the 'healthcheck' function deployed?"
    }

    $url = "https://$hostName/api/healthcheck?full=1&code=$funcKey"
    Write-Host "  URL           : https://$hostName/api/healthcheck?full=1&code=***"
    Write-Host "------------------------"
    Write-Host ""
    Write-Host "Calling healthcheck (this may take 30-60s on cold start)..."
    Write-Host ""

    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -TimeoutSec 180
    } catch {
        throw "Healthcheck call failed: $($_.Exception.Message)"
    }

    if ($resp.summary) {
        Write-Host "--- Summary ---"
        Write-Host "  Cloud           : $($resp.summary.cloud)"
        Write-Host "  Hunting base    : $($resp.summary.hunting_base)"
        Write-Host "  REST base       : $($resp.summary.security_center_base)"
        Write-Host "  MI client id    : $($resp.summary.managed_identity_client_id)"
        Write-Host "  Checked / OK    : $($resp.summary.checked) / $($resp.summary.ok_count)"
        Write-Host "  Failed          : $($resp.summary.failed_count)"
        Write-Host "  Full probe?     : $($resp.summary.full)"
        Write-Host ""
    }

    $rows = @($resp.results)
    $rows | Sort-Object surface, dataset, url |
        Format-Table @{n='Surface';e={$_.surface}}, @{n='Dataset';e={$_.dataset}}, @{n='Status';e={$_.status}}, @{n='ms';e={$_.elapsed_ms}}, @{n='URL';e={$_.url}} -AutoSize | Out-Host

    $failed = @($rows | Where-Object { -not $_.ok })
    if ($failed.Count -gt 0) {
        Write-Host "--- Failure details ---"
        $failed | Sort-Object surface, dataset |
            Format-List surface, dataset, status, url, error, required_roles, hint | Out-Host
    }
    Write-Host ""
    Write-Host "Done. (Use https://$hostName/api/healthcheck?full=1&code=... in a browser for the raw JSON.)"
    return
}

# ============================================================================
# Local mode: probe each endpoint with a delegated user token. NOTE: most user
# accounts do not have Defender delegated scopes — 403s here are usually about
# YOUR roles, not endpoint availability. Prefer -FunctionAppName mode.
# ============================================================================

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
