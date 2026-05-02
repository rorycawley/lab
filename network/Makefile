.PHONY: help up tls build k8s-base certs deploy verify port-forward test test-all status full-check clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

LOCAL_PORT ?= 8443
APP_URL ?= https://localhost:$(LOCAL_PORT)
IMAGE ?= network-zero-trust-app:demo

help:
	@echo "Network zero-trust Kubernetes demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up            Generate certs, build image, deploy namespaces/apps/policies, verify"
	@echo "  make test-all      Run smoke test with a temporary port-forward to alpha"
	@echo "  make port-forward  Forward localhost:8443 to alpha-app HTTPS"
	@echo "  make status        Show namespaces, pods, services, policies, and recent logs"
	@echo "  make full-check    Run up, test-all, then clean even if a step fails"
	@echo "  make clean         Delete namespaces, generated certs, logs, and demo image"
	@echo "  make check-local   Syntax-check Python and dry-run manifests"
	@echo ""
	@echo "Variables:"
	@echo "  IMAGE=network-zero-trust-app:demo"
	@echo "  LOCAL_PORT=8443"

tls:
	./scripts/01-generate-certs.sh

build:
	IMAGE="$(IMAGE)" ./scripts/02-build-image.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

certs:
	./scripts/04-apply-certs.sh

deploy:
	IMAGE="$(IMAGE)" ./scripts/05-deploy-apps.sh

verify:
	./scripts/06-verify.sh

up: tls build k8s-base certs deploy verify

port-forward:
	LOCAL_PORT="$(LOCAL_PORT)" ./scripts/07-port-forward.sh

test:
	APP_URL="$(APP_URL)" IMAGE="$(IMAGE)" ./scripts/08-test.sh

test-all:
	APP_URL="$(APP_URL)" LOCAL_PORT="$(LOCAL_PORT)" IMAGE="$(IMAGE)" ./scripts/09-with-port-forward.sh

status:
	./scripts/10-status.sh

full-check:
	./scripts/12-full-check.sh

clean:
	IMAGE="$(IMAGE)" ./scripts/11-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl apply --dry-run=client --validate=false -f k8s/
