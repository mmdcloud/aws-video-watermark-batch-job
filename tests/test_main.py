"""
================================================================================
Unit Tests for AWS Media Watermarking Pipeline (Batch + Lambda)
================================================================================
"""

import json
import os
import re
import sys
import unittest
from unittest.mock import MagicMock, patch

# Ensure src is importable
SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "src"))
sys.path.insert(0, SRC_DIR)

# Mock boto3 dependencies when running locally without boto3 installed
with patch.dict(
    "sys.modules",
    {
        "boto3": MagicMock(),
        "boto3.s3.transfer": MagicMock(),
        "botocore.config": MagicMock(),
        "botocore.exceptions": MagicMock(),
    },
):
    import main


class TestMediaWatermarker(unittest.TestCase):

    def test_escape_drawtext_string(self):
        raw = "Hello: World! 100% 'Secure' \\ Path"
        escaped = main.escape_drawtext_string(raw)
        self.assertIn("\\:", escaped)
        self.assertIn("\\%", escaped)
        self.assertIn("'\\''", escaped)
        self.assertIn("\\\\", escaped)

    def test_calculate_watermark_positions(self):
        ox, oy, tx, ty = main.calculate_watermark_positions(
            "bottom-right", margin=20
        )
        self.assertEqual(ox, "main_w-overlay_w-20")
        self.assertEqual(oy, "main_h-overlay_h-20")
        self.assertEqual(tx, "w-tw-20")
        self.assertEqual(ty, "h-th-20")

        ox, oy, tx, ty = main.calculate_watermark_positions("center")
        self.assertEqual(ox, "(main_w-overlay_w)/2")
        self.assertEqual(oy, "(main_h-overlay_h)/2")

        ox, oy, tx, ty = main.calculate_watermark_positions("top-left", margin=15)
        self.assertEqual(ox, "15")
        self.assertEqual(oy, "15")

    def test_sanitize_batch_job_name(self):
        key = "uploads/2026/video file @ test (1).mp4"
        job_name = main.sanitize_batch_job_name("wm", key)
        self.assertTrue(job_name.startswith("wm-video_file___test__1__mp4-"))
        self.assertLessEqual(len(job_name), 128)
        self.assertTrue(re.match(r"^[a-zA-Z0-9_-]+$", job_name))

    def test_build_ffmpeg_command_video(self):
        cmd = main.build_ffmpeg_command(
            input_path="/tmp/input.mp4",
            output_path="/tmp/output.mp4",
            is_video=True,
            watermark_text="CONFIDENTIAL",
            watermark_img_path=None,
            position="bottom-right",
            opacity=0.8,
            font_size=28,
        )
        cmd_str = " ".join(cmd)
        self.assertIn("ffmpeg", cmd)
        self.assertIn("-filter_complex", cmd)
        self.assertIn("drawtext=", cmd_str)
        self.assertIn("libx264", cmd)
        self.assertIn("yuv420p", cmd)
        self.assertIn("+faststart", cmd)
        self.assertIn("-map 0:a?", cmd_str)
        self.assertEqual(cmd[-1], "/tmp/output.mp4")

    def test_build_ffmpeg_command_image(self):
        cmd = main.build_ffmpeg_command(
            input_path="/tmp/input.jpg",
            output_path="/tmp/output.jpg",
            is_video=False,
            watermark_text="COPYRIGHT",
            watermark_img_path=None,
            position="top-right",
            opacity=0.9,
        )
        self.assertIn("-q:v", cmd)
        self.assertNotIn("libx264", cmd)
        self.assertEqual(cmd[-1], "/tmp/output.jpg")

    def test_extract_s3_events(self):
        s3_record = {
            "s3": {
                "bucket": {"name": "source-bucket"},
                "object": {"key": "test+video.mp4"},
            }
        }
        res = main.extract_s3_events(s3_record)
        self.assertEqual(res, [("source-bucket", "test video.mp4")])

        sqs_record = {
            "body": json.dumps({
                "Records": [{
                    "s3": {
                        "bucket": {"name": "source-bucket"},
                        "object": {"key": "my%2Fnested%2Ffile.jpg"},
                    }
                }]
            })
        }
        res2 = main.extract_s3_events(sqs_record)
        self.assertEqual(res2, [("source-bucket", "my/nested/file.jpg")])

    def test_lambda_handler_direct_invocation(self):
        mock_batch = MagicMock()
        mock_batch.submit_job.return_value = {
            "jobId": "test-job-12345",
            "jobName": "wm-test-job",
        }

        with patch.object(main.boto3, "client", return_value=mock_batch):
            event = {
                "input_bucket": "my-source-bucket",
                "input_key": "sample.mp4",
                "output_bucket": "my-destination-bucket",
                "watermark_text": "CONFIDENTIAL",
            }
            resp = main.lambda_handler(event, None)
            self.assertEqual(resp["statusCode"], 200)
            self.assertEqual(resp["jobId"], "test-job-12345")
            self.assertTrue(mock_batch.submit_job.called)
            call_kwargs = mock_batch.submit_job.call_args[1]
            cmd = call_kwargs["containerOverrides"]["command"]
            self.assertEqual(cmd[1], "my-source-bucket")
            self.assertEqual(cmd[3], "sample.mp4")


if __name__ == "__main__":
    unittest.main()

