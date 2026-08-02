# dbt-sqlserver v2 roadmap

Planning and coordination workspace for porting the community **dbt-sqlserver**
adapter to **dbt Core v2.0** (the Rust/"Fusion" engine), per dbt Labs'
[Contribute a dbt Core 2.0 Adapter](https://docs.getdbt.com/guides/adapter-creation-v2)
guide.

This repo does **not** contain the adapter code itself — that work happens as
PRs against [`dbt-labs/dbt-core`](https://github.com/dbt-labs/dbt-core). This
repo holds the plan, decision log, and local dev tooling used to get there.

## Layout

- [`plan/`](plan/) — the implementation plan: architecture recap, file-by-file
  checklist, macro porting map, testing strategy, and the decision log
  (`plan/05-open-questions-and-risks.md`).
- [`issues/`](issues/) — drafts for issues to be opened on other repos
  (e.g. proposals for `dbt-msft/dbt-sqlserver`) before they're filed, so they
  get reviewed here first.
- `Makefile` — clones the two repos this plan is written against.
- [`AGENTS.md`](AGENTS.md) — conventions for anyone, human or agent, editing
  the plan: verify claims against a checkout, check live issue/PR state before
  trusting a decision, and bring ambiguous calls back to a maintainer.

## Getting started

```bash
make setup   # clones dbt-core/ and dbt-sqlserver/ alongside this repo
make status  # check both repos' git status
make update  # pull latest on both
```

`dbt-core` is cloned from [the fork](https://github.com/dbt-sqlserver-next/dbt-core)
on the `sqlserver-v2-port` integration branch, with `dbt-labs/dbt-core` added as
the `upstream` remote — see `plan/README.md`, "Branching strategy". Override
with `DBT_CORE_URL` / `DBT_CORE_BRANCH`, and pass
`CLONE_ARGS=--filter=blob:none` for a blobless clone.

### Devcontainer

`.devcontainer/` builds one container for both sides of the port: the Rust
toolchain, `cargo-nextest`, `z3` and `pkg-config` for dbt-core, and Python,
`uv`, the Microsoft ODBC driver and `sqlcmd` for dbt-sqlserver, with
docker-in-docker so `make server` can start SQL Server on `:1433`.

On creation it runs `make setup` (blobless), so both checkouts land inside the
workspace with `dbt-core` on the `sqlserver-v2-port` branch, and sets up
dbt-sqlserver's virtualenv and ADBC driver. Nothing to do after the container
comes up but `make server`.

Both `dbt-core/` and `dbt-sqlserver/` are independent git checkouts with
their own remotes and history — they're `.gitignore`d here on purpose, not
submodules. See `plan/README.md` for why.

## References

- Guide: https://docs.getdbt.com/guides/adapter-creation-v2
- Upgrading to v2: https://docs.getdbt.com/docs/dbt-versions/core-upgrade/upgrading-to-v2?version=2.0
- Fusion package compatibility: https://docs.getdbt.com/guides/fusion-package-compat
- Target repo: https://github.com/dbt-labs/dbt-core
- v1 adapter: https://github.com/dbt-msft/dbt-sqlserver
