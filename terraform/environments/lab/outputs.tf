output "tenant_namespaces" {
  description = "Namespaces created for each managed tenant."
  value = {
    trading     = module.trading_tenant.namespace
    market_data = module.market_data_tenant.namespace
  }
}

