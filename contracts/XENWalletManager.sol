// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

// import "hardhat/console.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";
import "./YENCrypto.sol";

contract XENWalletManager {
    using Clones for address;

    address public immutable implementation;
    address public immutable deployer;
    address public XENCrypto;
    YENCrypto public ownToken;

    uint256 public constant SECONDS_IN_DAY = 3_600 * 24;
    uint256 public constant MIN_REWARD_LIMIT = SECONDS_IN_DAY * 2;
    uint256 public constant RESCUE_FEE = 2000; // 20%

    // Use address resolver to derive proxy address
    // Mint and staking information is derived through XENCrypto contract
    mapping(address => address[]) public unmintedWallets;

    constructor(address xenCrypto, address walletImplementation) {
        XENCrypto = xenCrypto;
        implementation = walletImplementation;
        deployer = msg.sender;
        ownToken = new YENCrypto(address(this));
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
        clone.claimRank(term);

        unmintedWallets[msg.sender].push(address(clone));
    }

    function batchCreateWallets(uint256 amount, uint256 term) external {
        uint256 existing = unmintedWallets[msg.sender].length;
        for (uint256 id = 0; id < amount; id++) {
            createWallet(id + existing, term);
        }
    }

    function getWallets(
        address owner,
        uint256 _startId,
        uint256 _endId
    ) external view returns (address[] memory) {
        uint256 size = _endId - _startId + 1;
        address[] memory wallets = new address[](size);
        for (uint256 id = _startId; id <= _endId; id++) {
            wallets[id - _startId] = unmintedWallets[owner][id];
        }
        return wallets;
    }

    // Claims rewards and sends them to the wallet owner
    function batchClaimAndTransferMintReward(uint256 _startId, uint256 _endId)
        external
    {
        uint256 toBeMinted = 0;

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = unmintedWallets[msg.sender][id];

            IXENCrypto.MintInfo memory info = XENWallet(proxy).getUserMint();

            if (info.rank > 0 && block.timestamp > info.maturityTs) {
                if (info.term > 50) {
                    toBeMinted += XENWallet(proxy).claimAndTransferMintReward(
                        msg.sender
                    );
                } else {
                    XENWallet(proxy).claimAndTransferMintReward(msg.sender);
                }
                unmintedWallets[msg.sender][id] = address(0x0);
            }
        }

        if (toBeMinted > 0) {
            ownToken.mint(msg.sender, toBeMinted);
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

        // TODO: We can probably simplify the transfer logic for XENCrypto
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
