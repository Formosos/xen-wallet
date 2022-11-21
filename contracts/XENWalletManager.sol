// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

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
    YENCrypto public immutable yenCrypto;

    uint256 public totalWallets;
    uint256 public activeWallets;
    mapping(address => address[]) internal unmintedWallets;

    uint32[250] internal cumulativeWeeklyRewardMultiplier;

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
        yenCrypto = new YENCrypto(address(this));
        deployTimestamp = block.timestamp;

        populateRates();
    }

    // PUBLIC CONVENIENCE GETTERS

    /**
     * @dev generate a unique salt based on message sender and id value
     */
    function getSalt(uint256 id) public view returns (bytes32) {
        return keccak256(abi.encodePacked(msg.sender, id));
    }

    /**
     * @dev derive a deterministic address based on a salt value
     */
    function getDeterministicAddress(bytes32 salt)
        public
        view
        returns (address)
    {
        return implementation.predictDeterministicAddress(salt);
    }

    /**
     * @dev calculates elapsed number of weeks after contract deployment
     */
    function getElapsedWeeks() public view returns (uint256) {
        return (block.timestamp - deployTimestamp) / SECONDS_IN_WEEK;
    }

    /**
     * @dev returns wallet count associated with wallet owner
     */
    function getWalletCount(address owner) public view returns (uint256) {
        return unmintedWallets[owner].length;
    }

    /**
     * @dev returns wallet addresses based on pagination approach
     */
    function getWallets(
        address owner,
        uint256 startId,
        uint256 endId
    ) external view returns (address[] memory) {
        uint256 size = endId - startId + 1;
        address[] memory wallets = new address[](size);
        for (uint256 id = startId; id <= endId; id++) {
            wallets[id - startId] = unmintedWallets[owner][id];
        }
        return wallets;
    }

    /**
     * @dev returns Mint objects for an array of addresses
     */
    function getUserInfos(address[] calldata owners)
        external
        view
        returns (IXENCrypto.MintInfo[] memory infos)
    {
        infos = new IXENCrypto.MintInfo[](owners.length);
        for (uint256 id = 0; id < owners.length; id++) {
            infos[id] = XENWallet(owners[id]).getUserMint();
        }
    }

    /**
     * @dev returns cumulative weekly reward multiplier at a specific week index
     */
    function getCumulativeWeeklyRewardMultiplier(int256 index)
        public
        view
        returns (uint256)
    {
        if (index < 0) return 0;
        if (index >= int256(cumulativeWeeklyRewardMultiplier.length))
            return cumulativeWeeklyRewardMultiplier[249];
        return cumulativeWeeklyRewardMultiplier[uint256(index)];
    }

    /**
     * @dev returns weekly reward multiplier
     */
    function getWeeklyRewardMultiplier(int256 index)
        external
        view
        returns (uint256)
    {
        return
            getCumulativeWeeklyRewardMultiplier(index) -
            getCumulativeWeeklyRewardMultiplier(index - 1);
    }

    /**
     * @dev calculates reward multiplier
     * @param finalWeek defines the the number of weeks that has elapsed
     * @param termWeeks defines the term limit in weeks
     */
    function getRewardMultiplier(uint256 finalWeek, uint256 termWeeks)
        public
        view
        returns (uint256)
    {
        require(finalWeek + 1 >= termWeeks, "Incorrect term format");
        return
            getCumulativeWeeklyRewardMultiplier(int256(finalWeek)) -
            getCumulativeWeeklyRewardMultiplier(
                int256(finalWeek) - int256(termWeeks) - 1
            );
    }

    /**
     * @dev calculates adjusted mint amount based on reward multiplier
     * @param originalAmount defines the original amount without adjustment
     * @param termDays defines the term limit in days
     */
    function getAdjustedMintAmount(uint256 originalAmount, uint256 termDays)
        internal
        view
        virtual
        returns (uint256)
    {
        uint256 elapsedWeeks = getElapsedWeeks();
        uint256 termWeeks = termDays / 7;
        return
            (originalAmount * getRewardMultiplier(elapsedWeeks, termWeeks)) /
            1_000_000_000;
    }

    // STATE CHANGING FUNCTIONS

    /**
     * @dev create wallet using a specific index and term
     */
    function createWallet(uint256 id, uint256 term) internal {
        bytes32 salt = getSalt(id);
        XENWallet clone = XENWallet(implementation.cloneDeterministic(salt));

        clone.initialize(XENCrypto, address(this));
        clone.claimRank(term);

        unmintedWallets[msg.sender].push(address(clone));
    }

    /**
     * @dev batch create wallets with a specific term
     * @param amount defines the number of wallets
     * @param term defines the term limit in seconds
     */
    function batchCreateWallets(uint256 amount, uint256 term) external {
        require(amount >= 1, "More than one wallet");
        require(term >= MIN_TOKEN_MINT_TERM, "Too short term");

        uint256 existing = unmintedWallets[msg.sender].length;
        for (uint256 id = 0; id < amount; id++) {
            createWallet(id + existing, term);
        }

        totalWallets += amount;
        activeWallets += amount;
    }

    /**
     * @dev claims rewards and sends them to the wallet owner
     */
    function batchClaimAndTransferMintReward(uint256 startId, uint256 endId)
        external
    {
        require(endId >= startId, "Forward ordering");

        uint256 claimed = 0;
        uint256 averageTerm = 0;
        uint256 walletRange = endId - startId + 1;

        for (uint256 id = startId; id <= endId; id++) {
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
            yenCrypto.mint(msg.sender, toBeMinted - fee);
            yenCrypto.mint(feeReceiver, fee);
        }
    }

    /**
     * @dev rescues rewards which are about to expire, from the given owner
     */
    function batchClaimMintRewardRescue(
        address owner,
        uint256 startId,
        uint256 endId
    ) external onlyOwner {
        require(endId >= startId, "Forward ordering");

        IXENCrypto xenCrypto = IXENCrypto(XENCrypto);
        uint256 rescued = 0;
        uint256 averageTerm = 0;
        uint256 walletRange = endId - startId + 1;

        for (uint256 id = startId; id <= endId; id++) {
            address proxy = unmintedWallets[owner][id];

            IXENCrypto.MintInfo memory info = XENWallet(proxy).getUserMint();
            averageTerm += info.term;

            if (block.timestamp > info.maturityTs + MIN_REWARD_LIMIT) {
                rescued += XENWallet(proxy).claimAndTransferMintReward(
                    address(this)
                );
                unmintedWallets[owner][id] = address(0x0);
            }
        }

        averageTerm = averageTerm / walletRange;
        activeWallets -= walletRange;

        if (rescued > 0) {
            uint256 toBeMinted = getAdjustedMintAmount(rescued, averageTerm);
            uint256 xenFee = (rescued * RESCUE_FEE) / 10_000;
            uint256 mintFee = (toBeMinted * (RESCUE_FEE + MINT_FEE)) / 10_000;

            // Mint YEN tokens
            yenCrypto.mint(owner, toBeMinted - mintFee);
            yenCrypto.mint(feeReceiver, mintFee);

            // Transfer XEN tokens
            xenCrypto.transfer(owner, rescued - xenFee);
            xenCrypto.transfer(feeReceiver, xenFee);
        }
    }

    /**
     * @dev change fee receiver address
     */
    function changeFeeReceiver(address newReceiver) external onlyOwner {
        feeReceiver = newReceiver;
    }

    function populateRates() internal virtual {
        /*
        Precalculated values for the formula:
        // integrate 0.102586724 * 0.95^x from 0 to index
        // Calculate 5% weekly decline and compound rewards
        let current = precisionMultiplier * 0.102586724;
        let cumulative = current;
        for (let i = 0; i < elapsedWeeks; i++) {
            current = (current * 95) / 100;
            cumulative += current;
        }
        return cumulative;
        */
        cumulativeWeeklyRewardMultiplier[0] = 102586724;
        cumulativeWeeklyRewardMultiplier[1] = 200044111;
        cumulativeWeeklyRewardMultiplier[2] = 292628630;
        cumulativeWeeklyRewardMultiplier[3] = 380583922;
        cumulativeWeeklyRewardMultiplier[4] = 464141450;
        cumulativeWeeklyRewardMultiplier[5] = 543521102;
        cumulativeWeeklyRewardMultiplier[6] = 618931770;
        cumulativeWeeklyRewardMultiplier[7] = 690571906;
        cumulativeWeeklyRewardMultiplier[8] = 758630035;
        cumulativeWeeklyRewardMultiplier[9] = 823285257;
        cumulativeWeeklyRewardMultiplier[10] = 884707718;
        cumulativeWeeklyRewardMultiplier[11] = 943059056;
        cumulativeWeeklyRewardMultiplier[12] = 998492827;
        cumulativeWeeklyRewardMultiplier[13] = 1051154910;
        cumulativeWeeklyRewardMultiplier[14] = 1101183888;
        cumulativeWeeklyRewardMultiplier[15] = 1148711418;
        cumulativeWeeklyRewardMultiplier[16] = 1193862571;
        cumulativeWeeklyRewardMultiplier[17] = 1236756166;
        cumulativeWeeklyRewardMultiplier[18] = 1277505082;
        cumulativeWeeklyRewardMultiplier[19] = 1316216552;
        cumulativeWeeklyRewardMultiplier[20] = 1352992448;
        cumulativeWeeklyRewardMultiplier[21] = 1387929550;
        cumulativeWeeklyRewardMultiplier[22] = 1421119796;
        cumulativeWeeklyRewardMultiplier[23] = 1452650530;
        cumulativeWeeklyRewardMultiplier[24] = 1482604728;
        cumulativeWeeklyRewardMultiplier[25] = 1511061216;
        cumulativeWeeklyRewardMultiplier[26] = 1538094879;
        cumulativeWeeklyRewardMultiplier[27] = 1563776859;
        cumulativeWeeklyRewardMultiplier[28] = 1588174740;
        cumulativeWeeklyRewardMultiplier[29] = 1611352727;
        cumulativeWeeklyRewardMultiplier[30] = 1633371814;
        cumulativeWeeklyRewardMultiplier[31] = 1654289948;
        cumulativeWeeklyRewardMultiplier[32] = 1674162174;
        cumulativeWeeklyRewardMultiplier[33] = 1693040790;
        cumulativeWeeklyRewardMultiplier[34] = 1710975474;
        cumulativeWeeklyRewardMultiplier[35] = 1728013424;
        cumulativeWeeklyRewardMultiplier[36] = 1744199477;
        cumulativeWeeklyRewardMultiplier[37] = 1759576227;
        cumulativeWeeklyRewardMultiplier[38] = 1774184140;
        cumulativeWeeklyRewardMultiplier[39] = 1788061657;
        cumulativeWeeklyRewardMultiplier[40] = 1801245298;
        cumulativeWeeklyRewardMultiplier[41] = 1813769757;
        cumulativeWeeklyRewardMultiplier[42] = 1825667993;
        cumulativeWeeklyRewardMultiplier[43] = 1836971317;
        cumulativeWeeklyRewardMultiplier[44] = 1847709476;
        cumulativeWeeklyRewardMultiplier[45] = 1857910726;
        cumulativeWeeklyRewardMultiplier[46] = 1867601913;
        cumulativeWeeklyRewardMultiplier[47] = 1876808542;
        cumulativeWeeklyRewardMultiplier[48] = 1885554839;
        cumulativeWeeklyRewardMultiplier[49] = 1893863821;
        cumulativeWeeklyRewardMultiplier[50] = 1901757354;
        cumulativeWeeklyRewardMultiplier[51] = 1909256210;
        cumulativeWeeklyRewardMultiplier[52] = 1916380123;
        cumulativeWeeklyRewardMultiplier[53] = 1923147841;
        cumulativeWeeklyRewardMultiplier[54] = 1929577173;
        cumulativeWeeklyRewardMultiplier[55] = 1935685038;
        cumulativeWeeklyRewardMultiplier[56] = 1941487510;
        cumulativeWeeklyRewardMultiplier[57] = 1946999859;
        cumulativeWeeklyRewardMultiplier[58] = 1952236590;
        cumulativeWeeklyRewardMultiplier[59] = 1957211484;
        cumulativeWeeklyRewardMultiplier[60] = 1961937634;
        cumulativeWeeklyRewardMultiplier[61] = 1966427476;
        cumulativeWeeklyRewardMultiplier[62] = 1970692827;
        cumulativeWeeklyRewardMultiplier[63] = 1974744909;
        cumulativeWeeklyRewardMultiplier[64] = 1978594388;
        cumulativeWeeklyRewardMultiplier[65] = 1982251392;
        cumulativeWeeklyRewardMultiplier[66] = 1985725547;
        cumulativeWeeklyRewardMultiplier[67] = 1989025993;
        cumulativeWeeklyRewardMultiplier[68] = 1992161418;
        cumulativeWeeklyRewardMultiplier[69] = 1995140071;
        cumulativeWeeklyRewardMultiplier[70] = 1997969791;
        cumulativeWeeklyRewardMultiplier[71] = 2000658026;
        cumulativeWeeklyRewardMultiplier[72] = 2003211848;
        cumulativeWeeklyRewardMultiplier[73] = 2005637980;
        cumulativeWeeklyRewardMultiplier[74] = 2007942805;
        cumulativeWeeklyRewardMultiplier[75] = 2010132389;
        cumulativeWeeklyRewardMultiplier[76] = 2012212493;
        cumulativeWeeklyRewardMultiplier[77] = 2014188592;
        cumulativeWeeklyRewardMultiplier[78] = 2016065887;
        cumulativeWeeklyRewardMultiplier[79] = 2017849316;
        cumulativeWeeklyRewardMultiplier[80] = 2019543575;
        cumulativeWeeklyRewardMultiplier[81] = 2021153120;
        cumulativeWeeklyRewardMultiplier[82] = 2022682188;
        cumulativeWeeklyRewardMultiplier[83] = 2024134802;
        cumulativeWeeklyRewardMultiplier[84] = 2025514786;
        cumulativeWeeklyRewardMultiplier[85] = 2026825771;
        cumulativeWeeklyRewardMultiplier[86] = 2028071206;
        cumulativeWeeklyRewardMultiplier[87] = 2029254370;
        cumulativeWeeklyRewardMultiplier[88] = 2030378375;
        cumulativeWeeklyRewardMultiplier[89] = 2031446181;
        cumulativeWeeklyRewardMultiplier[90] = 2032460596;
        cumulativeWeeklyRewardMultiplier[91] = 2033424290;
        cumulativeWeeklyRewardMultiplier[92] = 2034339799;
        cumulativeWeeklyRewardMultiplier[93] = 2035209533;
        cumulativeWeeklyRewardMultiplier[94] = 2036035781;
        cumulativeWeeklyRewardMultiplier[95] = 2036820716;
        cumulativeWeeklyRewardMultiplier[96] = 2037566404;
        cumulativeWeeklyRewardMultiplier[97] = 2038274808;
        cumulativeWeeklyRewardMultiplier[98] = 2038947791;
        cumulativeWeeklyRewardMultiplier[99] = 2039587126;
        cumulativeWeeklyRewardMultiplier[100] = 2040194493;
        cumulativeWeeklyRewardMultiplier[101] = 2040771493;
        cumulativeWeeklyRewardMultiplier[102] = 2041319642;
        cumulativeWeeklyRewardMultiplier[103] = 2041840384;
        cumulativeWeeklyRewardMultiplier[104] = 2042335089;
        cumulativeWeeklyRewardMultiplier[105] = 2042805058;
        cumulativeWeeklyRewardMultiplier[106] = 2043251529;
        cumulativeWeeklyRewardMultiplier[107] = 2043675677;
        cumulativeWeeklyRewardMultiplier[108] = 2044078617;
        cumulativeWeeklyRewardMultiplier[109] = 2044461410;
        cumulativeWeeklyRewardMultiplier[110] = 2044825063;
        cumulativeWeeklyRewardMultiplier[111] = 2045170534;
        cumulativeWeeklyRewardMultiplier[112] = 2045498732;
        cumulativeWeeklyRewardMultiplier[113] = 2045810519;
        cumulativeWeeklyRewardMultiplier[114] = 2046106717;
        cumulativeWeeklyRewardMultiplier[115] = 2046388105;
        cumulativeWeeklyRewardMultiplier[116] = 2046655424;
        cumulativeWeeklyRewardMultiplier[117] = 2046909377;
        cumulativeWeeklyRewardMultiplier[118] = 2047150632;
        cumulativeWeeklyRewardMultiplier[119] = 2047379824;
        cumulativeWeeklyRewardMultiplier[120] = 2047597557;
        cumulativeWeeklyRewardMultiplier[121] = 2047804403;
        cumulativeWeeklyRewardMultiplier[122] = 2048000907;
        cumulativeWeeklyRewardMultiplier[123] = 2048187585;
        cumulativeWeeklyRewardMultiplier[124] = 2048364930;
        cumulativeWeeklyRewardMultiplier[125] = 2048533408;
        cumulativeWeeklyRewardMultiplier[126] = 2048693461;
        cumulativeWeeklyRewardMultiplier[127] = 2048845512;
        cumulativeWeeklyRewardMultiplier[128] = 2048989961;
        cumulativeWeeklyRewardMultiplier[129] = 2049127186;
        cumulativeWeeklyRewardMultiplier[130] = 2049257551;
        cumulativeWeeklyRewardMultiplier[131] = 2049381398;
        cumulativeWeeklyRewardMultiplier[132] = 2049499052;
        cumulativeWeeklyRewardMultiplier[133] = 2049610823;
        cumulativeWeeklyRewardMultiplier[134] = 2049717006;
        cumulativeWeeklyRewardMultiplier[135] = 2049817880;
        cumulativeWeeklyRewardMultiplier[136] = 2049913710;
        cumulativeWeeklyRewardMultiplier[137] = 2050004748;
        cumulativeWeeklyRewardMultiplier[138] = 2050091235;
        cumulativeWeeklyRewardMultiplier[139] = 2050173397;
        cumulativeWeeklyRewardMultiplier[140] = 2050251451;
        cumulativeWeeklyRewardMultiplier[141] = 2050325602;
        cumulativeWeeklyRewardMultiplier[142] = 2050396046;
        cumulativeWeeklyRewardMultiplier[143] = 2050462968;
        cumulativeWeeklyRewardMultiplier[144] = 2050526544;
        cumulativeWeeklyRewardMultiplier[145] = 2050586940;
        cumulativeWeeklyRewardMultiplier[146] = 2050644317;
        cumulativeWeeklyRewardMultiplier[147] = 2050698825;
        cumulativeWeeklyRewardMultiplier[148] = 2050750608;
        cumulativeWeeklyRewardMultiplier[149] = 2050799802;
        cumulativeWeeklyRewardMultiplier[150] = 2050846536;
        cumulativeWeeklyRewardMultiplier[151] = 2050890933;
        cumulativeWeeklyRewardMultiplier[152] = 2050933110;
        cumulativeWeeklyRewardMultiplier[153] = 2050973179;
        cumulativeWeeklyRewardMultiplier[154] = 2051011244;
        cumulativeWeeklyRewardMultiplier[155] = 2051047405;
        cumulativeWeeklyRewardMultiplier[156] = 2051081759;
        cumulativeWeeklyRewardMultiplier[157] = 2051114395;
        cumulativeWeeklyRewardMultiplier[158] = 2051145399;
        cumulativeWeeklyRewardMultiplier[159] = 2051174853;
        cumulativeWeeklyRewardMultiplier[160] = 2051202835;
        cumulativeWeeklyRewardMultiplier[161] = 2051229417;
        cumulativeWeeklyRewardMultiplier[162] = 2051254670;
        cumulativeWeeklyRewardMultiplier[163] = 2051278660;
        cumulativeWeeklyRewardMultiplier[164] = 2051301451;
        cumulativeWeeklyRewardMultiplier[165] = 2051323103;
        cumulativeWeeklyRewardMultiplier[166] = 2051343672;
        cumulativeWeeklyRewardMultiplier[167] = 2051363212;
        cumulativeWeeklyRewardMultiplier[168] = 2051381775;
        cumulativeWeeklyRewardMultiplier[169] = 2051399411;
        cumulativeWeeklyRewardMultiplier[170] = 2051416164;
        cumulativeWeeklyRewardMultiplier[171] = 2051432080;
        cumulativeWeeklyRewardMultiplier[172] = 2051447200;
        cumulativeWeeklyRewardMultiplier[173] = 2051461564;
        cumulativeWeeklyRewardMultiplier[174] = 2051475210;
        cumulativeWeeklyRewardMultiplier[175] = 2051488173;
        cumulativeWeeklyRewardMultiplier[176] = 2051500488;
        cumulativeWeeklyRewardMultiplier[177] = 2051512188;
        cumulativeWeeklyRewardMultiplier[178] = 2051523303;
        cumulativeWeeklyRewardMultiplier[179] = 2051533861;
        cumulativeWeeklyRewardMultiplier[180] = 2051543892;
        cumulativeWeeklyRewardMultiplier[181] = 2051553422;
        cumulativeWeeklyRewardMultiplier[182] = 2051562475;
        cumulativeWeeklyRewardMultiplier[183] = 2051571075;
        cumulativeWeeklyRewardMultiplier[184] = 2051579245;
        cumulativeWeeklyRewardMultiplier[185] = 2051587007;
        cumulativeWeeklyRewardMultiplier[186] = 2051594380;
        cumulativeWeeklyRewardMultiplier[187] = 2051601385;
        cumulativeWeeklyRewardMultiplier[188] = 2051608040;
        cumulativeWeeklyRewardMultiplier[189] = 2051614362;
        cumulativeWeeklyRewardMultiplier[190] = 2051620368;
        cumulativeWeeklyRewardMultiplier[191] = 2051626073;
        cumulativeWeeklyRewardMultiplier[192] = 2051631494;
        cumulativeWeeklyRewardMultiplier[193] = 2051636643;
        cumulativeWeeklyRewardMultiplier[194] = 2051641535;
        cumulativeWeeklyRewardMultiplier[195] = 2051646182;
        cumulativeWeeklyRewardMultiplier[196] = 2051650597;
        cumulativeWeeklyRewardMultiplier[197] = 2051654791;
        cumulativeWeeklyRewardMultiplier[198] = 2051658776;
        cumulativeWeeklyRewardMultiplier[199] = 2051662561;
        cumulativeWeeklyRewardMultiplier[200] = 2051666157;
        cumulativeWeeklyRewardMultiplier[201] = 2051669573;
        cumulativeWeeklyRewardMultiplier[202] = 2051672818;
        cumulativeWeeklyRewardMultiplier[203] = 2051675901;
        cumulativeWeeklyRewardMultiplier[204] = 2051678830;
        cumulativeWeeklyRewardMultiplier[205] = 2051681613;
        cumulativeWeeklyRewardMultiplier[206] = 2051684256;
        cumulativeWeeklyRewardMultiplier[207] = 2051686767;
        cumulativeWeeklyRewardMultiplier[208] = 2051689153;
        cumulativeWeeklyRewardMultiplier[209] = 2051691419;
        cumulativeWeeklyRewardMultiplier[210] = 2051693572;
        cumulativeWeeklyRewardMultiplier[211] = 2051695617;
        cumulativeWeeklyRewardMultiplier[212] = 2051697561;
        cumulativeWeeklyRewardMultiplier[213] = 2051699407;
        cumulativeWeeklyRewardMultiplier[214] = 2051701160;
        cumulativeWeeklyRewardMultiplier[215] = 2051702826;
        cumulativeWeeklyRewardMultiplier[216] = 2051704409;
        cumulativeWeeklyRewardMultiplier[217] = 2051705912;
        cumulativeWeeklyRewardMultiplier[218] = 2051707341;
        cumulativeWeeklyRewardMultiplier[219] = 2051708698;
        cumulativeWeeklyRewardMultiplier[220] = 2051709987;
        cumulativeWeeklyRewardMultiplier[221] = 2051711211;
        cumulativeWeeklyRewardMultiplier[222] = 2051712375;
        cumulativeWeeklyRewardMultiplier[223] = 2051713480;
        cumulativeWeeklyRewardMultiplier[224] = 2051714530;
        cumulativeWeeklyRewardMultiplier[225] = 2051715527;
        cumulativeWeeklyRewardMultiplier[226] = 2051716475;
        cumulativeWeeklyRewardMultiplier[227] = 2051717375;
        cumulativeWeeklyRewardMultiplier[228] = 2051718230;
        cumulativeWeeklyRewardMultiplier[229] = 2051719043;
        cumulativeWeeklyRewardMultiplier[230] = 2051719815;
        cumulativeWeeklyRewardMultiplier[231] = 2051720548;
        cumulativeWeeklyRewardMultiplier[232] = 2051721245;
        cumulativeWeeklyRewardMultiplier[233] = 2051721906;
        cumulativeWeeklyRewardMultiplier[234] = 2051722535;
        cumulativeWeeklyRewardMultiplier[235] = 2051723132;
        cumulativeWeeklyRewardMultiplier[236] = 2051723700;
        cumulativeWeeklyRewardMultiplier[237] = 2051724239;
        cumulativeWeeklyRewardMultiplier[238] = 2051724751;
        cumulativeWeeklyRewardMultiplier[239] = 2051725237;
        cumulativeWeeklyRewardMultiplier[240] = 2051725699;
        cumulativeWeeklyRewardMultiplier[241] = 2051726138;
        cumulativeWeeklyRewardMultiplier[242] = 2051726555;
        cumulativeWeeklyRewardMultiplier[243] = 2051726951;
        cumulativeWeeklyRewardMultiplier[244] = 2051727328;
        cumulativeWeeklyRewardMultiplier[245] = 2051727685;
        cumulativeWeeklyRewardMultiplier[246] = 2051728025;
        cumulativeWeeklyRewardMultiplier[247] = 2051728348;
        cumulativeWeeklyRewardMultiplier[248] = 2051728654;
        cumulativeWeeklyRewardMultiplier[249] = 2051728946;
    }
}
