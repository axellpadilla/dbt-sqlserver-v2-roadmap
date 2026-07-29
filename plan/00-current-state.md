# 00 — Current State Audit

Audited against local checkouts:
- `dbt-core/` @ commit `f4c63ccca244a2f28456deaef2d91ee539c99d3a` (branch `main`)
- `dbt-sqlserver/` @ commit `f51fd392f489b69275add5a9940c6380dc9cc9e` (branch `master`, dbt-msft fork)

> Note: the official guide refers to a `dbt-xdbc` crate. In this checkout the
> equivalent crate is named **`dbt-adbc`** (`crates/dbt-adbc/`). Treat every
> guide reference to `dbt-xdbc` as `dbt-adbc` for this repo's current layout —
> re-verify against `crates/` when you start, in case it gets renamed upstream.

## 1. `AdapterType` enum — `crates/dbt-adapter-core/src/lib.rs`

```rust
pub enum AdapterType {
    Snowflake, Bigquery, Databricks, Redshift, Spark, DuckDB,
    Postgres, Salesforce, Fabric, ClickHouse, Exasol, Athena,
    Starburst, Trino, Datafusion, Dremio, Oracle, Alt,
}
```

No `SqlServer` variant. This is the first thing to add (Step 5.1). `Fabric`
exists and is the T-SQL sibling — use its `quote_char` arm as the template
(double quote, same as most warehouses; SQL Server also supports `[bracket]`
quoting, which is a real behavioral decision — see `05-open-questions-and-risks.md`).

## 2. ADBC driver registration — `crates/dbt-adbc/src/driver.rs`, `install.rs`

**Already implemented.** `Backend::SQLServer` exists end-to-end:

- `driver.rs:78` — `Backend` enum variant `SQLServer`
- `driver.rs:113` — `Backend::SQLServer => write!(f, "SQL Server")`
- `driver.rs:134` — ADBC library name: `Backend::SQLServer => Some("adbc_driver_mssql")`
- `driver.rs:380`, `437` — included in the CDN-distributed backend list alongside
  Snowflake, BigQuery, ClickHouse, Postgres, Databricks, Redshift, DuckDB,
  DuckDB Extended, Salesforce, Spark
- `install.rs:26,317,733,769,889` — CDN download URL/version (`mssql` /
  `MSSQLSERVER_DRIVER_VERSION`), including a macOS x86_64 special case shared
  with ClickHouse (`install.rs:889`)
- `repl.rs:32` — `"sqlserver" | "mssql" => Ok(Backend::SQLServer)` (adbc REPL alias)

**Action for this project: none required** unless the driver needs new
connection parameters not yet exposed (see `apply_connection_args` gap in §3).

**Confirmed: this is the same driver dbt-sqlserver v1 now speaks to, not just
an architecturally-similar one** — v1 just merged
[PR #783 "Add experimental ADBC backend"](https://github.com/dbt-msft/dbt-sqlserver/pull/783)
(commit `bca9e3e`, `master`'s tip), a third connection backend (alongside
`pyodbc` and `mssql-python`) that opens `adbc_driver_manager.connect(driver="mssql", ...)`
against the identical `adbc_driver_mssql`/`go-mssqldb` combination. Details
and how it closes the `apply_connection_args` gaps below: §3.

## 3. Auth module — `crates/dbt-auth/src/sqlserver/mod.rs` (337 lines)

**Already implemented, with unit tests.** Supports:

- `ActiveDirectoryServicePrincipal` (alias `ServicePrincipal`) — tenant_id,
  client_id, client_secret → `fedauth=ActiveDirectoryServicePrincipal`
- `ActiveDirectoryPassword` — UID/PWD + client_id → `fedauth=ActiveDirectoryPassword`
- `environment` — reads standard `AZURE_*` env vars via
  [`EnvironmentCredential`](https://pkg.go.dev/github.com/Azure/azure-sdk-for-go/sdk/azidentity#EnvironmentCredential)
  → `fedauth=ActiveDirectoryEnvironment`
- Connection URI: `sqlserver://{host}:{port}?database={database}`, default port
  `1433` (`DEFAULT_PORT` const)
- Dispatch wired: `crates/dbt-auth/src/lib.rs:93` —
  `Backend::SQLServer => Box::new(sqlserver::SQLServerAuth {})`

**Explicitly stubbed as `unimplemented!()`** (line ~139):
`ActiveDirectoryInteractive`, `ActiveDirectoryIntegrated`, `CLI`, `auto`.

**Gaps relative to v1 `dbt-sqlserver`** (`dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_credentials.py`,
`sqlserver_auth.py`) — v1 also supports plain SQL auth (`authentication: sql`,
username/password against SQL Server's native login, not Entra) and Windows
integrated auth via `trusted_connection`. Neither is in the v2 module yet, and
**plain SQL auth is the default/most common on-prem SQL Server auth mode** —
this is very likely required for a real "SQL Server" (as opposed to
"Azure SQL via Entra") adapter to be useful. See `01` and `05`.

`apply_connection_args` has `// TODO` comments for: connection timeout, dial
timeout, `encrypt`, app name, log, retries — all standard `go-mssqldb` DSN
params (https://github.com/microsoft/go-mssqldb#connection-parameters-and-dsn).
`encrypt` in particular matters for on-prem servers without valid TLS certs
(`encrypt=disable` / `TrustServerCertificate` equivalent).

**These are not open design questions — v1's new ADBC backend already solved
them against the same driver.** `dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_backend.py:367-401`
(`build_adbc_connection_uri`) builds exactly this query string:

```python
query_parts = [
    f"database={urllib.parse.quote(database, safe='')}",
    f"encrypt={str(credentials.encrypt).lower()}",
    f"TrustServerCertificate={str(credentials.trust_cert).lower()}",
]
if credentials.login_timeout and credentials.login_timeout > 0:
    query_parts.append(f"connection timeout={credentials.login_timeout}")
```

with defaults from `sqlserver_credentials.py:55-59`:
`encrypt: Optional[bool] = True`, `trust_cert: Optional[bool] = False`,
`login_timeout: Optional[int] = 0` (0 = driver default, no explicit param
appended). It also URL-encodes user/password (`urllib.parse.quote(..., safe='')`)
and special-cases named instances (host containing `\\`, port omitted) —
both worth checking against v2's `apply_connection_args`, which currently
only handles `host:port` unconditionally. **Port these three params
(`encrypt`, `TrustServerCertificate`, `connection timeout`) and their
defaults directly** into `crates/dbt-auth/src/sqlserver/mod.rs` rather than
re-deriving them from `go-mssqldb`'s docs from scratch — v1's ADBC backend is
a working, merged reference for the exact same driver.

## 4. Profile config — `crates/dbt-schemas/src/schemas/profiles.rs`

```rust
pub enum DbConfig {
    Redshift(...), Snowflake(...), Postgres(...), Bigquery(...), Trino(...),
    Datafusion(...),
    // SqlServer,          <-- line 46, commented placeholder only
    // SingleStore,
    Spark(...), Databricks(...), Salesforce(...), DuckDB(...), Alt(...),
    Exasol(...),
    // Oracle,
    // Synapse,
    Fabric(Box<FabricDbConfig>),
    // Dremio,
    ClickHouse(...),
    ...
}
```

No `SqlServerDbConfig` struct exists. `FabricDbConfig` (same file) is the
closest template — check its field list (host, database, authentication,
tenant_id/client_id/client_secret, port, schema, threads, etc.) and diff
against what `sqlserver/mod.rs`'s `parse_auth`/`apply_connection_args` actually
read via `config.get_str(...)` / `config.require_str(...)`, since those calls
are the real source of truth for required field names.

## 5. Adapter layer — `crates/dbt-adapter/src/**`

No `SqlServer` arms anywhere; `Fabric` arms exist in every file that will need
a `SqlServer` arm added alongside:

| File | Fabric arm(s) | What it controls |
|---|---|---|
| `src/relation/relation_impl.rs:158,219,270,280,290,488` | shared generic relation impl list (`Databricks \| Fabric \| Postgres \| Redshift \| Salesforce \| Bigquery`) | quoting/inclusion policy for db/schema/identifier |
| `src/relation/factory.rs:19` | included in `create_static_relation` match | wires `AdapterType` to `RelationStatic` |
| `src/sql_types.rs:183,342,353,369,383,391,401,414,546,601,638,884,920,929,959,970` | type-name mapping (`real`, `float`, `bit`, `datetime2(6)`, `time(6)`, `varchar`), metadata key, row-size limits (VARCHAR ≤ 8000 bytes), explicit "INTERVAL/ARRAY not supported" errors | Arrow↔SQL type mapping, per-warehouse type quirks |
| `src/column/column_builder.rs:31,127-128,237-260` | `Fabric => Ok(Self::build_fabric(field, type_ops))`, dedicated `build_fabric` fn | Arrow record batch → dbt `Column` object |
| `src/metadata/get_relation.rs:76` | `AdapterType::Fabric => fabric_get_relation(...)` | single-relation catalog lookup |
| `src/metadata/fabric/mod.rs` | 346-line module: full catalog introspection (`INFORMATION_SCHEMA`/`sys.*` queries) | model for `metadata/sqlserver/mod.rs` |
| `src/adapter/adapter_impl.rs` | 44 occurrences across ~15 functions (`list_schemas`, `valid_incremental_strategies`, `get_adbc_execute_options`, `alter_table_add_columns`, `is_replaceable`, `truncate_relation`, `get_constraint_support`, grants/masking helpers, etc.) | most of the exhaustive per-warehouse behavior surface |

`valid_incremental_strategies` for Fabric (`adapter_impl.rs:534`):
`&[Append, DeleteInsert, Merge, Microbatch]` — SQL Server v1 supports the same
set (see `dbt-sqlserver/dbt/include/sqlserver/macros/materializations/models/incremental/incremental_strategies.sql`),
so this is very likely a direct copy.

**Action:** for every `Fabric =>` arm found by `grep -n "Fabric" crates/dbt-adapter/src -r`,
decide: (a) copy the same behavior for `SqlServer`, (b) diverge because classic
SQL Server lacks a Fabric/Synapse-only feature (e.g. OneLake, certain
distributed-warehouse DDL), or (c) diverge because SQL Server supports something
Fabric doesn't (e.g. `IDENTITY` columns, full DML `MERGE`, clustered/nonclustered
indexes beyond columnstore, `sp_rename`, `sql_variant`). Track these
in `05-open-questions-and-risks.md` as they're found — the compiler will
enumerate the full list once `AdapterType::SqlServer` exists (Step 5.1).

## 6. Jinja macros — `crates/dbt-loader/src/dbt_macro_assets/`

Only `dbt-fabric/` and `dbt-fabricspark/` exist. No `dbt-sqlserver/` directory.
`dbt-fabric/` contains (non-exhaustive, found via grep): `macros/adapters/persist_docs.sql`,
`macros/materializations/snapshots/snapshot.sql`. Read the full `dbt-fabric/`
tree before starting Step 5.6 — it's the closest existing v2 Jinja reference
for T-SQL dispatch macros (`fabric__create_table_as`, etc.) and shows the
current dispatch-prefix convention in this repo.

The v1 `dbt-sqlserver/dbt/include/sqlserver/macros/` tree (34 `.sql` files) is
the full porting source — see `03-macros-porting-map.md`.

## 7. `dbt init` interactive setup (optional, Step 5.3.1)

`crates/dbt-init/src/adapter_config/fabric_config.rs` exists as the pattern.
`crates/dbt-init/src/profile_setup.rs` — check `get_available_adapters()` for
whether `Fabric` is listed there yet as a template to copy for `SqlServer`.

## 8. v1 adapter inventory (porting source) — `dbt-sqlserver/`

```
dbt/adapters/sqlserver/
  sqlserver_adapter.py       — SQLServerAdapter class (no longer needed; behavior moves to Rust match arms)
  sqlserver_auth.py          — auth flows (compare against crates/dbt-auth/src/sqlserver/mod.rs gaps)
  sqlserver_backend.py
  sqlserver_column.py        — column/type mapping (source for sql_types.rs / column_builder.rs arms)
  sqlserver_configs.py       — incremental/materialization config (source for adapter_impl.rs arms)
  sqlserver_connections.py   — connection mgmt (NOT needed — ADBC driver replaces this entirely)
  sqlserver_constants.py
  sqlserver_credentials.py   — profile fields (source for SqlServerDbConfig struct)
  sqlserver_helpers.py
  sqlserver_mask.py          — data masking support (apply_masks.sql — SQL Server-specific feature, check if in scope)
  sqlserver_relation.py      — relation/quoting logic (source for relation_impl.rs arm + Policy)
  sqlserver_runtime.py
  relation_configs/          — relation config parsing (indexes, etc.)

dbt/include/sqlserver/macros/   — 34 .sql files, full mapping in 03-macros-porting-map.md
```

Per the guide's "What doesn't exist in v2" list, skip porting: connection
management (`sqlserver_connections.py`), the adapter class hierarchy
(`sqlserver_adapter.py`'s class shape — only its *behavior* matters, expressed
as match arms), and packaging (`pyproject.toml`, `setup.py` — no PyPI release
for v2, dbt Labs ships it in the monorepo binary).
