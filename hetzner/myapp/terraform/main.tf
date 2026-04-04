# ── kube-hetzner: Dev cluster with LGTM observability ─────────────
# Estimated cost: ~€30–35/month
#
# Prerequisites:
#   1. Create a Hetzner Cloud project at https://console.hetzner.cloud
#   2. Generate an API token (Read & Write) under Security → API Tokens
#   3. export TF_VAR_hcloud_token="your-token-here"
#   4. Generate an SSH key:  ssh-keygen -t ed25519 -f ~/.ssh/hetzner
#   5. terraform init && terraform apply

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.49"
    }
  }
}

variable "hcloud_token" {
  type      = string
  sensitive = true
}

provider "hcloud" {
  token = var.hcloud_token
}

module "kube-hetzner" {
  source  = "kube-hetzner/kube-hetzner/hcloud"
  # Pin to a specific version — check GitHub for latest
  # https://github.com/kube-hetzner/terraform-hcloud-kube-hetzner/releases

  providers = {
    hcloud = hcloud
  }

  hcloud_token = var.hcloud_token

  # ── SSH ──────────────────────────────────────────────────────────
  ssh_public_key  = file("~/.ssh/hetzner.pub")
  ssh_private_key = file("~/.ssh/hetzner")

  # ── Network ────────────────────────────────────────────────────
  network_region = "eu-central"   # Nuremberg, Germany

  # ── Control plane: 1 node ──────────────────────────────────────
  control_plane_nodepools = [
    {
      name        = "control-plane"
      server_type = "cx23"          # 2 vCPU, 4GB RAM — ~€4/mo
      location    = "nbg1"
      labels      = []
      taints      = []
      count       = 1
    }
  ]

  # ── Workers: 3 nodes ───────────────────────────────────────────
  # CX33 (4 vCPU, 8GB) needed for LGTM stack + your app
  agent_nodepools = [
    {
      name        = "worker"
      server_type = "cx33"          # 4 vCPU, 8GB RAM — ~€8/mo each
      location    = "nbg1"
      labels      = []
      taints      = []
      count       = 3
    }
  ]

  # ── Load balancer ──────────────────────────────────────────────
  # Traefik is installed by default and gets a Hetzner LB (~€6/mo)
  load_balancer_type     = "lb11"
  load_balancer_location = "nbg1"

  # ── Extras ─────────────────────────────────────────────────────
  # cert-manager for Let's Encrypt TLS
  enable_cert_manager = true
}

# ── Output the kubeconfig ──────────────────────────────────────────
# After `terraform apply`, run:
#   terraform output --raw kubeconfig > myapp_kubeconfig.yaml
#   export KUBECONFIG=$(pwd)/myapp_kubeconfig.yaml
#   kubectl get nodes

output "kubeconfig" {
  value     = module.kube-hetzner.kubeconfig
  sensitive = true
}
