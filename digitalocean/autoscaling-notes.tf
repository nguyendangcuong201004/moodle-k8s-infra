variable "enable_node_autoscale" {
  description = "Bật autoscaling cho node pool Moodle (nếu DigitalOcean hỗ trợ cấu hình này qua Terraform trong phiên bản provider hiện tại)"
  type        = bool
  default     = true
}

variable "node_pool_min_nodes" {
  description = "Số node tối thiểu cho autoscaling node pool (chỉ dùng khi enable_node_autoscale = true)"
  type        = number
  default     = 2
}

variable "node_pool_max_nodes" {
  description = "Số node tối đa cho autoscaling node pool (chỉ dùng khi enable_node_autoscale = true)"
  type        = number
  default     = 3
}

# Ghi chú:
# - Provider DigitalOcean hiện tại đang dùng version ~> 2.0 trong provider.tf.
# - Ở version này, Terraform resource digitalocean_kubernetes_cluster có thể hoặc không hỗ trợ trực tiếp block autoscaling cho node_pool.
# - Vì vậy, các biến trên chỉ là chỗ chuẩn bị sẵn. Khi muốn bật autoscaling:
#   - Kiểm tra lại tài liệu Terraform DigitalOcean mới nhất.
#   - Cập nhật resource digitalocean_kubernetes_cluster.moodle_cluster để dùng các biến này theo cú pháp được provider hỗ trợ.

