terraform {
  required_version = ">= 1.9.0"
}

module "trading_tenant" {
  source               = "../../modules/tenant"
  tenant_id            = "trading"
  display_name         = "Trading"
  owner                = "platform-team"
  cost_center          = "OBS-001"
  environment          = "production"
  retention_class      = "standard"
  cpu_quota            = "4"
  memory_quota         = "8Gi"
  storage_quota        = "50Gi"
  allowed_egress_cidrs = ["10.50.0.0/24"]
}
