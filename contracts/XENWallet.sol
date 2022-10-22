// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IXENCrypto.sol";

contract XENWallet is Initializable {
    IXENCrypto public XENCrypto;
    address public manager;

    function initialize(address xenAddress, address managerAddress)
        public
        initializer
    {
        XENCrypto = IXENCrypto(xenAddress);
        manager = managerAddress;
    }

    // Claim ranks
    function claimRank(uint256 _term) public {
        require(msg.sender == manager, "No access");
        XENCrypto.claimRank(_term);
    }

    // Claim mint reward
    function claimAndTransferMintReward(address target) external {
        require(msg.sender == manager, "No access");
        IXENCrypto(XENCrypto).claimMintReward();
        IXENCrypto(XENCrypto).transfer(
            target,
            IXENCrypto(XENCrypto).balanceOf(address(this))
        );
    }
}
