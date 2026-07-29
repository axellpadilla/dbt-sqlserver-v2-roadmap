DBT_CORE_URL      ?= https://github.com/dbt-labs/dbt-core.git
DBT_SQLSERVER_URL ?= https://github.com/dbt-msft/dbt-sqlserver.git
DBT_SQLSERVER_DIR := dbt-sqlserver

.PHONY: setup clone-dbt-core clone-dbt-sqlserver update status help \
        server server-stop server-logs test-env

help:
	@echo "Targets:"
	@echo "  make setup              Clone dbt-core and dbt-sqlserver if missing"
	@echo "  make clone-dbt-core     Clone dbt-labs/dbt-core into ./dbt-core"
	@echo "  make clone-dbt-sqlserver  Clone dbt-msft/dbt-sqlserver into ./dbt-sqlserver"
	@echo "  make update             git pull both repos on their current branch"
	@echo "  make status             git status for both repos"
	@echo ""
	@echo "Override remotes, e.g. to point at your own fork:"
	@echo "  make setup DBT_SQLSERVER_URL=https://github.com/<you>/dbt-sqlserver.git"
	@echo ""
	@echo "Local SQL Server test server (reuses dbt-sqlserver's docker-compose):"
	@echo "  make test-env           Create dbt-sqlserver/test.env from its sample (once)"
	@echo "  make server             Start a local SQL Server container"
	@echo "  make server-logs        Tail the container logs"
	@echo "  make server-stop        Stop the container"

setup: clone-dbt-core clone-dbt-sqlserver

clone-dbt-core:
	@if [ -d dbt-core/.git ]; then \
		echo "dbt-core/ already present, skipping clone"; \
	else \
		git clone $(DBT_CORE_URL) dbt-core; \
	fi

clone-dbt-sqlserver:
	@if [ -d dbt-sqlserver/.git ]; then \
		echo "dbt-sqlserver/ already present, skipping clone"; \
	else \
		git clone $(DBT_SQLSERVER_URL) dbt-sqlserver; \
	fi

update:
	@for repo in dbt-core dbt-sqlserver; do \
		if [ -d $$repo/.git ]; then \
			echo "== $$repo =="; \
			git -C $$repo pull; \
		else \
			echo "== $$repo missing, run 'make setup' first =="; \
		fi \
	done

status:
	@for repo in dbt-core dbt-sqlserver; do \
		if [ -d $$repo/.git ]; then \
			echo "== $$repo =="; \
			git -C $$repo status -sb; \
		else \
			echo "== $$repo missing =="; \
		fi \
	done

# --- Local SQL Server for live/functional testing ---
#
# Reuses dbt-sqlserver's own docker-compose.yml + `make server` target
# (docker-compose builds a SQL Server 2022 image via devops/server.Dockerfile)
# instead of duplicating that setup here. See plan/04-testing-and-validation.md.

test-env: clone-dbt-sqlserver
	@if [ -f $(DBT_SQLSERVER_DIR)/test.env ]; then \
		echo "$(DBT_SQLSERVER_DIR)/test.env already present, leaving as-is"; \
	else \
		cp $(DBT_SQLSERVER_DIR)/test.env.sample $(DBT_SQLSERVER_DIR)/test.env; \
		echo "Created $(DBT_SQLSERVER_DIR)/test.env from test.env.sample."; \
		echo "It's gitignored in dbt-sqlserver/ already. Review SA password /"; \
		echo "SQLSERVER_TEST_BACKEND before running functional tests -- the"; \
		echo "sample password is a local-dev-only default, not a secret."; \
	fi

server: clone-dbt-sqlserver test-env
	$(MAKE) -C $(DBT_SQLSERVER_DIR) server

server-stop: clone-dbt-sqlserver
	cd $(DBT_SQLSERVER_DIR) && docker compose down

server-logs: clone-dbt-sqlserver
	cd $(DBT_SQLSERVER_DIR) && docker compose logs -f
