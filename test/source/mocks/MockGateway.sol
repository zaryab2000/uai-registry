// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IGatewayAdapter} from "src/source/IGatewayAdapter.sol";

/// @dev Records all payloads sent via sendPayload for test assertions.
contract MockGatewayAdapter is IGatewayAdapter {
    struct Call {
        address recipient;
        bytes payload;
        bytes signatureData;
        address revertRecipient;
        uint256 value;
    }

    Call[] public calls;
    uint256 public fee;
    bool public shouldRevert;

    constructor(uint256 fee_) {
        fee = fee_;
    }

    function sendPayload(
        address recipient,
        bytes calldata payload,
        bytes calldata signatureData,
        address revertRecipient
    ) external payable override {
        if (shouldRevert) revert("gateway reverted");
        calls.push(
            Call({
                recipient: recipient,
                payload: payload,
                signatureData: signatureData,
                revertRecipient: revertRecipient,
                value: msg.value
            })
        );
    }

    function estimateFee() external view override returns (uint256) {
        return fee;
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function lastCall() external view returns (Call memory) {
        return calls[calls.length - 1];
    }

    function setShouldRevert(bool val) external {
        shouldRevert = val;
    }

    function setFee(uint256 fee_) external {
        fee = fee_;
    }
}
