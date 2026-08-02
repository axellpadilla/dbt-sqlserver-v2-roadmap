---
target_repo: dbt-sqlserver-next/dbt-core
type: tracking-series
status: open
parent: https://github.com/dbt-labs/dbt-core/issues/15714
related: ../plan/02-implementation-steps.md
---

# SQL Server Fusion adapter: "Part N" sub-issue series

Mirrors the structure of the ClickHouse Fusion rollout
([#14607](https://github.com/dbt-labs/dbt-core/issues/14607) and its
series) referenced in dbt-labs/dbt-core#15714.

## Why these live on the fork, not on `dbt-labs/dbt-core`

Originally drafted against `dbt-labs/dbt-core` (same repo as #15714), but
that's wrong for two reasons:

- GitHub's `Closes #N` auto-linking only works within a single repo. The
  PRs implementing each part get opened against
  `dbt-sqlserver-next/dbt-core:sqlserver-v2-port` (the work can't land on
  upstream `main` piecemeal — see `plan/README.md` "Branching strategy"),
  so an issue on `dbt-labs/dbt-core` could never actually be closed by them.
- Filing 10 granular WIP tickets on dbt-core's public tracker for work
  that isn't mergeable there yet is noise on someone else's repo. `#15714`
  is the one thing that belongs there — a single public touchpoint.

So all 10 are issues on `dbt-sqlserver-next/dbt-core`, cross-linked to
`dbt-labs/dbt-core#15714` via plain references (not native sub-issues,
since that link crosses repos/orgs).

Numbering starts at Part 1, not Part 0, because ADBC driver registration
(what ClickHouse's Part 0 covered) is already done for SQL Server — see
`plan/00-current-state.md` §2. Sequence is strict through Part 3 (each
unlocks the next crate's compiler errors); Parts 4–7 can happen in any
order once Parts 1–3 land.

## The series

| Part | Issue | Crate | Depends on |
|---|---|---|---|
| 1 | [dbt-sqlserver-next/dbt-core#1](https://github.com/dbt-sqlserver-next/dbt-core/issues/1) — register `AdapterType::SqlServer` | `dbt-adapter-core` | — |
| 2 | [dbt-sqlserver-next/dbt-core#2](https://github.com/dbt-sqlserver-next/dbt-core/issues/2) — `SqlServerDbConfig` | `dbt-schemas` | #1 |
| 3 | [dbt-sqlserver-next/dbt-core#3](https://github.com/dbt-sqlserver-next/dbt-core/issues/3) — plain SQL auth, TLS params, `QUOTED_IDENTIFIER` init | `dbt-auth` | #2 |
| 4 | [dbt-sqlserver-next/dbt-core#4](https://github.com/dbt-sqlserver-next/dbt-core/issues/4) — relation quoting (incl. escaping an embedded `"`) & factory | `dbt-adapter` | #1 |
| 5 | [dbt-sqlserver-next/dbt-core#5](https://github.com/dbt-sqlserver-next/dbt-core/issues/5) — catalog introspection | `dbt-adapter` | #1 |
| 6 | [dbt-sqlserver-next/dbt-core#6](https://github.com/dbt-sqlserver-next/dbt-core/issues/6) — SQL type mapping & column builder | `dbt-adapter` | #1 |
| 7 | [dbt-sqlserver-next/dbt-core#7](https://github.com/dbt-sqlserver-next/dbt-core/issues/7) — `adapter_impl.rs` match arms | `dbt-adapter` | #1 |
| 8 | [dbt-sqlserver-next/dbt-core#8](https://github.com/dbt-sqlserver-next/dbt-core/issues/8) — Jinja macro package | `dbt-loader` | #1–#7 |
| 9 | [dbt-sqlserver-next/dbt-core#9](https://github.com/dbt-sqlserver-next/dbt-core/issues/9) — `dbt init` profile wizard (optional) | `dbt-init` | #2 |
| 10 | [dbt-sqlserver-next/dbt-core#10](https://github.com/dbt-sqlserver-next/dbt-core/issues/10) — jaffle-shop smoke test, changelog | — | #1–#8 |

Part 10 closing is what triggers opening the actual PR(s) against
`dbt-labs/dbt-core:main`, closing #15714.
