# Phase 16: Repeatability and IaC


Phase 16 replaces the imperative `vault write` shell scripts that configured
Vault auth, policies, and the database secrets engine with a single declarative
Terraform module so the Vault state has a single source of truth, drift is
detectable, and the full bootstrap is reproducible.

Goal:

```text
Phase 1-15 built and proved a security model. Phase 16 makes that model
maintainable: a Terraform module is the source of truth for Vault config,
make verify-iac flags drift in either Vault config or NetworkPolicies,
make doctor preflights the operator's environment, make reset is a single
named operation with a stated time budget, and a CI workflow statically
validates every change.
```

This phase changes:

```text
terraform/                        NEW: full Vault configuration as code
  versions.tf, variables.tf, main.tf
  auth.tf       Kubernetes auth backend, demo-app and demo-migrate roles
  policies.tf   demo-app-runtime and demo-app-migrate policies
  database.tf   database mount, demo-postgres connection, runtime/migrate roles
  audit.tf      stdout audit device + on-disk file_disk audit device
  random.tf     random_password vault_admin + local file write to .runtime/
  outputs.tf    role names, policy names, audit paths, vault_admin password
scripts/36-apply-terraform.sh     NEW: port-forward + terraform apply + Postgres role apply
scripts/37-verify-iac-drift.sh    NEW: NetworkPolicy diff + terraform plan -detailed-exitcode
scripts/38-doctor.sh              NEW: preflight check for required tools and cluster
scripts/39-reset.sh               NEW: timed full clean + up + verify with reset SLA
.github/workflows/ci.yaml         NEW: shellcheck + yamllint + terraform fmt/validate + kubectl dry-run
scripts/08-verify-vault.sh        UPDATED: assert audit devices exist instead of enabling them
scripts/34-recover-vault.sh       UPDATED: re-applies Vault config via Terraform
Makefile                          vault-auth/policies/db collapsed into vault-config; new targets
REMOVED:
scripts/09-configure-vault-kubernetes-auth.sh
scripts/11-configure-vault-policies.sh
scripts/13-configure-vault-database-secrets.sh
```

The IaC promise extends to two surfaces:

```text
Terraform module (Vault state)
  Apply:   make vault-config       # also wired into make up
  Plan:    make tf-plan
  Destroy: make tf-destroy         # only the Terraform-managed Vault config
  Drift:   make verify-iac         # exits 2 if Vault state diverges from terraform/

NetworkPolicy manifests (k8s/15-networkpolicies.yaml)
  Apply:   make netpol             # also wired into make up
  Drift:   make verify-iac         # also diffs live NetPols vs the manifest
```

Reset SLA:

```text
make reset wraps clean + up + verify, prints elapsed wall-clock time, and
warns (soft fail) if the reset exceeded the documented budget. Default budget
is 6 minutes; override with RESET_BUDGET_SECONDS.
```

Acceptance criteria:

- `terraform/` contains complete declarations for Vault Kubernetes auth, the
  two roles, the two policies, the database secrets engine, the connection,
  the two database roles, and both audit devices
- `make vault-config` applies the Terraform module successfully and produces a
  cluster identical in behavior to the previous shell scripts
- `make verify-iac` exits 0 on a freshly applied cluster (no drift)
- After a manual change (e.g., `vault audit disable file_disk/` or
  `kubectl delete networkpolicy default-deny-all -n demo`), `make verify-iac`
  exits non-zero and names the drifted resource
- `make doctor` lists every required tool and exits non-zero if anything is
  missing
- `make reset` runs clean + up + verify end-to-end and reports elapsed time
- The CI workflow passes on the current branch (shellcheck, yamllint,
  terraform fmt + validate, kubectl client-side dry-run)
- All previously-passing verify scripts continue to pass after the conversion
- The three deleted scripts (09, 11, 13) have no remaining references in the
  repo
- `make recover-vault` re-bootstraps a destroyed Vault using the Terraform path

Documented limitations of this phase:

```text
Vault dev mode resets all state on Pod restart. Terraform state lives on the
operator's machine; if Vault dies, make recover-vault re-applies the same
declarative state to a freshly bootstrapped Vault. In production with
integrated storage (Raft), Terraform state and Vault state are independently
durable, and terraform plan is the canonical drift detector.

After make rotate (Phase 15), Terraform's view of the database connection
password is stale because rotate-root is a one-way operation. terraform plan
will show drift on the password field. The documented remediation is
terraform apply -refresh-only to mark the rotated password as the new known-
good state, or to re-run make vault-config to reset to the Terraform-known
password.

Image digest pinning protects against tag mutation but does not by itself
verify supply-chain integrity. Production needs an admission policy
(Kyverno, Sigstore policy-controller, or OPA Gatekeeper) that requires
signed images.
```

Run individual Phase 16 commands:

```sh
make doctor
make vault-config
make verify-iac
make tf-plan
make reset
```

The `verify` chain now ends with `verify-iac` so a full `make verify` confirms
both runtime behavior and configuration source-of-truth in a single pass.

