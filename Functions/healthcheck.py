"""HTTP-triggered health check for fast, deploy-time validation of Defender connectivity.

Probes each Defender API host this app talks to and returns a JSON matrix of
{host, endpoint, status, elapsed_ms, error?}. Lets you verify, in seconds rather
than waiting 30 minutes for the next NCRONTAB tick, that:

  * The managed identity got a token for each Defender audience.
  * Each required app role is actually granted (403 => role missing).
  * The configured base URLs reach a live host (404/DNS => wrong host for the cloud).

Invocation:
    GET https://<funcapp>/api/healthcheck?code=<function key>          # baseline probes
    GET https://<funcapp>/api/healthcheck?code=<function key>&full=1   # plus every dataset endpoint

Use the *function* key (not master). Function name: HealthCheck.
"""
from __future__ import annotations

import json
import logging
import time
from typing import Any

import azure.functions as func
import requests

from Shared.config_loader import ConfigLoader
from Shared.defender_auth_provider import DefenderAuthProvider


blueprint = func.Blueprint()


def _probe(method: str, url: str, token: str, *, json_body: dict[str, Any] | None = None, params: dict[str, Any] | None = None) -> dict[str, Any]:
    started = time.monotonic()
    try:
        if method == "GET":
            response = requests.get(
                url,
                headers={"Authorization": f"Bearer {token}"},
                params=params,
                timeout=30,
            )
        else:
            response = requests.post(
                url,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                json=json_body,
                timeout=30,
            )
        elapsed_ms = int((time.monotonic() - started) * 1000)
        body_excerpt = ""
        if not response.ok:
            body_excerpt = (response.text or "")[:400]
        return {
            "url": url,
            "method": method,
            "status": response.status_code,
            "ok": response.ok,
            "elapsed_ms": elapsed_ms,
            "error": body_excerpt or None,
        }
    except Exception as exc:  # noqa: BLE001 - we want every failure mode reported back
        elapsed_ms = int((time.monotonic() - started) * 1000)
        return {
            "url": url,
            "method": method,
            "status": None,
            "ok": False,
            "elapsed_ms": elapsed_ms,
            "error": f"{type(exc).__name__}: {exc}",
        }


def _safe_token(provider: DefenderAuthProvider, scope: str) -> tuple[str | None, str | None]:
    try:
        return provider.get_token(scope), None
    except Exception as exc:  # noqa: BLE001
        return None, f"{type(exc).__name__}: {exc}"


@blueprint.function_name(name="HealthCheck")
@blueprint.route(route="healthcheck", auth_level=func.AuthLevel.FUNCTION, methods=["GET"])
def healthcheck(req: func.HttpRequest) -> func.HttpResponse:
    full = (req.params.get("full") or "").lower() in ("1", "true", "yes")

    config_loader = ConfigLoader()
    app_settings = config_loader.load_app_settings()
    datasets = config_loader.load_datasets()

    hunting_base = app_settings.defender_hunting_base_url
    security_center_base = app_settings.resolved_security_center_api_base_url

    auth = DefenderAuthProvider(app_settings.managed_identity_client_id)

    results: list[dict[str, Any]] = []

    # 1) Advanced Hunting via Microsoft Graph (runHuntingQuery).
    hunting_token, hunting_err = _safe_token(auth, f"{hunting_base}/.default")
    if hunting_err:
        results.append({
            "surface": "advanced_hunting",
            "host": hunting_base,
            "url": f"{hunting_base}/.default",
            "method": "TOKEN",
            "status": None,
            "ok": False,
            "elapsed_ms": 0,
            "error": hunting_err,
            "hint": "Token acquisition failed for the Microsoft Graph audience. Check the managed identity is enabled and the host is reachable.",
        })
    else:
        probe = _probe(
            "POST",
            f"{hunting_base}/v1.0/security/runHuntingQuery",
            hunting_token,
            json_body={"Query": "DeviceInfo | take 1"},
        )
        probe["surface"] = "advanced_hunting"
        probe["host"] = hunting_base
        probe["required_roles"] = ["ThreatHunting.Read.All"]
        probe["hint"] = (
            "403 => missing ThreatHunting.Read.All on Microsoft Graph SP. "
            "404/DNS => wrong host for this cloud (Defender__HuntingBaseUrl). "
            "On Gov use https://graph.microsoft.us."
        )
        results.append(probe)

    # 2) Defender for Endpoint REST host (WindowsDefenderATP audience).
    rest_token, rest_err = _safe_token(auth, f"{security_center_base}/.default")
    if rest_err:
        results.append({
            "surface": "security_center_rest",
            "host": security_center_base,
            "url": f"{security_center_base}/.default",
            "method": "TOKEN",
            "status": None,
            "ok": False,
            "elapsed_ms": 0,
            "error": rest_err,
            "hint": "Token acquisition failed for the WindowsDefenderATP audience. On Gov this host MUST be api-gov.securitycenter.microsoft.us, NOT api-gov.security.microsoft.us.",
        })
    else:
        probe = _probe(
            "GET",
            f"{security_center_base}/api/machines",
            rest_token,
            params={"$top": 1},
        )
        probe["surface"] = "security_center_rest"
        probe["host"] = security_center_base
        probe["required_roles"] = ["Machine.Read.All"]
        probe["hint"] = (
            "403 => missing Machine.Read.All on WindowsDefenderATP SP. "
            "404/DNS => wrong host (Defender__SecurityCenterApiBaseUrl). On Gov use api-gov.securitycenter.microsoft.us."
        )
        results.append(probe)

    # 3) Optionally probe every configured dataset endpoint.
    if full and rest_token:
        seen: set[str] = set()
        for dataset in datasets:
            endpoint = (dataset.endpoint or "").strip()
            if not endpoint or not endpoint.startswith("/"):
                continue
            url = f"{security_center_base}{endpoint}"
            if url in seen:
                continue
            seen.add(url)
            probe = _probe("GET", url, rest_token, params={"$top": 1})
            probe["surface"] = "dataset_endpoint"
            probe["dataset"] = dataset.name
            results.append(probe)

    summary = {
        "ok": all(r.get("ok") for r in results),
        "checked": len(results),
        "ok_count": sum(1 for r in results if r.get("ok")),
        "failed_count": sum(1 for r in results if not r.get("ok")),
        "hunting_base": hunting_base,
        "security_center_base": security_center_base,
        "managed_identity_client_id": app_settings.managed_identity_client_id,
        "full": full,
    }

    payload = {"summary": summary, "results": results}
    logging.info("HealthCheck %s/%s ok", summary["ok_count"], summary["checked"])

    return func.HttpResponse(
        body=json.dumps(payload, indent=2, default=str),
        status_code=200,
        mimetype="application/json",
    )
