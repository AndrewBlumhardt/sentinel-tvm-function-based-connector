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
    [string]$CloudName = "AzureUSGovernment",

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
Invoke-AzCli -Args $deploymentArgs

Write-Host "Deployment completed successfully."
