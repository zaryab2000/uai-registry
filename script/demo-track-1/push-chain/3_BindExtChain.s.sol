// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";
import {ITAPRegistry} from "src/interfaces/ITAPRegistry.sol";

/// @title 3_BindExtChain
/// @notice Binds an external chain's ERC-8004 agent identity to the
///         canonical Push Chain identity via EIP-712 signed proof.
///         Run once per source chain.
///
/// Usage:
///   CHAIN_NS=eip155 CHAIN_ID=11155111 BOUND_AGENT_ID=<id> BIND_NONCE=1 \
///   forge script script/demo/push-chain/3_BindExtChain.s.sol \
///     --private-key $AGENT_BUILDER_KEY \
///     --rpc-url $PC_RPC --broadcast -vvvv
///
/// Env vars required:
///   AGENT_REGISTRY    - TAPRegistry proxy address
///   ERC8004_IDENTITY  - Registry address on the source chain
///   CHAIN_NS          - CAIP-2 namespace (e.g. "eip155")
///   CHAIN_ID          - CAIP-2 chain ID (e.g. "11155111")
///   BOUND_AGENT_ID    - Agent ID on the source chain
///   BIND_NONCE        - Nonce for this binding (1, 2, 3, ...)
///   AGENT_BUILDER_KEY - Private key (used for vm.sign)
contract BindExtChain is Script {
    bytes32 constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce," "uint256 deadline)"
    );

    struct BindParams {
        address registryAddr;
        address sourceRegistry;
        string chainNs;
        string chainId;
        uint256 boundAgentId;
        uint256 nonce;
        uint256 signerKey;
        uint256 deadline;
    }

    function run() external {
        BindParams memory p = _loadParams();
        _printInputs(p);

        bytes memory signature = _signBind(p);

        TAPRegistry registry = TAPRegistry(p.registryAddr);

        ITAPRegistry.BindRequest memory req = ITAPRegistry.BindRequest({
            chainNamespace: p.chainNs,
            chainId: p.chainId,
            registryAddress: p.sourceRegistry,
            boundAgentId: p.boundAgentId,
            proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: signature,
            nonce: p.nonce,
            deadline: p.deadline
        });

        vm.startBroadcast(p.signerKey);
        registry.bind(req);
        vm.stopBroadcast();

        _printResult(registry, p);
    }

    function _loadParams() internal view returns (BindParams memory p) {
        p.registryAddr = vm.envAddress("AGENT_REGISTRY");
        p.sourceRegistry = vm.envAddress("ERC8004_IDENTITY");
        p.chainNs = vm.envString("CHAIN_NS");
        p.chainId = vm.envString("CHAIN_ID");
        p.boundAgentId = vm.envUint("BOUND_AGENT_ID");
        p.nonce = vm.envUint("BIND_NONCE");
        p.signerKey = vm.envUint("AGENT_BUILDER_KEY");
        p.deadline = block.timestamp + 1 hours;
    }

    function _signBind(
        BindParams memory p
    ) internal view returns (bytes memory) {
        TAPRegistry registry = TAPRegistry(p.registryAddr);
        address caller = vm.addr(p.signerKey);

        bytes32 domainSep = _domainSeparator(registry);
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes(p.chainNs)),
                keccak256(bytes(p.chainId)),
                p.sourceRegistry,
                p.boundAgentId,
                p.nonce,
                p.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(p.signerKey, digest);
        console.log("  Signature     generated (65 bytes)");
        return abi.encodePacked(r, s, v);
    }

    function _printInputs(
        BindParams memory p
    ) internal pure {
        _header("STEP 3: Bind External Chain Identity");
        _log("Chain NS", p.chainNs);
        _log("Chain ID", p.chainId);
        _log("Source Registry", vm.toString(p.sourceRegistry));
        _log("Bound Agent ID", vm.toString(p.boundAgentId));
        _log("Nonce", vm.toString(p.nonce));
        _log("Deadline", vm.toString(p.deadline));
        _log("Signer", vm.toString(vm.addr(p.signerKey)));
        _separator();
    }

    function _printResult(
        TAPRegistry registry,
        BindParams memory p
    ) internal view {
        address caller = vm.addr(p.signerKey);
        uint256 agentId = registry.agentIdOfUEA(caller);

        ITAPRegistry.BindEntry[] memory bindings = registry.getBindings(agentId);

        _header("BIND RESULT");
        _log("Status", "SUCCESS");
        _log("Total Bindings", vm.toString(bindings.length));
        console.log("");

        for (uint256 i; i < bindings.length; i++) {
            string memory entry = string.concat(
                "  [",
                vm.toString(i),
                "] ",
                bindings[i].chainNamespace,
                ":",
                bindings[i].chainId,
                "  agentId=",
                vm.toString(bindings[i].boundAgentId)
            );
            console.log(entry);
        }
        _separator();

        (address canonical, bool verified) =
            registry.canonicalUEAFromBinding(p.chainNs, p.chainId, p.sourceRegistry, p.boundAgentId);

        _header("REVERSE LOOKUP VERIFICATION");
        _log("Canonical UEA", vm.toString(canonical));
        _log("Verified", verified ? "true" : "false");
        _separator();
    }

    function _domainSeparator(
        TAPRegistry registry
    ) internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 cId, address verifyingContract,,) =
            registry.eip712Domain();

        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,"
                    "uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                cId,
                verifyingContract
            )
        );
    }

    function _header(
        string memory title
    ) internal pure {
        console.log("");
        console.log("==========================================");
        console.log("  %s", title);
        console.log("==========================================");
    }

    function _log(
        string memory key,
        string memory value
    ) internal pure {
        console.log("  %-16s %s", key, value);
    }

    function _separator() internal pure {
        console.log("------------------------------------------");
    }
}
