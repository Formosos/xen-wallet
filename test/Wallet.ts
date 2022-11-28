import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  YENCrypto,
  XENCrypto,
  XENWallet,
  XENWalletManager,
  MockManager,
} from "../typechain-types";
import { PANIC_CODES } from "@nomicfoundation/hardhat-chai-matchers/panic";

describe("Wallet", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployWalletFixture() {
    // Contracts are deployed using the first signer/account by default
    const [_deployer, _feeReceiver, _user2] = await ethers.getSigners();

    const MathLib = await ethers.getContractFactory("Math");
    const _math = await MathLib.connect(_deployer).deploy();

    const XEN = await ethers.getContractFactory("XENCrypto", {
      libraries: {
        Math: _math.address,
      },
    });
    const _xen = await XEN.connect(_deployer).deploy();

    const Wallet = await ethers.getContractFactory("XENWallet");
    const _wallet = await Wallet.connect(_deployer).deploy();
    await _wallet.initialize(_xen.address, _deployer.address);

    const Manager = await ethers.getContractFactory("MockManager");
    const _manager = await Manager.connect(_deployer).deploy(
      _xen.address,
      _wallet.address,
      _feeReceiver.address
    );

    const YEN = await _manager.yenCrypto();
    const _yen = await ethers.getContractAt("YENCrypto", YEN);

    return { _xen, _wallet, _manager, _yen, _deployer, _feeReceiver, _user2 };
  }

  let xen: XENCrypto,
    wallet: XENWallet,
    manager: MockManager,
    yen: YENCrypto,
    deployer: SignerWithAddress,
    feeReceiver: SignerWithAddress,
    user2: SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _manager, _yen, _deployer, _feeReceiver, _user2 } =
      await loadFixture(deployWalletFixture);

    xen = _xen;
    wallet = _wallet;
    manager = _manager;
    yen = _yen;
    deployer = _deployer;
    feeReceiver = _feeReceiver;
    user2 = _user2;
  });

  describe("Deployment", function () {
    it("Should set the right values", async function () {
      const walletXen = await wallet.XENCrypto();
      const factoryXen = await manager.XENCrypto();
      const factoryDeployer = await manager.owner();
      const factoryImplementation = await manager.getImplementation();

      expect(walletXen).to.equal(xen.address);
      expect(factoryXen).to.equal(xen.address);
      expect(factoryDeployer).to.equal(deployer.address);
      expect(factoryImplementation).to.equal(wallet.address);
      expect(yen).to.not.empty;
    });
  });

  describe("Fee receiver update", function () {
    it("works", async function () {
      await manager.connect(deployer).changeFeeReceiver(user2.address);
      const feeRec = await manager.feeReceiver();

      expect(feeRec).to.equal(user2.address);
    });

    it("fails if not owner", async function () {
      await expect(
        manager.connect(feeReceiver).changeFeeReceiver(user2.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Wallet creation", function () {
    const day = 24 * 60 * 60;
    beforeEach(async function () {});

    it("sets the right data", async function () {
      await manager.batchCreateWallets(1, 50);

      const walletAddress = await manager.getDeterministicAddress(
        manager.getSalt(0)
      );
      const wallet = await ethers.getContractAt("XENWallet", walletAddress);

      const managerAddress = await wallet.manager();
      const xenAddress = await wallet.XENCrypto();

      expect(managerAddress).to.equal(manager.address);
      expect(xenAddress).to.equal(xen.address);
    });

    it("can create more wallets", async function () {
      await manager.batchCreateWallets(5, 50);
      await manager.batchCreateWallets(3, 50);

      const numWallets = await manager.activeWallets();
      expect(numWallets).to.equal(8);

      const wallets = await manager.getWallets(deployer.address, 0, 7);
      expect(wallets.length).to.equal(8);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("no data is set for deployer", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 50);
      const mintData = await xen.userMints(deployer.address);

      expect(mintData.user).to.equal(ethers.constants.AddressZero);
    });

    it("sets the right data in XEN", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 50);
      const wallets = await manager.getWallets(deployer.address, 0, 4);

      for (let i = 0; i < wallets.length; i++) {
        const mintData = await xen.userMints(wallets[i]);

        expect(mintData.user).to.equal(wallets[i]);
        expect(mintData.term).to.equal(50);
        expect(mintData.rank).to.equal(i + 1);
      }
    });

    it("multiple users have their own wallets", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 50);
      await manager.connect(user2).batchCreateWallets(4, 50);

      const wallets1 = await manager.getWallets(deployer.address, 0, 4);
      const wallets2 = await manager.getWallets(user2.address, 0, 3);

      expect(wallets1.length).to.equal(5);
      expect(wallets2.length).to.equal(4);

      const allWallets = wallets1.concat(wallets2);

      for (let i = 0; i < allWallets.length; i++) {
        expect(allWallets[i]).to.not.empty;
        expect(allWallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(allWallets.filter((w) => w == allWallets[i]).length).to.equal(1);
      }
    });

    it("fails when creating for too short term", async function () {
      await expect(manager.batchCreateWallets(5, 1)).to.be.revertedWith(
        "Too short term"
      );
      await expect(manager.batchCreateWallets(5, 49)).to.be.revertedWith(
        "Too short term"
      );
    });

    it("no direct access", async function () {
      await manager.batchCreateWallets(1, 50);
      const wallets = await manager.getWallets(deployer.address, 0, 0);
      const wallet = await ethers.getContractAt("XENWallet", wallets[0]);

      await expect(wallet.connect(deployer).claimRank(1)).to.be.revertedWith(
        "No access"
      );
      await expect(
        wallet.connect(deployer).claimAndTransferMintReward(deployer.address)
      ).to.be.revertedWith("No access");
    });
  });

  describe("Wallet retrieval", function () {
    const day = 24 * 60 * 60;
    beforeEach(async function () {});

    it("is possible to retrieve zero wallet count", async function () {
      const walletCount = await manager.getWalletCount(deployer.address);

      expect(walletCount).to.equal(0);
    });

    it("is possible to retrieve the wallet count", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 50);
      const walletCount = await manager.getWalletCount(deployer.address);

      expect(walletCount).to.equal(5);
    });

    it("wallet count doesn't change after minting", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 50);
      await timeTravelDays(50);

      let numTotalWallets = await manager.totalWallets();
      let numActiveWallets = await manager.activeWallets();
      expect(numTotalWallets).to.equal(5);
      expect(numActiveWallets).to.equal(5);

      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);

      numActiveWallets = await manager.activeWallets();
      numTotalWallets = await manager.totalWallets();
      expect(numTotalWallets).to.equal(5);
      expect(numActiveWallets).to.equal(0);

      const walletCount = await manager.getWalletCount(deployer.address);
      expect(walletCount).to.equal(5);
    });

    it("is possible to retrieve the wallets", async function () {
      await manager.batchCreateWallets(5, 50);
      const wallets = await manager.getWallets(deployer.address, 0, 4);

      expect(wallets.length).to.equal(5);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("is possible to retrieve the wallet infos", async function () {
      await manager.batchCreateWallets(5, 50);
      const wallets = await manager.getWallets(deployer.address, 0, 4);
      const infos = await manager.getUserInfos(wallets);

      expect(infos.length).to.equal(5);
      for (let i = 0; i < infos.length; i++) {
        expect(infos[i].rank).to.above(0);
      }
    });

    it("fails when querying for non-existing wallets", async function () {
      await manager.batchCreateWallets(5, 50);
      await expect(
        manager.getWallets(deployer.address, 2, 20)
      ).to.be.revertedWithPanic(PANIC_CODES.ARRAY_ACCESS_OUT_OF_BOUNDS);
    });
  });

  describe("Mint claim", function () {
    let wallets: string[];
    beforeEach(async function () {
      await manager.connect(deployer).batchCreateWallets(5, 100);
      wallets = await manager.getWallets(deployer.address, 0, 4);
      await timeTravelDays(100);
    });

    it("works", async function () {
      const xenBalanceBefore = await xen.balanceOf(deployer.address);
      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      const xenBalanceAfter = await xen.balanceOf(deployer.address);

      expect(xenBalanceBefore).to.equal(0);
      expect(xenBalanceAfter).to.above(0);

      const xenBalanceOwner = await xen.balanceOf(deployer.address);
      const yenBalanceOwner = await yen.balanceOf(deployer.address);

      expect(xenBalanceOwner).to.above(0);
      expect(yenBalanceOwner).to.above(xenBalanceOwner.div(2));
    });

    it("works for multiple users", async function () {
      await manager.connect(user2).batchCreateWallets(5, 100);
      await timeTravelDays(100);

      const feeReceiverAddress = await manager.feeReceiver();

      const yenDeployerBalanceBefore = await yen.balanceOf(feeReceiverAddress);
      const yenUserBalanceBefore = await yen.balanceOf(user2.address);

      const xenDeployerBalanceBefore = await xen.balanceOf(feeReceiverAddress);
      const xenUserBalanceBefore = await xen.balanceOf(user2.address);

      await manager.connect(user2).batchClaimAndTransferMintReward(0, 4);

      const yenDeployerBalanceAfter = await yen.balanceOf(feeReceiverAddress);
      const yenUserBalanceAfter = await yen.balanceOf(user2.address);

      const xenDeployerBalanceAfter = await xen.balanceOf(feeReceiverAddress);
      const xenUserBalanceAfter = await xen.balanceOf(user2.address);

      expect(yenDeployerBalanceAfter).to.above(yenDeployerBalanceBefore);
      expect(yenUserBalanceAfter).to.above(yenUserBalanceBefore);

      expect(xenDeployerBalanceAfter).to.equal(xenDeployerBalanceBefore);
      expect(xenUserBalanceAfter).to.above(xenUserBalanceBefore);

      // 10% minting fee is applied before fee separation
      // divisor becomes nine instead of ten
      expect(yenDeployerBalanceAfter).to.equal(yenUserBalanceAfter.div(9));
    });

    it("mints equal amount of own tokens", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 51);
      await timeTravelDays(51);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 9);

      const xenBalanceOwner = await xen.balanceOf(deployer.address);
      const yenBalanceOwner = await yen.balanceOf(deployer.address);
      const xenBalanceFeeReceiver = await xen.balanceOf(feeReceiver.address);
      const ownBalanceFeeReceiver = await yen.balanceOf(feeReceiver.address);

      expect(xenBalanceOwner).to.above(0);
      expect(yenBalanceOwner).to.above(0);
      expect(xenBalanceFeeReceiver).to.equal(0);
      expect(ownBalanceFeeReceiver).to.above(0);

      expect(ownBalanceFeeReceiver.mul(9)).to.approximately(
        yenBalanceOwner,
        10
      );
    });

    it("zeroes wallets", async function () {
      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      wallets = await manager.getWallets(deployer.address, 0, 4);

      expect(wallets[0]).to.equal(ethers.constants.AddressZero);
      expect(wallets[1]).to.equal(ethers.constants.AddressZero);
      expect(wallets[2]).to.equal(ethers.constants.AddressZero);
      expect(wallets[3]).to.equal(ethers.constants.AddressZero);
      expect(wallets[4]).to.equal(ethers.constants.AddressZero);
    });

    it("fails when not all wallets in range have matured", async function () {
      // create more wallets with longer term
      await manager.connect(deployer).batchCreateWallets(5, 53);
      // create more wallets with short term
      await manager.connect(deployer).batchCreateWallets(2, 51);
      await timeTravelDays(52);

      await expect(
        manager.connect(deployer).batchClaimAndTransferMintReward(0, 11)
      ).to.be.revertedWith("CRank: Mint maturity not reached");
    });

    it("fails if claiming outside range", async function () {
      await expect(
        manager.connect(deployer).batchClaimAndTransferMintReward(5, 5)
      ).to.be.revertedWithPanic(PANIC_CODES.ARRAY_ACCESS_OUT_OF_BOUNDS);
    });

    it("fails if already claimed", async function () {
      manager.connect(deployer).batchClaimAndTransferMintReward(0, 0);
      await expect(
        manager.connect(deployer).batchClaimAndTransferMintReward(0, 0)
      ).to.be.reverted;
    });
  });

  describe("Rescue", function () {
    let wallets: string[];
    beforeEach(async function () {
      await manager.connect(user2).batchCreateWallets(2, 50);
      wallets = await manager.getWallets(user2.address, 0, 1);
      await timeTravelDays(50);
    });

    it("works", async function () {
      const xenBalanceFeeReceiverBefore = await xen.balanceOf(
        feeReceiver.address
      );

      await nextDay();
      await nextDay();
      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 1);

      const xenBalanceFeeReceiver = await xen.balanceOf(feeReceiver.address);
      const yenBalanceFeeReceiver = await yen.balanceOf(feeReceiver.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const yenBalanceOwner = await yen.balanceOf(user2.address);

      expect(xenBalanceFeeReceiver).to.above(0);
      expect(yenBalanceFeeReceiver).to.above(0);
      expect(xenBalanceOwner).to.above(0);
      expect(yenBalanceOwner).to.above(0);

      expect(xenBalanceOwner).to.equal(
        xenBalanceFeeReceiver.mul(2125).div(1000)
      );
      expect(yenBalanceOwner).to.equal(
        yenBalanceFeeReceiver.mul(2125).div(1000)
      );
    });

    it("nothing rescued if not far ahead enough in maturity", async function () {
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 1);

      const xenBalanceFeeReceiver = await xen.balanceOf(feeReceiver.address);
      const ownBalanceFeeReceiver = await yen.balanceOf(feeReceiver.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const yenBalanceOwner = await yen.balanceOf(user2.address);

      expect(xenBalanceFeeReceiver).to.equal(0);
      expect(ownBalanceFeeReceiver).to.equal(0);
      expect(xenBalanceOwner).to.equal(0);
      expect(yenBalanceOwner).to.equal(0);
    });

    it("rescue zeroes wallets", async function () {
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 1);

      wallets = await manager.getWallets(user2.address, 0, 1);

      expect(wallets[0]).to.equal(ethers.constants.AddressZero);
      expect(wallets[1]).to.equal(ethers.constants.AddressZero);
    });

    it("fails if called by non-owner", async function () {
      await expect(
        manager.connect(user2).batchClaimMintRewardRescue(user2.address, 5, 5)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });
  });

  describe("Reward multiplier calculations", function () {
    describe("Weekly reward multiplier calculation", function () {
      it("week 1", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(0);
        const expected = 100000269;
        expect(expected).to.equal(adjusted);
      });

      it("week 10", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(10);
        const expected = 862402141 - 802528286;
        expect(expected).to.equal(adjusted);
      });

      it("week 200", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(200);
        const expected = 1999938794 - 1999935289;
        expect(expected).to.equal(adjusted);
      });

      it("week 249", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(249);
        const expected = 2000000000 - 1999999716;
        expect(expected).to.equal(adjusted);
      });

      it("week 250", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(250);
        // Mint reward disappears after 5 years
        const expected = 0;
        expect(expected).to.equal(adjusted);
      });

      it("week 300", async function () {
        const adjusted = await manager.getWeeklyRewardMultiplier(300);
        // Mint reward disappears after 5 years
        const expected = 0;
        expect(expected).to.equal(adjusted);
      });
    });

    // TODO: copy paste similar 'describe' sections for functions 'getRewardMultiplier' and 'getCumulativeWeeklyRewardMultiplier'
  });

  describe("Mint amount calculations", function () {
    let original: number;
    beforeEach(async function () {
      original = 1000000;
    });
    let daysInWeek = 7;

    it("no time has passed, returns 0.102586724 * original", async function () {
      const adjusted = await manager.getAdjustedMintAmount_mock(
        original,
        daysInWeek
      );
      const week_0 = 100000269;
      const expected = Math.floor((original * week_0) / 1000000000);
      expect(expected).to.equal(adjusted);
    });

    it("first week returns right amount", async function () {
      const numWeeks = 1;
      await timeTravelDays(daysInWeek * numWeeks);
      const adjusted = await manager.getAdjustedMintAmount_mock(
        original,
        numWeeks * daysInWeek
      );

      const week_1 = 195000526;
      const expected = Math.floor((original * week_1) / 1000000000);
      expect(expected).to.equal(adjusted);

      const elapsedWeeks = await manager.getElapsedWeeks();
      expect(elapsedWeeks).to.equal(1);
    });

    it("tenth week returns right amount", async function () {
      const numWeeks = 10;
      await timeTravelDays(daysInWeek * numWeeks);
      const adjusted = await manager.getAdjustedMintAmount_mock(
        original,
        2 * daysInWeek
      );

      const elapsedWeeks = await manager.getElapsedWeeks();
      expect(elapsedWeeks).to.equal(10);

      const week_10 = 862402141;
      const week_7 = 673160953;
      const expected = Math.floor((original * (week_10 - week_7)) / 1000000000);
      expect(expected).to.equal(adjusted);
    });

    it("a week after precalculated values the reward becomes zero", async function () {
      const currentWeek = 260;
      await timeTravelDays(daysInWeek * currentWeek);
      const adjusted = await manager.getAdjustedMintAmount_mock(
        original,
        2 * daysInWeek
      );
      const expected = 0;
      expect(adjusted).to.equal(expected);
    });
  });
});

export const timeTravelDays = async (days: number) => {
  const seconds = 24 * 60 * 60 * days;
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
};

const nextDay = async () => {
  await timeTravelDays(1);
};
