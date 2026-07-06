-- snapshots/accounts_snapshot.sql
-- dbt-native way to do SCD Type 2 (alternative to the Snowflake
-- Streams+Tasks version in sql/04_streams_tasks_cdc_scd2.sql).
-- Run with: dbt snapshot

{% snapshot accounts_snapshot %}

{{
    config(
        target_schema='staging',
        unique_key='account_id',
        strategy='timestamp',
        updated_at='last_updated',
    )
}}

select
    account_id,
    customer_id,
    account_type,
    branch_code,
    open_date,
    status,
    last_updated
from {{ source('raw', 'accounts') }}

{% endsnapshot %}
