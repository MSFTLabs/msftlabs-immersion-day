terraform {
  required_version = ">= 1.13.1, < 2.0.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.9.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "3.10.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.1"
    }
    msgraph = {
      source  = "microsoft/msgraph"
      version = "0.6.0"
    }
  }

  backend "local" {}
}