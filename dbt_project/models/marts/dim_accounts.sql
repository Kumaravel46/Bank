-- models/marts/dim_accounts.sql
-- Dimension table - Star Schema (current-state view;
-- full SCD Type 2 history lives in the Snowflake table
-- STAGING.DIM_ACCOUNTS_SCD2 built via Streams+Tasks, see
-- sql/04_streams_tasks_cdc_scd2.sql)

select
    account_id,
    customer_id,
    account_type,
    branch_code,
    open_date,
    status,
    last_updated
from {{ ref('stg_accounts') }}
