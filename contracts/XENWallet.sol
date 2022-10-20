// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IXENCrypto.sol";
import "./Presto.sol";

contract XENWallet is Initializable {
    IXENCrypto public XENCrypto;

    function initialize(address xenAddress) public initializer {
        XENCrypto = IXENCrypto(xenAddress);
    }

    // Claim ranks
    function claimRank(uint256 _term) public {
        XENCrypto.claimRank(_term);
    }

    /* function batchClaimRank(uint256 _startId, uint256 _endId, uint256 _term) external {
		for(uint256 id = _startId; id < _endId; id++) {
            bytes32 salt = keccak256(abi.encodePacked(msg.sender, id));
            address proxy = Clones.predictDeterministicAddress(address(this), salt);
			XENWallet(proxy).claimRank(_term);
		}
	} */

    // Claim mint reward
    function claimMintReward() external {
        IXENCrypto(XENCrypto).claimMintReward();
        selfdestruct(payable(tx.origin));
    }

    function claimMintRewardAndShare(address _to, uint256 _amount) external {
        IXENCrypto(XENCrypto).claimMintRewardAndShare(_to, _amount);
        selfdestruct(payable(tx.origin));
    }

    function XENbalanceOf(address account) public view returns (uint256) {
        return IXENCrypto(XENCrypto).balanceOf(account);
    }

    /* function batchClaimMintReward(uint256 _startId, uint256 _endId) external {

        uint256 mintTokens = 0;

		for(uint id = _startId; id < _endId; id++) {
            bytes32 salt = keccak256(abi.encodePacked(msg.sender, id));
            address proxy = Clones.predictDeterministicAddress(address(this), salt);

    		mintTokens += XENCrypto.balanceOf(proxy);
			XENWallet(proxy).claimMintReward();
		}

        //Presto._mint(msg.sender, mintTokens);

    } */

    function safeMintReward(address _proxy) external {
        // Verify that the deployer is saving people (we could leave this open)
        //require(msg.sender == deployer);
        //XENWallet(_proxy).claimMintRewardAndShare(reverseAddressResolver[_proxy], 90);
        //XENWallet(_proxy).claimMintRewardAndShare(deployer, 10);
        // TODO: Logic to understand if a day has passed (deployer can end stake under specific conditions)
        // TODO: Collect list of proxy address and iterate over them in typescript
    }

    // TODO: Stake and withdraw

    // Destroy contract and transfer tokens
    function transfer() external {}

    function batchTransfer() external {}

    // TBD ...

    /*  function getActiveWallets(address _address) external view returns (address[] memory) {
        return addressResolver[_address];
    } */
}
