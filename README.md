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
- `Functions/`: timer trigger entry points (see `Functions/README.md`).
- `Shared/`: shared config, auth, paging, transformation, batching, retries, and ingestion (see `Shared/README.md`).
- `infra/`: infrastructure as code for Function App, DCR/DCE, and tables (see `infra/README.md`).
- `deploy.ps1`: wrapper for group deployment with workspace parameters.
- `docs/deployment.md`: deployment and DCR/DCE notes.
- `docs/source-comparison.md`: guidance on comparing Advanced Hunting with REST datasets.
- `images/`: screenshots and diagrams used in documentation.

## Repository outline

This section is a quick tour for readers who are new to Azure Functions, Bicep, and Defender API integrations.

### Root files

- `README.md`: primary guide, deployment flow, and permission setup commands.
- `host.json`: Azure Functions host-level runtime configuration.
- `function_app.py`: top-level function registration entry point.
- `requirements.txt`: Python dependencies for local and cloud execution.
- `datasets.json`: dataset definitions (source type, destination table, schedule setting, batch/page behavior).
- `local.settings.sample.json`: local development app settings template.
- `deploy.ps1`: PowerShell deployment wrapper for `infra/main.bicep`.
- `.funcignore`: files excluded from function deployment packaging.
- `.gitignore`: files excluded from source control.
- `pyrightconfig.json`: Python analysis configuration for editor tooling.

### Root folders

- `Functions/`: one timer-trigger module per dataset and shared timer trigger helper.
- `Shared/`: reusable service layer used by all dataset timers.
- `infra/`: Bicep/ARM infrastructure definitions and deployment parameters.
- `docs/`: supplemental documentation and comparison notes.
- `images/`: screenshots and visual assets for the README/docs.

### Primary folders at a glance

- `Functions/`: thin function entry points only; logic stays in `Shared/`.
- `Shared/`: ingestion pipeline components (auth, clients, flattening, batching, retries, runner).
- `infra/`: resource deployment model for Function App + ingestion path (DCR/DCE/custom tables).

## Validation status

The scaffold compiles successfully with `python -m compileall .`.

## Azure deployment

1. Ensure you already have a Log Analytics workspace that backs your Microsoft Sentinel deployment.
2. Deploy the infrastructure with `./deploy.ps1`.
3. Grant the Function App's managed identity the required Microsoft Defender API permissions using the CLI steps below.
4. Deploy the Function App code package using `func azure functionapp publish <function-app-name>` or your CI/CD pipeline.
5. Enable and configure datasets in the Function App's application settings or `datasets.json`.

### Deployment script examples

For Azure GCC High (Azure Government), the script defaults to `AzureUSGovernment` cloud:

```powershell
./deploy.ps1 `
	-ResourceGroupName <rg> `
	-WorkspaceName <workspace> `
	-WorkspaceResourceGroupName <workspace-rg> `
	-SubscriptionId <subscription-id>
```

For public Azure, set the cloud explicitly:

```powershell
./deploy.ps1 `
	-CloudName AzureCloud `
	-ResourceGroupName <rg> `
	-WorkspaceName <workspace> `
	-WorkspaceResourceGroupName <workspace-rg> `
	-SubscriptionId <subscription-id>
```

Optional script parameters:

- `-TenantId`: tenant override for login.
- `-Location`: deployment location override.
- `-NamePrefix`: resource naming prefix.
- `-FunctionAppName`: explicit Function App name.
- `-SkipLogin`: skip `az login` if already authenticated.

Important: Azure Monitor DCR enforces a maximum of 10 `dataFlows` per DCR. This repository has more datasets than that, so the deployment automatically partitions datasets across multiple DCR resources and then applies `Dataset__<DatasetName>__dcrRuleId` app settings on the Function App. This routing step is handled by `deploy.ps1` after infrastructure deployment.

### Example deployed resources

![Example deployed resources in Azure portal](images/resources.png)

What you are seeing in that resource group:

- `sentinel-tvm-appi` (Application Insights): telemetry destination for Function App logs, traces, failures, and performance data.
- `sentinel-tvm-dce` (Data Collection Endpoint): ingestion endpoint used by Azure Monitor Logs Ingestion API.
- `sentinel-tvm-dcr-01`, `sentinel-tvm-dcr-02`, `sentinel-tvm-dcr-03` (Data Collection Rules): rules that map incoming records to custom Log Analytics tables. Multiple rules are created because a single DCR supports up to 10 `dataFlows`.
- `sentinel-tvm-func` (Function App): runtime host for timer-triggered dataset collectors.
- `sentinel-tvm-plan` (App Service plan): compute plan backing the Function App.
- `stgt6iif5iv4lqm4` (Storage account): required Azure Functions storage for runtime/state/host operations.

## Permission model

The connector uses a **system-assigned managed identity** for all authentication instead of connection strings or API keys. This approach:

- **Eliminates secrets**: Credentials are issued and rotated automatically by Azure.
- **Improves auditability**: All API calls are attributed to the managed identity.
- **Reduces attack surface**: No credentials to leak in code or configuration.
- **Follows least-privilege principles**: Permissions are scoped to specific APIs and operations.

We do not use Entra directory roles (like "Global Reader") because they grant broad permissions across all cloud services. Instead, we assign specific application-level permissions to the Microsoft Defender API service principal, which is more granular and aligned with the principle of least privilege.

## Managed identity permission setup (CLI)

This section is the primary runbook for granting required API permissions to the Function App's system-assigned managed identity.

### Required Defender API application permissions

- `AdvancedQuery.Read.All`
- `Machine.Read.All`
- `Software.Read.All`
- `Vulnerability.Read.All`
- `SecurityRecommendation.Read.All`
- `SecurityConfiguration.Read.All`

These are **application permissions (app roles)** on the Microsoft Defender API service principal. They are not Entra directory roles.

Important constraints for this connector:

- There is **no single master read permission** that covers all required Defender TVM APIs.
- Each permission above must be granted explicitly to the managed identity.
- There is **no Entra directory role** that is an equivalent least-privilege replacement for these API app roles.

### Why app permissions instead of Entra roles

- Entra directory roles are broad tenant-level privileges intended for administrators.
- Application permissions scope access to specific APIs and operations.
- Least privilege is easier to enforce and audit with API app roles.

At the time of writing, the practical and repeatable way to grant these app roles for this workflow is via Azure CLI commands.

### Step 1: Get the Function App managed identity object ID

```powershell
$functionAppName = "<function-app-name>"
$resourceGroup = "<resource-group>"

$principalId = az resource show `
	--name $functionAppName `
	--resource-group $resourceGroup `
	--resource-type Microsoft.Web/sites `
	--query identity.principalId `
	-o tsv

Write-Host "Managed identity object ID: $principalId"
```

### Step 2: Get the Defender API service principal ID

```powershell
$defenderSpId = az ad sp list `
	--display-name "Microsoft Threat Protection" `
	--query "[0].id" `
	-o tsv

Write-Host "Defender service principal ID: $defenderSpId"
```

### Step 3: Resolve app role IDs dynamically and grant permissions

This avoids hardcoding role GUIDs and always uses the current role IDs in your tenant.

Note: For this scenario, treat CLI automation as the source of truth for permission assignment. There is no single "grant all Defender read" control for managed identity, and Entra directory roles do not provide the required API-level scope.

```powershell
$requiredPermissions = @(
	"AdvancedQuery.Read.All",
	"Machine.Read.All",
	"Software.Read.All",
	"Vulnerability.Read.All",
	"SecurityRecommendation.Read.All",
	"SecurityConfiguration.Read.All"
)

$roleMapJson = az ad sp show --id $defenderSpId --query "appRoles[?allowedMemberTypes && contains(allowedMemberTypes, 'Application')].{Value:value,Id:id}" -o json
$roleMap = $roleMapJson | ConvertFrom-Json

foreach ($perm in $requiredPermissions) {
	$role = $roleMap | Where-Object { $_.Value -eq $perm } | Select-Object -First 1
	if (-not $role) {
		throw "Permission '$perm' was not found on Defender service principal appRoles."
	}

	Write-Host "Granting $perm ($($role.Id))"
	az ad app permission add `
		--id $principalId `
		--api $defenderSpId `
		--api-permissions "$($role.Id)=Role"
}
```

### Step 4: Grant admin consent

```powershell
az ad app permission admin-consent --id $principalId
```

### Step 5: Verify assigned API permissions

```powershell
az ad app permission list --id $principalId -o table
```

You should see all six permission values listed and consented.

### Azure Monitor Logs Ingestion permissions

Defender API permissions are not sufficient by themselves. The Function App also needs Azure RBAC for ingestion:

- `Monitoring Metrics Publisher` on the Data Collection Rule (DCR).

The Bicep deployment configures this separately from Defender API app permissions.




