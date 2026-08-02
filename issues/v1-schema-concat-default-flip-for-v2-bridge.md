---
target_repo: dbt-msft/dbt-sqlserver
type: enhancement
status: open
url: https://github.com/dbt-msft/dbt-sqlserver/issues/800
related: ../plan/02-implementation-steps.md
---

# Flip `dbt_sqlserver_use_default_schema_concat`'s default to `True` in the final 1.12 release

## Summary

`dbt/adapters/sqlserver/sqlserver_adapter.py` defines:

```python
{
    "name": "dbt_sqlserver_use_default_schema_concat",
    "default": False,
    ...
}
```

`False` (today's default) uses the legacy adapter behavior: a custom schema
name is used directly, with no `target.schema` prefix. `True` uses dbt-core's
standard concatenation (`target.schema` + `_` + `custom_schema_name`).

Propose flipping the default to `True` in the last 1.12 release — with a
deprecation window to opt back to `False` — before dbt-core v2 (Fusion) ships.

## Why now

The v2 Rust port's shared macro package can't read a behavior flag to gate
this dynamically. `default__generate_schema_name`
(`dbt-adapters/macros/get_custom_name/get_custom_schema.sql`) always does the
standard concatenation, and Fabric — the T-SQL sibling SQL Server's v2 macros
are expected to delegate to where behavior matches
(`02-implementation-steps.md` §5.6) — ships no override either. Absent a
deliberate SQL Server-specific override in Part 8, v2's actual behavior is the
standard concatenation regardless of v1's stored default — so flipping v1
ahead of the migration means schema naming doesn't silently change for anyone
moving from the final 1.12 to v2 with no explicit config.

A user who needs the legacy behavior after the flip overrides
`sqlserver__generate_schema_name` in their own project, the same escape hatch
`get_custom_schema.sql` documents for any adapter.

## References

- `dbt/adapters/sqlserver/sqlserver_adapter.py` — `dbt_sqlserver_use_default_schema_concat`
- `dbt-core/crates/dbt-loader/src/dbt_macro_assets/dbt-adapters/macros/get_custom_name/get_custom_schema.sql` — `default__generate_schema_name`
- `../plan/02-implementation-steps.md` §5.6 — macro delegation guidance
