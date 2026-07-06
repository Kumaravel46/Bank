-- models/staging/stg_accounts.sql

with source as (
    select * from {{ source('raw', 'accounts') }}
),

cleaned as (
    select
        account_id,
        customer_id,
        upper(account_type) as account_type,
        branch_code,
        open_date,
        upper(status)        as status,
        last_updated
    from source
    where account_id is not null
)

select * from cleaned
