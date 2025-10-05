provider "kubernetes" {
  config_path    = var.kube_config_path
  config_context = var.kube_context
}

provider "helm" {
  kubernetes {
    config_path    = var.kube_config_path
    config_context = var.kube_context
  }
}

provider "kubectl" {
  config_path    = var.kube_config_path
  config_context = var.kube_context
}

resource "kubernetes_namespace" "staging" {
  metadata {
    name = "staging"
    labels = {
      environment = "staging"
    }
  }
}

resource "kubernetes_namespace" "prod" {
  metadata {
    name = "prod"
    labels = {
      environment = "prod"
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      managed-by = "terraform"
    }
  }
}

resource "kubernetes_namespace" "helm_repo" {
  metadata {
    name = "helm-repo"
    labels = {
      app = "helm-repo"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "5.46.6"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  timeout = 600

  values = [file("${path.module}/values/argocd-values.yaml")]
}

resource "kubectl_manifest" "argocd_project_default" {
  yaml_body = <<-YAML
    apiVersion: argoproj.io/v1alpha1
    kind: AppProject
    metadata:
      name: root-apps
      namespace: argocd
    spec:
      description: Project for sample applications managed in this exercise.
      sourceRepos:
        - "*"
      destinations:
        - namespace: "*"
          server: https://kubernetes.default.svc
      clusterResourceWhitelist:
        - group: "*"
          kind: "*"
  YAML

  depends_on = [helm_release.argocd]
}
