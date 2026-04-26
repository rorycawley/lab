.PHONY: help up services build k8s-base deploy verify port-forward test test-all status full-check clean clean-k8s clean-services clean-images clean-logs check-local

SHELL := /bin/bash
.NOTPARALLEL:

PUBLISHER_URL  ?= http://localhost:8080
SUBSCRIBER_URL ?= http://localhost:8081

help:
	@echo "RabbitMQ + Postgres outbox-pattern demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up            Start services, build images, apply k8s, deploy publisher+subscriber, verify"
	@echo "  make port-forward  Forward 8080->publisher, 8081->subscriber; blocks until Ctrl+C"
	@echo "  make test          Run smoke test against existing port-forwards"
	@echo "  make test-all      Run smoke test with a temporary port-forward"
	@echo "  make status        Show Kubernetes, Docker, image, log, and port state"
	@echo "  make full-check    Run up, test-all, then clean even if a step fails"
	@echo "  make clean         Remove namespace, containers, volumes, network, images, logs"
	@echo ""
	@echo "Typical flow:"
	@echo "  make up"
	@echo "  make test-all"
	@echo "  make clean"
	@echo ""
	@echo "RabbitMQ UI (after make up):"
	@echo "  open http://localhost:15672    # tasks / tasks"
	@echo "  Worth a click each:"
	@echo "    Exchanges -> integration.events     topic exchange the relay publishes to"
	@echo "    Queues    -> task.subscriber        durable queue bound with task.*"
	@echo "    Connections                         publisher (relay) + subscriber (consumer)"

services:
	./scripts/01-start-services.sh

build:
	./scripts/02-build-images.sh

k8s-base:
	./scripts/03-apply-k8s-base.sh

deploy:
	./scripts/04-deploy-apps.sh

verify:
	./scripts/05-verify.sh

up: services build k8s-base deploy verify

port-forward:
	./scripts/06-port-forward.sh

test:
	PUBLISHER_URL="$(PUBLISHER_URL)" SUBSCRIBER_URL="$(SUBSCRIBER_URL)" ./scripts/07-test.sh

test-all:
	PUBLISHER_URL="$(PUBLISHER_URL)" SUBSCRIBER_URL="$(SUBSCRIBER_URL)" ./scripts/08-with-port-forward.sh all

status:
	./scripts/09-status.sh

full-check:
	./scripts/11-full-check.sh

clean-k8s:
	kubectl delete namespace rabbitmq-demo --ignore-not-found=true

clean-services:
	docker compose down -v --remove-orphans

clean-images:
	docker image rm -f rabbitmq-demo-publisher:demo  || true
	docker image rm -f rabbitmq-demo-subscriber:demo || true

clean-logs:
	rm -rf logs
	rm -f /tmp/rabbitmq-demo-pub-pf.log /tmp/rabbitmq-demo-sub-pf.log

clean:
	./scripts/10-clean.sh

check-local:
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/publisher/main.py
	PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile app/subscriber/main.py
	rm -rf app/publisher/__pycache__ app/subscriber/__pycache__
	kubectl apply --dry-run=client -f k8s/
