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

Measured: adding the variant produces **10** `E0004`s, nine of them the
`impl DbConfig` accessors in `profiles.rs` — `get_unique_field`,
`get_connection_keys`, `to_yaml_value`, `adapter_type`, `get_database`,
`get_schema`, `get_threads`, `set_threads`, and the `TargetContext` `try_from`
— plus `render_with_run_filter`. Nothing else in the workspace regresses: the
next 46 are §5.5's, all but one in `dbt-adapter`.

The odd one out is `dbt-df-providers` `seed_io.rs`
`infer_seed_column_name_strategy`, which owns no §5.5 file and is claimed by
no issue in the Part series. It picks how a seed CSV header becomes a column
name: `Verbatim`, `Lowercase` or `Uppercase`, keyed on `(quote_columns,
adapter_type)`. `Fabric` sits with `Bigquery | Databricks | Spark` on
`Verbatim`, which is what SQL Server does with an unquoted column name — it
stores the case it was given — so `Lowercase` would silently rename every
mixed-case seed header. Choose it deliberately; `05`'s collation risk lists it
alongside the other three case-sensitive sites.

Three field-level calls worth knowing before writing the struct:

- **`get_connection_keys` must say `host`, not v1's `server`.**
  `to_connection_mapping` filters the *serialized* key names, and
  `#[serde(alias)]` only affects deserialization. `FabricDbConfig` lists
  `"server"` while its field serializes as `host`, so Fabric's host never
  survives the filter — don't copy that. The same reasoning keeps `PWD` and
  `client_secret` off the list.
- **`threads` belongs on the struct**, even though `FabricDbConfig` has no such
  field and `get_threads` returns `None` for Fabric. v1 inherits `threads` from
  `Credentials`, so a ported profile setting it would otherwise be silently
  ignored.
- **`authentication` has no default here.** v1 defaults to `sql`, but the value
  that actually governs connection setup is `dbt-auth` `parse_auth`'s
  `DEFAULT_AUTH`, which is Entra service-principal today. §5.4 decides it;
  until then `TargetContext` leaves it empty rather than asserting an answer.

## 5.3.1 — `dbt init` profile generation (recommended; compiles-or-not, not truly optional)

**Crate:** `dbt-init` — `crates/dbt-init/`

- `[ ]` Add `AdapterType::SqlServer` to `get_available_adapters()` in
  `src/profile_setup.rs`.
- `[ ]` Create `src/adapter_config/sqlserver_config.rs` implementing
  `InteractiveSetup` for `SqlServerDbConfig`. Use
  `src/adapter_config/fabric_config.rs` as the template (same auth surface
  shape) and `postgres_config.rs` per the guide's "minimal reference" note.
- `[ ]` Export from `src/adapter_config/mod.rs`.
- `[ ]` Add match arm in `create_profile_for_adapter()` in `profile_setup.rs`.
- The *interactive setup* is deferrable — the guide calls it optional, and a
  hand-written `profiles.yml` gets `dbt build` working without it. The match
  arm is not: `create_profile_for_adapter` matches `AdapterType` exhaustively
  with no `_`, so `dbt-init` stops compiling the moment §5.1 lands. Deferring
  means landing `AdapterType::SqlServer => todo!("SqlServer")` there and
  filling it in later, not skipping the file. The compiler enforces this, so
  it can't be silently missed — but it does mean the workspace can't build
  green until someone touches `dbt-init`.

## 5.4 — Authentication

**Crate:** `dbt-auth` — `crates/dbt-auth/src/sqlserver/`

- `[x]` `mod.rs` exists with `ActiveDirectoryServicePrincipal`,
  `ActiveDirectoryPassword`, `environment` auth flows, unit-tested.
- `[x]` Dispatch wired in `src/lib.rs` `auth_for_backend`.
- `[x]` Plain SQL authentication — native SQL Server login, username and
  password, no Entra/`fedauth` param (`05` #2). `SQLServerAuthIR::SqlLogin`
  plus a `parse_auth` branch for `authentication: sql`, the value
  `SQLServerCredentials.authentication` defaults to. A top-level variant, not
  a refinement of an Entra one: a server-local login is a different
  authentication contract, which is what this crate's `AGENTS.md` invariant 5
  asks you to classify before touching the enum.

  It sets `user id` and `password` as query pairs, like the three variants
  already in the file, rather than the URI userinfo v1's
  `build_adbc_connection_uri` writes. Both work against `go-mssqldb`, and
  `append_pair` percent-encodes, which closes the user/password encoding gap
  v1 handles by hand.
- `[ ]` Leave Windows/trusted-connection auth out (`05` #2) — it only matters
  when dbt itself runs on a domain-joined Windows host. Keep the existing
  `unimplemented!()` stub for `ActiveDirectoryIntegrated` as-is; don't add a
  `trusted_connection` config field.
- `[x]` `encrypt`, `TrustServerCertificate` and `connection timeout` in
  `apply_connection_args` (`crates/dbt-auth/src/sqlserver/mod.rs`). Ported from
  `sqlserver_backend.py` `build_adbc_connection_uri`, which builds the
  identical query string against the same driver
  ([PR #783](https://github.com/dbt-msft/dbt-sqlserver/pull/783)), rather than
  re-derived from the `go-mssqldb` docs. Defaults are `SQLServerCredentials`':
  `encrypt=True`, `trust_cert=False`, `login_timeout=0` (param omitted when
  not positive). Both flags accept a YAML boolean or its string spelling,
  following `clickhouse/mod.rs` `secure`.
  Reference: https://github.com/microsoft/go-mssqldb#connection-parameters-and-dsn
- `[ ]` Named instances still fail. `host: myserver\SQLEXPRESS` is rejected at
  URI parse with `invalid domain character`, because the `url` crate won't
  accept a backslash in a host; v1 omits the port and lets the SQL Server
  Browser resolve the instance. Percent-encoding to `%5C` parses on our side,
  but nothing in this workspace can confirm `go-mssqldb` decodes it back, and
  a host rewrite that silently reaches the wrong server is worse than the
  current loud error. `TODO` at the parse site.
- `[ ]` `DEFAULT_AUTH` is still `ActiveDirectoryServicePrincipal`, where v1
  defaults to `sql`. Fabric maps to the same backend
  (`adapter_factory.rs` `AdapterType::Fabric => Backend::SQLServer`) and shares
  this module, and `auth_for_backend` receives only a `Backend`, so the two
  can't be told apart inside `dbt-auth`. Changing the constant would change
  Fabric. Consequence today: a ported v1 profile that omits `authentication`
  gets `client_id is required` rather than a SQL login. Resolving it means
  passing the adapter type in, or defaulting the field before the config
  reaches `dbt-auth` — either way a `dbt-adapter` change (§5.5).
- `[ ]` Connection-init SQL — **not a `dbt-auth` file, and not
  `QUOTED_IDENTIFIER`.** Two findings move this:

  Measured against `make server` (SQL Server 2022) through the same
  `go-mssqldb` ADBC driver v1.6.0 dbt installs:
  `sessionproperty('QUOTED_IDENTIFIER') = 1`, `ANSI_NULLS = 1`,
  `CONCAT_NULL_YIELDS_NULL = 1`, and `@@OPTIONS & 16384 = 0` — so `XACT_ABORT`
  is **off**. That reproduces
  [PR #795](https://github.com/dbt-msft/dbt-sqlserver/pull/795)'s conclusion
  that the quoting-side setting needs no code change, and it identifies the one
  that does: `SET XACT_ABORT ON` is the session-level `SET` v1 issues on connect
  (`sqlserver_connections.py` `_apply_session_settings`,
  [#718](https://github.com/dbt-msft/dbt-sqlserver/issues/718)), and v1 macro
  bodies depend on it — `create.sql`, `table_dml_refresh.sql` and `indexes.sql`
  each say so in comments. Porting those bodies without the `SET` changes what
  a mid-batch error does.

  There is also nowhere in dbt-core to put it. No per-connection init hook
  exists: `AdbcEngine::new_connection_with_config` goes straight to
  `connection::Builder::default().build()`. The one precedent,
  `apply_duckdb_init_sql`, runs once per *database* on a throwaway connection —
  which cannot carry a SQL Server session setting, since every connection is
  its own session. So `dbt-auth/src/sqlserver/init.rs` would be dead code with
  no call site; the work belongs in `dbt-adapter` (§5.5) next to the hook that
  executes it. `05` #1 records the quoting side of the same decision.

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

- `[x]` `SqlServer` in `get_database`, joining the existing
  `Databricks | Fabric | Postgres | Redshift | Salesforce | Bigquery` group.
  That group raises `InvalidConfig` when `database` is unset; the `_` arm
  returns an empty string, so without the arm a relation missing a database
  renders as `.schema.table` instead of erroring.
- `[x]` `include_policy` left alone — its `_ => Policy::trues()`
  is already correct for SQL Server's 3-part naming, and the explicit arms
  there are all for adapters that drop a path part.
- `[x]` The shared rendering path does **not** escape an embedded delimiter.
  `BaseRelation::quoted` in `dbt-schemas` is
  `format!("{q}{s}{q}")`, so `x"q` rendered `"x"q"` — unparseable, and v2
  would reject names v1 accepts (v1 fixed this in
  `SQLServerAdapter.quote()`/`SQLServerRelation.quoted()`,
  `05-open-questions-and-risks.md` #1). Fixed with a `SqlServer` arm in
  `Relation`'s override, not in the shared default: `quoted()` is inherited by
  every adapter with a quote character, so widening it would change rendering
  for Snowflake, Postgres, Redshift and Fabric. That the shared default looks
  wrong for those too is worth raising upstream separately.
- `[x]` `SqlServer` alongside `Fabric` in `get_canonical_fqn`'s three
  db/schema/identifier arms, which case-fold an unquoted path part.
  `Fabric | Bigquery` pass it through verbatim; the `_` arm lowercases. SQL
  Server preserves the case it was given, so it belongs with `Fabric`.
- `[x]` `normalize_component` left alone, which is a different question from
  the one above: it models how the server *resolves* an unquoted name, not how
  it stores one. Folding to lower case is the right canonicalization for a
  case-insensitive collation — the bucket Fabric already sits in — and passing
  through would make `MyTable` and `mytable` distinct `semantic_fqn`s for one
  object.
- `[x]` `new_sqlserver` mirroring `new_fabric`. No callers until the metadata
  module below.

### Relation factory — `src/relation/factory.rs`

- `[x]` `SqlServer` in the `create_static_relation` match, alongside `Fabric`.

### Adapter backend — `src/adapter/adapter_factory.rs`

- `[x]` `AdapterType::SqlServer => Backend::SQLServer` in `backend_of`, the
  same ADBC backend Fabric rides. One of the `E0004`s, and no issue in the
  Part series claimed it — it landed with Part 4, since no adapter can be
  constructed without it.

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

- `[x]` Add an `AdapterType::SqlServer => sqlserver_get_relation(...)` arm to
  `get_relation`, alongside the existing `Fabric` arm.
- `[x]` Create `src/metadata/sqlserver/mod.rs`, modeled on
  `src/metadata/fabric/mod.rs` — but **not** driving `sp_tables`/`sp_columns`
  the way Fabric's does. Measured against SQL Server 2022 (16.0.4265.3):
  - A `@table_qualifier` other than the connection's current database is
    error 15250, "The database name component of the object qualifier must be
    the name of the current database". Fabric never meets this because a
    warehouse *is* the database; on SQL Server, cross-database references are
    ordinary, and v1 supports them by emitting `USE [db];` first.
  - `@table_name` is a `LIKE` pattern unless `@fUsePattern = 0` is passed, so
    `probe_table` also returns `probeXtable`. `\_` does not escape it. In
    `get_relation` the extra row fails the one-row check; in `sp_columns` it
    merges a second table's columns into the schema. dbt model names are
    snake_case, so this is not an edge case.

  Both defects apply to `metadata/fabric/mod.rs` as it stands. The port uses
  three-part `sys.objects`/`sys.schemas`/`sys.columns`/`sys.types` instead,
  which resolves cross-database and — unlike v1's `USE` — leaves the
  connection's current database untouched.
- `[x]` Type text: `sp_columns.TYPE_NAME` is the bare name, so `decimal(18,4)`
  arrives as `decimal`. `compose_type_text` rebuilds it from
  `max_length`/`precision`/`scale` following v1's
  `sqlserver__get_columns_in_relation`, including halving `max_length` for the
  national types (`sys.columns` reports bytes) and leaving `datetime` bare,
  which reports a scale but rejects one.
- `[x]` The catalog `build_*` functions read `table_comment` and
  `column_comment` (Postgres does, Fabric does not). v1's `get_catalog`
  returns both and v1 supports `persist_docs`; this fixes the column contract
  §5.6's catalog macro has to satisfy.
- `[ ]` `freshness_inner` and `list_relations_schemas_by_patterns_inner` are
  `todo!()`, matching both Fabric and Postgres. v1 has
  `sqlserver__get_relation_last_modified` to port for the first.
- `[ ]` Index metadata via `sys.indexes`/`sys.index_columns`, used by v1's
  `indexes.sql` and `relation_configs/`. Not part of the `MetadataAdapter`
  trait, so it has no home in this module yet — revisit with the
  materializations.
- Two arms in `adapter_impl.rs` (`metadata_adapter`, `list_relations`) landed
  here rather than below: they are what makes the module reachable.

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
