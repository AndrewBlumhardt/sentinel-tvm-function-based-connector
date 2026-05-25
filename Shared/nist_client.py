"""NIST NVD 2.0 API client used by the ``Nist*`` datasets.

Pages via ``startIndex``/``resultsPerPage`` until ``totalResults`` is reached.
Unauthenticated callers are rate-limited (5 req / 30s); set ``Nist__ApiKey``
to raise the limit to 50 req / 30s. ``requestDelayMs`` in the dataset config
gives a simple way to throttle between page calls.

Transform modes: ``cve_summary`` projects the CVE record itself; the default
flattens the CPE match list into one row per ``cpeMatch``.
"""
from __future__ import annotations

import time
from collections.abc import Iterator

import requests

from Shared.models import DatasetConfig
from Shared.retry_policy import RetryPolicy


class NistClient:
    def __init__(self, api_key: str | None, retry_policy: RetryPolicy) -> None:
        self._api_key = api_key
        self._retry_policy = retry_policy
        self._session = requests.Session()

    def iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        start_index = 0
        total_results: int | None = None
        while total_results is None or start_index < total_results:
            response_json = self._retry_policy.run(lambda: self._get_page(dataset, start_index))
            vulnerabilities = response_json.get("vulnerabilities", [])
            total_results = int(response_json.get("totalResults", 0))
            if not vulnerabilities:
                break
            if dataset.transform_mode == "cve_summary":
                rows = [item.get("cve", {}) for item in vulnerabilities if isinstance(item, dict)]
            else:
                rows = self._extract_cpe_rows(vulnerabilities)
            if rows:
                yield rows
            start_index += int(response_json.get("resultsPerPage", dataset.page_size))
            if dataset.request_delay_ms > 0:
                time.sleep(dataset.request_delay_ms / 1000)

    def _get_page(self, dataset: DatasetConfig, start_index: int) -> dict[str, object]:
        headers = {}
        if self._api_key:
            headers["apiKey"] = self._api_key
        response = self._session.get(
            dataset.endpoint,
            headers=headers,
            params={
                "startIndex": start_index,
                "resultsPerPage": dataset.page_size,
            },
            timeout=300,
        )
        response.raise_for_status()
        return response.json()

    def _extract_cpe_rows(self, vulnerabilities: list[dict[str, object]]) -> list[dict[str, object]]:
        rows: list[dict[str, object]] = []
        for item in vulnerabilities:
            cve = item.get("cve", {}) if isinstance(item, dict) else {}
            configurations = cve.get("configurations", []) if isinstance(cve, dict) else []
            for configuration in configurations:
                nodes = configuration.get("nodes", []) if isinstance(configuration, dict) else []
                for node in nodes:
                    for cpe_match in node.get("cpeMatch", []):
                        if isinstance(cpe_match, dict):
                            rows.append({
                                "CveId": cve.get("id"),
                                "Operator": node.get("operator"),
                                **cpe_match,
                            })
        return rows
