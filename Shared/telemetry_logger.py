from __future__ import annotations

import logging


def get_logger(name: str = "tvm_snapshot_connector") -> logging.Logger:
    logger = logging.getLogger(name)
    if not logger.handlers:
        logger.setLevel(logging.INFO)
    return logger
