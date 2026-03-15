variable "node_pool_size" {
  description = "Droplet size for node pool (e.g. s-2vcpu-4gb)"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_pool_count" {
  description = "Number of nodes in node pool"
  type        = number
  default     = 2
}

variable "db_size" {
  description = "Managed PostgreSQL plan size"
  type        = string
  default     = "db-s-2vcpu-4gb"
}

variable "db_node_count" {
  description = "Number of nodes in DB cluster"
  type        = number
  default     = 1
}

