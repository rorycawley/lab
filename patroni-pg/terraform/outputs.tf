output "kubernetes_auth_path" {
  value       = vault_auth_backend.kubernetes.path
  description = "Vault Kubernetes auth method mount path."
}

output "auth_role_names" {
  value = [
    vault_kubernetes_auth_backend_role.demo_app.role_name,
    vault_kubernetes_auth_backend_role.demo_migrate.role_name,
  ]
  description = "Configured Vault Kubernetes auth role names."
}

output "policy_names" {
  value = [
    vault_policy.demo_app_runtime.name,
    vault_policy.demo_app_migrate.name,
  ]
  description = "Configured Vault policy names."
}

output "database_role_names" {
  value = [
    vault_database_secret_backend_role.runtime.name,
    vault_database_secret_backend_role.migrate.name,
  ]
  description = "Configured Vault database secret role names."
}

output "audit_device_paths" {
  value = [
    "${vault_audit.stdout.path}/",
    "${vault_audit.file_disk.path}/",
  ]
  description = "Configured Vault audit device paths."
}

output "vault_admin_password" {
  value       = random_password.vault_admin.result
  description = "Password Vault uses for the vault_admin PostgreSQL role."
  sensitive   = true
}
