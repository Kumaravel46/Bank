/* ============================================================
   06_GOVERNANCE_RBAC_MASKING_RESOURCE_MONITORS.sql
   Purpose : Data governance & cost control - RBAC roles,
             Dynamic Data Masking, Column-Level Security,
             Resource Monitors (all called out in your resume).
   ============================================================ */

USE ROLE SECURITYADMIN;

-- -------------------------------------------------
-- 1. RBAC - functional roles for a BFSI project
-- -------------------------------------------------
CREATE ROLE IF NOT EXISTS BANK_DATA_ENGINEER;
CREATE ROLE IF NOT EXISTS BANK_ANALYST;
CREATE ROLE IF NOT EXISTS BANK_AUDITOR;

GRANT USAGE ON DATABASE BANK_DB TO ROLE BANK_DATA_ENGINEER;
GRANT USAGE ON DATABASE BANK_DB TO ROLE BANK_ANALYST;
GRANT USAGE ON DATABASE BANK_DB TO ROLE BANK_AUDITOR;

GRANT USAGE ON ALL SCHEMAS IN DATABASE BANK_DB TO ROLE BANK_DATA_ENGINEER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA BANK_DB.RAW TO ROLE BANK_DATA_ENGINEER;

-- Analysts only get read access to the ANALYTICS (mart) layer, never RAW
GRANT USAGE ON SCHEMA BANK_DB.ANALYTICS TO ROLE BANK_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA BANK_DB.ANALYTICS TO ROLE BANK_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA BANK_DB.ANALYTICS TO ROLE BANK_ANALYST;

-- Auditors get read-only access to the audit/reconciliation schema only
GRANT USAGE ON SCHEMA BANK_DB.AUDIT TO ROLE BANK_AUDITOR;
GRANT SELECT ON ALL TABLES IN SCHEMA BANK_DB.AUDIT TO ROLE BANK_AUDITOR;

-- Assign roles to users (replace with real usernames)
-- GRANT ROLE BANK_DATA_ENGINEER TO USER kumaravel_k;
-- GRANT ROLE BANK_ANALYST TO USER some_analyst;

USE ROLE ACCOUNTADMIN;

-- -------------------------------------------------
-- 2. DYNAMIC DATA MASKING - hide PII from non-privileged roles
--    (email/phone should not be visible to analysts, only to
--     data engineers / compliance)
-- -------------------------------------------------
CREATE OR REPLACE MASKING POLICY BANK_DB.RAW.MASK_EMAIL AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('BANK_DATA_ENGINEER','ACCOUNTADMIN') THEN val
    ELSE REGEXP_REPLACE(val, '^(.)(.*)(@.*)$', '\\1***\\3')   -- j***@example.com
  END;

CREATE OR REPLACE MASKING POLICY BANK_DB.RAW.MASK_PHONE AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() IN ('BANK_DATA_ENGINEER','ACCOUNTADMIN') THEN val
    ELSE 'XXXXXX' || RIGHT(val, 4)
  END;

ALTER TABLE BANK_DB.RAW.CUSTOMERS MODIFY COLUMN email SET MASKING POLICY BANK_DB.RAW.MASK_EMAIL;
ALTER TABLE BANK_DB.RAW.CUSTOMERS MODIFY COLUMN phone SET MASKING POLICY BANK_DB.RAW.MASK_PHONE;

-- Test: switch role and query to confirm masking applies
-- USE ROLE BANK_ANALYST;
-- SELECT customer_id, email, phone FROM BANK_DB.RAW.CUSTOMERS LIMIT 5;

-- -------------------------------------------------
-- 3. ROW ACCESS POLICY (column/row level security) -
--    restrict a branch manager to only their own branch's accounts
-- -------------------------------------------------
CREATE OR REPLACE TABLE BANK_DB.RAW.BRANCH_ACCESS_MAP (
    role_name    STRING,
    branch_code  STRING
);
INSERT INTO BANK_DB.RAW.BRANCH_ACCESS_MAP VALUES ('BANK_ANALYST', 'CHN001');

CREATE OR REPLACE ROW ACCESS POLICY BANK_DB.RAW.BRANCH_RAP AS (branch_code STRING)
RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1 FROM BANK_DB.RAW.BRANCH_ACCESS_MAP m
    WHERE m.role_name = CURRENT_ROLE() AND m.branch_code = branch_code
  )
  OR CURRENT_ROLE() IN ('ACCOUNTADMIN','BANK_DATA_ENGINEER');

ALTER TABLE BANK_DB.RAW.ACCOUNTS ADD ROW ACCESS POLICY BANK_DB.RAW.BRANCH_RAP ON (branch_code);

-- -------------------------------------------------
-- 4. RESOURCE MONITOR - guardrail on warehouse credit spend
--    (directly reflects the 25% Cortex compute-cost reduction
--     bullet in your resume)
-- -------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR BANK_WH_MONITOR
  WITH CREDIT_QUOTA = 50
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATE
  TRIGGERS
    ON 75  PERCENT DO NOTIFY
    ON 90  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND
    ON 110 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE BANK_WH SET RESOURCE_MONITOR = BANK_WH_MONITOR;

-- Query monitoring: find your most expensive queries this week (cost tuning habit)
SELECT query_text, total_elapsed_time/1000 AS seconds, warehouse_name, execution_status
FROM TABLE(INFORMATION_SCHEMA.QUERY_HISTORY())
WHERE start_time >= DATEADD('day', -7, CURRENT_TIMESTAMP())
ORDER BY total_elapsed_time DESC
LIMIT 20;
