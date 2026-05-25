"""Composition root for the timer-triggered runtime graph.

Builds the registry, auth provider, upstream clients, and ingestion client once
per worker process and caches the resulting ``DatasetRunner`` via ``lru_cache``.
All per-dataset timer functions go through ``get_dataset_runner()``.
"""
from __future__ import annotations

from functools import lru_cache

from Shared.config_loader import ConfigLoader
from Shared.dataset_registry import DatasetRegistry
from Shared.dataset_runner import DatasetRunner
from Shared.defender_advanced_hunting_client import DefenderAdvancedHuntingClient
from Shared.defender_auth_provider import DefenderAuthProvider
from Shared.defender_rest_client import DefenderRestClient
from Shared.log_ingestion_client import LogIngestionClient
from Shared.nist_client import NistClient
from Shared.retry_policy import RetryPolicy


@lru_cache(maxsize=1)
def get_dataset_runner() -> DatasetRunner:
    """Create and cache the shared runtime graph used by timer-trigger executions."""
    config_loader = ConfigLoader()
    app_settings = config_loader.load_app_settings()
    registry = DatasetRegistry(config_loader.load_datasets())
    auth_provider = DefenderAuthProvider(app_settings.managed_identity_client_id)
    retry_policy = RetryPolicy()
    return DatasetRunner(
        registry=registry,
        app_settings=app_settings,
        hunting_client=DefenderAdvancedHuntingClient(auth_provider, retry_policy, base_url=app_settings.defender_hunting_base_url),
        rest_client=DefenderRestClient(auth_provider, retry_policy, base_url=app_settings.resolved_security_center_api_base_url),
        nist_client=NistClient(app_settings.nist_api_key, retry_policy),
        ingestion_client=LogIngestionClient(app_settings.logs_ingestion_endpoint, auth_provider.credential),
    )
