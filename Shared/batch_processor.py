from __future__ import annotations

from collections.abc import Iterable, Iterator


def iter_batches(records: Iterable[dict[str, object]], batch_size: int) -> Iterator[list[dict[str, object]]]:
    batch: list[dict[str, object]] = []
    for record in records:
        batch.append(record)
        if len(batch) >= batch_size:
            yield batch
            batch = []
    if batch:
        yield batch
