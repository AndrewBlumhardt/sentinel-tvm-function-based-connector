# scripts folder

This folder contains deployment, permission, and local validation scripts used by this connector.

## Scripts

- `deploy.ps1`
  - Deploys infrastructure and function app settings from `../infra/main.bicep`.
  - Handles cloud context, login checks, resource group validation, and DCR mapping app settings.
  - Reads dataset metadata from `../Functions/datasets.json`.
  - Writes per-dataset app settings in sortable format: `Enabled_<DatasetName>` and `DcrRuleId_<DatasetName>`.
- `set-managed-identity-defender-permissions.ps1`
  - Grants Defender API application permissions to the Function App managed identity.
  - Optionally grants admin consent when `-GrantAdminConsent` is supplied.
- `check_deploy.ps1`
  - Quick parser check for `deploy.ps1`.
  - Returns pass/fail output for basic syntax validation.
- `test_parser.ps1`
  - Detailed parser validation for `deploy.ps1` with line/column syntax error reporting.
- `migrate-dataset-setting-names.ps1`
  - Migrates legacy app setting names (`Dataset__<DatasetName>__enabled` and `Dataset__<DatasetName>__dcrRuleId`) to `Enabled_<DatasetName>` and `DcrRuleId_<DatasetName>`.
  - Dry-run by default. Use `-Apply` to write renamed settings and `-RemoveLegacy` to delete legacy names after verification.

## Typical order of use

1. Run `deploy.ps1`.
2. Run `migrate-dataset-setting-names.ps1` if you need to rename existing Function App settings.
3. Run `set-managed-identity-defender-permissions.ps1`.
4. Run `check_deploy.ps1` or `test_parser.ps1` when editing deployment script logic.
