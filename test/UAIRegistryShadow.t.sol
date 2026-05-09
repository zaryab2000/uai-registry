// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UAIRegistry} from "src/UAIRegistry.sol";
import {IUAIRegistry} from "src/interfaces/IUAIRegistry.sol";
import "src/libraries/Errors.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UAIRegistryShadowTest is Test {
    UAIRegistry public registry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public ueaUser;
    uint256 public ueaUserKey;
    address public shadowOwner;
    uint256 public shadowOwnerKey;

    bytes32 constant CARD_HASH = keccak256("agent-card");
    string constant AGENT_URI = "ipfs://QmTest";

    bytes32 public constant SHADOW_LINK_TYPEHASH = keccak256(
        "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        (ueaUser, ueaUserKey) = makeAddrAndKey("ueaUser");
        (shadowOwner, shadowOwnerKey) = makeAddrAndKey("shadowOwner");

        factory = new MockUEAFactory();
        factory.addUEA(
            ueaUser,
            UniversalAccountId({
                chainNamespace: "eip155",
                chainId: "1",
                owner: abi.encodePacked(ueaUser)
            })
        );

        UAIRegistry impl = new UAIRegistry(factory);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(UAIRegistry.initialize, (admin, pauser))
        );
        registry = UAIRegistry(address(proxy));

        vm.prank(ueaUser);
        registry.register(AGENT_URI, CARD_HASH);
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

    struct SignParams {
        uint256 signerKey;
        address canonicalUEA;
        string chainNs;
        string chainId;
        address registryAddr;
        uint256 shadowAgentId;
        uint256 nonce;
        uint256 deadline;
    }

    function _signShadowLinkProper(
        uint256 signerKey,
        address canonicalUEA,
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 shadowAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signShadowLink(
            SignParams(signerKey, canonicalUEA, chainNs, chainId, registryAddr, shadowAgentId, nonce, deadline)
        );
    }

    function _signShadowLink(SignParams memory p) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                p.canonicalUEA,
                keccak256(bytes(p.chainNs)),
                keccak256(bytes(p.chainId)),
                p.registryAddr,
                p.shadowAgentId,
                p.nonce,
                p.deadline
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(p.signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultReq(
        uint256 nonce
    ) internal view returns (IUAIRegistry.ShadowLinkRequest memory) {
        return IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42,
                nonce,
                block.timestamp + 1 hours
            ),
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });
    }

    // ──────────────────────────────────────────────
    //  linkShadow
    // ──────────────────────────────────────────────

    function test_LinkShadow_ValidSignature_CreatesLink() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.linkShadow(req);

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 1);
        assertEq(shadows[0].chainNamespace, "eip155");
        assertEq(shadows[0].chainId, "1");
        assertEq(shadows[0].shadowAgentId, 42);
        assertTrue(shadows[0].verified);
    }

    function test_LinkShadow_EmitsEvent() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        uint256 agentId = uint256(uint160(ueaUser));

        vm.expectEmit(true, false, false, true);
        emit IUAIRegistry.ShadowLinked(
            agentId,
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42,
            IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            true
        );

        vm.prank(ueaUser);
        registry.linkShadow(req);
    }

    function test_LinkShadow_NotRegistered_Reverts() public {
        address nobody = makeAddr("nobody");
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentNotRegistered.selector,
                uint256(uint160(nobody))
            )
        );
        registry.linkShadow(req);
    }

    function test_LinkShadow_ExpiredDeadline_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        req.deadline = block.timestamp - 1;

        vm.prank(ueaUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShadowLinkExpired.selector, req.deadline
            )
        );
        registry.linkShadow(req);
    }

    function test_LinkShadow_ReusedNonce_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 17,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "8453",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                17,
                1,
                block.timestamp + 1 hours
            ),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(
            abi.encodeWithSelector(ShadowLinkNonceUsed.selector, 1)
        );
        registry.linkShadow(req2);
        vm.stopPrank();
    }

    function test_LinkShadow_WrongSigner_Reverts() public {
        (, uint256 otherKey) = makeAddrAndKey("otherSigner");

        IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                otherKey,
                ueaUser,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42,
                1,
                block.timestamp + 1 hours
            ),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ueaUser);
        vm.expectRevert(InvalidShadowSignature.selector);
        registry.linkShadow(req);
    }

    function test_LinkShadow_GarbageSignature_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: hex"deadbeef",
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ueaUser);
        vm.expectRevert(InvalidShadowSignature.selector);
        registry.linkShadow(req);
    }

    function test_LinkShadow_EmptyChainNamespace_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        req.chainNamespace = "";

        vm.prank(ueaUser);
        vm.expectRevert(InvalidChainIdentifier.selector);
        registry.linkShadow(req);
    }

    function test_LinkShadow_EmptyChainId_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        req.chainId = "";

        vm.prank(ueaUser);
        vm.expectRevert(InvalidChainIdentifier.selector);
        registry.linkShadow(req);
    }

    function test_LinkShadow_ZeroRegistry_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        req.registryAddress = address(0);

        vm.prank(ueaUser);
        vm.expectRevert(InvalidRegistryAddress.selector);
        registry.linkShadow(req);
    }

    function test_LinkShadow_DuplicateShadow_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42,
                2,
                block.timestamp + 1 hours
            ),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                ShadowAlreadyClaimed.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42
            )
        );
        registry.linkShadow(req2);
        vm.stopPrank();
    }

    function test_LinkShadow_DifferentAgentSameShadow_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.linkShadow(req);

        address ueaUser2 = makeAddr("ueaUser2");
        factory.addUEA(
            ueaUser2,
            UniversalAccountId({
                chainNamespace: "eip155",
                chainId: "1",
                owner: abi.encodePacked(ueaUser2)
            })
        );
        vm.prank(ueaUser2);
        registry.register(AGENT_URI, CARD_HASH);

        (, uint256 signer2Key) = makeAddrAndKey("signer2");
        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                signer2Key,
                ueaUser2,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42,
                1,
                block.timestamp + 1 hours
            ),
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ueaUser2);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShadowAlreadyClaimed.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42
            )
        );
        registry.linkShadow(req2);
    }

    function test_LinkShadow_MaxShadowsExceeded_Reverts() public {
        uint256 agentId = uint256(uint160(ueaUser));

        vm.startPrank(ueaUser);
        for (uint256 i = 0; i < 64; i++) {
            string memory chainId = vm.toString(i + 100);
            IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: chainId,
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId: i,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: _signShadowLinkProper(
                    ueaUserKey,
                    ueaUser,
                    "eip155",
                    chainId,
                    address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                    i,
                    i + 10,
                    block.timestamp + 1 hours
                ),
                nonce: i + 10,
                deadline: block.timestamp + 1 hours
            });
            registry.linkShadow(req);
        }

        IUAIRegistry.ShadowLinkRequest memory req65 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "999",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 999,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "999",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                999,
                100,
                block.timestamp + 1 hours
            ),
            nonce: 100,
            deadline: block.timestamp + 1 hours
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                MaxShadowsExceeded.selector, agentId
            )
        );
        registry.linkShadow(req65);
        vm.stopPrank();
    }

    function test_LinkShadow_64Shadows_Succeeds() public {
        vm.startPrank(ueaUser);
        for (uint256 i = 0; i < 64; i++) {
            string memory chainId = vm.toString(i + 100);
            IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: chainId,
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                shadowAgentId: i,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: _signShadowLinkProper(
                    ueaUserKey,
                    ueaUser,
                    "eip155",
                    chainId,
                    address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                    i,
                    i + 10,
                    block.timestamp + 1 hours
                ),
                nonce: i + 10,
                deadline: block.timestamp + 1 hours
            });
            registry.linkShadow(req);
        }
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 64);
    }

    function test_LinkShadow_WhenPaused_Reverts() public {
        vm.prank(pauser);
        registry.pause();

        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.linkShadow(req);
    }

    function test_LinkShadow_MultipleShadows_AllStored() public {
        vm.startPrank(ueaUser);

        IUAIRegistry.ShadowLinkRequest memory req1 = _defaultReq(1);
        registry.linkShadow(req1);

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 17,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "8453",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                17,
                2,
                block.timestamp + 1 hours
            ),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req2);

        IUAIRegistry.ShadowLinkRequest memory req3 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 8,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "42161",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                8,
                3,
                block.timestamp + 1 hours
            ),
            nonce: 3,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req3);
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 3);
        assertEq(shadows[0].shadowAgentId, 42);
        assertEq(shadows[1].shadowAgentId, 17);
        assertEq(shadows[2].shadowAgentId, 8);
    }

    // ──────────────────────────────────────────────
    //  unlinkShadow
    // ──────────────────────────────────────────────

    function test_UnlinkShadow_Owner_RemovesLink() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 0);

        (address canonical,) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42
        );
        assertEq(canonical, address(0));
    }

    function test_UnlinkShadow_EmitsEvent() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);
        uint256 agentId = uint256(uint160(ueaUser));

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        vm.expectEmit(true, false, false, true);
        emit IUAIRegistry.ShadowUnlinked(
            agentId,
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
        vm.stopPrank();
    }

    function test_UnlinkShadow_NotRegistered_Reverts() public {
        address nobody = makeAddr("nobody");

        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentNotRegistered.selector,
                uint256(uint160(nobody))
            )
        );
        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
    }

    function test_UnlinkShadow_NoLink_Reverts() public {
        vm.prank(ueaUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShadowNotFound.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
            )
        );
        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
    }

    function test_UnlinkShadow_RelinkAfterUnlink_Succeeds() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 42,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey,
                ueaUser,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42,
                2,
                block.timestamp + 1 hours
            ),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req2);
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 1);
        assertEq(shadows[0].shadowAgentId, 42);
    }

    function test_UnlinkShadow_SwapAndPop_Preserves() public {
        vm.startPrank(ueaUser);

        IUAIRegistry.ShadowLinkRequest memory req1 = _defaultReq(1);
        registry.linkShadow(req1);

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 17,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey, ueaUser, "eip155", "8453",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 17, 2,
                block.timestamp + 1 hours
            ),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req2);

        IUAIRegistry.ShadowLinkRequest memory req3 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 8,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey, ueaUser, "eip155", "42161",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 8, 3,
                block.timestamp + 1 hours
            ),
            nonce: 3,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req3);

        // Unlink the middle element (eip155/8453)
        registry.unlinkShadow(
            "eip155",
            "8453",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 2);
        assertEq(shadows[0].shadowAgentId, 42);
        // Last element swapped into middle position
        assertEq(shadows[1].shadowAgentId, 8);

        // Verify the swapped element is still resolvable
        (address canonical,) = registry.canonicalUEAFromShadow(
            "eip155",
            "42161",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            8
        );
        assertEq(canonical, ueaUser);
    }

    function test_UnlinkShadow_WhenPaused_Reverts() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.linkShadow(req);

        vm.prank(pauser);
        registry.pause();

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
    }

    // ──────────────────────────────────────────────
    //  canonicalUEAFromShadow
    // ──────────────────────────────────────────────

    function test_CanonicalUEAFromShadow_LinkedAgent_ReturnsUEA() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.linkShadow(req);

        (address canonical, bool verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42
        );
        assertEq(canonical, ueaUser);
        assertTrue(verified);
    }

    function test_CanonicalUEAFromShadow_VerifiedFlag() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.linkShadow(req);

        (, bool verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42
        );
        assertTrue(verified);
    }

    function test_CanonicalUEAFromShadow_NoLink_ReturnsZero() public view {
        (address canonical, bool verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            999
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }

    function test_CanonicalUEAFromShadow_AfterUnlink_ReturnsZero() public {
        IUAIRegistry.ShadowLinkRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.linkShadow(req);

        registry.unlinkShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );
        vm.stopPrank();

        (address canonical, bool verified) = registry.canonicalUEAFromShadow(
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }

    // ──────────────────────────────────────────────
    //  getShadows
    // ──────────────────────────────────────────────

    function test_GetShadows_ReturnsAll() public {
        vm.startPrank(ueaUser);
        registry.linkShadow(_defaultReq(1));

        IUAIRegistry.ShadowLinkRequest memory req2 = IUAIRegistry.ShadowLinkRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            shadowAgentId: 17,
            proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
            proofData: _signShadowLinkProper(
                ueaUserKey, ueaUser, "eip155", "8453",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 17, 2,
                block.timestamp + 1 hours
            ),
            nonce: 2,
            deadline: block.timestamp + 1 hours
        });
        registry.linkShadow(req2);
        vm.stopPrank();

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 2);
    }

    function test_GetShadows_EmptyAgent_ReturnsEmpty() public view {
        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(ueaUser)));
        assertEq(shadows.length, 0);
    }

    // ──────────────────────────────────────────────
    //  ERC-1271 Signature Verification
    // ──────────────────────────────────────────────

    function _setupERC1271Agent(
        MockERC1271Wallet wallet
    ) internal returns (address walletUEA, uint256 walletAgentId) {
        walletUEA = address(wallet);
        factory.addUEA(
            walletUEA,
            UniversalAccountId({
                chainNamespace: "eip155",
                chainId: "1",
                owner: abi.encodePacked(walletUEA)
            })
        );
        vm.prank(walletUEA);
        walletAgentId = registry.register(AGENT_URI, CARD_HASH);
    }

    function _erc1271ProofData(
        address signer,
        bytes memory signature
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(signer, signature);
    }

    function _buildERC1271Digest(
        address canonicalUEA,
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 shadowAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                canonicalUEA,
                keccak256(bytes(chainNs)),
                keccak256(bytes(chainId)),
                registryAddr,
                shadowAgentId,
                nonce,
                deadline
            )
        );
        return keccak256(
            abi.encodePacked(
                "\x19\x01", _getDomainSeparator(), structHash
            )
        );
    }

    function test_LinkShadow_ERC1271_ValidSignature() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg =
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(
            walletUEA, bytes("dummy-sig")
        );

        vm.prank(walletUEA);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                shadowAgentId: 100,
                proofType: IUAIRegistry
                    .ShadowProofType
                    .OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );

        uint256 walletAgentId = uint256(uint160(walletUEA));
        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(walletAgentId);
        assertEq(shadows.length, 1);
        assertEq(shadows[0].shadowAgentId, 100);
    }

    function test_LinkShadow_ERC1271_Reverts_ReturnsFalse() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        wallet.setRevert(true);
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg =
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(
            walletUEA, bytes("dummy-sig")
        );

        vm.prank(walletUEA);
        vm.expectRevert(InvalidShadowSignature.selector);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                shadowAgentId: 100,
                proofType: IUAIRegistry
                    .ShadowProofType
                    .OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );
    }

    function test_LinkShadow_ERC1271_BadMagic_Reverts() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        wallet.setReturnBadMagic(true);
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg =
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(
            walletUEA, bytes("dummy-sig")
        );

        vm.prank(walletUEA);
        vm.expectRevert(InvalidShadowSignature.selector);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                shadowAgentId: 100,
                proofType: IUAIRegistry
                    .ShadowProofType
                    .OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );
    }
}
