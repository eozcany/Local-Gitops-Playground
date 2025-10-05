#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="argocd"
IMAGE_REPOSITORY="nginx-demo"
DEFAULT_SOURCE_ENV="staging"

usage() {
  cat <<USAGE
Promote or rollback a container image tag for an environment (staging or prod).

Usage: $0 -e <environment> [-t <image-tag>]

Options:
  -e, --env <environment>   Target environment to update (staging|prod) [required]
  -t, --tag <image-tag>     Tag to apply. If omitted and env=prod, the tag is copied from staging.
  -h, --help                Show this help message

Examples:
  $0 -e staging -t 1.1.0      # set staging to tag 1.1.0
  $0 -e prod -t 1.0.0         # force prod to tag 1.0.0 (manual rollback)
  $0 -e prod                  # copy current staging tag into production
USAGE
}

ENV=""
TAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    -e|--env)
      shift
      [ $# -gt 0 ] || { echo "--env requires a value" >&2; exit 1; }
      ENV="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
      ;;
    -t|--tag)
      shift
      [ $# -gt 0 ] || { echo "--tag requires a value" >&2; exit 1; }
      TAG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [ -z "$ENV" ]; then
  echo "--env is required" >&2
  usage >&2
  exit 1
fi

case "$ENV" in
  staging|prod) ;;
  *)
    echo "Environment must be 'staging' or 'prod'" >&2
    exit 1
    ;;
esac

APP="nginx-$ENV"

get_application_tag() {
  local app_name="$1"
  kubectl -n "$NAMESPACE" get application "$app_name" \
    -o jsonpath="{range .spec.source.helm.parameters[?(@.name=='image.tag')]}{.value}{end}" 2>/dev/null
}

ensure_tag_exists() {
  local tag_value="$1"
  if ! command -v minikube >/dev/null 2>&1; then
    echo "minikube command not found; cannot verify image availability." >&2
    return 0
  fi
  eval "$(minikube -p minikube docker-env)"
  if ! docker image inspect "$IMAGE_REPOSITORY:$tag_value" >/dev/null 2>&1; then
    echo "Image $IMAGE_REPOSITORY:$tag_value not found in Minikube's Docker daemon." >&2
    echo "Build it first (e.g. ./scripts/build.sh --tag $tag_value) or ensure it is accessible to the cluster." >&2
    exit 1
  fi
}

if [ -z "$TAG" ]; then
  if [ "$ENV" = "prod" ]; then
    TAG=$(get_application_tag "nginx-$DEFAULT_SOURCE_ENV") || true
    if [ -z "$TAG" ]; then
      echo "Could not determine image tag from nginx-$DEFAULT_SOURCE_ENV. Specify --tag explicitly." >&2
      exit 1
    fi
    echo "Using staging tag $TAG for production"
  else
    echo "--tag is required when promoting to staging" >&2
    exit 1
  fi
fi

ensure_tag_exists "$TAG"

PATCH_PAYLOAD=$(printf '{"spec":{"source":{"helm":{"parameters":[{"name":"image.repository","value":"%s"},{"name":"image.tag","value":"%s"}]}}}}' "$IMAGE_REPOSITORY" "$TAG")

kubectl -n "$NAMESPACE" patch application "$APP" --type merge --patch "$PATCH_PAYLOAD" >/dev/null

echo "Update requested. ArgoCD will reconcile '$APP' toward image tag '$TAG'."
