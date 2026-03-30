resource "random_password" "db_password" {
  length  = 24
  special = false
}

resource "azurerm_postgresql_flexible_server" "moodle" {
  name                   = "moodle-pg-${terraform.workspace}-${random_integer.name_suffix.result}"
  resource_group_name    = azurerm_resource_group.moodle.name
  location               = azurerm_resource_group.moodle.location
  version                = "16"
  delegated_subnet_id    = azurerm_subnet.db.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id
  administrator_login    = "moodleuser"
  administrator_password = random_password.db_password.result
  sku_name                      = var.db_sku_name
  storage_mb                    = var.db_storage_mb
  public_network_access_enabled = false

  depends_on = [azurerm_private_dns_zone_virtual_network_link.postgres]
}

resource "azurerm_postgresql_flexible_server_database" "moodle" {
  name      = "moodle"
  server_id = azurerm_postgresql_flexible_server.moodle.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_configuration" "ssl_off" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.moodle.id
  value     = "off"
}

output "db_host" {
  description = "PostgreSQL Flexible Server FQDN"
  value       = azurerm_postgresql_flexible_server.moodle.fqdn
}

output "db_port" {
  value = "5432"
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.moodle.name
}

output "db_user" {
  value = azurerm_postgresql_flexible_server.moodle.administrator_login
}

output "db_password" {
  description = "Auto-generated DB password"
  value       = random_password.db_password.result
  sensitive   = true
}
