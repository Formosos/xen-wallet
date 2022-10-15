// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";

contract XENWallet is IXENCrypto {

    address private immutable original;
	address private immutable deployer;
	address private constant XENCrypto = 0xca41f293A32d25c2216bC4B30f5b0Ab61b6ed2CB;

    // Use address resolver to derive proxy address
    // Mint and staking information is derived through XENCrypto contract
    mapping (address => address[]) private addressResolver;
    mapping (address => address) private reverseAddressResolver;

	constructor() {
        original = address(this);
		deployer = msg.sender;
	}

    // Create wallets
    function createWallet(uint256 _id) public {
        bytes32 salt = keccak256(abi.encodePacked(msg.sender, _id));
        address proxy = Clones.cloneDeterministic(address(this), salt);
        // TODO: Check if the following is valid in Solidity (empty dynamic array)
        addressResolver[msg.sender].push(proxy);
        reverseAddressResolver[proxy] = msg.sender;
    }

    function batchCreateWallet(uint256 _startId, uint256 _endId) external {
		for(uint256 id = _startId; id < _endId; id++) {
            createWallet(id);
        }
    }

    // Claim ranks
	function claimRank(uint256 _term) public {
		IXENCrypto(XENCrypto).claimRank(_term);
	}

	function batchClaimRank(uint256 _startId, uint256 _endId, uint256 _term) external {
		for(uint256 id = _startId; id < _endId; id++) {
            bytes32 salt = keccak256(abi.encodePacked(msg.sender, id));
            address proxy = Clones.predictDeterministicAddress(address(this), salt);
			XENWallet(proxy).claimRank(_term);
		}
	}

    // Claim mint reward
	function claimMintReward() external {
		IXENCrypto(XENCrypto).claimMintReward();
		if(address(this) != original)
		    selfdestruct(payable(tx.origin));
	}

	function claimMintRewardAndShare(address _to, uint256 _amount) external {
		IXENCrypto(XENCrypto).claimMintRewardAndShare(_to, _amount);
		if(address(this) != original)
		    selfdestruct(payable(tx.origin));
	}

    function batchClaimMintReward(uint256 _startId, uint256 _endId) external {
		for(uint id = _startId; id < _endId; id++) {
            bytes32 salt = keccak256(abi.encodePacked(msg.sender, id));
            address proxy = Clones.predictDeterministicAddress(address(this), salt);
			XENWallet(proxy).claimMintReward();
		}

        // TODO: Mint ERC20 tokens here
    }

    function safeMintReward(address _proxy) external {
        // Verify that the deployer is saving people (we could leave this open)
        require(msg.sender == deployer);

		XENWallet(_proxy).claimMintRewardAndShare(reverseAddressResolver[_proxy], 90);
		XENWallet(_proxy).claimMintRewardAndShare(deployer, 10);

        // TODO: Logic to understand if a day has passed (deployer can end stake under specific conditions)

        // TODO: Collect list of proxy address and iterate over them in typescript
    }

    // TODO: Stake and withdraw

    // Destroy contract and transfer tokens
    function transfer() external {}

    function batchTransfer() external {}

    // TBD ...

    function getActiveWallets(address _address) external view returns (address[] memory) {
        return addressResolver[_address];
    }
}
