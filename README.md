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

1. Clone the repo locally and open PowerShell in the repo folder.
2. Sign in and verify cloud/subscription.
3. Run `scripts/deploy.ps1`.
4. Run `scripts/set-managed-identity-defender-permissions.ps1`.
5. Run post-deployment validation.

### 1) Clone locally and open PowerShell

```powershell
git clone https://github.com/AndrewBlumhardt/sentinel-tvm-function-based-connector.git
Set-Location .\sentinel-tvm-function-based-connector
```

### 2) Sign in and verify context

```powershell
az login
az cloud show --query name -o tsv
az account show --query "{subscription:id, tenant:tenantId, user:user.name}" -o table
```

For GCC High, either set cloud to `AzureUSGovernment` first, or pass `-CloudName AzureUSGovernment` to both scripts.

### 3) Deploy infrastructure and function app

```powershell
./scripts/deploy.ps1 `
  -ResourceGroupName <deployment-resource-group> `
  -WorkspaceName <sentinel-workspace-name> `
  -WorkspaceResourceGroupName <workspace-resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment
```

### 4) Grant managed identity permissions

```powershell
./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName sentinel-tvm-connector-func `
  -FunctionAppResourceGroup <deployment-resource-group> `
  -SubscriptionId <subscription-id> `
  -CloudName AzureUSGovernment `
  -GrantAdminConsent
```

### 5) Confirm deployed resources

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

## Optional local development setup

You only need this if you plan to run or debug the function app locally.

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
Copy-Item local.settings.sample.json local.settings.json
```

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
  --query "[?name=='LogsIngestion__Endpoint' || starts_with(name,'DcrRuleId_')].[name,value]" -o table

az monitor app-insights query `
  --app $appiName `
  --resource-group $deployRg `
  --subscription $subId `
  --analytics-query "traces | where timestamp > ago(60m) | project timestamp, severityLevel, message | take 20" -o table
```

## Required Azure and Entra permissions

Use these minimum permissions for operators running deployment and permission scripts.

### For `scripts/deploy.ps1`

The script deploys infrastructure, configures Function App settings, and assigns RBAC to the Function managed identity.

- Azure subscription/resource access:
  - `Contributor` on the deployment resource group.
  - `Contributor` on the workspace resource group (custom table module is deployed there).
- RBAC assignment capability:
  - `User Access Administrator` or `Owner` on the deployment resource group scope (required to create `Monitoring Metrics Publisher` role assignment for the Function managed identity).

Notes:

- `Contributor` alone is not enough when a new role assignment must be created.
- If role assignment already exists, `User Access Administrator`/`Owner` is not used for creation, but keeping it avoids rerun failures.

### For `scripts/set-managed-identity-defender-permissions.ps1`

The script assigns Microsoft Defender application roles to the Function managed identity service principal via Microsoft Graph.

- Azure resource access:
  - Reader-level access to the Function App resource (or broader) to resolve managed identity principal ID.
- Microsoft Entra role:
  - `Application Administrator`, `Cloud Application Administrator`, `Privileged Role Administrator`, or `Global Administrator`.

Notes:

- Script behavior uses direct app role assignment on the managed identity service principal.
- Separate admin-consent workflow is not required for this managed identity assignment path.

## Dataset coverage

Detailed per-dataset mappings are defined in `Functions/datasets.json`.

README keeps this section intentionally high-level:

- Advanced Hunting TVM datasets: enabled by default.
- Defender REST API datasets: optional (mostly disabled by default).
- NIST enrichment datasets: optional.

If you need table-level mapping details, use `Functions/datasets.json` as the source of truth.

## Source comparison and operating model

Use raw Advanced Hunting datasets when you want table-level parity with Defender hunting data and direct KQL access patterns.

Use Defender REST datasets when you want cleaner object models, endpoint-level pagination behavior, or more durable API contracts for high-volume collection.

Recommended operating model:

1. Enable both source families for the domains you care about.
2. Compare the resulting custom tables in Sentinel.
3. Disable the source family you do not need.

## Table schema and added columns

This connector writes a standardized envelope to each dataset table, then stores source-specific content in `PayloadJson`.

Common columns written to all datasets:

- `TimeGenerated`
- `SnapshotTime`
- `RunId`
- `DatasetName`
- `SourceType`
- `SourceName`
- `DestinationTable`
- `CollectionMode`
- `CollectorVersion`
- `PayloadJson`

Why these columns were added (likely):

- easier cross-dataset troubleshooting and run correlation (`RunId`, `SnapshotTime`)
- clearer provenance and routing metadata (`SourceType`, `SourceName`, `DestinationTable`)
- stable ingestion and transformation contract while source schemas change over time (`PayloadJson`)
- simpler scale-out deployment with one consistent DCR stream shape per dataset

How this compares to the official Sentinel reference connector:

- the reference implementation defines table-specific schemas with many source-native columns per table
- this implementation intentionally normalizes around a common envelope and keeps source detail in `PayloadJson`

So this behavior is not a direct one-to-one copy of the reference connector schema design; it appears to be an intentional evolution for portability, repeatable deployment, and easier multi-source operations.

## Configuration highlights

Primary configuration is in `Functions/datasets.json` and Function App settings.

Key app settings:

- `DatasetConfigPath`
- `LogsIngestion__Endpoint`
- `LogsIngestion__RuleId`
- `DcrRuleId_<DatasetName>`
- `Enabled_<DatasetName>`
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

## App setting migration

Use the migration script to rename existing legacy dataset app setting keys in a deployed Function App.

```powershell
./scripts/migrate-dataset-setting-names.ps1 `
  -FunctionAppName sentinel-tvm-connector-func `
  -ResourceGroupName <deployment-resource-group>
```

Apply changes and optionally remove legacy keys after validation:

```powershell
./scripts/migrate-dataset-setting-names.ps1 `
  -FunctionAppName sentinel-tvm-connector-func `
  -ResourceGroupName <deployment-resource-group> `
  -Apply `
  -RemoveLegacy
```

## Required root files

These files stay in the repo root because Azure Functions tooling and packaging expect them there:

- `function_app.py`
- `host.json`
- `requirements.txt`
- `pyrightconfig.json`
- `local.settings.sample.json`

Why each should stay in root:

- `function_app.py`: loaded as the Python v2 function app entry point during local host startup and deployment packaging.
- `host.json`: global Azure Functions host configuration file; the host resolves it from the app root.
- `requirements.txt`: used by build/deploy tooling to install Python dependencies from the project root.
- `pyrightconfig.json`: default Pyright/Pylance project configuration location for workspace-level analysis.
- `local.settings.sample.json`: canonical template for creating `local.settings.json` with the documented root-level copy command.

## Repo layout

- `function_app.py`: Function app entry point.
- `Functions/datasets.json`: Dataset catalog and defaults.
- `Functions/`: Timer trigger entry points.
- `Shared/`: Shared ingestion runtime.
- `infra/`: Bicep/ARM definitions.
- `scripts/`: Deployment, permissions, migration, and local validation scripts.
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
az functionapp config appsettings list --name <function-app-name> --resource-group <resource-group> --query "[?name=='LogsIngestion__Endpoint' || starts_with(name,'DcrRuleId_')]" -o table
az role assignment list --assignee <function-mi-object-id> --scope /subscriptions/<sub-id>/resourceGroups/<deployment-rg> --query "[?roleDefinitionName=='Monitoring Metrics Publisher']" -o table
```
