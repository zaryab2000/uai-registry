// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UniversalAccountId} from "./Types.sol";

/// @title IUEAFactory
/// @notice Minimal interface for the Push Chain UEA Factory.
///         UAIRegistry only uses getOriginForUEA.
interface IUEAFactory {
    /// @notice Returns origin info for any address on Push Chain.
    /// @param addr Address to look up.
    /// @return account UniversalAccountId for the address.
    /// @return isUEA True if the address is a deployed UEA.
    function getOriginForUEA(
        address addr
    ) external view returns (UniversalAccountId memory account, bool isUEA);

    /// @notice Computes the deterministic UEA address before deployment.
    /// @param id Universal Account information.
    /// @return Predicted UEA proxy address.
    function computeUEA(
        UniversalAccountId memory id
    ) external view returns (address);
}
