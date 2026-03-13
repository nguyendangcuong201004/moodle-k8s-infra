variable "node_pool_size" {
  description = "Kích thước Droplet cho node pool Moodle (ví dụ: s-2vcpu-4gb)"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "node_pool_count" {
  description = "Số lượng node trong node pool Moodle"
  type        = number
  default     = 2
}

variable "db_size" {
  description = "Kích thước gói Managed PostgreSQL cho Moodle"
  type        = string
  default     = "db-s-2vcpu-4gb"
}

variable "db_node_count" {
  description = "Số node trong cluster Managed PostgreSQL"
  type        = number
  default     = 1
}

