"""Per-run ingestion metadata stamped onto every record (``TimeGenerated``)."""
from __future__ import annotations

from datetime import datetime, timezone


def create_snapshot_context() -> dict[str, str]:
    """Create per-run ingestion metadata shared across all records in a run."""
    return {
        "TimeGenerated": datetime.now(timezone.utc).isoformat(),
    }
