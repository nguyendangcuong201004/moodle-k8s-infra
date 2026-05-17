variable "enable_node_autoscale" {
  description = "Enable node pool autoscaling"
  type        = bool
  default     = true
}

variable "node_pool_min_nodes" {
  description = "Min nodes when autoscale enabled"
  type        = number
  default     = 3
}

variable "node_pool_max_nodes" {
  description = "Max nodes when autoscale enabled"
  type        = number
  default     = 6
}
