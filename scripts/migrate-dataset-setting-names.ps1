[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [string]$SubscriptionId = "",

    [switch]$Apply,
    [switch]$RemoveLegacy
)

$ErrorActionPreference = "Stop"

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $output = & az @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "Azure CLI command failed: az $($Args -join ' ')"
        }

        throw $message
    }

    return $output
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null
}

$settingsJson = Invoke-AzCli -Args @(
    "functionapp", "config", "appsettings", "list",
    "--name", $FunctionAppName,
    "--resource-group", $ResourceGroupName,
    "-o", "json"
)

$settings = $settingsJson | ConvertFrom-Json
$setPairs = @()
$legacyKeys = @()

foreach ($item in $settings) {
    if (-not $item.name) {
        continue
    }

    $match = [regex]::Match($item.name, '^Dataset__(.+?)__(enabled|dcrRuleId)$')
    if (-not $match.Success) {
        continue
    }

    $datasetName = $match.Groups[1].Value
    $propertyName = $match.Groups[2].Value

    $newName = switch ($propertyName) {
        "enabled" { "Enabled_$datasetName" }
        "dcrRuleId" { "DcrRuleId_$datasetName" }
        default { $null }
    }

    if ([string]::IsNullOrWhiteSpace($newName)) {
        continue
    }

    $setPairs += "$newName=$($item.value)"
    $legacyKeys += $item.name
}

if ($setPairs.Count -eq 0) {
    Write-Host "No legacy Dataset__<DatasetName>__* app settings were found. Nothing to migrate."
    exit 0
}

Write-Host "Prepared migration app settings:"
$setPairs | Sort-Object | ForEach-Object { Write-Host "  $_" }

if (-not $Apply) {
    Write-Host ""
    Write-Host "Dry run only. Re-run with -Apply to write these settings."
    if ($RemoveLegacy) {
        Write-Host "Note: -RemoveLegacy is ignored unless -Apply is also set."
    }
    exit 0
}

Invoke-AzCli -Args (@(
    "functionapp", "config", "appsettings", "set",
    "--name", $FunctionAppName,
    "--resource-group", $ResourceGroupName,
    "--settings"
) + $setPairs) | Out-Null

Write-Host "New setting names were applied successfully."

if ($RemoveLegacy -and $legacyKeys.Count -gt 0) {
    Invoke-AzCli -Args (@(
        "functionapp", "config", "appsettings", "delete",
        "--name", $FunctionAppName,
        "--resource-group", $ResourceGroupName,
        "--setting-names"
    ) + $legacyKeys) | Out-Null

    Write-Host "Legacy setting names were removed."
}
else {
    Write-Host "Legacy setting names were left in place for compatibility."
}
