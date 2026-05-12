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
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract TAPReputationRegistryFuzzTest is Test {
    TAPRegistry public tapRegistry;
    TAPReputationRegistry public repRegistry;
    MockUEAFactory public factory;

    address public admin = makeAddr("admin");
    address public pauser = makeAddr("pauser");
    address public reporter = makeAddr("reporter");
    address public slasher = makeAddr("slasher");

    address public ueaUser;
    uint256 public ueaUserKey;
    uint256 public agentId;

    address constant REGISTRY_ETH = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);

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
        agentId = tapRegistry.register("ipfs://QmTest", keccak256("card"));

        _linkBinding("eip155", "1", REGISTRY_ETH, 42, 1);
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

    function _signDigest(
        bytes32 digest
    ) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ueaUserKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _linkBinding(
        string memory chainNs,
        string memory chainId,
        address registryAddr,
        uint256 boundAgentId,
        uint256 nonce
    ) internal {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                BIND_TYPEHASH,
                ueaUser,
                keccak256(bytes(chainNs)),
                keccak256(bytes(chainId)),
                registryAddr,
                boundAgentId,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash));
        bytes memory sig = _signDigest(digest);

        vm.prank(ueaUser);
        tapRegistry.bind(
            ITAPRegistry.BindRequest({
                chainNamespace: chainNs,
                chainId: chainId,
                registryAddress: registryAddr,
                boundAgentId: boundAgentId,
                proofType: ITAPRegistry.BindProofType.OWNER_KEY_SIGNED,
                proofData: sig,
                nonce: nonce,
                deadline: deadline
            })
        );
    }

    function testFuzz_Score_AlwaysBounded(
        uint64 feedbackCount,
        int128 summaryValue,
        uint256 slashSeverity
    ) public {
        feedbackCount = uint64(bound(feedbackCount, 1, type(uint64).max));
        summaryValue = int128(bound(int256(summaryValue), -100 * 1e18, 100 * 1e18));
        slashSeverity = bound(slashSeverity, 0, 50_000);

        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: feedbackCount,
                summaryValue: summaryValue,
                valueDecimals: 18,
                positiveCount: feedbackCount / 2,
                negativeCount: feedbackCount / 2,
                sourceBlockNumber: 1000
            })
        );

        uint256 slashApplied;
        while (slashApplied < slashSeverity) {
            uint256 chunk = slashSeverity - slashApplied;
            if (chunk > 10_000) chunk = 10_000;
            vm.prank(slasher);
            repRegistry.slash(agentId, "eip155", "1", "test", keccak256("e"), chunk);
            slashApplied += chunk;
        }

        uint256 score = repRegistry.getReputationScore(agentId);
        assertLe(score, 10_000);
    }

    function testFuzz_Aggregation_TotalCountMatchesSum(
        uint64 count1,
        uint64 count2
    ) public {
        count1 = uint64(bound(count1, 1, 1e9));
        count2 = uint64(bound(count2, 1, 1e9));

        address reg2 = address(0x8004b269Fb4A3325136eB29FA0ceb6d2E539b543);
        _linkBinding("eip155", "8453", reg2, 17, 2);

        vm.startPrank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: count1,
                summaryValue: 90 * 1e18,
                valueDecimals: 18,
                positiveCount: count1,
                negativeCount: 0,
                sourceBlockNumber: 1000
            })
        );
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "8453",
                registryAddress: reg2,
                boundAgentId: 17,
                feedbackCount: count2,
                summaryValue: 80 * 1e18,
                valueDecimals: 18,
                positiveCount: count2,
                negativeCount: 0,
                sourceBlockNumber: 2000
            })
        );
        vm.stopPrank();

        ITAPReputationRegistry.AggregatedReputation memory agg =
            repRegistry.getAggregatedReputation(agentId);
        assertEq(agg.totalFeedbackCount, uint64(uint256(count1) + uint256(count2)));
    }

    function testFuzz_StaleProtection_Enforced(
        uint256 block1,
        uint256 block2
    ) public {
        block1 = bound(block1, 1, type(uint128).max);
        block2 = bound(block2, 0, block1);

        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: 100,
                summaryValue: 90 * 1e18,
                valueDecimals: 18,
                positiveCount: 90,
                negativeCount: 10,
                sourceBlockNumber: block1
            })
        );

        vm.prank(reporter);
        vm.expectRevert();
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: 200,
                summaryValue: 95 * 1e18,
                valueDecimals: 18,
                positiveCount: 190,
                negativeCount: 10,
                sourceBlockNumber: block2
            })
        );
    }

    function testFuzz_SlashPenalty_NeverNegativeScore(
        uint8 slashCount
    ) public {
        slashCount = uint8(bound(slashCount, 1, 20));

        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: 10,
                summaryValue: 50 * 1e18,
                valueDecimals: 18,
                positiveCount: 5,
                negativeCount: 5,
                sourceBlockNumber: 1000
            })
        );

        for (uint256 i; i < slashCount; i++) {
            vm.prank(slasher);
            repRegistry.slash(agentId, "eip155", "1", "test", keccak256(abi.encode(i)), 5000);
        }

        uint256 score = repRegistry.getReputationScore(agentId);
        assertLe(score, 10_000);
    }

    function testFuzz_Reaggregate_Idempotent(
        uint64 count
    ) public {
        count = uint64(bound(count, 1, 1e9));

        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: count,
                summaryValue: 85 * 1e18,
                valueDecimals: 18,
                positiveCount: count,
                negativeCount: 0,
                sourceBlockNumber: 1000
            })
        );

        repRegistry.reaggregate(agentId);
        ITAPReputationRegistry.AggregatedReputation memory agg1 =
            repRegistry.getAggregatedReputation(agentId);

        repRegistry.reaggregate(agentId);
        ITAPReputationRegistry.AggregatedReputation memory agg2 =
            repRegistry.getAggregatedReputation(agentId);

        assertEq(agg1.reputationScore, agg2.reputationScore);
        assertEq(agg1.totalFeedbackCount, agg2.totalFeedbackCount);
        assertEq(agg1.weightedAvgValue, agg2.weightedAvgValue);
        assertEq(agg1.chainCount, agg2.chainCount);
    }

    function testFuzz_Log2_Correct(
        uint256 x
    ) public {
        x = bound(x, 2, type(uint64).max);

        vm.prank(reporter);
        repRegistry.submitReputation(
            ITAPReputationRegistry.ReputationSubmission({
                agentId: agentId,
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: REGISTRY_ETH,
                boundAgentId: 42,
                feedbackCount: uint64(x),
                summaryValue: 100 * 1e18,
                valueDecimals: 18,
                positiveCount: uint64(x),
                negativeCount: 0,
                sourceBlockNumber: 1000
            })
        );

        uint256 score = repRegistry.getReputationScore(agentId);
        assertGt(score, 0);
        assertLe(score, 10_000);
    }
}
