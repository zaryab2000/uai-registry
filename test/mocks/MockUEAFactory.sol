// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUEAFactory} from "src/interfaces/IUEAFactory.sol";
import {UniversalAccountId} from "src/interfaces/Types.sol";

contract MockUEAFactory is IUEAFactory {
    mapping(address => UniversalAccountId) private _origins;
    mapping(address => bool) private _isUEA;
    mapping(address => bool) private _hasOrigin;

    function addUEA(address uea, UniversalAccountId memory origin) external {
        _origins[uea] = origin;
        _isUEA[uea] = true;
        _hasOrigin[uea] = true;
    }

    function getOriginForUEA(
        address addr
    )
        external
        view
        override
        returns (UniversalAccountId memory account, bool isUEA)
    {
        if (_hasOrigin[addr]) {
            return (_origins[addr], _isUEA[addr]);
        }
        return (
            UniversalAccountId({
                chainNamespace: "push",
                chainId: "42101",
                owner: abi.encodePacked(addr)
            }),
            false
        );
    }

    function computeUEA(
        UniversalAccountId memory id
    ) external pure override returns (address) {
        return address(uint160(uint256(keccak256(abi.encode(id)))));
    }
}
