---
target_repo: dbt-labs/dbt-core
type: tracking-series
status: draft
parent: https://github.com/dbt-labs/dbt-core/issues/15714
related: ../plan/02-implementation-steps.md
---

# SQL Server Fusion adapter: "Part N" sub-issue series

Mirrors the structure of the ClickHouse Fusion rollout
([#14607](https://github.com/dbt-labs/dbt-core/issues/14607) and its
series) referenced in #15714. Each part is one crate-scoped unit of work,
opened as its own issue once work on it actually starts (not all at once —
opening all 10 upfront before any work exists would be the same "commented
but not real" problem #15714 had). This file is the draft for that series;
nothing here is live yet.

Numbering starts at Part 1, not Part 0, because ADBC driver registration
(what ClickHouse's Part 0 covered) is already done for SQL Server — see
`plan/00-current-state.md` §2. Sequence is strict through Part 3 (each
unlocks the next crate's compiler errors); Parts 4–7 within `dbt-adapter`
can happen in any order once Parts 1–3 land, since the compiler enumerates
all of them independently once `AdapterType::SqlServer` exists.

All work happens on `dbt-sqlserver-next/dbt-core:sqlserver-v2-port`, PRs
against that branch, not upstream `main` — see #15714 / `plan/README.md`
("Branching strategy") for why.

---

## Part 1 — `dbt-adapter-core`: register `AdapterType::SqlServer`

**Title**: `feat(sqlserver): Part 1 — register AdapterType::SqlServer`

**Body**:

Part of #15714.

Registers the adapter type itself. Nothing downstream is reachable until
this lands — every other part depends on it, and it's also what turns every
unhandled `match adapter_type()` in the rest of the codebase into a compile
error, which is how the remaining parts get their scope.

Work items:
- [ ] Add `SqlServer` to the `AdapterType` enum in
  `crates/dbt-adapter-core/src/lib.rs` (next to `Fabric`)
- [ ] Add `quote_char` arm: `SqlServer => '"'` (matches `Fabric`'s existing
  arm — decision recorded in roadmap `plan/05-open-questions-and-risks.md` #1)
- [ ] `cargo build -p dbt-adapter-core`

Full detail: roadmap `plan/02-implementation-steps.md` §5.1.

---

## Part 2 — `dbt-schemas`: `SqlServerDbConfig` + `DbConfig::SqlServer`

**Title**: `feat(sqlserver): Part 2 — SqlServerDbConfig`

**Body**:

Part of #15714. Depends on Part 1.

Adds the `profiles.yml` config surface.

Work items:
- [ ] Define `SqlServerDbConfig` struct in
  `crates/dbt-schemas/src/schemas/profiles.rs`, cross-referencing
  `FabricDbConfig`, what `crates/dbt-auth/src/sqlserver/mod.rs` already
  reads via `config.get_str`/`require_str`, and v1's
  `sqlserver_credentials.py`
- [ ] Include plain SQL auth fields (`user`/`UID`, `password`/`PWD`) —
  decided in scope, not deferred (roadmap `plan/05-open-questions-and-risks.md` #2)
- [ ] Uncomment/fix the `// SqlServer,` placeholder → `SqlServer(Box<SqlServerDbConfig>)`
- [ ] `cargo build -p dbt-schemas`, follow every resulting error

Full detail: roadmap `plan/02-implementation-steps.md` §5.3.

---

## Part 3 — `dbt-auth`: extend `sqlserver/` module

**Title**: `feat(sqlserver): Part 3 — plain SQL auth, TLS params, QUOTED_IDENTIFIER init`

**Body**:

Part of #15714. Depends on Part 2.

Most of this module already exists and is unit-tested (Entra flows). This
part is additive, not a rewrite.

Work items:
- [ ] Add plain SQL auth (`SQLServerAuthIR` variant + `parse_auth` branch,
  maps straight to URI userinfo like v1's ADBC backend does)
- [ ] Fill in `apply_connection_args` TODOs — `encrypt`, `TrustServerCertificate`,
  `connection timeout` — porting values/defaults directly from
  `dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_backend.py:367-401`
  (same driver, already solved there — see roadmap `plan/00-current-state.md` §3)
- [ ] `src/init.rs` — `SET QUOTED_IDENTIFIER ON` connection-init SQL
  (required, not optional — consequence of the Part 1 quoting decision)
- [ ] Unit tests alongside existing ones in `sqlserver/mod.rs`

Full detail: roadmap `plan/02-implementation-steps.md` §5.4.

---

## Part 4 — `dbt-adapter`: relation quoting & factory

**Title**: `feat(sqlserver): Part 4 — relation quoting and factory wiring`

**Body**:

Part of #15714. Depends on Part 1 (can run in parallel with Parts 5–7).

Work items:
- [ ] `src/relation/relation_impl.rs` — `include_policy` match, db/schema/identifier
  string-formatting arms, constructor (mirror `Fabric`'s arms)
- [ ] `src/relation/factory.rs` — `create_static_relation` match

Full detail: roadmap `plan/02-implementation-steps.md` §5.5 ("Relation type
& quoting", "Relation factory").

---

## Part 5 — `dbt-adapter`: catalog introspection

**Title**: `feat(sqlserver): Part 5 — catalog introspection (get_relation, metadata module)`

**Body**:

Part of #15714. Depends on Part 1 (can run in parallel with Parts 4, 6, 7).

Work items:
- [ ] `src/metadata/get_relation.rs` — `AdapterType::SqlServer => sqlserver_get_relation(...)` arm
- [ ] New `src/metadata/sqlserver/mod.rs`, modeled on `src/metadata/fabric/mod.rs`
  (346 lines), cross-checked against v1's `catalog.sql`/`metadata.sql` for
  anything Fabric's module doesn't need but classic SQL Server does (index
  metadata via `sys.indexes`/`sys.index_columns`)

Full detail: roadmap `plan/02-implementation-steps.md` §5.5 ("Catalog introspection").

---

## Part 6 — `dbt-adapter`: SQL type mapping & column builder

**Title**: `feat(sqlserver): Part 6 — SQL type mapping and column builder`

**Body**:

Part of #15714. Depends on Part 1 (can run in parallel with Parts 4, 5, 7).

Work items:
- [ ] `src/sql_types.rs` — `SqlServer` arms wherever `Fabric` appears; verify
  each against actual SQL Server T-SQL types rather than assuming Fabric
  parity (real surface differences exist, e.g. VARCHAR/row-size limits)
- [ ] Metadata SQL type key arm (mirrors `FABRIC_METADATA_SQL_TYPE_KEY`)
- [ ] Review INTERVAL/ARRAY unimplemented arms — SQL Server also lacks
  both, likely directly reusable
- [ ] `src/column/column_builder.rs` — `SqlServer` arm, try
  `build_postgres_like` first per the guide's default recommendation

Full detail: roadmap `plan/02-implementation-steps.md` §5.5 ("SQL type
mapping", "Column builder").

---

## Part 7 — `dbt-adapter`: adapter behavior match arms

**Title**: `feat(sqlserver): Part 7 — adapter_impl.rs match arms`

**Body**:

Part of #15714. Depends on Part 1 (can run in parallel with Parts 4–6).

`adapter_impl.rs` has 44 `Fabric` occurrences across ~15 functions today;
expect a comparable number of new `SqlServer` arms once the compiler
enumerates them post–Part 1. This is the largest part by arm count, though
most are 1–2 lines each (mirror `Fabric` or `unimplemented!()`).

Work items:
- [ ] `valid_incremental_strategies` — likely direct copy of Fabric's
  `&[Append, DeleteInsert, Merge, Microbatch]`
- [ ] `list_schemas_inner` schema column name
- [ ] `get_adbc_execute_options`
- [ ] `get_constraint_support`, `alter_table_add_columns`, `is_replaceable`,
  `truncate_relation`, grants (`grant_access_to`, `standardize_grants_dict`),
  `metadata_adapter`
- [ ] `unimplemented!()` for anything SQL Server genuinely doesn't support
  (explicitly fine for an initial contribution per the guide)
- [ ] `cargo build -p dbt-adapter` repeatedly until clean

Full detail: roadmap `plan/02-implementation-steps.md` §5.5 ("Adapter
behavior match arms").

---

## Part 8 — `dbt-loader`: SQL macro package

**Title**: `feat(sqlserver): Part 8 — dbt-sqlserver Jinja macro package`

**Body**:

Part of #15714. Depends on Parts 1–7 (needs the Rust side in place to be
testable against a real connection).

Work items:
- [ ] `dbt_macro_assets/dbt-sqlserver/dbt_project.yml`
- [ ] Required macro set with `sqlserver__` dispatch prefix: `create_schema`,
  `drop_schema`, `drop_relation`, `rename_relation`, `truncate_relation`,
  `create_table_as`, `create_view_as`, `list_schemas`, `check_schema_exists`,
  `information_schema_name`, `current_timestamp`, `get_columns_in_relation`,
  `list_relations_without_caching`
- [ ] Full macro-by-macro port from the 34 v1 `.sql` files — see roadmap
  `plan/03-macros-porting-map.md`
- [ ] Delegate to `fabric__*` macros where SQL Server behavior matches;
  override only where it genuinely differs

Full detail: roadmap `plan/02-implementation-steps.md` §5.6 and
`plan/03-macros-porting-map.md`.

---

## Part 9 — `dbt-init`: interactive profile setup (optional)

**Title**: `feat(sqlserver): Part 9 — dbt init profile wizard`

**Body**:

Part of #15714. Depends on Part 2. Optional — doesn't block `dbt build`
working via a hand-written `profiles.yml`; can slip past the initial PR.

Work items:
- [ ] Add `AdapterType::SqlServer` to `get_available_adapters()` in `src/profile_setup.rs`
- [ ] `src/adapter_config/sqlserver_config.rs` implementing `InteractiveSetup`,
  modeled on `fabric_config.rs`
- [ ] Export from `src/adapter_config/mod.rs`
- [ ] Match arm in `create_profile_for_adapter()`

Full detail: roadmap `plan/02-implementation-steps.md` §5.3.1.

---

## Part 10 — End-to-end validation

**Title**: `feat(sqlserver): Part 10 — jaffle-shop smoke test and changelog`

**Body**:

Part of #15714. Depends on Parts 1–8.

Work items:
- [ ] Clean `dbt build` against a local SQL Server container and
  [jaffle-shop](https://github.com/dbt-labs/jaffle-shop) — the guide's
  acceptance bar
- [ ] Auth-mode matrix: service principal, AD password, environment
  credential, plain SQL auth — each through a full `dbt build`
- [ ] `.changes/unreleased/Features-*.yaml` changelog entry
- [ ] Coordinate with `#adapter-ecosystem` for warehouse-credential CI
  (guide's Step 6)

Full detail: roadmap `plan/04-testing-and-validation.md`.
