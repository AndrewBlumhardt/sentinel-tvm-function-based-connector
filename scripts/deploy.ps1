[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [string]$WorkspaceResourceGroupName = $ResourceGroupName,
    [string]$Location = "",
    [string]$NamePrefix = "sentinel-tvm",
    [string]$FunctionAppName = "sentinel-tvm-connector-func",

    [string]$CloudName = "",

    [string]$SubscriptionId = "",
    [string]$TenantId = "",
    [string]$SmokeModule = "",

    [switch]$SkipLogin
)

$ErrorActionPreference = "Stop"
$script:CurrentStage = "Initialization"
$script:DeploymentStartTime = Get-Date
$script:CurrentStageStartTime = $null
$script:StageTimings = @()

function Format-Elapsed {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration
    )

    $totalHours = [int][Math]::Floor($Duration.TotalHours)
    if ($totalHours -ge 1) {
        return "{0:D2}:{1:D2}:{2:D2}.{3:D3}" -f $totalHours, $Duration.Minutes, $Duration.Seconds, $Duration.Milliseconds
    }

    return "{0:D2}:{1:D2}.{2:D3}" -f $Duration.Minutes, $Duration.Seconds, $Duration.Milliseconds
}

function Complete-CurrentStage {
    if ($null -eq $script:CurrentStageStartTime) {
        return
    }

    $elapsed = (Get-Date) - $script:CurrentStageStartTime
    $script:StageTimings += [PSCustomObject]@{
        Stage = $script:CurrentStage
        Duration = $elapsed
    }

    Write-Host "STAGE DURATION: $(Format-Elapsed -Duration $elapsed) [$($script:CurrentStage)]"
    $script:CurrentStageStartTime = $null
}

function Show-TimingSummary {
    Write-Host ""
    Write-Host "====================== Timing Summary ======================"
    foreach ($timing in $script:StageTimings) {
        Write-Host "  $(Format-Elapsed -Duration $timing.Duration)  $($timing.Stage)"
    }

    $totalElapsed = (Get-Date) - $script:DeploymentStartTime
    Write-Host "------------------------------------------------------------"
    Write-Host "  $(Format-Elapsed -Duration $totalElapsed)  TOTAL"
    Write-Host "============================================================"
}

function Start-Stage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Complete-CurrentStage
    $script:CurrentStage = $Name
    $script:CurrentStageStartTime = Get-Date
    Write-Host ""
    Write-Host "============================================================"
    Write-Host "STAGE: $Name"
    Write-Host "============================================================"
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    throw "[$($script:CurrentStage)] $Message"
}

function Get-ResourceIdSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$SegmentName
    )

    $segments = $ResourceId -split "/"
    for ($index = 0; $index -lt $segments.Length - 1; $index++) {
        if ($segments[$index] -ieq $SegmentName) {
            return $segments[$index + 1]
        }
    }

    return ""
}

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

        Stop-WithError $message
    }

    return $output
}

function Test-FunctionAppNameConflict {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$FunctionAppName
    )

    return $Message -match "Website with given name $([regex]::Escape($FunctionAppName)) already exists"
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-WithError "Azure CLI (az) is required but was not found in PATH."
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

function Test-ResourceGroupExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $exists = (Invoke-AzCli -Args @("group", "exists", "--name", $Name)).Trim()
    return $exists -eq "true"
}

function Get-ResourceGroupLocation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return (Invoke-AzCli -Args @("group", "show", "--name", $Name, "--query", "location", "-o", "tsv")).Trim()
}

function Get-StableSuffix {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText,

        [int]$Length = 6
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hashBytes = $sha.ComputeHash($bytes)
        $hashHex = -join ($hashBytes | ForEach-Object { $_.ToString("x2") })
        return $hashHex.Substring(0, [Math]::Min($Length, $hashHex.Length))
    }
    finally {
        $sha.Dispose()
    }
}

function Resolve-FunctionAppName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedName,

        [string]$NamePrefix = "sentinel-tvm",

        [string]$ScopeSeed = ""
    )

    $defaultNames = @("sentinel-tvm-func", "sentinel-tvm-connector-func")
    if ($RequestedName -notin $defaultNames) {
        return $RequestedName
    }

    $sanitizedPrefix = ($NamePrefix.ToLowerInvariant() -replace "[^a-z0-9-]", "")
    if ([string]::IsNullOrWhiteSpace($sanitizedPrefix)) {
        $sanitizedPrefix = "sentineltvm"
    }

    if ([string]::IsNullOrWhiteSpace($ScopeSeed)) {
        $ScopeSeed = "${sanitizedPrefix}:default"
    }

    $suffix = Get-StableSuffix -InputText $ScopeSeed -Length 6
    $candidate = "$sanitizedPrefix-connector-func-$suffix"

    if ($candidate.Length -gt 60) {
        $candidate = $candidate.Substring(0, 60)
    }

    Write-Host "Using Function App name: $candidate (deterministic default; override with -FunctionAppName)"
    return $candidate
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [string]$RoleName,

        [Parameter(Mandatory = $true)]
        [string]$Scope
    )

    $existing = (Invoke-AzCli -Args @(
        "role", "assignment", "list",
        "--assignee", $PrincipalId,
        "--scope", $Scope,
        "--query", "[?roleDefinitionName=='$RoleName'] | length(@)",
        "-o", "tsv"
    )).Trim()

    if ($existing -eq "0" -or [string]::IsNullOrWhiteSpace($existing)) {
        Invoke-AzCli -Args @(
            "role", "assignment", "create",
            "--assignee", $PrincipalId,
            "--role", $RoleName,
            "--scope", $Scope,
            "-o", "none"
        ) | Out-Null

        $verified = (Invoke-AzCli -Args @(
            "role", "assignment", "list",
            "--assignee", $PrincipalId,
            "--scope", $Scope,
            "--query", "[?roleDefinitionName=='$RoleName'] | length(@)",
            "-o", "tsv"
        )).Trim()

        if ($verified -eq "0" -or [string]::IsNullOrWhiteSpace($verified)) {
            Write-Warning "Role assignment create returned successfully but assignment is not yet visible. This can be propagation delay."
            Write-Warning "Manual fallback command: az role assignment create --assignee $PrincipalId --role `"$RoleName`" --scope $Scope"
            return $false
        }

        return $true
    }

    return $false
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-WithError "Azure CLI (az) is required but was not found in PATH."
}

Start-Stage -Name "Input and file validation"

$templatePath = Join-Path $PSScriptRoot "..\infra\main.bicep"
if (-not (Test-Path $templatePath)) {
    Stop-WithError "Template file not found at $templatePath"
}

$datasetConfigPath = Join-Path $PSScriptRoot "..\Functions\datasets.json"
if (-not (Test-Path $datasetConfigPath)) {
    Stop-WithError "Dataset config file not found at $datasetConfigPath"
}

$datasetConfig = Get-Content -Path $datasetConfigPath -Raw | ConvertFrom-Json
$datasetEntries = @($datasetConfig.datasets)
$templateText = Get-Content -Path $templatePath -Raw
$mappedSettings = @{}
foreach ($match in [regex]::Matches($templateText, 'DcrRuleId_(?<name>[A-Za-z0-9]+):\s+dataCollectionRules\[(?<index>\d+)\]\.properties\.immutableId')) {
    $mappedSettings[$match.Groups['name'].Value] = [int]$match.Groups['index'].Value
}

$missingSettings = @()
$extraSettings = @()
$shardMismatches = @()

foreach ($dataset in $datasetEntries) {
    $settingName = "DcrRuleId_$($dataset.name)"
    if (-not $mappedSettings.ContainsKey($dataset.name)) {
        $missingSettings += $settingName
        continue
    }

    if ([int]$dataset.ruleShardIndex -ne [int]$mappedSettings[$dataset.name]) {
        $shardMismatches += "$settingName (json=$($dataset.ruleShardIndex), bicep=$($mappedSettings[$dataset.name]))"
    }
}

foreach ($mappedName in $mappedSettings.Keys) {
    if ($datasetEntries.name -notcontains $mappedName) {
        $extraSettings += "DcrRuleId_$mappedName"
    }
}

if ($missingSettings.Count -gt 0 -or $extraSettings.Count -gt 0 -or $shardMismatches.Count -gt 0) {
    $message = "Dataset-to-DCR app setting mapping drift detected between datasets.json and infra/main.bicep."
    if ($missingSettings.Count -gt 0) {
        $message += " Missing: $($missingSettings -join ', ')."
    }
    if ($extraSettings.Count -gt 0) {
        $message += " Extra: $($extraSettings -join ', ')."
    }
    if ($shardMismatches.Count -gt 0) {
        $message += " Shard mismatches: $($shardMismatches -join '; ')."
    }
    Stop-WithError $message
}

if (-not [string]::IsNullOrWhiteSpace($SmokeModule)) {
    $smokeModulePath = Join-Path (Join-Path $PSScriptRoot "..\Functions") ("{0}.py" -f $SmokeModule)
    if (-not (Test-Path $smokeModulePath)) {
        Stop-WithError "Smoke module '$SmokeModule' was not found at '$smokeModulePath'."
    }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceResourceGroupName)) {
    $WorkspaceResourceGroupName = $ResourceGroupName
}

$currentCloud = (& az cloud show --query name -o tsv).Trim()
if ($LASTEXITCODE -ne 0) {
    Stop-WithError "Unable to query the current Azure cloud context."
}

Start-Stage -Name "Cloud and authentication"

$effectiveCloud = $currentCloud
if (-not [string]::IsNullOrWhiteSpace($CloudName)) {
    if ($CloudName -notin @("AzureCloud", "AzureUSGovernment")) {
        Stop-WithError "Invalid CloudName '$CloudName'. Allowed values: AzureCloud, AzureUSGovernment."
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

$resourceManagerEndpoint = (Invoke-AzCli -Args @("cloud", "show", "--query", "endpoints.resourceManager", "-o", "tsv")).Trim()
if ([string]::IsNullOrWhiteSpace($resourceManagerEndpoint)) {
    Stop-WithError "Unable to resolve ARM endpoint for cloud '$effectiveCloud'."
}
$resourceManagerEndpoint = $resourceManagerEndpoint.TrimEnd('/')

if (-not $SkipLogin) {
    Ensure-AzLogin -EffectiveCloud $effectiveCloud -TenantId $TenantId
}

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    Write-Host "Setting active subscription to '$SubscriptionId'..."
    Invoke-AzCli -Args @("account", "set", "--subscription", $SubscriptionId)
}

Start-Stage -Name "Preflight context and naming"

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

$scopeSeed = if ($accountInfo -and -not [string]::IsNullOrWhiteSpace($accountInfo.id)) {
    "$($accountInfo.id):${ResourceGroupName}:${NamePrefix}"
}
else {
    "${ResourceGroupName}:${NamePrefix}"
}

$resolvedFunctionAppName = Resolve-FunctionAppName -RequestedName $FunctionAppName -NamePrefix $NamePrefix -ScopeSeed $scopeSeed

Write-Host "Resolved Function App name: $resolvedFunctionAppName"

Start-Stage -Name "Resource group checks"

$workspaceRgExists = Test-ResourceGroupExists -Name $WorkspaceResourceGroupName
if (-not $workspaceRgExists) {
    Stop-WithError "Workspace resource group '$WorkspaceResourceGroupName' was not found in the active subscription."
}

$deploymentRgExists = Test-ResourceGroupExists -Name $ResourceGroupName
if (-not $deploymentRgExists) {
    Write-Host "Deployment resource group '$ResourceGroupName' does not exist. Attempting to create it..."

    $createLocation = $Location
    if ([string]::IsNullOrWhiteSpace($createLocation)) {
        $createLocation = Get-ResourceGroupLocation -Name $WorkspaceResourceGroupName
    }

    if ([string]::IsNullOrWhiteSpace($createLocation)) {
        Stop-WithError "Unable to determine location for new resource group '$ResourceGroupName'. Provide -Location explicitly."
    }

    Invoke-AzCli -Args @("group", "create", "--name", $ResourceGroupName, "--location", $createLocation, "-o", "none") | Out-Null
    Write-Host "Created resource group '$ResourceGroupName' in location '$createLocation'."
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
    "functionAppName=$resolvedFunctionAppName",
    "workspaceName=$WorkspaceName",
    "workspaceResourceGroupName=$WorkspaceResourceGroupName"
)

if (-not [string]::IsNullOrWhiteSpace($Location)) {
    $deploymentArgs += "location=$Location"
}

Start-Stage -Name "ARM/Bicep deployment"

Write-Host "Starting deployment '$deploymentName' in cloud '$effectiveCloud'..."
$deploymentResultRaw = $null
$deploymentAttempts = 10
$retryDelaySeconds = 30

for ($attempt = 1; $attempt -le $deploymentAttempts; $attempt++) {
    try {
        $deploymentResultRaw = Invoke-AzCli -Args $deploymentArgs
        break
    }
    catch {
        $deploymentError = $_.Exception.Message
        if ((Test-FunctionAppNameConflict -Message $deploymentError -FunctionAppName $resolvedFunctionAppName) -and $attempt -lt $deploymentAttempts) {
            Write-Warning "Function App name '$resolvedFunctionAppName' is still being released after delete. Retrying deployment in $retryDelaySeconds seconds ($attempt/$deploymentAttempts)..."
            Start-Sleep -Seconds $retryDelaySeconds
            continue
        }

        Write-Host "Deployment execution failed during stage '$script:CurrentStage'."
        Write-Host "Tip: run this for operation-level errors:"
        Write-Host "  az deployment operation group list --resource-group $ResourceGroupName --name $deploymentName -o table"
        throw
    }
}

if ($null -eq $deploymentResultRaw) {
    Stop-WithError "Deployment did not complete after $deploymentAttempts attempts. If the Function App name was just deleted, wait a few minutes and redeploy, or choose a different -FunctionAppName."
}

$deploymentResult = $deploymentResultRaw | ConvertFrom-Json

$functionPrincipalId = ""
if ($deploymentResult.properties.outputs.functionPrincipalId.value) {
    $functionPrincipalId = $deploymentResult.properties.outputs.functionPrincipalId.value
}

$storageAccountId = ""
if ($deploymentResult.properties.outputs.storageAccountId.value) {
    $storageAccountId = $deploymentResult.properties.outputs.storageAccountId.value
}

Start-Stage -Name "Post-deploy DCR RBAC"

if ([string]::IsNullOrWhiteSpace($functionPrincipalId)) {
    Write-Warning "Function principal ID was not returned by deployment outputs. Skipping automatic DCR RBAC assignment."
}
else {
    $rgScope = "/subscriptions/$($accountInfo.id)/resourceGroups/$ResourceGroupName"

    Write-Host "Target Function App for RBAC: $resolvedFunctionAppName"
    Write-Host "Target managed identity object ID: $functionPrincipalId"

    $miSpDisplayName = ""
    $miSpAppId = ""
    try {
        $miSpDisplayName = (Invoke-AzCli -Args @("ad", "sp", "show", "--id", $functionPrincipalId, "--query", "displayName", "-o", "tsv")).Trim()
        $miSpAppId = (Invoke-AzCli -Args @("ad", "sp", "show", "--id", $functionPrincipalId, "--query", "appId", "-o", "tsv")).Trim()
    }
    catch {
        Write-Warning "Unable to resolve managed identity service principal metadata from Entra ID. Proceeding with object ID only."
    }

    if (-not [string]::IsNullOrWhiteSpace($miSpDisplayName) -or -not [string]::IsNullOrWhiteSpace($miSpAppId)) {
        Write-Host "Target managed identity SP display name: $miSpDisplayName"
        Write-Host "Target managed identity SP app ID: $miSpAppId"
    }

    $created = Ensure-RoleAssignment -PrincipalId $functionPrincipalId -RoleName "Monitoring Metrics Publisher" -Scope $rgScope
    if ($created) {
        Write-Host "Assigned 'Monitoring Metrics Publisher' to Function MI on resource group scope '$rgScope'."
    }
    else {
        Write-Host "'Monitoring Metrics Publisher' already assigned on resource group scope '$rgScope' or awaiting RBAC propagation."
    }
}

Start-Stage -Name "Post-deploy Storage RBAC"

if ([string]::IsNullOrWhiteSpace($functionPrincipalId)) {
    Write-Warning "Function principal ID was not returned by deployment outputs. Skipping automatic storage RBAC assignment."
}
else {
    if ([string]::IsNullOrWhiteSpace($storageAccountId)) {
        Write-Warning "Storage account ID was not returned by deployment outputs. Skipping automatic storage RBAC assignment."
    }
    else {
        $storageRoles = @(
            "Storage Blob Data Owner",
            "Storage Queue Data Contributor",
            "Storage Table Data Contributor"
        )
        foreach ($roleName in $storageRoles) {
            $created = Ensure-RoleAssignment -PrincipalId $functionPrincipalId -RoleName $roleName -Scope $storageAccountId
            if ($created) {
                Write-Host "Assigned '$roleName' to Function MI on storage account."
            }
            else {
                Write-Host "'$roleName' already assigned on storage account or awaiting RBAC propagation."
            }
        }
    }
}

Start-Stage -Name "Function code deployment"

$functionProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stvmt-deploy-{0}" -f [guid]::NewGuid().ToString("N"))
$buildRoot = Join-Path $tmpRoot "build"
$packagePath = Join-Path $tmpRoot "functionPackage.zip"

New-Item -Path $buildRoot -ItemType Directory -Force | Out-Null

try {
    Write-Host "Building deterministic function package from '$functionProjectRoot'..."

    $requiredPaths = @(
        "host.json",
        "function_app.py",
        "requirements.txt",
        "Functions",
        "Shared"
    )

    foreach ($item in $requiredPaths) {
        $sourcePath = Join-Path $functionProjectRoot $item
        if (-not (Test-Path $sourcePath)) {
            Stop-WithError "Required package path '$item' was not found at '$sourcePath'."
        }

        Copy-Item -Path $sourcePath -Destination $buildRoot -Recurse -Force
    }

    $pythonPackagesTarget = Join-Path $buildRoot ".python_packages\lib\site-packages"
    New-Item -Path $pythonPackagesTarget -ItemType Directory -Force | Out-Null

    Write-Host "Vendoring Python dependencies into package..."
    $venvPath = Join-Path $tmpRoot "packaging-venv"
    $venvPython = Join-Path $venvPath "Scripts\python.exe"

    Push-Location $functionProjectRoot
    try {
        & python -m venv $venvPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPython)) {
            Stop-WithError "Failed to create temporary Python virtual environment for packaging at '$venvPath'."
        }

        # Use an isolated venv pip to avoid dependency conflict warnings from globally installed packages.
        & $venvPython -m pip install --upgrade pip --disable-pip-version-check --quiet
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Failed to initialize pip inside temporary packaging environment."
        }

        & $venvPython -m pip install -r requirements.txt --target $pythonPackagesTarget --disable-pip-version-check --quiet
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Python dependency packaging failed. Ensure python and pip are available and compatible with runtime 3.11."
        }
    }
    finally {
        Pop-Location
    }

    if (Test-Path $packagePath) {
        Remove-Item $packagePath -Force
    }

    Compress-Archive -Path (Join-Path $buildRoot "*") -DestinationPath $packagePath -Force


    Write-Host "Clearing run-from-package app settings before zip deploy..."
    Invoke-AzCli -Args @(
        "functionapp", "config", "appsettings", "delete",
        "--name", $resolvedFunctionAppName,
        "--resource-group", $ResourceGroupName,
        "--setting-names", "WEBSITE_RUN_FROM_PACKAGE", "SCM_RUN_FROM_PACKAGE",
        "--only-show-errors",
        "-o", "none"
    ) | Out-Null

    Write-Host "Deploying function package via Azure CLI..."
    try {
        Invoke-AzCli -Args @(
            "functionapp", "deployment", "source", "config-zip",
            "--name", $resolvedFunctionAppName,
            "--resource-group", $ResourceGroupName,
            "--src", $packagePath,
            "--only-show-errors"
        ) | Out-Null
    }
    catch {
        $deployError = $_.Exception.Message
        $unsupportedPath = ($deployError -match "does not support this deployment path" -or $deployError -match "deployfromurl")
        if (-not $unsupportedPath) {
            throw
        }

        if ([string]::IsNullOrWhiteSpace($storageAccountId)) {
            Stop-WithError "Zip deploy is not supported for this Function App and storage account output is unavailable for remote package deployment."
        }

        Write-Host "Zip deploy is unsupported for this hosting path. Falling back to remote package URL deployment (AAD auth, no storage keys)..."

        $storageAccountName = ($storageAccountId -split "/")[-1]
        $storageResourceGroupName = Get-ResourceIdSegment -ResourceId $storageAccountId -SegmentName "resourceGroups"
        if ([string]::IsNullOrWhiteSpace($storageResourceGroupName)) {
            $storageResourceGroupName = $ResourceGroupName
        }

        $blobBaseUrl = (Invoke-AzCli -Args @(
            "storage", "account", "show",
            "--ids", $storageAccountId,
            "--query", "primaryEndpoints.blob",
            "-o", "tsv",
            "--only-show-errors"
        )).Trim()
        if ([string]::IsNullOrWhiteSpace($blobBaseUrl)) {
            Stop-WithError "Failed to resolve blob endpoint for storage account '$storageAccountName'."
        }

        $containerName = "function-releases"
        $blobName = "packages/{0}-{1}.zip" -f (Get-Date -Format "yyyyMMddHHmmss"), [guid]::NewGuid().ToString("N")

        $deployIdentityObjectId = ""
        if ($accountInfo.user.type -eq "servicePrincipal") {
            $deployIdentityObjectId = (Invoke-AzCli -Args @(
                "ad", "sp", "show", "--id", $accountInfo.user.name,
                "--query", "id", "-o", "tsv", "--only-show-errors"
            )).Trim()
        }
        else {
            $deployIdentityObjectId = (Invoke-AzCli -Args @(
                "ad", "signed-in-user", "show",
                "--query", "id", "-o", "tsv", "--only-show-errors"
            )).Trim()
        }

        Write-Host "Remote package fallback context:"
        Write-Host "  Storage account scope: $storageAccountId"
        Write-Host "  Deploy principal type: $($accountInfo.user.type)"
        Write-Host "  Deploy principal name: $($accountInfo.user.name)"
        if (-not [string]::IsNullOrWhiteSpace($deployIdentityObjectId)) {
            Write-Host "  Deploy principal object ID: $deployIdentityObjectId"
        }
        else {
            Write-Warning "Unable to resolve deploy principal object ID for RBAC assignment."
        }

        $uploadSucceeded = $false
        $containerEnsured = $false
        $uploadAttempts = 10
        $retryDelaySeconds = 20

        if ([string]::IsNullOrWhiteSpace($deployIdentityObjectId)) {
            throw
        }

        Write-Host "Assigning 'Storage Blob Data Owner' to deploy identity for AAD blob upload and user delegation SAS..."
        $rbacCreated = Ensure-RoleAssignment -PrincipalId $deployIdentityObjectId -RoleName "Storage Blob Data Owner" -Scope $storageAccountId
        if ($rbacCreated) {
            Write-Host "Role assignment created. Waiting for RBAC propagation before retrying storage upload..."
        }
        else {
            Write-Host "Role assignment already exists or is awaiting propagation. Continuing with upload retries..."
        }

        for ($uploadAttempt = 1; $uploadAttempt -le $uploadAttempts; $uploadAttempt++) {
            try {
                if (-not $containerEnsured) {
                    try {
                        Invoke-AzCli -Args @(
                            "storage", "container", "create",
                            "--account-name", $storageAccountName,
                            "--name", $containerName,
                            "--auth-mode", "login",
                            "--public-access", "off",
                            "--only-show-errors",
                            "-o", "none"
                        ) | Out-Null
                    }
                    catch {
                        $containerError = $_.Exception.Message
                        if ($containerError -notmatch "already exists") {
                            throw
                        }
                    }

                    $containerEnsured = $true
                }

                Invoke-AzCli -Args @(
                    "storage", "blob", "upload",
                    "--account-name", $storageAccountName,
                    "--container-name", $containerName,
                    "--name", $blobName,
                    "--file", $packagePath,
                    "--overwrite", "true",
                    "--auth-mode", "login",
                    "--only-show-errors",
                    "-o", "none"
                ) | Out-Null
                $uploadSucceeded = $true
                break
            }
            catch {
                $uploadError = $_.Exception.Message
                if ($uploadAttempt -ge $uploadAttempts) {
                    throw
                }

                $waitSeconds = [Math]::Min(300, $retryDelaySeconds * $uploadAttempt)
                Write-Host "Storage upload still failing after RBAC assignment. Retrying in $waitSeconds seconds ($uploadAttempt/$uploadAttempts)..."
                Write-Host "Last error: $uploadError"
                Start-Sleep -Seconds $waitSeconds
            }
        }

        if (-not $uploadSucceeded) {
            Stop-WithError "Failed to upload deployment package to storage using AAD auth."
        }

        $sasExpiry = (Get-Date).ToUniversalTime().AddHours(12).ToString("yyyy-MM-ddTHH:mmZ")
        $sasToken = (Invoke-AzCli -Args @(
            "storage", "blob", "generate-sas",
            "--account-name", $storageAccountName,
            "--container-name", $containerName,
            "--name", $blobName,
            "--permissions", "r",
            "--expiry", $sasExpiry,
            "--https-only",
            "--as-user",
            "--auth-mode", "login",
            "--only-show-errors",
            "-o", "tsv"
        )).Trim()
        if ([string]::IsNullOrWhiteSpace($sasToken)) {
            Stop-WithError "Failed to generate user delegation SAS for remote package deployment."
        }

        $packageUrl = "{0}/{1}/{2}`?{3}" -f $blobBaseUrl.TrimEnd('/'), $containerName, $blobName, $sasToken

        $functionAppId = (Invoke-AzCli -Args @(
            "functionapp", "show",
            "--name", $resolvedFunctionAppName,
            "--resource-group", $ResourceGroupName,
            "--query", "id",
            "-o", "tsv",
            "--only-show-errors"
        )).Trim()
        if ([string]::IsNullOrWhiteSpace($functionAppId)) {
            Stop-WithError "Failed to resolve Function App resource ID for WEBSITE_RUN_FROM_PACKAGE update."
        }

        $appSettingsBody = @{ properties = @{ WEBSITE_RUN_FROM_PACKAGE = $packageUrl } } | ConvertTo-Json -Depth 5 -Compress
        Write-Host "Updating WEBSITE_RUN_FROM_PACKAGE app setting with remote package URL..."
        Write-Host "Package URL: $packageUrl"
        Invoke-AzCli -Args @(
            "rest",
            "--method", "PATCH",
            "--url", "$resourceManagerEndpoint$functionAppId/config/appsettings?api-version=2023-12-01",
            "--headers", "Content-Type=application/json",
            "--body", $appSettingsBody,
            "--only-show-errors",
            "-o", "json"
        ) | Out-Null
    }
    Write-Host "Function package deployed successfully."

    if ([string]::IsNullOrWhiteSpace($SmokeModule)) {
        Write-Host "Smoke mode disabled. Removing FUNCTIONS_SMOKE_MODULE app setting if present..."
        Invoke-AzCli -Args @(
            "functionapp", "config", "appsettings", "delete",
            "--name", $resolvedFunctionAppName,
            "--resource-group", $ResourceGroupName,
            "--setting-names", "FUNCTIONS_SMOKE_MODULE",
            "--only-show-errors",
            "-o", "none"
        ) | Out-Null
    }
    else {
        Write-Host "Smoke mode enabled. Limiting function discovery to module '$SmokeModule'."
        Invoke-AzCli -Args @(
            "functionapp", "config", "appsettings", "set",
            "--name", $resolvedFunctionAppName,
            "--resource-group", $ResourceGroupName,
            "--settings", "FUNCTIONS_SMOKE_MODULE=$SmokeModule",
            "--only-show-errors",
            "-o", "none"
        ) | Out-Null
    }

    Write-Host "Restarting Function App after deployment..."
    Invoke-AzCli -Args @(
        "functionapp", "restart",
        "--name", $resolvedFunctionAppName,
        "--resource-group", $ResourceGroupName,
        "-o", "none"
    ) | Out-Null

    Write-Host "Verifying deployed function discovery..."
    $functionListRaw = Invoke-AzCli -Args @(
        "functionapp", "function", "list",
        "--name", $resolvedFunctionAppName,
        "--resource-group", $ResourceGroupName,
        "-o", "json"
    )
    $functionList = $functionListRaw | ConvertFrom-Json
    if (-not $functionList -or $functionList.Count -eq 0) {
        Stop-WithError "Deployment completed but zero functions were discovered in the Function App."
    }

    Write-Host "Discovered functions:" 
    $functionList | ForEach-Object { Write-Host " - $($_.name)" }
}
finally {
    if (Test-Path $tmpRoot) {
        Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Start-Stage -Name "Function app state"
Write-Host "Function App '$resolvedFunctionAppName' is left running after deployment."
Write-Host "If needed, you can restart it with: az functionapp restart --name $resolvedFunctionAppName --resource-group $ResourceGroupName"

Start-Stage -Name "Completed"
Write-Host "Deployment completed successfully."
Write-Host ""
Write-Host "Test now checklist:"
Write-Host "  1) Grant Defender permissions:"
$subscriptionId = $accountInfo.id
Write-Host "     ./scripts/set-managed-identity-defender-permissions.ps1 -FunctionAppName $resolvedFunctionAppName -FunctionAppResourceGroup $ResourceGroupName -SubscriptionId $subscriptionId -GrantAdminConsent"
Write-Host "  2) Confirm function discovery:"
Write-Host "     az functionapp function list --name $resolvedFunctionAppName --resource-group $ResourceGroupName -o table"
Write-Host "  3) Confirm dataset rule app settings:"
Write-Host "     az functionapp config appsettings list --name $resolvedFunctionAppName --resource-group $ResourceGroupName --query `"[?starts_with(name,'DcrRuleId_')].[name,value]`" -o table"
Complete-CurrentStage
Show-TimingSummary
