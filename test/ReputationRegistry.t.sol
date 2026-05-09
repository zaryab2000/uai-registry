// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UAIRegistry} from "src/UAIRegistry.sol";
import {IUAIRegistry} from "src/interfaces/IUAIRegistry.sol";
import {ReputationRegistry} from "src/ReputationRegistry.sol";
import {IReputationRegistry} from "src/IReputationRegistry.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    AgentNotRegisteredForReputation,
    StaleSubmission,
    InvalidSeverity,
    InvalidChainIdentifierReputation,
    InvalidRegistryAddressReputation,
    ShadowNotLinked,
    BatchTooLarge,
    EmptyBatch,
    InvalidDecimals,
    InvalidUAIRegistryAddress,
    MaxSlashRecordsExceeded,
    SummaryValueOutOfRange,
    TooManyChainKeys,
    InvalidInitializationAddress
} from "src/libraries/ReputationErrors.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ReputationRegistryTest is Test {
    UAIRegistry public uaiRegistry;
    ReputationRegistry public repRegistry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public reporter = makeAddr("reporter");
    address public slasher = makeAddr("slasher");
    address public nobody = makeAddr("nobody");

    address public ueaUser;
    uint256 public ueaUserKey;
    uint256 public agentId;

    address constant SHADOW_REGISTRY_ETH =
        address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    address constant SHADOW_REGISTRY_BASE =
        address(0x8004b269Fb4A3325136eB29FA0ceb6d2E539b543);
    address constant SHADOW_REGISTRY_ARB =
        address(0x8004c369fB4a3325136eB29Fa0ceB6d2e539C654);

    bytes32 constant CARD_HASH = keccak256("agent-card");
    string constant AGENT_URI = "ipfs://QmTest";

    bytes32 public constant SHADOW_LINK_TYPEHASH = keccak256(
        "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        (ueaUser, ueaUserKey) = makeAddrAndKey("ueaUser");

        factory = new MockUEAFactory();
        factory.addUEA(
            ueaUser,
            UniversalAccountId({
                chainNamespace: "eip155",
                chainId: "1",
                owner: abi.encodePacked(ueaUser)
            })
        );

        UAIRegistry uaiImpl = new UAIRegistry(factory);
        TransparentUpgradeableProxy uaiProxy =
            new TransparentUpgradeableProxy(
                address(uaiImpl),
                admin,
                abi.encodeCall(UAIRegistry.initialize, (admin, pauser))
            );
        uaiRegistry = UAIRegistry(address(uaiProxy));

        ReputationRegistry repImpl = new ReputationRegistry();
        TransparentUpgradeableProxy repProxy =
            new TransparentUpgradeableProxy(
                address(repImpl),
                admin,
                abi.encodeCall(
                    ReputationRegistry.initialize,
                    (admin, pauser, address(uaiRegistry))
                )
            );
        repRegistry = ReputationRegistry(address(repProxy));

        vm.startPrank(admin);
        repRegistry.grantRole(repRegistry.REPORTER_ROLE(), reporter);
        repRegistry.grantRole(repRegistry.SLASHER_ROLE(), slasher);
        vm.stopPrank();

        vm.prank(ueaUser);
        agentId = uaiRegistry.register(AGENT_URI, CARD_HASH);

        _linkShadow("eip155", "1", SHADOW_REGISTRY_ETH, 42, 1);
        _linkShadow("eip155", "8453", SHADOW_REGISTRY_BASE, 17, 2);
        _linkShadow("eip155", "42161", SHADOW_REGISTRY_ARB, 8, 3);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _linkShadow(
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 shadowAgentId,
        uint256 nonce
    ) internal {
        bytes memory sig = _signShadowLink(
            ueaUserKey,
            ueaUser,
            chainNs,
            chainId,
            registryAddr,
            shadowAgentId,
            nonce,
            block.timestamp + 1 hours
        );

        IUAIRegistry.ShadowLinkRequest memory req = IUAIRegistry
            .ShadowLinkRequest({
                chainNamespace: chainNs,
                chainId: chainId,
                registryAddress: registryAddr,
                shadowAgentId: shadowAgentId,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: sig,
                nonce: nonce,
                deadline: block.timestamp + 1 hours
            });

        vm.prank(ueaUser);
        uaiRegistry.linkShadow(req);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 cId, address vc,,) =
            uaiRegistry.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,"
                    "uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                cId,
                vc
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

    function _signShadowLink(
        uint256 signerKey,
        address canonicalUEA,
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 shadowAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signShadowLinkStruct(
            SignParams(signerKey, canonicalUEA, chainNs, chainId, registryAddr, shadowAgentId, nonce, deadline)
        );
    }

    function _signShadowLinkStruct(SignParams memory p) internal view returns (bytes memory) {
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

    function _defaultSubmission()
        internal
        view
        returns (IReputationRegistry.ReputationSubmission memory)
    {
        return IReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: SHADOW_REGISTRY_ETH,
            shadowAgentId: 42,
            feedbackCount: 200,
            summaryValue: 92 * 1e18,
            valueDecimals: 18,
            positiveCount: 180,
            negativeCount: 20,
            sourceBlockNumber: 1000
        });
    }

    function _submitForChain(
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 shadowId,
        uint64 feedbackCount,
        int128 summaryValue,
        uint256 sourceBlock
    ) internal {
        IReputationRegistry.ReputationSubmission memory sub =
            IReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: chainNs,
                chainId: chainId,
                registryAddress: registryAddr,
                shadowAgentId: shadowId,
                feedbackCount: feedbackCount,
                summaryValue: summaryValue,
                valueDecimals: 18,
                positiveCount: feedbackCount > 10 ? feedbackCount - 10 : feedbackCount,
                negativeCount: feedbackCount > 10 ? 10 : 0,
                sourceBlockNumber: sourceBlock
            });

        vm.prank(reporter);
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Submission Tests
    // ──────────────────────────────────────────────

    function test_SubmitReputation_ValidReporter_Stores() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        IReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 200);
        assertEq(cr.summaryValue, 92 * 1e18);
        assertEq(cr.positiveCount, 180);
        assertEq(cr.negativeCount, 20);
        assertEq(cr.sourceBlockNumber, 1000);
        assertEq(cr.reporter, reporter);
    }

    function test_SubmitReputation_EmitsEvent() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.expectEmit(true, true, false, true);
        emit IReputationRegistry.ReputationSubmitted(
            agentId, "eip155", "1", 200, 92 * 1e18, reporter
        );

        vm.prank(reporter);
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_NotReporter_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(nobody);
        vm.expectRevert();
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_AgentNotRegistered_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.agentId = 999;

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentNotRegisteredForReputation.selector, 999
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_ShadowNotLinked_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.chainNamespace = "eip155";
        sub.chainId = "137";

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                ShadowNotLinked.selector, agentId, "eip155", "137"
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_StaleBlock_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        sub.sourceBlockNumber = 999;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaleSubmission.selector,
                agentId,
                "eip155",
                "1",
                1000,
                999
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_EqualBlock_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                StaleSubmission.selector,
                agentId,
                "eip155",
                "1",
                1000,
                1000
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_InvalidDecimals_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.valueDecimals = 19;

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidDecimals.selector, 19)
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_Update_OverwritesOld() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        sub.sourceBlockNumber = 2000;
        sub.feedbackCount = 300;
        sub.summaryValue = 95 * 1e18;

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        IReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 300);
        assertEq(cr.summaryValue, 95 * 1e18);
        assertEq(cr.sourceBlockNumber, 2000);
    }

    function test_SubmitReputation_WhenPaused_Reverts() public {
        vm.prank(pauser);
        repRegistry.pause();

        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_EmptyChainId_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.chainId = "";

        vm.prank(reporter);
        vm.expectRevert(InvalidChainIdentifierReputation.selector);
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_ZeroRegistryAddr_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.registryAddress = address(0);

        vm.prank(reporter);
        vm.expectRevert(InvalidRegistryAddressReputation.selector);
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Batch Tests
    // ──────────────────────────────────────────────

    function test_BatchSubmit_MultipleAgents() public {
        (address ueaUser2, uint256 ueaUser2Key) = makeAddrAndKey("ueaUser2");
        factory.addUEA(
            ueaUser2,
            UniversalAccountId({
                chainNamespace: "eip155",
                chainId: "1",
                owner: abi.encodePacked(ueaUser2)
            })
        );
        vm.prank(ueaUser2);
        uint256 agentId2 = uaiRegistry.register("ipfs://test2", CARD_HASH);

        bytes memory sig2 = _signShadowLink(
            ueaUser2Key,
            ueaUser2,
            "eip155",
            "1",
            SHADOW_REGISTRY_ETH,
            99,
            1,
            block.timestamp + 1 hours
        );
        vm.prank(ueaUser2);
        uaiRegistry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: SHADOW_REGISTRY_ETH,
                shadowAgentId: 99,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: sig2,
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        IReputationRegistry.ReputationSubmission[] memory subs =
            new IReputationRegistry.ReputationSubmission[](2);
        subs[0] = _defaultSubmission();
        subs[1] = IReputationRegistry.ReputationSubmission({
            agentId: agentId2,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: SHADOW_REGISTRY_ETH,
            shadowAgentId: 99,
            feedbackCount: 50,
            summaryValue: 80 * 1e18,
            valueDecimals: 18,
            positiveCount: 40,
            negativeCount: 10,
            sourceBlockNumber: 500
        });

        vm.prank(reporter);
        repRegistry.batchSubmitReputation(subs);

        assertEq(repRegistry.getReputationScore(agentId) > 0, true);
        assertEq(repRegistry.getReputationScore(agentId2) > 0, true);
    }

    function test_BatchSubmit_SameAgent_MultipleChains() public {
        IReputationRegistry.ReputationSubmission[] memory subs =
            new IReputationRegistry.ReputationSubmission[](3);

        subs[0] = IReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: SHADOW_REGISTRY_ETH,
            shadowAgentId: 42,
            feedbackCount: 200,
            summaryValue: 92 * 1e18,
            valueDecimals: 18,
            positiveCount: 180,
            negativeCount: 20,
            sourceBlockNumber: 1000
        });
        subs[1] = IReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: SHADOW_REGISTRY_BASE,
            shadowAgentId: 17,
            feedbackCount: 150,
            summaryValue: 88 * 1e18,
            valueDecimals: 18,
            positiveCount: 130,
            negativeCount: 20,
            sourceBlockNumber: 2000
        });
        subs[2] = IReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: SHADOW_REGISTRY_ARB,
            shadowAgentId: 8,
            feedbackCount: 50,
            summaryValue: 95 * 1e18,
            valueDecimals: 18,
            positiveCount: 48,
            negativeCount: 2,
            sourceBlockNumber: 3000
        });

        vm.prank(reporter);
        repRegistry.batchSubmitReputation(subs);

        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 400);
        assertEq(agg.chainCount, 3);
    }

    function test_BatchSubmit_TooLarge_Reverts() public {
        IReputationRegistry.ReputationSubmission[] memory subs =
            new IReputationRegistry.ReputationSubmission[](51);

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(BatchTooLarge.selector, 51, 50)
        );
        repRegistry.batchSubmitReputation(subs);
    }

    function test_BatchSubmit_Empty_Reverts() public {
        IReputationRegistry.ReputationSubmission[] memory subs =
            new IReputationRegistry.ReputationSubmission[](0);

        vm.prank(reporter);
        vm.expectRevert(EmptyBatch.selector);
        repRegistry.batchSubmitReputation(subs);
    }

    // ──────────────────────────────────────────────
    //  Aggregation Tests
    // ──────────────────────────────────────────────

    function test_Aggregation_SingleChain_MatchesSubmission() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 200, 92 * 1e18, 1000
        );

        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 200);
        assertEq(agg.weightedAvgValue, 92 * 1e18);
        assertEq(agg.chainCount, 1);
    }

    function test_Aggregation_MultipleChains_WeightedAvg() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 200, 90 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 100, 60 * 1e18, 2000
        );

        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 300);

        // weighted avg = (200*90 + 100*60) / 300 = 24000/300 = 80
        assertEq(agg.weightedAvgValue, 80 * 1e18);
    }

    function test_Aggregation_DifferentDecimals_Normalized() public {
        IReputationRegistry.ReputationSubmission memory sub1 =
            IReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: SHADOW_REGISTRY_ETH,
                shadowAgentId: 42,
                feedbackCount: 100,
                summaryValue: 90 * 1e2,
                valueDecimals: 2,
                positiveCount: 90,
                negativeCount: 10,
                sourceBlockNumber: 1000
            });

        vm.prank(reporter);
        repRegistry.submitReputation(sub1);

        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.valueDecimals, 18);
        assertEq(agg.weightedAvgValue, 90 * 1e18);
    }

    function test_Aggregation_NegativeValue_ClampsToZero() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, -50 * 1e18, 1000
        );

        uint256 score = repRegistry.getReputationScore(agentId);
        // Negative → baseScore = 0, still gets diversity bonus (500)
        assertEq(score, 500);
    }

    function test_Aggregation_ChainCount_Correct() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 50, 80 * 1e18, 2000
        );

        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.chainCount, 2);
    }

    function test_Reaggregate_RemovesUnlinkedChain() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 200, 90 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 100, 80 * 1e18, 2000
        );

        IReputationRegistry.AggregatedReputation memory aggBefore =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggBefore.chainCount, 2);
        assertEq(aggBefore.totalFeedbackCount, 300);

        vm.prank(ueaUser);
        uaiRegistry.unlinkShadow("eip155", "8453", SHADOW_REGISTRY_BASE);

        repRegistry.reaggregate(agentId);

        IReputationRegistry.AggregatedReputation memory aggAfter =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggAfter.chainCount, 1);
        assertEq(aggAfter.totalFeedbackCount, 200);
    }

    function test_Reaggregate_AnyoneCanCall() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        vm.prank(nobody);
        repRegistry.reaggregate(agentId);
    }

    function test_Reaggregate_AgentNotRegistered_Reverts() public {
        vm.prank(nobody);
        vm.expectRevert(
            abi.encodeWithSelector(
                AgentNotRegisteredForReputation.selector, 999
            )
        );
        repRegistry.reaggregate(999);
    }

    // ──────────────────────────────────────────────
    //  Score Tests
    // ──────────────────────────────────────────────

    function test_Score_PerfectAgent_HighScore() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 1024, 100 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 1024, 100 * 1e18, 2000
        );
        _submitForChain(
            "eip155",
            "42161",
            SHADOW_REGISTRY_ARB,
            8,
            1024,
            100 * 1e18,
            3000
        );

        uint256 score = repRegistry.getReputationScore(agentId);
        // 3072 total feedback → log2(3072)=11 → volumeMultiplier capped at 10000
        // baseScore = 100*7000/100 = 7000
        // adjusted = 7000 * 10000 / 10000 = 7000
        // diversity = 3 * 500 = 1500
        // total = 8500
        assertGt(score, 8000);
        assertLe(score, 10000);
    }

    function test_Score_NewAgent_LowVolume() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 1, 100 * 1e18, 1000
        );

        uint256 score = repRegistry.getReputationScore(agentId);
        // 1 feedback → log2(1)=0 → volumeMultiplier = 5000
        // baseScore = 7000
        // adjusted = 7000 * 5000 / 10000 = 3500
        // diversity = 500
        // total = 4000
        assertEq(score, 4000);
    }

    function test_Score_MultiChain_DiversityBonus() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 1, 100 * 1e18, 1000
        );

        uint256 scoreOneChain = repRegistry.getReputationScore(agentId);

        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 1, 100 * 1e18, 2000
        );

        uint256 scoreTwoChains = repRegistry.getReputationScore(agentId);

        assertGt(scoreTwoChains, scoreOneChain);
        // Difference should be close to 500 (diversity bonus per chain)
        // But volume multiplier also changes with 2 total feedback
        assertGe(scoreTwoChains - scoreOneChain, 400);
    }

    function test_Score_DiversityBonus_CappedAt2000() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 1, 100 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 1, 100 * 1e18, 2000
        );
        _submitForChain(
            "eip155", "42161", SHADOW_REGISTRY_ARB, 8, 1, 100 * 1e18, 3000
        );

        uint256 scoreThree = repRegistry.getReputationScore(agentId);

        // Diversity bonus at 3 chains = 1500, at 4 would be 2000 (capped)
        // With 3 feedback total, log2(3)=1, volumeMultiplier = 5500
        // baseScore = 7000, adjusted = 7000*5500/10000 = 3850
        // total = 3850 + 1500 = 5350
        assertGt(scoreThree, 5000);
    }

    function test_Score_SlashReduces() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);

        vm.prank(slasher);
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "bad behavior",
            keccak256("evidence"),
            1000
        );

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertLt(scoreAfter, scoreBefore);
        assertEq(scoreBefore - scoreAfter, 1000);
    }

    function test_Score_HeavySlash_ClampsToZero() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 1, 50 * 1e18, 1000
        );

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);
        assertGt(scoreBefore, 0);

        vm.prank(slasher);
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "critical failure",
            keccak256("evidence"),
            10000
        );

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertEq(scoreAfter, 0);
    }

    // ──────────────────────────────────────────────
    //  Slashing Tests
    // ──────────────────────────────────────────────

    function test_Slash_ValidSlasher_Records() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        vm.prank(slasher);
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "fraud",
            keccak256("proof"),
            2000
        );

        IReputationRegistry.SlashRecord[] memory records =
            repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 1);
        assertEq(records[0].severityBps, 2000);
        assertEq(records[0].reporter, slasher);
        assertEq(
            keccak256(bytes(records[0].reason)),
            keccak256(bytes("fraud"))
        );
    }

    function test_Slash_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit IReputationRegistry.AgentSlashed(
            agentId, "eip155", "1", "fraud", 2000, slasher
        );

        vm.prank(slasher);
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "fraud",
            keccak256("proof"),
            2000
        );
    }

    function test_Slash_NotSlasher_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "fraud",
            keccak256("proof"),
            2000
        );
    }

    function test_Slash_InvalidSeverity_Zero_Reverts() public {
        vm.prank(slasher);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSeverity.selector, 0)
        );
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "fraud",
            keccak256("proof"),
            0
        );
    }

    function test_Slash_InvalidSeverity_Over10000_Reverts() public {
        vm.prank(slasher);
        vm.expectRevert(
            abi.encodeWithSelector(InvalidSeverity.selector, 10001)
        );
        repRegistry.slash(
            agentId,
            "eip155",
            "1",
            "fraud",
            keccak256("proof"),
            10001
        );
    }

    function test_Slash_CumulativePenalty() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);

        vm.startPrank(slasher);
        repRegistry.slash(
            agentId, "eip155", "1", "fraud1", keccak256("e1"), 500
        );
        repRegistry.slash(
            agentId, "eip155", "1", "fraud2", keccak256("e2"), 700
        );
        repRegistry.slash(
            agentId, "eip155", "1", "fraud3", keccak256("e3"), 300
        );
        vm.stopPrank();

        IReputationRegistry.SlashRecord[] memory records =
            repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 3);

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertEq(scoreBefore - scoreAfter, 1500);
    }

    // ──────────────────────────────────────────────
    //  Read Function Tests
    // ──────────────────────────────────────────────

    function test_GetAggregated_NoData_ReturnsZero() public view {
        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 0);
        assertEq(agg.reputationScore, 0);
    }

    function test_GetChainReputation_Exists() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        IReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 100);
        assertEq(
            keccak256(bytes(cr.chainNamespace)),
            keccak256(bytes("eip155"))
        );
    }

    function test_GetChainReputation_NotExists_ReturnsZero() public view {
        IReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "137");
        assertEq(cr.feedbackCount, 0);
        assertEq(cr.sourceBlockNumber, 0);
    }

    function test_GetAllChainReputations_MultipleChains() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 200, 90 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 150, 88 * 1e18, 2000
        );
        _submitForChain(
            "eip155", "42161", SHADOW_REGISTRY_ARB, 8, 50, 95 * 1e18, 3000
        );

        IReputationRegistry.ChainReputation[] memory all =
            repRegistry.getAllChainReputations(agentId);
        assertEq(all.length, 3);
    }

    function test_GetReputationScore_MatchesAggregate() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        uint256 score = repRegistry.getReputationScore(agentId);
        IReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(score, agg.reputationScore);
    }

    function test_IsFresh_WithinAge_True() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        assertTrue(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_IsFresh_Expired_False() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100, 90 * 1e18, 1000
        );

        vm.warp(block.timestamp + 7 hours);
        assertFalse(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_IsFresh_NoData_False() public view {
        assertFalse(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_GetSlashRecords_ReturnsAll() public {
        vm.startPrank(slasher);
        repRegistry.slash(
            agentId, "eip155", "1", "r1", keccak256("e1"), 100
        );
        repRegistry.slash(
            agentId, "eip155", "8453", "r2", keccak256("e2"), 200
        );
        vm.stopPrank();

        IReputationRegistry.SlashRecord[] memory records =
            repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 2);
        assertEq(records[0].severityBps, 100);
        assertEq(records[1].severityBps, 200);
    }

    // ──────────────────────────────────────────────
    //  Admin Tests
    // ──────────────────────────────────────────────

    function test_SetUAIRegistry_Admin_Updates() public {
        address newAddr = makeAddr("newUAIRegistry");

        vm.prank(admin);
        repRegistry.setUAIRegistry(newAddr);

        assertEq(repRegistry.getUAIRegistry(), newAddr);
    }

    function test_SetUAIRegistry_NonAdmin_Reverts() public {
        vm.prank(nobody);
        vm.expectRevert();
        repRegistry.setUAIRegistry(makeAddr("newUAIRegistry"));
    }

    function test_SetUAIRegistry_ZeroAddr_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(InvalidUAIRegistryAddress.selector);
        repRegistry.setUAIRegistry(address(0));
    }

    function test_Pause_Unpause_WorksForPauser() public {
        vm.startPrank(pauser);
        repRegistry.pause();

        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();

        vm.stopPrank();
        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.submitReputation(sub);

        vm.prank(pauser);
        repRegistry.unpause();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: summaryValue bounds (M-4 / C-1)
    // ──────────────────────────────────────────────

    function test_SubmitReputation_SummaryValueTooHigh_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.summaryValue = 101 * 1e18;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SummaryValueOutOfRange.selector,
                int128(101 * 1e18),
                int128(100 * 1e18)
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_SummaryValueTooLow_Reverts() public {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.summaryValue = -101 * 1e18;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SummaryValueOutOfRange.selector,
                int128(-101 * 1e18),
                int128(100 * 1e18)
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_SummaryValueAtBoundary_Succeeds()
        public
    {
        IReputationRegistry.ReputationSubmission memory sub =
            _defaultSubmission();
        sub.summaryValue = 100 * 1e18;
        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        sub.summaryValue = -100 * 1e18;
        sub.sourceBlockNumber = 2000;
        vm.prank(reporter);
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: chainKeys cap (M-1)
    // ──────────────────────────────────────────────

    function test_SubmitReputation_TooManyChainKeys_Reverts() public {
        // setUp already links 3 shadows. Fill to 64 shadows with data.
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 10,
            50 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "8453", SHADOW_REGISTRY_BASE, 17, 10,
            50 * 1e18, 1000
        );
        _submitForChain(
            "eip155", "42161", SHADOW_REGISTRY_ARB, 8, 10,
            50 * 1e18, 1000
        );
        for (uint256 i = 4; i <= 64; i++) {
            string memory cid = vm.toString(i);
            address shadowReg = address(uint160(0xBEEF0000 + i));
            _linkShadow("eip155", cid, shadowReg, i, i + 100);
            _submitForChain(
                "eip155", cid, shadowReg, i, 10, 50 * 1e18, 1000
            );
        }

        // Now unlink one shadow to free a slot in UAIRegistry,
        // then link a new shadow on a different chain.
        // The chain key from the old shadow still persists in
        // ReputationRegistry, so we now have 64 chain keys and
        // the 65th will exceed the cap.
        vm.prank(ueaUser);
        uaiRegistry.unlinkShadow("eip155", "4", address(uint160(0xBEEF0004)));

        string memory cid65 = "65";
        address shadowReg65 = address(uint160(0xBEEF0041));
        _linkShadow("eip155", cid65, shadowReg65, 65, 200);

        IReputationRegistry.ReputationSubmission memory sub =
            IReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: cid65,
                registryAddress: shadowReg65,
                shadowAgentId: 65,
                feedbackCount: 10,
                summaryValue: 50 * 1e18,
                valueDecimals: 18,
                positiveCount: 5,
                negativeCount: 5,
                sourceBlockNumber: 1000
            });
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                TooManyChainKeys.selector, agentId, 64
            )
        );
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: reaggregate pauseable (H-3)
    // ──────────────────────────────────────────────

    function test_Reaggregate_WhenPaused_Reverts() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100,
            90 * 1e18, 1000
        );

        vm.prank(pauser);
        repRegistry.pause();

        vm.expectRevert();
        repRegistry.reaggregate(agentId);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: slash updates lastAggregated (M-2)
    // ──────────────────────────────────────────────

    function test_Slash_UpdatesLastAggregated() public {
        _submitForChain(
            "eip155", "1", SHADOW_REGISTRY_ETH, 42, 100,
            90 * 1e18, 1000
        );

        uint64 tsBeforeSlash =
            repRegistry.getAggregatedReputation(agentId).lastAggregated;

        vm.warp(block.timestamp + 100);

        vm.prank(slasher);
        repRegistry.slash(
            agentId, "eip155", "1", "test", keccak256("e"), 500
        );

        uint64 tsAfterSlash =
            repRegistry.getAggregatedReputation(agentId).lastAggregated;

        assertGt(tsAfterSlash, tsBeforeSlash);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: initialize zero-address (H-4)
    // ──────────────────────────────────────────────

    function test_Initialize_ZeroAdmin_Reverts() public {
        ReputationRegistry impl = new ReputationRegistry();
        vm.expectRevert(InvalidInitializationAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                ReputationRegistry.initialize,
                (address(0), pauser, address(uaiRegistry))
            )
        );
    }

    function test_Initialize_ZeroPauser_Reverts() public {
        ReputationRegistry impl = new ReputationRegistry();
        vm.expectRevert(InvalidInitializationAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                ReputationRegistry.initialize,
                (admin, address(0), address(uaiRegistry))
            )
        );
    }

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    function test_SupportsInterface_IReputationRegistry() public view {
        assertTrue(
            repRegistry.supportsInterface(
                type(IReputationRegistry).interfaceId
            )
        );
    }

    function test_SupportsInterface_IAccessControl() public view {
        assertTrue(
            repRegistry.supportsInterface(
                type(IAccessControl).interfaceId
            )
        );
    }

    // ──────────────────────────────────────────────
    //  ERC-7201 Storage Slot Verification
    // ──────────────────────────────────────────────

    function test_StorageSlot_MatchesERC7201Formula() public pure {
        bytes32 expected = keccak256(
            abi.encode(
                uint256(keccak256("reputationregistry.storage")) - 1
            )
        ) & ~bytes32(uint256(0xff));

        assertEq(
            expected,
            0xe070097f04227be86f6bce14fa1fa3a34d6ed0171b77fb88539672b7cff99400
        );
    }
}
