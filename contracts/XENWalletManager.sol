// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";
import "./Presto.sol";
import "hardhat/console.sol";

contract XENWalletManager {
    using Clones for address;

    address public immutable implementation;
    address public immutable deployer;
    address public XENCrypto;
    PrestoCrypto public ownToken;

    uint256 public constant SECONDS_IN_DAY = 3_600 * 24;
    uint256 public constant MIN_REWARD_LIMIT = SECONDS_IN_DAY * 2;
    uint256 public constant RESCUE_FEE = 2000; // 20%

    // Use address resolver to derive proxy address
    // Mint and staking information is derived through XENCrypto contract
    mapping(address => address[]) public addressResolver;
    mapping(address => address) public reverseAddressResolver;

    constructor(address xenCrypto, address walletImplementation) {
        XENCrypto = xenCrypto;
        implementation = walletImplementation;
        deployer = msg.sender;
        ownToken = new PrestoCrypto(address(this));
    }

    function getSalt(uint256 _id) public view returns (bytes32) {
        return getWalletSalt(msg.sender, _id);
    }

    function getWalletSalt(address wallet, uint256 _id)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(wallet, _id));
    }

    function getDeterministicAddress(bytes32 salt)
        public
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(salt);
    }

    // Create wallets
    function createWallet(uint256 _id, uint256 term) internal {
        bytes32 salt = getSalt(_id);
        XENWallet clone = XENWallet(implementation.cloneDeterministic(salt));
        clone.initialize(XENCrypto, address(this));
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

    function batchCreateWallet(
        uint256 _startId,
        uint256 _endId,
        uint256 term
    ) external {
        for (uint256 id = _startId; id <= _endId; id++) {
            createWallet(id, term);
        }
    }

    // Mostly useful for external parties
    function getWallets(uint256 _startId, uint256 _endId)
        external
        view
        returns (address[] memory)
    {
        uint256 size = _endId - _startId + 1;
        address[] memory wallets = new address[](size);
        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = getDeterministicAddress(getSalt(id));

            // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/a1948250ab8c441f6d327a65754cb20d2b1b4554/contracts/utils/Address.sol#L41
            if (proxy.code.length > 0) {
                wallets[id - _startId] = proxy;
            } else {
                // no more wallets
                // create new (smaller) array so that we don't return 0x0 addresses
                address[] memory truncatedWallets = new address[](
                    id - _startId
                );

                for (uint256 i2 = 0; i2 < id - _startId; ++i2) {
                    truncatedWallets[i2] = wallets[i2];
                }

                return truncatedWallets;
            }
        }
        return wallets;
    }

    // Claims rewards and sends them to the wallet owner
    function batchClaimAndTransferMintReward(uint256 _startId, uint256 _endId)
        external
    {
        uint256 balanceBefore = IXENCrypto(XENCrypto).balanceOf(msg.sender);

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = getDeterministicAddress(getSalt(id));

            if (proxy.code.length > 0) {
                IXENCrypto.MintInfo memory info = XENWallet(proxy)
                    .getUserMint();

                if (info.rank > 0 && block.timestamp > info.maturityTs) {
                    XENWallet(proxy).claimAndTransferMintReward(msg.sender);
                }
            }
        }
        uint256 balanceAfter = IXENCrypto(XENCrypto).balanceOf(msg.sender);
        uint256 diff = balanceAfter - balanceBefore;
        if (diff > 0) {
            ownToken.mint(msg.sender, diff);
        }
    }

    function batchClaimMintRewardRescue(
        address walletOwner,
        uint256 _startId,
        uint256 _endId
    ) external {
        require(msg.sender == deployer, "No access");

        IXENCrypto xenCrypto = IXENCrypto(XENCrypto);

        uint256 balanceBefore = xenCrypto.balanceOf(address(this));

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = getDeterministicAddress(
                getWalletSalt(walletOwner, id)
            );
            if (proxy.code.length > 0) {
                IXENCrypto.MintInfo memory info = XENWallet(proxy)
                    .getUserMint();

                if (block.timestamp > info.maturityTs + MIN_REWARD_LIMIT) {
                    XENWallet(proxy).claimAndTransferMintReward(address(this));
                }
            }
        }

        uint256 balanceAfter = xenCrypto.balanceOf(address(this));
        uint256 diff = balanceAfter - balanceBefore;

        if (diff > 0) {
            // transfer XEN and own token
            uint256 fee = (diff * RESCUE_FEE) / 10000;

            ownToken.mint(walletOwner, diff - fee);
            ownToken.mint(deployer, fee);

            xenCrypto.transfer(walletOwner, diff - fee);
            xenCrypto.transfer(deployer, fee);
        }
    }
}
