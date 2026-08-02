# Working in this repo

Instructions for coding agents. Humans may find the context useful too.

## What this repo is

A planning and coordination workspace for porting dbt-sqlserver to dbt Core v2
(Fusion). It contains **no adapter code**. Almost every sentence in `plan/` is a
claim about one of two codebases that are actively changing:

- `dbt-labs/dbt-core` — where the v2 adapter lives, cloned to `dbt-core/`
- `dbt-msft/dbt-sqlserver` — the v1 adapter being ported, cloned to `dbt-sqlserver/`

`make setup` clones both (they're gitignored, not submodules — `plan/README.md`
explains why). `dbt-core` comes from the fork on the `sqlserver-v2-port`
integration branch, with `dbt-labs/dbt-core` as the `upstream` remote, so a
checkout is on the branch the port lands on rather than on upstream `main`.

`.devcontainer/` provides both toolchains in one container — Rust plus
`cargo-nextest`, `z3` and `pkg-config` for dbt-core; Python, `uv` and the
Microsoft ODBC driver for dbt-sqlserver; docker-in-docker for `make server` —
and runs `make setup` on creation, so both checkouts are in the workspace.

That framing drives everything below: **the main failure mode here is not a bug,
it's a confident sentence that stopped being true.**

## Verify against a checkout, not against memory or a loose grep

Every file:line reference in `plan/` was checked against a real checkout. Keep
it that way.

- **List directories, don't infer them from grep.** `00-current-state.md` §6
  once claimed the `dbt-fabric` macro package held 2 files, from a
  non-exhaustive grep. It holds 42, and the wrong number had propagated into a
  porting strategy that told people to rewrite macros the upstream project
  actually vendors verbatim. `find <dir> -type f` before characterizing a tree.
- **Re-check line numbers before citing them.** `include_policy` is at
  `relation_impl.rs:37`, not the 219 an earlier pass cited — 219 is
  `get_database`, a different match with different consequences. A plausible
  line number is not a checked one.
- **Read the code that implements the thing, not just the thing that names it.**
  `adapter.parse_index` exists and is dispatched from Jinja, which reads like
  working support; the implementation it resolves to is `unimplemented!()` for
  every adapter. Follow the call through.

When a claim can be settled by running a command, run the command and state the
result plainly. Don't write "very likely", "presumably", or "should be" about
something a `grep` would answer in five seconds.

## Check live state before trusting a decision

Decisions in `plan/05-open-questions-and-risks.md` were made against a snapshot
of both repos. Upstream keeps moving, and it has already invalidated
reasoning here at least twice — a quoting decision framed as a deliberate
divergence from v1 became alignment when v1 shipped
[#795](https://github.com/dbt-msft/dbt-sqlserver/pull/795), and a "SQL
Server-specific extra" turned out to be a shared dbt feature Postgres also
exposes.

Before relying on a decision, or restating one to the user:

```bash
gh issue view 786 --repo dbt-msft/dbt-sqlserver --json state,body
gh pr list --repo dbt-msft/dbt-sqlserver --state all --limit 20
gh issue list --repo dbt-sqlserver-next/dbt-core --state all   # Part N series
gh issue view 15714 --repo dbt-labs/dbt-core --json state,comments
git -C dbt-sqlserver log --oneline -20
```

Read the PR bodies, not just the titles. #795's body carried live-server
measurements — `sessionproperty('QUOTED_IDENTIFIER') = 1` on all three
backends — that answered an open question in the plan and that nothing in the
diff would have told you.

If reality has moved, fix the affected docs in the same change, and say so in
the commit message rather than silently rewriting.

## When a decision is ambiguous, ask — with enough context to decide

Ambiguity here usually means a real trade-off between deferring work and
shipping a silent behavior change. Those are the user's call, not yours.

Don't ask bare questions ("should we support indexes?"). Give the user what
they'd need to answer without opening a checkout:

1. **What you found**, with the file:line or PR that establishes it.
2. **What each option costs**, concretely — which crates, roughly how much work,
   what's blocked by whom.
3. **What the user-visible consequence is**, especially any silent one. A
   feature that no-ops without an error is worth flagging every time.
4. **Your recommendation**, stated as such.

Worked example, from this repo's history: rather than "should indexes be in
scope?", the useful framing was — the shared `dbt-adapters` package already
defines the index contract and v1 already speaks it, so this isn't exotic; but
`adapter.parse_index` is `unimplemented!()` in Rust for every adapter, so
shipping it means doing that work first; and deferring it means a model
configured with `indexes:` builds successfully with no indexes and no warning,
which is bad for a user base that leans on clustered columnstore. That gives
the user something to decide.

Ask before, not after, writing a plan section that assumes an answer.

## Outward-facing actions need explicit approval

The repo coordinates work across trackers that other people read.

- **Don't push.** Commit locally and let the user push, unless they've said
  otherwise in the current session.
- **Don't edit live issues** on `dbt-msft/dbt-sqlserver`,
  `dbt-sqlserver-next/dbt-core`, or `dbt-labs/dbt-core`. Drafts in `issues/`
  mirror them; propose the edit and let the user apply it.
- Note in your summary when a draft has drifted from the live issue it mirrors,
  so the user can decide whether to sync.

## Writing style for `plan/` and `issues/`

These documents are read by contributors who weren't in the conversation that
produced them.

- **State what is true now.** No "this section previously said", no "updated
  2026-08-02", no "no longer a divergence". Git holds the history; the document
  holds the current state.
- **Cite file:line** for claims about either codebase, so the next person can
  re-verify rather than re-derive.
- **Keep the audit hashes in `00-current-state.md` honest.** If you re-verify
  against a newer commit, bump them. If you didn't verify, don't.
- Don't hedge what you checked, and don't assert what you didn't.
- Skip the emphasis-shouting (`**DECIDED**`, `**do not**`, `**required**`).
  Ordinary prose carries it.

## Where things live

- `plan/00`–`05` — audit, architecture, step-by-step checklist, macro map,
  testing, decisions and risks. `plan/README.md` is the entry point.
- `issues/` — drafts of issues filed on other repos, reviewed here first. Each
  carries frontmatter with `target_repo`, `status` and the live `url`.
- `Makefile` — clones both repos, and runs the local SQL Server container by
  delegating to dbt-sqlserver's own `docker-compose.yml`.
