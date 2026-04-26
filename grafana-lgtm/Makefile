.PHONY: help up k8s-base lgtm build deploy verify port-forward-grafana port-forward-app test generate-traffic verify-telemetry verify-alerts test-with-port-forward traffic-with-port-forward telemetry-with-port-forward alerts-with-port-forward test-all status full-check clean clean-k8s clean-image clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

APP_URL ?= http://localhost:8080
GRAFANA_URL ?= http://localhost:3000

help:
	@echo "Grafana LGTM + OpenTelemetry Kubernetes demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up                    Apply k8s base, deploy LGTM, build app image, deploy app, verify"
	@echo "  make port-forward-grafana  Forward localhost:3000 to Grafana; blocks until Ctrl+C"
	@echo "  make port-forward-app      Forward localhost:8080 to the Python app; blocks until Ctrl+C"
	@echo "  make test                  Exercise the app and emit logs/traces; needs app port-forward running"
	@echo "  make generate-traffic      Emit repeated demo traffic; needs app port-forward running"
	@echo "  make verify-telemetry      Query Loki, Tempo, and Mimir through Grafana; needs Grafana port-forward"
	@echo "  make verify-alerts         Check provisioned Grafana alert rules; needs Grafana port-forward"
	@echo "  make test-with-port-forward Start temporary forwards, run test, then stop them"
	@echo "  make traffic-with-port-forward Start temporary forwards, generate traffic, then stop them"
	@echo "  make telemetry-with-port-forward Start temporary forwards, verify backend telemetry, then stop them"
	@echo "  make alerts-with-port-forward Start temporary forwards, verify alert rules, then stop them"
	@echo "  make test-all              Start temporary forwards, run test + traffic + telemetry + alerts"
	@echo "  make status                Show Kubernetes, image, log, and local port state"
	@echo "  make full-check            Run up, test-all, then clean even if a step fails"
	@echo "  make clean                 Remove namespace, local image, logs, and port-forward temp files"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make port-forward-grafana   # keep this running in a terminal"
	@echo "  open $(GRAFANA_URL)/d/python-app-otel/python-app-otel-logs-and-traces"
	@echo "  make clean"
	@echo ""
	@echo "Dashboard:"
	@echo "  1. Run: make port-forward-grafana"
	@echo "  2. Open: $(GRAFANA_URL)/d/python-app-otel/python-app-otel-logs-and-traces"
	@echo "  3. Login if prompted: admin / admin"
	@echo "  4. Dashboard name: Python App OTel Logs and Traces"

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

port-forward-grafana:
	./scripts/06-port-forward-grafana.sh

port-forward-app:
	./scripts/07-port-forward-app.sh

test:
	APP_URL="$(APP_URL)" ./scripts/08-test.sh

generate-traffic:
	APP_URL="$(APP_URL)" ./scripts/10-generate-traffic.sh

verify-telemetry:
	GRAFANA_URL="$(GRAFANA_URL)" ./scripts/11-verify-telemetry.sh

verify-alerts:
	GRAFANA_URL="$(GRAFANA_URL)" ./scripts/12-verify-alerts.sh

test-with-port-forward:
	APP_URL="$(APP_URL)" GRAFANA_URL="$(GRAFANA_URL)" ./scripts/09-with-port-forward.sh test

traffic-with-port-forward:
	APP_URL="$(APP_URL)" GRAFANA_URL="$(GRAFANA_URL)" ./scripts/09-with-port-forward.sh traffic

telemetry-with-port-forward:
	APP_URL="$(APP_URL)" GRAFANA_URL="$(GRAFANA_URL)" ./scripts/09-with-port-forward.sh telemetry

alerts-with-port-forward:
	APP_URL="$(APP_URL)" GRAFANA_URL="$(GRAFANA_URL)" ./scripts/09-with-port-forward.sh alerts

test-all:
	APP_URL="$(APP_URL)" GRAFANA_URL="$(GRAFANA_URL)" ./scripts/09-with-port-forward.sh all

status:
	./scripts/13-status.sh

full-check:
	./scripts/14-full-check.sh

clean-k8s:
	kubectl delete namespace grafana-lgtm-demo --ignore-not-found=true

clean-image:
	docker image rm -f otel-demo-app:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/grafana-lgtm-app-port-forward.log /tmp/grafana-lgtm-grafana-port-forward.log

clean:
	./scripts/15-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/main.py
	rm -rf app/__pycache__
	kubectl create --dry-run=client --validate=false -f k8s/
