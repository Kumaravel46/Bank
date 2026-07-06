-- models/marts/dim_customers.sql
-- Dimension table - Star Schema

with customers as (
    select * from {{ ref('stg_customers') }}
),

account_counts as (
    select customer_id, count(*) as number_of_accounts
    from {{ ref('stg_accounts') }}
    group by customer_id
)

select
    c.customer_id,
    c.first_name,
    c.last_name,
    c.first_name || ' ' || c.last_name as full_name,
    c.email,
    c.phone,
    c.dob,
    c.customer_age,
    c.kyc_status,
    c.created_date,
    coalesce(a.number_of_accounts, 0) as number_of_accounts
from customers c
left join account_counts a on c.customer_id = a.customer_id
