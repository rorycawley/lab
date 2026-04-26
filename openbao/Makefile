.PHONY: help up services build k8s-base bootstrap deploy verify port-forward test test-with-port-forward test-all status full-check clean clean-k8s clean-services clean-image clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "OpenBao + Postgres demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up                 Start services, build image, apply k8s, bootstrap OpenBao, deploy app, verify"
	@echo "  make port-forward       Forward localhost:8080 to the app Service; blocks until Ctrl+C"
	@echo "  make test               Hit /healthz, /db-healthz, /query/static, /query/dynamic; needs port-forward running"
	@echo "  make test-all           Start a temporary port-forward, run test, then stop it"
	@echo "  make status             Show Kubernetes, Docker, image, log, and port state"
	@echo "  make full-check         Run up, test-all, then clean even if a step fails"
	@echo "  make clean              Remove namespace, containers, volumes, network, image, logs"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make clean"
	@echo ""
	@echo "OpenBao UI (after make up):"
	@echo "  open http://localhost:8200/ui    # Method: Token, Token: root"
	@echo "  Worth a click each:"
	@echo "    Secrets   -> kv/postgres                       static creds /query/static reads"
	@echo "    Secrets   -> database/roles/poc-role           click 'Generate credentials' to mint a dynamic user"
	@echo "    Secrets   -> database/config/postgres-pocdb    connection OpenBao uses as vaultadmin"
	@echo "    Access    -> AppRole/poc-app                   role the app authenticates as"
	@echo "    Policies  -> poc-app                           two paths the app is permitted to read"
	@echo "    Access    -> Leases                            active dynamic users with TTLs ticking down"

services:
	./scripts/01-start-services.sh

build:
	./scripts/02-build-python-image.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

bootstrap:
	./scripts/04-bootstrap-openbao.sh

deploy:
	./scripts/05-deploy-python-app.sh

verify:
	./scripts/06-verify.sh

up: services build k8s-base bootstrap deploy verify

port-forward:
	./scripts/07-port-forward.sh

test:
	APP_URL="$(APP_URL)" ./scripts/08-test.sh

test-with-port-forward:
	APP_URL="$(APP_URL)" ./scripts/09-with-port-forward.sh test

test-all:
	APP_URL="$(APP_URL)" ./scripts/09-with-port-forward.sh all

status:
	./scripts/10-status.sh

full-check:
	./scripts/12-full-check.sh

clean-k8s:
	kubectl delete namespace openbao-demo --ignore-not-found=true

clean-services:
	docker compose down -v --remove-orphans

clean-image:
	docker image rm -f openbao-demo-app:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/openbao-demo-port-forward.log

clean:
	./scripts/11-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl apply --dry-run=client -f k8s/
