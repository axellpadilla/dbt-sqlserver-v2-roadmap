# dbt-sqlserver on dbt Core v2 (Fusion / Rust engine) — Implementation Plan

Root plan for porting the community **dbt-sqlserver** adapter (currently a
standalone v1 Python package at [`dbt-sqlserver/`](../dbt-sqlserver)) into
**dbt Core v2.0**, the Rust monorepo checked out at [`dbt-core/`](../dbt-core).

This plan follows the official contribution guide:

- **Guide**: https://docs.getdbt.com/guides/adapter-creation-v2
- **Target repo (upstream)**: https://github.com/dbt-labs/dbt-core (local checkout: `dbt-core/`)
- **Working fork + integration branch**: https://github.com/dbt-sqlserver-next/dbt-core,
  branch `sqlserver-v2-port`. All contributor work lands here first, not
  directly on upstream `main` — see "Branching strategy" below for why.
- **v1 source to port from**: https://github.com/dbt-msft/dbt-sqlserver (local checkout: `dbt-sqlserver/`)
- **ADBC driver (already exists, CDN-distributed)**: `adbc_driver_mssql`, built on
  [microsoft/go-mssqldb](https://github.com/microsoft/go-mssqldb)
- **Same driver, working reference implementation**: `dbt-sqlserver/` (v1) just
  merged [PR #783 "Add experimental ADBC backend"](https://github.com/dbt-msft/dbt-sqlserver/pull/783)
  (commit `bca9e3e`, now `master`'s tip), which connects to `adbc_driver_mssql`
  via the identical `sqlserver://` URI scheme v2 uses. Its
  `sqlserver_backend.py`/`sqlserver_credentials.py` are a working, merged
  oracle for connection-parameter details (`encrypt`, `TrustServerCertificate`,
  `connection timeout`, named-instance handling) that v2's
  `crates/dbt-auth/src/sqlserver/mod.rs` still has as open `// TODO`s — see
  `00-current-state.md` §3.
- **Reference adapter for T-SQL family patterns**: Microsoft Fabric
  (`AdapterType::Fabric`), already implemented in this checkout — Fabric Warehouse
  and SQL Server share the T-SQL dialect and the same `go-mssqldb`/ADBC wire driver,
  so most of the Rust match arms can be written as a sibling of the `Fabric` arm
  rather than from scratch.
- **v1 Python adapter reference**: [dbt-fabric](https://github.com/microsoft/dbt-fabric)
  (already cited in-repo as the source for auth semantics) and
  [dbt-msft/dbt-sqlserver](https://github.com/dbt-msft/dbt-sqlserver) (this repo's
  `dbt-sqlserver/` checkout) for macro/catalog SQL to port.

## Why this is smaller than a from-scratch adapter

A repo audit (see [`00-current-state.md`](00-current-state.md)) found that SQL Server
is **already partially wired up** in dbt-core v2:

| Piece | Status | Evidence |
|---|---|---|
| ADBC driver registration (`Backend::SQLServer`) | ✅ Done, CDN-distributed | `crates/dbt-adbc/src/driver.rs:78`, `crates/dbt-adbc/src/install.rs` |
| Auth module (`crates/dbt-auth/src/sqlserver/mod.rs`) | ✅ Mostly done (337 lines, tested) | Service principal, AD password, environment auth implemented; interactive/CLI/integrated auth stubbed as `unimplemented!()`; connection-param gaps (`encrypt`, `TrustServerCertificate`, `connection timeout`) have a direct, working reference to port from — v1's PR #783 (same driver) |
| Auth dispatch wiring | ✅ Done | `crates/dbt-auth/src/lib.rs:93` (`Backend::SQLServer => sqlserver::SQLServerAuth`) |
| `AdapterType::SqlServer` enum variant | ❌ Missing | Not present in `crates/dbt-adapter-core/src/lib.rs` (only `Fabric` exists) |
| `DbConfig::SqlServer` profile struct | ❌ Missing (commented placeholder only) | `crates/dbt-schemas/src/schemas/profiles.rs:46` — `// SqlServer,` |
| Adapter layer match arms (relations, catalog, columns, SQL types) | ❌ Missing | `crates/dbt-adapter/src/**` has `Fabric` arms only |
| Jinja macros (`dbt_macro_assets/dbt-sqlserver/`) | ❌ Missing | Only `dbt-fabric/` and `dbt-fabricspark/` exist |
| `dbt init` interactive profile setup | ❌ Missing (optional) | `crates/dbt-init/src/adapter_config/fabric_config.rs` is the pattern to copy |

**Net effect:** this is closer to Step 5.1/5.3/5.5/5.6 of the guide than the full
13-file greenfield checklist — the credential/connection layer (Steps 5.2 and half
of 5.4) is already merged. The remaining work is registering the adapter type,
the profile config struct, the Rust adapter-layer match arms, and the SQL macros.

## Plan structure

This plan is split into files because the full scope doesn't fit comfortably in
one document:

1. [`00-current-state.md`](00-current-state.md) — detailed audit of what exists today in `dbt-core/` and what needs porting from `dbt-sqlserver/`, with file:line references.
2. [`01-architecture-and-prerequisites.md`](01-architecture-and-prerequisites.md) — v2 architecture recap, SQL Server-specific warehouse knowledge needed, dev machine setup.
3. [`02-implementation-steps.md`](02-implementation-steps.md) — the ordered, file-by-file implementation checklist (the guide's Step 5, made concrete for SQL Server).
4. [`03-macros-porting-map.md`](03-macros-porting-map.md) — table mapping every v1 Jinja macro in `dbt-sqlserver/dbt/include/sqlserver/macros/` to its v2 destination and porting notes.
5. [`04-testing-and-validation.md`](04-testing-and-validation.md) — type-checking, smoke testing, jaffle-shop acceptance bar, CI coordination process, SQL Server-specific test matrix (auth modes, on-prem vs Azure SQL DB vs Azure SQL MI vs Fabric-adjacent).
6. [`05-open-questions-and-risks.md`](05-open-questions-and-risks.md) — decisions that need a human call before/during implementation, plus known risk areas.

## Branching strategy

Registering `AdapterType::SqlServer` (Step 5.1) breaks every exhaustive
`match adapter_type()` block across every crate depending on
`dbt-adapter-core` — `cargo build --bin dbt` and dbt-core's CI fail
workspace-wide until all arms are filled in. Never merge that to
`dbt-labs/dbt-core:main` piecemeal.

- **Fork**: https://github.com/dbt-sqlserver-next/dbt-core
- **Integration branch**: `sqlserver-v2-port`
- PRs (including from dbt-sqlserver contributors) target
  `dbt-sqlserver-next/dbt-core:sqlserver-v2-port`.
- Once the full vertical slice (`02-implementation-steps.md` §5.1–5.6)
  builds clean, tests pass, and it clears the jaffle-shop smoke test
  (`04-testing-and-validation.md`), it goes upstream as one PR (or a tight
  same-day sequence) to `dbt-labs/dbt-core:main`.
- The branch periodically merges upstream `main`.

## Why `dbt-core/` and `dbt-sqlserver/` aren't submodules

Both are `.gitignore`d in the root workspace repo and cloned via the root
`Makefile` (`make setup`) instead of being tracked as git submodules. This
was revisited once the workspace repo went public and started acting as a
shared coordination point (`issues/`, this plan) — submodules would give
collaborators a reproducible pinned checkout, which sounds like exactly what
a public collaboration repo should want. Two things outweigh that:

- **The audience for `plan/` mostly doesn't need the code checked out at
  all.** Submodules add mandatory `git submodule update --init` friction to
  a repo whose primary use is "read the roadmap."
- **Both repos are actively being patched, not consumed as frozen
  dependencies.** Commits get pushed to forks of `dbt-core`/`dbt-sqlserver`
  as implementation work happens; a submodule pointer would need bumping on
  every such push, on both repos — exactly the overhead a plain `git clone`
  avoids. The `Makefile`'s `DBT_CORE_URL`/`DBT_SQLSERVER_URL` overrides let
  anyone point their local clone at a fork/branch without touching this
  repo's history at all.

Where reproducibility genuinely matters — e.g. "this audit was performed
against exactly this commit" in `00-current-state.md` — it's recorded as a
commit hash in prose instead. That doesn't need git to enforce it; if the
audit goes stale as upstream moves, the fix is re-auditing and bumping the
cited hash, not switching to submodules.

## Suggested execution order

Steps 1–4 in `02-implementation-steps.md` are strictly ordered (each unlocks the
next crate's compiler errors). Within Step 4 (the adapter crate) and Step 5
(macros), work can proceed in parallel once the `AdapterType::SqlServer` variant
and `DbConfig::SqlServer` struct exist, since after that point `cargo build -p
dbt-adapter` becomes the todo list generator described in the guide's "Compiler-
Driven Completeness" section.

Read `01` and `05` before writing any code — several SQL Server–specific decisions
(2-part vs 3-part naming, quoting, auth surface) need to be locked in first because
they're load-bearing for almost every later file.
