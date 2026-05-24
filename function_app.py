import importlib
import logging
import os
import pkgutil

import azure.functions as func

import Functions


# Silence the very chatty per-request INFO logs from azure-core's HTTP pipeline
# (e.g. "Request URL: ...", "No body was attached to the request"). These come from
# every MI token acquisition and every Defender/Monitor SDK call and bury real signal.
# Set AZURE_SDK_HTTP_LOG_LEVEL=INFO to opt back in for debugging.
_azure_http_level = os.getenv("AZURE_SDK_HTTP_LOG_LEVEL", "WARNING").upper()
logging.getLogger("azure.core.pipeline.policies.http_logging_policy").setLevel(_azure_http_level)
logging.getLogger("azure.identity").setLevel(_azure_http_level)


app = func.FunctionApp()

smoke_module = os.getenv("FUNCTIONS_SMOKE_MODULE", "").strip()
if smoke_module:
    module = importlib.import_module(f"Functions.{smoke_module}")
    blueprint = getattr(module, "blueprint", None)
    if blueprint is None:
        raise RuntimeError(f"Smoke module '{smoke_module}' does not expose a blueprint")
    app.register_functions(blueprint)
else:
    # Auto-discover and register every dataset timer blueprint from the Functions package.
    for module_info in pkgutil.iter_modules(Functions.__path__):
        if module_info.name == "common":
            continue
        module = importlib.import_module(f"Functions.{module_info.name}")
        blueprint = getattr(module, "blueprint", None)
        if blueprint is not None:
            app.register_functions(blueprint)
