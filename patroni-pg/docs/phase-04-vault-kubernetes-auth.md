# Phase 4: Vault Kubernetes Auth


Phase 4 configures Vault to verify Kubernetes workload identity using the
Kubernetes TokenReview API.

Goal:

```text
Vault accepts only the exact Kubernetes identity demo/demo-app for the demo app
role, and rejects default or wrong-namespace identities.
```

This phase uses the preferred in-cluster pattern:

```text
Vault runs as ServiceAccount vault/vault-auth.
Only vault/vault-auth is bound to system:auth-delegator.
Vault uses its own in-pod ServiceAccount token to call TokenReview.
Client application ServiceAccounts do not need TokenReview permission.
```

This phase creates:

```text
ServiceAccount: vault/vault-auth
ClusterRoleBinding: vault-tokenreview-auth-delegator
Vault auth method: kubernetes/
Vault auth role: demo-app
Bound identity: ServiceAccount demo-app in namespace demo
```

Acceptance criteria:

- ServiceAccount `vault-auth` exists in namespace `vault`
- `vault-auth` can create TokenReview requests
- `demo/demo-app` cannot create TokenReview requests
- Vault Kubernetes auth method is enabled
- Vault role `demo-app` is bound to `demo/demo-app`
- `demo/demo-app` can authenticate to Vault through Kubernetes auth
- `demo/default` cannot authenticate as the app
- `phase4-other/demo-app` cannot authenticate as the app

Run Phase 4:

```sh
make vault-auth
```

Verify only Vault Kubernetes auth:

```sh
make verify-vault-auth
```

