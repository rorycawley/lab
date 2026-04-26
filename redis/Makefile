.PHONY: help up services build k8s-base deploy verify port-forward test test-all status full-check clean clean-k8s clean-services clean-image clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080

help:
	@echo "Redis cache-aside demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up            Start services, build image, apply k8s, deploy app, verify"
	@echo "  make port-forward  Forward localhost:8080 to the app Service; blocks until Ctrl+C"
	@echo "  make test          Hit /healthz, /readyz, /items, /cache, /stats; needs port-forward running"
	@echo "  make test-all      Run smoke test with a temporary port-forward"
	@echo "  make status        Show Kubernetes, Docker, image, log, and port state"
	@echo "  make full-check    Run up, test-all, then clean even if a step fails"
	@echo "  make clean         Remove namespace, containers, volumes, network, image, logs"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make clean"
	@echo ""
	@echo "RedisInsight UI (after make up):"
	@echo "  open http://localhost:5540"
	@echo "  Add database: host=redis-demo-server, port=6379, password=redispass"
	@echo "  Worth a click each:"
	@echo "    Browser   -> keys matching item:*       cached items the app has populated"
	@echo "    Workbench -> KEYS item:* / TTL item:1   inspect what is currently cached and TTLs"

services:
	./scripts/01-start-services.sh

build:
	./scripts/02-build-image.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

deploy:
	./scripts/04-deploy-app.sh

verify:
	./scripts/05-verify.sh

up: services build k8s-base deploy verify

port-forward:
	./scripts/06-port-forward.sh

test:
	APP_URL="$(APP_URL)" ./scripts/07-test.sh

test-all:
	APP_URL="$(APP_URL)" ./scripts/08-with-port-forward.sh all

status:
	./scripts/09-status.sh

full-check:
	./scripts/11-full-check.sh

clean-k8s:
	kubectl delete namespace redis-demo --ignore-not-found=true

clean-services:
	docker compose down -v --remove-orphans

clean-image:
	docker image rm -f redis-demo-app:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/redis-demo-pf.log

clean:
	./scripts/10-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl apply --dry-run=client -f k8s/
