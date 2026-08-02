---
target_repo: dbt-msft/dbt-sqlserver
type: bug
status: draft
related: ../plan/02-implementation-steps.md
---

# `MAX_CHARACTERS_IN_IDENTIFIER` is 127, which is Redshift's limit — SQL Server accepts 128

The adapter rejects relation names of exactly 128 characters that SQL Server
creates without complaint. Both halves are measured against a live server
(SQL Server 2022 Developer Edition, 16.0.4265.3, Linux), not taken from
documentation.

## Summary

`dbt/adapters/sqlserver/relation_configs/policies.py` defines:

```python
MAX_CHARACTERS_IN_IDENTIFIER = 127
```

In `sqlserver_relation.py`, `SQLServerRelation.__post_init__` raises
`DbtRuntimeError` above it, and `relation_max_name_length()` returns it to
Jinja. SQL Server's limit for a regular identifier is 128 — identifiers are
`sysname`, which is `nvarchar(128)`.

127 is Redshift's limit, and this is scaffolding rather than a decision:

- `dbt-labs/dbt-adapters` has
  `dbt-redshift/src/dbt/adapters/redshift/relation_configs/policies.py`
  containing `MAX_CHARACTERS_IN_IDENTIFIER = 127` — same path, same constant,
  same value.
- The constant, the raise, and `relation_max_name_length()` all arrive in one
  commit, `a204adb` ("Updated to 1.8 and rebuilt test suite", 2024-08-21),
  which created `relation_configs/` and `sqlserver_relation.py` wholesale.
- The comment above the check still reads
  `# Check for length of Redshift table/view names`
  (`SQLServerRelation.__post_init__`).
- No issue or PR on this tracker discusses identifier length.

## What the server does

```sql
SELECT max_length/2 FROM sys.types WHERE name = 'sysname';   -- 128
```

Creating a table with a 128-character name succeeds, bracket-quoted and
double-quoted alike. 129 fails:

```
Msg 103 - The identifier that starts with 'hhhh...' is too long.
          Maximum length is 128.
```

Same boundary for 128-character column names and schema names — both created.

Local temporary tables are the one exception, and the limit there is not 128
either: `#` + 115 characters (116 total) succeeds, 117 total fails with

```
Msg 193 - The object or column name starting with '#ffff...' is too long.
          The maximum length is 116 characters.
```

That doesn't affect this constant, because `sqlserver__make_temp_relation`
builds a regular table with a `__dbt_temp` suffix rather than a `#` temp
table. It does mean a long model name fails at temp-relation construction
before it reaches the server: a 118-character model plus `__dbt_temp` is
exactly 128, so 118 is the effective cap for anything incremental, whatever
this constant says.

Not measured: Azure SQL and Fabric. Both document the same 128, but this was
validated on SQL Server 2022 only.

## What the adapter does

```python
>>> SQLServerRelation.create(database="d", schema="s", identifier="a"*127, type="table")
accepted
>>> SQLServerRelation.create(database="d", schema="s", identifier="a"*128, type="table")
DbtRuntimeError: Relation name 'aaa…' is longer than 127 characters
>>> SQLServerRelation.create(database="d", schema="s", identifier="a"*129, type="table")
DbtRuntimeError: Relation name 'aaa…' is longer than 127 characters
```

So exactly one name length is affected — 128 — and it fails at parse time,
never reaching the database.

`relation_max_name_length()` is also what dbt's own truncation logic and
packages such as `dbt_utils` consult, so the off-by-one shortens generated
names by one character too.

There is no test covering the boundary: `grep -rl
"MAX_CHARACTERS_IN_IDENTIFIER" tests/` is empty.

## Implementation

1. `MAX_CHARACTERS_IN_IDENTIFIER = 128` in
   `dbt/adapters/sqlserver/relation_configs/policies.py`, with a comment
   citing `sysname`/`nvarchar(128)` instead of inheriting Redshift's.
2. Replace the `# Check for length of Redshift table/view names` comment in
   `SQLServerRelation.__post_init__` — it is wrong regardless of the value.
3. Add a boundary test: 128 accepted, 129 rejected. There is no existing test
   file for this; `tests/unit/adapters/mssql/test_quote.py` (added by
   [#795](https://github.com/dbt-msft/dbt-sqlserver/pull/795)) is the closest
   neighbour for placement.

Optional, and a separate call: `sqlserver__make_temp_relation` silently
produces an over-limit identifier for models longer than 118 characters. The
`__post_init__` check catches it, but the error names the temp relation rather
than the model, which is confusing. Worth its own issue rather than bundling.

## Why this matters for the v2 port

`dbt-adapter-sql`'s `max_identifier_length` needs a `SqlServer` arm
(`../plan/02-implementation-steps.md` §5.1), and it took 128 on the evidence
above. Until v1 moves, a 128-character relation name errors under v1 and
builds under v2.

## References

- v1: `dbt/adapters/sqlserver/relation_configs/policies.py`
  `MAX_CHARACTERS_IN_IDENTIFIER`, `dbt/adapters/sqlserver/sqlserver_relation.py`
  `SQLServerRelation.__post_init__` / `relation_max_name_length` (v1.12.0rc2)
- Origin commit: `a204adb`
- Redshift's constant:
  `dbt-labs/dbt-adapters` → `dbt-redshift/src/dbt/adapters/redshift/relation_configs/policies.py`
- https://learn.microsoft.com/en-us/sql/relational-databases/databases/database-identifiers
