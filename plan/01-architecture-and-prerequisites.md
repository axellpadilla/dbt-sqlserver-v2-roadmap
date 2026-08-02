# 01 — Architecture Recap & Prerequisites

Source: https://docs.getdbt.com/guides/adapter-creation-v2 (Steps 1–4)

## Architecture recap (v2-specific — don't skip if you only know v1)

```
[dbt Core v2.0] → [ADAPTER LAYER: crates/dbt-adapter*, dbt-auth, dbt-schemas] ↔ [ADBC driver: adbc_driver_mssql] ↔ [SQL Server / Azure SQL / Managed Instance]
```

- **No `SqlServerAdapter` class.** Behavior is expressed as arms in
  `match self.adapter_type()` / `match adapter_type` blocks spread across the
  six crates listed below. You are *adding arms*, not writing a package.
- **The adapter never touches the wire protocol.** `adbc_driver_mssql` (built on
  [`microsoft/go-mssqldb`](https://github.com/microsoft/go-mssqldb)) already
  handles TDS, connection pooling, and query execution. This is why
  `sqlserver_connections.py` from the v1 adapter has no v2 equivalent.
- **Compiler-driven completeness.** Once `AdapterType::SqlServer` is added
  (Step 5.1 in `02-implementation-steps.md`), every exhaustive `match
  adapter_type()` block missing a `SqlServer` arm becomes a compile error in
  its crate. Build order matters because later crates' arms often only make
  sense once earlier crates compile (e.g. you need `DbConfig::SqlServer` before
  `dbt-adapter` arms that read config fields make sense).

## Crates touched, in dependency order

| Order | Crate | Location | What SQL Server needs there |
|---|---|---|---|
| 1 | `dbt-adapter-core` | `crates/dbt-adapter-core/` | `AdapterType::SqlServer` variant + `quote_char` arm |
| 2 | `dbt-adbc` | `crates/dbt-adbc/` | **Already done** — verify only, no new code expected |
| 3 | `dbt-schemas` | `crates/dbt-schemas/` | `SqlServerDbConfig` struct + `DbConfig::SqlServer` variant |
| 4 | `dbt-auth` | `crates/dbt-auth/` | **Mostly done** — add plain SQL auth + TLS params (see `00-current-state.md` §3) |
| 5 | `dbt-adapter` | `crates/dbt-adapter/` | Largest step — relation quoting, catalog introspection, column builder, SQL type mapping, ~15 `adapter_impl.rs` match arms |
| 6 | `dbt-loader` | `crates/dbt-loader/` | New `dbt_macro_assets/dbt-sqlserver/` package: `dbt_project.yml` + macros |
| — | `dbt-init` (optional) | `crates/dbt-init/` | Interactive `dbt init` profile prompts |

## Required knowledge before starting

1. **Rust fundamentals** — read enums, `match` exhaustiveness, and how to read
   `error[E0004]: non-exhaustive patterns`. Reference: [The Rust Book, Ch. 6](https://doc.rust-lang.org/book/ch06-00-enums.html).
2. **dbt fundamentals** — [materializations](https://docs.getdbt.com/docs/build/materializations),
   [adapter dispatch](https://docs.getdbt.com/reference/dbt-jinja-functions/dispatch).
3. **SQL Server-specific decisions that are load-bearing across many files**
   (lock these in via `05-open-questions-and-risks.md` before writing code):
   - **Identifier quoting — DECIDED**: `quote_char = '"'` (double quotes),
     with an embedded `"` doubled when rendering, plus `SET QUOTED_IDENTIFIER
     ON` as connection-init SQL. v1 now quotes the same way (as of 1.12.0rc2),
     so macro bodies port verbatim. Full rationale and downstream
     consequences: `05-open-questions-and-risks.md` #1.
   - **2-part vs 3-part naming**: SQL Server is 3-part (`database.schema.table`),
     unlike Exasol's 2-part example in the guide. Confirm `Fabric`'s
     `include_policy` (`relation_impl.rs:219`, `Policy::new(...)`) already
     encodes 3-part inclusion — if so it's very likely directly reusable.
   - **Case sensitivity**: default SQL Server collations are
     case-*insensitive* (unlike Exasol's uppercasing behavior in the guide's
     worked example) but this is collation-dependent per-database/per-column.
     Don't assume `upper()` normalization is needed or safe — verify against
     the actual collation behavior instead of copying the Exasol pattern
     blindly.
   - **Auth surface — DECIDED**: plain SQL auth (native login) is in scope
     for the initial PR; Windows/trusted-connection auth is deferred. See
     `05-open-questions-and-risks.md` #2 for rationale and implementation
     notes.
   - **Required connection parameters**: host, port (default 1433 — already
     implemented), database, schema, authentication mode, and TLS/encrypt
     settings (currently a `// TODO` in `apply_connection_args`).
   - **Transaction support**: SQL Server supports transactions; confirm how
     `auto_begin` is handled in macros (`{% call statement(..., auto_begin=False) %}`
     patterns from `Fabric`/other adapters) versus v1's transaction handling in
     `sqlserver_connections.py` (not portable — check what replaces it, likely
     nothing needed since ADBC/the shared task runner manages this now). One
     piece *is* portable: v1 issues `SET XACT_ABORT ON` on every connection, so
     a run-time error partway through a multi-statement batch rolls the batch
     back instead of leaving it half-applied (`sqlserver_connections.py:401-434`).
   - **Datatype mappings**: string/timestamp/boolean/numeric — v1's
     `sqlserver_column.py` and v2's `Fabric` arms in `sql_types.rs` are both
     useful references; SQL Server and Fabric mostly share `datetime2`, `bit`,
     `varchar`/`nvarchar`, but classic SQL Server also has types Fabric may not
     support identically (e.g. `IDENTITY`, `uniqueidentifier`, `xml`,
     `hierarchyid`, `sql_variant`, `rowversion`) — decide which are in scope
     for v1 parity vs. deferred.
   - **System catalog**: `INFORMATION_SCHEMA.*` views work identically on both
     SQL Server and Fabric for most introspection; `sys.*` catalog views
     (`sys.tables`, `sys.indexes`, `sys.columns`) needed for anything
     `INFORMATION_SCHEMA` doesn't cover (e.g. index metadata, is-computed-column
     flags). Compare `crates/dbt-adapter/src/metadata/fabric/mod.rs` against
     v1's `dbt-sqlserver/dbt/include/sqlserver/macros/adapters/catalog.sql` and
     `metadata.sql`.

## AI-assisted development (per the guide)

If using an LLM/agent to generate match arms:
- Always give it: the exact file + `match` block being edited, the equivalent
  `Fabric` arm (or another adapter's arm) as a reference, the actual
  `cargo build -p <crate>` error text, and SQL Server-specific facts (catalog
  table names, connection fields) rather than letting it guess.
- **Do not trust hallucinated file paths.** Use the file table in
  `02-implementation-steps.md` and `00-current-state.md` as ground truth —
  re-`grep` the repo if a referenced path doesn't exist, since this checkout's
  layout already diverges from the guide in one place (`dbt-xdbc` → `dbt-adbc`).
- **Always verify with `cargo build -p <crate>`** after each generated arm.
  Never assume it compiles from inspection alone.
- v1 SQL macro patterns don't always port cleanly — Jinja macro *names* and
  *dispatch prefix* (`sqlserver__`) transfer, but verify materialization
  control flow against an existing v2 macro (e.g. `Fabric`'s) rather than
  assuming v1's macro is drop-in compatible with v2's task runner.

## Dev machine setup

```bash
# Rust toolchain
rustup show   # verify; repo pins a toolchain via rust-toolchain.toml

# Go (required for ADBC/driver-adjacent tooling)
go version

# Already cloned locally:
#   dbt-core/       (target repo, this monorepo)
#   dbt-sqlserver/  (v1 porting source)

cd dbt-core
cargo build --bin dbt   # verify a clean baseline build before making changes
```

If `cargo build` hits Z3-related errors: `brew install pkg-config z3` (macOS;
use the platform-appropriate package manager on Linux, e.g. `apt install
z3 pkg-config`). If disk fills during build: `cargo clean`.

### Iterative workflow (repeat per crate, in the order in the table above)

1. Add the `AdapterType::SqlServer` enum variant (unlocks everything downstream).
2. `cargo build -p <crate-name>` — compiler lists every missing match arm as an error.
3. Implement each arm using the compiler error + the `Fabric` reference arm +
   SQL Server-specific facts.
4. Re-run `cargo build -p <crate-name>` until clean.
5. Move to the next crate in the table.

For a SQL Server–specific worked example, run this first to see the exact
current error surface once the enum variant lands:

```bash
cargo build -p dbt-adapter-core
cargo build -p dbt-schemas
cargo build -p dbt-auth
cargo build -p dbt-adapter
cargo build -p dbt-loader
```
