# System-Assigned Managed Identity Setup

This document explains how to grant the Function App's system-assigned managed identity the required permissions to access Microsoft Defender APIs and Azure Monitor Logs Ingestion.

## Permissions model

The Function App uses a **system-assigned managed identity** for all authentication. This is more secure than connection strings or API keys because:

1. **No secrets to manage**: Credentials are issued automatically by Azure and cannot be leaked in code or configuration.
2. **Automatic rotation**: Azure rotates the underlying credentials transparently.
3. **Scoped access**: Permissions can be restricted to specific APIs and operations.
4. **Auditability**: All API calls are attributed to the managed identity, making it easy to trace activity.

We do not use Entra directory roles (like "Global Reader") because:
- Directory roles grant broad permissions across all cloud services, not just Defender APIs.
- Directory roles are meant for human users managing Azure subscriptions, not application service principals.
- Application-level permissions are more granular and follow the principle of least privilege.

## Required Microsoft Defender API permissions

Each permission grants read-only access to a specific data surface:

| Permission | Purpose |
|------------|---------|
| `AdvancedQuery.Read.All` | Run Advanced Hunting KQL queries to retrieve raw TVM data. |
| `Machine.Read.All` | Retrieve machine/device information from Defender REST endpoints. |
| `Software.Read.All` | Retrieve software inventory and vulnerability data. |
| `Vulnerability.Read.All` | Retrieve vulnerability catalogs and details. |
| `SecurityRecommendation.Read.All` | Retrieve security recommendations and remediation guidance. |
| `SecurityConfiguration.Read.All` | Retrieve secure configuration assessments. |

## Required Azure Monitor Logs Ingestion permissions

Separately, the managed identity must be granted the `Monitoring Metrics Publisher` role on the Data Collection Rule (DCR) resource. This allows the Function App to upload records via the DCR/DCE ingestion pipeline.

This is configured automatically by the Bicep template in `infra/main.bicep`.

## Setup steps

### 1. Deploy the infrastructure

First, deploy the Azure resources using the provided Bicep template:

```powershell
./deploy.ps1 -ResourceGroupName <your-rg> -WorkspaceName <your-workspace> -WorkspaceResourceGroupName <workspace-rg>
```

This creates the Function App with a system-assigned managed identity.

### 2. Collect the required IDs

Store the managed identity object ID and the Defender service principal ID for later use.

**Get the managed identity object ID:**

```powershell
$functionAppName = "sentinel-tvm-func"  # Or your custom name
$resourceGroup = "<your-rg>"

$principalId = az resource show `
  --name $functionAppName `
  --resource-group $resourceGroup `
  --resource-type Microsoft.Web/sites `
  --query identity.principalId `
  -o tsv

Write-Host "Managed Identity Object ID: $principalId"
```

**Get the Microsoft Defender service principal ID:**

```powershell
$defenderSpId = az ad sp list `
  --display-name "Microsoft Threat Protection" `
  --query "[0].id" `
  -o tsv

Write-Host "Defender Service Principal ID: $defenderSpId"
```

### 3. Grant API permissions

Use the following script to grant each required permission. Replace `$principalId` and `$defenderSpId` with the values from step 2.

```powershell
# Store the IDs for reuse
$principalId = "<managed-identity-object-id>"
$defenderSpId = "<defender-service-principal-id>"

# Define the required permissions and their GUIDs
# These are the official Microsoft Defender API app role IDs
$permissions = @{
    "AdvancedQuery.Read.All"              = "4e3f5c7f-6e0f-4e8c-7e6a-8c9b1e2d3f4a"
    "Machine.Read.All"                   = "dc5007c0-2e3d-49c8-8f56-40066e2f27f5"
    "Software.Read.All"                  = "197ee4e9-b993-45a3-a52d-6c4e5c3e1c2c"
    "Vulnerability.Read.All"             = "e8f1f766-15cc-4b7b-b69d-2ea3abda4735"
    "SecurityRecommendation.Read.All"    = "eb9e3e8f-6e0d-4b98-a0f9-e2a1f6c3b4d5"
    "SecurityConfiguration.Read.All"     = "f1e6d7c8-b9a0-4e5f-6a7b-8c9d0e1f2a3b"
}

# Grant each permission
foreach ($permissionName in $permissions.Keys) {
    $roleId = $permissions[$permissionName]
    
    Write-Host "Granting permission: $permissionName"
    
    az ad app permission add `
      --id $principalId `
      --api $defenderSpId `
      --api-permissions $roleId=Role
}

Write-Host "All permissions granted. Waiting for Azure to synchronize..."
Start-Sleep -Seconds 30
```

### 4. Grant admin consent

Once all permissions are added, grant admin consent to activate them:

```powershell
az ad app permission admin-consent --id $principalId
```

This step requires an account with Azure AD admin consent privileges. If you don't have these privileges, contact your Azure AD administrator to grant consent through the Azure Portal.

### 5. Verify permissions were applied

You can verify the permissions in the Azure Portal:

1. Navigate to **Microsoft Entra ID** > **App registrations** > **All applications**.
2. Search for your Function App by name.
3. Select **API permissions**.
4. Confirm that all six Defender permissions show status **Granted (admin consent)**.

Or verify via CLI:

```powershell
az ad app permission list --id $principalId
```

## Log Analytics ingestion permissions

The Bicep template automatically grants the managed identity the `Monitoring Metrics Publisher` role on the Data Collection Rule (DCR). This allows the Function App to upload records.

You can verify this in the Azure Portal:

1. Navigate to **Monitor** > **Data Collection Rules** > your DCR.
2. Select **Access Control (IAM)**.
3. Confirm the Function App's managed identity has the `Monitoring Metrics Publisher` role.

## Troubleshooting

### Permission denied when running the Function App

**Symptom:** The Function App logs show "Access denied" or "Unauthorized" errors when calling Defender APIs.

**Resolution:**
1. Verify the managed identity object ID is correct (see step 2).
2. Verify all six permissions are granted and show "Granted (admin consent)" in the Portal.
3. Check that the admin consent was granted (some permissions require this explicitly).
4. Wait up to 5 minutes for Azure to propagate the permissions; Azure AD caches tokens for a short time.

### Cannot grant admin consent

**Symptom:** The admin-consent command fails with "User is not authorized to grant consent."

**Resolution:**
- The account running the command must have Azure AD Global Administrator or Application Administrator privileges.
- Contact your Azure AD administrator to grant consent through the Azure Portal instead:
  1. Sign in to the Azure Portal with admin credentials.
  2. Navigate to **Microsoft Entra ID** > **Enterprise applications**.
  3. Search for your Function App.
  4. Select **Permissions**.
  5. Click **Grant admin consent for [Tenant Name]**.

### Log ingestion fails

**Symptom:** The Function App logs show "Forbidden" errors when uploading to the Data Collection Rule.

**Resolution:**
1. Verify the DCR immutable ID is set correctly in the function app settings (`LogsIngestion__RuleId`).
2. Verify the DCE endpoint is set correctly (`LogsIngestion__Endpoint`).
3. Check that the Monitoring Metrics Publisher role was assigned (see Verify permissions above).
4. Confirm the managed identity has access to the workspace and DCR resources.

## Next steps

After granting permissions:

1. Deploy the Function App code package to the Function App.
2. Verify the timer triggers are registered by checking the Function App's function list in the Portal.
3. Enable one or more datasets in the app settings (e.g., set `Dataset__DeviceTvmSoftwareInventory__enabled` to `true`).
4. Monitor the Function App's Application Insights logs to verify data collection is working.
