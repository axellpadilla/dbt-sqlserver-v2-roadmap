---
target_repo: dbt-labs/dbt-core
type: feature
status: open
url: https://github.com/dbt-labs/dbt-core/issues/15714
labels: [type:feature, area:adapters, engine:v2]
related: ../plan/README.md
---

# [Feature] Add SQL Server adapter support (dbt Fusion / v2)

## Is this your first time submitting a feature request?

- [x] I have read the [expectations for open source contributors](https://docs.getdbt.com/docs/contributing/oss-expectations)
- [x] I have searched the existing issues, and I could not find an existing issue for this feature
- [x] I am requesting a straightforward extension of existing dbt functionality, rather than a Big Idea better suited to a discussion

## Which version of dbt is this feature for?

dbt v2.x (Fusion)

## Describe the feature

Add `AdapterType::SqlServer` support to dbt Fusion, following [Contribute a dbt Core 2.0 Adapter](https://docs.getdbt.com/guides/adapter-creation-v2).

An audit of the current codebase found SQL Server further along than a from-scratch adapter:

- `Backend::SQLServer` — ADBC driver registration is done, CDN-distributed (`crates/dbt-adbc/src/driver.rs`, `install.rs`), library `adbc_driver_mssql`.
- `crates/dbt-auth/src/sqlserver/mod.rs` — Entra/Azure AD auth flows (service principal, AD password, environment credential), done and unit-tested, dispatch wired in `crates/dbt-auth/src/lib.rs`.
- `AdapterType::SqlServer` itself isn't registered (only `Fabric` exists), so none of the above is reachable from a `profiles.yml` yet.

Scope for the initial contribution:

- **Identifier quoting**: double-quote (`quote_char = '"'`), with an embedded `"` doubled when rendering, and `SET QUOTED_IDENTIFIER ON` issued as connection-init SQL — matches the existing `Fabric` arm. dbt-sqlserver v1 standardized on the same double-quote rendering in 1.12 ([#785](https://github.com/dbt-msft/dbt-sqlserver/issues/785)), so the ported macros need no quoting rewrite.
- **Auth**: plain SQL Server authentication (native login) — the existing module only covers Entra flows, and plain SQL auth is the common on-prem mode. Windows/trusted-connection auth deferred.
- **Deferred**: dynamic data masking, index/columnstore materialization config, `full_refresh_build: prebuilt`, scalar function materializations, clone support — v1-only extras beyond the guide's minimal required-macro list, each a follow-up once the base adapter merges.
- **Validation target**: on-prem SQL Server via Docker, with Azure SQL Database as a secondary target for the Entra auth paths.

Full plan, decision log, and file-by-file checklist: https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap.

## Describe alternatives you've considered

None — SQL Server is a widely used warehouse with an active existing dbt-sqlserver v1 user base; there's no substitute for native Fusion support.

## Who will this benefit?

dbt-sqlserver v1 users migrating to Fusion. Filed by a `dbt-msft/dbt-sqlserver` maintainer (see Contributing below).

## Are you interested in contributing this feature?

Yes. Work stages on a fork branch rather than opening PRs directly against `main`: registering `AdapterType::SqlServer` breaks exhaustive `match adapter_type()` across every dependent crate, so `cargo build --bin dbt` and this repo's CI stay broken workspace-wide until every arm lands.

- **Fork**: https://github.com/dbt-sqlserver-next/dbt-core
- **Branch**: `sqlserver-v2-port`
- PRs (dbt-sqlserver v1 contributors welcome) target `dbt-sqlserver-next/dbt-core:sqlserver-v2-port`.

Execution follows the same crate-by-crate structure as the ClickHouse Fusion rollout (#14607 and its series): scoped "Part N" sub-issues, each closed by the PR that implements it. Filed on the fork (`dbt-sqlserver-next/dbt-core`), not here — `Closes #N` only auto-links within a repo, and the PRs land on `sqlserver-v2-port`, not `main` (see Contributing above), so an issue here could never actually close.

Full series (`dbt-sqlserver-next/dbt-core` issues #1–#10, indexed with links at https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap/blob/main/issues/dbt-core-sqlserver-v2-parts.md):

- Part 1 — `crates/dbt-adapter-core`: register `AdapterType::SqlServer` + `quote_char`.
- Part 2 — `crates/dbt-schemas`: `SqlServerDbConfig` + `DbConfig::SqlServer`.
- Part 3 — `crates/dbt-auth`: extend `sqlserver/` module — plain SQL auth, TLS/`encrypt` params (porting from v1's experimental ADBC backend, which talks to the same driver), `SET QUOTED_IDENTIFIER ON` init SQL (defensive — v1 measured it already `ON` by default on `go-mssqldb`).
- Parts 4–7 — `crates/dbt-adapter`: relation quoting & factory, catalog introspection, SQL type mapping & column builder, adapter behavior match arms (mirroring `Fabric` where applicable) — independent of each other, run in any order once Part 1 lands.
- Part 8 — `crates/dbt-loader`: `dbt_macro_assets/dbt-sqlserver/` macro package, ported from the v1 Jinja macros.
- Part 9 (optional) — `crates/dbt-init`: interactive profile wizard.
- Part 10 — end-to-end validation: jaffle-shop smoke test, changelog, CI coordination. Closing it triggers the actual PR(s) against `dbt-labs/dbt-core:main`, closing this issue.

Each step: `cargo build -p <crate>` / `cargo test -p <crate>`. End-to-end: a real `dbt build` against a local SQL Server container and [jaffle-shop](https://github.com/dbt-labs/jaffle-shop), the guide's acceptance bar.

## Anything else?

Precedent for this shape of contribution:

- #14373 (AWS Glue) — same pattern: v1 adapter maintainer proposing Fusion support, with partial `AdapterType`/`Backend` wiring already prototyped.
- #14607 and series (ClickHouse) — dbt Labs' own Fusion adapter rollout, structured as numbered "Part N" issues with scoped work-item checklists, each closed by specific PRs. That implementation lives in a private `dbt-labs/fs` repo with dbt-core issues as the public tracker — not available to external contributors, which is why this proposal stages on a public fork instead.
- #13131 / #13822 (Trino/Starburst, Athena) — dbt Labs-initiated tracking issues for adapters already partially wired in Fusion; useful context on the adapter-completion process, though initiated differently from this one.

Will loop in `#adapter-ecosystem` on the [dbt Community Slack](https://community.getdbt.com/) for warehouse-credential CI coordination (guide's Step 6) once ready for review.
