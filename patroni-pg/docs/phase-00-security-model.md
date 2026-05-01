# Phase 0: Security Model and Demo Contract


Phase 0 defines what the demo must prove before deploying services.

Acceptance criteria:

- namespaces are named `demo`, `vault`, and `database`
- workload identity is fixed as `demo/demo-app`
- database roles are defined as `schema_owner`, `migration_runtime`, and `app_runtime`
- Vault credential paths are fixed as:
  - `database/creds/demo-app-runtime`
  - `database/creds/demo-app-migrate`
- allowed network flows are defined as:
  - `demo/demo-app -> vault/vault:8200`
  - `demo/demo-app -> database/postgres:5432`
  - `vault/vault -> database/postgres:5432`
- denied cases are listed and later testable
- no runtime database password will live in Git, an image, an environment variable,
  Deployment YAML, or a Kubernetes Secret
- one command will eventually prove the demo end to end

Denied cases this repo must eventually prove:

- `demo/default` cannot authenticate to Vault as the app
- `other-namespace/demo-app` cannot authenticate to Vault as the app
- a random Pod cannot get runtime database credentials
- the runtime app cannot request migration credentials
- the runtime app cannot perform PostgreSQL DDL or admin operations
- unapproved Pods cannot reach Vault or PostgreSQL once NetworkPolicy is active
- revoked generated PostgreSQL credentials stop working

