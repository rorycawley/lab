.PHONY: help certs postgres build k8s-base migrate deploy verify up port-forward test test-all status full-check clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "Kubernetes Migration Job + External Postgres demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up             Generate certs, start Postgres, build images, apply k8s, migrate, deploy, verify"
	@echo "  make test-all       Start a temporary port-forward and run API smoke tests"
	@echo "  make port-forward   Forward localhost:8080 to the API; blocks until Ctrl+C"
	@echo "  make status         Show Kubernetes, Docker, and image state"
	@echo "  make full-check     Run up + test-all, then clean"
	@echo "  make clean          Remove namespace, containers, volumes, images, generated certs, and logs"

certs:
	./scripts/01-generate-certs.sh

postgres:
	./scripts/02-start-postgres.sh

build:
	./scripts/03-build-images.sh

k8s-base:
	./scripts/04-apply-k8s-base.sh

migrate:
	./scripts/05-run-migrations.sh

deploy:
	./scripts/06-deploy-python-app.sh

verify:
	./scripts/07-verify.sh

up: postgres build k8s-base migrate deploy verify

port-forward:
	./scripts/08-port-forward.sh

test:
	APP_URL="$(APP_URL)" ./scripts/09-test.sh

test-all:
	APP_URL="$(APP_URL)" ./scripts/10-with-port-forward.sh

status:
	./scripts/11-status.sh

full-check:
	./scripts/13-full-check.sh

clean:
	./scripts/12-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py migrator/migrate.py
	find app migrator -name __pycache__ -type d -prune -exec rm -rf {} +
	kubectl apply --dry-run=client -f k8s/
