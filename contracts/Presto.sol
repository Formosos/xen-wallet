// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "./interfaces/IXENCrypto.sol";
import '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract PrestoCrypto is ERC20 {
    uint256 internal constant LAUNCH_TIME = 1666254094;

    address public minter;

    constructor(address _minter) ERC20("", "") {
        minter = _minter;
    }

    function currentDay() external view returns (uint256) {
        return (block.timestamp - LAUNCH_TIME) / 1 days;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == minter, "No access");
        _mint(account, amount);
    }
    

    // function claimRank(uint256 term) external {
    // }

    // function claimMintReward() external {
    // }

	// function claimMintRewardAndShare(address other, uint256 pct) external {
    // }

    // TODO: Copyright XEN functionality

}
