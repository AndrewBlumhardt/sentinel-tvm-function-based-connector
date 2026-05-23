<#
.SYNOPSIS
    Trigger one or more timer-triggered functions to run immediately, without waiting
    for the next NCRONTAB tick. Intended for post-deployment verification after the
    Defender permissions script has been run.

.DESCRIPTION
    Uses the Functions admin endpoint (/admin/functions/<name>) with the master key.
    This is the same mechanism the portal "Test/Run" button uses, but works without
    CORS / browser-origin concerns and is safe on Azure US Government.

    Does NOT modify the function's schedule. Each invocation is one-shot and the
    next scheduled tick still fires normally.

.PARAMETER FunctionAppName
    Name of the Function App (e.g. sentinel-tvm-connector-func-6c44c9).

.PARAMETER ResourceGroupName
    Resource group containing the Function App.

.PARAMETER FunctionName
    Optional. Name of a single function to invoke (e.g. AlertsAndIncidents).
    If omitted, all timer-triggered functions on the app are invoked.

.PARAMETER DelaySeconds
    Seconds to wait between successive invocations when running all functions.
    Default 5. Used to spread load against the Defender API.

.EXAMPLE
    ./scripts/invoke-functions-once.ps1 -FunctionAppName sentinel-tvm-connector-func-6c44c9 -ResourceGroupName fundemo9

.EXAMPLE
    ./scripts/invoke-functions-once.ps1 -FunctionAppName sentinel-tvm-connector-func-6c44c9 -ResourceGroupName fundemo9 -FunctionName AlertsAndIncidents
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FunctionAppName,
    [Parameter(Mandatory = $true)][string]$ResourceGroupName,
    [string]$FunctionName = "",
    [int]$DelaySeconds = 5
)

$ErrorActionPreference = "Stop"

function Invoke-AzJson {
    param([string[]]$Args)
    $raw = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Args -join ' ') failed: $raw"
    }
    $text = ($raw | Out-String).Trim()
    $brace = $text.IndexOf('{')
    $bracket = $text.IndexOf('[')
    $start = if ($brace -lt 0) { $bracket } elseif ($bracket -lt 0) { $brace } else { [Math]::Min($brace, $bracket) }
    if ($start -lt 0) { return $null }
    return ($text.Substring($start) | ConvertFrom-Json)
}

Write-Host "Resolving Function App host name and master key..."
$hostName = (& az functionapp show --name $FunctionAppName --resource-group $ResourceGroupName --query defaultHostName -o tsv 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($hostName)) {
    throw "Could not resolve defaultHostName for $FunctionAppName in $ResourceGroupName."
}
$masterKey = (& az functionapp keys list --name $FunctionAppName --resource-group $ResourceGroupName --query masterKey -o tsv 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($masterKey)) {
    throw "Could not retrieve master key for $FunctionAppName. You need 'Microsoft.Web/sites/host/listkeys/action'."
}

# Determine target list
$targets = @()
if (-not [string]::IsNullOrWhiteSpace($FunctionName)) {
    $targets = @($FunctionName)
}
else {
    Write-Host "Listing functions on $FunctionAppName (retrying for up to 2 minutes while the host warms up)..."
    $functions = $null
    $listAttempts = 12
    $listDelaySeconds = 10
    for ($a = 1; $a -le $listAttempts; $a++) {
        try {
            $listResult = Invoke-AzJson -Args @("functionapp", "function", "list", "--name", $FunctionAppName, "--resource-group", $ResourceGroupName, "-o", "json")
            # Force into an array — PowerShell unwraps single/empty arrays from function returns
            $functions = @($listResult)
        }
        catch {
            Write-Warning "  Attempt $a/$($listAttempts): list failed: $($_.Exception.Message)"
            $functions = @()
        }
        if ($functions.Count -gt 0) { break }
        if ($a -lt $listAttempts) {
            Write-Host "  Attempt $a/$($listAttempts): host reported 0 functions, waiting $listDelaySeconds seconds..."
            Start-Sleep -Seconds $listDelaySeconds
        }
    }

    if ($functions.Count -eq 0) {
        # Fall back to enumerating from local function.json files in the repo so the user can
        # still verify against a freshly-deployed app where the management plane is slow to
        # reflect the function list.
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $localFunctions = Get-ChildItem -Path $repoRoot -Recurse -Filter "function.json" -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\.venv\\|\\node_modules\\|\\.python_packages\\' }
        if ($localFunctions) {
            Write-Warning "Management plane returned 0 functions. Falling back to local function.json files in the repo."
            foreach ($lf in $localFunctions) {
                try {
                    $cfg = Get-Content -Raw -Path $lf.FullName | ConvertFrom-Json
                    $hasTimer = $false
                    foreach ($b in $cfg.bindings) { if ($b.type -eq 'timerTrigger') { $hasTimer = $true; break } }
                    if ($hasTimer) {
                        $name = Split-Path -Leaf $lf.DirectoryName
                        $targets += $name
                    }
                }
                catch { }
            }
        }
        if ($targets.Count -eq 0) {
            throw "No functions returned after $($listAttempts * $listDelaySeconds) seconds and no local function.json files were found. The host may still be loading the package (check WEBSITE_RUN_FROM_PACKAGE), or you may lack 'Microsoft.Web/sites/functions/read' on the app. Try: az functionapp function list --name $FunctionAppName --resource-group $ResourceGroupName -o table"
        }
    }
    else {
        foreach ($f in $functions) {
            $bindings = $f.config.bindings
            $hasTimer = $false
            foreach ($b in $bindings) {
                if ($b.type -eq "timerTrigger") { $hasTimer = $true; break }
            }
            if ($hasTimer) {
                # az returns name as "<app>/<func>"; take the function part
                $shortName = ($f.name -split "/")[-1]
                $targets += $shortName
            }
        }
    }
}

if ($targets.Count -eq 0) {
    throw "No timer-triggered functions found to invoke."
}

Write-Host ""
Write-Host "Will invoke $($targets.Count) function(s) against https://$hostName"
$targets | ForEach-Object { Write-Host "  - $_" }
Write-Host ""

$headers = @{ "x-functions-key" = $masterKey; "Content-Type" = "application/json" }
$success = 0
$failed = @()

for ($i = 0; $i -lt $targets.Count; $i++) {
    $name = $targets[$i]
    $uri = "https://$hostName/admin/functions/$name"
    Write-Host "[$($i+1)/$($targets.Count)] POST $uri"
    try {
        Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body "{}" -TimeoutSec 30 | Out-Null
        Write-Host "    Accepted."
        $success++
    }
    catch {
        Write-Warning "    Failed: $($_.Exception.Message)"
        $failed += $name
    }
    if ($i -lt ($targets.Count - 1) -and $DelaySeconds -gt 0) {
        Start-Sleep -Seconds $DelaySeconds
    }
}

Write-Host ""
Write-Host "Summary: $success accepted, $($failed.Count) failed."
if ($failed.Count -gt 0) {
    Write-Host "Failed functions:"
    $failed | ForEach-Object { Write-Host "  - $_" }
}
Write-Host ""
Write-Host "Watch results in the portal: Function App -> Functions -> <name> -> Invocations,"
Write-Host "or in Application Insights -> Live Metrics / Logs."
