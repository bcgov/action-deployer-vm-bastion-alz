#!/usr/bin/env bash
# =============================================================================
# run-deploy.sh - CI entry point for the reusable VM + Bastion deployer
# =============================================================================
# Invoked by .github/workflows/deploy.yml. Responsibilities:
#   1. Assemble override -var arguments from OVERRIDE_* env vars (non-empty).
#   2. Run the bundled deploy-terraform.sh with the requested command.
#
# The caller's tfvars file (if any) is fetched separately by fetch-tfvars.sh
# and written to INFRA_DIR/terraform.tfvars, which deploy-terraform.sh
# auto-detects and passes via -var-file.
#
# Terraform precedence reminder (highest wins):
#   -var (CLI)  >  -var-file=terraform.tfvars  >  TF_VAR_* env vars
# So OVERRIDE_* inputs win over the tfvars file, which wins over secret-backed
# TF_VAR_* defaults that are not present in the tfvars file.
#
# Required env (set by the workflow):
#   DEPLOYER_INFRA_DIR            Absolute path to the bundled infra directory
#   TERRAFORM_COMMAND            apply | plan | destroy
#   VM_ADMIN_LOGIN_PRINCIPAL_IDS  Comma-separated Entra object IDs (user/group)
#                                 -> converted to TF_VAR_vm_admin_login_principal_ids
# Optional env:
#   OVERRIDE_<var>               Override values applied as -var <var>=<value>
# =============================================================================
set -euo pipefail

INFRA_DIR="${DEPLOYER_INFRA_DIR:?DEPLOYER_INFRA_DIR is required}"
COMMAND="${TERRAFORM_COMMAND:-apply}"

# 1. Build override -var args from OVERRIDE_* env vars that are non-empty.
declare -A overrides=(
  [location]="${OVERRIDE_location:-}"
  [vm_size]="${OVERRIDE_vm_size:-}"
  [os_disk_size_gb]="${OVERRIDE_os_disk_size_gb:-}"
  [bastion_sku]="${OVERRIDE_bastion_sku:-}"
  [enable_bastion]="${OVERRIDE_enable_bastion:-}"
  [enable_jumpbox]="${OVERRIDE_enable_jumpbox:-}"
  [enable_bastion_automation]="${OVERRIDE_enable_bastion_automation:-}"
  [enable_monitoring]="${OVERRIDE_enable_monitoring:-}"
  [existing_log_analytics_workspace_id]="${OVERRIDE_existing_log_analytics_workspace_id:-}"
)

var_args=()
for key in "${!overrides[@]}"; do
  value="${overrides[$key]}"
  [[ -n "$value" ]] && var_args+=("-var=${key}=${value}")
done

# 2. Convert the comma-separated VM admin login principal IDs into a Terraform
#    list(string). These grant "Virtual Machine Administrator Login" on the
#    jumpbox; without at least one, nobody can Entra-SSH in. Each value must be
#    an Entra object ID (GUID) for a user OR a group - not a UPN, email, or name.
#    Validation is skipped for destroy (no RBAC is assigned during teardown).
guid_re='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
principal_items=()
IFS=',' read -ra raw_principal_ids <<<"${VM_ADMIN_LOGIN_PRINCIPAL_IDS:-}"
for raw_id in "${raw_principal_ids[@]}"; do
  id="${raw_id//[[:space:]]/}" # strip surrounding/embedded whitespace
  [[ -z "$id" ]] && continue
  if [[ ! "$id" =~ $guid_re ]]; then
    echo "::error::VM_ADMIN_LOGIN_PRINCIPAL_IDS contains '${id}', which is not an Entra object ID (GUID). Pass user/group object IDs, not UPNs, emails, or display names." >&2
    exit 1
  fi
  principal_items+=("\"${id}\"")
done

if [[ ${#principal_items[@]} -eq 0 ]]; then
  if [[ "${COMMAND}" == "destroy" ]]; then
    echo "VM_ADMIN_LOGIN_PRINCIPAL_IDS not set; skipping for destroy."
    export TF_VAR_vm_admin_login_principal_ids="[]"
  else
    echo "::error::VM_ADMIN_LOGIN_PRINCIPAL_IDS is empty. Provide at least one Entra user or group object ID so someone can log in to the jumpbox." >&2
    exit 1
  fi
else
  principal_csv="$(
    IFS=','
    printf '%s' "${principal_items[*]}"
  )"
  export TF_VAR_vm_admin_login_principal_ids="[${principal_csv}]"
  echo "Configured ${#principal_items[@]} VM admin login principal ID(s)."
fi

# 3. Run the bundled deploy script. CI=true triggers auto-approve for
#    apply/destroy inside deploy-terraform.sh.
cd "$INFRA_DIR"
echo "Running: deploy-terraform.sh ${COMMAND} ${var_args[*]:-}"
./deploy-terraform.sh "$COMMAND" "${var_args[@]}"

