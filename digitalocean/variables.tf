variable "node_pool_size" {
  description = "Droplet size for node pool (e.g. s-2vcpu-4gb)"
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "node_pool_count" {
  description = "Number of nodes in node pool"
  type        = number
  default     = 3
}

variable "db_size" {
  description = "Managed PostgreSQL plan size (db-s-2vcpu-4gb ≈ $48/mo: 97 conn limit, min 60 GiB storage)"
  type        = string
  default     = "db-s-2vcpu-4gb"
}

variable "db_storage_size_mib" {
  description = "Managed PostgreSQL storage size in MiB (60 GiB minimum for db-s-2vcpu-4gb)"
  type        = number
  default     = 61440
}

variable "db_node_count" {
  description = "Number of nodes in DO Managed Postgres (2 = primary + hot standby for read replica / streaming replication)"
  type        = number
  default     = 2
}

variable "enable_db_connection_pool" {
  description = "Enable DigitalOcean managed PgBouncer connection pooling"
  type        = bool
  default     = true
}

variable "db_connection_pool_mode" {
  description = "Connection pool mode (session|transaction|statement)"
  type        = string
  default     = "session"

  validation {
    condition     = contains(["session", "transaction", "statement"], var.db_connection_pool_mode)
    error_message = "db_connection_pool_mode must be one of: session, transaction, statement."
  }
}

variable "db_connection_pool_size" {
  description = "Max server connections in the managed connection pool (≤ ~85 recommended for 97 conn cluster limit)"
  type        = number
  default     = 85
}

