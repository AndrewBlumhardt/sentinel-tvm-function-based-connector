from __future__ import annotations

import logging

import azure.functions as func

from Shared.runtime import get_dataset_runner


def build_timer_blueprint(dataset_name: str, schedule_setting: str, function_name: str) -> func.Blueprint:
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
        get_dataset_runner().run_dataset(dataset_name)

    return blueprint
