from __future__ import annotations

from collections.abc import Iterator

import requests

from Shared.models import DatasetConfig
from Shared.retry_policy import RetryPolicy


class DefenderRestClient:
    def __init__(self, token_provider, retry_policy: RetryPolicy, base_url: str = "https://api.security.microsoft.com") -> None:
        self._token_provider = token_provider
        self._retry_policy = retry_policy
        self._session = requests.Session()
        self._base_url = base_url.rstrip("/")

    def iter_pages(self, dataset: DatasetConfig) -> Iterator[list[dict[str, object]]]:
        next_url: str | None = self._build_url(dataset.endpoint or "")
        # Track whether the next URL is a server-provided @odata.nextLink (which
        # already encodes $top/$skip) vs. our initial endpoint (which still needs
        # the first page's params attached). Passing $top/$skip on a nextLink
        # produces duplicate query keys and a 400 "Filter parameter is invalid".
        use_nextlink = False
        skip = 0
        while next_url:
            current_url = next_url
            current_use_nextlink = use_nextlink
            response_json = self._retry_policy.run(
                lambda: self._get_page(current_url, dataset.page_size, skip, current_use_nextlink)
            )
            rows = self._extract_rows(response_json)
            if not rows:
                break
            yield rows
            next_link = response_json.get("@odata.nextLink")
            if isinstance(next_link, str) and next_link:
                next_url = next_link
                use_nextlink = True
            else:
                if len(rows) < dataset.page_size:
                    break
                skip += dataset.page_size
                use_nextlink = False

    def _get_page(self, url: str, top: int, skip: int, use_nextlink: bool = False) -> dict[str, object]:
        token = self._token_provider.get_token(f"{self._base_url}/.default")
        request_kwargs: dict[str, object] = {
            "headers": {"Authorization": f"Bearer {token}"},
            "timeout": 300,
        }
        if not use_nextlink:
            # Only attach $top/$skip on the initial request. The server's
            # @odata.nextLink already carries its own paging parameters.
            request_kwargs["params"] = {"$top": top, "$skip": skip}
        response = self._session.get(url, **request_kwargs)
        if not response.ok:
            body = (response.text or "")[:2000]
            raise requests.HTTPError(
                f"Defender REST GET failed: status={response.status_code} url={response.url} body={body}",
                response=response,
            )
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
