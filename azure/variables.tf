variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "southeastasia"
}

variable "node_count" {
  description = "Number of nodes in the AKS node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes (e.g. Standard_B2s = 2 vCPU, 4 GB)"
  type        = string
  default     = "Standard_B2s"
}

variable "db_sku_name" {
  description = "PostgreSQL Flexible Server SKU (e.g. B_Standard_B1ms)"
  type        = string
  default     = "B_Standard_B1ms"
}

variable "db_storage_mb" {
  description = "PostgreSQL storage size in MB"
  type        = number
  default     = 32768
}
