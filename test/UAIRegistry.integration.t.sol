// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {UAIRegistry} from "src/UAIRegistry.sol";
import {IUAIRegistry} from "src/IUAIRegistry.sol";
import {IUEAFactory} from "src/interfaces/IUEAFactory.sol";
import {UniversalAccountId} from "src/interfaces/Types.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract UAIRegistryIntegrationTest is Test {
    UAIRegistry public registry;

    address constant UEA_FACTORY = 0x00000000000000000000000000000000000000eA;
    uint256 constant PUSH_CHAIN_ID = 42101;

    address public admin;
    uint256 public adminKey;

    bytes32 public constant SHADOW_LINK_TYPEHASH = keccak256(
        "ShadowLink(address canonicalUEA,string chainNamespace,string chainId,"
        "address registryAddress,uint256 shadowAgentId,uint256 nonce,uint256 deadline)"
    );

    modifier onlyPushChain() {
        if (block.chainid != PUSH_CHAIN_ID) {
            return;
        }
        _;
    }

    function setUp() public onlyPushChain {
        (admin, adminKey) = makeAddrAndKey("integrationAdmin");

        UAIRegistry impl = new UAIRegistry(IUEAFactory(UEA_FACTORY));
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(impl),
            admin,
            abi.encodeCall(UAIRegistry.initialize, (admin, admin))
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

    function test_Integration_RegisterWithRealUEAFactory()
        public
        onlyPushChain
    {
        address caller = makeAddr("integrationCaller");
        vm.prank(caller);
        uint256 agentId = registry.register(
            "ipfs://QmIntegration",
            keccak256("integration-card")
        );

        assertEq(agentId, uint256(uint160(caller)));

        IUAIRegistry.AgentRecord memory rec = registry.getAgentRecord(agentId);
        assertTrue(rec.registered);
        assertTrue(bytes(rec.originChainNamespace).length > 0);
    }

    function test_Integration_LinkShadow_EthereumRegistry()
        public
        onlyPushChain
    {
        address caller = makeAddr("integrationLinker");
        (, uint256 signerKey) = makeAddrAndKey("integrationSigner");

        vm.prank(caller);
        registry.register(
            "ipfs://QmIntegrationLink",
            keccak256("integration-link-card")
        );

        address ethRegistry =
            address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);

        bytes32 structHash = keccak256(
            abi.encode(
                SHADOW_LINK_TYPEHASH,
                caller,
                keccak256(bytes("eip155")),
                keccak256(bytes("1")),
                ethRegistry,
                uint256(42),
                uint256(1),
                block.timestamp + 1 hours
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _getDomainSeparator(), structHash)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.prank(caller);
        registry.linkShadow(
            IUAIRegistry.ShadowLinkRequest({
                chainNamespace: "eip155",
                chainId: "1",
                registryAddress: ethRegistry,
                shadowAgentId: 42,
                proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                proofData: abi.encodePacked(r, s, v),
                nonce: 1,
                deadline: block.timestamp + 1 hours
            })
        );

        (address canonical, bool verified) = registry.canonicalUEAFromShadow(
            "eip155", "1", ethRegistry, 42
        );
        assertEq(canonical, caller);
        assertTrue(verified);
    }

    function test_Integration_FullFlow() public onlyPushChain {
        address caller = makeAddr("integrationFull");
        (, uint256 signerKey) = makeAddrAndKey("integrationFullSigner");

        vm.prank(caller);
        registry.register(
            "ipfs://QmFullFlow",
            keccak256("full-flow-card")
        );

        address reg = address(0x8004A169FB4a3325136EB29fA0ceB6D2e539a432);

        string[3] memory chains = ["1", "8453", "42161"];
        uint256[3] memory shadowIds = [uint256(42), uint256(17), uint256(8)];

        vm.startPrank(caller);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 structHash = keccak256(
                abi.encode(
                    SHADOW_LINK_TYPEHASH,
                    caller,
                    keccak256(bytes("eip155")),
                    keccak256(bytes(chains[i])),
                    reg,
                    shadowIds[i],
                    i + 1,
                    block.timestamp + 1 hours
                )
            );
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01", _getDomainSeparator(), structHash
                )
            );
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

            registry.linkShadow(
                IUAIRegistry.ShadowLinkRequest({
                    chainNamespace: "eip155",
                    chainId: chains[i],
                    registryAddress: reg,
                    shadowAgentId: shadowIds[i],
                    proofType: IUAIRegistry.ShadowProofType.OWNER_KEY_SIGNED,
                    proofData: abi.encodePacked(r, s, v),
                    nonce: i + 1,
                    deadline: block.timestamp + 1 hours
                })
            );
        }

        IUAIRegistry.ShadowEntry[] memory shadows =
            registry.getShadows(uint256(uint160(caller)));
        assertEq(shadows.length, 3);

        registry.unlinkShadow("eip155", "8453", reg);

        shadows = registry.getShadows(uint256(uint160(caller)));
        assertEq(shadows.length, 2);

        (address canonical,) = registry.canonicalUEAFromShadow(
            "eip155", "8453", reg, 17
        );
        assertEq(canonical, address(0));

        (canonical,) = registry.canonicalUEAFromShadow(
            "eip155", "1", reg, 42
        );
        assertEq(canonical, caller);

        vm.stopPrank();
    }
}
