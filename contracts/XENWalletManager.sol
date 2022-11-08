// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./interfaces/IXENCrypto.sol";
import "./XENWallet.sol";
import "./YENCrypto.sol";

contract XENWalletManager is Ownable {
    using Clones for address;

    address public feeReceiver;
    address internal immutable implementation;
    address public immutable XENCrypto;
    uint256 public immutable deployTimestamp;
    YENCrypto public immutable ownToken;

    uint256 public totalWallets;
    uint256 public activeWallets;
    mapping(address => address[]) internal unmintedWallets;

    uint32[250] internal weeklyRewardMultiplier;

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

    /// @notice Number of elapsed weeks after deployment
    function getElapsedWeeks() public view returns (uint256) {
        return (block.timestamp - deployTimestamp) / SECONDS_IN_WEEK;
    }

    /// @dev Get number of active mint wallets
    function getActiveWallets() external view returns (uint256) {
        return activeWallets;
    }

    /// @dev Get number of wallets that have batch minted
    function getTotalWallets() external view returns (uint256) {
        return totalWallets;
    }

    /// @dev Get wallet count for a wallet owner
    function getWalletCount(address _owner) public view returns (uint256) {
        return unmintedWallets[_owner].length;
    }

    /// @dev Get wallets using pagination approach
    function getWallets(
        address _owner,
        uint256 _startId,
        uint256 _endId
    ) external view returns (address[] memory) {
        uint256 size = _endId - _startId + 1;
        address[] memory wallets = new address[](size);
        for (uint256 id = _startId; id <= _endId; id++) {
            wallets[id - _startId] = unmintedWallets[_owner][id];
        }
        return wallets;
    }

    /// @notice Mint infos for an array of addresses
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

    /// @notice Limits range for reward multiplier
    /// @return Returns weekly reward multiplier at specific week
    function getWeeklyRewardMultiplier(int256 _index)
        internal
        view
        virtual
        returns (uint256)
    {
        if (_index < 0) return 0;
        if (_index >= int256(weeklyRewardMultiplier.length))
            return weeklyRewardMultiplier[249];
        return weeklyRewardMultiplier[uint256(_index)];
    }

    /// @notice Calculates reward multiplier
    /// @dev Exposes reward multiplier to frontend
    /// @param _elapsedWeeks The number of weeks that has elapsed
    /// @param _termWeeks The term limit in weeks
    function getRewardMultiplier(uint256 _elapsedWeeks, uint256 _termWeeks)
        public
        view
        returns (uint256)
    {
        require(_elapsedWeeks >= _termWeeks, "Incorrect term format");
        return
            getWeeklyRewardMultiplier(int256(_elapsedWeeks)) -
            getWeeklyRewardMultiplier(int256(_elapsedWeeks - _termWeeks) - 1);
    }

    /// @notice Get adjusted mint amount based on reward multiplier
    /// @param _originalAmount The original mint amount without adjustment
    /// @param _termSeconds The term limit in seconds
    function getAdjustedMintAmount(
        uint256 _originalAmount,
        uint256 _termSeconds
    ) internal view virtual returns (uint256) {
        uint256 elapsedWeeks = getElapsedWeeks();
        uint256 termWeeks = _termSeconds / SECONDS_IN_WEEK;
        return
            (_originalAmount * getRewardMultiplier(elapsedWeeks, termWeeks)) /
            1_000_000_000;
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
        require(term >= MIN_TOKEN_MINT_TERM, "Too short term");

        uint256 existing = unmintedWallets[msg.sender].length;
        for (uint256 id = 0; id < amount; id++) {
            createWallet(id + existing, term);
        }

        totalWallets += amount;
        activeWallets += amount;
    }

    // Claims rewards and sends them to the wallet owner
    function batchClaimAndTransferMintReward(uint256 _startId, uint256 _endId)
        external
    {
        require(_endId >= _startId, "Forward ordering");

        uint256 claimed = 0;
        uint256 averageTerm = 0;
        uint256 walletRange = _endId - _startId + 1;

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = unmintedWallets[msg.sender][id];

            IXENCrypto.MintInfo memory info = XENWallet(proxy).getUserMint();
            averageTerm += info.term;

            claimed += XENWallet(proxy).claimAndTransferMintReward(msg.sender);
            unmintedWallets[msg.sender][id] = address(0x0);
        }

        averageTerm = averageTerm / walletRange;
        activeWallets -= walletRange;

        if (claimed > 0) {
            uint256 toBeMinted = getAdjustedMintAmount(claimed, averageTerm);
            uint256 fee = (toBeMinted * MINT_FEE) / 10_000; // reduce minting fee
            ownToken.mint(msg.sender, toBeMinted - fee);
            ownToken.mint(feeReceiver, fee);
        }
    }

    function batchClaimMintRewardRescue(
        address walletOwner,
        uint256 _startId,
        uint256 _endId
    ) external onlyOwner {
        require(_endId >= _startId, "Forward ordering");

        IXENCrypto xenCrypto = IXENCrypto(XENCrypto);
        uint256 rescued = 0;
        uint256 averageTerm = 0;
        uint256 walletRange = _endId - _startId + 1;

        for (uint256 id = _startId; id <= _endId; id++) {
            address proxy = unmintedWallets[walletOwner][id];

            IXENCrypto.MintInfo memory info = XENWallet(proxy).getUserMint();
            averageTerm += info.term;

            if (block.timestamp > info.maturityTs + MIN_REWARD_LIMIT) {
                rescued += XENWallet(proxy).claimAndTransferMintReward(
                    address(this)
                );
                unmintedWallets[walletOwner][id] = address(0x0);
            }
        }

        averageTerm = averageTerm / walletRange;
        activeWallets -= walletRange;

        if (rescued > 0) {
            uint256 toBeMinted = getAdjustedMintAmount(rescued, averageTerm);

            uint256 xenFee = (rescued * RESCUE_FEE) / 10_000;
            uint256 mintFee = (toBeMinted * (RESCUE_FEE + MINT_FEE)) / 10_000;

            // Transfer XEN and own token

            ownToken.mint(walletOwner, toBeMinted - mintFee);
            ownToken.mint(feeReceiver, mintFee);

            xenCrypto.transfer(walletOwner, rescued - xenFee);
            xenCrypto.transfer(feeReceiver, xenFee);
        }
    }

    function changeFeeReceiver(address newReceiver) external onlyOwner {
        feeReceiver = newReceiver;
    }

    function populateRates() internal virtual {
        /*
        Precalculated values for the formula:
        // integrate 0.102586724 * 0.95^x from 0 to index
        // Calculate 5% weekly decline and compound rewards
        let _current = _precisionMultiplier * 0.102586724;
        let _cumulative = _current;
        for (let i = 0; i < _elapsedWeeks; ++i) {
            _current = (_current * 95) / 100;
            _cumulative += _current;
        }
        return _cumulative;
        */
        weeklyRewardMultiplier[0] = 102586724;
        weeklyRewardMultiplier[1] = 200044111;
        weeklyRewardMultiplier[2] = 292628630;
        weeklyRewardMultiplier[3] = 380583922;
        weeklyRewardMultiplier[4] = 464141450;
        weeklyRewardMultiplier[5] = 543521102;
        weeklyRewardMultiplier[6] = 618931770;
        weeklyRewardMultiplier[7] = 690571906;
        weeklyRewardMultiplier[8] = 758630035;
        weeklyRewardMultiplier[9] = 823285257;
        weeklyRewardMultiplier[10] = 884707718;
        weeklyRewardMultiplier[11] = 943059056;
        weeklyRewardMultiplier[12] = 998492827;
        weeklyRewardMultiplier[13] = 1051154910;
        weeklyRewardMultiplier[14] = 1101183888;
        weeklyRewardMultiplier[15] = 1148711418;
        weeklyRewardMultiplier[16] = 1193862571;
        weeklyRewardMultiplier[17] = 1236756166;
        weeklyRewardMultiplier[18] = 1277505082;
        weeklyRewardMultiplier[19] = 1316216552;
        weeklyRewardMultiplier[20] = 1352992448;
        weeklyRewardMultiplier[21] = 1387929550;
        weeklyRewardMultiplier[22] = 1421119796;
        weeklyRewardMultiplier[23] = 1452650530;
        weeklyRewardMultiplier[24] = 1482604728;
        weeklyRewardMultiplier[25] = 1511061216;
        weeklyRewardMultiplier[26] = 1538094879;
        weeklyRewardMultiplier[27] = 1563776859;
        weeklyRewardMultiplier[28] = 1588174740;
        weeklyRewardMultiplier[29] = 1611352727;
        weeklyRewardMultiplier[30] = 1633371814;
        weeklyRewardMultiplier[31] = 1654289948;
        weeklyRewardMultiplier[32] = 1674162174;
        weeklyRewardMultiplier[33] = 1693040790;
        weeklyRewardMultiplier[34] = 1710975474;
        weeklyRewardMultiplier[35] = 1728013424;
        weeklyRewardMultiplier[36] = 1744199477;
        weeklyRewardMultiplier[37] = 1759576227;
        weeklyRewardMultiplier[38] = 1774184140;
        weeklyRewardMultiplier[39] = 1788061657;
        weeklyRewardMultiplier[40] = 1801245298;
        weeklyRewardMultiplier[41] = 1813769757;
        weeklyRewardMultiplier[42] = 1825667993;
        weeklyRewardMultiplier[43] = 1836971317;
        weeklyRewardMultiplier[44] = 1847709476;
        weeklyRewardMultiplier[45] = 1857910726;
        weeklyRewardMultiplier[46] = 1867601913;
        weeklyRewardMultiplier[47] = 1876808542;
        weeklyRewardMultiplier[48] = 1885554839;
        weeklyRewardMultiplier[49] = 1893863821;
        weeklyRewardMultiplier[50] = 1901757354;
        weeklyRewardMultiplier[51] = 1909256210;
        weeklyRewardMultiplier[52] = 1916380123;
        weeklyRewardMultiplier[53] = 1923147841;
        weeklyRewardMultiplier[54] = 1929577173;
        weeklyRewardMultiplier[55] = 1935685038;
        weeklyRewardMultiplier[56] = 1941487510;
        weeklyRewardMultiplier[57] = 1946999859;
        weeklyRewardMultiplier[58] = 1952236590;
        weeklyRewardMultiplier[59] = 1957211484;
        weeklyRewardMultiplier[60] = 1961937634;
        weeklyRewardMultiplier[61] = 1966427476;
        weeklyRewardMultiplier[62] = 1970692827;
        weeklyRewardMultiplier[63] = 1974744909;
        weeklyRewardMultiplier[64] = 1978594388;
        weeklyRewardMultiplier[65] = 1982251392;
        weeklyRewardMultiplier[66] = 1985725547;
        weeklyRewardMultiplier[67] = 1989025993;
        weeklyRewardMultiplier[68] = 1992161418;
        weeklyRewardMultiplier[69] = 1995140071;
        weeklyRewardMultiplier[70] = 1997969791;
        weeklyRewardMultiplier[71] = 2000658026;
        weeklyRewardMultiplier[72] = 2003211848;
        weeklyRewardMultiplier[73] = 2005637980;
        weeklyRewardMultiplier[74] = 2007942805;
        weeklyRewardMultiplier[75] = 2010132389;
        weeklyRewardMultiplier[76] = 2012212493;
        weeklyRewardMultiplier[77] = 2014188592;
        weeklyRewardMultiplier[78] = 2016065887;
        weeklyRewardMultiplier[79] = 2017849316;
        weeklyRewardMultiplier[80] = 2019543575;
        weeklyRewardMultiplier[81] = 2021153120;
        weeklyRewardMultiplier[82] = 2022682188;
        weeklyRewardMultiplier[83] = 2024134802;
        weeklyRewardMultiplier[84] = 2025514786;
        weeklyRewardMultiplier[85] = 2026825771;
        weeklyRewardMultiplier[86] = 2028071206;
        weeklyRewardMultiplier[87] = 2029254370;
        weeklyRewardMultiplier[88] = 2030378375;
        weeklyRewardMultiplier[89] = 2031446181;
        weeklyRewardMultiplier[90] = 2032460596;
        weeklyRewardMultiplier[91] = 2033424290;
        weeklyRewardMultiplier[92] = 2034339799;
        weeklyRewardMultiplier[93] = 2035209533;
        weeklyRewardMultiplier[94] = 2036035781;
        weeklyRewardMultiplier[95] = 2036820716;
        weeklyRewardMultiplier[96] = 2037566404;
        weeklyRewardMultiplier[97] = 2038274808;
        weeklyRewardMultiplier[98] = 2038947791;
        weeklyRewardMultiplier[99] = 2039587126;
        weeklyRewardMultiplier[100] = 2040194493;
        weeklyRewardMultiplier[101] = 2040771493;
        weeklyRewardMultiplier[102] = 2041319642;
        weeklyRewardMultiplier[103] = 2041840384;
        weeklyRewardMultiplier[104] = 2042335089;
        weeklyRewardMultiplier[105] = 2042805058;
        weeklyRewardMultiplier[106] = 2043251529;
        weeklyRewardMultiplier[107] = 2043675677;
        weeklyRewardMultiplier[108] = 2044078617;
        weeklyRewardMultiplier[109] = 2044461410;
        weeklyRewardMultiplier[110] = 2044825063;
        weeklyRewardMultiplier[111] = 2045170534;
        weeklyRewardMultiplier[112] = 2045498732;
        weeklyRewardMultiplier[113] = 2045810519;
        weeklyRewardMultiplier[114] = 2046106717;
        weeklyRewardMultiplier[115] = 2046388105;
        weeklyRewardMultiplier[116] = 2046655424;
        weeklyRewardMultiplier[117] = 2046909377;
        weeklyRewardMultiplier[118] = 2047150632;
        weeklyRewardMultiplier[119] = 2047379824;
        weeklyRewardMultiplier[120] = 2047597557;
        weeklyRewardMultiplier[121] = 2047804403;
        weeklyRewardMultiplier[122] = 2048000907;
        weeklyRewardMultiplier[123] = 2048187585;
        weeklyRewardMultiplier[124] = 2048364930;
        weeklyRewardMultiplier[125] = 2048533408;
        weeklyRewardMultiplier[126] = 2048693461;
        weeklyRewardMultiplier[127] = 2048845512;
        weeklyRewardMultiplier[128] = 2048989961;
        weeklyRewardMultiplier[129] = 2049127186;
        weeklyRewardMultiplier[130] = 2049257551;
        weeklyRewardMultiplier[131] = 2049381398;
        weeklyRewardMultiplier[132] = 2049499052;
        weeklyRewardMultiplier[133] = 2049610823;
        weeklyRewardMultiplier[134] = 2049717006;
        weeklyRewardMultiplier[135] = 2049817880;
        weeklyRewardMultiplier[136] = 2049913710;
        weeklyRewardMultiplier[137] = 2050004748;
        weeklyRewardMultiplier[138] = 2050091235;
        weeklyRewardMultiplier[139] = 2050173397;
        weeklyRewardMultiplier[140] = 2050251451;
        weeklyRewardMultiplier[141] = 2050325602;
        weeklyRewardMultiplier[142] = 2050396046;
        weeklyRewardMultiplier[143] = 2050462968;
        weeklyRewardMultiplier[144] = 2050526544;
        weeklyRewardMultiplier[145] = 2050586940;
        weeklyRewardMultiplier[146] = 2050644317;
        weeklyRewardMultiplier[147] = 2050698825;
        weeklyRewardMultiplier[148] = 2050750608;
        weeklyRewardMultiplier[149] = 2050799802;
        weeklyRewardMultiplier[150] = 2050846536;
        weeklyRewardMultiplier[151] = 2050890933;
        weeklyRewardMultiplier[152] = 2050933110;
        weeklyRewardMultiplier[153] = 2050973179;
        weeklyRewardMultiplier[154] = 2051011244;
        weeklyRewardMultiplier[155] = 2051047405;
        weeklyRewardMultiplier[156] = 2051081759;
        weeklyRewardMultiplier[157] = 2051114395;
        weeklyRewardMultiplier[158] = 2051145399;
        weeklyRewardMultiplier[159] = 2051174853;
        weeklyRewardMultiplier[160] = 2051202835;
        weeklyRewardMultiplier[161] = 2051229417;
        weeklyRewardMultiplier[162] = 2051254670;
        weeklyRewardMultiplier[163] = 2051278660;
        weeklyRewardMultiplier[164] = 2051301451;
        weeklyRewardMultiplier[165] = 2051323103;
        weeklyRewardMultiplier[166] = 2051343672;
        weeklyRewardMultiplier[167] = 2051363212;
        weeklyRewardMultiplier[168] = 2051381775;
        weeklyRewardMultiplier[169] = 2051399411;
        weeklyRewardMultiplier[170] = 2051416164;
        weeklyRewardMultiplier[171] = 2051432080;
        weeklyRewardMultiplier[172] = 2051447200;
        weeklyRewardMultiplier[173] = 2051461564;
        weeklyRewardMultiplier[174] = 2051475210;
        weeklyRewardMultiplier[175] = 2051488173;
        weeklyRewardMultiplier[176] = 2051500488;
        weeklyRewardMultiplier[177] = 2051512188;
        weeklyRewardMultiplier[178] = 2051523303;
        weeklyRewardMultiplier[179] = 2051533861;
        weeklyRewardMultiplier[180] = 2051543892;
        weeklyRewardMultiplier[181] = 2051553422;
        weeklyRewardMultiplier[182] = 2051562475;
        weeklyRewardMultiplier[183] = 2051571075;
        weeklyRewardMultiplier[184] = 2051579245;
        weeklyRewardMultiplier[185] = 2051587007;
        weeklyRewardMultiplier[186] = 2051594380;
        weeklyRewardMultiplier[187] = 2051601385;
        weeklyRewardMultiplier[188] = 2051608040;
        weeklyRewardMultiplier[189] = 2051614362;
        weeklyRewardMultiplier[190] = 2051620368;
        weeklyRewardMultiplier[191] = 2051626073;
        weeklyRewardMultiplier[192] = 2051631494;
        weeklyRewardMultiplier[193] = 2051636643;
        weeklyRewardMultiplier[194] = 2051641535;
        weeklyRewardMultiplier[195] = 2051646182;
        weeklyRewardMultiplier[196] = 2051650597;
        weeklyRewardMultiplier[197] = 2051654791;
        weeklyRewardMultiplier[198] = 2051658776;
        weeklyRewardMultiplier[199] = 2051662561;
        weeklyRewardMultiplier[200] = 2051666157;
        weeklyRewardMultiplier[201] = 2051669573;
        weeklyRewardMultiplier[202] = 2051672818;
        weeklyRewardMultiplier[203] = 2051675901;
        weeklyRewardMultiplier[204] = 2051678830;
        weeklyRewardMultiplier[205] = 2051681613;
        weeklyRewardMultiplier[206] = 2051684256;
        weeklyRewardMultiplier[207] = 2051686767;
        weeklyRewardMultiplier[208] = 2051689153;
        weeklyRewardMultiplier[209] = 2051691419;
        weeklyRewardMultiplier[210] = 2051693572;
        weeklyRewardMultiplier[211] = 2051695617;
        weeklyRewardMultiplier[212] = 2051697561;
        weeklyRewardMultiplier[213] = 2051699407;
        weeklyRewardMultiplier[214] = 2051701160;
        weeklyRewardMultiplier[215] = 2051702826;
        weeklyRewardMultiplier[216] = 2051704409;
        weeklyRewardMultiplier[217] = 2051705912;
        weeklyRewardMultiplier[218] = 2051707341;
        weeklyRewardMultiplier[219] = 2051708698;
        weeklyRewardMultiplier[220] = 2051709987;
        weeklyRewardMultiplier[221] = 2051711211;
        weeklyRewardMultiplier[222] = 2051712375;
        weeklyRewardMultiplier[223] = 2051713480;
        weeklyRewardMultiplier[224] = 2051714530;
        weeklyRewardMultiplier[225] = 2051715527;
        weeklyRewardMultiplier[226] = 2051716475;
        weeklyRewardMultiplier[227] = 2051717375;
        weeklyRewardMultiplier[228] = 2051718230;
        weeklyRewardMultiplier[229] = 2051719043;
        weeklyRewardMultiplier[230] = 2051719815;
        weeklyRewardMultiplier[231] = 2051720548;
        weeklyRewardMultiplier[232] = 2051721245;
        weeklyRewardMultiplier[233] = 2051721906;
        weeklyRewardMultiplier[234] = 2051722535;
        weeklyRewardMultiplier[235] = 2051723132;
        weeklyRewardMultiplier[236] = 2051723700;
        weeklyRewardMultiplier[237] = 2051724239;
        weeklyRewardMultiplier[238] = 2051724751;
        weeklyRewardMultiplier[239] = 2051725237;
        weeklyRewardMultiplier[240] = 2051725699;
        weeklyRewardMultiplier[241] = 2051726138;
        weeklyRewardMultiplier[242] = 2051726555;
        weeklyRewardMultiplier[243] = 2051726951;
        weeklyRewardMultiplier[244] = 2051727328;
        weeklyRewardMultiplier[245] = 2051727685;
        weeklyRewardMultiplier[246] = 2051728025;
        weeklyRewardMultiplier[247] = 2051728348;
        weeklyRewardMultiplier[248] = 2051728654;
        weeklyRewardMultiplier[249] = 2051728946;
    }
}
