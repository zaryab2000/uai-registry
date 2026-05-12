#!/usr/bin/env bash
set -euo pipefail

# ==========================================
#  TAP — Query Fragmented Agent State (Pretty)
# ==========================================
#
# Usage:
#   ./script/query-agent-profile.sh <agent_number>
#   ./script/query-agent-profile.sh 1

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

export BOUND_AGENT_ID_ETH BOUND_AGENT_ID_BASE BOUND_AGENT_ID_BSC
node "${SCRIPT_DIR}/demo-track-1/display/query-fragmented.mjs"
