# infra folder

This folder contains infrastructure-as-code assets for deploying the connector resources.

## Purpose

- Provision the Function App and required platform resources.
- Provision Data Collection Endpoint (DCE), Data Collection Rule (DCR), and custom tables.
- Keep infrastructure repeatable and source-controlled.

## Files

- `main.bicep`: primary infrastructure template.
  - Creates or configures core resources for the ingestion pipeline.
  - Defines app settings used by the Function App.
  - Wires logs ingestion path to destination tables.
- `main.parameters.sample.json`: sample parameter file to help with deployments.
- `main.json`: compiled ARM template output generated from `main.bicep`.
- `modules/`: reusable Bicep modules referenced by `main.bicep`.

## modules folder

- `workspaceTables.bicep`: module that creates/updates workspace custom tables based on dataset configuration.

## Notes

- Deployment entry point is `../scripts/deploy.ps1`, which calls `main.bicep` with the required parameters.
- These resources support the Function App ingestion workflow (not a Logic App workflow).
