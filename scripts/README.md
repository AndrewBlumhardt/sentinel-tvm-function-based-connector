# scripts folder

This folder contains deployment, permission, and local validation scripts used by this connector.

## Scripts

- `deploy.ps1`
  - Deploys infrastructure and function app settings from `../infra/main.bicep`.
  - Handles cloud context, login checks, resource group validation, and DCR mapping app settings.
  - Reads dataset metadata from `../Functions/datasets.json`.
  - Writes per-dataset app settings in sortable format: `DcrRuleId_<DatasetName>` (one per dataset, mapping the dataset to its DCR rule ID). Per-dataset enable/disable is **not** an app setting — use the per-function **Enable/Disable** toggle on the Function App's **Functions** blade, or set `"enabled": false` on the dataset in `Functions/datasets.json` and redeploy.
- `set-managed-identity-defender-permissions.ps1`
  - Grants Defender API application permissions to the Function App managed identity.
  - Optionally grants admin consent when `-GrantAdminConsent` is supplied.
- `check_deploy.ps1`
  - Quick parser check for `deploy.ps1`.
  - Returns pass/fail output for basic syntax validation.
- `test_parser.ps1`
  - Detailed parser validation for `deploy.ps1` with line/column syntax error reporting.
- `migrate-dataset-setting-names.ps1`
  - Migrates the legacy `Dataset__<DatasetName>__dcrRuleId` app setting names to the current `DcrRuleId_<DatasetName>` shape that `deploy.ps1` emits.
  - Dry-run by default. Use `-Apply` to write renamed settings and `-RemoveLegacy` to delete legacy names after verification.
  - Only needed if you're updating a Function App that was first deployed with an older version of this repo. Fresh deployments already use the new names.

## Typical order of use

1. Run `deploy.ps1`.
2. Run `migrate-dataset-setting-names.ps1` if you need to rename existing Function App settings.
3. Run `set-managed-identity-defender-permissions.ps1`.
4. Run `check_deploy.ps1` or `test_parser.ps1` when editing deployment script logic.
