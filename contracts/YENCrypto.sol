// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract YENCrypto is ERC20 {
    address public minter;

    constructor(address _minter) ERC20("YEN", "YEN") {
        minter = _minter;
    }

    function mint(address account, uint256 amount) external {
        require(msg.sender == minter, "No access");
        _mint(account, amount);
    }
}
