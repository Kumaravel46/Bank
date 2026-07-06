"""
load_trigger.py
----------------
Triggers Snowflake COPY INTO loads from Python instead of a manual
worksheet run - the "load trigger" half of the pipeline. In a real
project this would be called by an Airflow PythonOperator/task;
here it can be run standalone or scheduled with cron for practice.

Mirrors resume bullets:
  "Python scripts handling file movement, load triggers, and error
   logging from AWS S3"
  "Ingesting raw financial data from AWS S3 into Snowflake ... with
   dependency handling, retry logic, and email alerting on task failures"

Usage:
    python load_trigger.py
"""

import logging
import os
import sys
import time

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[logging.FileHandler("load_trigger.log"), logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)

# Each load step: (description, table, stage_file, file_format)
LOAD_STEPS = [
    ("Load customers", "RAW.CUSTOMERS", "@BANK_DB.RAW.STG_S3_RAW/customers.csv", "BANK_DB.RAW.FF_CSV"),
    ("Load accounts", "RAW.ACCOUNTS", "@BANK_DB.RAW.STG_S3_RAW/accounts.csv", "BANK_DB.RAW.FF_CSV"),
    ("Load transactions (raw JSON)", "RAW.TRANSACTIONS_RAW(raw_json)",
     "@BANK_DB.RAW.STG_S3_RAW/transactions.json", "BANK_DB.RAW.FF_JSON"),
]


def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.getenv("SNOWFLAKE_ROLE", "BANK_DATA_ENGINEER"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "BANK_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "BANK_DB"),
        schema=os.getenv("SNOWFLAKE_SCHEMA", "RAW"),
    )


def run_copy_into(cursor, table: str, stage_path: str, file_format: str, retries: int = 3) -> bool:
    sql = f"""
        COPY INTO {table}
        FROM {stage_path}
        FILE_FORMAT = (FORMAT_NAME = '{file_format}')
        ON_ERROR = 'CONTINUE'
    """
    for attempt in range(1, retries + 1):
        try:
            cursor.execute(sql)
            rows = cursor.fetchall()
            for row in rows:
                logger.info("COPY result: %s", row)
            return True
        except Exception as e:
            logger.error("Attempt %d/%d failed for %s: %s", attempt, retries, table, e)
            time.sleep(2 * attempt)  # simple backoff
    return False


def send_failure_alert(step_description: str):
    # Placeholder for the "email alerting on task failures" bullet.
    # Wire this up to SES / SMTP / Slack webhook in a real deployment.
    logger.error("ALERT: step failed and would trigger an email/Slack notification: %s", step_description)


def main():
    conn = get_connection()
    cursor = conn.cursor()
    failures = []

    try:
        for description, table, stage_path, file_format in LOAD_STEPS:
            logger.info("Starting: %s", description)
            success = run_copy_into(cursor, table, stage_path, file_format)
            if not success:
                failures.append(description)
                send_failure_alert(description)
            else:
                logger.info("Completed: %s", description)
    finally:
        cursor.close()
        conn.close()

    if failures:
        logger.error("Pipeline finished with %d failed step(s): %s", len(failures), failures)
        sys.exit(1)

    logger.info("All load steps completed successfully.")


if __name__ == "__main__":
    main()
