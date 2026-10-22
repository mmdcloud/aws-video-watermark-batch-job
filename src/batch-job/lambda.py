"""
================================================================================
AWS Lambda Function Handler: Media Watermark Job Submitter
================================================================================
Entrypoint referenced by Terraform (handler = "lambda.lambda_handler").
Delegates to the production lambda_handler defined in main.py.
================================================================================
"""

from main import lambda_handler

__all__ = ["lambda_handler"]

