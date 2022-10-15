// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

interface IXENCrypto {

    // TODO: Check how to use events
    event RankClaimed(address indexed user, uint256 term, uint256 rank);
    event MintClaimed(address indexed user, uint256 rewardAmount);
    event Staked(address indexed user, uint256 amount, uint256 term);
    event Withdrawn(address indexed user, uint256 amount, uint256 reward);

    // TODO: Add other interfaces from XENCrypto contract

    // TODO: Check how public functions are integrated and if we need to define parameters
    // function getCurrentAPY() external;
    // function getCurrentMaxTerm() external;
    function claimRank(uint256 term) external;

    function claimMintReward() external;
	function claimMintRewardAndShare(address other, uint256 pct) external;

    // function claimMintRewardAndStake(uint256 pct, uint256 term) external;

    // function stake(uint256 amount, uint256 term) external;
    // function withdraw() external;

	// function transfer(address to, uint256 amount) external;
}
