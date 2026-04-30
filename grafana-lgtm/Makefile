.PHONY: help up k8s-base lgtm build deploy verify status clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

help:
	@echo "Grafana LGTM logging demo on Rancher Desktop Kubernetes"
	@echo ""
	@echo "Targets:"
	@echo "  make up       Deploy namespace, alarik (S3), Loki, Alloy, Grafana, app"
	@echo "  make verify   Emit logs and verify they are in Loki and in alarik bucket"
	@echo "  make status   Show namespace resources"
	@echo "  make clean    Remove namespace and local app image"

k8s-base:
	./scripts/01-apply-k8s-base.sh

lgtm:
	./scripts/02-deploy-lgtm.sh

build:
	./scripts/03-build-python-image.sh

deploy:
	./scripts/04-deploy-python-app.sh

verify:
	./scripts/05-verify.sh

up: k8s-base lgtm build deploy verify

status:
	./scripts/13-status.sh

clean:
	./scripts/15-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl create --dry-run=client --validate=false -f k8s/
