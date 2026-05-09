// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IGatewayAdapter} from "./IGatewayAdapter.sol";

/// @notice Minimal interface for the Push Chain Universal Gateway.
interface IUniversalGateway {
    struct UniversalTxRequest {
        address recipient;
        address token;
        uint256 amount;
        bytes payload;
        address revertRecipient;
        bytes signatureData;
    }

    function sendUniversalTx(
        UniversalTxRequest calldata req
    ) external payable;

    function inboundFee() external view returns (uint256);
}

/// @title PushGatewayAdapter
/// @notice Concrete adapter wrapping UniversalGateway.sendUniversalTx()
///         for ERC-8004+ source-chain contracts.
///         All messages use GAS_AND_PAYLOAD TX_TYPE (no funds, only payload).
contract PushGatewayAdapter is IGatewayAdapter {
    IUniversalGateway public immutable GATEWAY;

    constructor(address gateway_) {
        require(gateway_ != address(0), "zero gateway");
        GATEWAY = IUniversalGateway(gateway_);
    }

    /// @inheritdoc IGatewayAdapter
    function sendPayload(
        address recipient,
        bytes calldata payload,
        bytes calldata signatureData,
        address revertRecipient
    ) external payable override {
        GATEWAY.sendUniversalTx{value: msg.value}(
            IUniversalGateway.UniversalTxRequest({
                recipient: recipient,
                token: address(0),
                amount: 0,
                payload: payload,
                revertRecipient: revertRecipient,
                signatureData: signatureData
            })
        );
    }

    /// @inheritdoc IGatewayAdapter
    function estimateFee() external view override returns (uint256 fee) {
        fee = GATEWAY.inboundFee();
    }
}
