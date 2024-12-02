variable "resource_group" {
  type = string
}

variable "location" {
  type    = string
  default = "East US"
}

variable "cluster_name" {
  type    = string
  default = "East US"
}

variable "tags" {
  type = map(string)
}

variable "subscription_id" { type = string }
variable "tenant_id" { type = string }
variable "sp_principal_id" { type = string }
variable "container_registry_scope" { type = string }
