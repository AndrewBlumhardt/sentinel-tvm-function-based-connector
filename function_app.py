import importlib
import os
import pkgutil

import azure.functions as func

import Functions


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
