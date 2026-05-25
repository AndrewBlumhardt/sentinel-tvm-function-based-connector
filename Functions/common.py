"""Factory used by every per-dataset timer function in this folder.

Each ``Functions/<dataset>.py`` file is a 6-line shim that calls
``build_timer_blueprint(...)`` with its dataset name, schedule app-setting key,
and function name. The blueprint registers a single timer trigger that hands
off to the shared ``DatasetRunner`` — keeping per-dataset files trivially small
and keeping all real logic in ``Shared/``.
"""
from __future__ import annotations

import logging

import azure.functions as func

from Shared.runtime import get_dataset_runner


def build_timer_blueprint(dataset_name: str, schedule_setting: str, function_name: str) -> func.Blueprint:
    """Build a timer-trigger blueprint that runs one configured dataset pipeline."""
    blueprint = func.Blueprint()

    @blueprint.function_name(name=function_name)
    @blueprint.timer_trigger(
        arg_name="timer",
        schedule=f"%{schedule_setting}%",
        run_on_startup=False,
        use_monitor=True,
    )
    def dataset_timer(timer: func.TimerRequest) -> None:
        if timer.past_due:
            logging.warning("Timer for %s ran late.", dataset_name)
        # Runtime wiring is shared across all triggers to keep per-dataset files minimal.
        get_dataset_runner().run_dataset(dataset_name)

    return blueprint
