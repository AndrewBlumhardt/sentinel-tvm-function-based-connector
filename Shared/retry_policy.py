"""Simple linear-backoff retry wrapper.

Retries any exception ``attempts`` times with ``base_delay_seconds * attempt``
backoff between tries. Intentionally retry-everything: 4xx errors that are not
going to recover (401, 403, 404) will still get retried and then surfaced, on
the theory that the cost of a few extra calls is small and the original error
is preserved for the operator to read in logs.
"""
from __future__ import annotations

import time
from typing import Callable, TypeVar


T = TypeVar("T")


class RetryPolicy:
    def __init__(self, attempts: int = 3, base_delay_seconds: float = 1.0) -> None:
        self._attempts = attempts
        self._base_delay_seconds = base_delay_seconds

    def run(self, operation: Callable[[], T]) -> T:
        last_error: Exception | None = None
        for attempt in range(1, self._attempts + 1):
            try:
                return operation()
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                if attempt == self._attempts:
                    break
                time.sleep(self._base_delay_seconds * attempt)
        assert last_error is not None
        raise last_error
