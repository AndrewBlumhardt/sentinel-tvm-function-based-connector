from __future__ import annotations

from collections.abc import Iterator

import requests

from Shared.models import DatasetConfig
from Shared.retry_policy import RetryPolicy


class DefenderAdvancedHuntingClient:
    """Advanced Hunting client targeting the Microsoft Graph runHuntingQuery endpoint.

    Uses POST {graph}/v1.0/security/runHuntingQuery, which requires the
    ThreatHunting.Read.All application role on the Microsoft Graph service
    principal. This is the same API the Logic App-based TVM connector uses and
    avoids the legacy MDATP /api/advancedqueries/run endpoint that requires the
    separate AdvancedQuery.Read.All role on the WindowsDefenderATP SP.
    """

    HUNTING_PATH = "/v1.0/security/runHuntingQuery"

    def __init__(self, token_provider, retry_policy: RetryPolicy, base_url: str = "https://graph.microsoft.com") -> None:
        self._token_provider = token_provider
        self._retry_policy = retry_policy
        self._session = requests.Session()
        self._base_url = base_url.rstrip("/")

    def iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        page_size = dataset.page_size
        page_index = 0
        while True:
            query = self._build_query(dataset, skip=page_index * page_size, take=page_size)
            response_json = self._retry_policy.run(lambda: self._post_query(query))
            # Graph returns lowercase 'results'; tolerate legacy 'Results' as well.
            rows = response_json.get("results") or response_json.get("Results") or []
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
        token = self._token_provider.get_token(f"{self._base_url}/.default")
        url = f"{self._base_url}{self.HUNTING_PATH}"
        response = self._session.post(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            },
            json={"Query": query},
            timeout=300,
        )
        if not response.ok:
            body = (response.text or "")[:2000]
            raise requests.HTTPError(
                f"Defender Advanced Hunting POST failed: status={response.status_code} url={url} body={body}",
                response=response,
            )
        return response.json()
