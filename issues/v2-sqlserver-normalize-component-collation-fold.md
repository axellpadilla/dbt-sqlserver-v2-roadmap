---
target_repo: dbt-sqlserver-next/dbt-core
type: bug
status: draft
parent: https://github.com/dbt-sqlserver-next/dbt-core/issues/4
related: ../plan/05-open-questions-and-risks.md
---

# `normalize_component` lowercases SQL Server identifiers regardless of collation, merging names a case-sensitive server keeps distinct

`crates/dbt-adapter/src/relation/relation_impl.rs` `normalize_component`
dispatches on `AdapterType` via `format_ident::default_identifier_case`.
`SqlServer` has no dedicated arm, so it falls into the catch-all
`_ => to_lowercase()`, the same arm Fabric uses. Fabric's collation is fixed
and always case-insensitive; SQL Server's is a per-server, per-database, and
even per-column setting, commonly case-sensitive (`_CS_`) on non-default
installs.

## Consequence

`semantic_fqn` — used for cache keys and relation identity — folds `MODEL`
and `model` to the same string. On a case-sensitive SQL Server, those are two
distinct objects; the fold makes dbt's relation cache treat them as one,
which can misattribute state between them (e.g. cache a lookup or a
`drop`/`rename` against the wrong object).

Reachable only when a project sets `quoting: false` (or turns off quoting for
a specific component) — `DEFAULT_RESOLVED_QUOTING` is all-`true`, and the
quoted path in `quoted()` skips `normalize_component` entirely. Still a real
surface: `quoting: false` is an ordinary project setting, not exotic
configuration.

## This is not a new defect — v1 has it too, and knows it

v1's `dbt-sqlserver` has the identical assumption and already caught it:
`TestCachingUppercaseModel` is `@pytest.mark.skip`ped with "Fails because of
case sensitivity. MODEL is coereced to model which fails the test as it sees
conflicting naming." So this isn't a regression introduced by the port — it's
an inherited, previously-accepted gap, now also present in the v2 arm added
by Part 4 (`dbt-sqlserver-next/dbt-core#4`).

## Why this isn't a quick fix

Nothing in dbt-core's Rust currently models "what collation does this
connection have." Fixing this properly means either:

- querying the connection's actual collation (`DATABASEPROPERTYEX(db,
  'Collation')`, or per-column via `sys.columns.collation_name`) and folding
  conditionally, which needs a live connection at a point `normalize_component`
  doesn't currently have one, or
- picking a single conservative default (e.g. never fold, matching what an
  unquoted case-sensitive identifier does) and accepting it's wrong for the
  common case-insensitive default collation.

Either is a deliberate design decision, not a one-line patch, and affects at
least three other identifier-casing sites named in
`plan/05-open-questions-and-risks.md` (`seed_io.rs`
`infer_seed_column_name_strategy`, and the catalog introspection `where`
predicates) that carry the same nothing-knows-the-collation problem — worth
deciding once, for all of them, rather than patching this one site in
isolation.

## References

- `crates/dbt-adapter/src/relation/relation_impl.rs` `normalize_component`
- v1: `dbt/adapters/sqlserver/sqlserver_adapter.py` /
  `TestCachingUppercaseModel` (`@pytest.mark.skip`)
- `plan/05-open-questions-and-risks.md`, "Nothing in dbt-core knows what a
  collation is"
- Found while reviewing the SQL Server Fusion (v2) port
  (`dbt-sqlserver-next/dbt-core#4`)
