# Phase 1: Kubernetes Foundation


Phase 1 creates only Kubernetes identity primitives. It does not deploy Vault,
PostgreSQL, an app, TLS, or NetworkPolicy yet.

Goal:

```text
Create namespaces, a dedicated app ServiceAccount, and a minimal RBAC baseline.
```

Acceptance criteria:

- namespace `demo` exists
- namespace `vault` exists
- namespace `database` exists
- ServiceAccount `demo-app` exists in namespace `demo`
- the app workload will not use the `default` ServiceAccount
- no Vault role will later be bound to the `default` ServiceAccount
- `demo/demo-app` cannot list Kubernetes Secrets
- `demo/demo-app` cannot list Pods
- `demo/demo-app` cannot read ConfigMaps
- `demo/demo-app` cannot read resources in other namespaces

Run Phase 1:

```sh
make up
```

Verify Phase 1:

```sh
make verify
```

Check current state:

```sh
make status
```

Remove Phase 1 resources:

```sh
make clean
```

Validate manifests without applying them:

```sh
make check-local
```

