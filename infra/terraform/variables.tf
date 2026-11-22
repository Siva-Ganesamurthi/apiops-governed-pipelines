variable "subscription_id" {
  type        = string
  description = "Azure subscription to create the resources in."
}

variable "location" {
  type        = string
  default     = "westus"
  description = "Azure region, as the lowercase name that matches the pipelines' Region dropdown (WestUS is westus)."

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.location))
    error_message = "Use the lowercase Azure region name without spaces, for example westus, eastus or westeurope."
  }
}

variable "environments" {
  type        = list(string)
  default     = ["development", "production"]
  description = "One API Management instance is created per environment. Use the lowercase names of the pipelines' Environment dropdown: development, testing, uat, production."

  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : can(regex("^[a-z][a-z0-9]{1,15}$", e))])
    error_message = "List at least one environment. Each name must be lowercase letters and digits (2-16 characters), for example development."
  }
}

variable "name_prefix" {
  type        = string
  default     = "apiops"
  description = "Prefix for every resource name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.name_prefix))
    error_message = "Use 2-12 lowercase letters and digits, starting with a letter."
  }
}

variable "publisher_name" {
  type        = string
  default     = "APIOps demo"
  description = "Organization name shown in the developer portal and in email notifications."
}

variable "publisher_email" {
  type        = string
  description = "Email address that receives API Management system notifications."
}

variable "sku_name" {
  type        = string
  default     = "Developer"
  description = "API Management tier. Developer is the cheapest classic tier with all features, but has no SLA and takes 30-45 minutes to create. BasicV2 creates in minutes. Consumption has no fixed cost but lacks some features."

  validation {
    condition     = contains(["Consumption", "Developer", "Basic", "BasicV2", "Standard", "StandardV2", "Premium", "PremiumV2"], var.sku_name)
    error_message = "Use one of: Consumption, Developer, Basic, BasicV2, Standard, StandardV2, Premium, PremiumV2."
  }
}

variable "sku_count" {
  type        = number
  default     = 1
  description = "Number of units. Ignored for Consumption."
}

variable "federated_credentials" {
  type = map(object({
    issuer  = string
    subject = string
  }))
  default     = {}
  description = "Optional, filled in after the service connections exist. Keyed by environment: the Issuer and Subject identifier that Azure DevOps shows for that environment's service connection."
}

variable "tags" {
  type = map(string)
  default = {
    project = "apiops-governed-pipelines"
    purpose = "demo"
  }
  description = "Tags added to every resource. An environment tag is added per environment."
}

variable "demo_key_vault" {
  type        = bool
  default     = true
  description = "Create a Key Vault per environment with a demo secret, and give each APIM instance a system-assigned identity that can read its own vault. Shows Key Vault-backed named values being promoted."
}
