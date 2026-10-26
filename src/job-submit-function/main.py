"""
AWS Lambda Job Submit Function: Entrypoint alias for main.py / lambda.py
"""

import importlib
import sys

_lambda_mod = importlib.import_module("lambda")
lambda_handler = getattr(_lambda_mod, "lambda_handler")

__all__ = ["lambda_handler"]

if __name__ == "__main__":
    # Direct test invocation
    test_event = {
        "input_bucket": "source-bucket",
        "input_key": "test.mp4",
        "output_bucket": "destination-bucket",
    }
    result = lambda_handler(test_event, None)
    print(result)

