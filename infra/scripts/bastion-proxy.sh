#!/usr/bin/env bash
# bastion-proxy.sh — open a SOCKS5 proxy through Azure Bastion to the jumpbox.
#
# Usage:
#   ./bastion-proxy.sh -g <resource-group> -b <bastion-name> -v <vm-name> \
#                      [-p <port>] [-s <subscription>]
#   ./bastion-proxy.sh --self-test     # unit-check find_free_port, no Azure needed
#
# Prereqs (see README): Azure CLI 2.65+, logged in (`az login`). The bastion/ssh
# CLI extensions install on first use via dynamic install. Default port: 8228.
#
set -euo pipefail

PORT=8228
SUBSCRIPTION=""
RG="" BASTION="" VM=""

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# find_free_port START — first TCP port at or above START that nothing is listening on.
find_free_port() {
  local p="$1"
  while (echo >"/dev/tcp/127.0.0.1/$p") 2>/dev/null; do p=$((p + 1)); done
  printf '%s' "$p"
}

if [[ "${1:-}" == "--self-test" ]]; then
  p="$(find_free_port 49213)"
  if [[ "$p" =~ ^[0-9]+$ && "$p" -ge 49213 ]]; then
    echo "self-test ok (free port: $p)"
    exit 0
  fi
  echo "self-test FAILED: find_free_port returned '$p'" >&2
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g | --resource-group) RG="$2"; shift 2 ;;
    -b | --bastion)        BASTION="$2"; shift 2 ;;
    -v | --vm)             VM="$2"; shift 2 ;;
    -p | --port)           PORT="$2"; shift 2 ;;
    -s | --subscription)   SUBSCRIPTION="$2"; shift 2 ;;
    -h | --help)           usage 0 ;;
    *) echo "Unknown argument: $1" >&2; usage 1 ;;
  esac
done

[[ -n "$RG" && -n "$BASTION" && -n "$VM" ]] ||
  { echo "Error: -g, -b and -v are required." >&2; usage 1; }
command -v az >/dev/null ||
  { echo "Error: Azure CLI not found. Install az 2.65+ (see README)." >&2; exit 1; }

[[ -n "$SUBSCRIPTION" ]] && az account set --subscription "$SUBSCRIPTION"
az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors >/dev/null

# Start the jumpbox if auto-shutdown has deallocated it (az vm start is a no-op if running).
state="$(az vm get-instance-view -g "$RG" -n "$VM" \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>/dev/null || true)"
if [[ "$state" != "PowerState/running" ]]; then
  echo "Jumpbox is ${state:-unknown}; starting $VM ..."
  az vm start -g "$RG" -n "$VM" --only-show-errors >/dev/null
fi

VM_ID="$(az vm show -g "$RG" -n "$VM" --query id -o tsv)"
PORT="$(find_free_port "$PORT")"

AZ_PID=""
cleanup() { [[ -n "$AZ_PID" ]] && kill "$AZ_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo "Opening SOCKS5 proxy on 127.0.0.1:${PORT} via Bastion ${BASTION} ..."
# MSYS_NO_PATHCONV: Git Bash/MSYS must not rewrite the /subscriptions/... resource ID.
MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' az network bastion ssh \
  --name "$BASTION" --resource-group "$RG" --target-resource-id "$VM_ID" \
  --auth-type AAD -- -D "127.0.0.1:${PORT}" -N \
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ExitOnForwardFailure=yes &
AZ_PID=$!

# Wait up to 60s for the proxy to start accepting connections.
for _ in $(seq 1 30); do
  (echo >"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null && break
  sleep 2
done

echo "SOCKS5 proxy ready: 127.0.0.1:${PORT}  (Ctrl-C to close)"
echo "Point your browser or CLI at socks5h://127.0.0.1:${PORT} to reach private endpoints via the jumpbox."
wait "$AZ_PID"
