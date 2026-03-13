data "digitalocean_kubernetes_versions" "main" {}

resource "digitalocean_kubernetes_cluster" "moodle_cluster" {
  name    = "moodle-cluster-${terraform.workspace}-${random_integer.name_suffix.result}"
  region  = var.region
  version = data.digitalocean_kubernetes_versions.main.latest_version

  node_pool {
    name       = "moodle-node-pool-${terraform.workspace}-${random_integer.name_suffix.result}"
    size       = var.node_pool_size
    node_count = var.node_pool_count
    auto_scale = var.enable_node_autoscale
    min_nodes  = var.node_pool_min_nodes
    max_nodes  = var.node_pool_max_nodes

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
