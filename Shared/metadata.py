from __future__ import annotations

from datetime import datetime, timezone
from uuid import uuid4


def create_snapshot_context() -> dict[str, str]:
    return {
        "SnapshotTime": datetime.now(timezone.utc).isoformat(),
        "RunId": str(uuid4()),
    }


def enrich_record(record: dict[str, object], metadata: dict[str, object]) -> dict[str, object]:
    enriched = dict(record)
    enriched.update(metadata)
    return enriched
