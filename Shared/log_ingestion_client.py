from __future__ import annotations

from azure.monitor.ingestion import LogsIngestionClient


def _resolve_credential_scope(endpoint: str) -> str:
    """Pick the right Azure Monitor audience based on the DCE host.

    The azure-monitor-ingestion SDK defaults to ``https://monitor.azure.com/.default``,
    which is wrong on sovereign clouds and produces ``InvalidAudience`` from the DCE.
    """
    host = (endpoint or "").lower()
    if ".monitor.azure.us" in host or host.endswith(".us"):
        return "https://monitor.azure.us/.default"
    if ".monitor.azure.cn" in host or host.endswith(".cn"):
        return "https://monitor.azure.cn/.default"
    return "https://monitor.azure.com/.default"


class LogIngestionClient:
    def __init__(self, endpoint: str, credential) -> None:
        scope = _resolve_credential_scope(endpoint)
        self._client = LogsIngestionClient(
            endpoint=endpoint,
            credential=credential,
            credential_scopes=[scope],
        )

    def upload(self, rule_id: str, stream_name: str, records: list[dict[str, object]]) -> None:
        """Upload one batch of transformed records to the configured DCR stream."""
        self._client.upload(rule_id=rule_id, stream_name=stream_name, logs=records)
