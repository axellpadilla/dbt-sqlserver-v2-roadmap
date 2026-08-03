---
target_repo: dbt-labs/dbt-core
type: bug
status: draft
related: ../plan/04-testing-and-validation.md
---

# Unit test SQL wraps a model's own `WITH`-based compiled query as a CTE body, which T-SQL (SQL Server, Fabric) rejects

Measured against SQL Server 2022 (16.0.4265.3, Linux) via the Fusion (v2)
engine's unit-test renderer, smoke-testing jaffle-shop
(`dbt-sqlserver-next/dbt-core` Part 10). Not yet confirmed against a live
Fabric warehouse, but Fabric runs the same T-SQL engine and would hit the
identical restriction.

## Summary

The unit-test scaffold built by `renderable/unit_test.rs` embeds each
`given`/model relation as a named CTE, including the actual model under
test — compiled directly as-is:

```sql
WITH
    TestDB_raw_raw_stores as (SELECT ... UNION ALL SELECT ...),
    TestDB_dbo_stg_locations_expect as (SELECT ... UNION ALL SELECT ...),
    TestDB_dbo_stg_locations_actual as (with

        source as ( select * from TestDB_raw_raw_stores ),
        renamed as ( select ..., CAST(...) as opened_date from source )

        select * from renamed
    )
SELECT * FROM (
    (SELECT ... FROM TestDB_dbo_stg_locations_actual)
    UNION ALL
    (SELECT ... FROM TestDB_dbo_stg_locations_expect)
) unit_test_diff
ORDER BY ...
```

`stg_locations` compiles to its own `with source as (...), renamed as (...)
select * from renamed`, and that entire `WITH`-bearing query is spliced
directly into `TestDB_dbo_stg_locations_actual as (...)`'s parentheses — a
second `WITH` nested inside a CTE body. This is the same restriction
documented in `v2-date-spine-nested-cte-tsql.md`: T-SQL only allows a single
`WITH` introducing a flat CTE list at the start of a statement/batch. Reproduced
directly against a live SQL Server container:

```sql
with rawdata as (
    with p as (select 1 as n)
    select n from p
)
select * from rawdata
```

fails with:

```
Msg 156: Incorrect syntax near the keyword 'with'.
```

which matches the actual failure observed
(`unit_test.jaffle_shop.stg_locations.test_does_location_opened_at_trunc_to_date`):
`[mssql] Could not execute query: Incorrect syntax near the keyword 'with'.
(ErrorNumber 156, ...)`.

## Impact

Any unit test whose target model compiles to a `WITH`-based query (i.e. has
one or more CTEs of its own — extremely common) fails outright on SQL Server
and, once confirmed, likely Fabric. This is broader than the `date_spine`
finding: it hits any model with CTEs, not just ones using a specific macro,
and the failing SQL is generated entirely by the engine's unit-test renderer
rather than by a Jinja macro, so there's no per-adapter macro override that
can fix it — this needs an engine-side change.

## Suggested fix

For dialects that reject nested `WITH` (SQL Server, Fabric), wrap each
relation's compiled SQL in a derived table instead of splicing it straight
into the CTE body, e.g.:

```sql
TestDB_dbo_stg_locations_actual as (
    select * from (
        with source as (...), renamed as (...) select * from renamed
    ) as unit_test_actual_wrapped
)
```

so the inner `WITH` starts its own subquery rather than nesting inside the
outer CTE's parentheses. Needs a working end-to-end test against a live
instance before landing — this issue documents root cause, not a verified
fix.
