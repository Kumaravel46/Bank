-- tests/assert_no_negative_amounts.sql
-- Custom singular test: fails (returns rows) if any transaction
-- amount is negative or zero - a real business rule check.

select transaction_id, amount
from {{ ref('stg_transactions') }}
where amount <= 0
