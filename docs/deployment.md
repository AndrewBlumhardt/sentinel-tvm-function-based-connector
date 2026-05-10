# Deployment Notes

## Deployment workflow

1. **Deploy infrastructure** using the provided Bicep template.
2. **Grant API permissions** to the managed identity (see the "Managed identity permission setup (CLI)" section in `README.md`).
3. **Deploy the Function App code** using your preferred CI/CD tool or `func azure functionapp publish`.
4. **Enable datasets** by setting app settings or editing the `datasets.json` configuration.
5. **Monitor execution** using Application Insights and the Function App's timer trigger logs.

## Azure GCC High usage

The deployment script supports Azure Government cloud selection and defaults to `AzureUSGovernment`.

Example:

```powershell
./deploy.ps1 `
	-ResourceGroupName <rg> `
	-WorkspaceName <workspace> `
	-WorkspaceResourceGroupName <workspace-rg> `
	-SubscriptionId <subscription-id>
```

If you need public Azure instead, pass:

```powershell
-CloudName AzureCloud
```

The script will:

- set the active cloud context with `az cloud set`
- ensure an authenticated Azure CLI session
- optionally set the active subscription
- run `az deployment group create` with the required Bicep parameters
- automatically map each dataset to a DCR immutable ID using `Dataset__<DatasetName>__dcrRuleId` app settings

Why this extra mapping exists:

- Azure Monitor DCR has a hard limit of 10 `dataFlows` per DCR.
- This connector defines more datasets than 10, so deployment creates multiple DCRs.
- The Function App needs a per-dataset DCR rule ID to route each upload request correctly.

## Required configuration

The Function App expects these application settings:

- `DatasetConfigPath` — path to the dataset registry (default: `datasets.json`).
- `LogsIngestion__Endpoint` — the DCE ingestion endpoint (e.g., `https://my-dce-name.region.ingest.monitor.azure.com`).
- `LogsIngestion__RuleId` — the DCR immutable ID.
- `ManagedIdentity__ClientId` — only required when using a user-assigned identity instead of the default system-assigned identity.
- one `Schedule_*` setting per timer-triggered dataset — CRON expression controlling the collection schedule.

These are set automatically by the Bicep template except for custom overrides.

## Managed identity permissions

The Function App uses a **system-assigned managed identity** for all authentication. This is more secure than connection strings because credentials are issued automatically by Azure, rotated transparently, and cannot be leaked in code.

The managed identity requires:

1. **Microsoft Defender API application permissions** to call Defender Advanced Hunting and REST endpoints:
	- `AdvancedQuery.Read.All` — run Advanced Hunting KQL queries.
	- `Machine.Read.All` — retrieve device/machine data.
	- `Software.Read.All` — retrieve software inventory and vulnerability data.
	- `Vulnerability.Read.All` — retrieve vulnerability catalogs.
	- `SecurityRecommendation.Read.All` — retrieve security recommendations.
	- `SecurityConfiguration.Read.All` — retrieve secure configuration assessments.

2. **Azure Monitor Logs Ingestion permissions** to upload records via the Data Collection Rule:
	- `Monitoring Metrics Publisher` role on the DCR (granted automatically by Bicep).

See `README.md` for step-by-step CLI commands to grant these permissions.


## DCR and table design

Each dataset is intended to map to its own custom table and DCR stream.

Recommended convention:

- Custom table: `<DatasetName>_CL`
- DCR stream: `Custom-<DatasetName>`

Each table uses the same stable schema:

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

The raw source-specific content is normalized and stored in `PayloadJson`. This keeps the infrastructure deployable without needing a separate table schema for every source shape.

## Initial operating model

- Enable the raw Advanced Hunting datasets you need.
- Optionally enable the curated Defender REST datasets that overlap those domains.
- Ingest both into separate tables.
- Compare the outputs in Sentinel and trim the dataset list later.
