// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "src/AgentRegistry.sol";
import {IAgentRegistry} from "src/interfaces/IAgentRegistry.sol";
import "src/libraries/Errors.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {MockERC1271Wallet} from "./mocks/MockERC1271Wallet.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract AgentRegistryBindTest is Test {
    AgentRegistry public registry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public ueaUser;
    uint256 public ueaUserKey;
    address public shadowOwner;
    uint256 public shadowOwnerKey;

    bytes32 constant CARD_HASH = keccak256("agent-card");
    string constant AGENT_URI = "ipfs://QmTest";

    bytes32 public constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        (ueaUser, ueaUserKey) = makeAddrAndKey("ueaUser");
        (shadowOwner, shadowOwnerKey) = makeAddrAndKey("shadowOwner");

        factory = new MockUEAFactory();
        factory.addUEA(
            ueaUser,
            UniversalAccountId({
                chainNamespace: "eip155", chainId: "1", owner: abi.encodePacked(ueaUser)
            })
        );

        AgentRegistry impl = new AgentRegistry(factory);
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl), admin, abi.encodeCall(AgentRegistry.initialize, (admin, pauser))
        );
        registry = AgentRegistry(address(proxy));

        vm.prank(ueaUser);
        registry.register(AGENT_URI, CARD_HASH);
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

    struct SignParams {
        uint256 signerKey;
        address canonicalUEA;
        string chainNs;
        string chainId;
        address registryAddr;
        uint256 boundAgentId;
        uint256 nonce;
        uint256 deadline;
    }

    function _signBindProper(
        uint256 signerKey,
        address canonicalUEA,
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 boundAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signBind(
            SignParams(
                signerKey,
                canonicalUEA,
                chainNs,
                chainId,
                registryAddr,
                boundAgentId,
                nonce,
                deadline
            )
        );
    }

    function _signBind(
        SignParams memory p
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                p.canonicalUEA,
                keccak256(bytes(p.chainNs)),
                keccak256(bytes(p.chainId)),
                p.registryAddr,
                p.boundAgentId,
                p.nonce,
                p.deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(p.signerKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _defaultReq(
        uint256 nonce
    ) internal view returns (IAgentRegistry.BindRequest memory) {
        return IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
    //  bind
    // ──────────────────────────────────────────────

    function test_Bind_ValidSignature_CreatesLink() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.bind(req);

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 1);
        assertEq(bindings[0].chainNamespace, "eip155");
        assertEq(bindings[0].chainId, "1");
        assertEq(bindings[0].boundAgentId, 42);
        assertTrue(bindings[0].verified);
    }

    function test_Bind_EmitsEvent() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        uint256 agentId = uint256(uint160(ueaUser));

        vm.expectEmit(true, false, false, true);
        emit IAgentRegistry.AgentBound(
            agentId,
            "eip155",
            "1",
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            42,
            IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            true
        );

        vm.prank(ueaUser);
        registry.bind(req);
    }

    function test_Bind_NotRegistered_Reverts() public {
        address nobody = makeAddr("nobody");
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(AgentNotRegistered.selector, uint256(uint160(nobody)))
        );
        registry.bind(req);
    }

    function test_Bind_ExpiredDeadline_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        req.deadline = block.timestamp - 1;

        vm.prank(ueaUser);
        vm.expectRevert(abi.encodeWithSelector(BindExpired.selector, req.deadline));
        registry.bind(req);
    }

    function test_Bind_ReusedNonce_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.bind(req);

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 17,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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

        vm.expectRevert(abi.encodeWithSelector(BindNonceUsed.selector, 1));
        registry.bind(req2);
        vm.stopPrank();
    }

    function test_Bind_WrongSigner_Reverts() public {
        (, uint256 otherKey) = makeAddrAndKey("otherSigner");

        IAgentRegistry.BindRequest memory req = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        vm.expectRevert(InvalidBindSignature.selector);
        registry.bind(req);
    }

    function test_Bind_GarbageSignature_Reverts() public {
        IAgentRegistry.BindRequest memory req = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: hex"deadbeef",
            nonce: 1,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ueaUser);
        vm.expectRevert(InvalidBindSignature.selector);
        registry.bind(req);
    }

    function test_Bind_EmptyChainNamespace_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        req.chainNamespace = "";

        vm.prank(ueaUser);
        vm.expectRevert(InvalidChainIdentifier.selector);
        registry.bind(req);
    }

    function test_Bind_EmptyChainId_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        req.chainId = "";

        vm.prank(ueaUser);
        vm.expectRevert(InvalidChainIdentifier.selector);
        registry.bind(req);
    }

    function test_Bind_ZeroRegistry_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        req.registryAddress = address(0);

        vm.prank(ueaUser);
        vm.expectRevert(InvalidRegistryAddress.selector);
        registry.bind(req);
    }

    function test_Bind_DuplicateBinding_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.bind(req);

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
                BindingAlreadyClaimed.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42
            )
        );
        registry.bind(req2);
        vm.stopPrank();
    }

    function test_Bind_DifferentAgentSameBinding_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.bind(req);

        address ueaUser2 = makeAddr("ueaUser2");
        factory.addUEA(
            ueaUser2,
            UniversalAccountId({
                chainNamespace: "eip155", chainId: "1", owner: abi.encodePacked(ueaUser2)
            })
        );
        vm.prank(ueaUser2);
        registry.register(AGENT_URI, CARD_HASH);

        (, uint256 signer2Key) = makeAddrAndKey("signer2");
        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
                BindingAlreadyClaimed.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                42
            )
        );
        registry.bind(req2);
    }

    function test_Bind_MaxBindingsExceeded_Reverts() public {
        uint256 agentId = uint256(uint160(ueaUser));

        vm.startPrank(ueaUser);
        for (uint256 i = 0; i < 64; i++) {
            string memory chainId = vm.toString(i + 100);
            IAgentRegistry.BindRequest memory req = IAgentRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: chainId,
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId: i,
                proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: _signBindProper(
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
            registry.bind(req);
        }

        IAgentRegistry.BindRequest memory req65 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "999",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 999,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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

        vm.expectRevert(abi.encodeWithSelector(MaxBindingsExceeded.selector, agentId));
        registry.bind(req65);
        vm.stopPrank();
    }

    function test_Bind_64Bindings_Succeeds() public {
        vm.startPrank(ueaUser);
        for (uint256 i = 0; i < 64; i++) {
            string memory chainId = vm.toString(i + 100);
            IAgentRegistry.BindRequest memory req = IAgentRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: chainId,
                registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
                boundAgentId: i,
                proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: _signBindProper(
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
            registry.bind(req);
        }
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 64);
    }

    function test_Bind_WhenPaused_Reverts() public {
        vm.prank(pauser);
        registry.pause();

        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.bind(req);
    }

    function test_Bind_MultipleBindings_AllStored() public {
        vm.startPrank(ueaUser);

        IAgentRegistry.BindRequest memory req1 = _defaultReq(1);
        registry.bind(req1);

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 17,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req2);

        IAgentRegistry.BindRequest memory req3 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 8,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req3);
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 3);
        assertEq(bindings[0].boundAgentId, 42);
        assertEq(bindings[1].boundAgentId, 17);
        assertEq(bindings[2].boundAgentId, 8);
    }

    // ──────────────────────────────────────────────
    //  unbind
    // ──────────────────────────────────────────────

    function test_Unbind_Owner_RemovesLink() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.bind(req);

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 0);

        (address canonical,) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 42
        );
        assertEq(canonical, address(0));
    }

    function test_Unbind_EmitsEvent() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);
        uint256 agentId = uint256(uint160(ueaUser));

        vm.startPrank(ueaUser);
        registry.bind(req);

        vm.expectEmit(true, false, false, true);
        emit IAgentRegistry.AgentUnbound(
            agentId, "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
        );

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
        vm.stopPrank();
    }

    function test_Unbind_NotRegistered_Reverts() public {
        address nobody = makeAddr("nobody");

        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(AgentNotRegistered.selector, uint256(uint160(nobody)))
        );
        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
    }

    function test_Unbind_NoLink_Reverts() public {
        vm.prank(ueaUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                BindingNotFound.selector,
                "eip155",
                "1",
                address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432)
            )
        );
        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
    }

    function test_Unbind_RebindAfterUnbind_Succeeds() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.bind(req);

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 42,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req2);
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 1);
        assertEq(bindings[0].boundAgentId, 42);
    }

    function test_Unbind_SwapAndPop_Preserves() public {
        vm.startPrank(ueaUser);

        IAgentRegistry.BindRequest memory req1 = _defaultReq(1);
        registry.bind(req1);

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 17,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req2);

        IAgentRegistry.BindRequest memory req3 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 8,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req3);

        // Unbind the middle element (eip155/8453)
        registry.unbind("eip155", "8453", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 2);
        assertEq(bindings[0].boundAgentId, 42);
        // Last element swapped into middle position
        assertEq(bindings[1].boundAgentId, 8);

        // Verify the swapped element is still resolvable
        (address canonical,) = registry.canonicalUEAFromBinding(
            "eip155", "42161", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 8
        );
        assertEq(canonical, ueaUser);
    }

    function test_Unbind_WhenPaused_Reverts() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.bind(req);

        vm.prank(pauser);
        registry.pause();

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
    }

    // ──────────────────────────────────────────────
    //  canonicalUEAFromBinding
    // ──────────────────────────────────────────────

    function test_CanonicalUEAFromBinding_LinkedAgent_ReturnsUEA() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.bind(req);

        (address canonical, bool verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 42
        );
        assertEq(canonical, ueaUser);
        assertTrue(verified);
    }

    function test_CanonicalUEAFromBinding_VerifiedFlag() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.prank(ueaUser);
        registry.bind(req);

        (, bool verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 42
        );
        assertTrue(verified);
    }

    function test_CanonicalUEAFromBinding_NoLink_ReturnsZero() public view {
        (address canonical, bool verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 999
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }

    function test_CanonicalUEAFromBinding_AfterUnbind_ReturnsZero() public {
        IAgentRegistry.BindRequest memory req = _defaultReq(1);

        vm.startPrank(ueaUser);
        registry.bind(req);

        registry.unbind("eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432));
        vm.stopPrank();

        (address canonical, bool verified) = registry.canonicalUEAFromBinding(
            "eip155", "1", address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432), 42
        );
        assertEq(canonical, address(0));
        assertFalse(verified);
    }

    // ──────────────────────────────────────────────
    //  getBindings
    // ──────────────────────────────────────────────

    function test_GetBindings_ReturnsAll() public {
        vm.startPrank(ueaUser);
        registry.bind(_defaultReq(1));

        IAgentRegistry.BindRequest memory req2 = IAgentRegistry.BindRequest({
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432),
            boundAgentId: 17,
            proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: _signBindProper(
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
        registry.bind(req2);
        vm.stopPrank();

        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 2);
    }

    function test_GetBindings_EmptyAgent_ReturnsEmpty() public view {
        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(uint256(uint160(ueaUser)));
        assertEq(bindings.length, 0);
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
                chainNamespace: "eip155", chainId: "1", owner: abi.encodePacked(walletUEA)
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
        uint256 boundAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                canonicalUEA,
                keccak256(bytes(chainNs)),
                keccak256(bytes(chainId)),
                registryAddr,
                boundAgentId,
                nonce,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
    }

    function test_Bind_ERC1271_ValidSignature() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(walletUEA, bytes("dummy-sig"));

        vm.prank(walletUEA);
        registry.bind(
            IAgentRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                boundAgentId: 100,
                proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );

        uint256 walletAgentId = uint256(uint160(walletUEA));
        IAgentRegistry.BindEntry[] memory bindings = registry.getBindings(walletAgentId);
        assertEq(bindings.length, 1);
        assertEq(bindings[0].boundAgentId, 100);
    }

    function test_Bind_ERC1271_Reverts_ReturnsFalse() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        wallet.setRevert(true);
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(walletUEA, bytes("dummy-sig"));

        vm.prank(walletUEA);
        vm.expectRevert(InvalidBindSignature.selector);
        registry.bind(
            IAgentRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                boundAgentId: 100,
                proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );
    }

    function test_Bind_ERC1271_BadMagic_Reverts() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet();
        wallet.setReturnBadMagic(true);
        (address walletUEA,) = _setupERC1271Agent(wallet);

        address shadowReg = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory proofData = _erc1271ProofData(walletUEA, bytes("dummy-sig"));

        vm.prank(walletUEA);
        vm.expectRevert(InvalidBindSignature.selector);
        registry.bind(
            IAgentRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: shadowReg,
                boundAgentId: 100,
                proofType: IAgentRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: proofData,
                nonce: 1,
                deadline: deadline
            })
        );
    }
}
