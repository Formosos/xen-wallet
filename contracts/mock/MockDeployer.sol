// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

// Used for simulating regular contract deploys for unit tests

import "../XENWallet.sol";

contract MockDeployer {
    function deployWallets(uint256 amount) external {
        for (uint256 i; i < amount; ++i) {
            new XENWallet();
        }
    }
}
