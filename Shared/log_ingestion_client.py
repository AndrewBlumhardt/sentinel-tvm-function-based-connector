from __future__ import annotations

from azure.monitor.ingestion import LogsIngestionClient


class LogIngestionClient:
    def __init__(self, endpoint: str, credential) -> None:
        self._client = LogsIngestionClient(endpoint=endpoint, credential=credential, logging_enable=True)

    def upload(self, rule_id: str, stream_name: str, records: list[dict[str, object]]) -> None:
        self._client.upload(rule_id=rule_id, stream_name=stream_name, logs=records)
