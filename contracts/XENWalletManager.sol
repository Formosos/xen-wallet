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
    uint32[500] internal precalculatedRates;

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
            // return the last rate
            return
                (original * precalculatedRates[precalculatedRates.length - 1]) /
                100000;
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

    function populateRates() internal virtual {
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
        precalculatedRates[100] = 39381;
        precalculatedRates[101] = 39006;
        precalculatedRates[102] = 38637;
        precalculatedRates[103] = 38276;
        precalculatedRates[104] = 37920;
        precalculatedRates[105] = 37571;
        precalculatedRates[106] = 37228;
        precalculatedRates[107] = 36891;
        precalculatedRates[108] = 36560;
        precalculatedRates[109] = 36234;
        precalculatedRates[110] = 35914;
        precalculatedRates[111] = 35600;
        precalculatedRates[112] = 35290;
        precalculatedRates[113] = 34986;
        precalculatedRates[114] = 34687;
        precalculatedRates[115] = 34392;
        precalculatedRates[116] = 34103;
        precalculatedRates[117] = 33818;
        precalculatedRates[118] = 33538;
        precalculatedRates[119] = 33262;
        precalculatedRates[120] = 32991;
        precalculatedRates[121] = 32724;
        precalculatedRates[122] = 32461;
        precalculatedRates[123] = 32202;
        precalculatedRates[124] = 31947;
        precalculatedRates[125] = 31696;
        precalculatedRates[126] = 31449;
        precalculatedRates[127] = 31205;
        precalculatedRates[128] = 30966;
        precalculatedRates[129] = 30730;
        precalculatedRates[130] = 30497;
        precalculatedRates[131] = 30268;
        precalculatedRates[132] = 30042;
        precalculatedRates[133] = 29819;
        precalculatedRates[134] = 29600;
        precalculatedRates[135] = 29384;
        precalculatedRates[136] = 29171;
        precalculatedRates[137] = 28961;
        precalculatedRates[138] = 28753;
        precalculatedRates[139] = 28549;
        precalculatedRates[140] = 28348;
        precalculatedRates[141] = 28149;
        precalculatedRates[142] = 27953;
        precalculatedRates[143] = 27760;
        precalculatedRates[144] = 27569;
        precalculatedRates[145] = 27381;
        precalculatedRates[146] = 27196;
        precalculatedRates[147] = 27013;
        precalculatedRates[148] = 26832;
        precalculatedRates[149] = 26654;
        precalculatedRates[150] = 26478;
        precalculatedRates[151] = 26304;
        precalculatedRates[152] = 26133;
        precalculatedRates[153] = 25964;
        precalculatedRates[154] = 25797;
        precalculatedRates[155] = 25632;
        precalculatedRates[156] = 25469;
        precalculatedRates[157] = 25308;
        precalculatedRates[158] = 25150;
        precalculatedRates[159] = 24993;
        precalculatedRates[160] = 24838;
        precalculatedRates[161] = 24685;
        precalculatedRates[162] = 24534;
        precalculatedRates[163] = 24384;
        precalculatedRates[164] = 24237;
        precalculatedRates[165] = 24091;
        precalculatedRates[166] = 23947;
        precalculatedRates[167] = 23805;
        precalculatedRates[168] = 23664;
        precalculatedRates[169] = 23525;
        precalculatedRates[170] = 23388;
        precalculatedRates[171] = 23252;
        precalculatedRates[172] = 23118;
        precalculatedRates[173] = 22985;
        precalculatedRates[174] = 22854;
        precalculatedRates[175] = 22724;
        precalculatedRates[176] = 22596;
        precalculatedRates[177] = 22469;
        precalculatedRates[178] = 22344;
        precalculatedRates[179] = 22220;
        precalculatedRates[180] = 22097;
        precalculatedRates[181] = 21976;
        precalculatedRates[182] = 21856;
        precalculatedRates[183] = 21737;
        precalculatedRates[184] = 21619;
        precalculatedRates[185] = 21503;
        precalculatedRates[186] = 21388;
        precalculatedRates[187] = 21275;
        precalculatedRates[188] = 21162;
        precalculatedRates[189] = 21051;
        precalculatedRates[190] = 20941;
        precalculatedRates[191] = 20832;
        precalculatedRates[192] = 20724;
        precalculatedRates[193] = 20617;
        precalculatedRates[194] = 20511;
        precalculatedRates[195] = 20407;
        precalculatedRates[196] = 20303;
        precalculatedRates[197] = 20201;
        precalculatedRates[198] = 20099;
        precalculatedRates[199] = 19999;
        precalculatedRates[200] = 19899;
        precalculatedRates[201] = 19801;
        precalculatedRates[202] = 19703;
        precalculatedRates[203] = 19607;
        precalculatedRates[204] = 19511;
        precalculatedRates[205] = 19416;
        precalculatedRates[206] = 19323;
        precalculatedRates[207] = 19230;
        precalculatedRates[208] = 19138;
        precalculatedRates[209] = 19047;
        precalculatedRates[210] = 18956;
        precalculatedRates[211] = 18867;
        precalculatedRates[212] = 18779;
        precalculatedRates[213] = 18691;
        precalculatedRates[214] = 18604;
        precalculatedRates[215] = 18518;
        precalculatedRates[216] = 18432;
        precalculatedRates[217] = 18348;
        precalculatedRates[218] = 18264;
        precalculatedRates[219] = 18181;
        precalculatedRates[220] = 18099;
        precalculatedRates[221] = 18017;
        precalculatedRates[222] = 17937;
        precalculatedRates[223] = 17856;
        precalculatedRates[224] = 17777;
        precalculatedRates[225] = 17698;
        precalculatedRates[226] = 17620;
        precalculatedRates[227] = 17543;
        precalculatedRates[228] = 17467;
        precalculatedRates[229] = 17391;
        precalculatedRates[230] = 17315;
        precalculatedRates[231] = 17241;
        precalculatedRates[232] = 17167;
        precalculatedRates[233] = 17093;
        precalculatedRates[234] = 17021;
        precalculatedRates[235] = 16949;
        precalculatedRates[236] = 16877;
        precalculatedRates[237] = 16806;
        precalculatedRates[238] = 16736;
        precalculatedRates[239] = 16666;
        precalculatedRates[240] = 16597;
        precalculatedRates[241] = 16528;
        precalculatedRates[242] = 16460;
        precalculatedRates[243] = 16393;
        precalculatedRates[244] = 16326;
        precalculatedRates[245] = 16260;
        precalculatedRates[246] = 16194;
        precalculatedRates[247] = 16128;
        precalculatedRates[248] = 16064;
        precalculatedRates[249] = 15999;
        precalculatedRates[250] = 15936;
        precalculatedRates[251] = 15872;
        precalculatedRates[252] = 15810;
        precalculatedRates[253] = 15747;
        precalculatedRates[254] = 15686;
        precalculatedRates[255] = 15624;
        precalculatedRates[256] = 15564;
        precalculatedRates[257] = 15503;
        precalculatedRates[258] = 15443;
        precalculatedRates[259] = 15384;
        precalculatedRates[260] = 15325;
        precalculatedRates[261] = 15267;
        precalculatedRates[262] = 15209;
        precalculatedRates[263] = 15151;
        precalculatedRates[264] = 15094;
        precalculatedRates[265] = 15037;
        precalculatedRates[266] = 14981;
        precalculatedRates[267] = 14925;
        precalculatedRates[268] = 14869;
        precalculatedRates[269] = 14814;
        precalculatedRates[270] = 14760;
        precalculatedRates[271] = 14705;
        precalculatedRates[272] = 14652;
        precalculatedRates[273] = 14598;
        precalculatedRates[274] = 14545;
        precalculatedRates[275] = 14492;
        precalculatedRates[276] = 14440;
        precalculatedRates[277] = 14388;
        precalculatedRates[278] = 14336;
        precalculatedRates[279] = 14285;
        precalculatedRates[280] = 14234;
        precalculatedRates[281] = 14184;
        precalculatedRates[282] = 14134;
        precalculatedRates[283] = 14084;
        precalculatedRates[284] = 14035;
        precalculatedRates[285] = 13986;
        precalculatedRates[286] = 13937;
        precalculatedRates[287] = 13888;
        precalculatedRates[288] = 13840;
        precalculatedRates[289] = 13793;
        precalculatedRates[290] = 13745;
        precalculatedRates[291] = 13698;
        precalculatedRates[292] = 13651;
        precalculatedRates[293] = 13605;
        precalculatedRates[294] = 13559;
        precalculatedRates[295] = 13513;
        precalculatedRates[296] = 13468;
        precalculatedRates[297] = 13422;
        precalculatedRates[298] = 13377;
        precalculatedRates[299] = 13333;
        precalculatedRates[300] = 13289;
        precalculatedRates[301] = 13245;
        precalculatedRates[302] = 13201;
        precalculatedRates[303] = 13157;
        precalculatedRates[304] = 13114;
        precalculatedRates[305] = 13071;
        precalculatedRates[306] = 13029;
        precalculatedRates[307] = 12987;
        precalculatedRates[308] = 12944;
        precalculatedRates[309] = 12903;
        precalculatedRates[310] = 12861;
        precalculatedRates[311] = 12820;
        precalculatedRates[312] = 12779;
        precalculatedRates[313] = 12738;
        precalculatedRates[314] = 12698;
        precalculatedRates[315] = 12658;
        precalculatedRates[316] = 12618;
        precalculatedRates[317] = 12578;
        precalculatedRates[318] = 12539;
        precalculatedRates[319] = 12499;
        precalculatedRates[320] = 12461;
        precalculatedRates[321] = 12422;
        precalculatedRates[322] = 12383;
        precalculatedRates[323] = 12345;
        precalculatedRates[324] = 12307;
        precalculatedRates[325] = 12269;
        precalculatedRates[326] = 12232;
        precalculatedRates[327] = 12195;
        precalculatedRates[328] = 12158;
        precalculatedRates[329] = 12121;
        precalculatedRates[330] = 12084;
        precalculatedRates[331] = 12048;
        precalculatedRates[332] = 12012;
        precalculatedRates[333] = 11976;
        precalculatedRates[334] = 11940;
        precalculatedRates[335] = 11904;
        precalculatedRates[336] = 11869;
        precalculatedRates[337] = 11834;
        precalculatedRates[338] = 11799;
        precalculatedRates[339] = 11764;
        precalculatedRates[340] = 11730;
        precalculatedRates[341] = 11695;
        precalculatedRates[342] = 11661;
        precalculatedRates[343] = 11627;
        precalculatedRates[344] = 11594;
        precalculatedRates[345] = 11560;
        precalculatedRates[346] = 11527;
        precalculatedRates[347] = 11494;
        precalculatedRates[348] = 11461;
        precalculatedRates[349] = 11428;
        precalculatedRates[350] = 11396;
        precalculatedRates[351] = 11363;
        precalculatedRates[352] = 11331;
        precalculatedRates[353] = 11299;
        precalculatedRates[354] = 11267;
        precalculatedRates[355] = 11235;
        precalculatedRates[356] = 11204;
        precalculatedRates[357] = 11173;
        precalculatedRates[358] = 11142;
        precalculatedRates[359] = 11111;
        precalculatedRates[360] = 11080;
        precalculatedRates[361] = 11049;
        precalculatedRates[362] = 11019;
        precalculatedRates[363] = 10989;
        precalculatedRates[364] = 10958;
        precalculatedRates[365] = 10928;
        precalculatedRates[366] = 10899;
        precalculatedRates[367] = 10869;
        precalculatedRates[368] = 10840;
        precalculatedRates[369] = 10810;
        precalculatedRates[370] = 10781;
        precalculatedRates[371] = 10752;
        precalculatedRates[372] = 10723;
        precalculatedRates[373] = 10695;
        precalculatedRates[374] = 10666;
        precalculatedRates[375] = 10638;
        precalculatedRates[376] = 10610;
        precalculatedRates[377] = 10582;
        precalculatedRates[378] = 10554;
        precalculatedRates[379] = 10526;
        precalculatedRates[380] = 10498;
        precalculatedRates[381] = 10471;
        precalculatedRates[382] = 10443;
        precalculatedRates[383] = 10416;
        precalculatedRates[384] = 10389;
        precalculatedRates[385] = 10362;
        precalculatedRates[386] = 10335;
        precalculatedRates[387] = 10309;
        precalculatedRates[388] = 10282;
        precalculatedRates[389] = 10256;
        precalculatedRates[390] = 10230;
        precalculatedRates[391] = 10204;
        precalculatedRates[392] = 10178;
        precalculatedRates[393] = 10152;
        precalculatedRates[394] = 10126;
        precalculatedRates[395] = 10101;
        precalculatedRates[396] = 10075;
        precalculatedRates[397] = 10050;
        precalculatedRates[398] = 10025;
        precalculatedRates[399] = 9999;
        precalculatedRates[400] = 9975;
        precalculatedRates[401] = 9950;
        precalculatedRates[402] = 9925;
        precalculatedRates[403] = 9900;
        precalculatedRates[404] = 9876;
        precalculatedRates[405] = 9852;
        precalculatedRates[406] = 9828;
        precalculatedRates[407] = 9803;
        precalculatedRates[408] = 9779;
        precalculatedRates[409] = 9756;
        precalculatedRates[410] = 9732;
        precalculatedRates[411] = 9708;
        precalculatedRates[412] = 9685;
        precalculatedRates[413] = 9661;
        precalculatedRates[414] = 9638;
        precalculatedRates[415] = 9615;
        precalculatedRates[416] = 9592;
        precalculatedRates[417] = 9569;
        precalculatedRates[418] = 9546;
        precalculatedRates[419] = 9523;
        precalculatedRates[420] = 9501;
        precalculatedRates[421] = 9478;
        precalculatedRates[422] = 9456;
        precalculatedRates[423] = 9433;
        precalculatedRates[424] = 9411;
        precalculatedRates[425] = 9389;
        precalculatedRates[426] = 9367;
        precalculatedRates[427] = 9345;
        precalculatedRates[428] = 9324;
        precalculatedRates[429] = 9302;
        precalculatedRates[430] = 9280;
        precalculatedRates[431] = 9259;
        precalculatedRates[432] = 9237;
        precalculatedRates[433] = 9216;
        precalculatedRates[434] = 9195;
        precalculatedRates[435] = 9174;
        precalculatedRates[436] = 9153;
        precalculatedRates[437] = 9132;
        precalculatedRates[438] = 9111;
        precalculatedRates[439] = 9090;
        precalculatedRates[440] = 9070;
        precalculatedRates[441] = 9049;
        precalculatedRates[442] = 9029;
        precalculatedRates[443] = 9009;
        precalculatedRates[444] = 8988;
        precalculatedRates[445] = 8968;
        precalculatedRates[446] = 8948;
        precalculatedRates[447] = 8928;
        precalculatedRates[448] = 8908;
        precalculatedRates[449] = 8888;
        precalculatedRates[450] = 8869;
        precalculatedRates[451] = 8849;
        precalculatedRates[452] = 8830;
        precalculatedRates[453] = 8810;
        precalculatedRates[454] = 8791;
        precalculatedRates[455] = 8771;
        precalculatedRates[456] = 8752;
        precalculatedRates[457] = 8733;
        precalculatedRates[458] = 8714;
        precalculatedRates[459] = 8695;
        precalculatedRates[460] = 8676;
        precalculatedRates[461] = 8658;
        precalculatedRates[462] = 8639;
        precalculatedRates[463] = 8620;
        precalculatedRates[464] = 8602;
        precalculatedRates[465] = 8583;
        precalculatedRates[466] = 8565;
        precalculatedRates[467] = 8547;
        precalculatedRates[468] = 8528;
        precalculatedRates[469] = 8510;
        precalculatedRates[470] = 8492;
        precalculatedRates[471] = 8474;
        precalculatedRates[472] = 8456;
        precalculatedRates[473] = 8438;
        precalculatedRates[474] = 8421;
        precalculatedRates[475] = 8403;
        precalculatedRates[476] = 8385;
        precalculatedRates[477] = 8368;
        precalculatedRates[478] = 8350;
        precalculatedRates[479] = 8333;
        precalculatedRates[480] = 8316;
        precalculatedRates[481] = 8298;
        precalculatedRates[482] = 8281;
        precalculatedRates[483] = 8264;
        precalculatedRates[484] = 8247;
        precalculatedRates[485] = 8230;
        precalculatedRates[486] = 8213;
        precalculatedRates[487] = 8196;
        precalculatedRates[488] = 8179;
        precalculatedRates[489] = 8163;
        precalculatedRates[490] = 8146;
        precalculatedRates[491] = 8130;
        precalculatedRates[492] = 8113;
        precalculatedRates[493] = 8097;
        precalculatedRates[494] = 8080;
        precalculatedRates[495] = 8064;
        precalculatedRates[496] = 8048;
        precalculatedRates[497] = 8032;
        precalculatedRates[498] = 8016;
        precalculatedRates[499] = 7999;
    }
}
