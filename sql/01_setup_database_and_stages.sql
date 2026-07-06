/* ============================================================
   01_SETUP_DATABASE_AND_STAGES.sql
   Project : Bank Transaction Analytics Pipeline
   Purpose : Database/Schema architecture, Warehouse, File Formats,
             Stages (S3 external + internal), first loads
   ============================================================ */

-- -------------------------------------------------
-- 1. WAREHOUSE (compute)
-- -------------------------------------------------
CREATE WAREHOUSE IF NOT EXISTS BANK_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Compute warehouse for bank analytics project';

USE WAREHOUSE BANK_WH;

-- -------------------------------------------------
-- 2. DATABASE + SCHEMA ARCHITECTURE
--    RAW      -> untouched landed data (as-is from source)
--    STAGING  -> cleaned / typed / conformed data (dbt staging models)
--    ANALYTICS-> dimensional model - facts & dimensions (dbt marts)
-- -------------------------------------------------
CREATE DATABASE IF NOT EXISTS BANK_DB;

CREATE SCHEMA IF NOT EXISTS BANK_DB.RAW;
CREATE SCHEMA IF NOT EXISTS BANK_DB.STAGING;
CREATE SCHEMA IF NOT EXISTS BANK_DB.ANALYTICS;
CREATE SCHEMA IF NOT EXISTS BANK_DB.AUDIT;     -- for logs / reconciliation tables

USE DATABASE BANK_DB;
USE SCHEMA RAW;

-- -------------------------------------------------
-- 3. FILE FORMATS
--    One for structured CSV, one for semi-structured JSON (NDJSON)
-- -------------------------------------------------
CREATE OR REPLACE FILE FORMAT BANK_DB.RAW.FF_CSV
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  FIELD_OPTIONALLY_ENCLOSED_BY = '"'
  NULL_IF = ('', 'NULL', 'null')
  EMPTY_FIELD_AS_NULL = TRUE
  TRIM_SPACE = TRUE
  COMMENT = 'Structured CSV format for customers/accounts';

CREATE OR REPLACE FILE FORMAT BANK_DB.RAW.FF_JSON
  TYPE = 'JSON'
  STRIP_OUTER_ARRAY = FALSE      -- our file is NDJSON (one JSON object per line)
  IGNORE_UTF8_ERRORS = TRUE
  COMMENT = 'Semi-structured NDJSON format for transactions';

-- -------------------------------------------------
-- 4. STORAGE INTEGRATION + EXTERNAL STAGE (AWS S3)
--    Do this once per AWS account. Replace ARN / bucket with your own.
--    (Run the ALTER STORAGE INTEGRATION output in AWS IAM trust policy)
-- -------------------------------------------------
-- 4a. Storage integration (run as ACCOUNTADMIN)
CREATE OR REPLACE STORAGE INTEGRATION BANK_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-bank-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://bank-project-raw-data/');

-- Run this and copy the STORAGE_AWS_IAM_USER_ARN + STORAGE_AWS_EXTERNAL_ID
-- into your AWS IAM Role's trust policy before continuing:
DESC STORAGE INTEGRATION BANK_S3_INT;

-- 4b. External stage pointing at your S3 bucket/prefix
CREATE OR REPLACE STAGE BANK_DB.RAW.STG_S3_RAW
  URL = 's3://bank-project-raw-data/'
  STORAGE_INTEGRATION = BANK_S3_INT
  DIRECTORY = (ENABLE = TRUE);   -- lets you SELECT * FROM DIRECTORY(@stage)

-- Sanity check: list files that have landed in S3
LIST @BANK_DB.RAW.STG_S3_RAW;

/* ------------------------------------------------------------
   NOTE FOR BEGINNERS:
   If you don't want to set up AWS IAM roles yet, you can start
   with an INTERNAL stage and PUT the sample files from your
   laptop straight into Snowflake - functionally identical for
   learning COPY INTO / semi-structured loading. See below.
   ------------------------------------------------------------ */
CREATE OR REPLACE STAGE BANK_DB.RAW.STG_INTERNAL
  FILE_FORMAT = BANK_DB.RAW.FF_CSV
  COMMENT = 'Internal stage - use PUT from SnowSQL if skipping S3 setup';

-- From SnowSQL CLI (not the worksheet), run:
--   PUT file:///path/to/sample_data/customers.csv @BANK_DB.RAW.STG_INTERNAL AUTO_COMPRESS=TRUE;
--   PUT file:///path/to/sample_data/accounts.csv  @BANK_DB.RAW.STG_INTERNAL AUTO_COMPRESS=TRUE;
--   PUT file:///path/to/sample_data/transactions.json @BANK_DB.RAW.STG_INTERNAL AUTO_COMPRESS=TRUE;
