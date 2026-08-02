# 05 — Open Questions & Risks

Decisions that should be made explicitly (ideally confirmed with dbt Labs via
`#adapter-ecosystem`, per `04-testing-and-validation.md` §3) before or during
implementation, because they're load-bearing across many files.

## Decisions needed before writing code

1. **Identifier quoting mechanism — DECIDED.** Use `"double quotes"` as
   `quote_char` (`'"'`), with **`SET QUOTED_IDENTIFIER ON` required** for the
   session. Rationale: fits the existing `quote_char() -> char` API in
   `crates/dbt-adapter-core/src/lib.rs` unchanged (no upstream API change to
   negotiate with dbt Labs), and matches the convention most other v2
   adapters already use.

   **No longer a divergence from v1** (updated 2026-08-02). When this was
   decided, v1 hand-formatted `[bracket]` identifiers in ~9 macro files.
   [PR #795](https://github.com/dbt-msft/dbt-sqlserver/pull/795) (v1.12.0rc2,
   closing #785 — the issue this workspace filed for exactly this reason —
   and #409) removed all of them, so v1 and v2 now render identifiers the
   same way. Brackets survive in v1 only inside server-side `QUOTENAME()`
   dynamic SQL, which is deliberate and isn't ported.

   **Scope of "v2 doesn't use brackets": `quote_char` only.** Verified
   2026-08-02 — v2's vendored `dbt-fabric` macro package still hand-formats
   `USE [db]`, `EXEC('CREATE SCHEMA [...]')` and `{{ "["~column~"]" }}` in
   five files, while `AdapterType::Fabric`'s `quote_char` is `'"'`. `quote_char`
   governs relation rendering; macro bodies are vendored from the v1 Python
   adapters as-is (`00-current-state.md` §6). So bracket literals in a ported
   macro body would not violate any upstream convention — v1's #785 cleanup is
   a quality choice that happens to make the port simpler, not a gate.

   **Consequences to carry through the rest of the plan:**
   - `crates/dbt-adapter-core/src/lib.rs` — `quote_char` arm for `SqlServer`
     is `'"'` (Step 5.1, `02-implementation-steps.md`).
   - **Escaping is part of the decision, not an afterthought.** An embedded
     `"` must be doubled: `ab"cd` → `"ab""cd"`. A `"` needs no escaping
     inside `[brackets]` but does inside double quotes, so choosing the
     double-quote delimiter without escaping would reject names v1 accepts.
     v1 implements this in `SQLServerAdapter.quote()` and
     `SQLServerRelation.quoted()` (neither delegates to `super()`, which
     wraps verbatim — pre-escaping its input would double-escape if upstream
     ever starts escaping). **Check whether v2's relation rendering escapes
     at all** before assuming the `quote_char` arm is sufficient — this is
     Part 4 (`relation_impl.rs`) work, not just a one-character arm.
   - `SET QUOTED_IDENTIFIER ON` as connection-init SQL in
     `crates/dbt-auth/src/sqlserver/init.rs` (Step 5.4). **Belt-and-braces,
     not a blocker** — v1 verified against a live server that
     `sessionproperty('QUOTED_IDENTIFIER') = 1` already on all three of its
     backends, including the `go-mssqldb`-backed ADBC one v2 uses (PR #795's
     verification notes). Issue it anyway: server-level `user options`, a
     login default or legacy compatibility settings can force it `OFF`, and
     the failure mode is total — the same check confirmed `USE "db"` is a
     hard `Msg 102` with it off.
   - `crates/dbt-loader/src/dbt_macro_assets/dbt-sqlserver/` macros port from
     v1 **verbatim** as far as quoting goes — the rewrite this bullet used to
     mandate is already done upstream (`03-macros-porting-map.md`).
   - Document `QUOTED_IDENTIFIER ON` as a hard prerequisite in the Step 7
     setup guide (`04-testing-and-validation.md`/user-facing docs), since a
     server/login with it forced `OFF` will break every quoted-identifier
     statement the adapter emits — this is a real footgun for on-prem
     instances with legacy compatibility settings.
   - Add a smoke-test case for this explicitly (`04-testing-and-validation.md`):
     confirm behavior against a session where `QUOTED_IDENTIFIER` defaults to
     `OFF` (e.g. via login/database `ANSI` settings) to verify the init SQL
     actually overrides it.

2. **Auth scope for the initial PR — DECIDED.** Plain SQL authentication
   (native SQL Server login: username + password, no `fedauth` param) is
   **in scope for the initial PR**. Windows/trusted-connection auth is
   **deferred** (lower value, environment-dependent — only meaningful when
   the dbt process itself runs on a domain-joined Windows host).

   Rationale: plain SQL auth is the most common on-prem SQL Server auth mode,
   and `crates/dbt-auth/src/sqlserver/mod.rs` currently only implements
   Entra/Azure AD flows (`ActiveDirectoryServicePrincipal`,
   `ActiveDirectoryPassword`, `environment`) — without plain SQL auth the
   adapter would only be usable against Azure SQL / Entra-integrated targets,
   which contradicts the on-prem-first testing priority already decided in
   item 5 below.

   **Implementation notes:**
   - Add a new `SQLServerAuthIR` variant (e.g. `Sql { user, password }`) and
     a `parse_auth` branch, likely `authentication: sql` — confirm the exact
     value name against v1's `sqlserver_credentials.py`/`sqlserver_auth.py`
     rather than inventing a new one.
   - Unlike the Entra variants, this does **not** set `fedauth` in the
     connection URI — it maps directly to the `uid`/`password` (or
     `user id`/`password`) userinfo portion of the `sqlserver://` URI, the
     same way v1's ADBC backend embeds credentials
     (`sqlserver_backend.py:387` — `userinfo = f"{uid}:{pwd}"`, URL-encoded).
     See `00-current-state.md` §3 for the full v1 ADBC-backend reference.
   - Add a unit test mirroring the existing `sqlserver/mod.rs` test style
     (`test_service_principal_with_tenant_id`, etc.) — e.g.
     `test_plain_sql_auth`.
   - Update `02-implementation-steps.md` §5.4 and `SqlServerDbConfig`
     (§5.3) to include this as a config-mode, not just document it here.

3. **TLS/`encrypt` handling — DECIDED (porting task, not a design question).**
   `apply_connection_args` has a `// TODO` for
   `encrypt`. Without it, connections to on-prem SQL Server instances with
   self-signed certificates will likely fail by default (recent `go-mssqldb`
   defaults to `encrypt=true` with strict cert validation). This is a
   functional blocker for on-prem use, not a nice-to-have — treat as
   required, not optional, for the initial PR if on-prem is in scope.
   **No longer a design question, just a porting task**: v1's just-merged
   ADBC backend (`dbt-sqlserver/dbt/adapters/sqlserver/sqlserver_backend.py:367-401`,
   [PR #783](https://github.com/dbt-msft/dbt-sqlserver/pull/783)) already
   implements this exact param set (`encrypt`, `TrustServerCertificate`,
   `connection timeout`) against the same driver, with defaults `encrypt=True`,
   `trust_cert=False`, `login_timeout=0` (`sqlserver_credentials.py:55-59`).
   Port those values directly rather than re-deciding them — see
   `00-current-state.md` §3 and `02-implementation-steps.md` §5.4.

4. **Feature scope for v1 parity — DECIDED: out of scope for the initial PR.**
   v1 `dbt-sqlserver` has several SQL-Server-specific extras beyond the
   guide's minimal required-macro list, all deferred as known follow-ups:
   - Dynamic data masking (`apply_masks.sql`)
   - Index/columnstore materialization config (`indexes.sql`, `relation_configs/`)
   - `full_refresh_build: heap_then_index` vs `prebuilt` table-rebuild
     optimization (`relations/table/create.sql`)
   - Scalar function materializations
   - Zero-copy-style table clone (`relations/table/clone.sql`)

   Consistent with the guide's framing ("once your adapter is in place, `dbt
   build` and `dbt run` should work" — not full v1 feature parity). This
   keeps the PR closer to the guide's ~13-file scope and easier to review.

   **Implementation notes:**
   - In `03-macros-porting-map.md`, the corresponding v1 files
     (`apply_masks.sql`, `indexes.sql`, the `prebuilt` branch of
     `relations/table/create.sql`, `materializations/functions/*.sql`,
     `relations/table/clone.sql`) should be **skipped**, not ported — treat
     their "Port if in scope" notes there as resolved to "skip for initial PR."
   - `crates/dbt-adapter/src/adapter/adapter_impl.rs` arms with no SQL Server
     equivalent for these features should use `unimplemented!()` per the
     guide's explicit allowance for initial contributions, rather than
     stubbing out partial/incorrect behavior.
   - Track each deferred item as a named follow-up issue once the initial PR
     is merged (mirrors the `issues/` convention started in this workspace
     for the v1 quoting-alignment proposal).

5. **Which SQL Server "flavor(s)" to target for smoke testing — RECOMMENDED,
   pending confirmation** (the one item here not yet locked in). On-prem
   Linux/Windows SQL Server, Azure SQL Database, and Azure SQL Managed
   Instance have real behavioral differences (cross-database queries, some
   DMV availability, feature support). Recommend: primary target = on-prem
   SQL Server via Docker (matches most existing dbt-sqlserver v1 users, has
   the simplest local reproduction via `dbt-sqlserver/docker-compose.yml`),
   secondary/CI-coordinated target = Azure SQL Database (validates the
   already-implemented Entra auth paths). Confirm this prioritization with
   dbt Labs given the CI/credential coordination constraints in
   `04-testing-and-validation.md` §3.

## Risks

- **Metadata/catalog query correctness is the highest-risk area for silent
  bugs.** `INFORMATION_SCHEMA` behavior is close but not identical between
  classic SQL Server and Fabric Warehouse (e.g. certain DMVs, computed-column
  metadata, index metadata only available via `sys.*` views). Don't assume
  `crates/dbt-adapter/src/metadata/fabric/mod.rs` is a safe copy-paste target —
  verify every query against a real SQL Server instance's `sys.*`/
  `INFORMATION_SCHEMA` output, not just against Fabric's behavior.

- **`STRING_AGG` version dependency** — `utils/listagg.sql` likely uses
  `STRING_AGG()`, only available SQL Server 2017+. If the adapter aims to
  support older on-prem instances (2016 and earlier, still common in the
  wild), this needs either a documented minimum-version requirement or a
  fallback implementation (e.g. `FOR XML PATH` string concatenation).
  Decide and document the minimum supported SQL Server version explicitly —
  don't leave it implicit.

- **Residual risk from the quoting decision (Decision 1)**: choosing
  double-quote over bracket quoting avoided an upstream API-change
  discussion, but it means `SET QUOTED_IDENTIFIER ON` becomes a hard
  runtime dependency instead. If that init SQL is ever skipped or fails
  silently on a given connection, every subsequent quoted-identifier
  statement breaks — treat the smoke test in item 1's "consequences" list
  as non-optional, not a nice-to-have. **Partly retired**: v1 measured
  `QUOTED_IDENTIFIER = 1` as the default on `go-mssqldb`, so the common path
  is safe; what remains is servers/logins that force it `OFF`.

- **Identifiers built inside string literals — a silent-failure class v1 hit
  and v2 will too.** `OBJECT_ID('schema.table')`, `sp_rename`, and any
  catalog predicate comparing against a name are string-literal contexts, not
  identifier contexts, so quoting rules don't apply automatically and errors
  don't surface: `OBJECT_ID` returns `NULL` for a schema containing a `.` or
  a `"`, which every caller reads as "object does not exist". In v1 this
  silently skipped drop-before-create guards and made dynamic data masking a
  no-op for affected schemas (fixed in PR #795, 11 sites). The v2 Rust
  catalog module (Part 5, `metadata/sqlserver/mod.rs`) builds exactly these
  predicates. Test with a schema containing a `.`, a `"`, a backslash and a
  space — v1's `TestIndexMacros` uses `…_dom\usr.x"q` as a single covering
  name.

- **Concurrent catalog reads deadlock without `(nolock)`.** v1 found that
  read-only catalog lookups and temp-relation catalog DDL participating in
  the ambient transaction deadlock under concurrent incremental runs (fixed
  2026-08-01: `f0afd9f`, `75e9345`, `4ceca61`). Whoever writes the Rust
  catalog queries for Part 5 should carry the same hints/isolation choices
  over rather than rediscovering this against a live warehouse.

- **ADBC driver maturity** — `adbc_driver_mssql` is CDN-distributed already,
  which is a strong signal it's reasonably mature, but this plan hasn't
  independently verified its Arrow type coverage for SQL Server-specific
  types (`uniqueidentifier`, `hierarchyid`, `sql_variant`, `xml`,
  `rowversion`). Treat as unverified until the first live smoke test —
  budget time for `column_builder.rs`/`sql_types.rs` rework if the driver's
  Arrow schema surprises you.

- **v1 macro helper dependencies** (`get_query_options`, `load_cached_relation`,
  `make_intermediate_relation`, `make_backup_relation`, `get_use_database_sql`)
  are assumed to still exist in v2's shared macro set based on their use in
  other adapters' v1 codebases, but this hasn't been directly confirmed in
  this repo's v2 macro layer. If any are missing or behave differently,
  several materializations in `03-macros-porting-map.md` will need rework,
  not just a straight port.

- **Compiler-driven completeness cuts both ways**: it guarantees you won't
  *miss* a required match arm, but it says nothing about whether the arm's
  *content* is correct for SQL Server vs. merely "compiles because it copied
  Fabric's arm." Treat every `Fabric`-derived arm as a hypothesis to verify
  against real SQL Server behavior during smoke testing, not as done once it
  compiles.
