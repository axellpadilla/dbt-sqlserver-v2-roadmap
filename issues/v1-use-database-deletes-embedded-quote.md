---
target_repo: dbt-msft/dbt-sqlserver
type: bug
status: draft
related: v1-quoting-alignment-with-v2.md
---

# `get_use_database_sql` deletes an embedded `"` instead of escaping it, so `USE` can address a different database than the rest of the run

`sqlserver__get_use_database_sql` strips quote characters from the database name
before handing it to `adapter.quote()`, so that one site bypasses the delimiter
escaping [#795](https://github.com/dbt-msft/dbt-sqlserver/pull/795) added.

Measured against SQL Server 2022 (16.0.4265.3, Linux).

## Summary

`dbt/include/sqlserver/macros/adapters/metadata.sql`:

```jinja
{%- macro sqlserver__get_use_database_sql(database) -%}
  USE {{ adapter.quote(database | replace('"', '')) }};
{%- endmacro -%}
```

The filter runs first, so `adapter.quote()` never sees the character it exists to
escape. For a database named `we"ird`:

| path | emits |
|---|---|
| `SQLServerAdapter.quote` | `"we""ird"` |
| `SQLServerRelation.quoted` / `{{ relation }}` | `"we""ird"` |
| `sqlserver__get_use_database_sql` | `"weird"` |

This is the only remaining `replace('"', '')` under `dbt/include/` and
`dbt/adapters/`.

## Why it is there

It came in with the Fabric port (`19c32a1`), which copied
`fabric__get_use_database_sql` verbatim:

```jinja
USE [{{database | replace('"', '')}}];
```

Inside `[brackets]` a `"` is an ordinary character, so deleting it was already
wrong there, just invisible — the brackets did the quoting either way. #795
(`8d16c6e`) replaced the bracket literal with `adapter.quote()` and added
doubling to both quoting paths, but left the filter in place, which is what turns
it from cosmetic into a behavior difference.

## Measured

SQL Server accepts `"` in a database name. With both `we"ird` and `weird`
present:

```
USE "we""ird";   -> Changed database context to 'we"ird'.
USE "weird";     -> Changed database context to 'weird'.
```

The second is what the macro emits when asked for `we"ird`. There is no error —
the run continues against the wrong database. Every statement that renders
through the relation object still targets `"we""ird"`, so a single dbt run
addresses two databases.

With no database named `weird`:

```
USE "weird";     -> Msg 911: Database 'weird' does not exist.
```

so the second branch is a hard failure naming a database the user never
configured.

## Impact

Low reach. `BaseRelation.database` returns the raw path component, so the value
originates from `profiles.yml` or a `database:` config, and a `"` in a database
name is unusual. It is not unreachable, and the wrong-database branch is silent.

## Fix

Delete the filter:

```jinja
{%- macro sqlserver__get_use_database_sql(database) -%}
  USE {{ adapter.quote(database) }};
{%- endmacro -%}
```

`adapter.quote()` already does the right thing —
`tests/unit/adapters/mssql/test_quote.py::test_quote_escapes_embedded_delimiters`
asserts `ab"cd` renders `"ab""cd"`.

The lint in the same file (`test_macros_do_not_hand_format_identifiers`) catches
hand-formatted brackets but not this, since the identifier does go through
`adapter.quote()`. Adding a `HAND_QUOTING` pattern for a `replace` of a quote
character would close the gap — it is the same class of defect: escaping done in
the macro rather than left to the quoting helper.

## References

- Introduced by `19c32a1`, "Initial work at porting over the macros from fabric"
- Survived `8d16c6e` / [#795](https://github.com/dbt-msft/dbt-sqlserver/pull/795),
  which closed [#785](https://github.com/dbt-msft/dbt-sqlserver/issues/785)
- Escaping rule:
  https://learn.microsoft.com/sql/relational-databases/databases/database-identifiers
- Found while reviewing `get_use_database_sql` call sites for
  `v1-use-database-state-vs-unqualified-catalog-reads.md`
