#!/usr/bin/env bash
# =============================================================================
# fetch-tfvars.sh - Download the caller's tfvars file via the GitHub raw API
# =============================================================================
# Used by the reusable workflow instead of checking out the whole caller repo.
# When a tfvars_file path is provided, the file is fetched from the caller
# repository at the triggering ref and written into the bundled infra directory
# as terraform.tfvars (which deploy-terraform.sh auto-detects).
#
# Because this runs inside a reusable workflow, the GitHub contexts below refer
# to the CALLER repository / ref, so the file is pulled from the consuming team's
# repo, not from this deployer repo.
#
# Required env (set by the workflow):
#   TFVARS_FILE_INPUT    Path to the tfvars file within the caller repo
#   CALLER_REPOSITORY    owner/repo of the caller (github.repository)
#   CALLER_REF           Branch/ref to fetch from
#   DEPLOYER_INFRA_DIR   Destination infra directory
# Optional env:
#   GITHUB_TOKEN         Token for private-repo access (recommended)
# =============================================================================
set -euo pipefail

# No tfvars file requested -> nothing to do (deploy falls back to inputs/secrets).
if [[ -z "${TFVARS_FILE_INPUT:-}" ]]; then
  echo "No tfvars_file provided; skipping fetch (using inputs/secrets only)."
  exit 0
fi

INFRA_DIR="${DEPLOYER_INFRA_DIR:?DEPLOYER_INFRA_DIR is required}"
REPO="${CALLER_REPOSITORY:?CALLER_REPOSITORY is required}"
# ref_name = branch on push, head_ref = source branch on PR, default_branch fallback.
BRANCH_OR_REF="${CALLER_REF:?CALLER_REF is required}"

# Normalize the path: strip a leading ./ or / so the raw URL is well-formed.
TFVARS_PATH="${TFVARS_FILE_INPUT#./}"
TFVARS_PATH="${TFVARS_PATH#/}"

TFVARS_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH_OR_REF}/${TFVARS_PATH}"
DEST="${INFRA_DIR}/terraform.tfvars"

# Build curl auth options if a token is provided (required for private repos).
CURL_AUTH_OPTS=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  CURL_AUTH_OPTS=(-H "Authorization: token ${GITHUB_TOKEN}")
fi

echo "Fetching tfvars: ${TFVARS_URL}"

# Validate the URL is reachable before downloading.
if ! curl "${CURL_AUTH_OPTS[@]}" --output /dev/null --silent --head --fail "${TFVARS_URL}"; then
  echo "::error::tfvars file not found or inaccessible: ${TFVARS_URL}"
  echo "Hint: if the caller repo is private, ensure the calling workflow grants"
  echo "      'contents: read' so the automatic GITHUB_TOKEN can read the file."
  exit 1
fi

# Download into the bundled infra directory.
curl "${CURL_AUTH_OPTS[@]}" --silent --show-error --fail --location "${TFVARS_URL}" --output "${DEST}"
echo "Wrote ${DEST}"
