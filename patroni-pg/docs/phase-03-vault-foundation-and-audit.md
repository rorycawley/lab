# Phase 3: Vault Foundation and Audit


Phase 3 deploys Vault and proves it is reachable, initialized, unsealed, and
emitting audit evidence. It does not configure Kubernetes auth, Vault policy, the
database secrets engine, or application credential injection yet.

Goal:

```text
Run Vault, understand the unseal model, and capture audit evidence before any
application trusts Vault.
```

This phase uses Vault dev mode:

```text
Vault starts initialized.
Vault starts unsealed.
The dev root token is generated into a Kubernetes Secret at apply time.
Vault data is not durable.
Restarting Vault loses configuration and state.
This is for learning the control flow, not for production.
```

Production-shaped Vault will be handled later with persistent storage, an
explicit unseal or auto-unseal model, and stronger audit storage.

Acceptance criteria:

- Vault is running in namespace `vault`
- Service `vault.vault.svc.cluster.local:8200` exists
- `vault status` works inside the Vault Pod
- Vault is initialized
- Vault is unsealed
- the chosen unseal model is documented as dev mode
- Vault audit logging is enabled
- an allowed Vault request is visible in audit logs
- a denied Vault request is visible in audit logs
- audit backpressure risk is documented

Audit caveat:

```text
This phase enables one file audit device to stdout for demo visibility.
For production, use at least two audit devices and monitor the backing storage or
logging pipeline. A blocked audit device can affect Vault availability.
```

Run Phase 3:

```sh
make vault
```

Verify only Vault foundation and audit:

```sh
make verify-vault
```

