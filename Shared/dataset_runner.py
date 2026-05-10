from __future__ import annotations

import json
from collections.abc import Iterator

from Shared.batch_processor import iter_batches
from Shared.dataset_registry import DatasetRegistry
from Shared.json_flattener import JsonFlattener
from Shared.metadata import create_snapshot_context, enrich_record
from Shared.models import AppSettings, DatasetConfig
from Shared.telemetry_logger import get_logger


class DatasetRunner:
    def __init__(
        self,
        registry: DatasetRegistry,
        app_settings: AppSettings,
        hunting_client,
        rest_client,
        nist_client,
        ingestion_client,
    ) -> None:
        self._registry = registry
        self._app_settings = app_settings
        self._hunting_client = hunting_client
        self._rest_client = rest_client
        self._nist_client = nist_client
        self._ingestion_client = ingestion_client
        self._flattener = JsonFlattener()
        self._logger = get_logger()

    def run_dataset(self, dataset_name: str) -> dict[str, int | str]:
        dataset = self._registry.get(dataset_name)
        if not dataset.enabled:
            self._logger.info("Dataset %s is disabled; skipping timer run.", dataset.name)
            return {"dataset": dataset.name, "ingested": 0, "pages": 0}

        if not self._app_settings.logs_ingestion_endpoint:
            raise ValueError("Logs ingestion endpoint is required before dataset execution.")

        rule_id = dataset.dcr_rule_id or self._app_settings.logs_ingestion_rule_id
        if not rule_id:
            raise ValueError(
                f"No DCR rule ID configured for dataset '{dataset.name}'. "
                "Set Dataset__<DatasetName>__dcrRuleId or LogsIngestion__RuleId."
            )

        snapshot_context = create_snapshot_context()
        metadata = {
            **snapshot_context,
            "SourceType": dataset.source_type,
            "SourceName": dataset.normalized_source_name,
            "DestinationTable": dataset.destination_table,
            "CollectionMode": dataset.collection_mode,
            "CollectorVersion": self._app_settings.collector_version,
        }

        ingested = 0
        pages = 0
        for page in self._iter_pages(dataset):
            pages += 1
            transformed = (self._transform_record(dataset, row, metadata) for row in page)
            for batch in iter_batches(transformed, dataset.batch_size):
                self._ingestion_client.upload(
                    rule_id=rule_id,
                    stream_name=dataset.stream_name,
                    records=batch,
                )
                ingested += len(batch)

        self._logger.info("Dataset %s completed. Pages=%s Records=%s", dataset.name, pages, ingested)
        return {"dataset": dataset.name, "ingested": ingested, "pages": pages}

    def _iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        if dataset.source_type == "AdvancedHunting":
            return self._hunting_client.iter_pages(dataset)
        if dataset.source_type == "DefenderRestApi":
            return self._rest_client.iter_pages(dataset)
        if dataset.source_type == "NistApi":
            return self._nist_client.iter_pages(dataset)
        raise ValueError(f"Unsupported sourceType '{dataset.source_type}'.")

    def _transform_record(
        self,
        dataset: DatasetConfig,
        record: dict[str, object],
        metadata: dict[str, object],
    ) -> dict[str, object]:
        flattened = self._flattener.flatten(record)
        envelope = {
            "TimeGenerated": metadata["SnapshotTime"],
            "DatasetName": dataset.name,
            "PayloadJson": json.dumps(flattened, ensure_ascii=True, separators=(",", ":")),
        }
        return enrich_record(envelope, metadata)
