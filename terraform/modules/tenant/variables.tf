variable "tenant_id" {
  type = string
  validation {
    condition     = length(var.tenant_id) > 0
    error_message = "tenant_id is required."
  }
}

variable "display_name" { type = string }
variable "owner" { type = string }
variable "cost_center" { type = string }
variable "environment" { type = string }
variable "retention_class" { type = string }
variable "cpu_quota" { type = string }
variable "memory_quota" { type = string }
variable "storage_quota" { type = string }
variable "allowed_egress_cidrs" { type = list(string) }
