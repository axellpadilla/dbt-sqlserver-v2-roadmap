---
target_repo: dbt-msft/dbt-sqlserver
type: tracking
status: open
url: https://github.com/dbt-msft/dbt-sqlserver/issues/786
pin: true
label: v2-migration
related: ../plan/README.md
---

# Tracking: dbt Core v2.0 (Fusion) migration for SQL Server

## Summary

Links the issues and PRs — here and in `dbt-labs/dbt-core` — for bringing SQL Server support to dbt Core v2.0 (the Rust/"Fusion" engine), plus the v1 fixes found while auditing v1 for that port. Decisions and detail live in the [roadmap repo](https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap) `plan/`; this issue stays a one-line-per-item index.

dbt Labs' [Contribute a dbt Core 2.0 Adapter](https://docs.getdbt.com/guides/adapter-creation-v2) guide has v2 adapters living inside the `dbt-core` monorepo. v1 (`dbt-sqlserver`) keeps existing as an independently maintained package; this tracks the parallel v2 work.

## Want to help?

- Align v1 closer to the final v2 state (e.g. #785, #770)
- Check for bugs or issues on work in progress

### Where PRs go

- **Fork**: https://github.com/dbt-sqlserver-next/dbt-core
- **Branch**: `sqlserver-v2-port`
- Open PRs against `dbt-sqlserver-next/dbt-core:sqlserver-v2-port`, not `dbt-labs/dbt-core:main`. Rationale: roadmap repo's `plan/README.md` ("Branching strategy").

## Related: aligning v1 with the future v2 parser, on this repo

- [ ] #770 — Explore dbt Core 1.12 v2 parser support: validates the existing Python `dbt-sqlserver` adapter against dbt Core 1.12's opt-in `--use-v2-parser` (Rust parser, existing Python adapter — not the Fusion adapter framework this issue tracks). Surfaces project/macro/manifest compatibility issues early, ahead of the full Fusion port below.

## dbt-core (v2 adapter implementation)

- [x] [dbt-labs/dbt-core#15714](https://github.com/dbt-labs/dbt-core/issues/15714) — bootstrap/scope-alignment issue (upstream, public)

Granular execution ("Part N" issues, one per crate-scoped unit of work) is tracked on the fork, not here — same reasoning as "Where PRs go" above (`Closes #N` only works same-repo, and these aren't mergeable upstream yet): [dbt-sqlserver-next/dbt-core#1](https://github.com/dbt-sqlserver-next/dbt-core/issues/1) through [`#10`](https://github.com/dbt-sqlserver-next/dbt-core/issues/10) ([index](https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap/blob/main/issues/dbt-core-sqlserver-v2-parts.md)).

## dbt-sqlserver (v1 fixes found while planning the v2 port)

- [x] #785 — Inconsistent identifier quoting (`[bracket]` vs `"double quote"`) across a handful of macros
- [ ] *(more get added here as they're found/filed)*

## Deferred / follow-up scope (explicitly out of the v2 initial PR)

Not scheduled — tracked so they aren't lost. Reasoning: roadmap repo's `plan/05-open-questions-and-risks.md` #4.

- [ ] Dynamic data masking support in v2
- [ ] Index/columnstore materialization config in v2
- [ ] `full_refresh_build: prebuilt` optimization in v2
- [ ] Scalar function materializations in v2
- [ ] Table clone support in v2
- [ ] Windows/trusted-connection auth in v2

## References

- Roadmap: https://github.com/dbt-sqlserver-next/dbt-sqlserver-v2-roadmap
- Guide: https://docs.getdbt.com/guides/adapter-creation-v2
- v2 target repo: https://github.com/dbt-labs/dbt-core
