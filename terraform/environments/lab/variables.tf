variable "kubeconfig_path" {
  type        = string
  description = "Path to the kubeconfig used to apply tenant resources to the lab cluster."
  default     = "~/.kube/config"
}

