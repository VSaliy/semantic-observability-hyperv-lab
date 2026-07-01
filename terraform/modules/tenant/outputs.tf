output "namespace" {
  value = kubernetes_namespace_v1.tenant.metadata[0].name
}

output "resource_names" {
  value = {
    quota          = kubernetes_resource_quota_v1.tenant.metadata[0].name
    limit_range    = kubernetes_limit_range_v1.tenant.metadata[0].name
    network_policy = kubernetes_network_policy_v1.default_deny.metadata[0].name
    service_account = kubernetes_service_account_v1.tenant.metadata[0].name
    config_map     = kubernetes_config_map_v1.tenant_metadata.metadata[0].name
  }
}
