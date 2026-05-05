# Sentinel TVM Function-Based Connector

This project is a Python Azure Functions snapshot-ingestion framework for Microsoft Defender Threat and Vulnerability Management data. It collects datasets on independent schedules, streams results page-by-page, stamps snapshot metadata onto each record, and sends batches into Microsoft Sentinel custom tables through the Azure Monitor Logs Ingestion API using a DCR and DCE.

The ingestion contract is intentionally stable: every custom table receives the snapshot metadata columns plus a `PayloadJson` field containing the normalized record body. That keeps the DCR schema deployable even when source datasets evolve.

## Design summary

- One Function App.
- One timer-trigger module per dataset.
- Configurable enable/disable behavior per dataset.
- Configurable schedule per dataset using application settings.
- Separate destination table and DCR stream per dataset.
- Streaming execution pattern: page -> transform -> batch -> ingest -> clear.
- Managed identity authentication for Defender and Logs Ingestion.
- Optional NIST CVE collection with a separate CPE/configuration dataset.

## Snapshot metadata

Every ingested record is stamped with:

- `SnapshotTime`
- `RunId`
- `SourceType`
- `SourceName`
- `DestinationTable`
- `CollectionMode`
- `CollectorVersion`

## Implemented dataset families

### Advanced Hunting TVM datasets

- `DeviceTvmSoftwareInventory`
- `DeviceTvmSoftwareVulnerabilities`
- `DeviceTvmSoftwareVulnerabilitiesKB`
- `DeviceTvmSecureConfigurationAssessment`
- `DeviceTvmSecureConfigurationAssessmentKB`
- `DeviceTvmSoftwareEvidenceBeta`
- `DeviceTvmBrowserExtensions`
- `DeviceTvmBrowserExtensionsKB`
- `DeviceTvmCertificateInfo`
- `DeviceTvmHardwareFirmware`
- `DeviceTvmInfoGathering`
- `DeviceTvmInfoGatheringKB`

### Defender REST datasets

- `ApiMachines`
- `ApiSoftwareVulnerabilitiesByMachine`
- `ApiSoftwareInventoryByMachine`
- `ApiNonCpeSoftwareInventory`
- `ApiRecommendations`
- `ApiSecureConfigurationAssessmentByMachine`
- `ApiVulnerabilitiesCatalog`
- `ApiBrowserExtensionsInventory`
- `ApiBrowserExtensionPermissions`
- `ApiCertificateInventoryAssessment`
- `ApiHardwareFirmwareAssessment`

### Optional NIST datasets

- `NistCveCatalog`
- `NistCpeConfigurations`

## Local setup

1. Create and activate a Python 3.11 virtual environment.
2. Install dependencies with `python -m pip install -r requirements.txt`.
3. Copy `local.settings.sample.json` to `local.settings.json`.
4. Set `LogsIngestion__Endpoint` to the DCE ingestion endpoint.
5. Set `LogsIngestion__RuleId` to the DCR immutable ID.
6. Set the `Schedule_*` values you want to use.
7. Set any dataset overrides with environment variables like `Dataset__ApiMachines__enabled=false`.
8. Run the app with Azure Functions Core Tools.

## Managed identity model

The Function App is designed around a single managed identity. That identity must be able to:

1. Acquire access tokens for `https://api.security.microsoft.com/.default`.
2. Call the enabled Microsoft Defender APIs.
3. Acquire access tokens for Azure Monitor Logs Ingestion.
4. Upload records to the DCR streams backing your custom tables.

## Project layout

- `function_app.py`: application bootstrap and timer blueprint registration.
- `datasets.json`: dataset catalog and defaults.
- `Functions/`: timer trigger entry points.
- `Shared/`: shared config, auth, paging, transformation, batching, retries, and ingestion.
- `infra/main.bicep`: Function App, Storage, Application Insights, DCE, DCR, and custom table deployment.
- `deploy.ps1`: wrapper for group deployment with workspace parameters.
- `docs/deployment.md`: deployment and DCR/DCE notes.
- `docs/permissions.md`: system-assigned managed identity setup and Microsoft Defender API permission grants.
- `docs/source-comparison.md`: guidance on comparing Advanced Hunting with REST datasets.

## Validation status

The scaffold compiles successfully with `python -m compileall .`.

## Azure deployment

1. Ensure you already have a Log Analytics workspace that backs your Microsoft Sentinel deployment.
2. Deploy the infrastructure with `./deploy.ps1 -ResourceGroupName <rg> -WorkspaceName <workspace> -WorkspaceResourceGroupName <workspace-rg>`.
3. Grant the Function App's managed identity the required Microsoft Defender API permissions (see [docs/permissions.md](docs/permissions.md) for step-by-step CLI commands).
4. Deploy the Function App code package using `func azure functionapp publish <function-app-name>` or your CI/CD pipeline.
5. Enable and configure datasets in the Function App's application settings or `datasets.json`.

## Permission model

The connector uses a **system-assigned managed identity** for all authentication instead of connection strings or API keys. This approach:

- **Eliminates secrets**: Credentials are issued and rotated automatically by Azure.
- **Improves auditability**: All API calls are attributed to the managed identity.
- **Reduces attack surface**: No credentials to leak in code or configuration.
- **Follows least-privilege principles**: Permissions are scoped to specific APIs and operations.

We do not use Entra directory roles (like "Global Reader") because they grant broad permissions across all cloud services. Instead, we assign specific application-level permissions to the Microsoft Defender API service principal, which is more granular and aligned with the principle of least privilege.



