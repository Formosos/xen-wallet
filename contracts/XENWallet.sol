// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IXENCrypto.sol";

contract XENWallet is Initializable {
    IXENCrypto public XENCrypto;
    address public owner;

    function initialize(address xenAddress, address ownerAddress)
        public
        initializer
    {
        XENCrypto = IXENCrypto(xenAddress);
        owner = ownerAddress;
    }

    // Claim ranks
    function claimRank(uint256 _term) public {
        XENCrypto.claimRank(_term);
    }

    // Claim mint reward
    function claimMintReward() external {
        IXENCrypto(XENCrypto).claimMintReward();
    }

    function transferBalance() external {
        IXENCrypto(XENCrypto).transfer(
            owner,
            IXENCrypto(XENCrypto).balanceOf(address(this))
        );
    }
}
