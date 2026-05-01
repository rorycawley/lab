# Phase 8: Python App With Dynamic DB Credentials


Phase 8 replaces the injector smoke Pod with a real Python application that
uses the rendered Vault Agent file.

Goal:

```text
The app reads /vault/secrets/db-creds, connects to PostgreSQL with Vault-issued
runtime credentials, performs CRUD, and proves forbidden database operations are
denied.
```

This phase creates:

```text
Docker image: python-postgres-vault-demo:phase8
Deployment: demo/python-postgres-demo
Service: demo/python-postgres-demo
Vault-rendered file: /vault/secrets/db-creds
```

The app reads:

```text
DB_USERNAME and DB_PASSWORD from /vault/secrets/db-creds
```

The app does not receive:

```text
DB_PASSWORD as an environment variable
DB_PASSWORD in Deployment YAML
DB_PASSWORD in image contents
```

Acceptance criteria:

- Python app image builds
- app Deployment is created in namespace `demo`
- app runs as ServiceAccount `demo-app`
- Vault Agent sidecar is injected
- `/vault/secrets/db-creds` exists in the app container
- app has no database password in Deployment YAML
- `/healthz` works
- app connects as a Vault-generated `v-demo-app-runtime...` database user
- app can `INSERT`, `SELECT`, `UPDATE`, and `DELETE` `registry.company` rows
- app proves `DROP TABLE` is denied
- app proves `CREATE ROLE` is denied

Run Phase 8:

```sh
make deploy-app
```

Verify only the Python app:

```sh
make verify-app
```

