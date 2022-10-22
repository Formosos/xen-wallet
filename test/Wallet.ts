import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { BigNumber } from "ethers";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  PrestoCrypto,
  XENCrypto,
  XENWallet,
  XENWalletManager,
} from "../typechain-types";

describe("Wallet", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployWalletFixture() {
    // Contracts are deployed using the first signer/account by default
    const [_owner, _user2] = await ethers.getSigners();

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
    await _wallet.initialize(_xen.address, _owner.address);

    const Manager = await ethers.getContractFactory("XENWalletManager");
    const _manager = await Manager.deploy(_xen.address, _wallet.address);

    const OwnToken = await _manager.ownToken();
    const _ownToken = await ethers.getContractAt("PrestoCrypto", OwnToken);

    return { _xen, _wallet, _manager, _ownToken, _owner, _user2 };
  }

  let xen: XENCrypto,
    wallet: XENWallet,
    manager: XENWalletManager,
    ownToken: PrestoCrypto,
    owner: SignerWithAddress,
    user2: SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _manager, _ownToken, _owner, _user2 } =
      await loadFixture(deployWalletFixture);

    xen = _xen;
    wallet = _wallet;
    manager = _manager;
    ownToken = _ownToken;
    owner = _owner;
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
      expect(factoryDeployer).to.equal(owner.address);
      expect(factoryImplementation).to.equal(wallet.address);
      expect(ownToken).to.not.empty;
    });
  });

  describe("Wallet creation", function () {
    const day = 24 * 60 * 60;
    beforeEach(async function () {});

    it("sets the right data", async function () {
      await manager.batchCreateWallet(1, 1, 5);

      const walletAddress = await manager.getDeterministicAddress(
        manager.getSalt(1)
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

      await manager.batchCreateWallet(id, id + 1, 5);

      const storedAddress = await manager.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(owner.address);
    });

    it("is possible to retrieve the wallets", async function () {
      await manager.batchCreateWallet(1, 5, 5);
      const wallets = await manager.getWallets(1, 5);

      expect(wallets.length).to.equal(5);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("returns only existing wallets", async function () {
      await manager.batchCreateWallet(1, 5, 5);
      const wallets = await manager.getWallets(3, 20);

      expect(wallets.length).to.equal(3);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("can create more wallets", async function () {
      await manager.batchCreateWallet(1, 5, 5);
      await manager.batchCreateWallet(6, 8, 5);

      const wallets = await manager.getWallets(1, 8);
      expect(wallets.length).to.equal(8);
      for (let i = 0; i < wallets.length; i++) {
        expect(wallets[i]).to.not.empty;
        expect(wallets[i]).to.not.equal(ethers.constants.AddressZero);
        // make sure all addresses are unique
        expect(wallets.filter((w) => w == wallets[i]).length).to.equal(1);
      }
    });

    it("no data for deployer", async function () {
      await manager.connect(owner).batchCreateWallet(1, 5, 5);
      const mintData = await xen.userMints(owner.address);

      expect(mintData.user).to.equal(ethers.constants.AddressZero);
    });

    it("sets the right data in XEN", async function () {
      await manager.connect(owner).batchCreateWallet(1, 5, 5);
      const wallets = await manager.getWallets(1, 5);

      for (let i = 0; i < wallets.length; i++) {
        const mintData = await xen.userMints(wallets[i]);

        expect(mintData.user).to.equal(wallets[i]);
        expect(mintData.term).to.equal(5);
        expect(mintData.rank).to.equal(i + 1);
      }
    });

    it("multiple users have their own wallets", async function () {
      await manager.connect(owner).batchCreateWallet(1, 5, 5);
      await manager.connect(user2).batchCreateWallet(1, 4, 5);

      const wallets1 = await manager.connect(owner).getWallets(1, 5);
      const wallets2 = await manager.connect(user2).getWallets(1, 5);

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

    it("reusing the IDs fails", async function () {
      await manager.batchCreateWallet(3, 5, 5);
      await expect(manager.batchCreateWallet(1, 5, 5)).to.be.revertedWith(
        "ERC1167: create2 failed"
      );
    });

    it("no direct access", async function () {
      await manager.batchCreateWallet(1, 1, 5);
      const wallets = await manager.getWallets(1, 1);
      const wallet = await ethers.getContractAt("XENWallet", wallets[0]);

      await expect(wallet.connect(owner).claimRank(1)).to.be.revertedWith(
        "No access"
      );
      await expect(
        wallet.connect(owner).claimAndTransferMintReward(owner.address)
      ).to.be.revertedWith("No access");
    });
  });

  describe("Mint claim", function () {
    let wallets: string[];
    beforeEach(async function () {
      await manager.connect(owner).batchCreateWallet(1, 5, 1);
      wallets = await manager.getWallets(1, 5);
      await nextDay();
    });

    it("works", async function () {
      const xenBalanceBefore = await xen.balanceOf(owner.address);
      await manager.connect(owner).batchClaimAndTransferMintReward(1, 5);
      const xenBalanceAfter = await xen.balanceOf(owner.address);

      expect(xenBalanceBefore).to.equal(0);
      expect(xenBalanceAfter).to.above(0);
    });

    it("mints equal amount of own tokens", async function () {
      await manager.connect(owner).batchClaimAndTransferMintReward(1, 5);

      const xenBalance = await xen.balanceOf(owner.address);
      const ownBalance = await ownToken.balanceOf(owner.address);
      expect(xenBalance).to.equal(ownBalance);
    });
  });
});

const nextDay = async () => {
  const oneDay = 24 * 60 * 60;
  await network.provider.send("evm_increaseTime", [oneDay]);
  await network.provider.send("evm_mine");
};
