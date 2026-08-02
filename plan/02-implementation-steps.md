# 02 — Implementation Steps (file-by-file checklist)

Source guide: https://docs.getdbt.com/guides/adapter-creation-v2 (Step 5).
All paths are relative to `dbt-core/`. After every sub-step run
`cargo build -p <crate>` per `01-architecture-and-prerequisites.md`.

Checkbox legend: `[ ]` not started, `[~]` partially done already in this repo,
`[x]` already done in this repo (verify, don't redo).

---

## 5.1 — Register the adapter type

**Crates:** `dbt-adapter-core` — `crates/dbt-adapter-core/src/lib.rs`;
`dbt-adapter-sql` — `src/ident.rs`, `src/statements.rs`

- `[ ]` Add `SqlServer` to the `AdapterType` enum (next to `Fabric`).
- `[ ]` Add a `quote_char` arm: `SqlServer => '"'` (`05` #1), matching
  `Fabric`'s and v1's own rendering, with `SET QUOTED_IDENTIFIER ON` as
  connection-init SQL (§5.4). The arm isn't the whole decision — see the
  escaping check in §5.5.
- `[ ]` Update the three variant-enumerating tests in the same file:
  `test_from_str`, `test_iter_with_names`, `test_quote_char_by_adapter`.
  `test_iter_with_names` is what pins the strum rendering to `sqlserver`,
  the name §5.6's macro package resolves from.
- `[ ]` `dbt-adapter-sql` is the next crate the new variant breaks, before
  `dbt-schemas`, so its three arms belong in this step — otherwise §5.3 and
  §5.4 can't build their own crates:
  - `ident.rs` `max_identifier_length` — `Some(128)`, SQL Server's
    documented limit for a regular identifier (`sysname` is `nvarchar(128)`).
    v1 enforces 127, but that constant is a copy of dbt-redshift's
    `relation_configs/policies.py` (same filename, same constant, same value)
    introduced with its `# Check for length of Redshift table/view names`
    comment intact in `a204adb`, with no SQL Server rationale anywhere in v1's
    history or tracker. Following the database means a 128-character relation
    name errors in v1 and builds in v2. Measured on SQL Server 2022: 128
    creates, 129 fails with `Msg 103 ... Maximum length is 128`, and the
    adapter rejects 128 with its own error.
    `../issues/v1-identifier-length-127-vs-128.md` carries the measurements
    and proposes closing the split on the v1 side.
  - `ident.rs` `is_valid_ident_char` — join `Fabric`'s group.
  - `statements.rs` `is_update_statement` — join the `false` group.
  - `ident.rs` `canonical_quote` needs nothing: its `_` arm already
    yields `QuotingStyle::Double`. Name `SqlServer` alongside `Fabric` anyway
    so the choice is visible rather than incidental.
- `[ ]` Run `cargo build -p dbt-adapter-core -p dbt-adapter-sql`. Both should
  be clean; the workspace then stops at one `E0004` in
  `dbt-schemas/src/schemas/relations/base.rs`, which is §5.3's crate.

## 5.2 — ADBC driver registration

**Crate:** `dbt-adbc` (guide calls it `dbt-xdbc`) — `crates/dbt-adbc/src/driver.rs`, `src/install.rs`

- `[x]` `Backend::SQLServer` variant exists.
- `[x]` ADBC library name `adbc_driver_mssql` registered.
- `[x]` CDN download URL/version registered (`install.rs`), including macOS
  x86_64 special-casing.
- `[ ]` **Verify only**: confirm no additional Arrow type mapping is needed for
  SQL Server-specific types (`uniqueidentifier`, `datetime2`, `sql_variant`,
  `xml`, `hierarchyid`) — the guide notes this is only needed "if your driver
  returns types that Arrow's standard schema doesn't cover." Cross-check
  against what `adbc_driver_mssql` actually returns once you can run a live
  query (Step 6 smoke test) — don't guess this ahead of time.

## 5.3 — Connection profile config

**Crate:** `dbt-schemas` — `crates/dbt-schemas/src/schemas/profiles.rs`

- `[ ]` Define `SqlServerDbConfig` struct. Cross-reference three sources for
  the field list:
  1. `FabricDbConfig` in the same file (closest existing v2 struct — same
     T-SQL/Entra-auth shape).
  2. What `crates/dbt-auth/src/sqlserver/mod.rs` actually reads via
     `config.get_str(...)` / `config.require_str(...)`: `authentication`,
     `host`, `port`, `database`, `tenant_id`, `client_id`, `client_secret`,
     `UID`, `PWD`. This is the authoritative minimal field set today.
  3. v1 `dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_credentials.py` for
     fields v1 users expect (schema, additional SQL-auth fields, encrypt,
     trust_cert, login_timeout, etc.) that aren't in the v2 auth module yet.
- `[ ]` Include plain SQL auth fields (`user`/`UID`, `password`/`PWD`, without
  the Entra `tenant_id`/`client_id`/`client_secret`) in `SqlServerDbConfig` —
  in scope for the initial PR (`05` #2). Leave out `trusted_connection`; that
  auth mode is deferred.
- `[ ]` Uncomment and fix the `// SqlServer,` placeholder in the `DbConfig`
  enum → `SqlServer(Box<SqlServerDbConfig>)`.
- `[ ]` Add `SqlServer` to `render_with_run_filter` in
  `crates/dbt-schemas/src/schemas/relations/base.rs`, joining the
  `Postgres | Databricks | Redshift | Salesforce | Spark | DuckDB | Alt |
  Fabric` group. This is the microbatch event-time filter predicate, unrelated
  to `SqlServerDbConfig` but the one `E0004` this crate carries after §5.1,
  so it lands here rather than blocking §5.4.
- `[ ]` `cargo build -p dbt-schemas` and follow every resulting error — the
  compiler will point at every place that reads `DbConfig` and needs a new
  `SqlServer` case (per the guide's stated behavior for this step).

## 5.3.1 — `dbt init` profile generation (optional, recommended)

**Crate:** `dbt-init` — `crates/dbt-init/`

- `[ ]` Add `AdapterType::SqlServer` to `get_available_adapters()` in
  `src/profile_setup.rs`.
- `[ ]` Create `src/adapter_config/sqlserver_config.rs` implementing
  `InteractiveSetup` for `SqlServerDbConfig`. Use
  `src/adapter_config/fabric_config.rs` as the template (same auth surface
  shape) and `postgres_config.rs` per the guide's "minimal reference" note.
- `[ ]` Export from `src/adapter_config/mod.rs`.
- `[ ]` Add match arm in `create_profile_for_adapter()` in `profile_setup.rs`.
- Defer this sub-step if time-constrained — it's explicitly optional in the
  guide and doesn't block `dbt build` from working via a hand-written
  `profiles.yml`.

## 5.4 — Authentication

**Crate:** `dbt-auth` — `crates/dbt-auth/src/sqlserver/`

- `[x]` `mod.rs` exists with `ActiveDirectoryServicePrincipal`,
  `ActiveDirectoryPassword`, `environment` auth flows, unit-tested.
- `[x]` Dispatch wired in `src/lib.rs` `auth_for_backend`.
- `[ ]` Add plain SQL authentication — native SQL Server login, username and
  password, no Entra/`fedauth` param (`05` #2). A new `SQLServerAuthIR` variant
  plus a `parse_auth` branch for `authentication: sql`; confirm the value name
  against `sqlserver_credentials.py`/`sqlserver_auth.py` rather than inventing
  one. Unlike the Entra variants it maps straight to the URI's userinfo
  (`user:password@host`), as v1's ADBC backend does
  (`sqlserver_backend.py` `build_adbc_connection_uri`). Add a unit test
  alongside the existing ones.
- `[ ]` Leave Windows/trusted-connection auth out (`05` #2) — it only matters
  when dbt itself runs on a domain-joined Windows host. Keep the existing
  `unimplemented!()` stub for `ActiveDirectoryIntegrated` as-is; don't add a
  `trusted_connection` config field.
- `[ ]` Fill in the `// TODO` params in `apply_connection_args`
  (`crates/dbt-auth/src/sqlserver/mod.rs`): `encrypt`/TLS trust settings,
  connection timeout, app name. Without the TLS settings, connections to
  on-prem instances with self-signed certificates fail validation.

  Port these from `sqlserver_backend.py` `build_adbc_connection_uri` rather
  than re-deriving them from the `go-mssqldb` docs — v1 builds the
  identical query string (`encrypt`, `TrustServerCertificate`,
  `connection timeout`) against the same driver
  ([PR #783](https://github.com/dbt-msft/dbt-sqlserver/pull/783)). Field
  defaults are on `SQLServerCredentials`: `encrypt=True`,
  `trust_cert=False`, `login_timeout=0` (omit the param when `<= 0`). Two more
  gaps visible in the same comparison: named-instance handling (host containing
  `\\`, port omitted) and URL-encoding of user/password, neither of which v2's
  `apply_connection_args` does.
  Reference: https://github.com/microsoft/go-mssqldb#connection-parameters-and-dsn
- `[ ]` `src/init.rs` — issue `SET QUOTED_IDENTIFIER ON` on every connection
  open. Required by the quoting decision in 5.1: server, login and database
  defaults can force it `OFF` via legacy compatibility settings, and on such a
  session every double-quoted identifier the adapter emits either errors or
  parses as a string literal (v1 measured `USE "db"` as a hard `Msg 102`).
  This is insurance against a misconfigured server rather than the common
  case — v1 verified `sessionproperty('QUOTED_IDENTIFIER') = 1` by default on
  `go-mssqldb`, `pyodbc` and `mssql-python`
  ([PR #795](https://github.com/dbt-msft/dbt-sqlserver/pull/795)).

  Also evaluate `SET ANSI_NULLS ON` (its standard companion; indexed views and
  computed-column indexes need both) and `SET XACT_ABORT ON`, the one
  session-level `SET` v1 issues on connect
  (`sqlserver_connections.py` `_apply_session_settings`), which makes a
  run-time error mid-batch roll back instead of half-applying.

## 5.5 — Adapter layer (largest step)

**Crate:** `dbt-adapter` — `crates/dbt-adapter/src/`

Simple-vs-complex call: SQL Server uses standard `database.schema.table`
3-part naming like `Fabric` — **treat it as a simple adapter**, adding arms to
shared files rather than a dedicated subdirectory (per the guide's "Simple vs.
Complex Adapters" split, where Snowflake/BigQuery get subdirectories and most
others don't).

### Relation type & quoting — `src/relation/relation_impl.rs`

Every match in this file has a `_` arm, so none of the work below produces a
compile error once 5.1 lands. The compiler enumerates `adapter_impl.rs`,
`sql_types.rs` and the rest of 5.5; here it stays silent, and a missing arm
shows up as wrong SQL rather than a build failure. Work the list rather than
`cargo build` output.

- `[ ]` Add `SqlServer` to `get_database`, joining the existing
  `Databricks | Fabric | Postgres | Redshift | Salesforce | Bigquery` group.
  That group raises `InvalidConfig` when `database` is unset; the `_` arm
  returns an empty string, so without the arm a relation missing a database
  renders as `.schema.table` instead of erroring.
- `[ ]` Leave `include_policy` alone — its `_ => Policy::trues()`
  is already correct for SQL Server's 3-part naming, and the explicit arms
  there are all for adapters that drop a path part.
- `[ ]` Check whether the shared rendering path **escapes an embedded delimiter**
  (`ab"cd` → `"ab""cd"`). If it interpolates verbatim, a SQL Server name
  containing a `"` breaks or injects, and v2 would reject names v1 accepts —
  v1 fixed exactly this in `SQLServerAdapter.quote()`/`SQLServerRelation.quoted()`
  (`05-open-questions-and-risks.md` #1). Decide whether to fix it in the shared
  impl (affects other adapters) or take a separate `SqlServer` arm.
- `[ ]` Add `SqlServer` alongside `Fabric` in `get_canonical_fqn`'s three
  db/schema/identifier arms, which case-fold an unquoted path part.
  `Fabric | Bigquery` pass it through verbatim; the `_` arm lowercases. SQL
  Server preserves the case it was given, so it belongs with `Fabric`.
- `[ ]` Add a `SqlServer` constructor mirroring `new_fabric`
  (`Self::new(AdapterType::Fabric, database, schema, identifier)`).

### Relation factory — `src/relation/factory.rs`

- `[ ]` Add `SqlServer` to the `create_static_relation` match, alongside
  `Fabric`.

### SQL type mapping — `src/sql_types.rs`

- `[ ]` Add `SqlServer` arms wherever `Fabric` appears — 16 mentions today,
  so `rg '\bFabric\b' crates/dbt-adapter/src/sql_types.rs` is the work list.
  Confirm each value against
  actual SQL Server T-SQL types, not assumed identical to Fabric — Fabric
  Warehouse has real T-SQL surface differences (e.g. Fabric disallows some
  legacy types, has different max VARCHAR/row-size limits than on-prem SQL
  Server's 8060-byte page limit vs the 8000-byte `FABRIC_MAX_VARCHAR_TYPE` in
  `mod fabric` — verify against SQL Server's actual limits rather than
  copying).
  **Match v1's current mappings, not its legacy ones**: as of 1.12.0
  `dbt_sqlserver_use_native_string_types` defaults `True`, so `STRING` →
  `VARCHAR(MAX)`, `NVARCHAR` → `NVARCHAR(4000)`, `NCHAR` → `NCHAR(1)`. The
  `VARCHAR(8000)`/`CHAR(1)` mappings still in `sqlserver_column.py`'s legacy
  table are deprecated in v1 and should not be ported.
- `[x]` **Already answered** — the metadata type key lives in
  `crates/dbt-adapter-sql/src/types/mod.rs`, and v2 already defines
  `const SQLSERVER_KEYS: [&str; 2] = ["SQLSERVER:type", "type_text"]`, which
  `AdapterType::Fabric` maps to in `metadata_type_candidate_keys`. Fabric
  reaches it because it rides the same `adbc_driver_mssql`/`go-mssqldb`
  driver that emits
  `SQLSERVER:type` in the Arrow field metadata. So the SqlServer arm is
  `AdapterType::SqlServer => &SQLSERVER_KEYS` — nothing to derive from your
  catalog queries, and note it's in `dbt-adapter-sql`, not `dbt-adapter`.
- `[ ]` Reuse the two error arms for unsupported INTERVAL and ARRAY types in
  `mod fabric`'s `try_format_type`. SQL Server lacks both natively, so only
  the wording needs adjusting.

### Column builder — `src/column/column_builder.rs`

- `[ ]` Add `SqlServer` arm to `ColumnBuilder::build`. Try
  `Self::build_postgres_like(...)`
  first (per the guide's default recommendation for adapters without unusual
  type handling); if SQL Server-specific type quirks surface during smoke
  testing, add a dedicated `build_sqlserver` following the `build_fabric`
  pattern instead.

### Catalog introspection — `src/metadata/get_relation.rs` + `src/metadata/sqlserver/mod.rs` (new)

- `[ ]` Add an `AdapterType::SqlServer => sqlserver_get_relation(...)` arm to
  `get_relation`, alongside the existing `Fabric` arm.
- `[ ]` Create `src/metadata/sqlserver/mod.rs`, modeled on
  `src/metadata/fabric/mod.rs` (346 lines — full catalog introspection).
  Cross-check queries against v1's
  `dbt-sqlserver/dbt/include/sqlserver/macros/adapters/catalog.sql` and
  `metadata.sql` for anything Fabric's catalog module doesn't need but classic
  SQL Server does (e.g. index metadata via `sys.indexes`/`sys.index_columns`,
  used by v1's `indexes.sql` and `relation_configs/`).

### Adapter behavior match arms — `src/adapter/adapter_impl.rs`

44 `Fabric` occurrences across ~15 functions today; expect a comparable number
of new `SqlServer` arms once the compiler enumerates them post-5.1. Known
ones from the current `Fabric` arms to triage:

- `[ ]` `valid_incremental_strategies`: Fabric supports `&[Append,
  DeleteInsert, Merge, Microbatch]`. v1 SQL Server supports the same set per
  `dbt-sqlserver/.../incremental_strategies.sql` — **likely a direct copy**.
- `[ ]` `list_schemas_inner` schema column name: Fabric uses
  `"schema"` — verify SQL Server's `INFORMATION_SCHEMA.SCHEMATA` column naming
  matches (it should, since both use SQL Server's information schema).
- `[ ]` `get_adbc_execute_options`: check what Fabric sets here
  (execution options passed to ADBC) and whether SQL Server needs the same or
  different options.
- `[ ]` `get_constraint_support`, `alter_table_add_columns`, `is_replaceable`,
  `truncate_relation`, grants (`grant_access_to`, `standardize_grants_dict`),
  masking (`apply_masks.sql` in v1 — decide if data masking is in scope),
  `describe_dynamic_table` (likely N/A — dynamic tables may be Fabric/Snowflake-
  specific; use `unimplemented!()` if SQL Server has no equivalent), `metadata_adapter`.
- `[ ]` For any capability SQL Server genuinely doesn't support, use
  `unimplemented!()` — explicitly fine for an initial contribution per the guide.
- `[ ]` Run `cargo build -p dbt-adapter` repeatedly; treat every
  `error[E0004]: non-exhaustive patterns` as one checklist item until clean.

---

## 5.6 — SQL macros

**Crate:** `dbt-loader` — `crates/dbt-loader/src/dbt_macro_assets/dbt-sqlserver/` (new directory)

No registration code is needed anywhere: `internal_package_names()` in
`load_packages.rs` resolves the package as `format!("dbt-{adapter_type}")`, so
adding the directory is what wires it up (`00-current-state.md` §6).

- `[ ]` Create `dbt_project.yml`: `name: dbt_sqlserver`, `macro-paths: ["macros"]`
  (mirror `dbt-fabric/dbt_project.yml`) and `__init__.py` (three lines, exposing
  `PACKAGE_PATH` — copy Fabric's).
- `[ ]` Copy `dbt/include/sqlserver/macros/` across with its directory structure
  intact. v2 keeps v1's layout — `dbt-fabric/` has `macros/adapters/`,
  `macros/materializations/`, `macros/utils/`, vendored verbatim from
  `microsoft/dbt-fabric` (42 files). Flat single-file packages exist
  (`dbt-exasol`, 2 files) but are the exception, and the guide's worked example
  rather than the norm.
- `[ ]` Confirm the required macro set is present and dispatches under
  `sqlserver__`: `create_schema`, `drop_schema`, `drop_relation`,
  `rename_relation`, `truncate_relation`, `create_table_as`, `create_view_as`,
  `list_schemas`, `check_schema_exists`, `information_schema_name`,
  `current_timestamp`, `get_columns_in_relation`,
  `list_relations_without_caching`.
- `[ ]` Work the exceptions to the wholesale copy — deferrals, macros the Rust
  layer now owns, and defaults the shared `dbt-adapters` package already
  provides: `03-macros-porting-map.md`.
- `[ ]` Where SQL Server behavior matches an already-supported T-SQL adapter,
  delegate rather than reimplement:
  ```jinja
  {% macro sqlserver__create_table_as(temporary, relation, sql) -%}
    {{ return(fabric__create_table_as(temporary, relation, sql)) }}
  {%- endmacro %}
  ```
  Only override where T-SQL/SQL Server-specific behavior differs from Fabric
  (e.g. `IDENTITY_INSERT`, index/columnstore DDL, `MERGE` syntax nuances).

---

## Cross-cutting: changelog entry

- `[ ]` Add `.changes/unreleased/Features-*.yaml` per repo convention (check
  an existing entry, e.g. for Exasol or Fabric's original PR, for the exact
  format expected).

## Summary file count vs. the guide's "~13 files"

Given SQL Server already has ADBC + most of `dbt-auth` done, expect roughly:
`dbt-adapter-core` (1) + `dbt-schemas` (1) + `dbt-auth` (1, extending existing)
+ `dbt-adapter` (6: relation_impl, factory, sql_types, column_builder,
get_relation, adapter_impl, metadata/sqlserver/mod.rs — 7) + `dbt-loader`
(2+: dbt_project.yml + macro files) + changelog (1) + optional dbt-init (2) ≈
**12–16 files**, in line with the guide's estimate, biased slightly higher
because of the auth-gap work in 5.4 and the metadata module in 5.5.
