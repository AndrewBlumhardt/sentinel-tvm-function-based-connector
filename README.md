# Sentinel TVM Function-Based Connector

Azure Function connector for collecting Microsoft Defender TVM data and ingesting it into Microsoft Sentinel (Log Analytics custom tables) using DCR/DCE.

## Why this exists

This connector is a continuation of the Logic App approach, built to address scale and operational limits seen in larger environments.

The goal is to combine the best parts of two existing paths:

- Official Microsoft Sentinel connector reference:
  <https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/M365Defender-VulnerabilityManagement>
- Previous implementation evolution from this repo:
  <https://github.com/AndrewBlumhardt/sentinel-defender-tvm-connector>

The official Sentinel option is useful, but it is not a direct table-for-table migration of every prior pattern. This repo focuses on practical parity where needed, plus stronger deployment repeatability and scale behavior.

## What this connector does

Data collection can run from two source models:

1. Advanced Hunting TVM tables via Microsoft Threat Protection permissions.
2. Defender service REST APIs via WindowsDefenderATP permissions.

Running both lets you compare coverage and keep what works best for your environment.

## Local operator sequence

Use this exact flow for first deploy and redeploy:

1. Local copy
  - Clone or pull this repository locally.
2. Open PowerShell
  - Open a PowerShell window in the repo root.
3. Sign in and verify cloud/subscription
  - Run:

```powershell
az login
az cloud show --query name -o tsv
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o table
```

4. Run deployment script
  - Deploy or update infrastructure and Function configuration with `deploy.ps1`.
5. Run permission script
  - Grant Defender API roles to the Function managed identity with `scripts/set-managed-identity-defender-permissions.ps1`.
6. Validate
  - Confirm DCR app settings, RBAC assignment, and first logs.

For GCC High, either set cloud context to AzureUSGovernment before running scripts, or pass `-CloudName AzureUSGovernment` to both scripts.

### Local variables reference

<p align="center">
  <img src="images/variables.png" alt="Local variables reference" width="75%" />
</p>

## Quick deploy

Use deployment mode for production/shared environments.

```powershell
./deploy.ps1 `
  -ResourceGroupName <deployment-resource-group> `
  -WorkspaceName <sentinel-workspace-name> `
  -WorkspaceResourceGroupName <workspace-resource-group> `
  -SubscriptionId <subscription-id>
```

Optional for GCC High:

```powershell
./deploy.ps1 `
  -ResourceGroupName <deployment-resource-group> `
  -WorkspaceName <sentinel-workspace-name> `
  -WorkspaceResourceGroupName <workspace-resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment
```

Worked GCC High example (copy/paste):

```powershell
$subId = "c4139225-5edc-4fe4-a426-f62c934cd8ba"
$deployRg = "fundemo"
$workspaceName = "FedAIRS"
$workspaceRg = "rg-sentinel"
$funcName = "sentinel-tvm-connector-func"

./deploy.ps1 `
  -ResourceGroupName $deployRg `
  -WorkspaceName $workspaceName `
  -WorkspaceResourceGroupName $workspaceRg `
  -SubscriptionId $subId `
  -CloudName AzureUSGovernment

./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName $funcName `
  -FunctionAppResourceGroup $deployRg `
  -SubscriptionId $subId `
  -CloudName AzureUSGovernment `
  -GrantAdminConsent
```

Post-deploy validation (copy/paste):

```powershell
$subId = "c4139225-5edc-4fe4-a426-f62c934cd8ba"
$deployRg = "fundemo"
$funcName = "sentinel-tvm-connector-func"
$appiName = "sentinel-tvm-appi"

$funcPrincipalId = az functionapp identity show `
  --name $funcName `
  --resource-group $deployRg `
  --subscription $subId `
  --query principalId -o tsv

"Function managed identity object ID: $funcPrincipalId"

az role assignment list `
  --assignee $funcPrincipalId `
  --scope /subscriptions/$subId/resourceGroups/$deployRg `
  --query "[?roleDefinitionName=='Monitoring Metrics Publisher']" -o table

az functionapp config appsettings list `
  --name $funcName `
  --resource-group $deployRg `
  --subscription $subId `
  --query "[?name=='LogsIngestion__Endpoint' || ends_with(name,'__dcrRuleId')].[name,value]" -o table

az monitor app-insights query `
  --app $appiName `
  --resource-group $deployRg `
  --subscription $subId `
  --analytics-query "traces | where timestamp > ago(60m) | project timestamp, severityLevel, message | take 20" -o table
```

If the App Insights query is empty, wait for the next timer interval and run it again.

## 5-minute troubleshooting checklist

1. Cloud/context mismatch errors.

```powershell
az cloud show --query name -o tsv
az account show --query "{subscription:id, tenant:tenantId}" -o table
```

For GCC High, rerun deploy with `-CloudName AzureUSGovernment`.

2. "Website with given name ... already exists" after RG delete.

```powershell
./deploy.ps1 ...
```

If it still fails after retries, wait a few minutes and rerun, or set a unique `-FunctionAppName`.

3. Managed identity permissions assigned but no data flow.

```powershell
./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName <function-app-name> `
  -FunctionAppResourceGroup <resource-group> `
  -SubscriptionId <subscription-id>
```

Confirm assignments include both `Microsoft Threat Protection` and `WindowsDefenderATP` resources.

4. Function deploy succeeded but ingestion fails.

```powershell
az functionapp config appsettings list --name <function-app-name> --resource-group <resource-group> --query "[?name=='LogsIngestion__Endpoint' || contains(name,'__dcrRuleId')]" -o table
az role assignment list --assignee <function-mi-object-id> --scope /subscriptions/<sub-id>/resourceGroups/<deployment-rg> --query "[?roleDefinitionName=='Monitoring Metrics Publisher']" -o table
```

5. No records in custom tables.

```powershell
az functionapp config appsettings list --name <function-app-name> --resource-group <resource-group> --query "[?starts_with(name,'Schedule_') || contains(name,'__enabled')]" -o table
```

Then review Function and Application Insights logs for timer execution failures and API permission errors.

### Naming behavior

- Default Function App name is fixed: `sentinel-tvm-connector-func`.
- Redeploy updates the same Function App instance (no timestamp churn).
- Override with `-FunctionAppName` if you intentionally want multiple instances.

### Deploy script behavior

- If `-CloudName` is omitted, the script keeps your current `az cloud` context.
- Per-dataset DCR mapping is set automatically through app settings:
  - `Dataset__<DatasetName>__dcrRuleId`
- The script now prints stage durations and total runtime.

## Required permissions

For `deploy.ps1`:

- Contributor on the deployment resource group.
- Contributor (or equivalent write access) on the Sentinel workspace resource group.

For `scripts/set-managed-identity-defender-permissions.ps1`:

- Reader or higher on the Function App resource group.
- Entra rights to manage app permissions (for example Application Administrator).
- Admin consent authority if using `-GrantAdminConsent`.

## Managed identity permission setup

After deploy, grant Defender API app roles to the Function App managed identity:

```powershell
./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName <function-app-name> `
  -FunctionAppResourceGroup <resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment `
  -GrantAdminConsent
```

If `-CloudName` is omitted, the script keeps your current `az cloud` context.

### Why two API resources are used

| Entra API resource | Used for | Typical permissions |
|---|---|---|
| `Microsoft Threat Protection` | Advanced Hunting KQL over `DeviceTvm*` tables | `AdvancedHunting.Read.All` (or alias `AdvancedQuery.Read.All`) |
| `WindowsDefenderATP` | Defender service APIs (machines, vulnerabilities, recommendations, software, secure config) | `Machine.Read.All`, `Software.Read.All`, `Vulnerability.Read.All`, `SecurityRecommendation.Read.All`, `SecurityConfiguration.Read.All` |

There is no single "master read" permission that covers both patterns.

## Why deploy and permission scripts are separate

They configure different authorization planes:

- `deploy.ps1`: Azure RBAC for ingestion resources.
- `scripts/set-managed-identity-defender-permissions.ps1`: Entra API app roles for Defender data reads.

You need both for end-to-end operation.

If RBAC appears missing right after deploy, this is usually propagation delay. Verify or force it:

```powershell
az role assignment list --assignee <function-mi-object-id> --scope /subscriptions/<sub-id>/resourceGroups/<dcr-rg> --query "[?roleDefinitionName=='Monitoring Metrics Publisher']" -o table

az role assignment create --assignee <function-mi-object-id> --role "Monitoring Metrics Publisher" --scope /subscriptions/<sub-id>/resourceGroups/<dcr-rg>
```

## Configuration

Primary configuration is in `datasets.json` plus Function App settings.

Key app settings:

- `DatasetConfigPath` (default `datasets.json`)
- `LogsIngestion__Endpoint`
- `LogsIngestion__RuleId` (global fallback)
- `Dataset__<DatasetName>__dcrRuleId` (per-dataset DCR mapping)
- `Dataset__<DatasetName>__enabled`
- `Schedule_<DatasetName>`

Timer schedule format:

- `second minute hour day month day-of-week`
- Example daily at 01:00 UTC: `0 0 1 * * *`

Default schedules are defined in:

- `infra/main.bicep`
- `local.settings.sample.json`

## Dataset coverage

### Advanced Hunting TVM (enabled by default)

| Dataset | Destination table |
|---|---|
| DeviceTvmSoftwareInventory | DeviceTvmSoftwareInventory_CL |
| DeviceTvmSoftwareVulnerabilities | DeviceTvmSoftwareVulnerabilities_CL |
| DeviceTvmSoftwareVulnerabilitiesKB | DeviceTvmSoftwareVulnerabilitiesKB_CL |
| DeviceTvmSecureConfigurationAssessment | DeviceTvmSecureConfigurationAssessment_CL |
| DeviceTvmSecureConfigurationAssessmentKB | DeviceTvmSecureConfigurationAssessmentKB_CL |
| DeviceTvmSoftwareEvidenceBeta | DeviceTvmSoftwareEvidenceBeta_CL |
| DeviceTvmBrowserExtensions | DeviceTvmBrowserExtensions_CL |
| DeviceTvmBrowserExtensionsKB | DeviceTvmBrowserExtensionsKB_CL |
| DeviceTvmCertificateInfo | DeviceTvmCertificateInfo_CL |
| DeviceTvmHardwareFirmware | DeviceTvmHardwareFirmware_CL |
| DeviceTvmInfoGathering | DeviceTvmInfoGathering_CL |
| DeviceTvmInfoGatheringKB | DeviceTvmInfoGatheringKB_CL |

### Defender REST API (optional, mostly disabled by default)

| Dataset | Destination table |
|---|---|
| ApiSoftwareVulnerabilitiesByMachine | ApiSoftwareVulnerabilitiesByMachine_CL |
| ApiMachines | ApiMachines_CL |
| ApiSoftwareInventoryByMachine | ApiSoftwareInventoryByMachine_CL |
| ApiNonCpeSoftwareInventory | ApiNonCpeSoftwareInventory_CL |
| ApiRecommendations | ApiRecommendations_CL |
| ApiSecureConfigurationAssessmentByMachine | ApiSecureConfigurationAssessmentByMachine_CL |
| ApiVulnerabilitiesCatalog | ApiVulnerabilitiesCatalog_CL |
| ApiBrowserExtensionsInventory | ApiBrowserExtensionsInventory_CL |
| ApiBrowserExtensionPermissions | ApiBrowserExtensionPermissions_CL |
| ApiCertificateInventoryAssessment | ApiCertificateInventoryAssessment_CL |
| ApiHardwareFirmwareAssessment | ApiHardwareFirmwareAssessment_CL |

### NIST API (optional)

| Dataset | Destination table |
|---|---|
| NistCveCatalog | NistCveCatalog_CL |
| NistCpeConfigurations | NistCpeConfigurations_CL |

## Optional local setup

Use local setup only if you are developing/debugging function code.

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
Copy-Item local.settings.sample.json local.settings.json
```

## Example deployed resources

<p align="center">
  <img src="images/resources.png" alt="Example deployed resources in Azure portal" width="75%" />
</p>

Expected core resources:

- `sentinel-tvm-appi` (Application Insights)
- `sentinel-tvm-dce` (Data Collection Endpoint)
- `sentinel-tvm-dcr-01/02/03` (sharded Data Collection Rules)
- `sentinel-tvm-connector-func` (Function App)
- `sentinel-tvm-plan` (App Service plan)
- `stg...` (storage account)

## Repo layout

- `function_app.py`: Function app entry point.
- `deploy.ps1`: Deployment orchestration script.
- `datasets.json`: Dataset catalog and defaults.
- `Functions/`: Timer trigger entry points.
- `Shared/`: Shared ingestion runtime.
- `infra/`: Bicep/ARM definitions.
- `scripts/`: Permission and support scripts.
- `docs/`: Supplemental notes.
- `images/`: Screenshots and diagrams.
