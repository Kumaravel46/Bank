-- models/staging/stg_transactions.sql

with source as (
    select * from {{ source('raw', 'transactions') }}
),

cleaned as (
    select
        transaction_id,
        account_id,
        transaction_date,
        amount,
        upper(transaction_type)  as transaction_type,
        upper(channel)           as channel,
        merchant_name,
        upper(merchant_category) as merchant_category,
        merchant_city,
        merchant_state,
        transaction_flag,
        case
            when amount < 1000    then 'LOW'
            when amount < 25000   then 'MEDIUM'
            when amount < 100000  then 'HIGH'
            else 'VERY_HIGH'
        end as transaction_tier
    from source
    where transaction_id is not null
)

select * from cleaned
