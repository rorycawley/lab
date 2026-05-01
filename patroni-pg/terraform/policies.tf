resource "vault_policy" "demo_app_runtime" {
  name = "demo-app-runtime"

  policy = <<-HCL
    path "database/creds/demo-app-runtime" {
      capabilities = ["read"]
    }
  HCL
}

resource "vault_policy" "demo_app_migrate" {
  name = "demo-app-migrate"

  policy = <<-HCL
    path "database/creds/demo-app-migrate" {
      capabilities = ["read"]
    }
  HCL
}
