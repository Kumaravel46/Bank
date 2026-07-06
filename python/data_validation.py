"""
data_validation.py
-------------------
Python + pandas based data quality / reconciliation framework.
Mirrors resume bullets:
  "Writing Python and SQL scripts for data validation and quality
   checks across Snowflake tables"
  "Built a Python and SQL based validation framework ... comparing
   record counts, checksums, and field level values ... generating
   reconciliation reports with exact discrepancy locations"

This pulls RAW.CUSTOMERS / RAW.ACCOUNTS / RAW.TRANSACTIONS out of
Snowflake into pandas DataFrames and runs a set of data quality
checks, writing a reconciliation report CSV - the same shape of
report you'd hand to a BFSI compliance team.

Usage:
    python data_validation.py
"""

import hashlib
import logging
import os
import sys
from datetime import datetime

import pandas as pd
import snowflake.connector
from dotenv import load_dotenv

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
    handlers=[logging.FileHandler("data_validation.log"), logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


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


def fetch_df(conn, query: str) -> pd.DataFrame:
    cursor = conn.cursor()
    try:
        cursor.execute(query)
        columns = [c[0] for c in cursor.description]
        return pd.DataFrame(cursor.fetchall(), columns=columns)
    finally:
        cursor.close()


def row_checksum(row: pd.Series) -> str:
    """Simple checksum for field-level comparison - same idea used to
    compare Oracle source rows against Snowflake target rows."""
    concatenated = "|".join(str(v) for v in row.values)
    return hashlib.md5(concatenated.encode("utf-8")).hexdigest()


def check_row_counts(customers: pd.DataFrame, accounts: pd.DataFrame, transactions: pd.DataFrame) -> list:
    issues = []
    if len(customers) == 0:
        issues.append({"check": "row_count", "table": "CUSTOMERS", "detail": "Zero rows loaded"})
    if len(accounts) == 0:
        issues.append({"check": "row_count", "table": "ACCOUNTS", "detail": "Zero rows loaded"})
    if len(transactions) == 0:
        issues.append({"check": "row_count", "table": "TRANSACTIONS", "detail": "Zero rows loaded"})
    return issues


def check_referential_integrity(accounts: pd.DataFrame, customers: pd.DataFrame,
                                 transactions: pd.DataFrame) -> list:
    issues = []
    orphan_accounts = accounts[~accounts["CUSTOMER_ID"].isin(customers["CUSTOMER_ID"])]
    for _, row in orphan_accounts.iterrows():
        issues.append({
            "check": "referential_integrity",
            "table": "ACCOUNTS",
            "detail": f"account_id={row['ACCOUNT_ID']} references missing customer_id={row['CUSTOMER_ID']}",
        })

    orphan_txns = transactions[~transactions["ACCOUNT_ID"].isin(accounts["ACCOUNT_ID"])]
    for _, row in orphan_txns.iterrows():
        issues.append({
            "check": "referential_integrity",
            "table": "TRANSACTIONS",
            "detail": f"transaction_id={row['TRANSACTION_ID']} references missing account_id={row['ACCOUNT_ID']}",
        })
    return issues


def check_nulls_and_duplicates(customers: pd.DataFrame, accounts: pd.DataFrame,
                                transactions: pd.DataFrame) -> list:
    issues = []

    if customers["CUSTOMER_ID"].isnull().any():
        issues.append({"check": "null_check", "table": "CUSTOMERS", "detail": "Null customer_id found"})
    dup_customers = customers[customers.duplicated("CUSTOMER_ID", keep=False)]
    if not dup_customers.empty:
        issues.append({
            "check": "duplicate_check", "table": "CUSTOMERS",
            "detail": f"{dup_customers['CUSTOMER_ID'].nunique()} duplicate customer_id values found",
        })

    dup_accounts = accounts[accounts.duplicated("ACCOUNT_ID", keep=False)]
    if not dup_accounts.empty:
        issues.append({
            "check": "duplicate_check", "table": "ACCOUNTS",
            "detail": f"{dup_accounts['ACCOUNT_ID'].nunique()} duplicate account_id values found",
        })

    negative_amounts = transactions[transactions["AMOUNT"] <= 0]
    if not negative_amounts.empty:
        issues.append({
            "check": "business_rule", "table": "TRANSACTIONS",
            "detail": f"{len(negative_amounts)} transactions with amount <= 0",
        })

    return issues


def main():
    conn = get_connection()
    try:
        logger.info("Pulling tables from Snowflake for validation...")
        customers = fetch_df(conn, "SELECT * FROM RAW.CUSTOMERS")
        accounts = fetch_df(conn, "SELECT * FROM RAW.ACCOUNTS")
        transactions = fetch_df(conn, "SELECT * FROM RAW.TRANSACTIONS")
    finally:
        conn.close()

    logger.info("Rows fetched -> customers: %d, accounts: %d, transactions: %d",
                len(customers), len(accounts), len(transactions))

    all_issues = []
    all_issues += check_row_counts(customers, accounts, transactions)
    all_issues += check_referential_integrity(accounts, customers, transactions)
    all_issues += check_nulls_and_duplicates(customers, accounts, transactions)

    # Field-level checksum sample - useful when comparing against an
    # Oracle extract of the same table during a migration
    customers_with_checksum = customers.copy()
    customers_with_checksum["row_checksum"] = customers.apply(row_checksum, axis=1)
    customers_with_checksum[["CUSTOMER_ID", "row_checksum"]].to_csv(
        "customers_checksums.csv", index=False
    )
    logger.info("Wrote per-row checksums to customers_checksums.csv (compare against source system extract)")

    report_df = pd.DataFrame(all_issues) if all_issues else pd.DataFrame(
        columns=["check", "table", "detail"]
    )
    report_path = f"reconciliation_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"
    report_df.to_csv(report_path, index=False)

    if all_issues:
        logger.warning("Validation found %d issue(s). See %s", len(all_issues), report_path)
        sys.exit(1)
    else:
        logger.info("All validation checks passed. Report written to %s", report_path)


if __name__ == "__main__":
    main()
