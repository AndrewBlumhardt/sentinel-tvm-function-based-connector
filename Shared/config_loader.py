from __future__ import annotations

import json
import os
from pathlib import Path

from Shared.models import AppSettings, DatasetConfig


class ConfigLoader:
    def __init__(self, root_path: Path | None = None) -> None:
        self._root_path = root_path or Path(__file__).resolve().parent.parent

    def load_app_settings(self) -> AppSettings:
        return AppSettings(
            dataset_config_path=os.getenv("DatasetConfigPath", "datasets.json"),
            collector_version=os.getenv("CollectorVersion", "0.1.0"),
            logs_ingestion_endpoint=os.getenv("LogsIngestion__Endpoint", ""),
            logs_ingestion_rule_id=os.getenv("LogsIngestion__RuleId", ""),
            managed_identity_client_id=os.getenv("ManagedIdentity__ClientId") or None,
            nist_api_key=os.getenv("Nist__ApiKey") or None,
        )

    def load_datasets(self) -> list[DatasetConfig]:
        app_settings = self.load_app_settings()
        raw_config = json.loads(self._resolve_path(app_settings.dataset_config_path).read_text(encoding="utf-8"))
        collector_version = raw_config.get("collectorVersion") or app_settings.collector_version
        datasets: list[DatasetConfig] = []
        for item in raw_config.get("datasets", []):
            name = item["name"]
            enabled = self._get_bool_override(name, item.get("enabled", True))
            batch_size = self._get_int_override(name, "batchSize", item.get("batchSize", 500))
            page_size = self._get_int_override(name, "pageSize", item.get("pageSize", 10000))
            request_delay_ms = self._get_int_override(name, "requestDelayMs", item.get("requestDelayMs", 0))
            datasets.append(
                DatasetConfig(
                    name=name,
                    enabled=enabled,
                    source_type=item["sourceType"],
                    query=self._get_text_override(name, "query", item.get("query")),
                    endpoint=self._get_text_override(name, "endpoint", item.get("endpoint")),
                    destination_table=self._get_text_override(name, "destinationTable", item["destinationTable"]),
                    dcr_stream_name=self._get_text_override(name, "dcrStreamName", item.get("dcrStreamName")),
                    dcr_rule_id=self._get_text_override(name, "dcrRuleId", item.get("dcrRuleId")),
                    schedule_setting=self._get_text_override(name, "scheduleSetting", item["scheduleSetting"]),
                    batch_size=batch_size,
                    page_size=page_size,
                    collection_mode=self._get_text_override(name, "collectionMode", item.get("collectionMode", "FullSnapshot")) or "FullSnapshot",
                    page_order_by=self._get_text_override(name, "pageOrderBy", item.get("pageOrderBy")),
                    source_name=self._get_text_override(name, "sourceName", item.get("sourceName")),
                    request_delay_ms=request_delay_ms,
                    transform_mode=self._get_text_override(name, "transformMode", item.get("transformMode", "default")) or "default",
                    extra_params=item.get("extraParams") or {},
                )
            )
        os.environ.setdefault("CollectorVersion", collector_version)
        return datasets

    def _resolve_path(self, raw_path: str) -> Path:
        path = Path(raw_path)
        if path.is_absolute():
            return path
        return self._root_path / path

    def _get_env_name(self, dataset_name: str, property_name: str) -> str:
        return f"Dataset__{dataset_name}__{property_name}"

    def _get_text_override(self, dataset_name: str, property_name: str, fallback: str | None) -> str | None:
        return os.getenv(self._get_env_name(dataset_name, property_name), fallback)

    def _get_bool_override(self, dataset_name: str, fallback: bool) -> bool:
        value = os.getenv(self._get_env_name(dataset_name, "enabled"))
        if value is None:
            return fallback
        return value.strip().lower() in {"1", "true", "yes", "on"}

    def _get_int_override(self, dataset_name: str, property_name: str, fallback: int) -> int:
        value = os.getenv(self._get_env_name(dataset_name, property_name))
        if value is None:
            return fallback
        return int(value)
