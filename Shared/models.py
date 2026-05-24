from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class DatasetColumn:
    name: str
    type: str


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
    dcr_rule_id: str | None = None
    query: str | None = None
    endpoint: str | None = None
    page_order_by: str | None = None
    source_name: str | None = None
    request_delay_ms: int = 0
    transform_mode: str = "default"
    extra_params: dict[str, Any] | None = None
    columns: list[DatasetColumn] = field(default_factory=list)

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
    # Microsoft Graph endpoint used by Advanced Hunting (POST /v1.0/security/runHuntingQuery).
    # Audience: Microsoft Graph. Required app role: ThreatHunting.Read.All on Microsoft
    # Graph SP. This is the MODERN unified hunting API — use this, not the legacy
    # /api/advancedqueries/run on the MDATP host (which requires the separate
    # AdvancedQuery.Read.All role on WindowsDefenderATP SP).
    defender_hunting_base_url: str = "https://graph.microsoft.com"
    # Legacy MDATP/MTP base URL. Retained for backward compatibility with existing
    # deployments and for the healthcheck "REST host" fallback. NOT used for hunting.
    defender_api_base_url: str = "https://api.security.microsoft.com"
    # Defender for Endpoint (WindowsDefenderATP) REST endpoint used by DefenderRestClient
    # (GET /api/<Endpoint>). On Gov this is a DIFFERENT host than Advanced Hunting:
    # api-gov.securitycenter.microsoft.us vs api-gov.security.microsoft.us. Falls back
    # to defender_api_base_url when unset (correct for commercial).
    defender_security_center_api_base_url: str | None = None
    managed_identity_client_id: str | None = None
    nist_api_key: str | None = None

    @property
    def resolved_security_center_api_base_url(self) -> str:
        return self.defender_security_center_api_base_url or self.defender_api_base_url
