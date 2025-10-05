#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-1.0.0}"
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
CHART_DIR="$REPO_ROOT/helm/nginx-app"
REPO_CHART_DIR="$REPO_ROOT/helm/helm-repo"
DIST_DIR="$REPO_ROOT/dist/charts"
CHART_PACKAGE=""
HELM_REPO_RELEASE="helm-repo"
HELM_REPO_NAMESPACE="helm-repo"
HOSTS_MARKER="# hello-local"
HOSTS_UPDATED=0
LOG_DIR="$REPO_ROOT/logs"

check_prereqs() {
  local missing=()
  for cmd in minikube kubectl helm terraform docker sudo; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "Please install them before running this script." >&2
    exit 1
  fi
}

start_minikube() {
  echo "=== Ensuring Minikube is running with ingress addon"
  if ! minikube status >/dev/null 2>&1; then
    minikube start --memory=4096 --cpus=2 --addons=ingress
  else
    minikube addons enable ingress >/dev/null 2>&1 || true
  fi
}

use_minikube_docker() {
  echo "=== Using Minikube Docker daemon"
  eval "$(minikube -p minikube docker-env)"
}

configure_hosts() {
  echo "=== Updating /etc/hosts with staging, prod, and ArgoCD endpoints"
  local target_ip shell_uname
  target_ip="127.0.0.1"
  shell_uname=$(uname)

  echo "This step needs sudo to edit /etc/hosts so your browser resolves the vanity hostnames to $target_ip (loopback)."

  if ! sudo -n true 2>/dev/null; then
    if [ -t 1 ]; then
      if ! sudo -v; then
        echo "Warning: Unable to update /etc/hosts (sudo denied). Please add this entry manually:" >&2
        echo "  $target_ip staging.hello.local prod.hello.local argocd.local" >&2
        return
      fi
    else
      echo "Warning: Unable to update /etc/hosts automatically (sudo password required)." >&2
      echo "         Add this entry manually: $target_ip staging.hello.local prod.hello.local argocd.local" >&2
      return
    fi
  fi

  if [ "$shell_uname" = "Darwin" ]; then
    sudo sed -i '' "/$HOSTS_MARKER/d" /etc/hosts
  else
    sudo sed -i "/$HOSTS_MARKER/d" /etc/hosts
  fi

  echo "$target_ip staging.hello.local prod.hello.local argocd.local $HOSTS_MARKER" | sudo tee -a /etc/hosts >/dev/null
  HOSTS_UPDATED=1
}

build_image() {
  echo "=== Building application image nginx-demo:${APP_VERSION}"
  docker build -t nginx-demo:"${APP_VERSION}" "$REPO_ROOT/app"
}

run_terraform() {
  echo "=== Applying Terraform to provision namespaces and ArgoCD"

  if [ -n "${KUBECONFIG:-}" ]; then
    export TF_VAR_kube_config_path="${KUBECONFIG%%:*}"
  else
    export TF_VAR_kube_config_path="$HOME/.kube/config"
  fi

  local current_context="minikube"
  if kubectl_current=$(kubectl config current-context 2>/dev/null); then
    if [ -n "$kubectl_current" ]; then
      current_context="$kubectl_current"
    fi
  fi
  export TF_VAR_kube_context="$current_context"

  terraform -chdir="$REPO_ROOT/terraform" init -input=false >/dev/null
  terraform -chdir="$REPO_ROOT/terraform" apply -auto-approve
}

package_chart() {
  echo "=== Packaging Helm chart and generating index"
  rm -rf "$REPO_ROOT/dist"
  mkdir -p "$DIST_DIR"
  helm package "$CHART_DIR" --destination "$DIST_DIR" >/dev/null
  helm repo index "$DIST_DIR" >/dev/null

  local chart_path
  chart_path="$(find "$DIST_DIR" -maxdepth 1 -type f -name 'nginx-app-*.tgz' | head -n 1)"
  if [ -z "$chart_path" ]; then
    echo "Unable to locate packaged chart in $DIST_DIR" >&2
    exit 1
  fi
  CHART_PACKAGE="$(basename "$chart_path")"
}

sync_repo_chart_assets() {
  if [ -z "$CHART_PACKAGE" ]; then
    echo "Chart package not detected. Did package_chart run?" >&2
    exit 1
  fi

  echo "=== Syncing packaged artifacts into helm repo chart assets"
  rm -f "$REPO_CHART_DIR"/files/index.yaml
  rm -f "$REPO_CHART_DIR"/files/nginx-app-*.tgz
  cp "$DIST_DIR/index.yaml" "$REPO_CHART_DIR/files/index.yaml"
  cp "$DIST_DIR/$CHART_PACKAGE" "$REPO_CHART_DIR/files/$CHART_PACKAGE"
}

deploy_local_helm_repo() {
  echo "=== Deploying in-cluster Helm repository"
  helm upgrade --install "$HELM_REPO_RELEASE" "$REPO_CHART_DIR" \
    --namespace "$HELM_REPO_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 180s \
    --set-string config.chartFile="$CHART_PACKAGE" \
    >/dev/null
}

apply_argocd_apps() {
  echo "=== Applying ArgoCD Applications"
  kubectl apply -f "$REPO_ROOT/argocd/applications/templates/nginx-staging.yaml.tpl"
  kubectl apply -f "$REPO_ROOT/argocd/applications/templates/nginx-production.yaml.tpl"
}

wait_for_argocd_sync() {
  local app="$1"
  local namespace="argocd"
  local retries=60
  local delay=5
  echo "=== Waiting for ArgoCD application '$app' to reach Synced/Healthy"
  while [ $retries -gt 0 ]; do
    if kubectl -n "$namespace" get application "$app" >/dev/null 2>&1; then
      local sync_status health_status
      sync_status=$(kubectl -n "$namespace" get application "$app" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
      health_status=$(kubectl -n "$namespace" get application "$app" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
      if [ "$sync_status" = "Synced" ] && [ "$health_status" = "Healthy" ]; then
        echo "    $app is Synced and Healthy."
        return 0
      fi
      echo "    status: sync=$sync_status health=$health_status ... waiting"
    else
      echo "    application $app not yet visible ... waiting"
    fi
    retries=$((retries-1))
    sleep "$delay"
  done
  echo "Timed out waiting for ArgoCD application $app to become Synced/Healthy" >&2
  kubectl -n "$namespace" get application "$app" -o yaml >&2 || true
  exit 1
}

wait_for_staging() {
  echo "=== Waiting for staging deployment to become ready"
  local retries=60
  local delay=5
  until kubectl -n staging get deployment/nginx-app >/dev/null 2>&1; do
    retries=$((retries-1))
    if [ $retries -le 0 ]; then
      echo "Timed out waiting for deployment/nginx-app to be created in staging." >&2
      kubectl -n argocd get application nginx-staging -o yaml >&2 || true
      exit 1
    fi
    echo "    deployment not created yet, waiting"
    sleep "$delay"
  done
  kubectl -n staging rollout status deployment/nginx-app --timeout=180s
}

application_access() {
  # Color / style (enabled only on a real TTY and if NO_COLOR not set)
  if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    BOLD="$(printf '\033[1m')"
    DIM="$(printf '\033[2m')"
    RED="$(printf '\033[31m')"
    GREEN="$(printf '\033[32m')"
    YELLOW="$(printf '\033[33m')"
    BLUE="$(printf '\033[34m')"
    RESET="$(printf '\033[0m')"
  else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
  fi

  # Header
  printf '%b\n' "${BOLD}${BLUE}=== Tunnel / External Access Instructions ===${RESET}"
  printf '\n'

  # Attention box
  local pad="  "
  printf '%b\n' "${YELLOW}${BOLD}${pad}⚠️  IMPORTANT: OPEN A NEW TERMINAL AND RUN${RESET}"
  printf '%b\n' "${pad}${BOLD}${RED}sudo minikube tunnel${RESET}"
  printf '%b\n' "${pad}${DIM}Leave that session open while using the cluster (Ctrl+C to stop).${RESET}"
  printf '\n'

  # If tunnel already running, tell them
  if pgrep -f "minikube tunnel" >/dev/null 2>&1; then
    printf '%b\n' "${GREEN}Note:${RESET} 'minikube tunnel' is already running."
    printf '\n'
  fi

  # Why/what
  printf '%b\n' "This exposes LoadBalancer services (ports 80/443) for your Ingress."
  printf '\n'

  # Endpoints
  printf '%b\n' "${BOLD}After the tunnel is running, the vanity hostnames should resolve (assuming /etc/hosts is configured):${RESET}"
  printf '%b\n' "  ${BLUE}Staging:${RESET}    http://staging.hello.local"
  printf '%b\n' "  ${BLUE}Production:${RESET} http://prod.hello.local"
  printf '%b\n' "  ${BLUE}ArgoCD UI:${RESET}  http://argocd.local"
  printf '\n'

  # Alternative path
  printf '%b\n' "${BOLD}Alternative (no tunnel):${RESET}"
  printf '%b\n' "Use ${BOLD}kubectl port-forward${RESET} to access services locally. See README.md → ${BOLD}Application Endpoints${RESET}."
  printf '%b\n' "Examples:"
  printf '%b\n' "  kubectl -n staging  port-forward svc/nginx-app      8080:80   # → http://localhost:8080"
  printf '%b\n' "  kubectl -n prod     port-forward svc/nginx-app      8081:80   # → http://localhost:8081"
  printf '%b\n' "  kubectl -n argocd   port-forward svc/argocd-server  8082:80   # → http://localhost:8082"
  printf '\n'
}

main() {
  check_prereqs
  start_minikube
  use_minikube_docker
  configure_hosts
  build_image
  run_terraform
  package_chart
  sync_repo_chart_assets
  deploy_local_helm_repo
  apply_argocd_apps
  wait_for_argocd_sync "nginx-staging"
  wait_for_argocd_sync "nginx-prod"
  wait_for_staging
  application_access

  echo
  echo "Deployment complete. Endpoints with minikube tunnel:"
  echo "  Staging: http://staging.hello.local"
  echo "  Production: http://prod.hello.local"
  echo "  ArgoCD UI: http://argocd.local"

  echo
  echo "ArgoCD access:"
  echo "  Username -> admin"
  echo "  Password -> kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 --decode"
  echo "  CLI      -> argocd login argocd.local --username admin --password <above> --grpc-web"

  if [ $HOSTS_UPDATED -eq 0 ]; then
    echo
    echo "Manual action: Add the following line to /etc/hosts if not already present:"
    echo "  127.0.0.1 staging.hello.local prod.hello.local argocd.local"
  fi

  echo
}

main "$@"
