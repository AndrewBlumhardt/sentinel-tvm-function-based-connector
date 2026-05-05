from __future__ import annotations

from azure.identity import ManagedIdentityCredential


class DefenderAuthProvider:
    def __init__(self, managed_identity_client_id: str | None = None) -> None:
        self._credential = ManagedIdentityCredential(client_id=managed_identity_client_id)

    @property
    def credential(self) -> ManagedIdentityCredential:
        return self._credential

    def get_token(self, scope: str) -> str:
        return self._credential.get_token(scope).token
