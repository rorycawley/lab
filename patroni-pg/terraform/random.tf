resource "random_password" "vault_admin" {
  length           = 48
  special          = true
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  override_special = "_-."
}

resource "local_sensitive_file" "vault_admin_env" {
  filename        = var.vault_admin_password_file
  file_permission = "0600"
  content         = "VAULT_POSTGRES_PASSWORD=${random_password.vault_admin.result}\n"
}
