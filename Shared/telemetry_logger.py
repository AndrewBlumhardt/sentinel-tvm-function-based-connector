"""Shared ``logging.Logger`` instance used by the runtime modules.

Azure Functions captures stdlib logging and forwards it to Application Insights
when the host is configured for AI, so callers do not need to attach handlers.
"""
from __future__ import annotations

import logging


def get_logger(name: str = "tvm_snapshot_connector") -> logging.Logger:
    logger = logging.getLogger(name)
    if not logger.handlers:
        logger.setLevel(logging.INFO)
    return logger
