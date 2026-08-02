# CLAUDE.md

See [AGENTS.md](AGENTS.md). It's the single source of instructions for agents
working in this repo, and this file exists only so that tools looking for
`CLAUDE.md` find their way there.

Two points from it are worth repeating up front, because they're what goes
wrong here:

- **This repo makes claims about two codebases that keep moving.** Verify
  against the `dbt-core/` and `dbt-sqlserver/` checkouts and against live
  issue/PR state before trusting or restating a decision.
- **Ambiguous calls belong to the user.** Ask, with the evidence, the cost of
  each option, and any silent user-visible consequence — see AGENTS.md, "When a
  decision is ambiguous".
