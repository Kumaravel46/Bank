"""
s3_upload.py
------------
Uploads the sample data files to S3 (the "file movement" step of the
pipeline). Mirrors the resume bullet:
  "Python scripts handling file movement, load triggers, and error
   logging from AWS S3"

Usage:
    python s3_upload.py
"""

import logging
import os
import sys
from pathlib import Path

import boto3
from botocore.exceptions import ClientError
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[
        logging.FileHandler("s3_upload.log"),
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger(__name__)

BUCKET = os.getenv("S3_BUCKET", "bank-project-r")
DATA_DIR = Path(__file__).resolve().parent.parent / ("sample_data"
                                                     "")

FILES_TO_UPLOAD = [
    "customers.csv",
    "accounts.csv",
    "accounts_day2.csv",
    "transactions.json",
]


def get_s3_client():
    return boto3.client(
        "s3",
        aws_access_key_id=os.getenv("AWS_ACCESS_KEY_ID"),
        aws_secret_access_key=os.getenv("AWS_SECRET_ACCESS_KEY"),
        region_name=os.getenv("AWS_REGION", "ap-south-1"),
    )


def upload_file(s3_client, local_path: Path, bucket: str, key: str, retries: int = 3) -> bool:
    """Upload one file with simple retry logic and error logging."""
    for attempt in range(1, retries + 1):
        try:
            s3_client.upload_file(str(local_path), bucket, key)
            logger.info("Uploaded %s -> s3://%s/%s", local_path.name, bucket, key)
            return True
        except ClientError as e:
            logger.error("Attempt %d/%d failed for %s: %s", attempt, retries, local_path.name, e)
    logger.error("Giving up on %s after %d attempts", local_path.name, retries)
    return False


def main():
    s3_client = get_s3_client()
    results = {}

    for filename in FILES_TO_UPLOAD:
        local_path = DATA_DIR / filename
        if not local_path.exists():
            logger.warning("Skipping missing file: %s", local_path)
            continue
        results[filename] = upload_file(s3_client, local_path, BUCKET, filename)

    succeeded = sum(1 for ok in results.values() if ok)
    failed = len(results) - succeeded
    logger.info("Upload summary: %d succeeded, %d failed", succeeded, failed)

    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
