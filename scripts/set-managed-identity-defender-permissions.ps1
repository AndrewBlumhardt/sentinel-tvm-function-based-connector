[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionAppName,

    [Parameter(Mandatory = $true)]
    [string]$FunctionAppResourceGroup,

    [string]$CloudName = "",

    [string]$SubscriptionId = "",
    [string]$TenantId = "",

    [switch]$GrantAdminConsent,
    [switch]$SkipLogin,

    [string[]]$RequiredPermissions = @(
        "ThreatHunting.Read.All",
        "AdvancedHunting.Read.All",
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

function Ensure-AzLogin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EffectiveCloud,

        [string]$TenantId = ""
    )

    & az account get-access-token --resource-type arm -o none 2>$null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    Write-Host "Azure session is missing or expired. Starting az login for cloud '$EffectiveCloud'..."
    $loginArgs = @("login", "--scope", "https://management.core.windows.net//.default", "--allow-no-subscriptions")
    if (-not [string]::IsNullOrWhiteSpace($TenantId)) {
        $loginArgs += @("--tenant", $TenantId)
    }

    Invoke-AzCli -Args $loginArgs | Out-Null
}

function Resolve-PermissionRole {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Permission,

        [Parameter(Mandatory = $true)]
        [object[]]$AppRoles
    )

    $aliases = @($Permission)
    switch ($Permission) {
        "AdvancedQuery.Read.All" {
            # Only fall back to the older short-form name on the same SP; do NOT
            # substitute AdvancedHunting.Read.All — it is a distinct app role and
            # the /api/advancedqueries/run endpoint requires AdvancedQuery.Read.All
            # specifically. Both roles should be granted (see $RequiredPermissions).
            $aliases += @("AdvancedQuery.Read")
        }
        "AdvancedHunting.Read.All" {
            $aliases += @("AdvancedHunting.Read")
        }
        default { }
    }

    foreach ($candidate in $aliases) {
        $match = $AppRoles | Where-Object { $_.value -eq $candidate } | Select-Object -First 1
        if ($match) {
            return [PSCustomObject]@{
                RequestedPermission = $Permission
                ResolvedPermission = $candidate
                RoleId = $match.id
            }
        }
    }

    return $null
}

function Get-PermissionCandidates {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Permission
    )

    $aliases = @($Permission)
    switch ($Permission) {
        "AdvancedQuery.Read.All" {
            $aliases += @("AdvancedQuery.Read")
        }
        "AdvancedHunting.Read.All" {
            $aliases += @("AdvancedHunting.Read")
        }
        default { }
    }

    return $aliases
}

function Get-GraphResourceEndpoint {
    $graphEndpoint = (& az cloud show --query endpoints.microsoftGraphResourceId -o tsv).Trim()
    if ([string]::IsNullOrWhiteSpace($graphEndpoint)) {
        throw "Unable to resolve Microsoft Graph resource endpoint from current cloud context."
    }

    return $graphEndpoint.TrimEnd('/')
}

function Invoke-GraphRest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Url,

        [string]$Resource,
        [string]$Body = ""
    )

    $args = @(
        "rest",
        "--method", $Method,
        "--url", $Url,
        "--headers", "Content-Type=application/json", "Accept=application/json",
        "--output", "json"
    )

    if (-not [string]::IsNullOrWhiteSpace($Resource)) {
        $args += @("--resource", $Resource)
    }

    $tempBodyPath = ""
    try {
        if (-not [string]::IsNullOrWhiteSpace($Body)) {
            $tempBodyPath = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempBodyPath -Value $Body -NoNewline -Encoding utf8
            $args += @("--body", "@$tempBodyPath")
        }

        return Invoke-AzCli -Args $args
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempBodyPath) -and (Test-Path $tempBodyPath)) {
            Remove-Item -Path $tempBodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI (az) is required but was not found in PATH."
}

$currentCloud = (& az cloud show --query name -o tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to query current Azure cloud context."
}

$effectiveCloud = $currentCloud
if (-not [string]::IsNullOrWhiteSpace($CloudName)) {
    if ($CloudName -notin @("AzureCloud", "AzureUSGovernment")) {
        throw "Invalid CloudName '$CloudName'. Allowed values: AzureCloud, AzureUSGovernment."
    }

    $effectiveCloud = $CloudName
}

if ($currentCloud -ne $effectiveCloud) {
    Write-Host "Switching Azure cloud context from '$currentCloud' to '$effectiveCloud'..."
    Invoke-AzCli -Args @("cloud", "set", "--name", $effectiveCloud) | Out-Null
}
else {
    Write-Host "Using current Azure cloud context '$effectiveCloud'."
}

if (-not $SkipLogin) {
    Ensure-AzLogin -EffectiveCloud $effectiveCloud -TenantId $TenantId
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-Host "Setting active subscription to '$SubscriptionId'..."
    Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId) | Out-Null
}

$accountInfo = (& az account show -o json 2>$null | ConvertFrom-Json)
if ($accountInfo) {
    Write-Host ""
    Write-Host "--- Preflight context ---"
    Write-Host "  Cloud       : $effectiveCloud"
    Write-Host "  Subscription: $($accountInfo.id)  ($($accountInfo.name))"
    Write-Host "  Tenant      : $($accountInfo.tenantId)"
    Write-Host "  User        : $($accountInfo.user.name)"
    Write-Host "-------------------------"
    Write-Host ""
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

$defenderSps = (Invoke-AzCli -Args @(
    "ad", "sp", "list",
    "--all",
    "--query", "[?displayName=='Microsoft Threat Protection' || displayName=='WindowsDefenderATP' || displayName=='Microsoft Graph'].{id:id,appId:appId,displayName:displayName}",
    "-o", "json"
) | ConvertFrom-Json)

if (-not $defenderSps -or $defenderSps.Count -eq 0) {
    throw "Failed to resolve Microsoft Threat Protection / Microsoft Graph service principals."
}

Write-Host "Candidate Defender service principals found:"
($defenderSps | Sort-Object displayName | Format-Table displayName, appId, id -AutoSize | Out-String).TrimEnd() | Out-Host

$spCatalog = @()
foreach ($candidateSp in $defenderSps) {
    $candidateRoles = (Invoke-AzCli -Args @(
        "ad", "sp", "show",
        "--id", $candidateSp.id,
        "--query", "appRoles[?contains(allowedMemberTypes, 'Application')].{value:value,id:id}",
        "-o", "json"
    ) | ConvertFrom-Json)

    $spCatalog += [PSCustomObject]@{
        Id = $candidateSp.id
        AppId = $candidateSp.appId
        DisplayName = $candidateSp.displayName
        AppRoles = @($candidateRoles)
    }
}

if (-not $spCatalog -or $spCatalog.Count -eq 0) {
    throw "Failed to load Defender service principal role catalogs."
}

$targetAssignments = @()
$missingPermissions = @()
foreach ($permission in $RequiredPermissions) {
    $matches = @()
    foreach ($sp in $spCatalog) {
        $resolved = Resolve-PermissionRole -Permission $permission -AppRoles $sp.AppRoles
        if ($resolved) {
            $matches += [PSCustomObject]@{
                Permission = $permission
                ResolvedPermission = $resolved.ResolvedPermission
                RoleId = $resolved.RoleId
                ResourceSpId = $sp.Id
                ResourceAppId = $sp.AppId
                ResourceDisplayName = $sp.DisplayName
            }
        }
    }

    if (-not $matches -or $matches.Count -eq 0) {
        $missingPermissions += $permission
        continue
    }

    $preferredDisplayName = switch ($permission) {
        # ThreatHunting.Read.All is the MODERN unified hunting role on Microsoft
        # Graph (POST /v1.0/security/runHuntingQuery). This is the canonical role
        # the connector now uses for Advanced Hunting; the two below are legacy.
        "ThreatHunting.Read.All"   { "Microsoft Graph" }
        # AdvancedQuery.Read.All is the LEGACY MDATP role that gates the
        # /api/advancedqueries/run endpoint (even when reached via the unified
        # MTP host). It MUST be granted on WindowsDefenderATP — the MTP SP may
        # publish a same-named role but its GUID/audience is different and the
        # legacy endpoint will still return 403.
        "AdvancedQuery.Read.All"   { "WindowsDefenderATP" }
        # AdvancedHunting.Read.All is the unified MTP role, granted on MTP.
        "AdvancedHunting.Read.All" { "Microsoft Threat Protection" }
        default {
            if ($permission -like "Advanced*") { "Microsoft Threat Protection" } else { "WindowsDefenderATP" }
        }
    }
    $chosen = $matches | Where-Object { $_.ResourceDisplayName -eq $preferredDisplayName } | Select-Object -First 1
    if (-not $chosen) {
        $chosen = $matches | Select-Object -First 1
    }

    $targetAssignments += $chosen
}

if ($targetAssignments.Count -eq 0) {
    $availableBySp = @()
    foreach ($sp in $spCatalog) {
        $availableBySp += "$($sp.DisplayName): $((@($sp.AppRoles | Select-Object -ExpandProperty value | Sort-Object) -join ', '))"
    }
    throw "None of the requested Defender permissions are available in this tenant/cloud. Requested: $($RequiredPermissions -join ', '). Available app roles by resource: $($availableBySp -join ' | ')"
}

if ($missingPermissions.Count -gt 0) {
    Write-Warning "The following requested permissions are not available in this tenant/cloud and will be skipped: $($missingPermissions -join ', ')"
}

Write-Host "Resolved permission assignment plan:"
($targetAssignments | Sort-Object Permission | Select-Object Permission, ResolvedPermission, ResourceDisplayName, ResourceAppId | Format-Table -AutoSize | Out-String).TrimEnd() | Out-Host

$graphResource = Get-GraphResourceEndpoint
$graphBase = "$graphResource/v1.0"
$assignmentsUrl = "$graphBase/servicePrincipals/$principalId/appRoleAssignments"

$currentAssignmentsResponse = (Invoke-GraphRest -Method "get" -Url $assignmentsUrl -Resource $graphResource | ConvertFrom-Json)
$currentAssignments = @()
if ($currentAssignmentsResponse.value) {
    $currentAssignments = @($currentAssignmentsResponse.value)
}

$currentAssignmentKeys = @{}
foreach ($assignment in $currentAssignments) {
    if ($assignment.resourceId -and $assignment.appRoleId) {
        $key = "$($assignment.resourceId.ToString().ToLowerInvariant())|$($assignment.appRoleId.ToString().ToLowerInvariant())"
        $currentAssignmentKeys[$key] = $true
    }
}

$added = @()
$alreadyPresent = @()

foreach ($entry in $targetAssignments) {
    $resourceKey = $entry.ResourceSpId.ToString().ToLowerInvariant()
    $roleIdLower = $entry.RoleId.ToString().ToLowerInvariant()
    $assignmentKey = "$resourceKey|$roleIdLower"

    if ($currentAssignmentKeys.ContainsKey($assignmentKey)) {
        $alreadyPresent += "$($entry.ResolvedPermission)@$($entry.ResourceDisplayName)"
        continue
    }

    if ($entry.Permission -ne $entry.ResolvedPermission) {
        Write-Host "Granting $($entry.Permission) using '$($entry.ResolvedPermission)' on '$($entry.ResourceDisplayName)' ($($entry.RoleId))"
    }
    else {
        Write-Host "Granting $($entry.Permission) on '$($entry.ResourceDisplayName)' ($($entry.RoleId))"
    }

    $assignmentBody = @{
        principalId = $principalId
        resourceId = $entry.ResourceSpId
        appRoleId = $entry.RoleId
    } | ConvertTo-Json -Compress

    Invoke-GraphRest -Method "post" -Url $assignmentsUrl -Resource $graphResource -Body $assignmentBody | Out-Null

    $added += "$($entry.ResolvedPermission)@$($entry.ResourceDisplayName)"
    $currentAssignmentKeys[$assignmentKey] = $true
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
    Write-Host "GrantAdminConsent was requested. For managed identities, direct app role assignments are already tenant-approved at assignment time. No separate admin-consent command is required."
}
else {
    Write-Host "Admin consent step skipped (not required for managed identity service principal app role assignments)."
}

Write-Host "Final Defender app role assignments for managed identity:"
$finalAssignmentsResponse = (Invoke-GraphRest -Method "get" -Url $assignmentsUrl -Resource $graphResource | ConvertFrom-Json)
$finalAssignments = @()
if ($finalAssignmentsResponse.value) {
    $targetSpIds = @($targetAssignments | Select-Object -ExpandProperty ResourceSpId -Unique)
    $finalAssignments = @($finalAssignmentsResponse.value | Where-Object { $targetSpIds -contains $_.resourceId })
}

$spNameById = @{}
$roleNameByResourceAndRole = @{}
foreach ($sp in $spCatalog) {
    $spNameById[$sp.Id.ToString().ToLowerInvariant()] = $sp.DisplayName
    foreach ($role in $sp.AppRoles) {
        $roleKey = "$($sp.Id.ToString().ToLowerInvariant())|$($role.id.ToString().ToLowerInvariant())"
        $roleNameByResourceAndRole[$roleKey] = $role.value
    }
}

$finalRows = @()
foreach ($assignment in $finalAssignments) {
    $resourceKey = $assignment.resourceId.ToString().ToLowerInvariant()
    $roleKey = $assignment.appRoleId.ToString().ToLowerInvariant()
    $compositeKey = "$resourceKey|$roleKey"
    $finalRows += [PSCustomObject]@{
        Resource = $(if ($spNameById.ContainsKey($resourceKey)) { $spNameById[$resourceKey] } else { "<unknown>" })
        RoleName = $(if ($roleNameByResourceAndRole.ContainsKey($compositeKey)) { $roleNameByResourceAndRole[$compositeKey] } else { "<unknown>" })
        AppRoleId = $assignment.appRoleId
        AssignmentId = $assignment.id
    }
}

$finalRows | Sort-Object Resource, RoleName | Format-Table -AutoSize | Out-Host
