"""In-memory lookup of dataset configurations by name.

Built once at runtime startup from the list returned by ``ConfigLoader``. Used
by ``DatasetRunner`` to resolve the dataset for an incoming timer trigger.
"""
from __future__ import annotations

from Shared.models import DatasetConfig


class DatasetRegistry:
    def __init__(self, datasets: list[DatasetConfig]) -> None:
        self._datasets = {dataset.name: dataset for dataset in datasets}

    def get(self, dataset_name: str) -> DatasetConfig:
        if dataset_name not in self._datasets:
            raise KeyError(f"Unknown dataset '{dataset_name}'.")
        return self._datasets[dataset_name]

    def list_all(self) -> list[DatasetConfig]:
        return list(self._datasets.values())
