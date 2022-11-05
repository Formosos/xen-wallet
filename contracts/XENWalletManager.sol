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
    uint32[100] internal precalculatedRates;

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

        populateRates();
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
        // Perform weekly floor division
        uint256 elapsedWeeks = (block.timestamp - deployTimestamp) /
            SECONDS_IN_WEEK;

        if (
            elapsedWeeks > precalculatedRates.length ||
            precalculatedRates[elapsedWeeks] == 0
        ) {
            return original * 0; // TODO: some static rate
        }

        return (original * precalculatedRates[elapsedWeeks]) / 100000;
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

    function populateRates() private {
        /*
        Precalculated values for the formula:
        // Starting reward is 2x of XEN minted
        // Calculate 5% weekly decline and compound rewards
        uint256 current = (2 * original) / (1 + elapsedWeeks);
        uint256 cumulative = current;
        for (uint256 i = 0; i < elapsedWeeks; ++i) {
            current = (current * 95) / 100;
            cumulative += current;
        }
        */
        precalculatedRates[0] = 200000;
        precalculatedRates[1] = 195000;
        precalculatedRates[2] = 190166;
        precalculatedRates[3] = 185493;
        precalculatedRates[4] = 180975;
        precalculatedRates[5] = 176605;
        precalculatedRates[6] = 172378;
        precalculatedRates[7] = 168289;
        precalculatedRates[8] = 164333;
        precalculatedRates[9] = 160505;
        precalculatedRates[10] = 156799;
        precalculatedRates[11] = 153213;
        precalculatedRates[12] = 149740;
        precalculatedRates[13] = 146378;
        precalculatedRates[14] = 143122;
        precalculatedRates[15] = 139968;
        precalculatedRates[16] = 136912;
        precalculatedRates[17] = 133952;
        precalculatedRates[18] = 131083;
        precalculatedRates[19] = 128302;
        precalculatedRates[20] = 125607;
        precalculatedRates[21] = 122993;
        precalculatedRates[22] = 120459;
        precalculatedRates[23] = 118001;
        precalculatedRates[24] = 115617;
        precalculatedRates[25] = 113304;
        precalculatedRates[26] = 111060;
        precalculatedRates[27] = 108881;
        precalculatedRates[28] = 106767;
        precalculatedRates[29] = 104714;
        precalculatedRates[30] = 102721;
        precalculatedRates[31] = 100786;
        precalculatedRates[32] = 98905;
        precalculatedRates[33] = 97079;
        precalculatedRates[34] = 95304;
        precalculatedRates[35] = 93580;
        precalculatedRates[36] = 91903;
        precalculatedRates[37] = 90274;
        precalculatedRates[38] = 88689;
        precalculatedRates[39] = 87148;
        precalculatedRates[40] = 85650;
        precalculatedRates[41] = 84192;
        precalculatedRates[42] = 82773;
        precalculatedRates[43] = 81393;
        precalculatedRates[44] = 80049;
        precalculatedRates[45] = 78741;
        precalculatedRates[46] = 77468;
        precalculatedRates[47] = 76228;
        precalculatedRates[48] = 75020;
        precalculatedRates[49] = 73844;
        precalculatedRates[50] = 72698;
        precalculatedRates[51] = 71581;
        precalculatedRates[52] = 70492;
        precalculatedRates[53] = 69431;
        precalculatedRates[54] = 68397;
        precalculatedRates[55] = 67388;
        precalculatedRates[56] = 66404;
        precalculatedRates[57] = 65445;
        precalculatedRates[58] = 64508;
        precalculatedRates[59] = 63595;
        precalculatedRates[60] = 62703;
        precalculatedRates[61] = 61833;
        precalculatedRates[62] = 60984;
        precalculatedRates[63] = 60154;
        precalculatedRates[64] = 59344;
        precalculatedRates[65] = 58553;
        precalculatedRates[66] = 57780;
        precalculatedRates[67] = 57025;
        precalculatedRates[68] = 56287;
        precalculatedRates[69] = 55566;
        precalculatedRates[70] = 54861;
        precalculatedRates[71] = 54172;
        precalculatedRates[72] = 53498;
        precalculatedRates[73] = 52839;
        precalculatedRates[74] = 52195;
        precalculatedRates[75] = 51564;
        precalculatedRates[76] = 50947;
        precalculatedRates[77] = 50343;
        precalculatedRates[78] = 49752;
        precalculatedRates[79] = 49174;
        precalculatedRates[80] = 48607;
        precalculatedRates[81] = 48053;
        precalculatedRates[82] = 47510;
        precalculatedRates[83] = 46978;
        precalculatedRates[84] = 46457;
        precalculatedRates[85] = 45946;
        precalculatedRates[86] = 45446;
        precalculatedRates[87] = 44956;
        precalculatedRates[88] = 44476;
        precalculatedRates[89] = 44004;
        precalculatedRates[90] = 43543;
        precalculatedRates[91] = 43090;
        precalculatedRates[92] = 42646;
        precalculatedRates[93] = 42210;
        precalculatedRates[94] = 41783;
        precalculatedRates[95] = 41363;
        precalculatedRates[96] = 40952;
        precalculatedRates[97] = 40548;
        precalculatedRates[98] = 40152;
        precalculatedRates[99] = 39763;
    }
}
