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

## Simple deployment instructions

Use this exact order.

1. Open PowerShell in the local repo folder.
2. Sign in and verify cloud/subscription.
3. Run `scripts/deploy.ps1`.
4. Run `scripts/set-managed-identity-defender-permissions.ps1`.
5. Run post-deployment validation.

### 1) Sign in and verify context

```powershell
az login
az cloud show --query name -o tsv
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o table
```

For GCC High, either set cloud to `AzureUSGovernment` first, or pass `-CloudName AzureUSGovernment` to both scripts.

### 2) Deploy infrastructure and function app

```powershell
./scripts/deploy.ps1 `
  -ResourceGroupName <deployment-resource-group> `
  -WorkspaceName <sentinel-workspace-name> `
  -WorkspaceResourceGroupName <workspace-resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment
```

### 3) Grant managed identity permissions

```powershell
./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName sentinel-tvm-connector-func `
  -FunctionAppResourceGroup <deployment-resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment `
  -GrantAdminConsent
```

### 4) Confirm deployed resources

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

## Post-deployment parameters and validation

Use the variables below as your local runbook values.

<p align="center">
  <img src="images/variables.png" alt="Local variables reference" width="75%" />
</p>

Validate identity, RBAC, and app settings:

```powershell
$subId = "<subscription-id>"
$deployRg = "<deployment-resource-group>"
$funcName = "sentinel-tvm-connector-func"
$appiName = "sentinel-tvm-appi"

$funcPrincipalId = az functionapp identity show `
  --name $funcName `
  --resource-group $deployRg `
  --subscription $subId `
  --query principalId -o tsv

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

## Dataset coverage

Detailed per-dataset mappings are defined in `datasets.json`.

README keeps this section intentionally high-level:

- Advanced Hunting TVM datasets: enabled by default.
- Defender REST API datasets: optional (mostly disabled by default).
- NIST enrichment datasets: optional.

If you need table-level mapping details, use `datasets.json` as the source of truth.

## Source comparison and operating model

Use raw Advanced Hunting datasets when you want table-level parity with Defender hunting data and direct KQL access patterns.

Use Defender REST datasets when you want cleaner object models, endpoint-level pagination behavior, or more durable API contracts for high-volume collection.

Recommended operating model:

1. Enable both source families for the domains you care about.
2. Compare the resulting custom tables in Sentinel.
3. Disable the source family you do not need.

## Configuration highlights

Primary configuration is in `datasets.json` and Function App settings.

Key app settings:

- `DatasetConfigPath`
- `LogsIngestion__Endpoint`
- `LogsIngestion__RuleId`
- `Dataset__<DatasetName>__dcrRuleId`
- `Dataset__<DatasetName>__enabled`
- `Schedule_<DatasetName>`

Timer format: `second minute hour day month day-of-week`

Example daily schedule: `0 0 1 * * *`

Naming behavior:

- Default Function App name: `sentinel-tvm-connector-func`
- Redeploy updates same instance
- Override with `-FunctionAppName` when needed

Permission model:

- `scripts/deploy.ps1` handles Azure RBAC for ingestion resources.
- `set-managed-identity-defender-permissions.ps1` handles Entra API app roles for Defender reads.

Both are required for end-to-end ingestion.

## Optional local setup

Use local setup only if you are developing/debugging function code.

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
Copy-Item local.settings.sample.json local.settings.json
```

## Repo layout

- `function_app.py`: Function app entry point.
- `datasets.json`: Dataset catalog and defaults.
- `Functions/`: Timer trigger entry points.
- `Shared/`: Shared ingestion runtime.
- `infra/`: Bicep/ARM definitions.
- `scripts/`: Deployment, permissions, and local validation scripts.
- `images/`: Screenshots and diagrams.

## Troubleshooting

1. Cloud/context mismatch.

```powershell
az cloud show --query name -o tsv
az account show --query "{subscription:id, tenant:tenantId}" -o table
```

2. Function App name conflict after RG delete (`already exists`).

- Wait a few minutes and rerun deploy.
- Or use a different `-FunctionAppName`.

3. No data flow after permission script.

- Confirm roles were assigned for both APIs:
  - `Microsoft Threat Protection`
  - `WindowsDefenderATP`

4. Ingestion still failing.

```powershell
az functionapp config appsettings list --name <function-app-name> --resource-group <resource-group> --query "[?name=='LogsIngestion__Endpoint' || contains(name,'__dcrRuleId')]" -o table
az role assignment list --assignee <function-mi-object-id> --scope /subscriptions/<sub-id>/resourceGroups/<deployment-rg> --query "[?roleDefinitionName=='Monitoring Metrics Publisher']" -o table
```
