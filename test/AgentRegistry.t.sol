// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentRegistry} from "src/AgentRegistry.sol";
import {IAgentRegistry} from "src/interfaces/IAgentRegistry.sol";
import "src/libraries/Errors.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

contract AgentRegistryTest is Test {
    AgentRegistry public registry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public ueaUser = makeAddr("ueaUser");

    string constant AGENT_URI = "ipfs://QmTest123";
    bytes32 constant CARD_HASH = keccak256("agent-card-content");

    function setUp() public {
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
    }

    // ──────────────────────────────────────────────
    //  Registration
    // ──────────────────────────────────────────────

    function test_Register_FirstTime_CreatesRecord() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertTrue(rec.registered);
        assertEq(rec.agentURI, AGENT_URI);
        assertEq(rec.agentCardHash, CARD_HASH);
        assertEq(rec.originChainNamespace, "eip155");
        assertEq(rec.originChainId, "1");
        assertEq(rec.ownerKey, abi.encodePacked(ueaUser));
        assertFalse(rec.nativeToPush);
    }

    function test_Register_FirstTime_EmitsRegistered() public {
        uint256 expectedId = uint256(uint160(ueaUser));

        vm.expectEmit(true, true, false, true);
        emit IAgentRegistry.Registered(
            expectedId, ueaUser, "eip155", "1", abi.encodePacked(ueaUser), AGENT_URI, CARD_HASH
        );

        vm.prank(ueaUser);
        registry.register(AGENT_URI, CARD_HASH);
    }

    function test_Register_Update_UpdatesURIAndHash() public {
        vm.startPrank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        string memory newURI = "ipfs://QmNewURI";
        bytes32 newHash = keccak256("new-card");
        registry.register(newURI, newHash);
        vm.stopPrank();

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertEq(rec.agentURI, newURI);
        assertEq(rec.agentCardHash, newHash);
        assertEq(rec.originChainNamespace, "eip155");
    }

    function test_Register_Update_EmitsEvents() public {
        vm.startPrank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        string memory newURI = "ipfs://QmUpdated";
        bytes32 newHash = keccak256("updated-card");

        vm.expectEmit(true, false, false, true);
        emit IAgentRegistry.AgentURIUpdated(agentId, newURI);
        vm.expectEmit(true, false, false, true);
        emit IAgentRegistry.AgentCardHashUpdated(agentId, newHash);

        registry.register(newURI, newHash);
        vm.stopPrank();
    }

    function test_Register_ZeroCardHash_Reverts() public {
        vm.prank(ueaUser);
        vm.expectRevert(AgentCardHashRequired.selector);
        registry.register(AGENT_URI, bytes32(0));
    }

    function test_Register_EmptyURI_Succeeds() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register("", CARD_HASH);
        assertEq(registry.tokenURI(agentId), "");
    }

    function test_Register_AgentIdDeterministic() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(agentId, uint256(uint160(ueaUser)));
    }

    function test_Register_OriginMetadataFromFactory() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertEq(rec.originChainNamespace, "eip155");
        assertEq(rec.originChainId, "1");
        assertEq(rec.ownerKey, abi.encodePacked(ueaUser));
    }

    function test_Register_NativePushAccount() public {
        address nativeUser = makeAddr("nativeUser");
        vm.prank(nativeUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertTrue(rec.nativeToPush);
        assertEq(rec.originChainNamespace, "push");
        assertEq(rec.originChainId, "42101");
    }

    function test_Register_WhenPaused_Reverts() public {
        vm.prank(pauser);
        registry.pause();

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.register(AGENT_URI, CARD_HASH);
    }

    // ──────────────────────────────────────────────
    //  setAgentURI / setAgentCardHash
    // ──────────────────────────────────────────────

    function test_SetAgentURI_Owner_Updates() public {
        vm.startPrank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        string memory newURI = "ipfs://QmUpdated";
        registry.setAgentURI(newURI);
        vm.stopPrank();

        assertEq(registry.tokenURI(agentId), newURI);
    }

    function test_SetAgentURI_NotRegistered_Reverts() public {
        address nobody = makeAddr("nobody");
        uint256 expectedId = uint256(uint160(nobody));

        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, expectedId));
        registry.setAgentURI("ipfs://test");
    }

    function test_SetAgentURI_EmitsEvent() public {
        vm.startPrank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        string memory newURI = "ipfs://QmUpdated";
        vm.expectEmit(true, false, false, true);
        emit IAgentRegistry.AgentURIUpdated(agentId, newURI);
        registry.setAgentURI(newURI);
        vm.stopPrank();
    }

    function test_SetAgentCardHash_Owner_Updates() public {
        vm.startPrank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        bytes32 newHash = keccak256("updated-card");
        registry.setAgentCardHash(newHash);
        vm.stopPrank();

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertEq(rec.agentCardHash, newHash);
    }

    function test_SetAgentCardHash_ZeroHash_Reverts() public {
        vm.startPrank(ueaUser);
        registry.register(AGENT_URI, CARD_HASH);

        vm.expectRevert(AgentCardHashRequired.selector);
        registry.setAgentCardHash(bytes32(0));
        vm.stopPrank();
    }

    function test_SetAgentCardHash_WhenPaused_Reverts() public {
        vm.prank(ueaUser);
        registry.register(AGENT_URI, CARD_HASH);

        vm.prank(pauser);
        registry.pause();

        vm.prank(ueaUser);
        vm.expectRevert();
        registry.setAgentCardHash(keccak256("new"));
    }

    // ──────────────────────────────────────────────
    //  ERC-721 read surface
    // ──────────────────────────────────────────────

    function test_OwnerOf_RegisteredAgent_ReturnsUEA() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(registry.ownerOf(agentId), ueaUser);
    }

    function test_OwnerOf_UnregisteredAgent_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, 999));
        registry.ownerOf(999);
    }

    function test_TokenURI_ReturnsStoredURI() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(registry.tokenURI(agentId), AGENT_URI);
    }

    function test_AgentURI_AliasesTokenURI() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(registry.agentURI(agentId), registry.tokenURI(agentId));
    }

    function test_CanonicalUEA_SameAsOwnerOf() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(registry.canonicalUEA(agentId), registry.ownerOf(agentId));
    }

    function test_AgentIdOfUEA_Registered_ReturnsId() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertEq(registry.agentIdOfUEA(ueaUser), agentId);
    }

    function test_AgentIdOfUEA_NotRegistered_ReturnsZero() public {
        address unknown = makeAddr("unknown");
        assertEq(registry.agentIdOfUEA(unknown), 0);
    }

    function test_IsRegistered_True() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);
        assertTrue(registry.isRegistered(agentId));
    }

    function test_IsRegistered_False() public view {
        assertFalse(registry.isRegistered(999));
    }

    function test_GetAgentRecord_ReturnsFullRecord() public {
        vm.prank(ueaUser);
        uint256 agentId = registry.register(AGENT_URI, CARD_HASH);

        IAgentRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertTrue(rec.registered);
        assertEq(rec.agentURI, AGENT_URI);
        assertEq(rec.agentCardHash, CARD_HASH);
        assertGt(rec.registeredAt, 0);
        assertEq(rec.originChainNamespace, "eip155");
        assertEq(rec.originChainId, "1");
    }

    // ──────────────────────────────────────────────
    //  ERC-721 transfer revert
    // ──────────────────────────────────────────────

    function test_TransferFrom_Reverts() public {
        vm.expectRevert(IdentityNotTransferable.selector);
        registry.transferFrom(ueaUser, admin, 1);
    }

    function test_SafeTransferFrom_Reverts() public {
        vm.expectRevert(IdentityNotTransferable.selector);
        registry.safeTransferFrom(ueaUser, admin, 1);
    }

    function test_SafeTransferFromWithData_Reverts() public {
        vm.expectRevert(IdentityNotTransferable.selector);
        registry.safeTransferFrom(ueaUser, admin, 1, "");
    }

    function test_Approve_Reverts() public {
        vm.expectRevert(IdentityNotTransferable.selector);
        registry.approve(admin, 1);
    }

    function test_SetApprovalForAll_Reverts() public {
        vm.expectRevert(IdentityNotTransferable.selector);
        registry.setApprovalForAll(admin, true);
    }

    // ──────────────────────────────────────────────
    //  Branch Coverage — Unregistered Agent Reads
    // ──────────────────────────────────────────────

    function test_SetAgentCardHash_NotRegistered_Reverts() public {
        address unregistered = makeAddr("unregistered");
        uint256 fakeId = uint256(uint160(unregistered));
        vm.prank(unregistered);
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, fakeId));
        registry.setAgentCardHash(keccak256("card"));
    }

    function test_TokenURI_NotRegistered_Reverts() public {
        uint256 fakeId = 12_345;
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, fakeId));
        registry.tokenURI(fakeId);
    }

    function test_AgentURI_NotRegistered_Reverts() public {
        uint256 fakeId = 12_345;
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, fakeId));
        registry.agentURI(fakeId);
    }

    function test_CanonicalUEA_NotRegistered_Reverts() public {
        uint256 fakeId = 12_345;
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegistered.selector, fakeId));
        registry.canonicalUEA(fakeId);
    }

    // ──────────────────────────────────────────────
    //  supportsInterface
    // ──────────────────────────────────────────────

    function test_SupportsInterface_IERC721() public view {
        assertTrue(registry.supportsInterface(type(IERC721).interfaceId));
    }

    function test_SupportsInterface_IERC165() public view {
        assertTrue(registry.supportsInterface(type(IERC165).interfaceId));
    }
}
