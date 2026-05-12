#!/usr/bin/env bash
set -euo pipefail

# ==========================================
#  TAP — Query Full Agent Profile (Pretty)
# ==========================================
#
# Usage:
#   ./script/query-tap-agent-profile.sh <agent_number>
#   ./script/query-tap-agent-profile.sh 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AGENT_NUM="${1:-1}"
AGENT_NAME="TAP_AGENT_${AGENT_NUM}"
ENV_FILE="${REPO_ROOT}/agents-dummy/${AGENT_NAME}.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "  ERROR: ${ENV_FILE} not found."
    exit 1
fi

if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

source "${ENV_FILE}"

export PC_RPC AGENT_NAME CANONICAL_AGENT_ID
AGENT_ID="${CANONICAL_AGENT_ID}" node "${SCRIPT_DIR}/demo-track-1/display/query-profile.mjs"
