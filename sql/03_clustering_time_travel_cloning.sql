/* ============================================================
   03_CLUSTERING_TIME_TRAVEL_CLONING.sql
   Purpose : Hands-on demo of Clustering Keys, Time Travel,
             and Zero-Copy Cloning - all real cost/performance
             levers you'd tune in production.
   ============================================================ */

USE DATABASE BANK_DB;
USE SCHEMA RAW;
USE WAREHOUSE BANK_WH;

-- -------------------------------------------------
-- 1. CLUSTERING KEY
--    Transactions table will be queried mostly by date range
--    and account_id -> cluster on those columns to prune
--    micro-partitions and speed up range scans.
-- -------------------------------------------------
ALTER TABLE RAW.TRANSACTIONS
  CLUSTER BY (transaction_date, account_id);

-- Check clustering quality/depth (run after decent data volume)
SELECT SYSTEM$CLUSTERING_INFORMATION('RAW.TRANSACTIONS', '(transaction_date, account_id)');

-- Manually trigger reclustering info (Snowflake auto-reclusters in background)
SELECT SYSTEM$CLUSTERING_DEPTH('RAW.TRANSACTIONS', '(transaction_date, account_id)');

-- -------------------------------------------------
-- 2. TIME TRAVEL
--    Simulate an accidental bad update, then recover data
--    exactly the way you would in an incident.
-- -------------------------------------------------
-- Set retention period (in days) - default is 1, Enterprise allows up to 90
ALTER TABLE RAW.ACCOUNTS SET DATA_RETENTION_TIME_IN_DAYS = 5;

-- Oops - a bad bulk update sets every account to CLOSED
UPDATE RAW.ACCOUNTS SET status = 'CLOSED';

-- Recovery option A: query data as of before the bad update
SELECT account_id, status
FROM RAW.ACCOUNTS
  AT (OFFSET => -60)          -- data as it was 60 seconds ago
LIMIT 5;

-- Recovery option B: query using a specific timestamp
-- SELECT * FROM RAW.ACCOUNTS AT (TIMESTAMP => '2026-07-04 10:00:00'::TIMESTAMP_NTZ);

-- Recovery option C: restore the whole table using CREATE OR REPLACE ... AT
CREATE OR REPLACE TABLE RAW.ACCOUNTS AS
SELECT * FROM RAW.ACCOUNTS AT (OFFSET => -60);

-- If a table was DROPped entirely, Time Travel also lets you UNDROP:
-- DROP TABLE RAW.ACCOUNTS;
-- UNDROP TABLE RAW.ACCOUNTS;

-- -------------------------------------------------
-- 3. ZERO-COPY CLONING
--    Instant, storage-free copies for dev/test/UAT environments
--    or for safely testing a migration before touching prod.
-- -------------------------------------------------
-- Clone a single table (e.g. to test a risky transformation)
CREATE OR REPLACE TABLE RAW.ACCOUNTS_DEV CLONE RAW.ACCOUNTS;

-- Clone an entire schema (common pattern: spin up a "DEV" schema
-- that mirrors PROD instantly for a sprint's testing)
CREATE OR REPLACE SCHEMA BANK_DB.RAW_DEV CLONE BANK_DB.RAW;

-- Clone a database as of a point in time (useful before a big migration cutover)
-- CREATE DATABASE BANK_DB_BACKUP CLONE BANK_DB AT (OFFSET => -3600);

-- Verify clone is independent - changes to clone don't affect source
UPDATE RAW.ACCOUNTS_DEV SET status = 'TEST_ONLY' WHERE account_id = 'ACC000001';
SELECT status FROM RAW.ACCOUNTS     WHERE account_id = 'ACC000001';  -- unaffected
SELECT status FROM RAW.ACCOUNTS_DEV WHERE account_id = 'ACC000001';  -- changed

-- Clean up dev objects when done
DROP TABLE IF EXISTS RAW.ACCOUNTS_DEV;
DROP SCHEMA IF EXISTS BANK_DB.RAW_DEV;
