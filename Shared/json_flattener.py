"""Flattens nested JSON objects into the flat column layout that DCRs expect.

Nested objects become underscore-joined keys (``foo.bar`` -> ``foo_bar``).
Arrays are JSON-serialized to strings so they fit a single ``dynamic`` or
``string`` column. Scalars pass through unchanged.
"""
from __future__ import annotations

import json
from collections.abc import Mapping, Sequence


class JsonFlattener:
    def flatten(self, payload: Mapping[str, object], prefix: str = "") -> dict[str, object]:
        """Flatten nested objects and serialize arrays for Log Analytics ingestion."""
        flattened: dict[str, object] = {}
        for key, value in payload.items():
            qualified_key = f"{prefix}_{key}" if prefix else key
            self._flatten_value(flattened, qualified_key, value)
        return flattened

    def _flatten_value(self, target: dict[str, object], key: str, value: object) -> None:
        if value is None or isinstance(value, (str, int, float, bool)):
            target[key] = value
            return
        if isinstance(value, Mapping):
            for nested_key, nested_value in value.items():
                self._flatten_value(target, f"{key}_{nested_key}", nested_value)
            return
        if isinstance(value, Sequence) and not isinstance(value, (str, bytes, bytearray)):
            target[key] = json.dumps(value, ensure_ascii=True)
            return
        target[key] = str(value)
