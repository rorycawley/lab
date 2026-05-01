# Phase 5: Vault Policies


Phase 5 configures Vault authorization after Phase 4 proved Kubernetes
authentication.

Goal:

```text
Runtime and migration identities can authenticate to Vault, but each identity is
authorized only for its own future database credential path.
```

This phase creates:

```text
ServiceAccount: demo/demo-migrate
Vault policy: demo-app-runtime
Vault policy: demo-app-migrate
Vault auth role: demo-app
Vault auth role: demo-migrate
```

Runtime policy:

```hcl
path "database/creds/demo-app-runtime" {
  capabilities = ["read"]
}
```

Migration policy:

```hcl
path "database/creds/demo-app-migrate" {
  capabilities = ["read"]
}
```

Acceptance criteria:

- `demo/demo-app` can authenticate to Vault through role `demo-app`
- `demo/demo-app` receives only the `demo-app-runtime` policy
- runtime identity has `read` capability on `database/creds/demo-app-runtime`
- runtime identity has `deny` capability on `database/creds/demo-app-migrate`
- runtime identity has `deny` capability on Vault config paths such as `sys/auth`
- `demo/demo-migrate` can authenticate to Vault through role `demo-migrate`
- `demo/demo-migrate` receives only the `demo-app-migrate` policy
- migration identity has `read` capability on `database/creds/demo-app-migrate`
- migration identity has `deny` capability on `database/creds/demo-app-runtime`
- migration identity has `deny` capability on Vault config paths such as `sys/auth`
- runtime ServiceAccount cannot authenticate as the migration Vault role

Important limitation:

```text
database/creds/demo-app-runtime and database/creds/demo-app-migrate do not issue
credentials yet. Phase 5 proves policy boundaries. Phase 6 configures the Vault
database secrets engine so those paths become real dynamic credential endpoints.
```

Run Phase 5:

```sh
make vault-policies
```

Verify only Vault policies:

```sh
make verify-vault-policies
```

