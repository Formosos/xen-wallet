// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";
import "./Presto.sol";

contract XENWalletManager {
    address public immutable implementation;
	address public immutable deployer;
	address public XENCrypto;

    using Clones for address;

    // Use address resolver to derive proxy address
    // Mint and staking information is derived through XENCrypto contract
    mapping (address => address[]) public addressResolver;
    mapping (address => address) public reverseAddressResolver;

    PrestoCrypto public ownToken;

	constructor(address xenCrypto, address walletImplementation) {
        XENCrypto = xenCrypto;
        implementation = walletImplementation;
		deployer = msg.sender;
        ownToken = new PrestoCrypto(address(this));
	}

    function getSalt(uint256 _id) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, _id));
    }

    function getDeterministicAddress(bytes32 salt) public view returns (address) {
        return implementation.predictDeterministicAddress(salt);
    }

    // Create wallets
    function createWallet(uint256 _id, uint256 term) public {
        bytes32 salt = getSalt(_id);
        XENWallet clone = XENWallet(implementation.cloneDeterministic(salt));
        clone.initialize(XENCrypto);
        clone.claimRank(term); // unsure if should be combined with initialize
        
        // TODO: Check if the following is valid in Solidity (empty dynamic array)

        // bytes memory bytecode = bytes.concat(bytes20(0x3D602d80600A3D3981F3363d3d373d3D3D363d73), bytes20(address(this)), bytes15(0x5af43d82803e903d91602b57fd5bf3));
		// address proxy;
        // assembly {
        //     proxy := create2(0, add(bytecode, 32), mload(bytecode), salt)
        // }

        //addressResolver[msg.sender].push(clone);
        reverseAddressResolver[address(clone)] = msg.sender;
    }

    function batchCreateWallet(uint256 _startId, uint256 _endId, uint256 term) external {
		for(uint256 id = _startId; id < _endId; id++) {
            createWallet(id, term);
        }
    }

    function batchClaimRank(uint256 _startId, uint256 _endId, uint256 _term) external {
		for(uint256 id = _startId; id < _endId; id++) {
            address proxy = getDeterministicAddress(getSalt(id));
            //address proxy = Clones.predictDeterministicAddress(address(this), salt);
			XENWallet(proxy).claimRank(_term);
		}
	}

    function batchClaimMintReward(uint256 _startId, uint256 _endId) external {

        uint256 mintTokens = 0;

		for(uint id = _startId; id < _endId; id++) {
            address proxy = getDeterministicAddress(getSalt(id));

    		mintTokens += XENWallet(proxy).XENbalanceOf(proxy);
			XENWallet(proxy).claimMintReward();
		}

        ownToken.mint(msg.sender, mintTokens);
    }
}
