.PHONY: help up services build k8s-base bootstrap deploy verify port-forward test test-with-port-forward test-all status full-check clean clean-k8s clean-services clean-images clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "OIDC BFF demo (Keycloak + Postgres + FastAPI)"
	@echo ""
	@echo "Targets:"
	@echo "  make up                 Start services, build image, apply k8s, bootstrap Keycloak, deploy app, verify"
	@echo "  make port-forward       Forward localhost:8080 to the app Service; blocks until Ctrl+C"
	@echo "  make test               Run the auth-code smoke test; needs port-forward running"
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
	@echo "Manual UI exploration (after make up + make port-forward):"
	@echo "  open http://localhost:8080/    # the BFF; click 'Log in', sign in as alice / alice"
	@echo "  open http://localhost:8180/    # Keycloak admin (admin / admin); poke around realm 'poc'"

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
	kubectl delete namespace keycloak-oidc-demo --ignore-not-found=true

clean-services:
	docker compose down -v --remove-orphans

clean-images:
	docker image rm -f keycloak-oidc-demo-app:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/keycloak-oidc-demo-port-forward.log

clean:
	./scripts/11-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl apply --dry-run=client -f k8s/
