resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

resource "vault_kubernetes_auth_backend_config" "this" {
  backend                = vault_auth_backend.kubernetes.path
  kubernetes_host        = var.kubernetes_host
  disable_iss_validation = true
}

resource "vault_kubernetes_auth_backend_role" "demo_app" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "demo-app"
  bound_service_account_names      = [var.demo_app_service_account]
  bound_service_account_namespaces = [var.demo_namespace]
  token_ttl                        = 900
  token_policies                   = [vault_policy.demo_app_runtime.name]
}

resource "vault_kubernetes_auth_backend_role" "demo_migrate" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "demo-migrate"
  bound_service_account_names      = [var.demo_migrate_service_account]
  bound_service_account_namespaces = [var.demo_namespace]
  token_ttl                        = 600
  token_policies                   = [vault_policy.demo_app_migrate.name]
}
