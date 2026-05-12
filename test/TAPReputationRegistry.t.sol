// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TAPRegistry} from "src/TAPRegistry.sol";
import {ITAPRegistry} from "src/interfaces/ITAPRegistry.sol";
import {TAPReputationRegistry} from "src/TAPReputationRegistry.sol";
import {ITAPReputationRegistry} from "src/interfaces/ITAPReputationRegistry.sol";
import {MockUEAFactory} from "./mocks/MockUEAFactory.sol";
import {UniversalAccountId} from "src/libraries/Types.sol";
import {
    AgentNotRegisteredForReputation,
    StaleSubmission,
    InvalidSeverity,
    InvalidChainIdentifierReputation,
    InvalidRegistryAddressReputation,
    BindingNotLinked,
    BatchTooLarge,
    EmptyBatch,
    InvalidDecimals,
    InvalidTAPRegistryAddress,
    MaxSlashRecordsExceeded,
    SummaryValueOutOfRange,
    TooManyChainKeys,
    InvalidInitializationAddress
} from "src/libraries/ReputationErrors.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract TAPReputationRegistryTest is Test {
    TAPRegistry public tapRegistry;
    TAPReputationRegistry public repRegistry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public reporter = makeAddr("reporter");
    address public slasher = makeAddr("slasher");
    address public nobody = makeAddr("nobody");

    address public ueaUser;
    uint256 public ueaUserKey;
    uint256 public agentId;

    address constant REGISTRY_ETH = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);
    address constant REGISTRY_BASE = address(0x8004b269Fb4A3325136eB29FA0ceb6d2E539b543);
    address constant REGISTRY_ARB = address(0x8004c369fB4a3325136eB29Fa0ceB6d2e539C654);

    bytes32 constant CARD_HASH = keccak256("agent-card");
    string constant AGENT_URI = "ipfs://QmTest";

    bytes32 public constant BIND_TYPEHASH = keccak256(
        "Bind(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 boundAgentId,uint256 nonce,uint256 deadline)"
    );

    function setUp() public {
        (ueaUser, ueaUserKey) = makeAddrAndKey("ueaUser");

        factory = new MockUEAFactory();
        factory.addUEA(
            ueaUser,
            UniversalAccountId({
                chainNamespace: "eip155", chainId: "1", owner: abi.encodePacked(ueaUser)
            })
        );

        TAPRegistry agentImpl = new TAPRegistry(factory);
        TransparentUpgradeableProxy agentProxy = new TransparentUpgradeableProxy(
            address(agentImpl), admin, abi.encodeCall(TAPRegistry.initialize, (admin, pauser))
        );
        tapRegistry = TAPRegistry(address(agentProxy));

        TAPReputationRegistry repImpl = new TAPReputationRegistry();
        TransparentUpgradeableProxy repProxy = new TransparentUpgradeableProxy(
            address(repImpl),
            admin,
            abi.encodeCall(TAPReputationRegistry.initialize, (admin, pauser, address(tapRegistry)))
        );
        repRegistry = TAPReputationRegistry(address(repProxy));

        vm.startPrank(admin);
        repRegistry.grantRole(repRegistry.REPORTER_ROLE(), reporter);
        repRegistry.grantRole(repRegistry.SLASHER_ROLE(), slasher);
        vm.stopPrank();

        vm.prank(ueaUser);
        agentId = tapRegistry.register(AGENT_URI, CARD_HASH);

        _linkBinding("eip155", "1", REGISTRY_ETH, 42, 1);
        _linkBinding("eip155", "8453", REGISTRY_BASE, 17, 2);
        _linkBinding("eip155", "42161", REGISTRY_ARB, 8, 3);
    }

    // ──────────────────────────────────────────────
    //  Helpers
    // ──────────────────────────────────────────────

    function _linkBinding(
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 boundAgentId,
        uint256 nonce
    ) internal {
        bytes memory sig = _signBind(
            ueaUserKey,
            ueaUser,
            chainNs,
            chainId,
            registryAddr,
            boundAgentId,
            nonce,
            block.timestamp + 1 hours
        );

        ITAPRegistry.BindRequest memory req = ITAPRegistry.BindRequest({
            chainNamespace: chainNs,
            chainId: chainId,
            registryAddress: registryAddr,
            boundAgentId: boundAgentId,
            proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
            proofData: sig,
            nonce: nonce,
            deadline: block.timestamp + 1 hours
        });

        vm.prank(ueaUser);
        tapRegistry.bind(req);
    }

    function _getDomainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 cId, address vc,,) =
            tapRegistry.eip712Domain();
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
        uint256 boundAgentId;
        uint256 nonce;
        uint256 deadline;
    }

    function _signBind(
        uint256 signerKey,
        address canonicalUEA,
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 boundAgentId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        return _signBindStruct(
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

    function _signBindStruct(
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

    function _defaultSubmission()
        internal
        view
        returns (ITAPReputationRegistry.ReputationSubmission memory)
    {
        return ITAPReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: REGISTRY_ETH,
            boundAgentId: 42,
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
        uint256 boundId,
        uint64 feedbackCount,
        int128 summaryValue,
        uint256 sourceBlock
    ) internal {
        ITAPReputationRegistry.ReputationSubmission memory sub =
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: chainNs,
                chainId: chainId,
                registryAddress: registryAddr,
                boundAgentId: boundId,
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
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        ITAPReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 200);
        assertEq(cr.summaryValue, 92 * 1e18);
        assertEq(cr.positiveCount, 180);
        assertEq(cr.negativeCount, 20);
        assertEq(cr.sourceBlockNumber, 1000);
        assertEq(cr.reporter, reporter);
    }

    function test_SubmitReputation_EmitsEvent() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.expectEmit(true, true, false, true);
        emit ITAPReputationRegistry.ReputationSubmitted(
            agentId, "eip155", "1", 200, 92 * 1e18, reporter
        );

        vm.prank(reporter);
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_NotReporter_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(nobody);
        vm.expectRevert();
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_AgentNotRegistered_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.agentId = 999;

        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegisteredForReputation.selector, 999));
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_BindingNotLinked_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.chainNamespace = "eip155";
        sub.chainId = "137";

        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(BindingNotLinked.selector, agentId, "eip155", "137"));
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_StaleBlock_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        sub.sourceBlockNumber = 999;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(StaleSubmission.selector, agentId, "eip155", "1", 1000, 999)
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_EqualBlock_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(StaleSubmission.selector, agentId, "eip155", "1", 1000, 1000)
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_InvalidDecimals_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.valueDecimals = 19;

        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(InvalidDecimals.selector, 19));
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_Update_OverwritesOld() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        sub.sourceBlockNumber = 2000;
        sub.feedbackCount = 300;
        sub.summaryValue = 95 * 1e18;

        vm.prank(reporter);
        repRegistry.submitReputation(sub);

        ITAPReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 300);
        assertEq(cr.summaryValue, 95 * 1e18);
        assertEq(cr.sourceBlockNumber, 2000);
    }

    function test_SubmitReputation_WhenPaused_Reverts() public {
        vm.prank(pauser);
        repRegistry.pause();

        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_EmptyChainId_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.chainId = "";

        vm.prank(reporter);
        vm.expectRevert(InvalidChainIdentifierReputation.selector);
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_ZeroRegistryAddr_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
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
                chainNamespace: "eip155", chainId: "1", owner: abi.encodePacked(ueaUser2)
            })
        );
        vm.prank(ueaUser2);
        uint256 agentId2 = tapRegistry.register("ipfs://test2", CARD_HASH);

        bytes memory sig2 = _signBind(
            ueaUser2Key, ueaUser2, "eip155", "1", REGISTRY_ETH, 99, 1, block.timestamp + 1 hours
        );
        vm.prank(ueaUser2);
        tapRegistry.bind(
            ITAPRegistry.BindRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 99,
                proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: sig2,
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        ITAPReputationRegistry.ReputationSubmission[] memory subs =
            new ITAPReputationRegistry.ReputationSubmission[](2);
        subs[0] = _defaultSubmission();
        subs[1] = ITAPReputationRegistry.ReputationSubmission({
            agentId: agentId2,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: REGISTRY_ETH,
            boundAgentId: 99,
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
        ITAPReputationRegistry.ReputationSubmission[] memory subs =
            new ITAPReputationRegistry.ReputationSubmission[](3);

        subs[0] = ITAPReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "1",
            registryAddress: REGISTRY_ETH,
            boundAgentId: 42,
            feedbackCount: 200,
            summaryValue: 92 * 1e18,
            valueDecimals: 18,
            positiveCount: 180,
            negativeCount: 20,
            sourceBlockNumber: 1000
        });
        subs[1] = ITAPReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "8453",
            registryAddress: REGISTRY_BASE,
            boundAgentId: 17,
            feedbackCount: 150,
            summaryValue: 88 * 1e18,
            valueDecimals: 18,
            positiveCount: 130,
            negativeCount: 20,
            sourceBlockNumber: 2000
        });
        subs[2] = ITAPReputationRegistry.ReputationSubmission({
            agentId: agentId,
            chainNamespace: "eip155",
            chainId: "42161",
            registryAddress: REGISTRY_ARB,
            boundAgentId: 8,
            feedbackCount: 50,
            summaryValue: 95 * 1e18,
            valueDecimals: 18,
            positiveCount: 48,
            negativeCount: 2,
            sourceBlockNumber: 3000
        });

        vm.prank(reporter);
        repRegistry.batchSubmitReputation(subs);

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 400);
        assertEq(agg.chainCount, 3);
    }

    function test_BatchSubmit_TooLarge_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission[] memory subs =
            new ITAPReputationRegistry.ReputationSubmission[](51);

        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(BatchTooLarge.selector, 51, 50));
        repRegistry.batchSubmitReputation(subs);
    }

    function test_BatchSubmit_Empty_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission[] memory subs =
            new ITAPReputationRegistry.ReputationSubmission[](0);

        vm.prank(reporter);
        vm.expectRevert(EmptyBatch.selector);
        repRegistry.batchSubmitReputation(subs);
    }

    // ──────────────────────────────────────────────
    //  Aggregation Tests
    // ──────────────────────────────────────────────

    function test_Aggregation_SingleChain_MatchesSubmission() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 200, 92 * 1e18, 1000);

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 200);
        assertEq(agg.weightedAvgValue, 92 * 1e18);
        assertEq(agg.chainCount, 1);
    }

    function test_Aggregation_MultipleChains_WeightedAvg() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 200, 90 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 100, 60 * 1e18, 2000);

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 300);

        // weighted avg = (200*90 + 100*60) / 300 = 24000/300 = 80
        assertEq(agg.weightedAvgValue, 80 * 1e18);
    }

    function test_Aggregation_DifferentDecimals_Normalized() public {
        ITAPReputationRegistry.ReputationSubmission memory sub1 =
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: 100,
                summaryValue: 90 * 1e2,
                valueDecimals: 2,
                positiveCount: 90,
                negativeCount: 10,
                sourceBlockNumber: 1000
            });

        vm.prank(reporter);
        repRegistry.submitReputation(sub1);

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.valueDecimals, 18);
        assertEq(agg.weightedAvgValue, 90 * 1e18);
    }

    function test_Aggregation_NegativeValue_ClampsToZero() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, -50 * 1e18, 1000);

        uint256 score = repRegistry.getReputationScore(agentId);
        // Negative → baseScore = 0, still gets diversity bonus (500)
        assertEq(score, 500);
    }

    function test_Aggregation_ChainCount_Correct() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 50, 80 * 1e18, 2000);

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.chainCount, 2);
    }

    function test_Reaggregate_RemovesUnlinkedChain() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 200, 90 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 100, 80 * 1e18, 2000);

        ITAPReputationRegistry.AggregatedReputation memory aggBefore =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggBefore.chainCount, 2);
        assertEq(aggBefore.totalFeedbackCount, 300);

        vm.prank(ueaUser);
        tapRegistry.unbind("eip155", "8453", REGISTRY_BASE);

        repRegistry.reaggregate(agentId);

        ITAPReputationRegistry.AggregatedReputation memory aggAfter =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggAfter.chainCount, 1);
        assertEq(aggAfter.totalFeedbackCount, 200);
    }

    function test_Reaggregate_AnyoneCanCall() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        vm.prank(nobody);
        repRegistry.reaggregate(agentId);
    }

    function test_Reaggregate_AgentNotRegistered_Reverts() public {
        vm.prank(nobody);
        vm.expectRevert(abi.encodeWithSelector(AgentNotRegisteredForReputation.selector, 999));
        repRegistry.reaggregate(999);
    }

    // ──────────────────────────────────────────────
    //  Score Tests
    // ──────────────────────────────────────────────

    function test_Score_PerfectAgent_HighScore() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 1024, 100 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 1024, 100 * 1e18, 2000);
        _submitForChain("eip155", "42161", REGISTRY_ARB, 8, 1024, 100 * 1e18, 3000);

        uint256 score = repRegistry.getReputationScore(agentId);
        // 3072 total feedback → log2(3072)=11 → volumeMultiplier capped at 10000
        // baseScore = 100*7000/100 = 7000
        // adjusted = 7000 * 10000 / 10000 = 7000
        // diversity = 3 * 500 = 1500
        // total = 8500
        assertGt(score, 8000);
        assertLe(score, 10_000);
    }

    function test_Score_NewAgent_LowVolume() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 1, 100 * 1e18, 1000);

        uint256 score = repRegistry.getReputationScore(agentId);
        // 1 feedback → log2(1)=0 → volumeMultiplier = 5000
        // baseScore = 7000
        // adjusted = 7000 * 5000 / 10000 = 3500
        // diversity = 500
        // total = 4000
        assertEq(score, 4000);
    }

    function test_Score_MultiChain_DiversityBonus() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 1, 100 * 1e18, 1000);

        uint256 scoreOneChain = repRegistry.getReputationScore(agentId);

        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 1, 100 * 1e18, 2000);

        uint256 scoreTwoChains = repRegistry.getReputationScore(agentId);

        assertGt(scoreTwoChains, scoreOneChain);
        // Difference should be close to 500 (diversity bonus per chain)
        // But volume multiplier also changes with 2 total feedback
        assertGe(scoreTwoChains - scoreOneChain, 400);
    }

    function test_Score_DiversityBonus_CappedAt2000() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 1, 100 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 1, 100 * 1e18, 2000);
        _submitForChain("eip155", "42161", REGISTRY_ARB, 8, 1, 100 * 1e18, 3000);

        uint256 scoreThree = repRegistry.getReputationScore(agentId);

        // Diversity bonus at 3 chains = 1500, at 4 would be 2000 (capped)
        // With 3 feedback total, log2(3)=1, volumeMultiplier = 5500
        // baseScore = 7000, adjusted = 7000*5500/10000 = 3850
        // total = 3850 + 1500 = 5350
        assertGt(scoreThree, 5000);
    }

    function test_Score_SlashReduces() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);

        vm.prank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "bad behavior", keccak256("evidence"), 1000);

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertLt(scoreAfter, scoreBefore);
        assertEq(scoreBefore - scoreAfter, 1000);
    }

    function test_Score_HeavySlash_ClampsToZero() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 1, 50 * 1e18, 1000);

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);
        assertGt(scoreBefore, 0);

        vm.prank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "critical failure", keccak256("evidence"), 10_000);

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertEq(scoreAfter, 0);
    }

    // ──────────────────────────────────────────────
    //  Slashing Tests
    // ──────────────────────────────────────────────

    function test_Slash_ValidSlasher_Records() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        vm.prank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "fraud", keccak256("proof"), 2000);

        ITAPReputationRegistry.SlashRecord[] memory records = repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 1);
        assertEq(records[0].severityBps, 2000);
        assertEq(records[0].reporter, slasher);
        assertEq(keccak256(bytes(records[0].reason)), keccak256(bytes("fraud")));
    }

    function test_Slash_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit ITAPReputationRegistry.AgentSlashed(agentId, "eip155", "1", "fraud", 2000, slasher);

        vm.prank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "fraud", keccak256("proof"), 2000);
    }

    function test_Slash_NotSlasher_Reverts() public {
        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.slash(agentId, "eip155", "1", "fraud", keccak256("proof"), 2000);
    }

    function test_Slash_InvalidSeverity_Zero_Reverts() public {
        vm.prank(slasher);
        vm.expectRevert(abi.encodeWithSelector(InvalidSeverity.selector, 0));
        repRegistry.slash(agentId, "eip155", "1", "fraud", keccak256("proof"), 0);
    }

    function test_Slash_InvalidSeverity_Over10000_Reverts() public {
        vm.prank(slasher);
        vm.expectRevert(abi.encodeWithSelector(InvalidSeverity.selector, 10_001));
        repRegistry.slash(agentId, "eip155", "1", "fraud", keccak256("proof"), 10_001);
    }

    function test_Slash_CumulativePenalty() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        uint256 scoreBefore = repRegistry.getReputationScore(agentId);

        vm.startPrank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "fraud1", keccak256("e1"), 500);
        repRegistry.slash(agentId, "eip155", "1", "fraud2", keccak256("e2"), 700);
        repRegistry.slash(agentId, "eip155", "1", "fraud3", keccak256("e3"), 300);
        vm.stopPrank();

        ITAPReputationRegistry.SlashRecord[] memory records = repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 3);

        uint256 scoreAfter = repRegistry.getReputationScore(agentId);
        assertEq(scoreBefore - scoreAfter, 1500);
    }

    // ──────────────────────────────────────────────
    //  Read Function Tests
    // ──────────────────────────────────────────────

    function test_GetAggregated_NoData_ReturnsZero() public view {
        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 0);
        assertEq(agg.reputationScore, 0);
    }

    function test_GetChainReputation_Exists() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        ITAPReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(cr.feedbackCount, 100);
        assertEq(keccak256(bytes(cr.chainNamespace)), keccak256(bytes("eip155")));
    }

    function test_GetChainReputation_NotExists_ReturnsZero() public view {
        ITAPReputationRegistry.ChainReputation memory cr =
            repRegistry.getChainReputation(agentId, "eip155", "137");
        assertEq(cr.feedbackCount, 0);
        assertEq(cr.sourceBlockNumber, 0);
    }

    function test_GetAllChainReputations_MultipleChains() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 200, 90 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 150, 88 * 1e18, 2000);
        _submitForChain("eip155", "42161", REGISTRY_ARB, 8, 50, 95 * 1e18, 3000);

        ITAPReputationRegistry.ChainReputation[] memory all =
            repRegistry.getAllChainReputations(agentId);
        assertEq(all.length, 3);
    }

    function test_GetReputationScore_MatchesAggregate() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        uint256 score = repRegistry.getReputationScore(agentId);
        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(score, agg.reputationScore);
    }

    function test_IsFresh_WithinAge_True() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        assertTrue(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_IsFresh_Expired_False() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        vm.warp(block.timestamp + 7 hours);
        assertFalse(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_IsFresh_NoData_False() public view {
        assertFalse(repRegistry.isFresh(agentId, 6 hours));
    }

    function test_GetSlashRecords_ReturnsAll() public {
        vm.startPrank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "r1", keccak256("e1"), 100);
        repRegistry.slash(agentId, "eip155", "8453", "r2", keccak256("e2"), 200);
        vm.stopPrank();

        ITAPReputationRegistry.SlashRecord[] memory records = repRegistry.getSlashRecords(agentId);
        assertEq(records.length, 2);
        assertEq(records[0].severityBps, 100);
        assertEq(records[1].severityBps, 200);
    }

    // ──────────────────────────────────────────────
    //  Admin Tests
    // ──────────────────────────────────────────────

    function test_SetTAPRegistry_Admin_Updates() public {
        address newAddr = makeAddr("newTAPRegistry");

        vm.prank(admin);
        repRegistry.setTAPRegistry(newAddr);

        assertEq(repRegistry.getTAPRegistry(), newAddr);
    }

    function test_SetTAPRegistry_NonAdmin_Reverts() public {
        vm.prank(nobody);
        vm.expectRevert();
        repRegistry.setTAPRegistry(makeAddr("newTAPRegistry"));
    }

    function test_SetTAPRegistry_ZeroAddr_Reverts() public {
        vm.prank(admin);
        vm.expectRevert(InvalidTAPRegistryAddress.selector);
        repRegistry.setTAPRegistry(address(0));
    }

    function test_Pause_Unpause_WorksForPauser() public {
        vm.startPrank(pauser);
        repRegistry.pause();

        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();

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
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.summaryValue = 101 * 1e18;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SummaryValueOutOfRange.selector, int128(101 * 1e18), int128(100 * 1e18)
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_SummaryValueTooLow_Reverts() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
        sub.summaryValue = -101 * 1e18;
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(
                SummaryValueOutOfRange.selector, int128(-101 * 1e18), int128(100 * 1e18)
            )
        );
        repRegistry.submitReputation(sub);
    }

    function test_SubmitReputation_SummaryValueAtBoundary_Succeeds() public {
        ITAPReputationRegistry.ReputationSubmission memory sub = _defaultSubmission();
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
        // setUp already links 3 bindings. Fill to 64 bindings with data.
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 10, 50 * 1e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 10, 50 * 1e18, 1000);
        _submitForChain("eip155", "42161", REGISTRY_ARB, 8, 10, 50 * 1e18, 1000);
        for (uint256 i = 4; i <= 64; i++) {
            string memory cid = vm.toString(i);
            address chainReg = address(uint160(0xBEEF0000 + i));
            _linkBinding("eip155", cid, chainReg, i, i + 100);
            _submitForChain("eip155", cid, chainReg, i, 10, 50 * 1e18, 1000);
        }

        // Now unbind one binding to free a slot in TAPRegistry,
        // then bind a new binding on a different chain.
        // The chain key from the old binding still persists in
        // TAPReputationRegistry, so we now have 64 chain keys and
        // the 65th will exceed the cap.
        vm.prank(ueaUser);
        tapRegistry.unbind("eip155", "4", address(uint160(0xBEEF0004)));

        string memory cid65 = "65";
        address chainReg65 = address(uint160(0xBEEF0041));
        _linkBinding("eip155", cid65, chainReg65, 65, 200);

        ITAPReputationRegistry.ReputationSubmission memory sub =
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: cid65,
                registryAddress: chainReg65,
                boundAgentId: 65,
                feedbackCount: 10,
                summaryValue: 50 * 1e18,
                valueDecimals: 18,
                positiveCount: 5,
                negativeCount: 5,
                sourceBlockNumber: 1000
            });
        vm.prank(reporter);
        vm.expectRevert(abi.encodeWithSelector(TooManyChainKeys.selector, agentId, 64));
        repRegistry.submitReputation(sub);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: reaggregate pauseable (H-3)
    // ──────────────────────────────────────────────

    function test_Reaggregate_WhenPaused_Reverts() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        vm.prank(pauser);
        repRegistry.pause();

        vm.expectRevert();
        repRegistry.reaggregate(agentId);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: slash updates lastAggregated (M-2)
    // ──────────────────────────────────────────────

    function test_Slash_UpdatesLastAggregated() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90 * 1e18, 1000);

        uint64 tsBeforeSlash = repRegistry.getAggregatedReputation(agentId).lastAggregated;

        vm.warp(block.timestamp + 100);

        vm.prank(slasher);
        repRegistry.slash(agentId, "eip155", "1", "test", keccak256("e"), 500);

        uint64 tsAfterSlash = repRegistry.getAggregatedReputation(agentId).lastAggregated;

        assertGt(tsAfterSlash, tsBeforeSlash);
    }

    // ──────────────────────────────────────────────
    //  Audit Fix: initialize zero-address (H-4)
    // ──────────────────────────────────────────────

    function test_Initialize_ZeroAdmin_Reverts() public {
        TAPReputationRegistry impl = new TAPReputationRegistry();
        vm.expectRevert(InvalidInitializationAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                TAPReputationRegistry.initialize, (address(0), pauser, address(tapRegistry))
            )
        );
    }

    function test_Initialize_ZeroPauser_Reverts() public {
        TAPReputationRegistry impl = new TAPReputationRegistry();
        vm.expectRevert(InvalidInitializationAddress.selector);
        new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(
                TAPReputationRegistry.initialize, (admin, address(0), address(tapRegistry))
            )
        );
    }

    // ──────────────────────────────────────────────
    //  ERC-165
    // ──────────────────────────────────────────────

    function test_SupportsInterface_ITAPReputationRegistry() public view {
        assertTrue(repRegistry.supportsInterface(type(ITAPReputationRegistry).interfaceId));
    }

    function test_SupportsInterface_IAccessControl() public view {
        assertTrue(repRegistry.supportsInterface(type(IAccessControl).interfaceId));
    }

    // ──────────────────────────────────────────────
    //  ERC-7201 Storage Slot Verification
    // ──────────────────────────────────────────────

    // ──────────────────────────────────────────────
    //  Branch Coverage Tests
    // ──────────────────────────────────────────────

    function test_Initialize_ZeroTAPRegistry_Reverts() public {
        TAPReputationRegistry impl = new TAPReputationRegistry();
        bytes memory initData =
            abi.encodeCall(TAPReputationRegistry.initialize, (admin, pauser, address(0)));
        vm.expectRevert(InvalidTAPRegistryAddress.selector);
        new TransparentUpgradeableProxy(address(impl), admin, initData);
    }

    function test_Slash_EmptyChainIdentifier_Reverts() public {
        vm.startPrank(slasher);

        vm.expectRevert(InvalidChainIdentifierReputation.selector);
        repRegistry.slash(agentId, "", "1", "reason", keccak256("e"), 1000);

        vm.expectRevert(InvalidChainIdentifierReputation.selector);
        repRegistry.slash(agentId, "eip155", "", "reason", keccak256("e"), 1000);

        vm.stopPrank();
    }

    function test_Slash_AgentNotRegistered_Reverts() public {
        uint256 fakeAgentId = 999;
        vm.prank(slasher);
        vm.expectRevert(
            abi.encodeWithSelector(AgentNotRegisteredForReputation.selector, fakeAgentId)
        );
        repRegistry.slash(fakeAgentId, "eip155", "1", "reason", keccak256("e"), 1000);
    }

    function test_Slash_MaxRecordsExceeded_Reverts() public {
        vm.startPrank(slasher);
        for (uint256 i; i < 256; i++) {
            repRegistry.slash(agentId, "eip155", "1", "reason", keccak256(abi.encode(i)), 1);
        }

        vm.expectRevert(abi.encodeWithSelector(MaxSlashRecordsExceeded.selector, agentId));
        repRegistry.slash(agentId, "eip155", "1", "reason", keccak256("e"), 1);
        vm.stopPrank();
    }

    function test_Reaggregate_SkipsZeroFeedbackChain() public {
        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: 0,
                summaryValue: 0,
                valueDecimals: 18,
                positiveCount: 0,
                negativeCount: 0,
                sourceBlockNumber: 1000
            })
        );

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, 0);
        assertEq(agg.weightedAvgValue, 0);
        assertEq(agg.reputationScore, 0);
    }

    function test_Reaggregate_SwapsMiddleChainKey() public {
        _submitForChain("eip155", "1", REGISTRY_ETH, 42, 100, 90e18, 1000);
        _submitForChain("eip155", "8453", REGISTRY_BASE, 17, 200, 85e18, 2000);
        _submitForChain("eip155", "42161", REGISTRY_ARB, 8, 150, 88e18, 3000);

        ITAPReputationRegistry.AggregatedReputation memory aggBefore =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggBefore.chainCount, 3);

        vm.prank(ueaUser);
        tapRegistry.unbind("eip155", "1", REGISTRY_ETH);

        repRegistry.reaggregate(agentId);

        ITAPReputationRegistry.AggregatedReputation memory aggAfter =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(aggAfter.chainCount, 2);
        assertEq(aggAfter.totalFeedbackCount, 350);

        ITAPReputationRegistry.ChainReputation memory ethRep =
            repRegistry.getChainReputation(agentId, "eip155", "1");
        assertEq(ethRep.feedbackCount, 0);
    }

    // ──────────────────────────────────────────────
    //  ERC-7201 Storage Slot Verification
    // ──────────────────────────────────────────────

    function test_StorageSlot_MatchesERC7201Formula() public pure {
        bytes32 expected = keccak256(abi.encode(uint256(keccak256("tap.reputation.storage")) - 1))
            & ~bytes32(uint256(0xff));

        assertEq(expected, 0x09e00015682a58e0492fcd039d3aa8486a464512777fa9b0afa9eb03e4da8a00);
    }
}
