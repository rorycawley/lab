.PHONY: help up k8s-base cert-manager tls postgres vault vault-config vault-injector build-app deploy-app netpol audit-drill audit-report rotate revoke-runtime recover recover-vault tf-plan tf-destroy doctor reset evidence verify verify-phase-1 verify-postgres verify-vault verify-vault-auth verify-vault-policies verify-vault-db verify-vault-injector verify-app verify-pool verify-tls verify-netpol verify-harden verify-audit verify-rrr verify-iac status clean check-local

SHELL := /bin/bash
.NOTPARALLEL:

help:
	@echo "Vault + PostgreSQL security demo"
	@echo ""
	@echo "Common commands:"
	@echo "  make doctor          Preflight check (tools, cluster, docker, terraform)"
	@echo "  make up              Apply phases 1-16 from scratch and verify"
	@echo "  make verify          Re-run all verify scripts (phases 1-16)"
	@echo "  make reset           Timed clean -> up -> verify (full repeatability test)"
	@echo "  make clean           Tear down everything (namespaces, Compose, runtime, TF state)"
	@echo "  make evidence        Human-readable security evidence (markdown rendering)"
	@echo "  make status          Show current K8s, PostgreSQL, and Vault state"
	@echo ""
	@echo "Operational drills (Phase 15):"
	@echo "  make rotate          Rotate Vault DB engine root credential"
	@echo "  make revoke-runtime  Mass-revoke runtime credentials (DESTRUCTIVE)"
	@echo "  make recover         Vault outage + PostgreSQL restart drills"
	@echo "  make recover-vault   Re-bootstrap a destroyed dev-mode Vault"
	@echo "  make verify-rrr      Run rotation + revocation + recovery as one chain"
	@echo ""
	@echo "Audit and IaC:"
	@echo "  make audit-drill     Phase 14 denied-attempt drill (writes to .runtime/audit/)"
	@echo "  make audit-report    Structured audit report as JSON (.runtime/audit/report.json)"
	@echo "  make verify-audit    Verify the Phase 14 audit evidence report"
	@echo "  make verify-iac      Drift check: terraform plan + NetworkPolicy diff"
	@echo "  make tf-plan         Show pending Vault config changes"
	@echo "  make tf-destroy      Destroy Terraform-managed Vault config"
	@echo ""
	@echo "Per-phase apply (rarely needed individually -- 'make up' chains them):"
	@echo "  make k8s-base, cert-manager, tls, postgres, vault, vault-config,"
	@echo "  vault-injector, build-app, deploy-app, netpol"
	@echo ""
	@echo "Per-phase verify (CI / debugging):"
	@echo "  make verify-phase-1, verify-postgres, verify-vault, verify-vault-auth,"
	@echo "  verify-vault-policies, verify-vault-db, verify-vault-injector, verify-app,"
	@echo "  verify-pool, verify-tls, verify-netpol, verify-harden"
	@echo ""
	@echo "Other:"
	@echo "  make check-local     Dry-run all Kubernetes manifests"
	@echo ""
	@echo "Typical flow: make doctor && make up && make status"

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
	./scripts/29-audit-evidence-report.sh >/dev/null
	@cat .runtime/audit/report.md

status:
	./scripts/03-status.sh

clean:
	./scripts/04-clean.sh

check-local:
	kubectl apply --dry-run=client -f k8s/
