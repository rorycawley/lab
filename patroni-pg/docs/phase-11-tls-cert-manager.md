# Phase 11: TLS With cert-manager


Phase 11 installs cert-manager, creates a demo CA, issues service certificates,
and verifies that Vault and PostgreSQL are no longer treated as plaintext
endpoints.

Goal:

```text
Use cert-manager-issued certificates so Vault Agent, Vault, PostgreSQL, and the
Python app verify the endpoints they talk to.
```

This phase creates:

```text
Helm release: cert-manager
ClusterIssuer: demo-selfsigned-bootstrap
ClusterIssuer: demo-ca
Certificate: vault/vault-tls
Certificate: database/postgres-tls
ConfigMap: demo/postgres-ca
ConfigMap: vault/postgres-ca
Secret: demo/vault-ca
```

Vault remains a dev-mode server for this learning phase, but the Kubernetes
Service endpoint is HTTPS:

```text
Vault dev listener: 127.0.0.1:8201 inside the Pod
Vault service endpoint: https://vault.vault.svc.cluster.local:8200
TLS termination: nginx sidecar using the cert-manager vault-tls Secret
```

PostgreSQL still runs in Docker Compose, not as a Kubernetes StatefulSet. Its
server certificate is issued by cert-manager and exported to
`.runtime/tls/postgres` for Docker Compose to mount.

Acceptance criteria:

- cert-manager is installed
- demo CA ClusterIssuer is ready
- Vault certificate is issued by cert-manager
- PostgreSQL certificate is issued by cert-manager
- Vault HTTPS verifies with the demo CA
- Vault HTTPS does not verify without the demo CA
- Vault Agent uses HTTPS to reach Vault
- Vault database engine reaches PostgreSQL with `sslmode=verify-full`
- PostgreSQL accepts `verify-full` TLS connections
- PostgreSQL rejects plaintext TCP connections
- Python app connects to PostgreSQL with `sslmode=verify-full`
- Python app still uses Vault-generated dynamic credentials

Run Phase 11:

```sh
make tls
make postgres
make vault
make deploy-app
```

Verify only TLS:

```sh
make verify-tls
```

