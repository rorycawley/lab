.PHONY: help up k8s-base cert-manager tls postgres vault vault-config vault-injector build-app deploy-app netpol audit-drill audit-report rotate revoke-runtime recover recover-vault tf-plan tf-destroy doctor reset evidence verify verify-phase-1 verify-postgres verify-vault verify-vault-auth verify-vault-policies verify-vault-db verify-vault-injector verify-app verify-pool verify-tls verify-netpol verify-harden verify-audit verify-rrr verify-iac status clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

help:
	@echo "Vault + PostgreSQL security demo"
	@echo ""
	@echo "Targets:"
	@echo "  make up               Apply phases 1-16 and verify"
	@echo "  make doctor           Phase 16: preflight environment check"
	@echo "  make reset            Phase 16: timed clean + up + verify"
	@echo "  make k8s-base         Apply namespaces and ServiceAccount"
	@echo "  make cert-manager     Install cert-manager"
	@echo "  make tls              Issue demo TLS certificates with cert-manager"
	@echo "  make postgres         Apply TLS-enabled Docker Compose PostgreSQL"
	@echo "  make vault            Apply dev-mode Vault behind a TLS proxy"
	@echo "  make vault-config     Phase 16: apply Vault auth, policies, DB engine, audit via Terraform"
	@echo "  make vault-injector   Install Vault Agent Injector and smoke Pod"
	@echo "  make build-app        Build Phase 8 Python app image"
	@echo "  make deploy-app       Deploy Phase 8 Python app"
	@echo "  make netpol           Apply Phase 12 NetworkPolicies"
	@echo "  make audit-drill      Run Phase 14 denied-attempt drill and capture evidence"
	@echo "  make audit-report     Emit Phase 14 structured audit evidence as JSON"
	@echo "  make rotate           Phase 15: rotate the Vault database engine root credential"
	@echo "  make revoke-runtime   Phase 15: revoke ALL outstanding runtime credentials (destructive)"
	@echo "  make recover          Phase 15: Vault outage + PostgreSQL restart drills"
	@echo "  make recover-vault    Phase 15: re-bootstrap a destroyed dev-mode Vault"
	@echo "  make tf-plan          Phase 16: terraform plan against the live Vault"
	@echo "  make tf-destroy       Phase 16: terraform destroy (Vault config only)"
	@echo "  make evidence         Show Phase 9 security evidence"
	@echo "  make verify           Verify phases 1-16"
	@echo "  make verify-phase-1   Verify namespaces, ServiceAccount, and no extra RBAC"
	@echo "  make verify-postgres  Verify PostgreSQL roles, CRUD, and denied operations"
	@echo "  make verify-vault     Verify Vault status and audit evidence"
	@echo "  make verify-vault-auth Verify Vault Kubernetes auth bindings"
	@echo "  make verify-vault-policies Verify Vault policy boundaries"
	@echo "  make verify-vault-db  Verify dynamic PostgreSQL credentials and revocation"
	@echo "  make verify-vault-injector Verify sidecar injection and rendered file"
	@echo "  make verify-app       Verify Python app dynamic credential flow"
	@echo "  make verify-pool      Verify pooled connection behavior"
	@echo "  make verify-tls       Verify cert-manager TLS paths"
	@echo "  make verify-netpol    Verify NetworkPolicy allowed and denied flows"
	@echo "  make verify-harden    Verify Pod Security Admission and per-Pod hardening"
	@echo "  make verify-audit     Verify the Phase 14 audit evidence report"
	@echo "  make verify-rrr       Verify Phase 15 rotation, revocation, and recovery drills"
	@echo "  make verify-iac       Verify Phase 16 IaC drift (Terraform + NetworkPolicy)"
	@echo "  make status           Show Kubernetes, PostgreSQL, and Vault resources"
	@echo "  make clean            Remove demo, vault, and database namespaces"
	@echo "  make check-local      Dry-run Kubernetes manifests"
	@echo ""
	@echo "Typical flow:"
	@echo "  make doctor"
	@echo "  make check-local"
	@echo "  make up"
	@echo "  make verify"
	@echo "  make status"
	@echo "  make clean"

up: k8s-base cert-manager tls postgres vault vault-config vault-injector build-app deploy-app netpol verify

k8s-base:
	./scripts/01-apply-k8s-foundation.sh

cert-manager: k8s-base
	./scripts/22-install-cert-manager.sh

tls: cert-manager
	./scripts/23-apply-tls-certificates.sh

postgres: tls
	./scripts/05-apply-postgres.sh

vault: tls
	./scripts/07-apply-vault.sh

vault-config: k8s-base postgres vault
	./scripts/36-apply-terraform.sh

vault-injector: vault-config
	./scripts/15-install-vault-agent-injector.sh

build-app:
	./scripts/17-build-python-app.sh

deploy-app: vault-injector build-app
	./scripts/18-deploy-python-app.sh

netpol: deploy-app
	./scripts/25-apply-networkpolicies.sh

verify: verify-phase-1 verify-postgres verify-vault verify-vault-auth verify-vault-policies verify-vault-db verify-vault-injector verify-app verify-pool verify-tls verify-netpol verify-harden verify-audit verify-rrr verify-iac

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

verify-app:
	./scripts/19-verify-python-app.sh

verify-pool:
	./scripts/21-verify-connection-pool.sh

verify-tls:
	./scripts/24-verify-tls.sh

verify-netpol:
	./scripts/26-verify-networkpolicies.sh

verify-harden:
	./scripts/27-verify-container-hardening.sh

audit-drill:
	./scripts/28-audit-drill.sh

audit-report:
	./scripts/29-audit-evidence-report.sh

verify-audit:
	./scripts/30-verify-audit.sh

rotate:
	./scripts/31-verify-rotation.sh

revoke-runtime:
	./scripts/32-verify-revocation.sh

recover:
	./scripts/33-verify-recovery.sh

recover-vault:
	./scripts/34-recover-vault.sh

verify-rrr:
	./scripts/35-verify-rrr.sh

verify-iac:
	./scripts/37-verify-iac-drift.sh

doctor:
	./scripts/38-doctor.sh

reset:
	./scripts/39-reset.sh

tf-plan:
	@./scripts/36-apply-terraform.sh --plan-only 2>/dev/null || true
	@bash -c 'set -e; \
	  vault_token=$$(kubectl get secret vault-dev-root-token --namespace vault -o jsonpath="{.data.token}" | base64 --decode); \
	  kubectl port-forward --namespace vault deployment/vault 18200:8201 >/tmp/tfplan-pf.log 2>&1 & \
	  pf_pid=$$!; \
	  trap "kill $$pf_pid 2>/dev/null || true" EXIT; \
	  sleep 2; \
	  export VAULT_ADDR=http://127.0.0.1:18200; \
	  export VAULT_TOKEN=$$vault_token; \
	  cd terraform && terraform plan -input=false'

tf-destroy:
	@bash -c 'set -e; \
	  vault_token=$$(kubectl get secret vault-dev-root-token --namespace vault -o jsonpath="{.data.token}" | base64 --decode); \
	  kubectl port-forward --namespace vault deployment/vault 18200:8201 >/tmp/tfdestroy-pf.log 2>&1 & \
	  pf_pid=$$!; \
	  trap "kill $$pf_pid 2>/dev/null || true" EXIT; \
	  sleep 2; \
	  export VAULT_ADDR=http://127.0.0.1:18200; \
	  export VAULT_TOKEN=$$vault_token; \
	  cd terraform && terraform destroy -input=false -auto-approve'

evidence:
	./scripts/20-security-evidence.sh

status:
	./scripts/03-status.sh

clean:
	./scripts/04-clean.sh

check-local:
	kubectl apply --dry-run=client -f k8s/
