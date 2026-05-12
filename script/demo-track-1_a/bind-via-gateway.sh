#!/usr/bin/env bash
set -euo pipefail

# ==========================================
#  TAP Demo — Bind External Chain via Gateway
# ==========================================
#
# Binds a source chain agent ID to the canonical Push Chain
# identity by sending the bind() call through the Universal
# Gateway on Sepolia. The Agent Builder never leaves Sepolia.
#
# Usage:
#   ./script/demo-track-1_a/bind-via-gateway.sh <agent_number> <chain>
#   ./script/demo-track-1_a/bind-via-gateway.sh 2 sepolia
#   ./script/demo-track-1_a/bind-via-gateway.sh 2 base
#   ./script/demo-track-1_a/bind-via-gateway.sh 2 bsc
#   ./script/demo-track-1_a/bind-via-gateway.sh 2 all
#
# Env vars required:
#   AGENT_BUILDER_KEY    - Private key for the Agent Builder wallet

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if [[ -z "${1:-}" || -z "${2:-}" ]]; then
    echo ""
    echo "  Usage: $0 <agent_number> <chain>"
    echo "  chain: sepolia | base | bsc | all"
    echo ""
    exit 1
fi

AGENT_NUM="$1"
CHAIN="$2"
AGENT_NAME="TAP_AGENT_${AGENT_NUM}"
ENV_FILE="${REPO_ROOT}/agents-dummy/${AGENT_NAME}.env"

if [[ ! -f "${ENV_FILE}" ]]; then
    echo "  ERROR: ${ENV_FILE} not found."
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
ERC8004_IDENTITY="${ERC8004_IDENTITY:-0x8004A818BFB912233c491871b3d84c89A494BD9e}"
ZERO="0x0000000000000000000000000000000000000000"

if [[ -z "${UEA_ADDRESS:-}" ]]; then
    echo "  ERROR: UEA_ADDRESS not set in ${ENV_FILE}"
    echo "  Run register-via-gateway.sh first."
    exit 1
fi

AGENT_BUILDER=$(cast wallet address "${AGENT_BUILDER_KEY}")

# ── Bind function ──────────────────────────────────

bind_chain() {
    local chain_name="$1"
    local chain_id="$2"
    local bound_agent_id="$3"
    local default_nonce="$4"
    local nonce_env_key="$5"

    # Use previously saved nonce + 1 if this chain was bound before
    local prev_nonce
    prev_nonce=$(grep "^${nonce_env_key}=" "${ENV_FILE}" 2>/dev/null \
        | tail -1 | cut -d= -f2)
    local nonce
    if [[ -n "${prev_nonce}" ]]; then
        nonce=$((prev_nonce + 1))
        echo "  NOTE: ${nonce_env_key}=${prev_nonce} found — using nonce ${nonce}"
    else
        nonce="${default_nonce}"
    fi

    echo ""
    echo "=========================================="
    echo "  BIND: ${chain_name} (eip155:${chain_id})"
    echo "=========================================="
    echo "  Canonical UEA:   ${UEA_ADDRESS}"
    echo "  Bound Agent ID:  ${bound_agent_id}"
    echo "  Bind Nonce:      ${nonce}"
    echo ""

    # 1. Compute EIP-712 domain separator (Push Chain domain)
    echo "  [1/6] Computing EIP-712 domain separator..."

    DOMAIN_TYPEHASH=$(cast keccak \
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    NAME_HASH=$(cast keccak "TAP")
    VERSION_HASH=$(cast keccak "1")

    DOMAIN_SEP=$(cast keccak "$(cast abi-encode \
        'f(bytes32,bytes32,bytes32,uint256,address)' \
        "${DOMAIN_TYPEHASH}" \
        "${NAME_HASH}" \
        "${VERSION_HASH}" \
        42101 \
        "${AGENT_REGISTRY}")")

    # 2. Compute struct hash
    echo "  [2/6] Computing struct hash..."

    local deadline=9999999999

    BIND_TYPEHASH=$(cast keccak \
        "Bind(address canonicalUEA,string chainNamespace,string chainId,address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)")

    STRUCT_HASH=$(cast keccak "$(cast abi-encode \
        'f(bytes32,address,bytes32,bytes32,address,uint256,uint256,uint256)' \
        "${BIND_TYPEHASH}" \
        "${UEA_ADDRESS}" \
        "$(cast keccak 'eip155')" \
        "$(cast keccak "${chain_id}")" \
        "${ERC8004_IDENTITY}" \
        "${bound_agent_id}" \
        "${nonce}" \
        "${deadline}")")

    # 3. Compute EIP-712 digest
    echo "  [3/6] Computing EIP-712 digest..."

    DIGEST=$(cast keccak "$(cast concat-hex 0x1901 "${DOMAIN_SEP}" "${STRUCT_HASH}")")

    # 4. Sign with Agent Builder key (matches ownerKey)
    echo "  [4/6] Signing with Agent Builder key..."

    SIGNATURE=$(cast wallet sign --no-hash "${DIGEST}" \
        --private-key "${AGENT_BUILDER_KEY}")

    # 5. Encode bind() calldata and wrap in UniversalPayload
    echo "  [5/6] Constructing gateway payload..."

    BIND_CALLDATA=$(cast calldata \
        "bind((string,string,address,uint256,uint8,bytes,uint256,uint256))" \
        "(eip155,${chain_id},${ERC8004_IDENTITY},${bound_agent_id},0,${SIGNATURE},${nonce},${deadline})")

    PAYLOAD=$(cast abi-encode \
        "f((address,uint256,bytes,uint256,uint256,uint256,uint256,uint256,uint8))" \
        "(${AGENT_REGISTRY},0,${BIND_CALLDATA},100000000,10000000000,0,0,9999999999,1)")

    # 6. Send via Universal Gateway on Sepolia
    echo "  [6/6] Sending gateway transaction..."

    TX_HASH=$(cast send "${GATEWAY_SEPOLIA}" \
        "sendUniversalTx((address,address,uint256,bytes,address,bytes))" \
        "(${ZERO},${ZERO},0,${PAYLOAD},${AGENT_BUILDER},0x)" \
        --private-key "${AGENT_BUILDER_KEY}" \
        --rpc-url "${SEPOLIA_RPC}" \
        --json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['transactionHash'])")

    echo ""
    echo "  TX Hash:         ${TX_HASH}"
    echo ""

    # Poll for binding confirmation
    echo "  Waiting for Push Chain execution..."

    local max_attempts=40
    local attempt=0
    local confirmed="false"

    while [[ ${attempt} -lt ${max_attempts} ]]; do
        attempt=$((attempt + 1))

        local result
        result=$(cast call "${AGENT_REGISTRY}" \
            "canonicalUEAFromBinding(string,string,address,uint256)(address,bool)" \
            "eip155" "${chain_id}" "${ERC8004_IDENTITY}" "${bound_agent_id}" \
            --rpc-url "${PC_RPC}" 2>/dev/null || echo "")

        if echo "${result}" | grep -q "true"; then
            confirmed="true"
            echo "  BOUND after ${attempt} polls (~$((attempt * 5))s)"
            break
        fi

        printf "  Poll %d/%d — not yet bound...\r" "${attempt}" "${max_attempts}"
        sleep 5
    done

    echo ""

    if [[ "${confirmed}" != "true" ]]; then
        echo "  WARNING: Binding not confirmed after $((max_attempts * 5))s"
        echo "  Gateway TX: ${TX_HASH}"
        echo "  Check manually later."
    else
        echo "  VERIFIED: eip155:${chain_id} => ${UEA_ADDRESS}"
    fi

    # Save to env
    if grep -q "^${nonce_env_key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i '' "s/^${nonce_env_key}=.*/${nonce_env_key}=${nonce}/" "${ENV_FILE}"
    else
        if ! grep -q "# Step 3: Bindings via gateway" "${ENV_FILE}" 2>/dev/null; then
            echo "" >> "${ENV_FILE}"
            echo "# Step 3: Bindings via gateway" >> "${ENV_FILE}"
        fi
        echo "${nonce_env_key}=${nonce}" >> "${ENV_FILE}"
    fi

    local tx_env_key="BIND_TX_${chain_name// /_}"
    if grep -q "^${tx_env_key}=" "${ENV_FILE}" 2>/dev/null; then
        sed -i '' "s/^${tx_env_key}=.*/${tx_env_key}=${TX_HASH}/" "${ENV_FILE}"
    else
        echo "${tx_env_key}=${TX_HASH}" >> "${ENV_FILE}"
    fi

    echo "  Saved nonce and tx to ${ENV_FILE}"
    echo "------------------------------------------"
}

# ── Dispatch ───────────────────────────────────────

case "${CHAIN}" in
    sepolia|eth)
        bind_chain "ETH" "11155111" "${BOUND_AGENT_ID_ETH}" 1 "BIND_NONCE_ETH"
        ;;
    base)
        bind_chain "BASE" "84532" "${BOUND_AGENT_ID_BASE}" 2 "BIND_NONCE_BASE"
        ;;
    bsc)
        bind_chain "BSC" "97" "${BOUND_AGENT_ID_BSC}" 3 "BIND_NONCE_BSC"
        ;;
    all)
        bind_chain "ETH" "11155111" "${BOUND_AGENT_ID_ETH}" 1 "BIND_NONCE_ETH"
        bind_chain "BASE" "84532" "${BOUND_AGENT_ID_BASE}" 2 "BIND_NONCE_BASE"
        bind_chain "BSC" "97" "${BOUND_AGENT_ID_BSC}" 3 "BIND_NONCE_BSC"
        ;;
    *)
        echo "  ERROR: Unknown chain '${CHAIN}'"
        echo "  Use: sepolia | base | bsc | all"
        exit 1
        ;;
esac

echo ""
echo "=========================================="
echo "  BINDING COMPLETE"
echo "=========================================="

BINDING_COUNT=$(cast call "${AGENT_REGISTRY}" \
    "getBindings(uint256)" "${CANONICAL_AGENT_ID}" \
    --rpc-url "${PC_RPC}" 2>/dev/null | head -1)

echo "  Agent:     ${AGENT_NAME}"
echo "  UEA:       ${UEA_ADDRESS}"
echo "  Env file:  ${ENV_FILE}"
echo "=========================================="
echo ""
