---
target_repo: dbt-labs/dbt-core
type: bug
status: draft
related: ../plan/04-testing-and-validation.md
---

# Unit test `given` upstream relation schema fetch intermittently fails against SQL Server, root cause unconfirmed

Observed twice while smoke-testing the SQL Server Fusion (v2) adapter against
jaffle-shop (`dbt-sqlserver-next/dbt-core` Part 10), across two independent
`dbt build` runs — but for a *different* relation each time, which is why
this is filed separately from the two confirmed nested-`WITH` findings
(`v2-date-spine-nested-cte-tsql.md`,
`v2-unit-test-actual-cte-nests-model-with-clause-tsql.md`) rather than
folded into either.

## Summary

`fetch_schema_for_unit_test_relation` (`renderable/unit_test.rs`) calls
`metadata_adapter.list_relations_sdf_schemas` to resolve the schema of a unit
test's `given`/upstream relation before building the test's SQL. This call
fails with a generic, un-elaborated error:

```
[error] [ExecutorFailed (dbt1401)]: Remote database error while fetching
schema for unit test upstream relation from `given`
'"TestDB"."dbo"."stg_supplies"'
```

Unlike the other database errors surfaced in the same runs (which all
include the driver's own message, e.g. `[mssql] Could not execute query:
...`), this error carries no inner SQL/driver detail — the `AdapterError`
being converted by `into_fs_error` appears to have an empty or generic
message at this call site, which is itself worth investigating independently
of the underlying failure.

Two data points so far:
- Run 1 (pre-rebase, `part-10-sqlserver-smoke-test`): failed for
  `"TestDB"."raw"."raw_stores"` *and* `"TestDB"."dbo"."stg_supplies"`.
- Run 2 (post-rebase onto `upstream-fix-execute-inner-last-batch`): failed
  only for `"TestDB"."dbo"."stg_supplies"` — `raw_stores` succeeded this
  time.

Both target relations existed and had already built successfully earlier in
the same run (visible in the build log preceding each failure), which rules
out "relation doesn't exist yet" as the cause. The fact that different runs
fail on different relations suggests either a timing/ordering race in when
the metadata catalog call runs relative to some other state, or a
relation-shape-dependent catalog query bug (e.g. specific to views built via
the multi-statement `CREATE VIEW`-based test/materialization pattern) — not
yet distinguished.

## Impact

Unknown scope until root-caused: at minimum, some unit tests intermittently
fail to resolve their `given` relation's schema against SQL Server, which
blocks the unit test entirely (`Skipped` cascade for everything downstream
in the same run). Not yet confirmed whether this reproduces on other
adapters or is SQL-Server-specific.

## Suggested fix

Not yet identified — this issue documents an observed, reproducible-in-kind
(but not reproducible-in-specifics) symptom, not a root cause. Next step is
a live-instance run with the metadata adapter's SQL/call tracing enabled to
capture the actual underlying error `into_fs_error` is discarding, and to
check whether the failure is deterministic per-relation or genuinely
timing-dependent across runs.
