import importlib
import pkgutil

import azure.functions as func

import Functions


app = func.FunctionApp()


# Auto-discover and register every dataset timer blueprint from the Functions package.
for module_info in pkgutil.iter_modules(Functions.__path__):
    if module_info.name == "common":
        continue
    module = importlib.import_module(f"Functions.{module_info.name}")
    blueprint = getattr(module, "blueprint", None)
    if blueprint is not None:
        app.register_functions(blueprint)
