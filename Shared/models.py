from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class DatasetConfig:
    name: str
    enabled: bool
    source_type: str
    destination_table: str
    schedule_setting: str
    batch_size: int
    page_size: int
    collection_mode: str
    dcr_stream_name: str | None = None
    query: str | None = None
    endpoint: str | None = None
    page_order_by: str | None = None
    source_name: str | None = None
    request_delay_ms: int = 0
    transform_mode: str = "default"
    extra_params: dict[str, Any] | None = None

    @property
    def stream_name(self) -> str:
        if self.dcr_stream_name:
            return self.dcr_stream_name
        return f"Custom-{self.destination_table.removesuffix('_CL')}"

    @property
    def normalized_source_name(self) -> str:
        if self.source_name:
            return self.source_name
        if self.query:
            return self.query.split("|")[0].strip()
        return self.endpoint or self.name


@dataclass(frozen=True)
class AppSettings:
    dataset_config_path: str
    collector_version: str
    logs_ingestion_endpoint: str
    logs_ingestion_rule_id: str
    managed_identity_client_id: str | None = None
    nist_api_key: str | None = None
