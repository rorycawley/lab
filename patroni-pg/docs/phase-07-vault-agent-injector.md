# Phase 7: Vault Agent Injector


Phase 7 installs the Vault Agent Injector and proves that annotated Pods are
mutated with a Vault Agent init container and sidecar.

Goal:

```text
The application container can consume a rendered local credential file without
calling the Vault API itself.
```

This phase installs:

```text
Helm release: vault-agent-injector
Deployment: vault/vault-agent-injector-agent-injector
MutatingWebhookConfiguration: vault-agent-injector-agent-injector-cfg
Smoke Pod: demo/vault-injector-smoke
Rendered file: /vault/secrets/db-creds
```

The smoke Pod uses `demo/demo-app` and these annotations:

```yaml
vault.hashicorp.com/agent-inject: "true"
vault.hashicorp.com/role: "demo-app"
vault.hashicorp.com/service: "https://vault.vault.svc.cluster.local:8200"
vault.hashicorp.com/tls-secret: "vault-ca"
vault.hashicorp.com/ca-cert: "/vault/tls/ca.crt"
vault.hashicorp.com/tls-server-name: "vault.vault.svc.cluster.local"
vault.hashicorp.com/agent-inject-secret-db-creds: "database/creds/demo-app-runtime"
vault.hashicorp.com/agent-inject-perms-db-creds: "0400"
```

Acceptance criteria:

- Vault Agent Injector Deployment is ready
- Vault Agent Injector mutating webhook exists
- annotated smoke Pod is mutated
- Vault Agent init container is injected
- Vault Agent sidecar container is injected
- `/vault/secrets/db-creds` exists in the app container
- rendered file contains `DB_USERNAME` and `DB_PASSWORD`
- rendered file permissions are `0400`
- an unannotated Pod is not injected

Important limitation:

```text
This phase proves injection and file rendering only. The Python app that reads
the file and reconnects with dynamic credentials comes in Phase 8.
```

Run Phase 7:

```sh
make vault-injector
```

Verify only Vault Agent Injector:

```sh
make verify-vault-injector
```

