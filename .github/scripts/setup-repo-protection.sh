#!/usr/bin/env bash
# =============================================================================
# setup-repo-protection.sh - One-time repo hardening via the GitHub API (gh)
# =============================================================================
# Configures the settings that make the Dependabot auto-merge workflow work:
#   1. Repo merge settings: enable auto-merge, squash-only, delete branch on merge.
#   2. Branch protection on the default branch: require 1 PR approval, linear
#      history, conversation resolution, and block force-push / deletion.
#
# Run locally by a repo admin (requires `gh auth login` with admin rights):
#   ./.github/scripts/setup-repo-protection.sh
#
# Environment overrides (all optional):
#   REPO              owner/repo                (default: bcgov/action-deployer-vm-bastion-alz)
#   BRANCH            branch to protect         (default: main)
#   REVIEW_COUNT      required approvals        (default: 1)
#   ENFORCE_ADMINS    apply rules to admins too (default: false)
#   REQUIRED_CHECKS   comma-separated status check contexts that must pass
#                     before merge (default: none). Example:
#                       REQUIRED_CHECKS="terraform-validate,lint"
# =============================================================================
set -euo pipefail

REPO="${REPO:-bcgov/action-deployer-vm-bastion-alz}"
BRANCH="${BRANCH:-main}"
REVIEW_COUNT="${REVIEW_COUNT:-1}"
ENFORCE_ADMINS="${ENFORCE_ADMINS:-false}"

# --- Preconditions -----------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is not installed. See https://cli.github.com/" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: not authenticated. Run 'gh auth login' first." >&2
  exit 1
fi
if ! gh api "repos/${REPO}/branches/${BRANCH}" >/dev/null 2>&1; then
  echo "Error: branch '${BRANCH}' not found in '${REPO}' (push an initial commit first)." >&2
  exit 1
fi

# --- 1. Repo merge settings --------------------------------------------------
echo "Configuring merge settings on ${REPO}..."
gh api -X PATCH "repos/${REPO}" \
  -F allow_auto_merge=true \
  -F delete_branch_on_merge=true \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false >/dev/null
echo "  auto-merge enabled, squash-only, delete branch on merge."

# --- 2. Branch protection ----------------------------------------------------
# Build the required_status_checks object from REQUIRED_CHECKS (or null).
build_required_status_checks() {
  if [[ -z "${REQUIRED_CHECKS:-}" ]]; then
    printf 'null'
    return
  fi
  local items=() c
  local IFS=','
  for c in ${REQUIRED_CHECKS}; do
    c="$(printf '%s' "$c" | xargs)" # trim surrounding whitespace
    [[ -n "$c" ]] && items+=("{\"context\":\"${c}\"}")
  done
  local joined
  joined="$(
    IFS=','
    printf '%s' "${items[*]}"
  )"
  printf '{"strict":true,"checks":[%s]}' "$joined"
}

REQUIRED_STATUS_CHECKS_JSON="$(build_required_status_checks)"

echo "Applying branch protection to ${REPO}@${BRANCH}..."
gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" \
  -H "Accept: application/vnd.github+json" \
  --input - >/dev/null <<JSON
{
  "required_status_checks": ${REQUIRED_STATUS_CHECKS_JSON},
  "enforce_admins": ${ENFORCE_ADMINS},
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": ${REVIEW_COUNT},
    "require_last_push_approval": false
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

echo "  ${REVIEW_COUNT} approval(s) required, linear history, conversations must resolve."
echo "Done. Dependabot PRs will auto-approve (patch/minor) and merge once checks pass."
