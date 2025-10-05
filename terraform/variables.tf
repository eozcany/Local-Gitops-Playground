variable "kube_context" {
  description = "Name of the kubeconfig context to target. Defaults to minikube."
  type        = string
  default     = "minikube"
}

variable "kube_config_path" {
  description = "Path to the kubeconfig file to use."
  type        = string
  default     = "~/.kube/config"
}
