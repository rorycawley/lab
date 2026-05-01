variable "demo_namespace" {
  description = "Namespace where the Python app and the demo ServiceAccounts live."
  type        = string
  default     = "demo"
}

variable "demo_app_service_account" {
  description = "Runtime ServiceAccount that the Python app uses to log in to Vault."
  type        = string
  default     = "demo-app"
}

variable "demo_migrate_service_account" {
  description = "Migration ServiceAccount that authenticates to the migrate role."
  type        = string
  default     = "demo-migrate"
}

variable "kubernetes_host" {
  description = "Kubernetes API server URL that Vault uses for TokenReview. Resolved from inside Vault's Pod network."
  type        = string
  default     = "https://kubernetes.default.svc:443"
}

variable "postgres_host" {
  description = "PostgreSQL host that Vault connects to from inside the Vault Pod."
  type        = string
  default     = "host.rancher-desktop.internal"
}

variable "postgres_port" {
  description = "PostgreSQL TCP port."
  type        = number
  default     = 5432
}

variable "postgres_database" {
  description = "PostgreSQL database that the demo workload uses."
  type        = string
  default     = "demo_registry"
}

variable "postgres_ca_cert_file" {
  description = "Path inside the Vault Pod where the PostgreSQL CA certificate is mounted."
  type        = string
  default     = "/vault/postgres-ca/ca.crt"
}

variable "vault_admin_user" {
  description = "PostgreSQL role that Vault uses to create and revoke dynamic users."
  type        = string
  default     = "vault_admin"
}

variable "runtime_default_ttl" {
  description = "Default TTL for runtime credentials issued by Vault."
  type        = string
  default     = "15m"
}

variable "runtime_max_ttl" {
  description = "Maximum TTL for runtime credentials."
  type        = string
  default     = "1h"
}

variable "migrate_default_ttl" {
  description = "Default TTL for migration credentials."
  type        = string
  default     = "10m"
}

variable "migrate_max_ttl" {
  description = "Maximum TTL for migration credentials."
  type        = string
  default     = "30m"
}

variable "vault_admin_password_file" {
  description = "Local file path where the generated vault_admin password is written for the Postgres-side role apply step."
  type        = string
  default     = "../.runtime/vault-postgres.env"
}

variable "audit_log_path" {
  description = "On-disk audit log path inside the Vault Pod (mounted from the vault-audit emptyDir)."
  type        = string
  default     = "/vault/audit/audit.log"
}
