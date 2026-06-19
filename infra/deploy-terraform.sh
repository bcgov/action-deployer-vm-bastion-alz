#!/usr/bin/env bash
# =============================================================================
# deploy-terraform.sh — Terraform operations for the bundled infra/.
# =============================================================================
# Usage (from repo root or infra/):
#   ./infra/deploy-terraform.sh <command> [terraform args...]
#
# Commands: init | plan | apply | destroy | validate | fmt | output | refresh | state
#
# Environment:
#   CI=true                  auto-approve apply/destroy, no interactive prompts
#   ARM_USE_OIDC=true        use OIDC (CI); otherwise Azure CLI auth is used
#   BACKEND_RESOURCE_GROUP / BACKEND_STORAGE_ACCOUNT / BACKEND_CONTAINER_NAME /
#   BACKEND_STATE_KEY        azurerm remote-state backend config
#   TF_VAR_*                 standard Terraform variables
#
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="${SCRIPT_DIR}"
TFVARS_FILE="${INFRA_DIR}/terraform.tfvars"

BACKEND_RESOURCE_GROUP="${BACKEND_RESOURCE_GROUP:-}"
BACKEND_STORAGE_ACCOUNT="${BACKEND_STORAGE_ACCOUNT:-}"
BACKEND_CONTAINER_NAME="${BACKEND_CONTAINER_NAME:-tfstate}"
BACKEND_STATE_KEY="${BACKEND_STATE_KEY:-}"

USE_TFVARS=false
TFVARS_ARGS=()

log() { echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [deploy] $*" >&2; }

usage() {
  sed -n '4,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

check_prerequisites() {
  command -v terraform >/dev/null || { log "ERROR: terraform not installed"; exit 1; }
  command -v az >/dev/null || { log "ERROR: Azure CLI not installed"; exit 1; }
  if ! az account show >/dev/null 2>&1; then
    if [[ "${CI:-false}" == "true" ]]; then
      log "CI mode: assuming OIDC/service-principal authentication"
    else
      log "Not logged in to Azure; running 'az login'..."
      az login
    fi
  fi
}

setup_azure_auth() {
  local sub="${TF_VAR_subscription_id:-}"
  if [[ -z "$sub" && -f "$TFVARS_FILE" ]]; then
    sub="$(grep -E "^subscription_id\s*=" "$TFVARS_FILE" | sed 's/.*=\s*"\(.*\)".*/\1/' | tr -d ' ' || true)"
  fi
  [[ -n "$sub" ]] && az account set --subscription "$sub"

  export ARM_SUBSCRIPTION_ID="${sub:-$(az account show --query id -o tsv)}"
  export ARM_TENANT_ID="${TF_VAR_tenant_id:-}"
  if [[ "${ARM_USE_OIDC:-false}" == "true" || "${TF_VAR_use_oidc:-false}" == "true" ]]; then
    export ARM_USE_OIDC=true
    export ARM_CLIENT_ID="${TF_VAR_client_id:-${ARM_CLIENT_ID:-}}"
    log "Using OIDC authentication"
  else
    export ARM_USE_CLI=true
    log "Using Azure CLI authentication"
  fi
}

setup_variables_source() {
  if [[ -f "$TFVARS_FILE" ]]; then
    USE_TFVARS=true
    TFVARS_ARGS=("-var-file=$TFVARS_FILE")
    log "Using terraform.tfvars"
    return
  fi
  local required=(TF_VAR_app_name TF_VAR_subscription_id TF_VAR_tenant_id
    TF_VAR_location TF_VAR_resource_group_name TF_VAR_vnet_name
    TF_VAR_vnet_resource_group_name TF_VAR_vnet_address_space)
  local missing=()
  for v in "${required[@]}"; do [[ -z "${!v:-}" ]] && missing+=("$v"); done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log "ERROR: missing required environment variables: ${missing[*]}"
    exit 1
  fi
}

tf_init() {
  log "Initializing Terraform (backend: ${BACKEND_STORAGE_ACCOUNT}/${BACKEND_CONTAINER_NAME}/${BACKEND_STATE_KEY})"
  cd "$INFRA_DIR"
  local args=()
  [[ "${CI:-false}" == "true" ]] && args+=("-input=false")
  terraform init -upgrade "${args[@]}" \
    -backend-config="resource_group_name=${BACKEND_RESOURCE_GROUP}" \
    -backend-config="storage_account_name=${BACKEND_STORAGE_ACCOUNT}" \
    -backend-config="container_name=${BACKEND_CONTAINER_NAME}" \
    -backend-config="key=${BACKEND_STATE_KEY}" \
    -backend-config="use_oidc=${ARM_USE_OIDC:-false}" \
    "$@"
}

ensure_initialized() {
  cd "$INFRA_DIR"
  [[ -d ".terraform" && -f ".terraform.lock.hcl" ]] || tf_init
}

tf_plan() {
  ensure_initialized
  cd "$INFRA_DIR"
  terraform plan "${TFVARS_ARGS[@]}" "$@"
}

tf_apply() {
  # Always init in CI (idempotent) so module/provider changes never error.
  [[ "${CI:-false}" == "true" ]] && tf_init || ensure_initialized
  cd "$INFRA_DIR"
  local args=("${TFVARS_ARGS[@]}")
  [[ "${CI:-false}" == "true" ]] && args+=("-auto-approve")
  terraform apply "${args[@]}" "$@"
  log "Apply complete; outputs:"
  terraform output
}

tf_destroy() {
  ensure_initialized
  cd "$INFRA_DIR"
  local args=("${TFVARS_ARGS[@]}")
  if [[ "${CI:-false}" == "true" ]]; then
    args+=("-auto-approve")
  else
    read -r -p "This will DESTROY infrastructure. Type 'yes' to continue: " confirm
    [[ "$confirm" == "yes" ]] || { log "Destroy cancelled"; exit 0; }
  fi
  terraform destroy "${args[@]}" "$@"
}

main() {
  [[ $# -ge 1 ]] || usage
  local command="$1"; shift
  [[ "${CI:-false}" == "true" ]] && log "Running in CI mode (auto-approve enabled)"

  case "$command" in
    fmt | validate) ;; # no Azure auth needed
    *) check_prerequisites; setup_azure_auth; setup_variables_source ;;
  esac

  cd "$INFRA_DIR"
  case "$command" in
    init)     tf_init "$@" ;;
    plan)     tf_plan "$@" ;;
    apply)    tf_apply "$@" ;;
    destroy)  tf_destroy "$@" ;;
    validate) terraform validate "$@" ;;
    fmt)      terraform fmt -recursive "$@" ;;
    output)   terraform output "$@" ;;
    refresh)  ensure_initialized; terraform refresh "${TFVARS_ARGS[@]}" "$@" ;;
    state)    terraform state "$@" ;;
    *)        log "Unknown command: $command"; usage ;;
  esac
}

main "$@"
