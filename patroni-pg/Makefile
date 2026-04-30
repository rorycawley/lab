.PHONY: help up k8s-base postgres vault vault-auth vault-policies vault-db vault-injector verify verify-phase-1 verify-postgres verify-vault verify-vault-auth verify-vault-policies verify-vault-db verify-vault-injector status clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

help:
	@echo "Vault + PostgreSQL security demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up               Apply phases 1-7 and verify"
	@echo "  make k8s-base         Apply namespaces and ServiceAccount"
	@echo "  make postgres         Apply PostgreSQL and wait for readiness"
	@echo "  make vault            Apply dev-mode Vault and wait for readiness"
	@echo "  make vault-auth       Configure Vault Kubernetes auth"
	@echo "  make vault-policies   Configure Vault runtime and migration policies"
	@echo "  make vault-db         Configure Vault database secrets engine"
	@echo "  make vault-injector   Install Vault Agent Injector and smoke Pod"
	@echo "  make verify           Verify phases 1-7"
	@echo "  make verify-phase-1   Verify namespaces, ServiceAccount, and no extra RBAC"
	@echo "  make verify-postgres  Verify PostgreSQL roles, CRUD, and denied operations"
	@echo "  make verify-vault     Verify Vault status and audit evidence"
	@echo "  make verify-vault-auth Verify Vault Kubernetes auth bindings"
	@echo "  make verify-vault-policies Verify Vault policy boundaries"
	@echo "  make verify-vault-db  Verify dynamic PostgreSQL credentials and revocation"
	@echo "  make verify-vault-injector Verify sidecar injection and rendered file"
	@echo "  make status           Show Kubernetes, PostgreSQL, and Vault resources"
	@echo "  make clean            Remove demo, vault, and database namespaces"
	@echo "  make check-local      Dry-run Kubernetes manifests"
	@echo ""
	@echo "Typical flow:"
	@echo "  make check-local"
	@echo "  make up"
	@echo "  make verify"
	@echo "  make status"
	@echo "  make clean"

up: k8s-base postgres vault vault-auth vault-policies vault-db vault-injector verify

k8s-base:
	./scripts/01-apply-k8s-foundation.sh

postgres:
	./scripts/05-apply-postgres.sh

vault:
	./scripts/07-apply-vault.sh

vault-auth: k8s-base vault
	./scripts/09-configure-vault-kubernetes-auth.sh

vault-policies: vault-auth
	./scripts/11-configure-vault-policies.sh

vault-db: postgres vault-policies
	./scripts/13-configure-vault-database-secrets.sh

vault-injector: vault-db
	./scripts/15-install-vault-agent-injector.sh

verify: verify-phase-1 verify-postgres verify-vault verify-vault-auth verify-vault-policies verify-vault-db verify-vault-injector

verify-phase-1:
	./scripts/02-verify-phase-1.sh

verify-postgres:
	./scripts/06-verify-postgres-permissions.sh

verify-vault:
	./scripts/08-verify-vault.sh

verify-vault-auth:
	./scripts/10-verify-vault-kubernetes-auth.sh

verify-vault-policies:
	./scripts/12-verify-vault-policies.sh

verify-vault-db:
	./scripts/14-verify-vault-database-secrets.sh

verify-vault-injector:
	./scripts/16-verify-vault-agent-injector.sh

status:
	./scripts/03-status.sh

clean:
	./scripts/04-clean.sh

check-local:
	kubectl apply --dry-run=client -f k8s/
