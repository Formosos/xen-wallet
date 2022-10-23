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
    const [_deployer, _user2] = await ethers.getSigners();

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
    const _manager = await Manager.deploy(_xen.address, _wallet.address);

    const OwnToken = await _manager.ownToken();
    const _ownToken = await ethers.getContractAt("YENCrypto", OwnToken);

    return { _xen, _wallet, _manager, _ownToken, _deployer, _user2 };
  }

  let xen: XENCrypto,
    wallet: XENWallet,
    manager: XENWalletManager,
    ownToken: YENCrypto,
    deployer: SignerWithAddress,
    user2: SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _manager, _ownToken, _deployer, _user2 } =
      await loadFixture(deployWalletFixture);

    xen = _xen;
    wallet = _wallet;
    manager = _manager;
    ownToken = _ownToken;
    deployer = _deployer;
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
      await manager.batchCreateWallet(1, 5);

      const walletAddress = await manager.getDeterministicAddress(
        manager.getSalt(0)
      );
      const wallet = await ethers.getContractAt("XENWallet", walletAddress);

      const managerAddress = await wallet.manager();
      const xenAddress = await wallet.XENCrypto();

      expect(managerAddress).to.equal(manager.address);
      expect(xenAddress).to.equal(xen.address);
    });

    it("sets the right mapping", async function () {
      const id = 1;
      const salt = await manager.getSalt(id);
      const addressToBe = await manager.getDeterministicAddress(salt);

      await manager.batchCreateWallet(2, 5);

      const storedAddress = await manager.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(deployer.address);
    });

    it("is possible to retrieve the wallets", async function () {
      await manager.batchCreateWallet(5, 5);
      const wallets = await manager.getWallets(deployer.address, 0, 4);

      expect(wallets.length).to.equal(5);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("returns only existing wallets", async function () {
      await manager.batchCreateWallet(5, 5);
      const wallets = await manager.getWallets(deployer.address, 2, 20);

      expect(wallets.length).to.equal(3);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("can create more wallets", async function () {
      await manager.batchCreateWallet(5, 5);
      await manager.batchCreateWallet(3, 5);

      const wallets = await manager.getWallets(deployer.address, 0, 8);
      expect(wallets.length).to.equal(8);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("no data for deployer", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 5);
      const mintData = await xen.userMints(deployer.address);

      expect(mintData.user).to.equal(ethers.constants.AddressZero);
    });

    it("sets the right data in XEN", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 5);
      const wallets = await manager.getWallets(deployer.address, 0, 4);

      for (let i = 0; i < wallets.length; i++) {
        const mintData = await xen.userMints(wallets[i]);

        expect(mintData.user).to.equal(wallets[i]);
        expect(mintData.term).to.equal(5);
        expect(mintData.rank).to.equal(i + 1);
      }
    });

    it("multiple users have their own wallets", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 5);
      await manager.connect(user2).batchCreateWallet(4, 5);

      const wallets1 = await manager.getWallets(deployer.address, 0, 4);
      const wallets2 = await manager.getWallets(user2.address, 0, 4);

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

    /* it("reusing the IDs fails", async function () {
      await manager.batchCreateWallet(3, 5, 5);
      await expect(manager.batchCreateWallet(1, 5, 5)).to.be.revertedWith(
        "ERC1167: create2 failed"
      );
    }); */

    it("no direct access", async function () {
      await manager.batchCreateWallet(1, 5);
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
      await manager.connect(deployer).batchCreateWallet(5, 1);
      wallets = await manager.getWallets(deployer.address, 0, 4);
      await nextDay();
    });

    it("works", async function () {
      const xenBalanceBefore = await xen.balanceOf(deployer.address);
      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      const xenBalanceAfter = await xen.balanceOf(deployer.address);

      expect(xenBalanceBefore).to.equal(0);
      expect(xenBalanceAfter).to.above(0);
    });

    it("works for multiple users", async function () {
      await manager.connect(user2).batchCreateWallet(5, 2);
      await nextDay();
      await nextDay();

      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 4);
      await manager.connect(user2).batchClaimAndTransferMintReward(0, 4);

      const deployerBalance = await xen.balanceOf(deployer.address);
      const otherBalance = await xen.balanceOf(user2.address);

      expect(deployerBalance).to.above(0);
      expect(otherBalance).to.above(0);
      expect(otherBalance).to.above(deployerBalance);
    });

    it("mints equal amount of own tokens", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 51);
      await timeTravel(51);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 9);

      const xenBalance = await xen.balanceOf(deployer.address);
      const ownBalance = await ownToken.balanceOf(deployer.address);

      expect(xenBalance).to.above(0);
      expect(xenBalance).to.equal(ownBalance);
    });

    it("doesn't mint own tokens if term too short", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 50);
      await timeTravel(50);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 9);

      const xenBalance = await xen.balanceOf(deployer.address);
      const ownBalance = await ownToken.balanceOf(deployer.address);

      expect(ownBalance).to.equal(0);
      expect(xenBalance).to.above(0);
    });

    it("mints own tokens correctly if only some wallets have term long enough", async function () {
      await manager.connect(deployer).batchCreateWallet(5, 51);
      await manager.connect(deployer).batchCreateWallet(5, 50);
      await manager.connect(deployer).batchCreateWallet(5, 51);

      await timeTravel(51);
      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 19);

      const xenBalance = await xen.balanceOf(deployer.address);
      const ownBalance = await ownToken.balanceOf(deployer.address);

      expect(ownBalance).to.above(0);
      expect(xenBalance).to.above(0);
      expect(xenBalance).to.above(ownBalance);
    });

    it("works when not all wallets in range have matured", async function () {
      // create more wallets with longer term
      await manager.connect(deployer).batchCreateWallet(5, 3);
      // create more wallets with short term
      await manager.connect(deployer).batchCreateWallet(2, 1);
      await nextDay();
      await nextDay();

      await manager.connect(deployer).batchClaimAndTransferMintReward(0, 11);

      const xenBalanceBefore = await xen.balanceOf(deployer.address);

      // wait until the middle batch has expired also
      await nextDay();
      await nextDay();
      await nextDay();

      await manager.connect(deployer).batchClaimAndTransferMintReward(5, 9);

      const xenBalanceAfter = await xen.balanceOf(deployer.address);

      expect(xenBalanceAfter.sub(xenBalanceBefore)).to.above(0);
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
      await manager.connect(user2).batchCreateWallet(5, 1);
      wallets = await manager.getWallets(user2.address, 0, 4);
      await nextDay();
    });

    it("works", async function () {
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 1, 5);

      const xenBalanceDeployer = await xen.balanceOf(deployer.address);
      const ownBalanceDeployer = await ownToken.balanceOf(deployer.address);
      const xenBalanceOwner = await xen.balanceOf(user2.address);
      const ownBalanceOwner = await ownToken.balanceOf(user2.address);

      expect(xenBalanceDeployer).to.above(0);
      expect(ownBalanceDeployer).to.above(0);
      expect(xenBalanceOwner).to.above(0);
      expect(ownBalanceOwner).to.above(0);

      expect(xenBalanceDeployer).to.equal(ownBalanceDeployer);
      expect(xenBalanceOwner).to.equal(ownBalanceOwner);

      expect(xenBalanceDeployer.mul(4)).to.equal(xenBalanceOwner);
    });

    it("works when not all wallets in range have matured", async function () {
      // create more wallets with longer term
      await manager.connect(user2).batchCreateWallet(5, 3);
      // create more wallets with short term
      await manager.connect(user2).batchCreateWallet(2, 1);
      await nextDay();
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 0, 14);

      const xenBalanceOwnerBefore = await xen.balanceOf(user2.address);
      const ownBalanceOwnerBefore = await ownToken.balanceOf(user2.address);

      // wait until the middle batch has expired also
      await nextDay();
      await nextDay();
      await nextDay();

      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 5, 9);

      const xenBalanceOwnerAfter = await xen.balanceOf(user2.address);
      const ownBalanceOwnerAfter = await ownToken.balanceOf(user2.address);

      expect(xenBalanceOwnerAfter.sub(xenBalanceOwnerBefore)).to.above(0);
      expect(ownBalanceOwnerAfter.sub(ownBalanceOwnerBefore)).to.above(0);
    });

    it("nothing is done if called prematurely", async function () {
      await manager
        .connect(deployer)
        .batchClaimMintRewardRescue(user2.address, 1, 5);
      const xenBalance = await xen.balanceOf(deployer.address);

      expect(xenBalance).to.equal(0);
    });
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
