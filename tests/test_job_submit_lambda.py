"""
================================================================================
Unit Tests for AWS Lambda Job Submit Function (src/job-submit-function)
================================================================================
"""

import importlib
import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Add src/job-submit-function to sys.path
LAMBDA_DIR = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "src", "job-submit-function")
)
sys.path.insert(0, LAMBDA_DIR)

class MockBotoCoreError(Exception):
    pass


class MockClientError(Exception):
    def __init__(self, error_response=None, operation_name=None):
        self.response = error_response or {}
        self.operation_name = operation_name or ""
        msg = f"An error occurred ({self.response.get('Error', {}).get('Code', 'Unknown')}) when calling the {self.operation_name} operation: {self.response.get('Error', {}).get('Message', '')}"
        super().__init__(msg)


# Mock boto3 before importing lambda module
mock_exceptions = MagicMock()
mock_exceptions.BotoCoreError = MockBotoCoreError
mock_exceptions.ClientError = MockClientError

with patch.dict(
    "sys.modules",
    {
        "boto3": MagicMock(),
        "botocore.config": MagicMock(),
        "botocore.exceptions": mock_exceptions,
    },
):
    lambda_mod = importlib.import_module("lambda")


class TestJobSubmitLambda(unittest.TestCase):

    def setUp(self):
        self.mock_batch = MagicMock()
        self.mock_dynamodb = MagicMock()
        self.mock_table = MagicMock()
        self.mock_dynamodb.Table.return_value = self.mock_table

        lambda_mod.batch_client = self.mock_batch
        lambda_mod.dynamodb_resource = self.mock_dynamodb

    def test_sanitize_batch_job_name(self):
        raw_key = "uploads/2026/product review (final) & edited!.mp4"
        job_name = lambda_mod.sanitize_batch_job_name("wm", raw_key)
        self.assertTrue(job_name.startswith("wm-product_review__final____edited__mp4-"))
        self.assertLessEqual(len(job_name), 128)
        import re
        self.assertTrue(re.match(r"^[a-zA-Z0-9_-]+$", job_name))

    def test_is_video_file(self):
        self.assertTrue(lambda_mod.is_video_file("video.mp4"))
        self.assertTrue(lambda_mod.is_video_file("movie.MOV"))
        self.assertTrue(lambda_mod.is_video_file("clip.mkv"))
        self.assertFalse(lambda_mod.is_video_file("photo.jpg"))
        self.assertFalse(lambda_mod.is_video_file("logo.png"))
        self.assertFalse(lambda_mod.is_video_file("doc.pdf"))

    def test_get_compute_requirements(self):
        vcpu_v, mem_v, timeout_v = lambda_mod.get_compute_requirements(is_video=True)
        self.assertEqual(vcpu_v, "2.0")
        self.assertEqual(mem_v, "4096")
        self.assertEqual(timeout_v, 7200)

        vcpu_i, mem_i, timeout_i = lambda_mod.get_compute_requirements(is_video=False)
        self.assertEqual(vcpu_i, "0.5")
        self.assertEqual(mem_i, "1024")
        self.assertEqual(timeout_i, 600)

    def test_extract_s3_records_direct(self):
        event_record = {
            "s3": {
                "bucket": {"name": "test-source-bucket"},
                "object": {"key": "folder%2Fvideo+file.mp4"},
            }
        }
        res = lambda_mod.extract_s3_records(event_record)
        self.assertEqual(res, [("test-source-bucket", "folder/video file.mp4")])

    def test_extract_s3_records_sqs(self):
        sqs_record = {
            "body": json.dumps({
                "Records": [
                    {
                        "s3": {
                            "bucket": {"name": "sqs-source-bucket"},
                            "object": {"key": "test%2Fimage.jpg"},
                        }
                    }
                ]
            })
        }
        res = lambda_mod.extract_s3_records(sqs_record)
        self.assertEqual(res, [("sqs-source-bucket", "test/image.jpg")])

    def test_build_container_overrides(self):
        overrides, timeout = lambda_mod.build_container_overrides(
            input_bucket="source-b",
            input_key="media/video.mp4",
            output_bucket="dest-b",
            output_key="watermarked/video.mp4",
            watermark_type="text",
            watermark_text="PROD_SAMPLE",
            watermark_image_bucket="",
            watermark_image_key="",
            position="bottom-right",
            opacity=0.85,
            font_size=32,
            font_color="yellow",
            enable_box=True,
            box_color="black@0.5",
            margin=30,
            is_video=True,
        )
        self.assertEqual(timeout, 7200)
        cmd = overrides["command"]
        self.assertIn("--input-bucket", cmd)
        self.assertIn("source-b", cmd)
        self.assertIn("--input-key", cmd)
        self.assertIn("media/video.mp4", cmd)
        self.assertIn("--output-bucket", cmd)
        self.assertIn("dest-b", cmd)
        self.assertIn("--watermark-text", cmd)
        self.assertIn("PROD_SAMPLE", cmd)
        self.assertIn("--enable-box", cmd)
        self.assertEqual(overrides["resourceRequirements"][0]["value"], "2.0")
        self.assertEqual(overrides["resourceRequirements"][1]["value"], "4096")

    def test_record_job_state_dynamodb(self):
        success = lambda_mod.record_job_state(
            record_id="job-12345",
            filename="path/to/video.mp4",
            status="SUBMITTED",
            job_id="job-12345",
            job_name="wm-video",
            source_bucket="source-b",
            destination_bucket="dest-b",
            destination_key="watermarked/video.mp4",
            media_type="video",
        )
        self.assertTrue(success)
        self.mock_table.put_item.assert_called_once()
        item = self.mock_table.put_item.call_args[1]["Item"]
        self.assertEqual(item["RecordId"], "job-12345")
        self.assertEqual(item["filename"], "path/to/video.mp4")
        self.assertEqual(item["status"], "SUBMITTED")
        self.assertEqual(item["source_bucket"], "source-b")
        self.assertIn("TimeToExist", item)
        self.assertIn("updated_at", item)

    def test_direct_invocation_success(self):
        self.mock_batch.submit_job.return_value = {
            "jobId": "batch-job-abc-999",
            "jobName": "wm-test-job",
        }

        event = {
            "input_bucket": "raw-media-bucket",
            "input_key": "trailers/sample.mp4",
            "output_bucket": "processed-media-bucket",
            "watermark_text": "ACME CORP",
        }

        resp = lambda_mod.lambda_handler(event, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(resp["jobId"], "batch-job-abc-999")
        self.assertEqual(resp["status"], "SUBMITTED")

        # Verify Batch was called
        self.mock_batch.submit_job.assert_called_once()
        # Verify DynamoDB recorded the job
        self.mock_table.put_item.assert_called_once()
        saved_item = self.mock_table.put_item.call_args[1]["Item"]
        self.assertEqual(saved_item["RecordId"], "batch-job-abc-999")
        self.assertEqual(saved_item["filename"], "trailers/sample.mp4")
        self.assertEqual(saved_item["status"], "SUBMITTED")

    def test_sqs_invocation_with_partial_failures(self):
        self.mock_batch.submit_job.return_value = {
            "jobId": "batch-job-sqs-001",
            "jobName": "wm-sqs-job",
        }

        sqs_event = {
            "Records": [
                {
                    "messageId": "msg-success-1",
                    "body": json.dumps({
                        "Records": [
                            {
                                "s3": {
                                    "bucket": {"name": "incoming-bucket"},
                                    "object": {"key": "good-video.mp4"},
                                }
                            }
                        ]
                    }),
                },
                {
                    "messageId": "msg-invalid-body-2",
                    "body": "INVALID_NON_JSON",
                },
            ]
        }

        resp = lambda_mod.lambda_handler(sqs_event, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(resp["processedCount"], 1)
        self.assertEqual(len(resp["submittedJobs"]), 1)
        # Verify ReportBatchItemFailures is returned
        self.assertIn("batchItemFailures", resp)

    def test_tag_resource_access_denied_fallback(self):
        # First call raises AccessDeniedException for TagResource, second call succeeds
        access_denied = MockClientError(
            {"Error": {"Code": "AccessDeniedException", "Message": "batch:TagResource not authorized"}},
            "SubmitJob"
        )
        self.mock_batch.submit_job.side_effect = [
            access_denied,
            {"jobId": "batch-job-fallback-123", "jobName": "wm-fallback"}
        ]

        event = {
            "input_bucket": "raw-media-bucket",
            "input_key": "trailers/sample.mp4",
            "output_bucket": "processed-media-bucket",
        }

        resp = lambda_mod.lambda_handler(event, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(resp["jobId"], "batch-job-fallback-123")
        self.assertEqual(self.mock_batch.submit_job.call_count, 2)
        # Verify second call was without tags
        second_call_kwargs = self.mock_batch.submit_job.call_args_list[1][1]
        self.assertNotIn("tags", second_call_kwargs)

    def test_eventbridge_batch_state_change_succeeded(self):
        self.mock_table.query.return_value = {
            "Items": [
                {
                    "RecordId": "batch-job-123",
                    "filename": "videos/sample.mp4",
                    "status": "SUBMITTED",
                }
            ]
        }

        event = {
            "source": "aws.batch",
            "detail-type": "Batch Job State Change",
            "detail": {
                "jobId": "batch-job-123",
                "status": "SUCCEEDED",
                "statusReason": "Essential container in task exited successfully",
                "stoppedAt": 1793346800000,
                "container": {
                    "exitCode": 0,
                },
            },
        }

        resp = lambda_mod.lambda_handler(event, None)
        self.assertEqual(resp["statusCode"], 200)
        self.assertEqual(resp["status"], "COMPLETED")
        self.assertTrue(resp["updated"])
        self.mock_table.update_item.assert_called_once()
        update_args = self.mock_table.update_item.call_args[1]
        self.assertEqual(update_args["Key"], {"RecordId": "batch-job-123", "filename": "videos/sample.mp4"})
        self.assertEqual(update_args["ExpressionAttributeValues"][":status"], "COMPLETED")


if __name__ == "__main__":
    unittest.main()
