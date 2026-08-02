# 04 — Testing & Validation

Source: https://docs.getdbt.com/guides/adapter-creation-v2 (Step 6), plus
SQL Server-specific additions given the auth/quoting decisions in this plan.

## 1. Type-checking gate (run after every crate, not just at the end)

```bash
cd dbt-core
cargo build -p dbt-adapter-core
cargo build -p dbt-adbc          # (guide's dbt-xdbc — see naming note in 00-current-state.md)
cargo build -p dbt-schemas
cargo build -p dbt-auth
cargo build -p dbt-adapter
cargo build -p dbt-loader
cargo build --bin dbt
```

Treat every compiler error as one checklist item (see `02-implementation-steps.md`).
Do not move to the next crate with outstanding errors in the current one —
downstream crates depend on the earlier ones compiling cleanly.

Also run the existing unit tests for touched crates, since `dbt-auth`
already has SQL Server tests that must keep passing after you extend the
auth module:

```bash
cargo test -p dbt-auth sqlserver
cargo test -p dbt-adapter
cargo test -p dbt-schemas
```

## 2. Smoke testing against a real SQL Server instance

Per the guide: exercise table, view, incremental, and seed materializations at
minimum. "SQL Server" isn't one product, so the targets are ranked (`05` #5):

| Target | Priority | Why it matters | How to get one |
|---|---|---|---|
| SQL Server on Linux/Windows (Docker) | **Primary** | Where most v1 users are; exercises plain SQL auth and the TLS/encrypt work in `02-implementation-steps.md` §5.4 | `make test-env && make server` from the workspace root, reusing `dbt-sqlserver/docker-compose.yml` |
| Azure SQL Database | Secondary | Exercises the Entra auth flows already implemented in `dbt-auth/src/sqlserver/mod.rs` | Needs an Azure subscription — coordinate with dbt Labs per §3 if there's no personal one |
| Azure SQL Managed Instance | Not targeted | Azure-hosted but closest to on-prem; edge cases around cross-database queries | — |

```bash
cargo build --bin dbt
./target/debug/dbt init                 # generate/select sqlserver profile (once 5.3.1 lands)
./target/debug/dbt build --project-dir <your-project>
```

**Acceptance bar** (per the guide): a clean `dbt build` against
[jaffle-shop](https://github.com/dbt-labs/jaffle-shop). Port/adjust jaffle-shop
seeds and models as needed for SQL Server type/syntax differences (e.g.
`STRING_AGG` version requirements noted in `03-macros-porting-map.md`).

If the test project pulls in dbt packages, they need Fusion compatibility of
their own — `require-dbt-version` including `2.0.0`, per the
[package compatibility guide](https://docs.getdbt.com/guides/fusion-package-compat).
A package that excludes it warns today and errors later, so a failure there is
the package's, not the adapter's. `dbt_utils`, `audit_helper`,
`dbt_external_tables` and `dbt_project_evaluator` are already compatible.

### SQL Server-specific smoke test matrix (beyond the guide's generic list)

- [ ] `dbt seed` — CSV load path. Seed loading is Rust, not Jinja:
  `crates/dbt-df-providers/src/seed_io.rs` (380 lines) matches on
  `AdapterType` at line ~233 to pick a column-name inference strategy
  (Fabric groups with Bigquery/Databricks/Spark; Snowflake uppercases).
  Choose SQL Server's arm deliberately — its default collation is
  case-insensitive — and test round-tripping mixed-case seed headers.
- [ ] `dbt run` — table, view, incremental (all supported strategies:
  `append`, `delete+insert`, `merge`, `microbatch` per the `Fabric` parity
  assumption in `02-implementation-steps.md`).
- [ ] `dbt snapshot` — timestamp and check strategies.
- [ ] `dbt test` — generic + singular tests, unit tests
  (`get_fixture_sql.sql`/`unit_test_create_table_as.sql` from the porting map).
- [ ] Schema/database create-if-not-exists idempotency (`create_schema` uses
  `sys.schemas` existence check in v1 — confirm the v2 port preserves this,
  since re-running `dbt build` shouldn't fail on existing schemas).
- [ ] Identifier quoting edge cases under the decided double-quote scheme
  (`05-open-questions-and-risks.md` #1): reserved words, mixed-case
  identifiers, a name containing a `"` (must render doubled, `"ab""cd"`), a
  schema containing a `.` or a backslash (the string-literal and index-name
  failures v1 fixed in #795 — `dbt-sqlserver`'s `TestIndexMacros` covers all
  of these in one schema name, `…_dom\usr.x"q`, worth copying), and a session
  where `QUOTED_IDENTIFIER` defaults to `OFF` (confirming the init SQL
  overrides it). No longer a v1/v2 divergence — v1 renders identifiers the
  same way as of 1.12 — but still the highest-risk area, because the failures
  are silent rather than loud.
- [ ] Each implemented auth mode individually: service principal, AD
  password, environment credential, and plain SQL auth — one `profiles.yml`
  target per mode, each run through a full `dbt build`.
- [ ] TLS/encrypt behavior against a self-signed on-prem instance (validates
  the `encrypt`/`TrustServerCertificate`-equivalent gap fix).
- [ ] Long-running/large incremental `MERGE` — validate generated T-SQL
  against SQL Server's actual `MERGE` syntax constraints (stricter than some
  other warehouses about statement termination, output clauses).
- [ ] Behaviors v2 changes for every adapter, which the smoke-test project
  should assert rather than inherit assumptions about
  ([upgrade guide](https://docs.getdbt.com/docs/dbt-versions/core-upgrade/upgrading-to-v2?version=2.0)):
  unit tests running before the rest of the DAG in `dbt build`, compile
  continuing past an error to unrelated DAG nodes, and a seed with trailing
  commas no longer producing an extra column.

### Cheap early signal: the v1.12 v2 parser

Before any Rust work, `dbt parse --use-v2-parser` runs v2's Rust parser against
the existing Python adapter, surfacing project/macro/manifest incompatibilities
(the parse-time strictness in `03-macros-porting-map.md`) without needing the
adapter to exist in v2 at all. That's what
[dbt-msft/dbt-sqlserver#770](https://github.com/dbt-msft/dbt-sqlserver/issues/770)
tracks. `uvx dbt-autofix deprecations` mechanically clears the YAML-side
deprecations that v2 rejects.

## 3. CI coordination

Community contributors can't run dbt Labs' CI for warehouse validation. The
guide names this as a known gap, so it's a coordination step, not something to
route around locally.

1. Once the PR is ready for warehouse validation, post in `#adapter-ecosystem`
   on the [dbt Community Slack](https://community.getdbt.com/).
2. Tag **Hope Watson (dbt Labs)**.
3. Expect coordination/back-and-forth — the handoff process is still being
   defined by dbt Labs as of the guide's writing.
4. Align beforehand (per Step 8 of the guide) on: which materializations are
   targeted in the initial PR, known ADBC driver gaps
  (`adbc_driver_mssql` limitations, if any are discovered during smoke
   testing), and rough timeline — this avoids surprises during review.

## 4. Regression check against v1 behavior

The v1 Python adapter and its test suite (`dbt-sqlserver/tests/`) are a
behavioral oracle:

- [ ] Mine `dbt-sqlserver/tests/` for fixtures encoding known-tricky SQL Server
  behavior — quoting edge cases, MERGE edge cases — and mirror them in the v2
  smoke-test project instead of inventing equivalents.
- [ ] Don't port the pytest suite structure itself. v2 tests with `cargo test`
  plus `dbt build`-based smoke/e2e runs coordinated with dbt Labs' CI; a
  standalone pytest adapter suite has no v2 equivalent (per the guide's
  "what doesn't exist in v2" list).
