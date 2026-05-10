[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [string]$WorkspaceResourceGroupName = $ResourceGroupName,
    [string]$Location = "",
    [string]$NamePrefix = "sentinel-tvm",
    [string]$FunctionAppName = "sentinel-tvm-func",

    [ValidateSet("AzureUSGovernment", "AzureCloud")]
    [string]$CloudName = "AzureCloud",

    [string]$SubscriptionId = "",
    [string]$TenantId = "",

    [switch]$SkipLogin
)

$ErrorActionPreference = "Stop"

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Args -join ' ')"
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

$templatePath = Join-Path $PSScriptRoot "infra\main.bicep"
if (-not (Test-Path $templatePath)) {
    throw "Template file not found at $templatePath"
}

$datasetConfigPath = Join-Path $PSScriptRoot "datasets.json"
if (-not (Test-Path $datasetConfigPath)) {
    throw "Dataset config file not found at $datasetConfigPath"
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
    $WorkspaceResourceGroupName = $ResourceGroupName
}

$currentCloud = (& az cloud show --query name -o tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query the current Azure cloud context."
}

if ($currentCloud -ne $CloudName) {
    Write-Host "Switching Azure cloud context from '$currentCloud' to '$CloudName'..."
    Invoke-AzCli -Args @("cloud", "set", "--name", $CloudName)
}

if (-not $SkipLogin) {
    $isLoggedIn = $true
    & az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        $isLoggedIn = $false
    }

    if (-not $isLoggedIn) {
        Write-Host "No active Azure session found. Starting Azure CLI sign-in for cloud '$CloudName'..."
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            Invoke-AzCli -Args @("login", "--tenant", $TenantId, "--allow-no-subscriptions")
        }
        else {
            Invoke-AzCli -Args @("login", "--allow-no-subscriptions")
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-Host "Setting active subscription to '$SubscriptionId'..."
    Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId)
}

$deploymentName = "sentinel-tvm-$(Get-Date -Format 'yyyyMMddHHmmss')"

$deploymentArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroupName,
    "--name", $deploymentName,
    "--template-file", $templatePath,
    "--output", "json",
    "--parameters",
    "namePrefix=$NamePrefix",
    "functionAppName=$FunctionAppName",
    "workspaceName=$WorkspaceName",
    "workspaceResourceGroupName=$WorkspaceResourceGroupName"
)

if (-not [string]::IsNullOrWhiteSpace($Location)) {
    $deploymentArgs += "location=$Location"
}

Write-Host "Starting deployment '$deploymentName' in cloud '$CloudName'..."
$deploymentResultRaw = Invoke-AzCli -Args $deploymentArgs
$deploymentResult = $deploymentResultRaw | ConvertFrom-Json

$ruleIds = @()
if ($deploymentResult.properties.outputs.dataCollectionRuleImmutableIds.value) {
    $ruleIds = @($deploymentResult.properties.outputs.dataCollectionRuleImmutableIds.value)
}
elseif ($deploymentResult.properties.outputs.dataCollectionRuleImmutableId.value) {
    $ruleIds = @($deploymentResult.properties.outputs.dataCollectionRuleImmutableId.value)
}

if ($ruleIds.Count -eq 0) {
    throw "Deployment did not return Data Collection Rule immutable IDs."
}

$datasets = (Get-Content -Path $datasetConfigPath -Raw | ConvertFrom-Json).datasets
$maxDataFlowsPerRule = 10

$datasetRuleSettings = @()
for ($i = 0; $i -lt $datasets.Count; $i++) {
    $dataset = $datasets[$i]
    $ruleIndex = [int][Math]::Floor($i / $maxDataFlowsPerRule)
    if ($ruleIndex -ge $ruleIds.Count) {
        throw "Calculated DCR index $ruleIndex for dataset '$($dataset.name)' exceeds available DCR count $($ruleIds.Count)."
    }

    $datasetRuleSettings += "Dataset__$($dataset.name)__dcrRuleId=$($ruleIds[$ruleIndex])"
}

Write-Host "Applying per-dataset DCR rule ID app settings to Function App '$FunctionAppName'..."
$appSettingsArgs = @(
    "functionapp", "config", "appsettings", "set",
    "--name", $FunctionAppName,
    "--resource-group", $ResourceGroupName,
    "--settings"
) + $datasetRuleSettings
Invoke-AzCli -Args $appSettingsArgs | Out-Null

Write-Host "Deployment completed successfully."
