// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Identity of an external-chain account on Push Chain.
struct UniversalAccountId {
    string chainNamespace;
    string chainId;
    bytes owner;
}
