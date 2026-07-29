---
target_repo: dbt-labs/dbt-core
type: tracking
status: draft
related: ../plan/README.md
---

# Community adapter: SQL Server support for dbt Core v2.0

## Summary

Tracking issue for a community contribution adding `AdapterType::SqlServer`
support to dbt Core v2.0, following the
[Contribute a dbt Core 2.0 Adapter](https://docs.getdbt.com/guides/adapter-creation-v2)
guide.

Registering `AdapterType::SqlServer` breaks exhaustive `match adapter_type()`
across every dependent crate, so `cargo build --bin dbt` and this repo's CI
stay broken workspace-wide until every arm lands. Work stages on a fork
branch first, opened here only once it's whole:

- **Fork**: https://github.com/dbt-sqlserver-next/dbt-core
- **Branch**: `sqlserver-v2-port`
- PRs (dbt-sqlserver v1 contributors welcome) target
  `dbt-sqlserver-next/dbt-core:sqlserver-v2-port`.
- Comes here as one PR (or a tight sequence) once the full slice builds
  clean, tests pass, and the jaffle-shop smoke test below clears.

Full plan and file-by-file checklist:
**https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap**.

## What's already in place

SQL Server is further along than a from-scratch adapter would be:

- `Backend::SQLServer` — ADBC driver registration is **done**,
  CDN-distributed (`crates/dbt-adbc/src/driver.rs`, `install.rs`), library
  `adbc_driver_mssql`.
- `crates/dbt-auth/src/sqlserver/mod.rs` — Entra/Azure AD auth flows
  (service principal, AD password, environment credential) are **done and
  unit-tested**, dispatch wired in `crates/dbt-auth/src/lib.rs`.

What's missing: `AdapterType::SqlServer` itself isn't registered yet (only
`Fabric` exists), so none of the above is reachable from a `profiles.yml`
today.

## Scope for the initial PR

- **Identifier quoting**: double-quote (`quote_char = '"'`) with
  `SET QUOTED_IDENTIFIER ON` enforced as connection-init SQL — matches the
  existing `Fabric` arm exactly, so this follows established precedent
  rather than introducing a new pattern. Not bracket quoting (which the v1
  Python adapter uses).
- **Auth**: adding plain SQL Server authentication (native login,
  username/password, no Entra) — the existing auth module only covers Entra
  flows, and plain SQL auth is the most common on-prem mode. Windows/
  trusted-connection auth is deferred to a follow-up.
- **Deferred to follow-ups**: dynamic data masking, index/columnstore
  materialization config, the `full_refresh_build: prebuilt` optimization,
  scalar function materializations, and clone support — v1-only extras
  beyond the guide's minimal required-macro list. Each will get its own
  tracked follow-up once the base adapter is merged, rather than growing
  this PR's scope.
- **Primary validation target**: on-prem SQL Server via Docker (matches most
  existing dbt-sqlserver v1 users), with Azure SQL Database as a secondary
  target for the already-implemented Entra auth paths.

## Plan

1. `crates/dbt-adapter-core` — register `AdapterType::SqlServer` + `quote_char`.
2. `crates/dbt-schemas` — `SqlServerDbConfig` + `DbConfig::SqlServer`.
3. `crates/dbt-auth` — extend `sqlserver/` module: plain SQL auth, TLS/
   `encrypt` params (porting directly from v1's just-merged experimental ADBC
   backend, which talks to the same driver), `SET QUOTED_IDENTIFIER ON` init SQL.
4. `crates/dbt-adapter` — relation quoting, catalog introspection, column
   builder, SQL type mapping, adapter behavior match arms (mirroring `Fabric`
   where applicable).
5. `crates/dbt-loader` — `dbt_macro_assets/dbt-sqlserver/` macro package,
   ported from the v1 Python adapter's Jinja macros.

Each step is validated with `cargo build -p <crate>` / `cargo test -p <crate>`
before moving to the next. End-to-end validation is a real `dbt build`
against a local SQL Server container and
[jaffle-shop](https://github.com/dbt-labs/jaffle-shop), the guide's
acceptance bar.

Will loop in `#adapter-ecosystem` on the
[dbt Community Slack](https://community.getdbt.com/) for warehouse-credential
CI coordination (per the guide's Step 6) once the PR is ready for review.
