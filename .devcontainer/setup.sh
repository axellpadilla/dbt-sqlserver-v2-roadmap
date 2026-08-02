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
# pkg-config and z3 are what the adapter guide's setup step names for the Z3
# link errors; its `brew install pkg-config z3` maps to libz3-dev on Debian,
# where the headers are a separate package. cmake isn't named by the guide —
# it's here because -sys crates commonly shell out to it, and finding out
# mid-build costs more than the download.
#
# protobuf-compiler is what dbt-state's build script shells out to; without it
# `cargo check --workspace` stops at "Could not find `protoc`" and never
# reaches the crates below it. libprotobuf-dev comes with it because the
# Debian split puts the well-known types in that package — with protoc alone,
# dbt-state's protos fail on `import "google/protobuf/duration.proto"`.
#
# dbt-core's release workflow downloads protoc 29.4 (release-v2.yml:203);
# bookworm ships 3.21.12, which builds dbt-state's protos today. If a proto
# starts using a newer feature, fetch 29.4 the way that workflow does rather
# than widening this line.
log "Build dependencies for dbt-core"
apt_install build-essential pkg-config z3 libz3-dev cmake \
  protobuf-compiler libprotobuf-dev

# rustup, rather than the devcontainer Rust feature: that feature adds its
# components outside the branch that installs rustup (install.sh:362 vs :400),
# so a skipped install fails the image build. Installing here also keeps
# CARGO_HOME under $HOME, which the remote user owns.
cargo_bin="$HOME/.cargo/bin"
if [ ! -x "$cargo_bin/rustup" ]; then
  log "Installing rustup"
  curl -sSf --proto '=https' --tlsv1.2 https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path --profile minimal
fi
export PATH="$cargo_bin:$PATH"
persist_env 'export PATH="$HOME/.cargo/bin:$PATH"'

# The downloaded-crate cache lives in the bind-mounted workspace, so a container
# rebuild doesn't re-fetch ~2GB of registry and git dependencies. Only the cache
# moves: `bin/` and the toolchain stay under $HOME, which the remote user owns.
#
# Symlinks rather than CARGO_HOME, because CARGO_HOME would also relocate the
# rustup-installed binaries this script just put in $cargo_bin.
#
# Note this puts the cache under `target/`, so `cargo clean` at the workspace
# root would delete it — recoverable (the next build re-downloads) but slow.
# Prefer `cargo clean -p <pkg>`, or re-run this script afterwards.
cargo_cache="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dbt-core/target/cache"
mkdir -p "$cargo_cache/registry" "$cargo_cache/git"
for d in registry git; do
  if [ ! -L "$HOME/.cargo/$d" ]; then
    # A real directory here means a pre-existing cache: fold it in, don't drop it.
    if [ -d "$HOME/.cargo/$d" ]; then
      log "Moving existing cargo $d cache into $cargo_cache"
      cp -a "$HOME/.cargo/$d/." "$cargo_cache/$d/"
      rm -rf "$HOME/.cargo/$d"
    fi
    ln -s "$cargo_cache/$d" "$HOME/.cargo/$d"
  fi
done

# Nextest is dbt-core's testing utility of choice (its CONTRIBUTING.md).
if ! command -v cargo-nextest >/dev/null 2>&1; then
  log "Installing cargo-nextest"
  curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C "$cargo_bin"
fi

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
echo "Branch: $(git -C dbt-core rev-parse --abbrev-ref HEAD)"
# rust-toolchain.toml pins the channel and lists the components; `rustup show`
# installs both, so the first cargo build isn't also a toolchain download.
( cd dbt-core && rustup show )
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
