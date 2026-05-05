from __future__ import annotations

from collections.abc import Iterator

import requests

from Shared.models import DatasetConfig
from Shared.retry_policy import RetryPolicy


class DefenderRestClient:
    def __init__(self, token_provider, retry_policy: RetryPolicy) -> None:
        self._token_provider = token_provider
        self._retry_policy = retry_policy
        self._session = requests.Session()
        self._base_url = "https://api.security.microsoft.com"

    def iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        next_url: str | None = self._build_url(dataset.endpoint or "")
        skip = 0
        while next_url:
            current_url = next_url
            response_json = self._retry_policy.run(lambda: self._get_page(current_url, dataset.page_size, skip))
            rows = self._extract_rows(response_json)
            if not rows:
                break
            yield rows
            next_url = response_json.get("@odata.nextLink")
            if not next_url:
                if len(rows) < dataset.page_size:
                    break
                skip += dataset.page_size

    def _get_page(self, url: str, top: int, skip: int) -> dict[str, object]:
        token = self._token_provider.get_token("https://api.security.microsoft.com/.default")
        response = self._session.get(
            url,
            headers={"Authorization": f"Bearer {token}"},
            params={"$top": top, "$skip": skip},
            timeout=300,
        )
        response.raise_for_status()
        return response.json()

    def _extract_rows(self, response_json: dict[str, object]) -> list[dict[str, object]]:
        value = response_json.get("value")
        if isinstance(value, list):
            return [row for row in value if isinstance(row, dict)]
        if isinstance(response_json, list):
            return [row for row in response_json if isinstance(row, dict)]
        return []

    def _build_url(self, endpoint: str) -> str:
        if endpoint.startswith("https://"):
            return endpoint
        return f"{self._base_url}{endpoint}"
