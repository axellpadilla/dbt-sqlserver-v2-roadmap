---
target_repo: dbt-labs/dbt-utils
type: bug
status: draft
related: ../plan/04-testing-and-validation.md
---

# `expression_is_true`'s default macro selects an unaliased literal, which fails on T-SQL engines (SQL Server, Fabric) unless `store_failures` is set

Measured against SQL Server 2022 (16.0.4265.3, Linux), but the same T-SQL
engine backs Microsoft Fabric Warehouse/Synapse, so this isn't specific to
on-prem SQL Server.

## Summary

`macros/generic_tests/expression_is_true.sql`'s `default__test_expression_is_true`:

```jinja
{% set column_list = '*' if should_store_failures() else "1" %}

select
    {{ column_list }}
from {{ model }}
where not({{ expression }})
```

selects a bare literal `1` (no alias) whenever `store_failures` isn't set —
which is the default. Every generic-test-wrapping macro in dbt-core wraps
`main_sql` in a named derived table (`from (main_sql) dbt_internal_test`, or
SQL Server's equivalent view). T-SQL requires every column of a named
derived table or view to have an explicit name, even when the caller (here,
just `count(*)`) never references the column by name:

```
Msg 8155: No column name was specified for column 1 of 'dbt_internal_test'.
```

Reproduced directly against a live SQL Server container, independent of any
dbt-core code path:

```sql
select count(*) as failures
from (select 1 from some_table where not(1=2)) dbt_internal_test
```

fails with the same error. This is a general T-SQL derived-table/view rule
(SQL Server, Fabric), not an artifact of how any particular adapter wraps the
test query.

## Impact

Any project using `dbt_utils.expression_is_true` (or `dbt_utils.equality`,
`accepted_range`, or other generic tests built on the same default macro
without a `column_name`) against SQL Server or Fabric without
`store_failures: true` hits this at test time. Discovered while smoke-testing
the SQL Server Fusion (v2) adapter against jaffle-shop
(`dbt-sqlserver-next/dbt-core` Part 10), but the query dbt_utils generates is
identical for v1 and v2, and for Fabric — this isn't a v2-only regression.

## Suggested fix

Add a `fabric__test_expression_is_true` / `sqlserver__test_expression_is_true`
override that aliases the literal, e.g. `select 1 as expression_is_true`
instead of bare `1` — mirroring how `fabric__cents_to_dollars` and similar
per-engine overrides already exist in project macro packages for this kind of
T-SQL quirk.
