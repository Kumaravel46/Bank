-- models/marts/agg_monthly_branch_summary.sql
-- Business-facing aggregate: monthly volume/value per branch,
-- the kind of table Power BI would sit directly on top of.

select
    branch_code,
    date_trunc('month', transaction_date) as txn_month,
    count(transaction_id) as txn_count,
    sum(case when transaction_type = 'CREDIT' then amount else 0 end) as total_credit,
    sum(case when transaction_type = 'DEBIT'  then amount else 0 end) as total_debit,
    sum(amount) as total_value
from {{ ref('fct_transactions') }}
group by branch_code, txn_month
