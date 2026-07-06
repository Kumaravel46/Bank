-- models/marts/fct_transactions.sql
-- Fact table - Star Schema
-- Grain: one row per transaction, joined to account/customer dims
-- for convenient analyst querying without needing extra joins.

with transactions as (
    select * from {{ ref('stg_transactions') }}
),

accounts as (
    select * from {{ ref('dim_accounts') }}
),

customers as (
    select * from {{ ref('dim_customers') }}
)

select
    t.transaction_id,
    t.transaction_date,
    t.amount,
    t.transaction_type,
    t.channel,
    t.merchant_name,
    t.merchant_category,
    t.merchant_city,
    t.merchant_state,
    t.transaction_tier,
    t.transaction_flag,
    a.account_id,
    a.account_type,
    a.branch_code,
    c.customer_id,
    c.full_name as customer_name,
    c.kyc_status
from transactions t
inner join accounts a  on t.account_id  = a.account_id
inner join customers c on a.customer_id = c.customer_id
