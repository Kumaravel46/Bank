"""
cortex_nl_query.py
-------------------
Python-based prompt workflow on top of Snowflake Cortex AI, letting
a business user ask a question in plain English and get it answered
against the ANALYTICS tables - no SQL knowledge required.

Mirrors the resume bullet:
  "Using Snowflake Cortex AI to build a natural language query
   interface on structured financial datasets, with Python based
   prompt workflows that allow business users to query data
   directly without SQL knowledge."

This is a simplified text-to-SQL pattern:
 1. Send the user's question + a description of the table schema
    to Cortex COMPLETE, asking it to return ONLY a SQL query.
 2. Run that SQL query against Snowflake.
 3. Return the results back to the user.

In production you'd add: SQL validation/sandboxing before execution,
row-level security enforcement, and a proper chat UI (e.g. Streamlit).

Usage:
    python cortex_nl_query.py "What was the total transaction value by branch last month?"
"""

import os
import sys
import textwrap

import snowflake.connector
from dotenv import load_dotenv

load_dotenv()

SCHEMA_DESCRIPTION = textwrap.dedent("""
    Table: ANALYTICS.FCT_TRANSACTIONS
      transaction_id, transaction_date, amount, transaction_type (CREDIT/DEBIT),
      channel, merchant_name, merchant_category, merchant_city, merchant_state,
      transaction_tier, account_id, account_type, branch_code,
      customer_id, customer_name, kyc_status

    Table: ANALYTICS.DIM_CUSTOMERS
      customer_id, full_name, email, phone, dob, customer_age, kyc_status,
      created_date, number_of_accounts

    Table: ANALYTICS.DIM_ACCOUNTS
      account_id, customer_id, account_type, branch_code, open_date, status
""").strip()


def get_connection():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.getenv("SNOWFLAKE_ROLE", "BANK_ANALYST"),
        warehouse=os.getenv("SNOWFLAKE_WAREHOUSE", "BANK_WH"),
        database=os.getenv("SNOWFLAKE_DATABASE", "BANK_DB"),
        schema="ANALYTICS",
    )


def build_prompt(question: str) -> str:
    return textwrap.dedent(f"""
        You are a Snowflake SQL expert. Given the schema below, write ONE
        Snowflake SQL query that answers the user's question.
        Return ONLY the SQL query - no explanation, no markdown fences.

        Schema:
        {SCHEMA_DESCRIPTION}

        Question: {question}
    """).strip()


def ask_cortex(cursor, question: str) -> str:
    prompt = build_prompt(question)
    cursor.execute(
        "SELECT SNOWFLAKE.CORTEX.COMPLETE(%s, %s)",
        ("llama3.1-70b", prompt),
    )
    generated_sql = cursor.fetchone()[0]
    return generated_sql.strip().strip(";")


def run_generated_sql(cursor, sql: str):
    # NOTE: in production, validate this is a read-only SELECT before
    # executing - never run LLM-generated SQL blindly against prod.
    if not sql.lstrip().upper().startswith("SELECT"):
        raise ValueError(f"Refusing to execute non-SELECT generated SQL: {sql}")
    cursor.execute(sql)
    columns = [c[0] for c in cursor.description]
    rows = cursor.fetchall()
    return columns, rows


def main():
    if len(sys.argv) < 2:
        print('Usage: python cortex_nl_query.py "your question here"')
        sys.exit(1)

    question = " ".join(sys.argv[1:])
    conn = get_connection()
    cursor = conn.cursor()

    try:
        print(f"Question: {question}\n")
        generated_sql = ask_cortex(cursor, question)
        print(f"Generated SQL:\n{generated_sql}\n")

        columns, rows = run_generated_sql(cursor, generated_sql)
        print(" | ".join(columns))
        for row in rows[:20]:
            print(" | ".join(str(v) for v in row))
    finally:
        cursor.close()
        conn.close()


if __name__ == "__main__":
    main()
