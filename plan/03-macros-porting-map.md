# 03 — Macro Porting Map (v1 → v2)

Source tree: `dbt-sqlserver/dbt/include/sqlserver/macros/` (34 files).
Destination: `dbt-core/crates/dbt-loader/src/dbt_macro_assets/dbt-sqlserver/macros/`
(exact subdirectory layout TBD — inspect `dbt-fabric/`'s tree first; don't
assume v1's directory structure carries over 1:1).

**Quoting reminder** (full rationale in `05-open-questions-and-risks.md` #1):
v1 macros hand-format `[bracket]`-quoted identifiers throughout (e.g. `USE
[{{ relation.database }}];` in `adapters/schema.sql`,
`relations/table/create.sql`), but v2 is decided as `"double quotes"`
(`quote_char = '"'`) with `SET QUOTED_IDENTIFIER ON` enforced at
connection-init. **Every `[...]` literal below must be rewritten to
double-quote form during porting, not copied verbatim** — preferably by
routing the identifier through the adapter's standard relation-rendering
path instead of hand-formatting it, so quoting stays centralized. Cross-check
against how `Fabric`'s existing v2 macros already render quoted identifiers.

## Required core macros (guide's mandatory list)

| Required macro | v1 source file | Notes |
|---|---|---|
| `create_schema` | `adapters/schema.sql` (`sqlserver__create_schema`, `..._with_authorization`) | Uses `USE [db]` + `sys.schemas` existence check |
| `drop_schema` | `adapters/schema.sql` | |
| `drop_relation` | `adapters/relation.sql` (`sqlserver__get_drop_sql`) | Handles view-reference lookup before drop |
| `rename_relation` | `adapters/relation.sql` | |
| `truncate_relation` | `adapters/relation.sql` | |
| `create_table_as` | `relations/table/create.sql` (`sqlserver__create_table_as`) | Non-trivial: builds a temp view first. Port only the `heap_then_index` (default) path — the `full_refresh_build: prebuilt` optimization is **deferred** per `05-open-questions-and-risks.md` #4 |
| `create_view_as` | `relations/views/create.sql` | |
| `list_schemas` | `adapters/metadata.sql` (verify exact macro name) | Cross-check against `crates/dbt-adapter/src/metadata/sqlserver/mod.rs` (Rust) — v2 often does catalog listing in Rust, not Jinja; don't duplicate logic in both places |
| `check_schema_exists` | `adapters/schema.sql` or `metadata.sql` | |
| `information_schema_name` | `adapters/metadata.sql` | SQL Server: typically `INFORMATION_SCHEMA` per-database, unlike Exasol's `sys` — verify exact v1 value |
| `current_timestamp` | `utils/timestamps.sql` | T-SQL: `GETDATE()` / `SYSDATETIME()` — check v1's exact choice |
| `get_columns_in_relation` | `adapters/columns.sql` | |
| `list_relations_without_caching` | `adapters/show.sql` or `metadata.sql` | |

## Full v1 file inventory → v2 disposition

| v1 file | v2 disposition |
|---|---|
| `adapters/apply_grants.sql` | Port if grants support is in scope for initial PR (check `adapter_impl.rs` `grant_access_to`/`standardize_grants_dict` Fabric arms first — Rust side may already assume a certain macro contract) |
| `adapters/apply_masks.sql` | **Skip — deferred** (`05-open-questions-and-risks.md` #4). SQL Server-specific dynamic data masking feature, out of scope for the initial PR; track as a follow-up issue once merged |
| `adapters/catalog.sql` | Cross-check against new `crates/dbt-adapter/src/metadata/sqlserver/mod.rs` (Rust) — v2 moves most catalog querying to Rust; only port the parts still expected to live in Jinja (check what `Fabric`'s macros vs. Rust module each own) |
| `adapters/columns.sql` | Port — `get_columns_in_relation`, empty-subquery CTE handling |
| `adapters/indexes.sql` | **Skip — deferred** (`05-open-questions-and-risks.md` #4). Index/columnstore materialization config is out of scope for the initial PR |
| `adapters/metadata.sql` | Port — schema listing, `information_schema_name` |
| `adapters/persist_docs.sql` | Port if column/relation comment support is in scope — `dbt-fabric` already has a `persist_docs.sql` in v2 (`crates/dbt-loader/src/dbt_macro_assets/dbt-fabric/macros/adapters/persist_docs.sql`) — use as direct template |
| `adapters/relation.sql` | Port — drop/rename/temp-relation macros |
| `adapters/schema.sql` | Port — create/drop schema |
| `adapters/show.sql` | Port — `list_relations_without_caching` and similar |
| `adapters/validate_sql.sql` | Port — likely used for `dbt compile`/dry-run validation |
| `materializations/functions/helpers.sql` | **Skip — deferred** (`05-open-questions-and-risks.md` #4). Scalar function materializations out of scope for the initial PR |
| `materializations/functions/scalar.sql` | **Skip — deferred**, same as above |
| `materializations/hooks.sql` | Port — pre/post-hook handling, likely thin |
| `materializations/models/incremental/incremental.sql` | Port — core incremental materialization control flow; diff carefully against v2's shared/default incremental macro to avoid duplicating logic the v2 task runner already provides |
| `materializations/models/incremental/incremental_strategies.sql` | Port — maps to the `valid_incremental_strategies` Rust arm (`adapter_impl.rs:534`); Fabric supports `Append, DeleteInsert, Merge, Microbatch` and v1 SQL Server matches this set |
| `materializations/models/incremental/merge.sql` | Port — `get_merge_sql`, `get_delete_insert_merge_sql`, `get_insert_overwrite_merge_sql`; note `get_query_options(parse_options=True)` calls — verify this helper still exists/means the same thing in v2 |
| `materializations/models/table/columns_spec_ddl.sql` | Port — explicit column DDL generation for `contract` enforcement |
| `materializations/models/table/table_dml_refresh.sql` | **Skip — deferred** (`05-open-questions-and-risks.md` #4). Only needed for the `full_refresh_build: prebuilt` optimization path, which is out of scope for the initial PR |
| `materializations/models/table/table.sql` | Port — full table materialization control flow; heavy use of `load_cached_relation`, `make_intermediate_relation`, `make_backup_relation` — verify these helper macros exist unchanged in v2 |
| `materializations/models/unit_test/get_fixture_sql.sql` | Port — needed for `dbt test`/unit test support |
| `materializations/models/unit_test/unit_test_create_table_as.sql` | Port, same as above |
| `materializations/models/view/create_view_as.sql` | Port |
| `materializations/models/view/view.sql` | Port — view materialization control flow |
| `materializations/snapshots/helpers.sql` | Port if snapshots are in initial scope (recommended — `Fabric` already has `snapshot.sql` in v2) |
| `materializations/snapshots/snapshot_merge.sql` | Port with snapshots |
| `materializations/snapshots/snapshot.sql` | Port — compare against `crates/dbt-loader/src/dbt_macro_assets/dbt-fabric/macros/materializations/snapshots/snapshot.sql`, which already exists in v2 and is T-SQL |
| `materializations/snapshots/strategies.sql` | Port with snapshots — timestamp/check strategies |
| `materializations/tests.sql` | Port — generic/singular test SQL wrapper, likely thin/mostly default |
| `materializations/unit_tests.sql` | Port, thin wrapper likely |
| `relations/seeds/helpers.sql` | Port — seed loading; check whether v2 has moved seed CSV loading into `dbt-df-providers`/Rust (there's a `seed_io.rs` referencing SQL Server-family adapters already — see `00-current-state.md`) before porting the Jinja version wholesale |
| `relations/table/clone.sql` | **Skip — deferred** (`05-open-questions-and-risks.md` #4). `dbt clone` / zero-copy clone support out of scope for the initial PR (SQL Server has no true zero-copy clone like Snowflake anyway — v1's implementation is likely `CREATE TABLE ... AS SELECT`-based) |
| `relations/table/create.sql` | Port — see notes above; only the `heap_then_index` (default) path, not `prebuilt` |
| `relations/views/create.sql` | Port |
| `utils/any_value.sql` | Port — dbt utils cross-db macro |
| `utils/array_construct.sql` | Port only if array-like construct is needed; SQL Server has no native ARRAY type (matches `sql_types.rs`'s existing "ARRAY not supported" error for Fabric) — check what v1 actually does here (likely a string-concat emulation) |
| `utils/cast_bool_to_text.sql` | Port |
| `utils/concat.sql` | Port — T-SQL `+` concatenation |
| `utils/dateadd.sql` | Port — `DATEADD()` |
| `utils/date_trunc.sql` | Port |
| `utils/get_tables_by_pattern.sql` | Port |
| `utils/hash.sql` | Port — likely `HASHBYTES('MD5', ...)` |
| `utils/last_day.sql` | Port |
| `utils/length.sql` | Port — `LEN()` |
| `utils/listagg.sql` | Port — `STRING_AGG()` (SQL Server 2017+) — note minimum SQL Server version implications, document as a prerequisite/limitation |
| `utils/position.sql` | Port — `CHARINDEX()` |
| `utils/safe_cast.sql` | Port — `TRY_CAST()` |
| `utils/split_part.sql` | Port |
| `utils/timestamps.sql` | Port — `current_timestamp` required macro lives here |

## Porting method

1. Read `dbt-fabric/`'s equivalent macro (if it exists) first — it already
   compiles against v2's task runner/materialization contract and is the
   closest working T-SQL example.
2. Port the v1 SQL Server macro body only where it differs meaningfully from
   Fabric (classic SQL Server DDL, `IDENTITY`, index/columnstore syntax,
   version-gated functions like `STRING_AGG`).
3. Where v1 and Fabric agree, prefer delegating to the `fabric__` macro
   (`{{ return(fabric__x(...)) }}`) over copy-pasting, per the guide's
   delegation pattern — but only if Fabric's version is confirmed
   semantically identical for SQL Server (not just similar-looking).
4. Flag any v1 macro that calls a helper (`get_query_options`,
   `load_cached_relation`, `make_intermediate_relation`,
   `make_backup_relation`, `get_use_database_sql`) whose v2 existence/behavior
   you haven't confirmed — verify each exists in v2's shared macro set before
   assuming it's still available; these are used pervasively across the table/
   incremental/view materializations above.
