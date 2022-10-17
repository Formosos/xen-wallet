// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";

contract XENWalletFactory {

    address public immutable implementation;
	address public immutable deployer;
	address public XENCrypto;

    using Clones for address;

    // Use address resolver to derive proxy address
    // Mint and staking information is derived through XENCrypto contract
    mapping (address => address[]) public addressResolver;
    mapping (address => address) public reverseAddressResolver;

	constructor(address xenCrypto, address walletImplementation) {
        XENCrypto = xenCrypto;
        implementation = walletImplementation;
		deployer = msg.sender;        
	}

    function getSalt(uint256 _id) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, _id));
    }

    function getDeterministicAddress(bytes32 salt) external view returns (address) {
        return implementation.predictDeterministicAddress(salt);
    }

    // Create wallets
    function createWallet(uint256 _id) public {
        bytes32 salt = getSalt(_id);
        XENWallet clone = XENWallet(implementation.cloneDeterministic(salt));
        clone.initialize(XENCrypto);
        
        // TODO: Check if the following is valid in Solidity (empty dynamic array)

        // bytes memory bytecode = bytes.concat(bytes20(0x3D602d80600A3D3981F3363d3d373d3D3D363d73), bytes20(address(this)), bytes15(0x5af43d82803e903d91602b57fd5bf3));
		// address proxy;
        // assembly {
        //     proxy := create2(0, add(bytecode, 32), mload(bytecode), salt)
        // }

        //addressResolver[msg.sender].push(clone);
        reverseAddressResolver[address(clone)] = msg.sender;
    }

    function batchCreateWallet(uint256 _startId, uint256 _endId) external {
		for(uint256 id = _startId; id < _endId; id++) {
            createWallet(id);
        }
    }
}
