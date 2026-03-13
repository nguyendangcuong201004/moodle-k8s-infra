resource "digitalocean_database_cluster" "moodle_db" {
  name       = "moodle-db-postgres-${terraform.workspace}-${random_integer.name_suffix.result}"
  engine     = "pg"
  version    = "16"
  size       = var.db_size
  region     = var.region
  node_count = var.db_node_count
}

resource "digitalocean_database_db" "moodle" {
  cluster_id = digitalocean_database_cluster.moodle_db.id
  name       = "moodle"
}

resource "digitalocean_database_user" "moodle" {
  cluster_id = digitalocean_database_cluster.moodle_db.id
  name       = "moodleuser"
}

data "digitalocean_database_user" "moodle" {
  cluster_id = digitalocean_database_cluster.moodle_db.id
  name       = digitalocean_database_user.moodle.name
}

output "db_cluster_id" {
  description = "UUID của database cluster (dùng để gọi API lấy doadmin password)"
  value       = digitalocean_database_cluster.moodle_db.id
}

output "db_host" {
  description = "Hostname private của database Moodle"
  value       = digitalocean_database_cluster.moodle_db.private_host
}

output "db_port" {
  value = digitalocean_database_cluster.moodle_db.port
}

output "db_name" {
  value = digitalocean_database_db.moodle.name
}

output "db_user" {
  value = digitalocean_database_user.moodle.name
}

output "db_password" {
  description = "Password tự sinh của user database Moodle trên DigitalOcean"
  value       = data.digitalocean_database_user.moodle.password
  sensitive   = true
}
