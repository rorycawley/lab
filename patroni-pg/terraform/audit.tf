resource "vault_audit" "stdout" {
  type = "file"
  path = "file"

  options = {
    file_path = "stdout"
  }
}

resource "vault_audit" "file_disk" {
  type = "file"
  path = "file_disk"

  options = {
    file_path = var.audit_log_path
  }
}
