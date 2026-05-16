from __future__ import annotations

from datetime import datetime, timezone


def create_snapshot_context() -> dict[str, str]:
    return {
        "TimeGenerated": datetime.now(timezone.utc).isoformat(),
    }
