terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  features {
    api_management {
      # Deleted API Management instances are kept (soft-deleted) for 48 hours by default.
      # Purging on destroy keeps a demo subscription clean.
      purge_soft_delete_on_destroy = true
    }
  }
}
