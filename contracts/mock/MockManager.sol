// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// Used for simulating regular contract deploys

import "../XENWalletManager.sol";

contract MockManager is XENWalletManager {
    constructor(
        address xenCrypto,
        address walletImplementation,
        address feeAddress
    ) XENWalletManager(xenCrypto, walletImplementation, feeAddress) {}

    function getImplementation() public view returns (address) {
        return implementation;
    }

    function getAdjustedMint(uint256 original) public view returns (uint256) {
        return super.getAdjustedMintAmount(original);
    }
}
