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

resource "digitalocean_database_connection_pool" "moodle" {
  count = var.enable_db_connection_pool ? 1 : 0

  cluster_id = digitalocean_database_cluster.moodle_db.id
  name       = "moodle-pool-${terraform.workspace}"
  mode       = var.db_connection_pool_mode
  size       = var.db_connection_pool_size
  db_name    = digitalocean_database_db.moodle.name
  user       = digitalocean_database_user.moodle.name
}

data "digitalocean_database_user" "moodle" {
  cluster_id = digitalocean_database_cluster.moodle_db.id
  name       = digitalocean_database_user.moodle.name
}

output "db_cluster_id" {
  description = "DB cluster UUID (for API e.g. doadmin password)"
  value       = digitalocean_database_cluster.moodle_db.id
}

output "db_host" {
  description = "Private hostname of Moodle DB"
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
  description = "Auto-generated DB user password"
  value       = data.digitalocean_database_user.moodle.password
  sensitive   = true
}

output "db_pool_enabled" {
  description = "Whether DigitalOcean managed PgBouncer connection pool is enabled"
  value       = var.enable_db_connection_pool
}

output "db_pool_host" {
  description = "Private host of DB connection pool"
  value       = try(digitalocean_database_connection_pool.moodle[0].private_host, "")
}

output "db_pool_name" {
  description = "Database name to use when connecting via managed connection pool"
  value       = try(digitalocean_database_connection_pool.moodle[0].name, "")
}

output "db_pool_port" {
  description = "Port of DB connection pool"
  value       = try(digitalocean_database_connection_pool.moodle[0].port, 0)
}

output "db_pool_password" {
  description = "Password for DB connection pool"
  value       = try(digitalocean_database_connection_pool.moodle[0].password, "")
  sensitive   = true
}
