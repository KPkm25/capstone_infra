# Terraform configuration for:
# - Azure SQL Database in private subnet
# - Key Vault for credentials
# - Traffic Manager
# - Ingress Controller via Helm

terraform {
    required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.95"
    }
  }
  backend "azurerm" {
    resource_group_name   = "parakram-capstone"
    storage_account_name  = "kpkmterraform1750231403"
    container_name        = "tfstate"
    key                   = "terraform.tfstate"
  }
}

provider "azurerm" {
  features {}
}

provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks_cluster.kube_config[0].host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks_cluster.kube_config[0].client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks_cluster.kube_config[0].client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks_cluster.kube_config[0].cluster_ca_certificate)
}

provider "helm" {
  # uses default kubernetes provider implicitly
}

data "azurerm_resource_group" "main" {
  name = "parakram-capstone"
}

variable "ingress_lb_ip" {
  type    = string
  default = ""
}

data "azurerm_client_config" "current" {}

# Key Vault & Secret Setup
resource "azurerm_key_vault" "main" {
  name                        = "kpkm-keyvault-v3"
  location                    = data.azurerm_resource_group.main.location
  resource_group_name         = data.azurerm_resource_group.main.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"
  soft_delete_retention_days  = 7
  purge_protection_enabled    = false
  enabled_for_disk_encryption = true

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = ["Get", "List", "Set","Delete"]
  }
}

# VNet with 2 subnets
resource "azurerm_virtual_network" "main" {
  name                = "aks-vnet"
  address_space       = ["10.0.0.0/8"]
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_subnet" "aks1" {
  name                 = "aks-subnet-1"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.1.0.0/16"]
}

resource "azurerm_subnet" "sql" {
  name                 = "sql-subnet"
  resource_group_name  = data.azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.2.0.0/24"]
}

# SQL Password in Key Vault
resource "random_password" "sql_admin" {
  length  = 16
  special = true
}

resource "azurerm_key_vault_secret" "sql_admin_password" {
  name         = "sql-admin-password"
  value        = random_password.sql_admin.result
  key_vault_id = azurerm_key_vault.main.id
}

# Azure SQL with Private Endpoint
resource "azurerm_mssql_server" "main" {
  name                         = "kpkmsqlserver"
  resource_group_name          = data.azurerm_resource_group.main.name
  location                     = data.azurerm_resource_group.main.location
  version                      = "12.0"
  administrator_login          = "sqladminuser"
  administrator_login_password = azurerm_key_vault_secret.sql_admin_password.value
  minimum_tls_version          = "1.2"
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_mssql_database" "main" {
  name      = "springbootdb"
  server_id = azurerm_mssql_server.main.id
  sku_name  = "Basic"
}

resource "azurerm_private_endpoint" "sql_pe" {
  name                = "sql-private-endpoint"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.sql.id

  private_service_connection {
    name                           = "sql-pe-connection"
    private_connection_resource_id = azurerm_mssql_server.main.id
    subresource_names              = ["sqlServer"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "sql" {
  name                = "privatelink.database.windows.net"
  resource_group_name = data.azurerm_resource_group.main.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sql_link" {
  name                  = "sql-dns-link"
  resource_group_name   = data.azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.sql.name
  virtual_network_id    = azurerm_virtual_network.main.id
}

resource "azurerm_private_dns_a_record" "sql_record" {
  name                = azurerm_mssql_server.main.name
  zone_name           = azurerm_private_dns_zone.sql.name
  resource_group_name = data.azurerm_resource_group.main.name
  ttl                 = 300
  records             = [azurerm_private_endpoint.sql_pe.private_service_connection[0].private_ip_address]
}

# AKS
resource "azurerm_kubernetes_cluster" "aks_cluster" {
  name                = "kpkm-aks-cluster"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  dns_prefix          = "myaks"

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = "Standard_D2s_v3"
    vnet_subnet_id = azurerm_subnet.aks1.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
  }

  tags = {
    environment = "dev"
  }
}

# ACR
resource "azurerm_container_registry" "acr" {
  name                = "kpkmacrcap"
  resource_group_name = data.azurerm_resource_group.main.name
  location            = data.azurerm_resource_group.main.location
  sku                 = "Basic"
  admin_enabled       = false
}

resource "azurerm_role_assignment" "aks_acr_pull" {
  principal_id         = azurerm_kubernetes_cluster.aks_cluster.identity[0].principal_id
  role_definition_name = "AcrPull"
  scope                = azurerm_container_registry.acr.id
}


# Traffic Manager profile only (no endpoint yet)
resource "azurerm_traffic_manager_profile" "tm" {
  name                    = "kpkm-tm"
  resource_group_name     = data.azurerm_resource_group.main.name
  traffic_routing_method  = "Priority"

  dns_config {
    relative_name = "kpkmtraffic"
    ttl           = 30
  }

  monitor_config {
    protocol = "HTTP"
    port     = 80
    path     = "/"
  }

  // dynamic "endpoint" {
  //   for_each = var.ingress_lb_ip != "" ? [var.ingress_lb_ip] : []
  //   content {
  //     name             = "aks-endpoint"
  //     type             = "ExternalEndpoints"
  //     target           = endpoint.value
  //     endpoint_status  = "Enabled"
  //     priority         = 1
  //   }
  // }
}

resource "azurerm_public_ip" "nginx_ingress_ip" {
  name                = "nginx-ingress-public-ip"
  location            = data.azurerm_resource_group.main.location
  resource_group_name = data.azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
}


resource "azurerm_traffic_manager_external_endpoint" "aks_endpoint" {
  name                = "aks-endpoint"
  profile_id          = azurerm_traffic_manager_profile.tm.id
  target              = azurerm_public_ip.nginx_ingress_ip.ip_address
  endpoint_location   = data.azurerm_resource_group.main.location
  priority            = 1
}

output "nginx_ingress_ip" {
  value = azurerm_public_ip.nginx_ingress_ip.ip_address
}



// resource "azurerm_traffic_manager_profile" "tm" {
//   name                    = "kpkm-tm"
//   resource_group_name     = data.azurerm_resource_group.main.name
//   traffic_routing_method  = "Priority"

//   dns_config {
//     relative_name = "kpkmtraffic"
//     ttl           = 30
//   }

//   monitor_config {
//     protocol = "HTTP"
//     port     = 80
//     path     = "/"
//   }
// }

# To be added later after LB IP is available:
// resource "azurerm_traffic_manager_endpoint" "aks_endpoint" {
//   count               = var.ingress_lb_ip != "" ? 1 : 0
//   name                = "aks-endpoint"
//   profile_name        = azurerm_traffic_manager_profile.tm.name
//   resource_group_name = data.azurerm_resource_group.main.name
//   type                = "ExternalEndpoints"
//   target              = var.ingress_lb_ip
//   endpoint_status     = "Enabled"
//   priority            = 1
// }

