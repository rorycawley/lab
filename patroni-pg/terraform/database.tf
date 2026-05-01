resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

# Apply the PostgreSQL `vault_admin` role with the Terraform-generated password
# before Vault's database engine tries to verify the connection. This breaks
# the chicken-and-egg between password generation and connection verification:
# Vault verifies by actually opening a Postgres session, which requires the role
# to already have the matching password.
resource "null_resource" "vault_admin_pg_role" {
  triggers = {
    password = random_password.vault_admin.result
  }

  provisioner "local-exec" {
    command     = "./scripts/41-apply-vault-admin-pg-role.sh"
    working_dir = "${path.module}/.."

    environment = {
      VAULT_POSTGRES_PASSWORD = random_password.vault_admin.result
    }
  }

  depends_on = [local_sensitive_file.vault_admin_env]
}

resource "vault_database_secret_backend_connection" "demo_postgres" {
  backend       = vault_mount.database.path
  name          = "demo-postgres"
  allowed_roles = ["demo-app-runtime", "demo-app-migrate"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${var.postgres_host}:${var.postgres_port}/${var.postgres_database}?sslmode=verify-full&sslrootcert=${var.postgres_ca_cert_file}"
    username       = var.vault_admin_user
    password       = random_password.vault_admin.result
  }

  depends_on = [null_resource.vault_admin_pg_role]
}

resource "vault_database_secret_backend_role" "runtime" {
  backend     = vault_mount.database.path
  name        = "demo-app-runtime"
  db_name     = vault_database_secret_backend_connection.demo_postgres.name
  default_ttl = 900
  max_ttl     = 3600

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT app_runtime TO \"{{name}}\";"
  ]

  revocation_statements = [
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'; REVOKE app_runtime FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}

resource "vault_database_secret_backend_role" "migrate" {
  backend     = vault_mount.database.path
  name        = "demo-app-migrate"
  db_name     = vault_database_secret_backend_connection.demo_postgres.name
  default_ttl = 600
  max_ttl     = 1800

  creation_statements = [
    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT migration_runtime TO \"{{name}}\";"
  ]

  revocation_statements = [
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'; REVOKE migration_runtime FROM \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";"
  ]
}
