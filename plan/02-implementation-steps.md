# 02 — Implementation Steps (file-by-file checklist)

Source guide: https://docs.getdbt.com/guides/adapter-creation-v2 (Step 5).
All paths are relative to `dbt-core/`. After every sub-step run
`cargo build -p <crate>` per `01-architecture-and-prerequisites.md`.

Checkbox legend: `[ ]` not started, `[~]` partially done already in this repo,
`[x]` already done in this repo (verify, don't redo).

---

## 5.1 — Register the adapter type

**Crate:** `dbt-adapter-core` — `crates/dbt-adapter-core/src/lib.rs`

- `[ ]` Add `SqlServer` to the `AdapterType` enum (next to `Fabric`, ~line 67).
- `[ ]` Add a `quote_char` arm: `SqlServer => '"'`. **Decided**
  (`05-open-questions-and-risks.md` #1) — double-quote identifiers, with
  `SET QUOTED_IDENTIFIER ON` enforced via connection-init SQL (see §5.4
  below), not bracket quoting. Compare against `Fabric`'s arm to confirm it
  uses the same convention before assuming this is novel.
- `[ ]` Run `cargo build -p dbt-adapter-core` — expect it to fail elsewhere
  first (this crate is small), but confirm this specific file compiles.

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
- `[ ]` Include plain SQL auth fields (`user`/`UID`, `password`/`PWD` without
  the Entra `tenant_id`/`client_id`/`client_secret` fields) in
  `SqlServerDbConfig` — **decided in scope for the initial PR**
  (`05-open-questions-and-risks.md` #2), not deferred. Windows/trusted-
  connection auth fields are deferred — don't add a `trusted_connection`
  field yet.
- `[ ]` Uncomment and fix the `// SqlServer,` placeholder (line 46) →
  `SqlServer(Box<SqlServerDbConfig>)`.
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
- `[x]` Dispatch wired in `src/lib.rs:93`.
- `[ ]` **DECIDED — in scope**: add plain SQL authentication (native SQL
  Server login: username + password, no Entra/`fedauth` param)
  (`05-open-questions-and-risks.md` #2). This is a new `SQLServerAuthIR`
  variant plus a `parse_auth` branch for `authentication: sql` (confirm
  exact value name against `sqlserver_credentials.py`/`sqlserver_auth.py`
  rather than inventing one). Unlike the Entra variants, it maps straight to
  the URI's userinfo (`user:password@host`), the same way v1's ADBC backend
  (`sqlserver_backend.py:387`) already does it — see `00-current-state.md` §3.
  Add a unit test alongside the existing ones in `sqlserver/mod.rs`.
- `[ ]` **DECIDED — deferred**: Windows/trusted-connection auth
  (`trusted_connection: true` in v1) is out of scope for the initial PR
  (`05-open-questions-and-risks.md` #2) — only relevant when the dbt process
  runs on a domain-joined Windows host. Leave the existing
  `unimplemented!()` stub for `ActiveDirectoryIntegrated` as-is; don't add a
  `trusted_connection` config field.
- `[ ]` Fill in the `// TODO` params in `apply_connection_args`
  (`crates/dbt-auth/src/sqlserver/mod.rs`): `encrypt`/TLS trust settings
  (**important for on-prem servers with self-signed certs** — without this,
  connections to most on-prem SQL Server instances will fail TLS validation),
  connection timeout, app name. **Don't re-derive these from the `go-mssqldb`
  docs from scratch — port directly from
  `dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_backend.py:367-401`
  (`build_adbc_connection_uri`)**, which already builds the identical query
  string (`encrypt`, `TrustServerCertificate`, `connection timeout`) against
  the same `adbc_driver_mssql` driver, as part of the just-merged
  [PR #783 "Add experimental ADBC backend"](https://github.com/dbt-msft/dbt-sqlserver/pull/783)
  (commit `bca9e3e`). Also port its field defaults from
  `sqlserver_credentials.py:55-59`: `encrypt` defaults `True`, `trust_cert`
  defaults `False`, `login_timeout` defaults `0` (omit the param when `<= 0`).
  While there, check its named-instance handling (host containing `\\` →
  port omitted from the URI) and URL-encoding of user/password
  (`urllib.parse.quote(..., safe='')`) — v2's current `apply_connection_args`
  doesn't handle either and both are visible gaps by direct comparison.
  Reference: https://github.com/microsoft/go-mssqldb#connection-parameters-and-dsn
- `[ ]` `src/init.rs` — **required, not optional**, as a direct consequence of
  the quoting decision in 5.1: must issue `SET QUOTED_IDENTIFIER ON` as init
  SQL on every connection open, since server/login/database defaults for this
  setting cannot be relied on (it can be forced `OFF` by legacy compatibility
  settings). Without this, every double-quoted identifier the adapter emits
  will error or be misinterpreted as a string literal on a session where it's
  off. Also evaluate `SET ANSI_NULLS ON` (standard companion setting, some
  T-SQL constructs — notably indexed views and computed-column indexes —
  require both `ON`). Check v1's `sqlserver_connections.py`/`sqlserver_adapter.py`
  for any other session-level `SET` statements it issues on connect, but treat
  `QUOTED_IDENTIFIER` as the one that's non-negotiable here (v1 doesn't need
  it because it quotes with brackets, not double quotes).

## 5.5 — Adapter layer (largest step)

**Crate:** `dbt-adapter` — `crates/dbt-adapter/src/`

Simple-vs-complex call: SQL Server uses standard `database.schema.table`
3-part naming like `Fabric` — **treat it as a simple adapter**, adding arms to
shared files rather than a dedicated subdirectory (per the guide's "Simple vs.
Complex Adapters" split, where Snowflake/BigQuery get subdirectories and most
others don't).

### Relation type & quoting — `src/relation/relation_impl.rs`

- `[ ]` Add `SqlServer` to the `include_policy` match (~line 219) — start by
  joining the existing `Databricks | Fabric | Postgres | Redshift | Salesforce
  | Bigquery` shared-generic-relation-impl group unless the quoting decision
  from 5.1 forces a separate arm.
- `[ ]` Add `SqlServer` alongside `Fabric` at lines ~270/280/290 (the
  db/schema/identifier string-formatting arms).
- `[ ]` Add a `SqlServer` constructor mirroring line ~488
  (`Self::new(AdapterType::Fabric, database, schema, identifier)`).

### Relation factory — `src/relation/factory.rs`

- `[ ]` Add `SqlServer` to the `create_static_relation` match (~line 19,
  alongside `Fabric`).

### SQL type mapping — `src/sql_types.rs`

- `[ ]` Add `SqlServer` arms wherever `Fabric` appears (lines ~183, 342, 353,
  369, 383, 391, 401, 414, 546, 601, 638, 959, 970). Confirm each value against
  actual SQL Server T-SQL types, not assumed identical to Fabric — Fabric
  Warehouse has real T-SQL surface differences (e.g. Fabric disallows some
  legacy types, has different max VARCHAR/row-size limits than on-prem SQL
  Server's 8060-byte page limit vs Fabric's stated 8000-byte VARCHAR limit at
  line ~884 — verify against SQL Server's actual limits rather than copying).
- `[ ]` Decide `AdapterType::SqlServer => SQLSERVER_METADATA_SQL_TYPE_KEY`
  (mirroring `FABRIC_METADATA_SQL_TYPE_KEY` at ~line 546) — value depends on
  whichever `INFORMATION_SCHEMA`/`sys.*` column your catalog queries select.
- `[ ]` Review the two `unimplemented!`/error arms (INTERVAL, ARRAY not
  supported — lines ~920/929) — SQL Server also lacks native ARRAY and
  INTERVAL types, so these error arms are very likely directly reusable
  (adjust wording only).

### Column builder — `src/column/column_builder.rs`

- `[ ]` Add `SqlServer` arm (~line 31). Try `Self::build_postgres_like(...)`
  first (per the guide's default recommendation for adapters without unusual
  type handling); if SQL Server-specific type quirks surface during smoke
  testing, add a dedicated `build_sqlserver` following the `build_fabric`
  pattern (~lines 127–260) instead.

### Catalog introspection — `src/metadata/get_relation.rs` + `src/metadata/sqlserver/mod.rs` (new)

- `[ ]` Add `AdapterType::SqlServer => sqlserver_get_relation(...)` arm
  (~line 76, alongside the existing `Fabric` arm).
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

- `[ ]` `valid_incremental_strategies` (~line 534): Fabric supports `&[Append,
  DeleteInsert, Merge, Microbatch]`. v1 SQL Server supports the same set per
  `dbt-sqlserver/.../incremental_strategies.sql` — **likely a direct copy**.
- `[ ]` `list_schemas_inner` schema column name (~line 1105): Fabric uses
  `"schema"` — verify SQL Server's `INFORMATION_SCHEMA.SCHEMATA` column naming
  matches (it should, since both use SQL Server's information schema).
- `[ ]` `get_adbc_execute_options` (~line 4873): check what Fabric sets here
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

- `[ ]` Create `dbt_project.yml`: `name: dbt_sqlserver`, `macro-paths: ["macros"]`
  (mirror `dbt-fabric/dbt_project.yml`).
- `[ ]` Create `macros/adapters.sql` (or split into subfiles matching
  `dbt-fabric/`'s layout — check whether v2 expects one flat file or the same
  `macros/adapters/`, `macros/materializations/` subdirectory structure v1
  uses; **do not assume** — inspect `dbt-fabric/`'s actual tree first).
- `[ ]` Implement the required macro set with `sqlserver__` dispatch prefix:
  `create_schema`, `drop_schema`, `drop_relation`, `rename_relation`,
  `truncate_relation`, `create_table_as`, `create_view_as`, `list_schemas`,
  `check_schema_exists`, `information_schema_name`, `current_timestamp`,
  `get_columns_in_relation`, `list_relations_without_caching`.
- `[ ]` Full macro-by-macro porting map from the 34 v1 `.sql` files: see
  `03-macros-porting-map.md`.
- `[ ]` Where SQL Server behavior is close to another already-supported
  T-SQL/ANSI adapter, delegate rather than reimplement, e.g.:
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
