/* ============================================================
   05_PROCEDURES_FUNCTIONS_CURSOR_JOINS_CTE.sql
   Purpose : Stored procedure using a CURSOR (row-by-row logic,
             mirrors your reconciliation-framework experience),
             UDFs, and analytical SQL with JOINs / CTEs / window
             functions - the kind of queries analysts consume.
   ============================================================ */

USE DATABASE BANK_DB;
USE SCHEMA STAGING;
USE WAREHOUSE BANK_WH;

-- -------------------------------------------------
-- 1. SCALAR FUNCTION (UDF) - classify transaction size
-- -------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_TRANSACTION_TIER(amount NUMBER)
RETURNS STRING
LANGUAGE SQL
AS
$$
  CASE
    WHEN amount < 1000        THEN 'LOW'
    WHEN amount < 25000        THEN 'MEDIUM'
    WHEN amount < 100000       THEN 'HIGH'
    ELSE 'VERY_HIGH'
  END
$$;

SELECT transaction_id, amount, STAGING.FN_TRANSACTION_TIER(amount) AS tier
FROM RAW.TRANSACTIONS
LIMIT 10;

-- -------------------------------------------------
-- 2. FUNCTION - calculate customer age from DOB (used in KYC checks)
-- -------------------------------------------------
CREATE OR REPLACE FUNCTION STAGING.FN_CUSTOMER_AGE(dob DATE)
RETURNS NUMBER
LANGUAGE SQL
AS
$$
  DATEDIFF(YEAR, dob, CURRENT_DATE())
$$;

SELECT customer_id, dob, STAGING.FN_CUSTOMER_AGE(dob) AS age
FROM RAW.CUSTOMERS
LIMIT 10;

-- -------------------------------------------------
-- 3. STORED PROCEDURE WITH CURSOR
--    Real-world use case from your resume: a reconciliation
--    framework that walks through accounts one at a time,
--    recalculates a running balance from transactions, and
--    logs any account whose derived balance looks abnormal.
--    (Cursors are rarely the fastest option in Snowflake - set
--    based SQL usually wins - but this is exactly the pattern
--    interviewers ask about, so it's worth having in your project.)
-- -------------------------------------------------
CREATE OR REPLACE TABLE AUDIT.RECONCILIATION_LOG (
    account_id      STRING,
    txn_count       NUMBER,
    net_amount      NUMBER(18,2),
    checked_at      TIMESTAMP_NTZ,
    flag            STRING
);

CREATE OR REPLACE PROCEDURE STAGING.SP_RECONCILE_ACCOUNTS()
RETURNS STRING
LANGUAGE SQL
AS
$$
DECLARE
    v_account_id   STRING;
    v_txn_count    NUMBER;
    v_net_amount   NUMBER(18,2);
    v_flag         STRING;
    row_count      NUMBER DEFAULT 0;

    -- Cursor over every active account
    acc_cursor CURSOR FOR
        SELECT account_id FROM RAW.ACCOUNTS WHERE status = 'ACTIVE';
BEGIN
    FOR rec IN acc_cursor DO
        v_account_id := rec.account_id;

        SELECT COUNT(*), COALESCE(SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount
                                            ELSE -amount END), 0)
          INTO :v_txn_count, :v_net_amount
        FROM RAW.TRANSACTIONS
        WHERE account_id = :v_account_id;

        v_flag := CASE WHEN v_net_amount < -500000 THEN 'REVIEW_LARGE_OUTFLOW'
                        ELSE 'OK' END;

        INSERT INTO AUDIT.RECONCILIATION_LOG
        VALUES (:v_account_id, :v_txn_count, :v_net_amount, CURRENT_TIMESTAMP(), :v_flag);

        row_count := row_count + 1;
    END FOR;

    RETURN 'Reconciled ' || row_count || ' accounts.';
END;
$$;

CALL STAGING.SP_RECONCILE_ACCOUNTS();
SELECT * FROM AUDIT.RECONCILIATION_LOG WHERE flag != 'OK';

-- -------------------------------------------------
-- 4. JOINS + CTEs - analytical query an analyst/PM would ask for:
--    "Monthly transaction volume and value per branch, with
--     each branch's rank versus other branches"
-- -------------------------------------------------
WITH txn_with_branch AS (
    SELECT
        a.branch_code,
        t.transaction_id,
        t.amount,
        t.transaction_type,
        DATE_TRUNC('MONTH', t.transaction_date) AS txn_month
    FROM RAW.TRANSACTIONS t
    INNER JOIN RAW.ACCOUNTS a
        ON t.account_id = a.account_id
),
monthly_branch_summary AS (
    SELECT
        branch_code,
        txn_month,
        COUNT(transaction_id)                                   AS txn_count,
        SUM(CASE WHEN transaction_type = 'CREDIT' THEN amount ELSE 0 END) AS total_credit,
        SUM(CASE WHEN transaction_type = 'DEBIT'  THEN amount ELSE 0 END) AS total_debit
    FROM txn_with_branch
    GROUP BY branch_code, txn_month
)
SELECT
    branch_code,
    txn_month,
    txn_count,
    total_credit,
    total_debit,
    RANK() OVER (PARTITION BY txn_month ORDER BY txn_count DESC) AS branch_rank_by_volume
FROM monthly_branch_summary
ORDER BY txn_month, branch_rank_by_volume;

-- -------------------------------------------------
-- 5. Customer 360 view - JOIN across all three tables + CTE
--    for "top 10 customers by total transaction value"
-- -------------------------------------------------
WITH customer_txn_totals AS (
    SELECT
        c.customer_id,
        c.first_name || ' ' || c.last_name AS customer_name,
        SUM(t.amount) AS total_txn_value,
        COUNT(t.transaction_id) AS txn_count
    FROM RAW.CUSTOMERS c
    JOIN RAW.ACCOUNTS a      ON c.customer_id = a.customer_id
    JOIN RAW.TRANSACTIONS t  ON a.account_id  = t.account_id
    GROUP BY c.customer_id, customer_name
)
SELECT *
FROM customer_txn_totals
ORDER BY total_txn_value DESC
LIMIT 10;
