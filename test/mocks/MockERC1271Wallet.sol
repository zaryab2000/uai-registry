// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC1271Wallet {
    bytes4 private constant _MAGIC = 0x1626ba7e;
    bool public shouldRevert;
    bool public returnBadMagic;

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function setReturnBadMagic(bool b) external {
        returnBadMagic = b;
    }

    function isValidSignature(
        bytes32,
        bytes calldata
    ) external view returns (bytes4) {
        if (shouldRevert) revert("mock revert");
        if (returnBadMagic) return bytes4(0xdeadbeef);
        return _MAGIC;
    }
}
