# Sentinel TVM Function-Based Connector

This project deploys an Azure Function App that collects Microsoft Defender TVM snapshots and writes them to Microsoft Sentinel / Log Analytics custom tables via DCR/DCE.

## Why this project

You can collect TVM data in two ways:

1. Table-first using Defender Advanced Hunting TVM tables.
2. API-first using Defender REST endpoints that often provide similar coverage.

This connector supports both patterns in parallel so you can compare output and choose what works best for your environment. TVM table-based datasets are enabled by default.

## Deploy first (recommended)

Use deployment mode for production and shared environments.

```powershell
./deploy.ps1 `
  -ResourceGroupName <resource-group> `
  -WorkspaceName <sentinel-workspace-name> `
  -WorkspaceResourceGroupName <workspace-resource-group> `
  -SubscriptionId <subscription-id>
```

Notes:

- Deploy script default cloud is commercial Azure (`AzureCloud`).
- For GCC High, add `-CloudName AzureUSGovernment`.
- The script deploys infrastructure, then maps each dataset to the correct DCR immutable ID via `Dataset__<DatasetName>__dcrRuleId` app settings.

## Optional local setup

Local setup is useful when:

- you are developing or debugging function code
- you want to test dataset transformations before publishing
- you want to validate schedule and config changes quickly

If you only need deployment, local setup is not required.

```powershell
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
Copy-Item local.settings.sample.json local.settings.json
```

## Dataset coverage and destination tables

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

## Configuration and parameters

Primary configuration lives in `datasets.json` and Function App app settings.

### Key app settings

- `DatasetConfigPath` (default: `datasets.json`)
- `LogsIngestion__Endpoint`
- `LogsIngestion__RuleId` (global fallback)
- `Dataset__<DatasetName>__dcrRuleId` (per-dataset rule, set by deploy script)
- `Dataset__<DatasetName>__enabled`
- `Schedule_<DatasetName>`

### Schedule format

Azure Functions timer format:

`second minute hour day month day-of-week`

Example daily schedule (1 AM UTC):

`0 0 1 * * *`

Current defaults are daily for all datasets in:

- `infra/main.bicep` schedule defaults
- `local.settings.sample.json`

## Managed identity permissions

Use the provided script to configure Microsoft Defender API app permissions for the Function App system-assigned managed identity:

```powershell
./scripts/set-managed-identity-defender-permissions.ps1 `
  -FunctionAppName <function-app-name> `
  -FunctionAppResourceGroup <resource-group> `
  -SubscriptionId <subscription-id> `
  -GrantAdminConsent
```

Important:

- There is no single master Defender read permission for this scenario.
- Required permissions are app roles and must be granted explicitly.
- There is no Entra directory role that is a least-privilege substitute for this API pattern.

## Example deployed resources

![Example deployed resources in Azure portal](images/resources.png)

What these resources are:

- `sentinel-tvm-appi`: Application Insights telemetry.
- `sentinel-tvm-dce`: Data Collection Endpoint for ingestion.
- `sentinel-tvm-dcr-01/02/03`: sharded Data Collection Rules (DCR dataFlow limit is 10).
- `sentinel-tvm-func`: Function App runtime.
- `sentinel-tvm-plan`: App Service plan.
- `stg...`: Function storage account.

## Repo layout

- `function_app.py`: function app entry point.
- `deploy.ps1`: deployment orchestration script.
- `datasets.json`: dataset catalog and defaults.
- `Functions/`: timer trigger entry points. See `Functions/README.md`.
- `Shared/`: shared ingestion runtime. See `Shared/README.md`.
- `infra/`: Bicep/ARM infrastructure definitions. See `infra/README.md`.
- `scripts/`: operational scripts (permissions and support tooling).
- `docs/`: supplemental notes.
- `images/`: screenshots and diagrams.
