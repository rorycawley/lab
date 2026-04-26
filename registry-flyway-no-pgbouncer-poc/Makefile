.PHONY: help \
	step-1-postgres step-2-build step-3-k8s-base step-4-connectivity \
	step-5-migrate step-6-deploy step-7-verify step-8-port-forward \
	up smoke check-tools wait-for-app port-forward clean clean-k8s clean-db

# Use bash so recipes can rely on 'set -o pipefail' to surface
# failures on the left side of a pipe (e.g. curl ... | jq .).
SHELL := /bin/bash

# The 'up' pipeline is order-dependent. Disable parallel execution
# so 'make -j up' (or MAKEFLAGS=-j) cannot interleave the steps.
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "Registry Flyway no-PgBouncer POC"
	@echo ""
	@echo "Common targets:"
	@echo "  make up             Run steps 1-7: databases, image, k8s base, connectivity, migrations, app, verify"
	@echo "  make port-forward   Forward localhost:8080 to the app Service; BLOCKS until Ctrl+C"
	@echo "  make smoke          Wait for the app, then exercise its endpoints (needs port-forward running)"
	@echo "  make clean          Delete Kubernetes namespace and Docker Postgres volumes"
	@echo "  make clean-k8s      Delete only the Kubernetes namespace (keeps Postgres data)"
	@echo "  make clean-db       Stop and remove only Docker Postgres containers and volumes"
	@echo ""
	@echo "============================================================"
	@echo "  IMPORTANT: 'make port-forward' BLOCKS the terminal."
	@echo "  You need TWO shells to run port-forward and smoke together."
	@echo "============================================================"
	@echo ""
	@echo "  Recommended flow (two terminals):"
	@echo "    Terminal 1:  make up"
	@echo "                 make port-forward       # blocks here until you Ctrl+C"
	@echo "    Terminal 2:  make smoke"
	@echo "                 make clean              # when done"
	@echo "    Terminal 1:  Ctrl+C                  # stops port-forward; trap cleans up kubectl"
	@echo ""
	@echo "  Single-terminal alternative (background port-forward):"
	@echo "    make port-forward &                  # backgrounded; logs to your shell"
	@echo "    make smoke                           # waits for /healthz, then runs"
	@echo "    kill %1                              # or 'fg' then Ctrl+C"
	@echo ""
	@echo "Individual steps:"
	@echo "  make step-1-postgres"
	@echo "  make step-2-build"
	@echo "  make step-3-k8s-base"
	@echo "  make step-4-connectivity"
	@echo "  make step-5-migrate"
	@echo "  make step-6-deploy"
	@echo "  make step-7-verify"
	@echo "  make step-8-port-forward"

step-1-postgres:
	./scripts/01-start-postgres.sh

step-2-build:
	./scripts/02-build-python-image.sh

step-3-k8s-base:
	./scripts/03-apply-k8s-base.sh

step-4-connectivity:
	./scripts/04-test-k8s-db-connectivity.sh

step-5-migrate:
	./scripts/05-run-migrations.sh

step-6-deploy:
	./scripts/06-deploy-python-app.sh

step-7-verify:
	PAGER=cat ./scripts/07-verify.sh

step-8-port-forward:
	./scripts/08-port-forward.sh

up: step-1-postgres step-2-build step-3-k8s-base step-4-connectivity step-5-migrate step-6-deploy step-7-verify

port-forward: step-8-port-forward

check-tools:
	@command -v jq >/dev/null || { echo "smoke needs 'jq' on PATH (brew install jq)"; exit 1; }
	@command -v curl >/dev/null || { echo "smoke needs 'curl' on PATH"; exit 1; }

wait-for-app:
	@echo "Waiting for $(APP_URL)/healthz (start 'make port-forward' in another terminal if this hangs)..."
	@for i in $$(seq 1 60); do \
		curl -sf $(APP_URL)/healthz >/dev/null && echo "App is ready." && exit 0; \
		sleep 1; \
	done; \
	echo "App did not become ready at $(APP_URL)/healthz after 60s." >&2; exit 1

smoke: check-tools wait-for-app
	@set -euo pipefail; \
	TS=$$(date +%s)$$$$; \
	echo "==> GET /healthz";          curl -fsS $(APP_URL)/healthz | jq .; \
	echo "==> GET /db-healthz";       curl -fsS $(APP_URL)/db-healthz | jq .; \
	echo "==> GET /companies";        curl -fsS $(APP_URL)/companies | jq .; \
	echo "==> GET /events";           curl -fsS $(APP_URL)/events | jq .; \
	echo "==> POST /companies/register (company_number=$$TS)"; \
	curl -fsS -X POST $(APP_URL)/companies/register \
		-H 'Content-Type: application/json' \
		-d "{\"company_number\":\"$$TS\",\"company_name\":\"Smoke Test $$TS\",\"registered_address\":\"7 Harbour Road, Galway\"}" \
		| jq .; \
	echo "==> GET /companies (after register)"; curl -fsS $(APP_URL)/companies | jq .; \
	echo "==> GET /events (after register)";    curl -fsS $(APP_URL)/events | jq .

clean-k8s:
	kubectl delete namespace registry-poc --ignore-not-found=true
	@echo "Deleted Kubernetes namespace registry-poc."

clean-db:
	docker compose down -v
	@echo "Removed Docker PostgreSQL containers and volumes."

clean: clean-k8s clean-db
	@echo "Cleanup complete."
