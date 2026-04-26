.PHONY: help up services build k8s-base bootstrap deploy verify port-forward test test-with-port-forward test-all status full-check clean clean-k8s clean-services clean-images clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "Keycloak + Postgres demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up                 Start services, build images, apply k8s, bootstrap Keycloak, deploy app, verify"
	@echo "  make port-forward       Forward localhost:8080 to the app Service; blocks until Ctrl+C"
	@echo "  make test               Hit /healthz, /query, /query/bad-token; needs port-forward running"
	@echo "  make test-all           Start a temporary port-forward, run test, then stop it"
	@echo "  make status             Show Kubernetes, Docker, image, log, and port state"
	@echo "  make full-check         Run up, test-all, then clean even if a step fails"
	@echo "  make clean              Remove namespace, containers, volumes, network, images, logs"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make clean"
	@echo ""
	@echo "Keycloak admin UI (after make up):"
	@echo "  open http://localhost:8180/    # admin / admin"
	@echo "  Worth a click each:"
	@echo "    Realms       -> poc                                  the realm the proxy trusts"
	@echo "    poc/Clients  -> poc-app                              confidential client, service accounts on"
	@echo "    poc/Clients  -> poc-app -> Credentials               the client_secret the app uses"
	@echo "    poc/Clients  -> poc-app -> Client scopes             default scope 'pg-role'"
	@echo "    poc/Client scopes -> pg-role -> Mappers              hardcoded 'pg_role: pgreader' claim"
	@echo "    poc/Sessions                                         a row appears each /query call"

services:
	./scripts/01-start-services.sh

build:
	./scripts/02-build-images.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

bootstrap:
	./scripts/04-bootstrap-keycloak.sh

deploy:
	./scripts/05-deploy-python-app.sh

verify:
	./scripts/06-verify.sh

up: build services k8s-base bootstrap deploy verify

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
	kubectl delete namespace keycloak-pg-demo --ignore-not-found=true

clean-services:
	docker compose down -v --remove-orphans

clean-images:
	docker image rm -f keycloak-pg-demo-app:demo || true
	docker image rm -f keycloak-pg-demo-proxy:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/keycloak-pg-demo-port-forward.log

clean:
	./scripts/11-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py proxy/proxy.py
	rm -rf app/__pycache__ proxy/__pycache__
	kubectl apply --dry-run=client -f k8s/
