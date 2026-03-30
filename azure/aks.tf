resource "azurerm_kubernetes_cluster" "moodle" {
  name                = "moodle-aks-${terraform.workspace}-${random_integer.name_suffix.result}"
  location            = azurerm_resource_group.moodle.location
  resource_group_name = azurerm_resource_group.moodle.name
  dns_prefix          = "moodle-${terraform.workspace}-${random_integer.name_suffix.result}"

  default_node_pool {
    name           = "default"
    node_count     = var.node_count
    vm_size        = var.node_vm_size
    vnet_subnet_id = azurerm_subnet.aks.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.1.0.0/16"
    dns_service_ip = "10.1.0.10"
  }
}

output "kubeconfig" {
  description = "Kubeconfig for the AKS cluster"
  value       = azurerm_kubernetes_cluster.moodle.kube_config_raw
  sensitive   = true
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.moodle.name
}

output "resource_group_name" {
  value = azurerm_resource_group.moodle.name
}
