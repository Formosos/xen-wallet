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

    const Manager = await ethers.getContractFactory("XENWalletManager");
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
    manager: XENWalletManager,
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
      const factoryDeployer = await manager.deployer();
      const factoryImplementation = await manager.implementation();

      expect(walletXen).to.equal(xen.address);
      expect(factoryXen).to.equal(xen.address);
      expect(factoryDeployer).to.equal(deployer.address);
      expect(factoryImplementation).to.equal(wallet.address);
      expect(ownToken).to.not.empty;
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

    it("fails when querying for non-existing wallets", async function () {
      await manager.batchCreateWallets(5, 50);
      await expect(
        manager.getWallets(deployer.address, 2, 20)
      ).to.be.revertedWithPanic(PANIC_CODES.ARRAY_ACCESS_OUT_OF_BOUNDS);
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

      const xenBalance = await xen.balanceOf(deployer.address);
      const ownBalance = await ownToken.balanceOf(deployer.address);

      expect(xenBalance).to.above(0);
      expect(xenBalance).to.above(ownBalance);
    });

    it("mints own tokens correctly if only some wallets have term long enough", async function () {
      await manager.connect(deployer).batchCreateWallets(5, 51);
      await manager.connect(deployer).batchCreateWallets(5, 50);
      await manager.connect(deployer).batchCreateWallets(5, 51);

      await timeTravel(51);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 19);

      const xenBalance = await xen.balanceOf(deployer.address);
      const ownBalance = await ownToken.balanceOf(deployer.address);

      expect(ownBalance).to.above(0);
      expect(xenBalance).to.above(0);
      expect(xenBalance).to.above(ownBalance);
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

  xdescribe("Rescue", function () {
    let wallets: string[];
    beforeEach(async function () {
      await manager.connect(user2).batchCreateWallets(20, 1);
      wallets = await manager.getWallets(user2.address, 0, 19);
      await nextDay();
    });

    it("works", async function () {
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 19);

      const xenBalanceRescuer = await xen.balanceOf(rescuer.address);
      const ownBalanceRescuer = await ownToken.balanceOf(rescuer.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const ownBalanceOwner = await ownToken.balanceOf(user2.address);

      expect(xenBalanceRescuer).to.above(0);
      expect(ownBalanceRescuer).to.above(0);
      expect(xenBalanceOwner).to.above(0);
      expect(ownBalanceOwner).to.above(0);

      expect(xenBalanceRescuer).to.below(ownBalanceRescuer);
      expect(xenBalanceOwner).to.below(ownBalanceOwner);

      expect(xenBalanceRescuer.mul(4)).to.equal(xenBalanceOwner);
    });

    // it("fails if called prematurely", async function () {
    //   await manager.connect(user2).batchCreateWallets(5, 3);
    //   await expect(
    //     manager
    //       .connect(deployer)
    //       .batchClaimMintRewardRescue(user2.address, 5, 5)
    //   ).to.be.revertedWith("CRank: Mint maturity not reached");
    // });
  });
});

const timeTravel = async (days: number) => {
  const seconds = 24 * 60 * 60 * days;
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
};

const nextDay = async () => {
  await timeTravel(1);
};
