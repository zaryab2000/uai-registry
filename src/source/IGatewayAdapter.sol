// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGatewayAdapter
/// @notice Minimal interface abstracting cross-chain payload delivery
///         to the Push Chain settlement layer.
interface IGatewayAdapter {
    /// @notice Send a payload to a UEA on Push Chain via the Universal Gateway.
    /// @param recipient Target UEA address on Push Chain.
    /// @param payload ABI-encoded calldata for the target contract.
    /// @param signatureData Signature for UEA verification on Push Chain.
    /// @param revertRecipient Address to refund on revert.
    function sendPayload(
        address recipient,
        bytes calldata payload,
        bytes calldata signatureData,
        address revertRecipient
    ) external payable;

    /// @notice Estimate the native fee required for sendPayload.
    /// @return fee The native token amount required as msg.value.
    function estimateFee() external view returns (uint256 fee);
}
