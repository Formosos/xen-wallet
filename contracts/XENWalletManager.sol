// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";
import "./YENCrypto.sol";
import "hardhat/console.sol";

contract XENWalletManager is Ownable {
    using Clones for address;

    address internal immutable implementation;
    address public immutable feeReceiver;
    address public immutable XENCrypto;
    uint256 public immutable deployTimestamp;
    YENCrypto public immutable ownToken;
    mapping(address => address[]) internal unmintedWallets;

    uint256 internal constant SECONDS_IN_DAY = 3_600 * 24;
    uint256 internal constant SECONDS_IN_WEEK = SECONDS_IN_DAY * 7;
    uint256 internal constant MIN_TOKEN_MINT_TERM = 50;
    uint256 internal constant MIN_REWARD_LIMIT = SECONDS_IN_DAY * 2;
    uint256 internal constant RESCUE_FEE = 4700; // 47%
    uint256 internal constant MINT_FEE = 500; // 5%

    constructor(
        address xenCrypto,
        address walletImplementation,
        address feeAddress
    ) {
        XENCrypto = xenCrypto;
        implementation = walletImplementation;
        feeReceiver = feeAddress;
        ownToken = new YENCrypto(address(this));
        deployTimestamp = block.timestamp;
    }

    //////////////////  VIEWS

    function getSalt(uint256 _id) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, _id));
    }

    function getDeterministicAddress(bytes32 salt)
        public
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(salt);
    }

    function getWalletCount(address owner) public view returns (uint256) {
        return unmintedWallets[owner].length;
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

    function getUserInfos(address[] calldata owners)
        external
        view
        returns (IXENCrypto.MintInfo[] memory infos)
    {
        infos = new IXENCrypto.MintInfo[](owners.length);
        for (uint256 i = 0; i < owners.length; ++i) {
            infos[i] = XENWallet(owners[i]).getUserMint();
        }
    }

    function getAdjustedMintAmount(uint256 original)
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 elapsedWeeks = (block.timestamp - deployTimestamp) /
            SECONDS_IN_WEEK;

        // Accurately calculate 5% weekly decline and compound
        uint256 current = (2 * original) / (1 + elapsedWeeks);
        uint256 cumulative = current;
        for (uint256 i = 0; i < elapsedWeeks; ++i) {
            current = (current * 95) / 100;
            cumulative += current;
        }

        // Starting reward is 2x of XEN minted
        return cumulative;
    }

    ////////////////// STATE CHANGING FUNCTIONS

    // Create wallets
    function createWallet(uint256 _id, uint256 term) internal {
        bytes32 salt = getSalt(_id);
        XENWallet clone = XENWallet(implementation.cloneDeterministic(salt));

        clone.initialize(XENCrypto, address(this));
        clone.claimRank(term);

        unmintedWallets[msg.sender].push(address(clone));
    }

    function batchCreateWallets(uint256 amount, uint256 term) external {
        require(term >= 50, "Too short term");
        uint256 existing = unmintedWallets[msg.sender].length;
        for (uint256 id = 0; id < amount; id++) {
            createWallet(id + existing, term);
        }
    }

    // Claims rewards and sends them to the wallet owner
    function batchClaimAndTransferMintReward(uint256 _startId, uint256 _endId)
        external
    {
        uint256 claimed = 0;

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = unmintedWallets[msg.sender][id];

            claimed += XENWallet(proxy).claimAndTransferMintReward(msg.sender);

            unmintedWallets[msg.sender][id] = address(0x0);
        }

        if (claimed > 0) {
            uint256 toBeMinted = getAdjustedMintAmount(claimed);
            uint256 fee = (toBeMinted * MINT_FEE) / 10_000; // reduce minting fee
            ownToken.mint(msg.sender, toBeMinted - fee);
            ownToken.mint(feeReceiver, fee);
        }
    }

    function batchClaimMintRewardRescue(
        address walletOwner,
        uint256 _startId,
        uint256 _endId
    ) external {
        require(msg.sender == owner(), "No access");

        IXENCrypto xenCrypto = IXENCrypto(XENCrypto);
        uint256 rescued = 0;

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = unmintedWallets[walletOwner][id];

            IXENCrypto.MintInfo memory info = XENWallet(proxy).getUserMint();

            if (block.timestamp > info.maturityTs + MIN_REWARD_LIMIT) {
                rescued += XENWallet(proxy).claimAndTransferMintReward(
                    address(this)
                );
                unmintedWallets[walletOwner][id] = address(0x0);
            }
        }

        if (rescued > 0) {
            uint256 toBeMinted = getAdjustedMintAmount(rescued);

            uint256 xenFee = (rescued * RESCUE_FEE) / 10_000;
            uint256 mintFee = (toBeMinted * (RESCUE_FEE + MINT_FEE)) / 10_000;

            // Transfer XEN and own token

            ownToken.mint(walletOwner, toBeMinted - mintFee);
            ownToken.mint(feeReceiver, mintFee);

            xenCrypto.transfer(walletOwner, rescued - xenFee);
            xenCrypto.transfer(feeReceiver, xenFee);
        }
    }
}
