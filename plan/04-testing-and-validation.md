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
minimum. For SQL Server specifically, plan for **multiple target flavors**
since "SQL Server" isn't one homogeneous product:

| Target | Why it matters | How to get one |
|---|---|---|
| SQL Server on Linux/Windows (Docker) | On-prem parity, tests plain SQL auth + TLS/encrypt gap from `02-implementation-steps.md` §5.4 | `make test-env && make server` from the workspace root — reuses `dbt-sqlserver/docker-compose.yml`/`make server` directly rather than duplicating that setup; see the Makefile |
| Azure SQL Database | Tests Entra auth flows already implemented in `dbt-auth/src/sqlserver/mod.rs` | Requires an Azure subscription — coordinate with dbt Labs per the CI section below if no personal subscription is available |
| Azure SQL Managed Instance | Closest to on-prem behavior but Azure-hosted; edge cases around cross-database queries | Same as above |

```bash
cargo build --bin dbt
./target/debug/dbt init                 # generate/select sqlserver profile (once 5.3.1 lands)
./target/debug/dbt build --project-dir <your-project>
```

**Acceptance bar** (per the guide): a clean `dbt build` against
[jaffle-shop](https://github.com/dbt-labs/jaffle-shop). Port/adjust jaffle-shop
seeds and models as needed for SQL Server type/syntax differences (e.g.
`STRING_AGG` version requirements noted in `03-macros-porting-map.md`).

### SQL Server-specific smoke test matrix (beyond the guide's generic list)

- [ ] `dbt seed` — CSV load path; verify against the `seed_io.rs` reference
  found during the audit (`00-current-state.md` §6) before assuming Jinja-only
  seed macros are sufficient.
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
  identifiers, and a session where `QUOTED_IDENTIFIER` defaults to `OFF`
  (confirming the init SQL actually overrides it) — this is the highest-risk
  area since it's a deliberate v1/v2 behavior divergence.
- [ ] Each implemented auth mode individually: service principal, AD
  password, environment credential, and plain SQL auth — one `profiles.yml`
  target per mode, each run through a full `dbt build`.
- [ ] TLS/encrypt behavior against a self-signed on-prem instance (validates
  the `encrypt`/`TrustServerCertificate`-equivalent gap fix).
- [ ] Long-running/large incremental `MERGE` — validate generated T-SQL
  against SQL Server's actual `MERGE` syntax constraints (stricter than some
  other warehouses about statement termination, output clauses).

## 3. CI coordination (per the guide — do not skip)

Community contributors **cannot run dbt Labs' CI independently** for warehouse
validation; this is an explicit known gap in the guide, not something to work
around locally.

1. Once the PR is ready for warehouse validation, post in `#adapter-ecosystem`
   on the [dbt Community Slack](https://community.getdbt.com/).
2. Tag **Hope Watson (dbt Labs)**.
3. Expect coordination/back-and-forth — the handoff process is still being
   defined by dbt Labs as of the guide's writing.
4. Align beforehand (per Step 8 of the guide) on: which materializations are
   targeted in the initial PR, known ADBC driver gaps
  (`adbc_driver_mssql` limitations, if any are discovered during smoke
   testing), and rough timeline — this avoids surprises during review.

## 4. Regression check against v1 behavior (project-specific addition)

Since a working v1 Python adapter (`dbt-sqlserver/`) exists in this workspace
with its own test suite (`dbt-sqlserver/tests/`, `pytest.ini`), use it as a
behavioral oracle where useful:

- [ ] Skim `dbt-sqlserver/tests/` for integration test fixtures/models that
  encode known-tricky SQL Server behavior (e.g. quoting edge cases,
  MERGE edge cases) and mirror them in the v2 smoke-test project rather than
  inventing new test cases from scratch.
- [ ] Do **not** port the v1 pytest suite structure itself — v2's testing
  approach is `cargo test` (Rust unit tests) + `dbt build`-based smoke/e2e
  testing coordinated with dbt Labs' CI, not a standalone pytest adapter
  test suite (that infrastructure has no v2 equivalent per the guide's
  "what doesn't exist in v2" list).
