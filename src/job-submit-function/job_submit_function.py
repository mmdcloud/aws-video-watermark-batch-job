"""
AWS Lambda Job Submit Function: Entrypoint matching Terraform handler
(handler = "job_submit_function.lambda_handler")
"""

import importlib

_mod = importlib.import_module("lambda")
lambda_handler = getattr(_mod, "lambda_handler")

__all__ = ["lambda_handler"]

