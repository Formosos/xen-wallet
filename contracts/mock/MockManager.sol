// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

// Used for extending the default manager for unit tests

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

    function getAdjustedMintAmount_mock(uint256 original, uint256 term)
        public
        view
        returns (uint256)
    {
        return super.getAdjustedMintAmount(original, term);
    }
}
