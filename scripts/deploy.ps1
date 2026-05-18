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

    $pythonPackagesTarget = Join-Path $buildRoot ".python_packages/lib/site-packages"
    New-Item -Path $pythonPackagesTarget -ItemType Directory -Force | Out-Null

    Write-Host "Vendoring Python dependencies into package (Python 3.11, Linux x86_64 wheels)..."
    $venvPath = Join-Path $tmpRoot "packaging-venv"
    $venvPython = Join-Path $venvPath "Scripts\python.exe"

    # Locate Python 3.11 explicitly. Function App runtime is Python 3.11 -- using any other
    # interpreter risks shipping ABI-incompatible wheels (cp312/cp313) that silently fail to
    # import at runtime, leading to zero discovered functions.
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    $py311Cmd = $null
    $py311Args = $null
    if ($pyLauncher) {
        $probe = & py -3.11 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe -and $probe.Trim() -eq "3.11") {
            $py311Cmd = "py"
            $py311Args = @("-3.11")
        }
    }
    if (-not $py311Cmd) {
        $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
        if ($pythonCmd) {
            $probe = & python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null
            if ($LASTEXITCODE -eq 0 -and $probe -and $probe.Trim() -eq "3.11") {
                $py311Cmd = "python"
                $py311Args = @()
            }
        }
    }
    if (-not $py311Cmd) {
        Stop-WithError "Python 3.11 not found. Install Python 3.11 (https://www.python.org/downloads/release/python-31110/) and ensure 'py -3.11' or 'python' resolves to it. The Function App runtime is Python 3.11; using 3.12/3.13 would ship ABI-incompatible wheels and cause zero functions to be discovered at runtime."
    }
    Write-Host "Using Python 3.11 interpreter: $py311Cmd $($py311Args -join ' ')"

    Push-Location $functionProjectRoot
    try {
        & $py311Cmd @py311Args -m venv $venvPath
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPython)) {
            Stop-WithError "Failed to create temporary Python 3.11 virtual environment for packaging at '$venvPath'."
        }

        # Use an isolated venv pip to avoid dependency conflict warnings from globally installed packages.
        & $venvPython -m pip install --upgrade pip --disable-pip-version-check --quiet
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Failed to initialize pip inside temporary packaging environment."
        }

        # Force Linux x86_64 + cp311 wheels (the Function App runs Linux Python 3.11). Without
        # these flags pip resolves Windows wheels locally, which are useless on the deployed app.
        & $venvPython -m pip install `
            --target $pythonPackagesTarget `
            --platform manylinux2014_x86_64 `
            --python-version 3.11 `
            --implementation cp `
            --abi cp311 `
            --only-binary=:all: `
            --upgrade `
            --disable-pip-version-check `
            --quiet `
            -r requirements.txt
        if ($LASTEXITCODE -ne 0) {
            Stop-WithError "Python dependency packaging failed. All requirements must have Linux x86_64 / cp311 wheels available on PyPI. If a package only ships sdists, build it on a Linux runner or use a pre-built wheel."
        }
    }
    finally {
        Pop-Location
    }

    if (Test-Path $packagePath) {
        Remove-Item $packagePath -Force
    }

    # IMPORTANT: PowerShell 5.1's Compress-Archive writes ZIP entries with backslash separators,
    # which Linux Function Apps cannot interpret as directory boundaries. Files end up as
    # "Functions\common.py" (flat filename) instead of "Functions/common.py" (real directory).
    # The runtime then discovers zero modules. Use .NET ZipFile which writes POSIX-style paths.
    Write-Host "Compressing package (POSIX-style entry names) to '$packagePath'..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $buildRoot,
        $packagePath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    # Sanity-check the zip before uploading. Catch the common silent failures (no Functions/
    # directory, no .python_packages/, backslash entries) before they cause runtime breakage.
    $zipArchive = [System.IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        $entryNames = @($zipArchive.Entries | ForEach-Object { $_.FullName })
    }
    finally {
        $zipArchive.Dispose()
    }
    $backslashEntries = @($entryNames | Where-Object { $_ -match '\\' })
    if ($backslashEntries.Count -gt 0) {
        Stop-WithError ("Package contains {0} entries with backslash separators (e.g. '{1}'). Linux Function Apps require POSIX-style paths. Aborting." -f $backslashEntries.Count, $backslashEntries[0])
    }
    if (-not ($entryNames | Where-Object { $_ -match '^Functions/' })) {
        Stop-WithError "Package is missing 'Functions/' directory entries. Function discovery would fail."
    }
    if (-not ($entryNames | Where-Object { $_ -match '^\.python_packages/' })) {
        Stop-WithError "Package is missing '.python_packages/' directory. Function imports would fail at runtime."
    }
    Write-Host ("Package contains {0} entries. Verified Functions/ and .python_packages/ present with POSIX paths." -f $entryNames.Count)

    # Apply FUNCTIONS_SMOKE_MODULE BEFORE the package deploy so the first cold-start after
    # the package change sees the correct discovery mode. Updating it after deploy would force
    # a second restart and a brief window where the wrong module set is loaded.
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

    # Linux Consumption (Y1) with identity-based AzureWebJobsStorage does not support
    # config-zip / one-deploy. Go straight to the documented WEBSITE_RUN_FROM_PACKAGE path.
    # We do NOT pre-delete the existing WEBSITE_RUN_FROM_PACKAGE setting -- a missing setting
    # causes the app to restart with no code and emit confusing errors mid-deploy. Overwriting
    # the value atomically at the end is the correct pattern.
    if ([string]::IsNullOrWhiteSpace($storageAccountId)) {
        Stop-WithError "Storage account ID is not available from deployment outputs; cannot stage remote package."
    }

    Write-Host "Deploying via WEBSITE_RUN_FROM_PACKAGE (remote URL, AAD-uploaded, user-delegation SAS)..."

    $storageAccountName = ($storageAccountId -split "/")[-1]

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

    Write-Host "Remote package staging context:"
    Write-Host "  Storage account scope: $storageAccountId"
    Write-Host "  Deploy principal type: $($accountInfo.user.type)"
    Write-Host "  Deploy principal name: $($accountInfo.user.name)"
    if ([string]::IsNullOrWhiteSpace($deployIdentityObjectId)) {
        Stop-WithError "Unable to resolve deploy principal object ID -- required for AAD blob upload and user-delegation SAS."
    }
    Write-Host "  Deploy principal object ID: $deployIdentityObjectId"

    Write-Host "Assigning 'Storage Blob Data Owner' to deploy identity for AAD blob upload and user delegation SAS..."
    $rbacCreated = Ensure-RoleAssignment -PrincipalId $deployIdentityObjectId -RoleName "Storage Blob Data Owner" -Scope $storageAccountId
    if ($rbacCreated) {
        Write-Host "Role assignment created. Continuing with upload retries to allow RBAC propagation..."
    }
    else {
        Write-Host "Role assignment already exists or is awaiting propagation. Continuing with upload retries..."
    }

    $uploadSucceeded = $false
    $containerEnsured = $false
    $uploadAttempts = 10
    $retryDelaySeconds = 20

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
            Write-Host "Storage upload failed (attempt $uploadAttempt/$uploadAttempts). Retrying in $waitSeconds seconds..."
            Write-Host "Last error: $uploadError"
            Start-Sleep -Seconds $waitSeconds
        }
    }

    if (-not $uploadSucceeded) {
        Stop-WithError "Failed to upload deployment package to storage using AAD auth."
    }

    # User-delegation SAS is capped at 7 days by Azure Storage. Use the max minus a small
    # buffer so the package URL remains valid as long as possible without re-deploying.
    # NOTE: If the function app cold-starts after 7 days, re-run this script to refresh the
    # package URL, OR switch the Function App to identity-based run-from-package (Flex/Premium).
    $sasExpiry = (Get-Date).ToUniversalTime().AddDays(7).AddMinutes(-5).ToString("yyyy-MM-ddTHH:mmZ")
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

    # Some az CLI versions return the SAS with a leading '?'; normalize to bare token.
    $sasToken = $sasToken.TrimStart('?')

    $packageUrl = "{0}/{1}/{2}?{3}" -f $blobBaseUrl.TrimEnd('/'), $containerName, $blobName, $sasToken

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

    # IMPORTANT: do NOT call ARM PATCH on /config/appsettings directly -- that endpoint is a
    # full replace, which wipes FUNCTIONS_WORKER_RUNTIME, FUNCTIONS_EXTENSION_VERSION,
    # AzureWebJobsStorage__*, APPLICATIONINSIGHTS_CONNECTION_STRING, dataset toggles, etc.,
    # and the host then cannot start. Instead use `az functionapp config appsettings set`
    # which performs a merge. Pass settings via @file.json to avoid Windows shell tokenization
    # of the SAS token (which contains '&', '=', and other special chars).
    $settingsFile = Join-Path $tmpRoot "appsettings-merge.json"
    $settingsArray = @(@{ name = "WEBSITE_RUN_FROM_PACKAGE"; value = $packageUrl; slotSetting = $false })
    [System.IO.File]::WriteAllText(
        $settingsFile,
        ($settingsArray | ConvertTo-Json -Depth 5),
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "Updating (merging) WEBSITE_RUN_FROM_PACKAGE app setting with remote package URL..."
    Write-Host "Package URL (SAS redacted): $($blobBaseUrl.TrimEnd('/'))/$containerName/$blobName?<sas-token-redacted>"
    Invoke-AzCli -Args @(
        "functionapp", "config", "appsettings", "set",
        "--name", $resolvedFunctionAppName,
        "--resource-group", $ResourceGroupName,
        "--settings", "@$settingsFile",
        "--only-show-errors",
        "-o", "none"
    ) | Out-Null
    Write-Host "Function package deployed successfully. App will restart automatically."

    # NOTE: changing WEBSITE_RUN_FROM_PACKAGE already triggers a Function App restart; an
    # explicit restart here is redundant and only adds startup latency.

    # The runtime needs time to (1) restart, (2) fetch the SAS package, (3) extract it,
    # (4) load Python and import every module. On Linux Consumption with a ~1300-file
    # package this can take 1-3 minutes. 'functionapp function list' hits the running
    # host directly and returns 400/502 until the host is ready, so we retry with backoff.
    Write-Host "Waiting for runtime to mount package and start the function host..."
    $listAttempts = 12
    $listDelaySeconds = 20
    $functionList = $null
    $lastListError = $null
    for ($listAttempt = 1; $listAttempt -le $listAttempts; $listAttempt++) {
        Start-Sleep -Seconds $listDelaySeconds
        try {
            $functionListRaw = Invoke-AzCli -Args @(
                "functionapp", "function", "list",
                "--name", $resolvedFunctionAppName,
                "--resource-group", $ResourceGroupName,
                "-o", "json",
                "--only-show-errors"
            )
            $candidate = $functionListRaw | ConvertFrom-Json
            if ($candidate -and $candidate.Count -gt 0) {
                $functionList = $candidate
                Write-Host ("Function host responded with {0} discovered function(s) after {1} attempt(s)." -f $candidate.Count, $listAttempt)
                break
            }
            Write-Host ("Function host responded but reported 0 functions (attempt {0}/{1}). Waiting for host warm-up..." -f $listAttempt, $listAttempts)
        }
        catch {
            $lastListError = $_.Exception.Message
            Write-Host ("Function host not ready yet (attempt {0}/{1}). Retrying in {2}s..." -f $listAttempt, $listAttempts, $listDelaySeconds)
        }
    }

    if (-not $functionList -or $functionList.Count -eq 0) {
        Write-Host ""
        Write-Host "--- Function host did not become ready or reported zero functions. Diagnostics: ---"
        Write-Host "App state:"
        try {
            Invoke-AzCli -Args @(
                "functionapp", "show",
                "--name", $resolvedFunctionAppName,
                "--resource-group", $ResourceGroupName,
                "--query", "{state:state, hostNames:defaultHostName, kind:kind, linuxFxVersion:siteConfig.linuxFxVersion}",
                "-o", "json"
            ) | Write-Host
        }
        catch { Write-Host "  (failed to read app state: $($_.Exception.Message))" }

        Write-Host "Runtime app settings (relevant subset):"
        try {
            Invoke-AzCli -Args @(
                "functionapp", "config", "appsettings", "list",
                "--name", $resolvedFunctionAppName,
                "--resource-group", $ResourceGroupName,
                "--query", "[?contains(['FUNCTIONS_WORKER_RUNTIME','FUNCTIONS_EXTENSION_VERSION','WEBSITE_RUN_FROM_PACKAGE','AzureWebJobsStorage__accountName','FUNCTIONS_SMOKE_MODULE','APPLICATIONINSIGHTS_CONNECTION_STRING'], name)].{name:name,valueLength:length(value)}",
                "-o", "table"
            ) | Write-Host
        }
        catch { Write-Host "  (failed to read app settings: $($_.Exception.Message))" }

        Write-Host "Recent Function App log entries (downloaded snapshot):"
        try {
            $logZipPath = Join-Path $tmpRoot "appservice-logs.zip"
            Invoke-AzCli -Args @(
                "webapp", "log", "download",
                "--name", $resolvedFunctionAppName,
                "--resource-group", $ResourceGroupName,
                "--log-file", $logZipPath,
                "--only-show-errors"
            ) | Out-Null
            if (Test-Path $logZipPath) {
                $logExtractDir = Join-Path $tmpRoot "appservice-logs"
                Expand-Archive -Path $logZipPath -DestinationPath $logExtractDir -Force
                $latestLogFiles = Get-ChildItem -Path $logExtractDir -Recurse -File |
                    Where-Object { $_.Extension -in '.log', '.txt' } |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 3
                foreach ($f in $latestLogFiles) {
                    Write-Host "  --- $($f.FullName) (last 30 lines) ---"
                    Get-Content -Path $f.FullName -Tail 30 | ForEach-Object { Write-Host "    $_" }
                }
            }
            else {
                Write-Host "  (no log archive produced)"
            }
        }
        catch { Write-Host "  (failed to download logs: $($_.Exception.Message))" }

        if ($lastListError) {
            Write-Host "Last function-list error: $lastListError"
        }
        Write-Host "------------------------------------------------------------------------------"
        Stop-WithError "Function host did not report any functions after $($listAttempts * $listDelaySeconds) seconds. Check the diagnostics above (app state, settings, logs)."
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
