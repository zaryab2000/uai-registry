// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReputationRegistrySource} from "src/source/ReputationRegistrySource.sol";
import {
    InvalidGatewayAdapter,
    InvalidSettlementRegistry,
    PropagationDisabled,
    InvalidBatchThreshold
} from "src/source/SourceErrors.sol";
import {MockGatewayAdapter} from "./mocks/MockGateway.sol";
import {MockReputationRegistry} from "./mocks/MockReputationRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ReputationRegistrySourceTest is Test {
    ReputationRegistrySource public plus;
    MockGatewayAdapter public gateway;
    MockReputationRegistry public localReg;

    address public owner = makeAddr("owner");
    address public client = makeAddr("client");
    address public settlement = makeAddr("settlement");

    uint256 constant GATEWAY_FEE = 0.01 ether;
    uint256 constant AGENT_ID = 42;

    // Feedback defaults
    int128 constant FB_VALUE = 85;
    uint8 constant FB_DECIMALS = 2;
    string constant TAG1 = "quality";
    string constant TAG2 = "speed";
    string constant ENDPOINT = "https://agent.example";
    string constant FEEDBACK_URI = "ipfs://QmFeedback";
    bytes32 constant FEEDBACK_HASH = keccak256("feedback");

    function setUp() public {
        gateway = new MockGatewayAdapter(GATEWAY_FEE);
        localReg = new MockReputationRegistry();

        ReputationRegistrySource impl = new ReputationRegistrySource();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ReputationRegistrySource.initialize,
                (owner, address(localReg), address(gateway), settlement)
            )
        );
        plus = ReputationRegistrySource(address(proxy));

        vm.prank(owner);
        plus.setPropagationEnabled(true);

        vm.deal(client, 10 ether);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _giveFeedback(
        uint256 val
    ) internal {
        vm.prank(client);
        plus.giveFeedback(
            AGENT_ID,
            int128(int256(val)),
            FB_DECIMALS,
            TAG1,
            TAG2,
            ENDPOINT,
            FEEDBACK_URI,
            FEEDBACK_HASH
        );
    }

    function _giveFeedbackWithFee(
        uint256 val
    ) internal {
        vm.prank(client);
        plus.giveFeedback{value: GATEWAY_FEE}(
            AGENT_ID,
            int128(int256(val)),
            FB_DECIMALS,
            TAG1,
            TAG2,
            ENDPOINT,
            FEEDBACK_URI,
            FEEDBACK_HASH
        );
    }

    // ──────────────────────────────────────────────
    //  Initialization
    // ──────────────────────────────────────────────

    function test_Initialize_SetsState() public view {
        assertEq(plus.gatewayAdapter(), address(gateway));
        assertEq(plus.settlementRegistry(), settlement);
        assertEq(plus.localRegistry(), address(localReg));
        assertTrue(plus.propagationEnabled());
        assertEq(plus.batchThreshold(), 10);
        assertEq(plus.maxPropagationInterval(), 1 hours);
    }

    function test_Initialize_ZeroGateway_Reverts() public {
        ReputationRegistrySource impl = new ReputationRegistrySource();
        vm.expectRevert(InvalidGatewayAdapter.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ReputationRegistrySource.initialize,
                (owner, address(localReg), address(0), settlement)
            )
        );
    }

    function test_Initialize_ZeroSettlement_Reverts() public {
        ReputationRegistrySource impl = new ReputationRegistrySource();
        vm.expectRevert(InvalidSettlementRegistry.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ReputationRegistrySource.initialize,
                (owner, address(localReg), address(gateway), address(0))
            )
        );
    }

    function test_Initialize_ZeroLocalRegistry_Reverts() public {
        ReputationRegistrySource impl = new ReputationRegistrySource();
        vm.expectRevert("zero local registry");
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ReputationRegistrySource.initialize,
                (owner, address(0), address(gateway), settlement)
            )
        );
    }

    function test_Initialize_DefaultsDisabled() public {
        ReputationRegistrySource impl = new ReputationRegistrySource();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                ReputationRegistrySource.initialize,
                (owner, address(localReg), address(gateway), settlement)
            )
        );
        ReputationRegistrySource fresh = ReputationRegistrySource(address(proxy));
        assertFalse(fresh.propagationEnabled());
    }

    // ──────────────────────────────────────────────
    //  giveFeedback — local only (no propagation)
    // ──────────────────────────────────────────────

    function test_GiveFeedback_DisabledPropagation_NoGateway() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        _giveFeedback(80);

        assertEq(gateway.callCount(), 0);
    }

    // ──────────────────────────────────────────────
    //  giveFeedback — first feedback triggers
    //  propagation (lastPropagated == 0)
    // ──────────────────────────────────────────────

    function test_GiveFeedback_FirstFeedback_Propagates() public {
        _giveFeedbackWithFee(80);

        assertEq(gateway.callCount(), 1);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 0);
        assertGt(plus.lastPropagated(AGENT_ID), 0);
    }

    function test_GiveFeedback_FirstFeedback_EmitsEvent() public {
        vm.expectEmit(true, false, false, true);
        emit ReputationRegistrySource.ReputationPropagated(AGENT_ID, 1, 80, block.number);

        _giveFeedbackWithFee(80);
    }

    // ──────────────────────────────────────────────
    //  Batch threshold triggering
    // ──────────────────────────────────────────────

    function test_GiveFeedback_BatchThreshold_Propagates() public {
        // First feedback triggers (lastPropagated == 0)
        _giveFeedbackWithFee(80);
        assertEq(gateway.callCount(), 1);

        // Next 9 feedbacks without fee — no propagation
        for (uint256 i = 1; i < 10; i++) {
            _giveFeedback(80);
        }
        assertEq(gateway.callCount(), 1);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 9);

        // 10th feedback with fee — triggers batch
        _giveFeedbackWithFee(80);
        assertEq(gateway.callCount(), 2);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 0);
    }

    function test_GiveFeedback_UnderThreshold_NoPropagation() public {
        // First feedback triggers
        _giveFeedbackWithFee(80);

        // 5 more feedbacks — under threshold
        for (uint256 i = 0; i < 5; i++) {
            _giveFeedbackWithFee(80);
        }
        // Only the first triggered, rest are under threshold
        // and within time interval
        assertEq(gateway.callCount(), 1);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 5);
    }

    // ──────────────────────────────────────────────
    //  Time-interval triggering
    // ──────────────────────────────────────────────

    function test_GiveFeedback_TimeInterval_Propagates() public {
        // First feedback triggers
        _giveFeedbackWithFee(80);
        assertEq(gateway.callCount(), 1);

        // Add feedback without fee
        _giveFeedback(80);
        assertEq(gateway.callCount(), 1);

        // Advance past maxPropagationInterval (1 hour)
        vm.warp(block.timestamp + 1 hours + 1);

        // Next feedback with fee should trigger
        _giveFeedbackWithFee(80);
        assertEq(gateway.callCount(), 2);
    }

    // ──────────────────────────────────────────────
    //  No fee → no propagation even when due
    // ──────────────────────────────────────────────

    function test_GiveFeedback_NoFee_NoPropagation() public {
        // First feedback without fee — condition met
        // (lastPropagated==0) but msg.value==0
        _giveFeedback(80);
        assertEq(gateway.callCount(), 0);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 1);
    }

    // ──────────────────────────────────────────────
    //  Manual propagateReputation
    // ──────────────────────────────────────────────

    function test_PropagateReputation_Success() public {
        localReg.setMockSummary(AGENT_ID, 5, 90, 2);

        vm.prank(client);
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);

        assertEq(gateway.callCount(), 1);
    }

    function test_PropagateReputation_Disabled_Reverts() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        vm.prank(client);
        vm.expectRevert(PropagationDisabled.selector);
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);
    }

    function test_PropagateReputation_PayloadContainsSettlement() public {
        localReg.setMockSummary(AGENT_ID, 5, 90, 2);

        vm.prank(client);
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);

        MockGatewayAdapter.Call memory c = gateway.lastCall();
        (address target,) = abi.decode(c.payload, (address, bytes));
        assertEq(target, settlement);
    }

    function test_PropagateReputation_ResetsCountAndTimestamp() public {
        // Build up some pending count
        _giveFeedbackWithFee(80); // triggers (first)
        _giveFeedback(80);
        _giveFeedback(80);
        assertEq(plus.pendingFeedbackCount(AGENT_ID), 2);

        // Manual propagate resets
        vm.prank(client);
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);

        assertEq(plus.pendingFeedbackCount(AGENT_ID), 0);
        assertGt(plus.lastPropagated(AGENT_ID), 0);
    }

    // ──────────────────────────────────────────────
    //  Canonical ID management
    // ──────────────────────────────────────────────

    function test_SetCanonicalId_Owner() public {
        vm.prank(owner);
        plus.setCanonicalId(AGENT_ID, 999);
        assertEq(plus.canonicalId(AGENT_ID), 999);
    }

    function test_SetCanonicalId_NonOwner_Reverts() public {
        vm.prank(client);
        vm.expectRevert();
        plus.setCanonicalId(AGENT_ID, 999);
    }

    function test_BatchSetCanonicalIds() public {
        uint256[] memory locals = new uint256[](3);
        uint256[] memory canonicals = new uint256[](3);
        locals[0] = 1;
        locals[1] = 2;
        locals[2] = 3;
        canonicals[0] = 100;
        canonicals[1] = 200;
        canonicals[2] = 300;

        vm.prank(owner);
        plus.batchSetCanonicalIds(locals, canonicals);

        assertEq(plus.canonicalId(1), 100);
        assertEq(plus.canonicalId(2), 200);
        assertEq(plus.canonicalId(3), 300);
    }

    function test_BatchSetCanonicalIds_LengthMismatch_Reverts() public {
        uint256[] memory locals = new uint256[](2);
        uint256[] memory canonicals = new uint256[](3);

        vm.prank(owner);
        vm.expectRevert("length mismatch");
        plus.batchSetCanonicalIds(locals, canonicals);
    }

    // ──────────────────────────────────────────────
    //  Propagated payload uses canonical ID
    // ──────────────────────────────────────────────

    function test_PropagateReputation_UsesCanonicalId() public {
        vm.prank(owner);
        plus.setCanonicalId(AGENT_ID, 777);

        localReg.setMockSummary(AGENT_ID, 5, 90, 2);

        vm.prank(client);
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);

        MockGatewayAdapter.Call memory c = gateway.lastCall();
        (, bytes memory innerPayload) = abi.decode(c.payload, (address, bytes));

        // The first argument in submitReputation is the
        // canonical ID — it's inside a struct ABI encoding.
        // Skip 4 bytes selector, then first 32 bytes = ID.
        uint256 encodedId;
        assembly {
            encodedId := mload(add(innerPayload, 36))
        }
        assertEq(encodedId, 777);
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

    function test_SetGatewayAdapter_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(InvalidGatewayAdapter.selector);
        plus.setGatewayAdapter(address(0));
    }

    function test_SetGatewayAdapter_NonOwner_Reverts() public {
        vm.prank(client);
        vm.expectRevert();
        plus.setGatewayAdapter(makeAddr("x"));
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

    function test_SetLocalRegistry_OnlyOwner() public {
        address newReg = makeAddr("newLocal");

        vm.prank(owner);
        plus.setLocalRegistry(newReg);
        assertEq(plus.localRegistry(), newReg);
    }

    function test_SetLocalRegistry_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert("zero local registry");
        plus.setLocalRegistry(address(0));
    }

    function test_SetPropagationEnabled_Toggle() public {
        vm.prank(owner);
        plus.setPropagationEnabled(false);
        assertFalse(plus.propagationEnabled());

        vm.prank(owner);
        plus.setPropagationEnabled(true);
        assertTrue(plus.propagationEnabled());
    }

    function test_SetBatchThreshold_OnlyOwner() public {
        vm.prank(owner);
        plus.setBatchThreshold(20);
        assertEq(plus.batchThreshold(), 20);
    }

    function test_SetBatchThreshold_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(InvalidBatchThreshold.selector);
        plus.setBatchThreshold(0);
    }

    function test_SetMaxPropagationInterval() public {
        vm.prank(owner);
        plus.setMaxPropagationInterval(2 hours);
        assertEq(plus.maxPropagationInterval(), 2 hours);
    }

    function test_EstimatePropagationFee() public view {
        assertEq(plus.estimatePropagationFee(), GATEWAY_FEE);
    }

    // ──────────────────────────────────────────────
    //  Pause
    // ──────────────────────────────────────────────

    function test_GiveFeedback_WhenPaused_Reverts() public {
        vm.prank(owner);
        plus.pause();

        vm.prank(client);
        vm.expectRevert();
        plus.giveFeedback(
            AGENT_ID, FB_VALUE, FB_DECIMALS, TAG1, TAG2, ENDPOINT, FEEDBACK_URI, FEEDBACK_HASH
        );
    }

    function test_Unpause_Resumes() public {
        vm.prank(owner);
        plus.pause();

        vm.prank(owner);
        plus.unpause();

        // Should work again (no propagation, no fee)
        vm.prank(owner);
        plus.setPropagationEnabled(false);

        _giveFeedback(80);
        // No revert = success
    }

    // ──────────────────────────────────────────────
    //  Gateway revert → atomic rollback
    // ──────────────────────────────────────────────

    function test_PropagateReputation_GatewayReverts() public {
        gateway.setShouldRevert(true);

        vm.prank(client);
        vm.expectRevert("gateway reverted");
        plus.propagateReputation{value: GATEWAY_FEE}(AGENT_ID);
    }

    // ──────────────────────────────────────────────
    //  Local registry revert → atomic rollback
    // ──────────────────────────────────────────────

    function test_GiveFeedback_LocalReverts_EntireTxReverts() public {
        localReg.setShouldRevert(true);

        vm.prank(client);
        vm.expectRevert("feedback reverted");
        plus.giveFeedback(
            AGENT_ID, FB_VALUE, FB_DECIMALS, TAG1, TAG2, ENDPOINT, FEEDBACK_URI, FEEDBACK_HASH
        );
    }
}
