---
target_repo: dbt-labs/dbt-core
type: bug
status: draft
related: ../plan/04-testing-and-validation.md
---

# `execute_inner` keeps only the literal last physical statement's result, even when a later statement is an empty cleanup query

Found while smoke-testing the SQL Server Fusion (v2) adapter
(`dbt-sqlserver-next/dbt-core` Part 10), but the affected code
(`crates/dbt-adapter/src/adapter/adapter_impl.rs`) is general engine code
shared by every adapter, not part of the SQL Server port itself. A fix
already exists on `dbt-sqlserver-next/dbt-core`'s
`part-10-sqlserver-smoke-test` branch and can be cherry-picked/ported
upstream independently of the SQL Server work.

## Summary

`execute_inner` splits a compiled `statement()` block's SQL into physical
statements (`splitter.split(sql, adapter_type)`) and executes them in
sequence, but the loop only remembers the *last* statement's response:

```rust
let mut last_batch = None;
for sql in statements {
    last_batch = Some(execute_query_with_retry(..., fetch, ...)?);
}
```

This silently returns the wrong result whenever a `statement()` block's
final physical statement is a no-op cleanup query that runs *after* the
meaningful one. SQL Server's `sqlserver__get_test_sql` (vendored verbatim
from v1) is exactly this shape: `EXEC('create view ...')` →
`select count(*) as failures, ...` → `EXEC('drop view ...')`. Because
`CREATE VIEW` must be the sole statement in its own T-SQL batch, the view
creation and drop have to be separate physical statements from the
meaningful `select count(*)`, wrapped in `EXEC()`. `execute_inner`
returned the `DROP VIEW`'s empty (0 rows, 0 columns) result instead of the
count, so `get_test_results` errored with "Test result table should have 1
row and 3 columns, but got 0 rows and 0 columns" on every generic test.

BigQuery and DuckDB are exempted from splitting entirely
(`vec![sql.to_string()]`), and Fabric's own test macro avoids the
multi-statement shape (a single CTE-wrapped `SELECT`, no `CREATE VIEW`), so
neither currently trips this — but any adapter or macro that emits a
multi-statement `fetch_result=True` block ending in a non-`SELECT`
statement would hit the same bug.

## Suggested fix (implemented on the fork, not yet upstreamed)

Track the last statement whose result actually has columns separately from
the literal last statement, and prefer it when `fetch` is true. The
`AdapterResponse` (rows_affected/query_id) still reflects the true last
statement, preserving existing multi-statement DML semantics (e.g.
delete+insert reporting the insert's rowcount).

See `crates/dbt-adapter/src/adapter/adapter_impl.rs` on
`part-10-sqlserver-smoke-test` (commit "fix(adapter): keep the real result
set from a multi-statement query batch").
