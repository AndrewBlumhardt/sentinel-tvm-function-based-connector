# Deployment Notes

## Required configuration

The Function App expects these application settings:

- `DatasetConfigPath`
- `LogsIngestion__Endpoint`
- `LogsIngestion__RuleId`
- `ManagedIdentity__ClientId` when using a user-assigned identity instead of the default system-assigned identity
- one `Schedule_*` setting per timer-triggered dataset

## Managed identity permissions

Grant the Function App managed identity the permissions needed to:

1. Acquire tokens for `https://api.security.microsoft.com/.default` and call the Defender APIs used by enabled datasets.
2. Acquire tokens for Azure Monitor Logs Ingestion and upload to the target DCR stream(s).
3. Access the DCR and DCE resources referenced by `LogsIngestion__RuleId` and `LogsIngestion__Endpoint`.

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
