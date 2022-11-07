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
    const [_deployer, _rescuer, _user2] = await ethers.getSigners();

    const MathLib = await ethers.getContractFactory("Math");
    const _math = await MathLib.deploy();

    const XEN = await ethers.getContractFactory("XENCrypto", {
      libraries: {
        Math: _math.address,
      },
    });
    const _xen = await XEN.deploy();

    const Wallet = await ethers.getContractFactory("XENWallet");
    const _wallet = await Wallet.deploy();
    await _wallet.initialize(_xen.address, _deployer.address);

    const Manager = await ethers.getContractFactory("MockManager");
    const _manager = await Manager.deploy(
      _xen.address,
      _wallet.address,
      _rescuer.address
    );

    const OwnToken = await _manager.ownToken();
    const _ownToken = await ethers.getContractAt("YENCrypto", OwnToken);

    return { _xen, _wallet, _manager, _ownToken, _deployer, _rescuer, _user2 };
  }

  let xen: XENCrypto,
    wallet: XENWallet,
    manager: MockManager,
    ownToken: YENCrypto,
    deployer: SignerWithAddress,
    rescuer: SignerWithAddress,
    user2: SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _manager, _ownToken, _deployer, _rescuer, _user2 } =
      await loadFixture(deployWalletFixture);

    xen = _xen;
    wallet = _wallet;
    manager = _manager;
    ownToken = _ownToken;
    deployer = _deployer;
    rescuer = _rescuer;
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
      expect(ownToken).to.not.empty;
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
        manager.connect(rescuer).changeFeeReceiver(user2.address)
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
      await timeTravel(50);
      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 3);

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
      await timeTravel(100);
    });

    it("works", async function () {
      const xenBalanceBefore = await xen.balanceOf(deployer.address);
      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      const xenBalanceAfter = await xen.balanceOf(deployer.address);

      expect(xenBalanceBefore).to.equal(0);
      expect(xenBalanceAfter).to.above(0);
    });

    it("works for multiple users", async function () {
      await manager.connect(user2).batchCreateWallets(5, 100);
      await timeTravel(100);

      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      await manager.connect(user2).batchClaimAndTransferMintReward(0, 4);

      const deployerBalance = await xen.balanceOf(deployer.address);
      const otherBalance = await xen.balanceOf(user2.address);

      expect(deployerBalance).to.above(0);
      expect(otherBalance).to.above(0);
      expect(otherBalance).to.above(deployerBalance);
    });

    it("mints equal amount of own tokens", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 51);
      await timeTravel(51);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 9);

      const xenBalanceOwner = await xen.balanceOf(deployer.address);
      const ownBalanceOwner = await ownToken.balanceOf(deployer.address);
      const xenBalanceFeeReceiver = await xen.balanceOf(rescuer.address);
      const ownBalanceFeeReceiver = await ownToken.balanceOf(rescuer.address);

      expect(xenBalanceOwner).to.above(0);
      expect(ownBalanceOwner).to.above(0);
      expect(xenBalanceFeeReceiver).to.equal(0);
      expect(ownBalanceFeeReceiver).to.above(0);

      expect(ownBalanceFeeReceiver.mul(19)).to.approximately(
        ownBalanceOwner,
        20
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
      await timeTravel(52);

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
      await timeTravel(50);
    });

    it("works", async function () {
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 1);

      const xenBalanceRescuer = await xen.balanceOf(rescuer.address);
      const ownBalanceRescuer = await ownToken.balanceOf(rescuer.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const ownBalanceOwner = await ownToken.balanceOf(user2.address);

      expect(xenBalanceRescuer).to.above(0);
      expect(ownBalanceRescuer).to.above(0);
      expect(xenBalanceOwner).to.above(0);
      expect(ownBalanceOwner).to.above(0);

      expect(xenBalanceRescuer).to.above(ownBalanceRescuer);
      expect(ownBalanceOwner).to.below(xenBalanceOwner);
      expect(ownBalanceRescuer).to.above(ownBalanceOwner);
      expect(xenBalanceRescuer).to.below(xenBalanceOwner);
      expect(xenBalanceRescuer.mul(2)).to.above(xenBalanceOwner);
    });

    it("nothing rescued if not far ahead enough in maturity", async function () {
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 1);

      const xenBalanceRescuer = await xen.balanceOf(rescuer.address);
      const ownBalanceRescuer = await ownToken.balanceOf(rescuer.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const ownBalanceOwner = await ownToken.balanceOf(user2.address);

      expect(xenBalanceRescuer).to.equal(0);
      expect(ownBalanceRescuer).to.equal(0);
      expect(xenBalanceOwner).to.equal(0);
      expect(ownBalanceOwner).to.equal(0);
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

  describe("Mint amount calculations", function () {
    let deployTimestamp: BigNumber;
    let original: number;
    beforeEach(async function () {
      deployTimestamp = await manager.deployTimestamp();
      original = 1000000;
    });

    let secondsInWeek = 60 * 60 * 24 * 7;

    it("no time has passed, returns 0.102586724 * original", async function () {
      const adjusted = await manager.getAdjustedMint(original, 0);
      const expected = Math.floor((original * 102586724) / 1000000000);
      expect(adjusted).to.equal(expected);
    });

    it("first week returns right amount", async function () {
      const currentWeek = 1;
      await timeTravelSecs(secondsInWeek * currentWeek);
      const adjusted = await manager.getAdjustedMint(
        original,
        currentWeek * secondsInWeek
      );
      const expected = Math.floor((original * 200044111) / 1000000000);
      expect(adjusted).to.equal(expected);
    });

    it("week after precalculated returns the same as the last precalculated", async function () {
      const currentWeek = 10;
      await timeTravelSecs(24 * 60 * 60 * 7 * currentWeek);
      const adjusted = await manager.getAdjustedMint(
        original,
        2 * secondsInWeek
      );
      const expected = Math.floor(
        (original * (884707718 - 690571906)) / 1000000000
      );
      expect(adjusted).to.equal(expected);
    });
  });
});

const timeTravelSecs = async (seconds: number) => {
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
};

export const timeTravel = async (days: number) => {
  const seconds = 24 * 60 * 60 * days;
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
};

const nextDay = async () => {
  await timeTravel(1);
};
