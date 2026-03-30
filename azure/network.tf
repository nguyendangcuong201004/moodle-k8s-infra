resource "azurerm_resource_group" "moodle" {
  name     = "moodle-rg-${terraform.workspace}-${random_integer.name_suffix.result}"
  location = var.location
}

resource "azurerm_virtual_network" "moodle" {
  name                = "moodle-vnet-${terraform.workspace}-${random_integer.name_suffix.result}"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.moodle.location
  resource_group_name = azurerm_resource_group.moodle.name
}

resource "azurerm_subnet" "aks" {
  name                 = "aks-subnet"
  resource_group_name  = azurerm_resource_group.moodle.name
  virtual_network_name = azurerm_virtual_network.moodle.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "db" {
  name                 = "db-subnet"
  resource_group_name  = azurerm_resource_group.moodle.name
  virtual_network_name = azurerm_virtual_network.moodle.name
  address_prefixes     = ["10.0.2.0/24"]

  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_private_dns_zone" "postgres" {
  name                = "moodle-${terraform.workspace}-${random_integer.name_suffix.result}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.moodle.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-vnet-link"
  resource_group_name   = azurerm_resource_group.moodle.name
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  virtual_network_id    = azurerm_virtual_network.moodle.id
}

resource "azurerm_network_security_group" "aks" {
  name                = "moodle-aks-nsg-${terraform.workspace}-${random_integer.name_suffix.result}"
  location            = azurerm_resource_group.moodle.location
  resource_group_name = azurerm_resource_group.moodle.name

  security_rule {
    name                       = "AllowHTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHTTPS"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "aks" {
  subnet_id                 = azurerm_subnet.aks.id
  network_security_group_id = azurerm_network_security_group.aks.id
}
