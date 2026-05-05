# Shared folder

This folder contains the reusable ingestion framework used by all dataset timer functions.

## Purpose

- Keep dataset function files small and consistent.
- Provide shared clients, configuration, transformation, batching, retry, and orchestration.
- Implement a streaming ingestion pattern: page -> transform -> batch -> ingest -> clear.

## Files

- `__init__.py`: package marker.
- `runtime.py`: constructs and caches the runtime graph (config, clients, runner).
- `dataset_runner.py`: main workflow orchestration for each dataset execution.
- `models.py`: configuration data models.
- `config_loader.py`: loads app settings and dataset configuration.
- `dataset_registry.py`: dataset lookup and registry operations.
- `metadata.py`: creates snapshot metadata and stamps records.
- `json_flattener.py`: flattens nested JSON payloads.
- `batch_processor.py`: groups transformed records into upload batches.
- `retry_policy.py`: retry helper for resilient API calls.
- `telemetry_logger.py`: logging helper for function diagnostics.

### External source and destination clients

- `defender_auth_provider.py`: managed identity token provider.
- `defender_advanced_hunting_client.py`: Advanced Hunting query execution with paging.
- `defender_rest_client.py`: Defender REST endpoint paging client.
- `nist_client.py`: optional NIST API paging client.
- `log_ingestion_client.py`: Azure Monitor Logs Ingestion API uploader.

## Notes

- This folder is the best starting point for understanding processing behavior.
- Most enhancements (new transforms, retry behavior, metadata, upload controls) are made here.
