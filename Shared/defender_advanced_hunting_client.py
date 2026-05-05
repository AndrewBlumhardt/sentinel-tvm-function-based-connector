from __future__ import annotations

from collections.abc import Iterator

import requests

from Shared.models import DatasetConfig
from Shared.retry_policy import RetryPolicy


class DefenderAdvancedHuntingClient:
    def __init__(self, token_provider, retry_policy: RetryPolicy) -> None:
        self._token_provider = token_provider
        self._retry_policy = retry_policy
        self._session = requests.Session()
        self._base_url = "https://api.security.microsoft.com"

    def iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        page_size = dataset.page_size
        page_index = 0
        while True:
            query = self._build_query(dataset, skip=page_index * page_size, take=page_size)
            response_json = self._retry_policy.run(lambda: self._post_query(query))
            rows = response_json.get("Results", [])
            if not rows:
                break
            yield rows
            if len(rows) < page_size:
                break
            page_index += 1

    def _build_query(self, dataset: DatasetConfig, skip: int, take: int) -> str:
        base = (dataset.query or dataset.name).strip().rstrip(";")
        if "|" not in base:
            base = f"{base}"
        order_by = dataset.page_order_by or "Timestamp asc"
        return f"{base} | order by {order_by} | skip {skip} | take {take}"

    def _post_query(self, query: str) -> dict[str, object]:
        token = self._token_provider.get_token("https://api.security.microsoft.com/.default")
        response = self._session.post(
            f"{self._base_url}/api/advancedqueries/run",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json={"Query": query},
            timeout=300,
        )
        response.raise_for_status()
        return response.json()
