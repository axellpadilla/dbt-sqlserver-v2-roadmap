# 05 — Decisions & Risks

The decisions below are load-bearing across many files, so they're settled here
rather than per-file. All five are locked; raise them with dbt Labs in
`#adapter-ecosystem` (`04-testing-and-validation.md` §3) if review pushes back.

## Decisions

1. **Identifier quoting: `"double quotes"`.** `quote_char = '"'`, with an
   embedded `"` escaped by doubling, and `SET QUOTED_IDENTIFIER ON` issued as
   connection-init SQL. This fits the existing `quote_char() -> char` API in
   `crates/dbt-adapter-core/src/lib.rs` unchanged, and matches Fabric and most
   other v2 adapters.

   dbt-sqlserver v1 renders identifiers the same way as of 1.12.0rc2
   ([#795](https://github.com/dbt-msft/dbt-sqlserver/pull/795), closing #785 —
   filed from this workspace — and #409), so macro bodies port without a
   quoting rewrite. Brackets survive in v1 only inside server-side
   `QUOTENAME()` dynamic SQL, which isn't ported.

   The decision governs `quote_char` and rendering, not macro bodies: v2's
   vendored `dbt-fabric` macros hand-format `USE [db]` and
   `{{ "["~column~"]" }}` in five files while Fabric's `quote_char` is `'"'`
   (`00-current-state.md` §6). Bracket literals in a ported body wouldn't
   violate an upstream convention — v1's cleanup just makes the port simpler.

   Consequences:

   - `quote_char` arm for `SqlServer` is `'"'` (Step 5.1).
   - **Escaping is part of the decision.** `ab"cd` must render `"ab""cd"`. A
     `"` needs no escaping inside `[brackets]` but does inside double quotes,
     so the delimiter choice without escaping would reject names v1 accepts.
     v1 implements this in `SQLServerAdapter.quote()` and
     `SQLServerRelation.quoted()`; neither delegates to `super()`, which wraps
     verbatim, so pre-escaping its input would double-escape if upstream ever
     starts escaping. Check whether v2's relation rendering escapes at all
     before assuming the one-character arm is enough — Part 4 work.
   - `SET QUOTED_IDENTIFIER ON` as connection-init SQL, issued from
     `dbt-adapter` (Step 5.5) — not from `dbt-auth`, which has no connection to
     issue it on. Defensive, not a blocker: measured directly against
     `make server` through the `go-mssqldb` ADBC driver v2 uses,
     `sessionproperty('QUOTED_IDENTIFIER') = 1`, matching what v1 measured for
     all three of its backends. Issue it anyway — server-level `user options`,
     a login default or legacy compatibility settings can force it `OFF`, and
     the failure is total (`USE "db"` is a hard `Msg 102`).

     The same hook carries `SET XACT_ABORT ON`, which is the one that is
     measurably absent: `@@OPTIONS & 16384 = 0` on a fresh connection, while v1
     sets it on connect and several v1 macro bodies are written assuming it.
     Step 5.4 has the full measurement.

     A client default can force it `OFF` too, which isn't hypothetical:
     `sqlcmd` from `mssql-tools18` connects with
     `sessionproperty('QUOTED_IDENTIFIER') = 0` unless `-I` is passed, and a
     `CREATE TABLE "..."` on that session fails with `Msg 102`. Measured
     against `make server` (SQL Server 2022, 16.0.4265.3) with
     `sys.configurations` `user options` at 0, so the server isn't the source.
     The `go-mssqldb` driver v2 uses is not `sqlcmd` and does default it `ON`,
     but it means the failure mode is one connection library away rather than
     confined to misconfigured servers.
   - Document `QUOTED_IDENTIFIER ON` as a prerequisite in the Step 7 setup
     guide, and smoke-test a session where it defaults to `OFF` to confirm the
     init SQL overrides it (`04-testing-and-validation.md`).

2. **Auth scope: plain SQL auth in, Windows auth out.** Native SQL Server login
   (username + password, no `fedauth` param) ships in the initial PR;
   Windows/trusted-connection auth is deferred, being environment-dependent and
   only meaningful when dbt itself runs on a domain-joined Windows host.

   `crates/dbt-auth/src/sqlserver/mod.rs` implements only Entra flows today
   (`ActiveDirectoryServicePrincipal`, `ActiveDirectoryPassword`,
   `environment`). Without plain SQL auth the adapter would serve only Azure
   SQL/Entra targets, contradicting the on-prem-first priority in Decision 5.

   Implementation notes:

   - Add a `SQLServerAuthIR` variant (e.g. `Sql { user, password }`) and a
     `parse_auth` branch, likely `authentication: sql` — confirm the value name
     against v1's `sqlserver_credentials.py`/`sqlserver_auth.py`.
   - It sets no `fedauth`; credentials go in the userinfo portion of the
     `sqlserver://` URI, as v1's ADBC backend does
     (`sqlserver_backend.py` `build_adbc_connection_uri` —
     `userinfo = f"{uid}:{pwd}"`, URL-encoded).
   - Add a unit test mirroring the existing `sqlserver/mod.rs` style
     (`test_service_principal_with_tenant_id` → `test_plain_sql_auth`).
   - Reflect it in `02-implementation-steps.md` §5.4 and `SqlServerDbConfig`
     (§5.3), not just here.

3. **TLS/`encrypt`: port v1's parameters.** `apply_connection_args` has a
   `// TODO` for `encrypt`. Without it, on-prem instances with self-signed
   certificates fail by default, since recent `go-mssqldb` defaults to
   `encrypt=true` with strict validation. Required for the initial PR, not
   optional.

   Nothing to design: v1's ADBC backend
   (`sqlserver_backend.py` `build_adbc_connection_uri`,
   [PR #783](https://github.com/dbt-msft/dbt-sqlserver/pull/783))
   builds the same parameter set against the same driver — `encrypt`,
   `TrustServerCertificate`, `connection timeout` — with defaults
   `encrypt=True`, `trust_cert=False`, `login_timeout=0`
   (`SQLServerCredentials`). Port those values (`00-current-state.md`
   §3, `02-implementation-steps.md` §5.4).

4. **Feature scope: v1's SQL-Server-specific extras are deferred.** Out of the
   initial PR, tracked as follow-ups:

   - Dynamic data masking (`apply_masks.sql`)
   - Index/columnstore config (`indexes.sql`, `relation_configs/`)
   - `full_refresh_build: prebuilt` table-rebuild optimization
   - Scalar function materializations
   - Table clone (`relations/table/clone.sql`)

   This matches the guide's framing — `dbt build` and `dbt run` working, not
   full v1 parity — and keeps the PR reviewable.

   **Indexes deserve a note, because the shape isn't what "SQL-Server-specific
   extra" implies.** Indexes are a shared, dispatch-based dbt feature:
   `dbt-adapters/macros/adapters/indexes.sql` in v2 defines `create_indexes`,
   `get_create_index_sql`, `get_drop_index_sql` and `get_show_indexes_sql`, and
   `dbt-postgres` implements the three `postgres__` arms in ~30 lines. v1
   dbt-sqlserver already speaks exactly that contract —
   `sqlserver__get_create_index_sql`, `sqlserver__get_drop_index_sql`,
   `sqlserver__create_indexes`, all driven by `adapter.parse_index()`. So this
   is deferred on cost, not because it's exotic.

   Two things follow:

   - Shipping it would also mean implementing the Rust side.
     `adapter.parse_index` exists as a Jinja callable
     (`crates/dbt-adapter/src/adapter/mod.rs` `parse_index`) but resolves to
     `adapter_impl.rs` `parse_index`, which is `unimplemented!("parse_index")` for
     *every* adapter — Postgres included. Its doc comment points at
     `PostgresAdapter.parse_index` in dbt-adapters, so it's a stub awaiting an
     implementation, and SQL Server can't be the first without doing that work.
   - **Deferring is a silent no-op, and shouldn't stay that way.** With no
     `sqlserver__get_create_index_sql`, `default__get_create_index_sql` returns
     `None` and `create_indexes` quietly does nothing — a model configured with
     `indexes:` builds successfully with no indexes. v1 users lean on clustered
     columnstore indexes heavily, so failing loudly is better than that: give
     SQL Server an arm that raises a compiler error pointing at the follow-up
     issue, rather than inheriting the silent default.

   For the other deferred items, `adapter_impl.rs` arms with no SQL Server
   equivalent should use `unimplemented!()`, per the guide's allowance for
   initial contributions, rather than partial behavior. Track each as a named
   follow-up issue once the initial PR merges.

5. **Smoke-test target: on-prem SQL Server on Linux/Windows.** Same primary
   target as v1, which is where most dbt-sqlserver users are, and the simplest
   to reproduce locally (`dbt-sqlserver/docker-compose.yml`). Azure SQL
   Database is the secondary, CI-coordinated target — it's what exercises the
   Entra auth paths already implemented in `dbt-auth`. Azure SQL Managed
   Instance is not a target for the initial PR.

   On-prem, Azure SQL DB and Azure SQL MI differ in real ways (cross-database
   queries, DMV availability, feature support), so "SQL Server works" needs to
   name a flavor. Coordinate the Azure side with dbt Labs given the
   CI/credential constraints in `04-testing-and-validation.md` §3.

## Risks

- **Metadata/catalog query correctness is the likeliest source of silent
  bugs.** `INFORMATION_SCHEMA` behavior is close but not identical between
  classic SQL Server and Fabric Warehouse (DMV availability, computed-column
  metadata, index metadata only in `sys.*`). Verify every query in
  `metadata/fabric/mod.rs` against a real SQL Server instance before reusing
  it, not against Fabric's behavior.

  **Done in Part 5, and it paid off twice.** Fabric's module drives
  `sp_tables`/`sp_columns`; on SQL Server 2022 those read only the
  connection's current database (error 15250 for any other
  `@table_qualifier`), and `@table_name` is a `LIKE` pattern unless
  `@fUsePattern = 0` is passed, so `stg_orders` also matches `stgXorders`.
  The pattern half is a live defect in Fabric's own code — drafted as
  `issues/v2-fabric-sp-tables-like-pattern.md`, unfiled. The port uses
  three-part catalog-view queries instead. `sp_columns` also drops
  precision, scale and length from `TYPE_NAME`, which `sys.columns` carries.

- **Nothing in dbt-core knows what a collation is.** Every case decision in the
  Rust is a per-`AdapterType` constant, and SQL Server is the only supported
  adapter whose case behavior is configurable per database, per column and per
  comparison. A name that folds to one value in Rust can be two distinct
  objects on a `_CS_` server, and vice versa. Four sites carry the assumption;
  each needs a deliberate choice and a test on a case-sensitive server:

  - `relation_impl.rs` `normalize_component` — SqlServer lands on the
    `_ => to_lowercase()` arm, so `semantic_fqn` merges `MODEL` and `model`.
    Correct under the default `_CI_` collation, wrong under `_CS_`. Reachable
    only when a project turns `quoting` off, since
    `DEFAULT_RESOLVED_QUOTING` is all-true and the quoted path skips the fold.
    v1 has the same defect and knows it: `TestCachingUppercaseModel` is
    `@pytest.mark.skip`ped with "Fails because of case sensitivity. MODEL is
    coereced to model which fails the test as it sees conflicting naming."
    Marked `TODO` in the Part 4 arm.
  - `relation_impl.rs` `get_canonical_fqn` — pass-through, correct either way.
  - `dbt-df-providers` `seed_io.rs` `infer_seed_column_name_strategy` — see the
    census below; `Verbatim` is the arm that matches how SQL Server stores an
    unquoted column name, and `Lowercase` would silently rename seed headers.
  - Catalog introspection (Part 5) compares names as strings. `column_name`
    and `data_type` carry `collate database_default`, following v1's
    `columns.sql`. The `where` predicates do not: `s.name = '...'` and
    `o.name = '...'` resolve under the database collation, so on a `_CS_`
    server a lookup of `stg_orders` will not find `STG_Orders`. That matches
    what the server itself does with an unquoted name, and matches v1, which
    compares the same way — but it is a decision, not an accident, and it
    needs a test on a case-sensitive server.

- **Identifiers built inside string literals fail silently.**
  `OBJECT_ID('schema.table')`, `sp_rename`, and catalog predicates comparing
  against a name are string-literal contexts, so identifier quoting doesn't
  apply automatically and mistakes don't raise: `OBJECT_ID` returns `NULL` for
  a schema containing a `.` or a `"`, which callers read as "does not exist".
  In v1 this skipped drop-before-create guards and made dynamic data masking a
  no-op for affected schemas (11 sites, fixed in #795). The Rust catalog module
  (Part 5) builds the same predicates. Test with a schema containing a `.`, a
  `"`, a backslash and a space — v1's `TestIndexMacros` covers all four in one
  name, `…_dom\usr.x"q`.

- **Concurrent catalog reads deadlock without `(nolock)`.** v1 hit this with
  read-only catalog lookups and temp-relation catalog DDL participating in the
  ambient transaction under concurrent incremental runs (`f0afd9f`, `75e9345`,
  `4ceca61`). Carry the hints and isolation choices into the Part 5 queries
  rather than rediscovering them against a live warehouse.

- **`STRING_AGG` sets a minimum server version.** `utils/listagg.sql` uses it,
  and it requires SQL Server 2017+. Either document the minimum supported
  version or add a `FOR XML PATH` fallback for 2016 and earlier, which is still
  common on-prem. Decide explicitly rather than leaving it implicit.

- **`QUOTED_IDENTIFIER` is a runtime dependency of Decision 1.** Measured `ON`
  by default on `go-mssqldb`, so the common path is safe; what remains is
  servers or logins that force it `OFF`, where every quoted-identifier
  statement breaks at once. That makes the smoke test in Decision 1 mandatory.

- **ADBC driver type coverage is unverified.** `adbc_driver_mssql` being
  CDN-distributed suggests maturity, but this plan hasn't checked its Arrow
  type coverage for `uniqueidentifier`, `hierarchyid`, `sql_variant`, `xml` or
  `rowversion`. Treat it as unknown until the first live smoke test, and budget
  for `column_builder.rs`/`sql_types.rs` rework if the driver surprises you.

- **v1 macro helper dependencies are assumed, not confirmed.**
  `get_query_options`, `load_cached_relation`, `make_intermediate_relation`,
  `make_backup_relation` and `get_use_database_sql` are used pervasively across
  the table/incremental/view materializations. Confirm each exists in v2's
  shared macro set before assuming a straight port; if any are missing, several
  materializations need rework rather than copying.

- **A compiling match arm is not a correct one.** Compiler-driven completeness
  guarantees no arm is *missed*; it says nothing about whether an arm copied
  from Fabric is right for SQL Server. Treat every Fabric-derived arm as a
  hypothesis to verify during smoke testing.
