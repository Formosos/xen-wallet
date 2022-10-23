// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract YENCrypto is ERC20 {
    address public minter;
    uint256 internal constant LAUNCH_TIME = 1_666_521_063;
    uint256 internal constant LAUNCH_PHASE = 1_000_000;

    constructor(address _minter) ERC20("YEN", "YEN") {
        minter = _minter;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == minter, "No access");

        // Calculate reward multiplier
        uint256 secondsSinceLaunch = block.timestamp - LAUNCH_TIME;
        uint256 rewardMultiplier = (2_000 * LAUNCH_PHASE) / secondsSinceLaunch;

        amount = (rewardMultiplier * amount) / 1_000;
        _mint(account, amount);
    }
}
