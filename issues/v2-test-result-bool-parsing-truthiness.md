---
target_repo: dbt-labs/dbt-core
type: bug
status: draft
related: ../plan/04-testing-and-validation.md
---

# `get_test_results` reads `should_warn`/`should_error` via generic Jinja truthiness, so a textual `'false'` is read as `true`

Found while smoke-testing the SQL Server Fusion (v2) adapter
(`dbt-sqlserver-next/dbt-core` Part 10), but the affected code
(`crates/dbt-tasks-sa/src/materialize.rs`) is general engine code shared by
every adapter, not part of the SQL Server port itself. A fix already
exists on `dbt-sqlserver-next/dbt-core`'s `part-10-sqlserver-smoke-test`
branch and can be cherry-picked/ported upstream independently of the SQL
Server work.

## Summary

`get_test_results`/`get_column_test_result` read the `should_warn`/
`should_error` columns via minijinja's `Value::is_true()`:

```rust
let should_warn_val = should_warn.map(|v| v.is_true()).unwrap_or(false);
```

`Value::is_true()` treats any non-empty string as true (`ValueRepr::String(x)
=> !x.is_empty()`), matching general Jinja truthiness. `get_test_sql` is not
guaranteed to return a native boolean, though: SQL Server has no boolean
literal, so `sqlserver__get_test_sql` (vendored verbatim from v1) emits the
text `'true'`/`'false'` instead of `true`/`false`/`1`/`0`. The literal string
`'false'` is non-empty, so `is_true()` reads it as `true` — every test on
SQL Server reported `should_error` regardless of the actual failure count.

v1's Python equivalent does not have this bug: `dbt.task.test.
BaseTestResultData.convert_bool_type()` explicitly parses the string case
via `strtobool()` before falling back to `bool(field)` — written with
exactly this "an adapter's test SQL returns text, not a native boolean"
case in mind. The v2 port's generic truthiness read is a regression against
that.

## Suggested fix (implemented on the fork, not yet upstreamed)

Parse recognized `'true'`/`'false'` text explicitly (case-insensitive)
before falling back to `is_true()` for everything else (real booleans, 0/1
integers) — mirroring v1's `convert_bool_type`.

See `crates/dbt-tasks-sa/src/materialize.rs` on
`part-10-sqlserver-smoke-test` (commit "fix(tests): parse
should_warn/should_error text before falling back to truthiness",
`value_to_test_bool`).
