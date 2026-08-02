---
target_repo: dbt-msft/dbt-sqlserver
type: bug
status: draft
related: ../plan/02-implementation-steps.md
---

# `check_schema_exists` and `get_relation_last_modified` ignore their database argument and answer about whichever database `USE` last selected

Both macros take an `information_schema` argument, neither uses it, and both read
`sys.*` — which is database-scoped. Their answer therefore depends on the
connection's current database, which an unrelated earlier macro sets with `USE`
and never restores.

Measured against SQL Server 2022 (16.0.4265.3, Linux).

## Summary

`dbt/include/sqlserver/macros/adapters/metadata.sql`:

```jinja
{% macro sqlserver__check_schema_exists(information_schema, schema) -%}
  {% call statement('check_schema_exists', fetch_result=True, auto_begin=False) -%}
    SELECT count(*) as schema_exist FROM sys.schemas WHERE name = '{{ schema }}' {{ get_query_options() }}
  {%- endcall %}
```

```jinja
{% macro sqlserver__get_relation_last_modified(information_schema, relations) -%}
  {%- call statement('last_modified', fetch_result=True) -%}
        select ...
        from sys.objects o {{ information_schema_hints() }}
        inner join sys.schemas s {{ information_schema_hints() }} on ...
```

`information_schema` is accepted and discarded in both. Every other catalog macro
in the adapter opens with `{{ get_use_database_sql(...) }}` — 26 call sites — and
these two are the exceptions.

## Measured

Two databases, `xdb_a` holding `only_in_a.orders`, `xdb_b` holding nothing of the
sort. Connection attached to `xdb_b`, dbt asking about `xdb_a`:

```
check_schema_exists('xdb_a', 'only_in_a')            -> 0        (truth: 1)
get_relation_last_modified(xdb_a.only_in_a.orders)   -> 0 rows   (truth: 1 row)
```

Then, without changing the question, run the `USE [xdb_a]` that
`sqlserver__create_view_as` or `sqlserver__create_schema` would have emitted:

```
check_schema_exists                                  -> 1
get_relation_last_modified                           -> 1 row
connection left on                                   -> xdb_a
```

The answer flips because of an unrelated statement. Nothing in either macro
changed.

`USE` is sticky in both directions that matter:

- It persists to every later statement on that connection, and dbt reuses one
  connection per thread.
- It survives a rollback. `begin transaction; USE [other]; rollback` leaves the
  connection on `other`.

## Impact

Source freshness is the reachable path. `dbt source freshness` on a source
without `loaded_at_field` goes through `get_relation_last_modified`, and sources
in a second database are a supported, tested configuration —
`tests/functional/adapter/mssql/test_cross_db.py` declares
`sources: - name: mysource / database: TestDB`. Whether the answer is right
depends on which model ran last on that thread, so it is order-dependent and
will not reproduce reliably.

An empty result is read as "no freshness information", not as an error, so this
fails quietly.

## Fix

Add the `USE` the other 26 sites already emit:

```jinja
{% macro sqlserver__check_schema_exists(information_schema, schema) -%}
  {% call statement('check_schema_exists', fetch_result=True, auto_begin=False) -%}
    {{ get_use_database_sql(information_schema.database) }}
    SELECT count(*) as schema_exist FROM sys.schemas WHERE name = '{{ schema }}' {{ get_query_options() }}
  {%- endcall %}
```

and the same in `sqlserver__get_relation_last_modified`.

Three-part qualification (`[db].sys.schemas`) is the alternative, and is what the
v2 port uses, but it is not a migration path for the adapter as a whole:
`CREATE VIEW`, `CREATE PROCEDURE` and `CREATE SCHEMA` reject a database prefix
outright (errors 166 and 102, measured), so `USE` stays load-bearing on those
paths regardless. Adding both mechanisms would be worse than keeping one.

## Audit

Other macros that read `sys.*` or `INFORMATION_SCHEMA.*` without emitting `USE`
themselves — these need checking for whether every caller emits it first, which
the two above do not:

```
adapters/apply_grants.sql    sqlserver__get_show_grant_sql
adapters/apply_masks.sql     sqlserver__get_show_mask_sql
                             sqlserver__get_mask_index_key_columns
                             sqlserver__get_unmaskable_columns
adapters/persist_docs.sql    sqlserver__alter_relation_comment
                             sqlserver__alter_column_comment
utils/                       sqlserver__get_tables_by_pattern_sql
```

The `indexes.sql` and `relations/table/create.sql` helpers in the same shape are
invoked from bodies that do emit `USE`, so they are covered by their callers.

## References

- Cross-database support and its test: `tests/functional/adapter/mssql/test_cross_db.py`
- Found while porting catalog introspection to v2: dbt-sqlserver-next/dbt-core#5
