#!/usr/bin/env bash
#
# postCreateCommand for the roadmap devcontainer.
#
# Installs what both sides of the port need, clones both repos into the
# workspace, and sets up the v1 virtualenv.
#
# Safe to re-run: `make setup` skips repos that are already there.

set -euo pipefail

log() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

pkg_installed() {
  dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii '
}

apt_install() {
  local missing=()
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  sudo apt-get install -y --no-install-recommends "${missing[@]}"
}

persist_env() {
  # Zed and `devcontainer exec` don't get remoteEnv, so persist to the shell rc.
  local line="$1"
  grep -qF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >>"$HOME/.bashrc"
}

sudo apt-get update

# --- v2 (dbt-core, Rust) -----------------------------------------------------
# z3 and pkg-config are the two that bite: without them cargo build fails part
# way through with a linker error that doesn't name them (plan/01).
log "Build dependencies for dbt-core"
apt_install build-essential pkg-config z3 libz3-dev cmake

# Nextest is dbt-core's testing utility of choice (its CONTRIBUTING.md).
if ! command -v cargo-nextest >/dev/null 2>&1; then
  log "Installing cargo-nextest"
  cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
  # The rust feature puts CARGO_HOME under /usr/local, which may not be
  # writable by the remote user; fall back to sudo rather than failing.
  if [ -w "$cargo_bin" ]; then
    curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$cargo_bin"
  else
    curl -LsSf https://get.nexte.st/latest/linux | sudo tar zxf - -C "$cargo_bin"
  fi
fi

# rust-toolchain.toml in dbt-core pins the channel; rustup honors it on first
# use inside the directory, so there's no toolchain to pick here.

# --- v1 (dbt-sqlserver, Python + ODBC) ---------------------------------------
log "Microsoft ODBC driver and SQL Server tools"
if ! pkg_installed msodbcsql18; then
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor \
    | sudo tee /usr/share/keyrings/microsoft-prod.gpg >/dev/null
  curl -fsSL https://packages.microsoft.com/config/debian/12/prod.list \
    | sudo tee /etc/apt/sources.list.d/mssql-release.list >/dev/null
  sudo apt-get update
  sudo ACCEPT_EULA=Y apt-get install -y msodbcsql18
fi
pkg_installed mssql-tools18 || sudo ACCEPT_EULA=Y apt-get install -y mssql-tools18
apt_install unixodbc-dev libgssapi-krb5-2 libkrb5-3 libltdl7

persist_env 'export PATH="$PATH:/opt/mssql-tools18/bin"'

command -v uv >/dev/null 2>&1 || pip install --quiet uv

# --- Checkouts ---------------------------------------------------------------
# Blobless by default (see the Makefile); dbt-core lands on the fork's
# sqlserver-v2-port branch with dbt-labs as `upstream`.
log "Cloning dbt-core and dbt-sqlserver"
make setup

log "Setting up dbt-sqlserver (v1)"
(
  cd dbt-sqlserver
  [ -f test.env ] || cp test.env.sample test.env
  [ -d .venv ] || uv venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  # Both backend extras so either connection path is exercisable, plus dev.
  uv sync --all-extras --group dev

  # --all-extras installs the ADBC client library but not the driver binary
  # that speaks the SQL Server wire protocol; that ships via the dbc CLI and
  # is not on PyPI. See dbt-sqlserver/docs/adbc_backend.md.
  #
  # `uv venv` creates no pip, so a bare `pip install` here silently falls
  # through to the system one and lands dbc outside the venv.
  uv pip install --quiet dbc

  # dbc installs relative to ADBC_DRIVER_PATH when it's set, and this script
  # persists that variable to ~/.bashrc — so on a re-run it would target the
  # path recorded last time rather than this venv. Clear it and pin VIRTUAL_ENV.
  env -u ADBC_DRIVER_PATH VIRTUAL_ENV="$PWD/.venv" .venv/bin/dbc install mssql

  if [ ! -d .venv/etc/adbc/drivers ]; then
    echo "ADBC driver did not install into $PWD/.venv — the adbc backend will not work" >&2
    exit 1
  fi
)
persist_env "export ADBC_DRIVER_PATH=\"$PWD/dbt-sqlserver/.venv/etc/adbc/drivers\""

log "dbt-core"
echo "Branch:    $(git -C dbt-core rev-parse --abbrev-ref HEAD)"
echo "Toolchain: $(cd dbt-core && rustc --version 2>/dev/null || echo 'resolves on first cargo run')"
echo "The first cargo build is slow and writes several GB to dbt-core/target/,"
echo "in the bind-mounted workspace, so it survives container rebuilds."

cat <<'EOF'

==> Ready

  make server   start SQL Server 2022 on :1433 (reuses dbt-sqlserver's compose file)
  make status   git status for both checkouts

  v1   cd dbt-sqlserver && source .venv/bin/activate && pytest tests/functional -k <name>
  v2   cd dbt-core && cargo build --bin dbt && cargo nextest run -p dbt-adapter

Read AGENTS.md before editing plan/ — claims here are checked against these
checkouts, and go stale when the checkouts move.
EOF
