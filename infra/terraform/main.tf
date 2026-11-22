# Demo infrastructure for apiops-governed-pipelines.
#
# Per environment: a resource group, an API Management instance, and a user-assigned managed
# identity that the environment's Azure DevOps service connection signs in as. The identity
# can manage only its own API Management instance.
#
# This creates the instances only. Their content (APIs, products, policies) is managed by the
# APIOps pipelines, so keep Terraform and APIOps away from each other's resources.

locals {
  sku_name = var.sku_name == "Consumption" ? "Consumption_0" : "${var.sku_name}_${var.sku_count}"

  # Key Vault names are limited to 24 characters, so environments get a short form.
  short_environment      = { development = "dev", testing = "test", uat = "uat", production = "prod" }
  key_vault_environments = { for env, rg in azurerm_resource_group.rg : env => rg if var.demo_key_vault }
}

data "azurerm_client_config" "current" {}

# API Management names are globally unique.
resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

resource "azurerm_resource_group" "rg" {
  for_each = toset(var.environments)

  name     = "rg-${var.name_prefix}-${each.key}-${var.location}"
  location = var.location
  tags     = merge(var.tags, { environment = each.key })
}

resource "azurerm_api_management" "apim" {
  for_each = azurerm_resource_group.rg

  name                = "apim-${var.name_prefix}-${each.key}-${random_string.suffix.result}"
  location            = each.value.location
  resource_group_name = each.value.name
  publisher_name      = var.publisher_name
  publisher_email     = var.publisher_email
  sku_name            = local.sku_name
  tags                = each.value.tags

  # The instance's own identity reads Key Vault-backed named values at run time.
  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_user_assigned_identity" "apiops" {
  for_each = azurerm_resource_group.rg

  name                = "id-${var.name_prefix}-${each.key}"
  location            = each.value.location
  resource_group_name = each.value.name
  tags                = each.value.tags
}

# Least privilege: each identity manages only its own environment's instance.
resource "azurerm_role_assignment" "apim_contributor" {
  for_each = azurerm_api_management.apim

  scope                = each.value.id
  role_definition_name = "API Management Service Contributor"
  principal_id         = azurerm_user_assigned_identity.apiops[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# `apiops publish` reads the resource group in its pre-flight check, so each identity also
# needs Reader on its own environment's resource group. Read-only, and not the subscription.
resource "azurerm_role_assignment" "rg_reader" {
  for_each = azurerm_resource_group.rg

  scope                = each.value.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.apiops[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

# Trust between an Azure DevOps service connection and its identity (workload identity
# federation, so there is no client secret). Azure DevOps shows the issuer and subject when you
# create the service connection; add them to var.federated_credentials and apply again.
resource "azurerm_federated_identity_credential" "azure_devops" {
  for_each = var.federated_credentials

  name                      = "azure-devops-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.apiops[each.key].id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = each.value.issuer
  subject                   = each.value.subject
}

# ---------------------------------------------------------------------------------------------
# Optional demo (var.demo_key_vault): a Key Vault per environment with one secret, so a
# Key Vault-backed named value can be promoted from Development to Production. Each
# environment's APIM instance reads only its own vault; the pipeline never sees the secret.
# ---------------------------------------------------------------------------------------------

resource "azurerm_key_vault" "demo" {
  for_each = local.key_vault_environments

  name                       = "kv-${var.name_prefix}-${lookup(local.short_environment, each.key, substr(each.key, 0, 4))}-${random_string.suffix.result}"
  location                   = each.value.location
  resource_group_name        = each.value.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = each.value.tags
}

# APIM's system-assigned identity may read secrets from its own environment's vault only.
resource "azurerm_role_assignment" "kv_apim_secrets_user" {
  for_each = azurerm_key_vault.demo

  scope                = each.value.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_api_management.apim[each.key].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Whoever runs Terraform needs to write the demo secret.
resource "azurerm_role_assignment" "kv_deployer_secrets_officer" {
  for_each = azurerm_key_vault.demo

  scope                = each.value.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Role assignments take a short while to apply to Key Vault's data plane.
resource "time_sleep" "kv_rbac_propagation" {
  count = var.demo_key_vault ? 1 : 0

  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.kv_deployer_secrets_officer]
}

resource "random_password" "petstore_api_key" {
  for_each = azurerm_key_vault.demo

  length  = 32
  special = false
}

resource "azurerm_key_vault_secret" "petstore_api_key" {
  for_each = azurerm_key_vault.demo

  name         = "petstore-api-key"
  value        = random_password.petstore_api_key[each.key].result
  key_vault_id = each.value.id
  content_type = "Demo value for the petstore-api-key named value"

  depends_on = [time_sleep.kv_rbac_propagation]
}
