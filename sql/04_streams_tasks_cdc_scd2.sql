/* ============================================================
   04_STREAMS_TASKS_CDC_SCD2.sql
   Purpose : Change Data Capture using Streams + Tasks, and
             maintaining an SCD Type 2 dimension for ACCOUNTS
             (mirrors the CDC pipeline described in your resume).
   ============================================================ */

USE DATABASE BANK_DB;
USE SCHEMA RAW;
USE WAREHOUSE BANK_WH;

-- -------------------------------------------------
-- 1. STREAM - tracks row-level INSERT/UPDATE/DELETE on ACCOUNTS
-- -------------------------------------------------
CREATE OR REPLACE STREAM RAW.ACCOUNTS_STREAM
  ON TABLE RAW.ACCOUNTS
  APPEND_ONLY = FALSE
  COMMENT = 'CDC stream capturing changes on accounts for SCD2 dimension';

-- Check what the stream currently sees (should be empty right after creation)
SELECT * FROM RAW.ACCOUNTS_STREAM;

-- -------------------------------------------------
-- 2. TARGET SCD TYPE 2 DIMENSION TABLE
-- -------------------------------------------------
CREATE OR REPLACE TABLE STAGING.DIM_ACCOUNTS_SCD2 (
    account_sk       NUMBER AUTOINCREMENT START 1 INCREMENT 1,
    account_id       STRING,
    customer_id      STRING,
    account_type     STRING,
    branch_code      STRING,
    status           STRING,
    effective_start  TIMESTAMP_NTZ,
    effective_end    TIMESTAMP_NTZ,
    is_current       BOOLEAN
);

-- Seed dimension with the initial load (all rows "current")
INSERT INTO STAGING.DIM_ACCOUNTS_SCD2
  (account_id, customer_id, account_type, branch_code, status,
   effective_start, effective_end, is_current)
SELECT
    account_id, customer_id, account_type, branch_code, status,
    CURRENT_TIMESTAMP(), NULL, TRUE
FROM RAW.ACCOUNTS;

-- -------------------------------------------------
-- 3. MERGE logic that applies CDC changes as SCD Type 2
--    (this is what the TASK will run on a schedule)
-- -------------------------------------------------
CREATE OR REPLACE PROCEDURE STAGING.SP_APPLY_ACCOUNTS_SCD2()
RETURNS STRING
LANGUAGE SQL
AS
$$
BEGIN
    -- Step 1: close out changed records (expire old version)
    UPDATE STAGING.DIM_ACCOUNTS_SCD2 d
    SET effective_end = CURRENT_TIMESTAMP(), is_current = FALSE
    FROM RAW.ACCOUNTS_STREAM s
    WHERE d.account_id = s.account_id
      AND d.is_current = TRUE
      AND s.METADATA$ACTION = 'INSERT'
      AND s.METADATA$ISUPDATE = TRUE;

    -- Step 2: insert new current version for changed/new rows
    INSERT INTO STAGING.DIM_ACCOUNTS_SCD2
        (account_id, customer_id, account_type, branch_code, status,
         effective_start, effective_end, is_current)
    SELECT
        s.account_id, s.customer_id, s.account_type, s.branch_code, s.status,
        CURRENT_TIMESTAMP(), NULL, TRUE
    FROM RAW.ACCOUNTS_STREAM s
    WHERE s.METADATA$ACTION = 'INSERT';

    RETURN 'SCD2 merge complete at ' || CURRENT_TIMESTAMP()::STRING;
END;
$$;

-- Manual run/test
CALL STAGING.SP_APPLY_ACCOUNTS_SCD2();
SELECT * FROM STAGING.DIM_ACCOUNTS_SCD2 ORDER BY account_id, effective_start;

-- -------------------------------------------------
-- 4. TASK - schedules the procedure to run automatically
--    In production this would run every 15-60 min after
--    upstream loads land; here it's every 5 minutes for demo.
-- -------------------------------------------------
CREATE OR REPLACE TASK STAGING.TASK_APPLY_ACCOUNTS_SCD2
  WAREHOUSE = BANK_WH
  SCHEDULE = '5 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('RAW.ACCOUNTS_STREAM')   -- skip run if nothing changed (cost saving)
AS
  CALL STAGING.SP_APPLY_ACCOUNTS_SCD2();

-- Tasks are created SUSPENDED by default - must resume to activate
ALTER TASK STAGING.TASK_APPLY_ACCOUNTS_SCD2 RESUME;

-- Check task run history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
  TASK_NAME => 'TASK_APPLY_ACCOUNTS_SCD2'
));

-- -------------------------------------------------
-- 5. SIMULATE A DAY-2 CHANGE FILE arriving
--    (load accounts_day2.csv - a few rows have changed status)
--    then watch the stream + task pick it up.
-- -------------------------------------------------
-- COPY INTO a staging landing table, then MERGE into RAW.ACCOUNTS
CREATE OR REPLACE TABLE RAW.ACCOUNTS_INCOMING LIKE RAW.ACCOUNTS;

COPY INTO RAW.ACCOUNTS_INCOMING
  FROM @BANK_DB.RAW.STG_S3_RAW/accounts_day2.csv
  FILE_FORMAT = (FORMAT_NAME = 'BANK_DB.RAW.FF_CSV')
  ON_ERROR = 'ABORT_STATEMENT';

MERGE INTO RAW.ACCOUNTS tgt
USING RAW.ACCOUNTS_INCOMING src
  ON tgt.account_id = src.account_id
WHEN MATCHED AND tgt.status != src.status THEN
  UPDATE SET tgt.status = src.status, tgt.last_updated = src.last_updated
WHEN NOT MATCHED THEN
  INSERT (account_id, customer_id, account_type, branch_code, open_date, status, last_updated)
  VALUES (src.account_id, src.customer_id, src.account_type, src.branch_code,
          src.open_date, src.status, src.last_updated);

-- Now RAW.ACCOUNTS_STREAM has data -> next task run (or manual CALL) applies SCD2
CALL STAGING.SP_APPLY_ACCOUNTS_SCD2();
SELECT * FROM STAGING.DIM_ACCOUNTS_SCD2
WHERE account_id IN (SELECT account_id FROM RAW.ACCOUNTS_INCOMING)
ORDER BY account_id, effective_start;

-- Suspend the task when you're done experimenting (avoid unnecessary credits)
ALTER TASK STAGING.TASK_APPLY_ACCOUNTS_SCD2 SUSPEND;
