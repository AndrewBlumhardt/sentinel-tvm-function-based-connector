param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,

    [string]$WorkspaceResourceGroupName = $ResourceGroupName,
    [string]$Location = "",
    [string]$NamePrefix = "sentinel-tvm",
    [string]$FunctionAppName = "sentinel-tvm-func"
)

$templatePath = Join-Path $PSScriptRoot 'infra\main.bicep'

$deploymentName = "sentinel-tvm-$(Get-Date -Format 'yyyyMMddHHmmss')"

$parameters = @{
    namePrefix = $NamePrefix
    functionAppName = $FunctionAppName
    workspaceName = $WorkspaceName
    workspaceResourceGroupName = $WorkspaceResourceGroupName
}

if ($Location) {
    $parameters.location = $Location
}

az deployment group create `
    --resource-group $ResourceGroupName `
    --name $deploymentName `
    --template-file $templatePath `
    --parameters $parameters
