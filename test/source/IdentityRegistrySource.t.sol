// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdentityRegistrySource} from "src/source/IdentityRegistrySource.sol";
import {
    InvalidGatewayAdapter,
    InvalidSettlementRegistry,
    PropagationDisabled,
    AlreadySynced,
    NotAgentOwner,
    InvalidUEARecipient
} from "src/source/SourceErrors.sol";
import {MockGatewayAdapter} from "./mocks/MockGateway.sol";
import {MockIdentityRegistry} from "./mocks/MockIdentityRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract IdentityRegistrySourceTest is Test {
    IdentityRegistrySource public plus;
    MockGatewayAdapter public gateway;
    MockIdentityRegistry public localReg;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public uea = makeAddr("uea");
    address public settlement = makeAddr("settlement");

    uint256 constant GATEWAY_FEE = 0.01 ether;
    string constant AGENT_URI = "ipfs://QmAgent123";

    function setUp() public {
        gateway = new MockGatewayAdapter(GATEWAY_FEE);
        localReg = new MockIdentityRegistry();

        IdentityRegistrySource impl = new IdentityRegistrySource();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IdentityRegistrySource.initialize,
                (owner, address(localReg), address(gateway), settlement)
            )
        );
        plus = IdentityRegistrySource(address(proxy));

        vm.prank(owner);
        plus.setPropagationEnabled(true);

        vm.deal(agent, 10 ether);
    }

    // ──────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────

    function test_Initialize_SetsState() public view {
        assertEq(plus.gatewayAdapter(), address(gateway));
        assertEq(plus.settlementRegistry(), settlement);
        assertEq(plus.localRegistry(), address(localReg));
        assertTrue(plus.propagationEnabled());
    }

    function test_Initialize_ZeroGateway_Reverts() public {
        IdentityRegistrySource impl = new IdentityRegistrySource();
        vm.expectRevert(InvalidGatewayAdapter.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IdentityRegistrySource.initialize,
                (owner, address(localReg), address(0), settlement)
            )
        );
    }

    function test_Initialize_ZeroSettlement_Reverts() public {
        IdentityRegistrySource impl = new IdentityRegistrySource();
        vm.expectRevert(InvalidSettlementRegistry.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                IdentityRegistrySource.initialize,
                (owner, address(localReg), address(gateway), address(0))
            )
        );
    }

    // ──────────────────────────────────────────────
    //  Registration with propagation
    // ──────────────────────────────────────────────

    function test_Register_PropagationEnabled_SendsGatewayCall() public {
        vm.prank(agent);
        uint256 agentId = plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");

        assertEq(agentId, 0);
        assertEq(gateway.callCount(), 1);

        MockGatewayAdapter.Call memory c = gateway.lastCall();
        assertEq(c.recipient, uea);
        assertEq(c.value, GATEWAY_FEE);
        assertEq(c.revertRecipient, agent);
    }

    function test_Register_EmitsCrossChainEvent() public {
        vm.expectEmit(true, true, true, true);
        emit IdentityRegistrySource.CrossChainRegistrationSent(0, agent, uea);

        vm.prank(agent);
        plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");
    }

    function test_Register_SetsSyncFlag() public {
        vm.prank(agent);
        uint256 agentId = plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");

        assertTrue(plus.isCrossChainSynced(agentId));
    }

    function test_Register_ZeroUEA_Reverts() public {
        vm.prank(agent);
        vm.expectRevert(InvalidUEARecipient.selector);
        plus.register{value: GATEWAY_FEE}(AGENT_URI, address(0), "");
    }

    function test_Register_PayloadContainsSettlementTarget() public {
        vm.prank(agent);
        plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");

        MockGatewayAdapter.Call memory c = gateway.lastCall();
        (address target,) = abi.decode(c.payload, (address, bytes));
        assertEq(target, settlement);
    }

    // ──────────────────────────────────────────────
    //  Registration without propagation
    // ──────────────────────────────────────────────

    function test_Register_PropagationDisabled_NoGatewayCall() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        vm.prank(agent);
        plus.register(AGENT_URI, uea, "");

        assertEq(gateway.callCount(), 0);
    }

    function test_RegisterLocalOnly_NoGatewayCall() public {
        vm.prank(agent);
        uint256 agentId = plus.registerLocalOnly(AGENT_URI);

        assertEq(agentId, 0);
        assertEq(gateway.callCount(), 0);
        assertFalse(plus.isCrossChainSynced(agentId));
    }

    // ──────────────────────────────────────────────
    //  Retry propagation
    // ──────────────────────────────────────────────

    function test_RetryPropagation_Success() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        vm.prank(agent);
        uint256 agentId = plus.registerLocalOnly(AGENT_URI);

        assertFalse(plus.isCrossChainSynced(agentId));

        vm.prank(owner);
        plus.setPropagationEnabled(true);

        vm.prank(agent);
        plus.retryPropagation{value: GATEWAY_FEE}(agentId, uea, "");

        assertTrue(plus.isCrossChainSynced(agentId));
        assertEq(gateway.callCount(), 1);
    }

    function test_RetryPropagation_NotOwner_Reverts() public {
        vm.prank(agent);
        plus.registerLocalOnly(AGENT_URI);

        address other = makeAddr("other");
        vm.deal(other, 1 ether);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(NotAgentOwner.selector, 0));
        plus.retryPropagation{value: GATEWAY_FEE}(0, uea, "");
    }

    function test_RetryPropagation_AlreadySynced_Reverts() public {
        vm.prank(agent);
        uint256 agentId = plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(AlreadySynced.selector, agentId));
        plus.retryPropagation{value: GATEWAY_FEE}(agentId, uea, "");
    }

    function test_RetryPropagation_Disabled_Reverts() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        vm.prank(agent);
        plus.registerLocalOnly(AGENT_URI);

        vm.prank(agent);
        vm.expectRevert(PropagationDisabled.selector);
        plus.retryPropagation{value: GATEWAY_FEE}(0, uea, "");
    }

    // ──────────────────────────────────────────────
    //  Pause
    // ──────────────────────────────────────────────

    function test_Register_WhenPaused_Reverts() public {
        vm.prank(owner);
        plus.pause();

        vm.prank(agent);
        vm.expectRevert();
        plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");
    }

    function test_RegisterLocalOnly_WhenPaused_Reverts() public {
        vm.prank(owner);
        plus.pause();

        vm.prank(agent);
        vm.expectRevert();
        plus.registerLocalOnly(AGENT_URI);
    }

    // ──────────────────────────────────────────────
    //  Admin
    // ──────────────────────────────────────────────

    function test_SetGatewayAdapter_OnlyOwner() public {
        address newAdapter = makeAddr("newAdapter");

        vm.prank(owner);
        plus.setGatewayAdapter(newAdapter);
        assertEq(plus.gatewayAdapter(), newAdapter);
    }

    function test_SetGatewayAdapter_NonOwner_Reverts() public {
        vm.prank(agent);
        vm.expectRevert();
        plus.setGatewayAdapter(makeAddr("x"));
    }

    function test_SetGatewayAdapter_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(InvalidGatewayAdapter.selector);
        plus.setGatewayAdapter(address(0));
    }

    function test_SetSettlementRegistry_OnlyOwner() public {
        address newReg = makeAddr("newSettlement");

        vm.prank(owner);
        plus.setSettlementRegistry(newReg);
        assertEq(plus.settlementRegistry(), newReg);
    }

    function test_SetSettlementRegistry_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(InvalidSettlementRegistry.selector);
        plus.setSettlementRegistry(address(0));
    }

    function test_SetPropagationEnabled_Toggle() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);
        assertFalse(plus.propagationEnabled());

        vm.prank(owner);
        plus.setPropagationEnabled(true);
        assertTrue(plus.propagationEnabled());
    }

    function test_EstimateRegistrationFee() public view {
        assertEq(plus.estimateRegistrationFee(), GATEWAY_FEE);
    }

    // ──────────────────────────────────────────────
    //  Gateway revert → atomic rollback
    // ──────────────────────────────────────────────

    function test_Register_GatewayReverts_EntireTxReverts() public {
        gateway.setShouldRevert(true);

        vm.prank(agent);
        vm.expectRevert("gateway reverted");
        plus.register{value: GATEWAY_FEE}(AGENT_URI, uea, "");
    }
}
