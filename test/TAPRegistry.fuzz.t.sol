// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";
import {ITAPRegistry} from "src/interfaces/ITAPRegistry.sol";
import "src/libraries/RegistryErrors.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract TAPRegistryFuzz is Test {
    TAPRegistry public registry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");

    bytes32 constant CARD_HASH = keccak256("fuzz-card");

    // ERC-1967 admin slot: keccak256("eip1967.proxy.admin") - 1
    bytes32 constant ERC1967_ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    bytes32 public constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        factory = new MockUEAFactory();
        TAPRegistry impl = new TAPRegistry(factory);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), admin, abi.encodeCall(TAPRegistry.initialize, (admin, pauser))
        );
        registry = TAPRegistry(address(proxy));
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,,
        ) = registry.eip712Domain();

        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,"
                    "uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }

    function testFuzz_Register_AgentIdAlwaysMatchesCaller(
        address caller
    ) public {
        vm.assume(caller != address(0));
        vm.assume(caller != admin);
        vm.assume(caller != _proxyAdmin());

        uint256 truncated = uint256(uint160(caller)) % 10_000_000;
        uint256 expectedId = truncated == 0 ? 10_000_000 : truncated;
        vm.assume(!registry.isRegistered(expectedId));

        vm.prank(caller);
        uint256 agentId = registry.register("ipfs://fuzz", CARD_HASH);
        assertEq(agentId, expectedId);
    }

    function testFuzz_Register_IdInRange(
        address caller
    ) public {
        vm.assume(caller != address(0));
        vm.assume(caller != admin);
        vm.assume(caller != _proxyAdmin());

        uint256 truncated = uint256(uint160(caller)) % 10_000_000;
        uint256 expectedId = truncated == 0 ? 10_000_000 : truncated;
        vm.assume(!registry.isRegistered(expectedId));

        vm.prank(caller);
        uint256 agentId = registry.register("ipfs://fuzz", CARD_HASH);
        assertGt(agentId, 0);
        assertLe(agentId, 10_000_000);
    }

    function _proxyAdmin() internal view returns (address) {
        bytes32 slot = vm.load(address(registry), ERC1967_ADMIN_SLOT);
        return address(uint160(uint256(slot)));
    }

    function testFuzz_OwnerOf_AlwaysMatchesAgentId(
        address caller
    ) public {
        vm.assume(caller != address(0));
        vm.assume(caller != admin);
        vm.assume(caller != _proxyAdmin());

        vm.prank(caller);
        uint256 agentId = registry.register("ipfs://fuzz", CARD_HASH);
        assertEq(registry.ownerOf(agentId), caller);
    }

    function testFuzz_Bind_WrongSignerReverts(
        uint256 wrongKey,
        uint256 boundAgentId
    ) public {
        wrongKey = bound(wrongKey, 1, type(uint128).max);
        boundAgentId = bound(boundAgentId, 1, type(uint128).max);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzCaller");
        vm.assume(wrongKey != callerKey);

        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);

        ITAPRegistry.BindRequest memory req = ITAPRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: boundAgentId,
            proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        vm.expectRevert(InvalidBindSignature.selector);
        registry.bind(req);
    }

    function testFuzz_BindDedup_NoDuplicates(
        uint256 boundAgentId,
        uint256 chainIdNum
    ) public {
        boundAgentId = bound(boundAgentId, 1, type(uint128).max);
        chainIdNum = bound(chainIdNum, 1, 10_000);
        string memory chainId = vm.toString(chainIdNum);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzDedup");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes(chainId)),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        ITAPRegistry.BindRequest memory req = ITAPRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: chainId,
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: boundAgentId,
            proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        registry.bind(req);

        structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes(chainId)),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(2),
                block.timestamp + 1 hours
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (v, r, s) = vm.sign(callerKey, digest);

        ITAPRegistry.BindRequest memory req2 = ITAPRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: chainId,
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: boundAgentId,
            proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        vm.expectRevert();
        registry.bind(req2);
    }

    function testFuzz_UnbindRebind_AlwaysSucceeds(
        uint256 boundAgentId
    ) public {
        boundAgentId = bound(boundAgentId, 1, type(uint128).max);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzRelink");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        vm.startPrank(caller);
        registry.bind(
            ITAPRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId: boundAgentId,
                proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));

        structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(2),
                block.timestamp + 1 hours
            )
        );
        digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (v, r, s) = vm.sign(callerKey, digest);

        registry.bind(
            ITAPRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId: boundAgentId,
                proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 2,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();

        (address canonical,) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), boundAgentId
        );
        assertEq(canonical, caller);
    }

    function testFuzz_CanonicalUEAFromBinding_Consistent(
        uint256 boundAgentId
    ) public {
        boundAgentId = bound(boundAgentId, 1, type(uint128).max);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzConsistent");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        vm.startPrank(caller);
        registry.bind(
            ITAPRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId: boundAgentId,
                proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        (address canonical, bool verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), boundAgentId
        );
        assertEq(canonical, caller);
        assertTrue(verified);

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
        vm.stopPrank();

        (canonical, verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), boundAgentId
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }
}
