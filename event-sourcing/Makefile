.PHONY: help up postgres build k8s-base connectivity migrate deploy verify port-forward test stress test-with-port-forward stress-with-port-forward test-all verify-db status full-check clean clean-k8s clean-db clean-image clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "Event Sourcing + CQRS demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up             Start Postgres, build image, apply k8s, run Flyway Jobs, deploy app, verify"
	@echo "  make port-forward   Forward localhost:8080 to the Kubernetes Service; blocks until Ctrl+C"
	@echo "  make test           Exercise command, projection, and query endpoints; needs port-forward running"
	@echo "  make stress         Stress idempotency and optimistic concurrency; needs port-forward running"
	@echo "  make test-all       Start a temporary port-forward, run test + stress, then stop it"
	@echo "  make verify-db      Query event-store and read-store tables directly"
	@echo "  make status         Show current Kubernetes, Docker, image, log, and port state"
	@echo "  make full-check     Run up, test-all, verify-db, then clean even if a step fails"
	@echo "  make clean          Remove namespace, containers, volumes, network, image, and logs"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make verify-db"
	@echo "  make clean"
	@echo ""
	@echo "Learning UI:"
	@echo "  make port-forward    # in one terminal"
	@echo "  open $(APP_URL)/ui   # buttons for command -> events -> projector -> read model"

postgres:
	./scripts/01-start-postgres.sh

build:
	./scripts/02-build-python-image.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

connectivity:
	./scripts/04-test-k8s-db-connectivity.sh

migrate:
	./scripts/05-run-migrations.sh

deploy:
	./scripts/06-deploy-python-app.sh

verify:
	./scripts/07-verify.sh

up: postgres build k8s-base connectivity migrate deploy verify

port-forward:
	./scripts/08-port-forward.sh

test:
	APP_URL="$(APP_URL)" ./scripts/09-test.sh

stress:
	APP_URL="$(APP_URL)" ./scripts/10-stress.sh

test-with-port-forward:
	APP_URL="$(APP_URL)" ./scripts/12-with-port-forward.sh test

stress-with-port-forward:
	APP_URL="$(APP_URL)" ./scripts/12-with-port-forward.sh stress

test-all:
	APP_URL="$(APP_URL)" ./scripts/12-with-port-forward.sh all

verify-db:
	./scripts/11-verify-db.sh

status:
	./scripts/13-status.sh

full-check:
	./scripts/14-full-check.sh

clean-k8s:
	kubectl delete namespace event-sourcing-demo --ignore-not-found=true

clean-db:
	docker compose down -v --remove-orphans

clean-image:
	docker image rm -f task-event-sourcing-api:demo || true

clean-logs:
	rm -rf logs

clean:
	./scripts/10-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	kubectl apply --dry-run=client -f k8s/
