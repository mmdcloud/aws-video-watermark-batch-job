"""
Job Submit Function Package
"""

import importlib

_lambda_module = importlib.import_module(".lambda", package=__name__)
lambda_handler = getattr(_lambda_module, "lambda_handler")

__all__ = ["lambda_handler"]

