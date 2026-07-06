/* ============================================================
   02_LOAD_RAW_DATA.sql
   Purpose : Create RAW tables, load structured (CSV) and
             semi-structured (JSON/VARIANT) data via COPY INTO,
             then FLATTEN the JSON into a queryable structured table.
   ============================================================ */

USE DATABASE BANK_DB;
USE SCHEMA RAW;
USE WAREHOUSE BANK_WH;

-- -------------------------------------------------
-- 1. STRUCTURED TABLES (Customers, Accounts)
-- -------------------------------------------------
CREATE OR REPLACE TABLE RAW.CUSTOMERS (
    customer_id     STRING,
    first_name      STRING,
    last_name       STRING,
    email           STRING,
    phone           STRING,
    dob             DATE,
    kyc_status      STRING,
    created_date    DATE
);

CREATE OR REPLACE TABLE RAW.ACCOUNTS (
    account_id      STRING,
    customer_id     STRING,
    account_type    STRING,
    branch_code     STRING,
    open_date       DATE,
    status          STRING,
    last_updated    DATE
);

-- Load from S3 (or swap stage name to STG_INTERNAL if using PUT)
COPY INTO RAW.CUSTOMERS
  FROM @BANK_DB.RAW.STG_S3_RAW/customers.csv
  FILE_FORMAT = (FORMAT_NAME = 'BANK_DB.RAW.FF_CSV')
  ON_ERROR = 'ABORT_STATEMENT';

COPY INTO RAW.ACCOUNTS
  FROM @BANK_DB.RAW.STG_S3_RAW/accounts.csv
  FILE_FORMAT = (FORMAT_NAME = 'BANK_DB.RAW.FF_CSV')
  ON_ERROR = 'ABORT_STATEMENT';

-- Validate the load
SELECT COUNT(*) AS customer_count FROM RAW.CUSTOMERS;
SELECT COUNT(*) AS account_count  FROM RAW.ACCOUNTS;

-- Check load history / errors (real project habit - always verify loads)
SELECT * FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'RAW.CUSTOMERS',
  START_TIME => DATEADD(HOUR, -1, CURRENT_TIMESTAMP())
));

-- -------------------------------------------------
-- 2. SEMI-STRUCTURED TABLE (Transactions -> VARIANT)
--    Landing raw JSON as-is in a single VARIANT column
--    is the standard Snowflake pattern.
-- -------------------------------------------------
CREATE OR REPLACE TABLE RAW.TRANSACTIONS_RAW (
    raw_json    VARIANT,
    load_ts     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

COPY INTO RAW.TRANSACTIONS_RAW (raw_json)
  FROM @BANK_DB.RAW.STG_S3_RAW/transactions.json
  FILE_FORMAT = (FORMAT_NAME = 'BANK_DB.RAW.FF_JSON')
  MATCH_BY_COLUMN_NAME = NONE
  ON_ERROR = 'ABORT_STATEMENT';

SELECT COUNT(*) FROM RAW.TRANSACTIONS_RAW;
SELECT raw_json FROM RAW.TRANSACTIONS_RAW LIMIT 3;

-- -------------------------------------------------
-- 3. FLATTEN semi-structured JSON into a structured table
--    Demonstrates dot-notation + FLATTEN() for nested arrays
-- -------------------------------------------------
CREATE OR REPLACE TABLE RAW.TRANSACTIONS AS
SELECT
    raw_json:transaction_id::STRING          AS transaction_id,
    raw_json:account_id::STRING              AS account_id,
    raw_json:transaction_date::TIMESTAMP_NTZ AS transaction_date,
    raw_json:amount::NUMBER(18,2)            AS amount,
    raw_json:type::STRING                    AS transaction_type,
    raw_json:channel::STRING                 AS channel,
    raw_json:merchant.name::STRING           AS merchant_name,
    raw_json:merchant.category::STRING       AS merchant_category,
    raw_json:merchant.location.city::STRING  AS merchant_city,
    raw_json:merchant.location.state::STRING AS merchant_state,
    raw_json:metadata.device_id::STRING      AS device_id,
    raw_json:metadata.ip_address::STRING     AS ip_address,
    flag.value::STRING                       AS transaction_flag
FROM RAW.TRANSACTIONS_RAW,
     LATERAL FLATTEN(input => raw_json:metadata.flags) flag;

SELECT * FROM RAW.TRANSACTIONS LIMIT 10;
