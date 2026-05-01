# Phase 6: Vault Database Secrets Engine


Phase 6 makes the policy paths from Phase 5 real by enabling Vault's database
secrets engine and configuring PostgreSQL dynamic credentials.

Goal:

```text
Vault issues short-lived PostgreSQL users for runtime and migration identities,
and PostgreSQL still enforces the role grants from Phase 2.
```

This phase creates:

```text
PostgreSQL management role: vault_admin
Vault secrets engine: database/
Vault connection config: database/config/demo-postgres
Vault dynamic role: database/roles/demo-app-runtime
Vault dynamic role: database/roles/demo-app-migrate
Credential path: database/creds/demo-app-runtime
Credential path: database/creds/demo-app-migrate
```

The `vault_admin` password is generated into `.runtime/vault-postgres.env` at
apply time. It is used only by Vault to create and revoke generated database
users. It is not an app runtime password and is not committed to Git.

Acceptance criteria:

- Vault database secrets engine is enabled
- Vault can connect to PostgreSQL
- Vault can issue runtime PostgreSQL credentials
- runtime credentials have a lease
- runtime generated user inherits `app_runtime`
- runtime generated user can `SELECT`, `INSERT`, `UPDATE`, and `DELETE`
- runtime generated user cannot `DROP TABLE`
- runtime generated user cannot `CREATE ROLE`
- runtime identity cannot read migration credentials
- Vault can issue migration PostgreSQL credentials
- migration credentials have a lease
- migration generated user inherits `migration_runtime`
- migration generated user can perform controlled schema changes
- migration identity cannot read runtime credentials
- revoking the runtime lease makes old runtime credentials fail
- revoking the migration lease makes old migration credentials fail

Run Phase 6:

```sh
make vault-db
```

Verify only Vault database dynamic credentials:

```sh
make verify-vault-db
```

