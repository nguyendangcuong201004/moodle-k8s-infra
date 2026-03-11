data "digitalocean_kubernetes_versions" "main" {}

resource "digitalocean_kubernetes_cluster" "moodle_cluster" {
  name    = "moodle-cluster"
  region  = var.region
  version = data.digitalocean_kubernetes_versions.main.latest_version

  node_pool {
    name       = "moodle-node-pool"
    size       = "s-2vcpu-4gb"
    node_count = 2

    labels = {
      role = "moodle-app"
    }
  }
}

output "kubeconfig" {
  description = "Kubeconfig của cluster Moodle trên DigitalOcean"
  value       = digitalocean_kubernetes_cluster.moodle_cluster.kube_config[0].raw_config
  sensitive   = true
}
