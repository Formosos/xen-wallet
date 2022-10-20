// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

abstract contract IXENCrypto is IERC20 {

    // TODO: Check how to use events
    event RankClaimed(address indexed user, uint256 term, uint256 rank);
    event MintClaimed(address indexed user, uint256 rewardAmount);
    event Staked(address indexed user, uint256 amount, uint256 term);
    event Withdrawn(address indexed user, uint256 amount, uint256 reward);

    // TODO: Add other interfaces from XENCrypto contract

    // TODO: Check how public functions are integrated and if we need to define parameters
    // function getCurrentAPY() external;
    // function getCurrentMaxTerm() external;
    function claimRank(uint256 term) virtual external;

    function claimMintReward() virtual external;
	function claimMintRewardAndShare(address other, uint256 pct) virtual external;

    // function claimMintRewardAndStake(uint256 pct, uint256 term) external;

    // function stake(uint256 amount, uint256 term) external;
    // function withdraw() external;

	// function transfer(address to, uint256 amount) external;
}
