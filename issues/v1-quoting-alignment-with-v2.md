---
target_repo: dbt-msft/dbt-sqlserver
type: bug
status: open
url: https://github.com/dbt-msft/dbt-sqlserver/issues/785
related: ../plan/05-open-questions-and-risks.md
---

# Inconsistent identifier quoting: a few macros hand-format `[brackets]` while relation rendering already uses `"double quotes"`

## Summary

`SQLServerRelation`/`SQLServerAdapter` don't override `quote_character` or `quote()` anywhere, so `{{ relation }}` — the rendering path used by nearly all generated DDL/DML — already emits ANSI `"double quoted"` identifiers via dbt-core's default. A small number of macros don't go through that path: they hand-format identifiers as raw `[bracket]`-quoted strings instead, producing SQL that mixes both styles in the same statement.

Concrete example, `dbt/include/sqlserver/macros/relations/table/create.sql`:

```jinja
{%- set table_name -%}
    {{ relation }}
{%- endset -%}
...
CREATE TABLE {{table_name}}   {# double-quoted, via relation rendering #}
...
USE [{{ relation.database }}];   {# bracket-quoted, hand-formatted #}
```

This issue proposes making the hand-formatted spots consistent with what the rest of the generated SQL already does, rather than leaving both styles in circulation.

## Why this matters beyond v1: the dbt Core v2.0 (Fusion) port

There's a community effort underway to add SQL Server support to dbt Core v2.0 (the Rust/"Fusion" engine) — see the [roadmap repo](https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap) for the full plan. v2 already standardizes on double-quote identifiers for SQL Server's T-SQL sibling, Microsoft Fabric (`AdapterType::Fabric => '"'` in `crates/dbt-adapter-core/src/lib.rs`), and the SQL Server plan follows the same convention (`AdapterType::SqlServer => '"'` — see the roadmap's [`plan/05-open-questions-and-risks.md` #1](https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap/blob/main/plan/05-open-questions-and-risks.md)). That decision was made independently of this issue — it's just what fits v2's `quote_char() -> char` API — but it turns out to already match what `{{ relation }}` renders in v1 today, for the reason described above.

That match matters for the port itself. v2's macro-porting approach (see the roadmap's [`plan/03-macros-porting-map.md`](https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap/blob/main/plan/03-macros-porting-map.md)) is: read v1's macro, port its body, and rewrite anything that doesn't match v2's conventions. Every hand-formatted `[bracket]` literal in v1 is exactly that kind of rewrite — one that has to happen *during* the port, macro by macro, easy to miss, and easy to get subtly wrong under time pressure. Fixing it here first means:

- The port copies macro bodies that already match the target quoting convention, instead of needing a quoting rewrite bundled into the port itself.
- v1 and v2 stay aligned in how they render identifiers, so contributors (and users comparing generated SQL between versions) aren't reconciling two different, undocumented quoting conventions.
- The regression check proposed below (§ Proposed change, item 3) protects both: it stops new bracket-formatted macros from landing in v1, and it's the same invariant the v2 port needs to hold once macros land there.

Filed here rather than handled silently inside the v2 port, since fixing the inconsistency at the source benefits both versions.

## Scope (verified against current `dbt/include/sqlserver/macros/`)

9 files hand-format bracket-quoted identifiers, ~20 occurrences total, falling into three repeated patterns:

| Pattern | Files |
|---|---|
| `USE [{{ relation.database }}];` / `USE [{{ target.database }}];` | `adapters/schema.sql`, `adapters/indexes.sql` (x2), `adapters/metadata.sql`, `relations/table/create.sql` (x2), `relations/views/create.sql`, `materializations/tests.sql`, `materializations/unit_tests.sql` |
| `EXEC('CREATE SCHEMA [{{ ... }}]')` | `adapters/schema.sql` (x2), `materializations/tests.sql`, `materializations/unit_tests.sql` |
| `{{ "["~column~"]" }}` (contract-enforced column list) | `relations/table/create.sql` (x2), `materializations/models/unit_test/unit_test_create_table_as.sql` |
| Misc: grantee names, index/constraint names, generated test view names | `adapters/apply_grants.sql`, `adapters/indexes.sql` |

(Files matching a literal `[` that are **not** identifier quoting — e.g. `utils/split_part.sql`'s XQuery `[position()...]`, Jinja list indexing like `fields[0]` — are excluded from this list; grepping for `[` alone over-counts.)

## `SET QUOTED_IDENTIFIER` — already satisfied for existing backends

Per Microsoft's docs on [`SET QUOTED_IDENTIFIER`](https://learn.microsoft.com/en-us/sql/t-sql/statements/set-quoted-identifier-transact-sql):

> The SQL Server Native Client ODBC driver and SQL Server Native Client OLE
> DB Provider for SQL Server automatically set `QUOTED_IDENTIFIER` to `ON`
> when connecting.

Both existing backends (`pyodbc`, `mssql-python`) connect via ODBC, so double-quoted identifiers already work correctly wherever the adapter uses them. The **experimental ADBC backend** (`go-mssqldb`, not ODBC — PR #783) needs an explicit check: confirm whether it sets `QUOTED_IDENTIFIER ON` by default, and if not, add it via `build_adbc_connection_uri` or a connection-init statement.

## Proposed change

1. Confirm `QUOTED_IDENTIFIER` behavior for the ADBC backend specifically (see above); add an explicit `SET QUOTED_IDENTIFIER ON` there if it's not already the driver default.
2. Replace the hand-formatted `[bracket]` literals in the files listed above with double-quote equivalents — or better, route them through the relation object / `adapter.quote()` instead of string-formatting identifiers directly, so this class of drift can't reappear.
3. Add a regression check (a simple test asserting no macro output contains a literal `[` identifier delimiter, or a grep-based lint) so new macros don't reintroduce bracket-formatted identifiers.

## Backwards compatibility

Narrower than "quoting migration" framing suggests, since it only touches already-inconsistent spots: `USE` statements, `CREATE SCHEMA` statements, generated column lists in contract-enforced `CREATE TABLE`, grantee names in `apply_grants.sql`, and index/constraint/test-view names in `indexes.sql`. Anyone parsing dbt's generated SQL/logs, or with custom macros that assume bracket formatting specifically in these spots, would see a behavior change. Recommend a changelog entry either way, even though it's a consistency fix rather than a new capability.

## References

- v1 code: `dbt/adapters/sqlserver/sqlserver_relation.py` (no `quote_character`/`quote()` override — confirms default double-quote rendering), and the files listed in Scope above
- `SET QUOTED_IDENTIFIER` docs (quoted above): https://learn.microsoft.com/en-us/sql/t-sql/statements/set-quoted-identifier-transact-sql
- ADBC backend (PR #783): `dbt/adapters/sqlserver/sqlserver_backend.py` (`build_adbc_connection_uri`)
- dbt Core v2.0 SQL Server port roadmap: https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap — see `plan/05-open-questions-and-risks.md` #1 (quoting decision) and `plan/03-macros-porting-map.md` (macro-porting approach referenced above)
- v2 quoting precedent: `crates/dbt-adapter-core/src/lib.rs` (`quote_char`, `AdapterType::Fabric => '"'`) in `dbt-labs/dbt-core`
