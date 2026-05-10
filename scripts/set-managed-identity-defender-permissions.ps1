[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppResourceGroup,

    [ValidateSet("AzureCloud", "AzureUSGovernment")]
    [string]$CloudName = "AzureCloud",

    [string]$SubscriptionId = "",
    [string]$TenantId = "",

    [switch]$GrantAdminConsent,
    [switch]$SkipLogin,

    [string[]]$RequiredPermissions = @(
        "AdvancedQuery.Read.All",
        "Machine.Read.All",
        "Software.Read.All",
        "Vulnerability.Read.All",
        "SecurityRecommendation.Read.All",
        "SecurityConfiguration.Read.All"
    )
)

$ErrorActionPreference = "Stop"

function Invoke-AzCli {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $output = & az @Args
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Args -join ' ')"
    }

    return $output
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

$currentCloud = (& az cloud show --query name -o tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query current Azure cloud context."
}

if ($currentCloud -ne $CloudName) {
    Write-Host "Switching Azure cloud context from '$currentCloud' to '$CloudName'..."
    Invoke-AzCli -Args @("cloud", "set", "--name", $CloudName) | Out-Null
}

if (-not $SkipLogin) {
    & az account show -o none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "No active Azure session found. Starting Azure CLI sign-in for cloud '$CloudName'..."
        if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
            Invoke-AzCli -Args @("login", "--tenant", $TenantId, "--allow-no-subscriptions") | Out-Null
        }
        else {
            Invoke-AzCli -Args @("login", "--allow-no-subscriptions") | Out-Null
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-Host "Setting active subscription to '$SubscriptionId'..."
    Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null
}

$principalId = (Invoke-AzCli -Args @(
    "resource", "show",
    "--name", $FunctionAppName,
    "--resource-group", $FunctionAppResourceGroup,
    "--resource-type", "Microsoft.Web/sites",
    "--query", "identity.principalId",
    "-o", "tsv"
)).Trim()

if ([string]::IsNullOrWhiteSpace($principalId)) {
    throw "Failed to resolve system-assigned managed identity object ID for Function App '$FunctionAppName'."
}

Write-Host "Managed identity object ID: $principalId"

$defenderSpId = (Invoke-AzCli -Args @(
    "ad", "sp", "list",
    "--display-name", "Microsoft Threat Protection",
    "--query", "[0].id",
    "-o", "tsv"
)).Trim()

if ([string]::IsNullOrWhiteSpace($defenderSpId)) {
    throw "Failed to resolve Microsoft Threat Protection service principal."
}

Write-Host "Defender service principal ID: $defenderSpId"

$appRoles = (Invoke-AzCli -Args @(
    "ad", "sp", "show",
    "--id", $defenderSpId,
    "--query", "appRoles[?contains(allowedMemberTypes, 'Application')].{value:value,id:id}",
    "-o", "json"
) | ConvertFrom-Json)

if (-not $appRoles -or $appRoles.Count -eq 0) {
    throw "No application app roles were returned for Defender service principal '$defenderSpId'."
}

$targetRoleIds = @()
foreach ($permission in $RequiredPermissions) {
    $match = $appRoles | Where-Object { $_.value -eq $permission } | Select-Object -First 1
    if (-not $match) {
        throw "Required permission '$permission' was not found in Defender app roles."
    }

    $targetRoleIds += [PSCustomObject]@{
        Permission = $permission
        RoleId = $match.id
    }
}

$currentAssignments = (Invoke-AzCli -Args @(
    "ad", "app", "permission", "list",
    "--id", $principalId,
    "-o", "json"
) | ConvertFrom-Json)

$currentRoleIds = @{}
foreach ($api in $currentAssignments) {
    if ($api.resourceAppId -eq $null) { continue }
    foreach ($assignment in $api.resourceAccess) {
        if ($assignment.type -eq "Role") {
            $currentRoleIds[$assignment.id.ToString().ToLowerInvariant()] = $true
        }
    }
}

$added = @()
$alreadyPresent = @()

foreach ($entry in $targetRoleIds) {
    $roleIdLower = $entry.RoleId.ToString().ToLowerInvariant()
    if ($currentRoleIds.ContainsKey($roleIdLower)) {
        $alreadyPresent += $entry.Permission
        continue
    }

    Write-Host "Granting $($entry.Permission) ($($entry.RoleId))"
    Invoke-AzCli -Args @(
        "ad", "app", "permission", "add",
        "--id", $principalId,
        "--api", $defenderSpId,
        "--api-permissions", "$($entry.RoleId)=Role"
    ) | Out-Null

    $added += $entry.Permission
}

if ($alreadyPresent.Count -gt 0) {
    Write-Host "Already present permissions: $($alreadyPresent -join ', ')"
}

if ($added.Count -gt 0) {
    Write-Host "Added permissions: $($added -join ', ')"
}
else {
    Write-Host "No new permissions were added."
}

if ($GrantAdminConsent) {
    Write-Host "Granting admin consent..."
    Invoke-AzCli -Args @("ad", "app", "permission", "admin-consent", "--id", $principalId) | Out-Null
    Write-Host "Admin consent completed."
}
else {
    Write-Host "Admin consent not requested. Re-run with -GrantAdminConsent if needed."
}

Write-Host "Final Defender app role assignments for managed identity:"
Invoke-AzCli -Args @("ad", "app", "permission", "list", "--id", $principalId, "-o", "table") | Out-Host
