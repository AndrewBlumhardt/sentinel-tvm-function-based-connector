"""Runs one dataset end-to-end: page from upstream, transform, upload to a DCR.

Dispatches to the right upstream client (Advanced Hunting via Graph, Defender
REST, or NIST) based on ``sourceType``, flattens nested JSON to match the table
schema, batches the rows, and POSTs each batch through the Logs Ingestion API.

Disabled datasets are skipped with an info-level log line. A missing DCR rule
ID (neither per-dataset ``DcrRuleId_<Name>`` nor global ``LogsIngestion__RuleId``)
is a hard failure — the dataset cannot ingest without a stream destination.
"""
from __future__ import annotations

import json
from collections.abc import Iterator

from Shared.batch_processor import iter_batches
from Shared.dataset_registry import DatasetRegistry
from Shared.json_flattener import JsonFlattener
from Shared.metadata import create_snapshot_context
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
        """Execute one dataset collection run and return ingestion counts."""
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
                "Set DcrRuleId_<DatasetName> or LogsIngestion__RuleId."
            )

        metadata = create_snapshot_context()

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
        """Dispatch page iteration to the matching upstream source client."""
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
        """Project one source row into the declared table schema and stamp shared ingestion fields."""
        flattened = self._flattener.flatten(record)
        transformed: dict[str, object] = {}

        for column in dataset.columns:
            if column.name == "TimeGenerated":
                continue

            source_value = record.get(column.name)
            if column.type == "dynamic":
                dynamic_value = self._coerce_dynamic_value(source_value)
                if dynamic_value is not None:
                    transformed[column.name] = dynamic_value
                continue

            flattened_value = flattened.get(column.name)
            if flattened_value is not None:
                transformed[column.name] = flattened_value
            elif source_value is not None:
                transformed[column.name] = source_value

        transformed["TimeGenerated"] = metadata["TimeGenerated"]
        return transformed

    def _coerce_dynamic_value(self, value: object) -> object | None:
        if value is None:
            return None
        if isinstance(value, str):
            try:
                return json.loads(value)
            except json.JSONDecodeError:
                return value
        return value
