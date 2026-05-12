#!/usr/bin/env bash
set -euo pipefail

# ==========================================
#  TAP Demo — Register Agent via Universal Gateway
# ==========================================
#
# The Agent Builder stays on Ethereum Sepolia and calls
# UniversalGateway.sendUniversalTx() to register the agent
# on Push Chain's AgentRegistry without ever transacting
# on Push Chain directly.
#
# Usage:
#   ./script/demo-track-1_a/register-via-gateway.sh <agent_number>
#   ./script/demo-track-1_a/register-via-gateway.sh 2
#
# Env vars required:
#   AGENT_BUILDER_KEY    - Private key for the Agent Builder wallet
#   AGENT_REGISTRY       - AgentRegistry proxy on Push Chain
#
# Env vars optional (loaded from .env):
#   SEPOLIA_RPC, PC_RPC, GATEWAY_SEPOLIA

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

AGENT_NUM="${1:-}"
if [[ -z "${AGENT_NUM}" ]]; then
    echo ""
    echo "  Usage: $0 <agent_number>"
    echo ""
    exit 1
fi

AGENT_NAME="TAP_AGENT_${AGENT_NUM}"
ENV_FILE="${REPO_ROOT}/agents-dummy/${AGENT_NAME}.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "  ERROR: ${ENV_FILE} not found."
    echo "  Run generate-agent-card.sh ${AGENT_NUM} first."
    exit 1
fi

source "${ENV_FILE}"

if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    source "${REPO_ROOT}/.env"
    set +a
fi

AGENT_REGISTRY="${AGENT_REGISTRY:-0x13499d36729467bd5C6B44725a10a0113cE47178}"
GATEWAY_SEPOLIA="${GATEWAY_SEPOLIA:-0x05bD7a3D18324c1F7e216f7fBF2b15985aE5281A}"
SEPOLIA_RPC="${SEPOLIA_RPC:-https://ethereum-sepolia-rpc.publicnode.com}"
PC_RPC="${PC_RPC:-https://evm.donut.rpc.push.org/}"
UEA_FACTORY="0x00000000000000000000000000000000000000eA"
AGENT_BUILDER=$(cast wallet address "${AGENT_BUILDER_KEY}")

echo ""
echo "=========================================="
echo "  STEP 2: Register via Universal Gateway"
echo "=========================================="
echo "  Agent:           ${AGENT_NAME}"
echo "  Agent Builder:   ${AGENT_BUILDER}"
echo "  Gateway:         ${GATEWAY_SEPOLIA}"
echo "  Target:          ${AGENT_REGISTRY} (Push Chain)"
echo "  Source Chain:     Sepolia (11155111)"
echo ""

# ── 1. Discover UEA address ────────────────────────
echo "  [1/5] Discovering UEA address..."

UEA_RESULT=$(cast call "${UEA_FACTORY}" \
    "getUEAForOrigin((string,string,bytes))((address,bool))" \
    "(eip155,11155111,${AGENT_BUILDER})" \
    --rpc-url "${PC_RPC}")

UEA_ADDRESS=$(echo "${UEA_RESULT}" | sed -n 's/.*(\(0x[0-9a-fA-F]*\),.*/\1/p')
UEA_DEPLOYED=$(echo "${UEA_RESULT}" | grep -o 'true\|false')

echo "  UEA Address:     ${UEA_ADDRESS}"
echo "  UEA Deployed:    ${UEA_DEPLOYED}"

TRUNCATED_ID=$(python3 -c "print(int('${UEA_ADDRESS}', 16) % 10_000_000)")
if [[ "${TRUNCATED_ID}" == "0" ]]; then TRUNCATED_ID=10000000; fi
echo "  Expected ID:     ${TRUNCATED_ID}"
echo ""

# ── 2. Check if already registered ─────────────────
echo "  [2/5] Checking if already registered..."

EXISTING_ID=$(cast call "${AGENT_REGISTRY}" \
    "agentIdOfUEA(address)(uint256)" "${UEA_ADDRESS}" \
    --rpc-url "${PC_RPC}" 2>/dev/null || echo "0")

if [[ "${EXISTING_ID}" != "0" ]]; then
    echo "  ALREADY REGISTERED — agent ID ${EXISTING_ID}"
    CANONICAL_AGENT_ID="${EXISTING_ID}"

    if grep -q "^CANONICAL_AGENT_ID=" "${ENV_FILE}" 2>/dev/null; then
        sed -i '' "s/^CANONICAL_AGENT_ID=.*/CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID}/" "${ENV_FILE}"
    else
        echo "CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID}" >> "${ENV_FILE}"
    fi
    echo "  Saved CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID} -> ${ENV_FILE}"
    echo ""
    exit 0
fi
echo "  Not registered yet — proceeding"
echo ""

# ── 3. Construct payload ───────────────────────────
echo "  [3/5] Constructing gateway payload..."

INNER_CALLDATA=$(cast calldata \
    "register(string,bytes32)" \
    "${AGENT_URI}" "${AGENT_CARD_HASH}")

echo "  Inner calldata:  ${INNER_CALLDATA:0:20}...${INNER_CALLDATA: -8}"

# UniversalPayload struct: (to, value, data, gasLimit,
#   maxFeePerGas, maxPriorityFeePerGas, nonce, deadline, vType)
PAYLOAD=$(cast abi-encode \
    "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
    "(${AGENT_REGISTRY},0,${INNER_CALLDATA},100000000,10000000000,0,0,9999999999,1)")

echo "  Payload size:    ${#PAYLOAD} chars"
echo ""

# ── 4. Send gateway transaction ────────────────────
echo "  [4/5] Sending gateway transaction on Sepolia..."
echo "        (msg.value = 0, INBOUND_FEE = 0)"
echo ""

ZERO="0x0000000000000000000000000000000000000000"

TX_HASH=$(cast send "${GATEWAY_SEPOLIA}" \
    "sendUniversalTx((address,address,uint256,bytes,address,bytes))" \
    "(${ZERO},${ZERO},0,${PAYLOAD},${AGENT_BUILDER},0x)" \
    --private-key "${AGENT_BUILDER_KEY}" \
    --rpc-url "${SEPOLIA_RPC}" \
    --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

echo "  TX Hash:         ${TX_HASH}"
echo "  Chain:           Sepolia (11155111)"
echo ""

# ── 5. Poll Push Chain for registration ─────────────
echo "  [5/5] Waiting for Push Chain execution..."
echo "        (TSS relay takes ~30-120 seconds)"
echo ""

MAX_ATTEMPTS=40
SLEEP_INTERVAL=5
ATTEMPT=0
CANONICAL_AGENT_ID=""

while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    CANONICAL_AGENT_ID=$(cast call "${AGENT_REGISTRY}" \
        "agentIdOfUEA(address)(uint256)" "${UEA_ADDRESS}" \
        --rpc-url "${PC_RPC}" 2>/dev/null || echo "0")

    if [[ "${CANONICAL_AGENT_ID}" != "0" ]]; then
        echo "  REGISTERED after ${ATTEMPT} polls (~$((ATTEMPT * SLEEP_INTERVAL))s)"
        echo "  Agent ID: ${CANONICAL_AGENT_ID}"
        break
    fi

    printf "  Poll %d/%d — not yet registered...\r" "${ATTEMPT}" "${MAX_ATTEMPTS}"
    sleep "${SLEEP_INTERVAL}"
done

echo ""

if [[ -z "${CANONICAL_AGENT_ID}" || "${CANONICAL_AGENT_ID}" == "0" ]]; then
    CANONICAL_AGENT_ID="${TRUNCATED_ID}"
    echo "  WARNING: Registration not confirmed after $((MAX_ATTEMPTS * SLEEP_INTERVAL))s"
    echo "  The gateway tx succeeded on Sepolia (${TX_HASH})"
    echo "  but Push Chain hasn't processed it yet."
    echo ""
    echo "  You can manually check later:"
    echo "    cast call ${AGENT_REGISTRY} 'agentIdOfUEA(address)(uint256)' ${UEA_ADDRESS} --rpc-url ${PC_RPC}"
    echo ""
    echo "  Saving expected agent ID (${TRUNCATED_ID}) to env file..."
fi

# ── Verify registration details ─────────────────────
if [[ "${CANONICAL_AGENT_ID}" != "0" && -n "${CANONICAL_AGENT_ID}" ]]; then
    echo ""
    echo "=========================================="
    echo "  REGISTRATION VERIFIED"
    echo "=========================================="

    RECORD=$(cast call "${AGENT_REGISTRY}" \
        "getAgentRecord(uint256)" "${CANONICAL_AGENT_ID}" \
        --rpc-url "${PC_RPC}" 2>/dev/null)

    OWNER=$(cast call "${AGENT_REGISTRY}" \
        "ownerOf(uint256)(address)" "${CANONICAL_AGENT_ID}" \
        --rpc-url "${PC_RPC}" 2>/dev/null)

    echo "  Agent ID:        ${CANONICAL_AGENT_ID}"
    echo "  UEA (owner):     ${OWNER}"
    echo "  Expected UEA:    ${UEA_ADDRESS}"
    echo ""

    UEA_CODE=$(cast code "${UEA_ADDRESS}" --rpc-url "${PC_RPC}" 2>/dev/null)
    if [[ "${UEA_CODE}" != "0x" && -n "${UEA_CODE}" ]]; then
        echo "  UEA has code:    YES (deployed)"
    else
        echo "  UEA has code:    NO (not deployed)"
    fi
fi

# ── Save to env file ────────────────────────────────
if grep -q "^UEA_ADDRESS=" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s/^UEA_ADDRESS=.*/UEA_ADDRESS=${UEA_ADDRESS}/" "${ENV_FILE}"
else
    echo "" >> "${ENV_FILE}"
    echo "# Step 2: Canonical registration via gateway" >> "${ENV_FILE}"
    echo "UEA_ADDRESS=${UEA_ADDRESS}" >> "${ENV_FILE}"
fi

if grep -q "^CANONICAL_AGENT_ID=" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s/^CANONICAL_AGENT_ID=.*/CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID}/" "${ENV_FILE}"
else
    echo "CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID}" >> "${ENV_FILE}"
fi

if grep -q "^GATEWAY_TX_HASH=" "${ENV_FILE}" 2>/dev/null; then
    sed -i '' "s/^GATEWAY_TX_HASH=.*/GATEWAY_TX_HASH=${TX_HASH}/" "${ENV_FILE}"
else
    echo "GATEWAY_TX_HASH=${TX_HASH}" >> "${ENV_FILE}"
fi

echo ""
echo "=========================================="
echo "  SAVED TO ${ENV_FILE}"
echo "=========================================="
echo "  UEA_ADDRESS=${UEA_ADDRESS}"
echo "  CANONICAL_AGENT_ID=${CANONICAL_AGENT_ID}"
echo "  GATEWAY_TX_HASH=${TX_HASH}"
echo ""
echo "  To load: source ${ENV_FILE}"
echo "=========================================="
echo ""
