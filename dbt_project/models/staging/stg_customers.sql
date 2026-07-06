-- models/staging/stg_customers.sql
-- Clean, typed, conformed view of raw customers.
-- Staging models: 1:1 with source, light cleaning only, no business logic.

with source as (
    select * from {{ source('raw', 'customers') }}
),

cleaned as (
    select
        customer_id,
        initcap(trim(first_name))   as first_name,
        initcap(trim(last_name))    as last_name,
        lower(trim(email))          as email,
        phone,
        dob,
        upper(kyc_status)           as kyc_status,
        created_date,
        datediff('year', dob, current_date()) as customer_age
    from source
    where customer_id is not null
)

select * from cleaned
