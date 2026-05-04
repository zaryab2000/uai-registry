// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UAIRegistry} from "src/UAIRegistry.sol";
import {IUAIRegistry} from "src/IUAIRegistry.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {UniversalAccountId} from "src/interfaces/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UAIRegistryFuzz is Test {
    UAIRegistry public registry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");

    bytes32 constant CARD_HASH = keccak256("fuzz-card");

    bytes32 public constant SHADOW_LINK_TYPEHASH = keccak256(
        "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        factory = new MockUEAFactory();
        UAIRegistry impl = new UAIRegistry(factory);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(UAIRegistry.initialize, (admin, pauser))
        );
        registry = UAIRegistry(address(proxy));
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        (
            ,
            string memory name,
            string memory version,
            uint256 chainId,
            address verifyingContract,
            ,
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

        vm.prank(caller);
        uint256 agentId = registry.register("ipfs://fuzz", CARD_HASH);
        assertEq(agentId, uint256(uint160(caller)));
    }

    function testFuzz_OwnerOf_AlwaysMatchesAgentId(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(caller != admin);

        vm.prank(caller);
        uint256 agentId = registry.register("ipfs://fuzz", CARD_HASH);
        assertEq(registry.ownerOf(agentId), caller);
    }

    function testFuzz_LinkShadow_OnlyAcceptsCorrectSigner(
        uint256 signerKey,
        uint256 shadowAgentId
    ) public {
        signerKey = bound(signerKey, 1, type(uint128).max);
        shadowAgentId = bound(shadowAgentId, 1, type(uint128).max);

        address caller = makeAddr("fuzzCaller");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: shadowAgentId,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        registry.linkShadow(req);

        (address canonical,) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId
        );
        assertEq(canonical, caller);
    }

    function testFuzz_ShadowDedup_NoDuplicates(
        uint256 shadowAgentId,
        uint256 chainIdNum
    ) public {
        shadowAgentId = bound(shadowAgentId, 1, type(uint128).max);
        chainIdNum = bound(chainIdNum, 1, 10_000);
        string memory chainId = vm.toString(chainIdNum);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzDedup");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes(chainId)),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: chainId,
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: shadowAgentId,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        registry.linkShadow(req);

        structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes(chainId)),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(2),
                block.timestamp + 1 hours
            )
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (v, r, s) = vm.sign(callerKey, digest);

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: chainId,
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: shadowAgentId,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: abi.encodePacked(r, s, v),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(caller);
        vm.expectRevert();
        registry.linkShadow(req2);
    }

    function testFuzz_UnlinkRelink_AlwaysSucceeds(
        uint256 shadowAgentId
    ) public {
        shadowAgentId = bound(shadowAgentId, 1, type(uint128).max);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzRelink");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        vm.startPrank(caller);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId: shadowAgentId,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );

        structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(2),
                block.timestamp + 1 hours
            )
        );
        digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (v, r, s) = vm.sign(callerKey, digest);

        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId: shadowAgentId,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 2,
                deadline: block.timestamp + 1 hours
            })
        );
        vm.stopPrank();

        (address canonical,) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId
        );
        assertEq(canonical, caller);
    }

    function testFuzz_CanonicalUEAFromShadow_Consistent(
        uint256 shadowAgentId
    ) public {
        shadowAgentId = bound(shadowAgentId, 1, type(uint128).max);

        (address caller, uint256 callerKey) = makeAddrAndKey("fuzzConsistent");
        vm.prank(caller);
        registry.register("ipfs://fuzz", CARD_HASH);

        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId,
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(callerKey, digest);

        vm.startPrank(caller);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId: shadowAgentId,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        (address canonical, bool verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId
        );
        assertEq(canonical, caller);
        assertTrue(verified);

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
        vm.stopPrank();

        (canonical, verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }
}
