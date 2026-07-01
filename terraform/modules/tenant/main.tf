terraform {
  required_version = ">= 1.9.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.32.0"
    }
  }
}

locals {
  namespace = "tenant-${var.tenant_id}"
  labels = {
    "platform.example.com/tenant"              = var.tenant_id
    "platform.example.com/environment"         = var.environment
    "platform.example.com/data-classification" = "internal"
    "platform.example.com/owner"               = var.owner
  }
}

resource "kubernetes_namespace_v1" "tenant" {
  metadata {
    name   = local.namespace
    labels = local.labels
  }
}

resource "kubernetes_resource_quota_v1" "tenant" {
  metadata {
    name      = "${var.tenant_id}-quota"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"       = var.cpu_quota
      "requests.memory"    = var.memory_quota
      "requests.storage"   = var.storage_quota
      "limits.cpu"         = var.cpu_quota
      "limits.memory"      = var.memory_quota
    }
  }
}

resource "kubernetes_limit_range_v1" "tenant" {
  metadata {
    name      = "${var.tenant_id}-limits"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "500m"
        memory = "512Mi"
      }
      default_request = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_service_account_v1" "tenant" {
  metadata {
    name      = "${var.tenant_id}-workload"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
    labels    = local.labels
  }
}

resource "kubernetes_config_map_v1" "tenant_metadata" {
  metadata {
    name      = "${var.tenant_id}-metadata"
    namespace = kubernetes_namespace_v1.tenant.metadata[0].name
    labels    = local.labels
  }
  data = {
    display_name    = var.display_name
    owner           = var.owner
    cost_center     = var.cost_center
    retention_class = var.retention_class
    allowed_egress  = join(",", var.allowed_egress_cidrs)
  }
}
