output "variable_groups" {
  description = "One Azure DevOps variable group per environment (Pipelines > Library): group name and its variables."
  value = {
    for env, apim in azurerm_api_management.apim : "apiops-${var.location}-${env}" => {
      APIM_NAME             = apim.name
      APIM_RESOURCE_GROUP   = apim.resource_group_name
      AZURE_SUBSCRIPTION_ID = var.subscription_id
    }
  }
}

output "service_connections" {
  description = "One Azure DevOps service connection per environment: name and the identity details to enter."
  value = {
    for env, identity in azurerm_user_assigned_identity.apiops : "apiops-${env}" => {
      client_id       = identity.client_id
      tenant_id       = identity.tenant_id
      subscription_id = var.subscription_id
      resource_group  = identity.resource_group_name
    }
  }
}

output "key_vault_secret_uris" {
  description = "Versionless URI of each environment's demo secret. Add it to that environment's variable group as NV_PETSTORE_API_KEY_KV_URL."
  value       = { for env, secret in azurerm_key_vault_secret.petstore_api_key : env => secret.versionless_id }
}

output "gateway_urls" {
  description = "Gateway URL of each API Management instance."
  value       = { for env, apim in azurerm_api_management.apim : env => apim.gateway_url }
}
