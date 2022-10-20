import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import {
  PrestoCrypto,
  PrestoCrypto,
  XENCrypto,
  XENWallet,
  XENWalletManager,
} from "../typechain-types";
import { prestoSol } from "../typechain-types/contracts";

describe("Wallet", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployWalletFixture() {
    // Contracts are deployed using the first signer/account by default
    const [_owner, _otherAccount] = await ethers.getSigners();

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
    await _wallet.initialize(_xen.address);

    const Manager = await ethers.getContractFactory("XENWalletManager");
    const _manager = await Manager.deploy(_xen.address, _wallet.address);

    const aaa = await _manager.ownToken();
    const _ownToken = (await ethers.getContractAt(
      "PrestoCrypto",
      aaa
    )) as PrestoCrypto;

    return { _xen, _wallet, _manager, _ownToken, _owner, _otherAccount };
  }

  let xen: XENCrypto,
    wallet: XENWallet,
    manager: XENWalletManager,
    ownToken: PrestoCrypto,
    owner: SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _manager, _ownToken, _owner } = await loadFixture(
      deployWalletFixture
    );

    xen = _xen;
    wallet = _wallet;
    manager = _manager;
    ownToken = _ownToken;
    owner = _owner;
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
    });
  });

  describe("Cloning", function () {
    beforeEach(async function () {});

    it("Sets right mapping", async function () {
      const id = 1;
      const salt = await manager.getSalt(id);
      const addressToBe = await manager.getDeterministicAddress(salt);

      await manager.createWallet(id, 5);

      const storedAddress = await manager.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(owner.address);
    });

    it("Batch cloning sets right mapping", async function () {
      const id = 1;
      const salt = await manager.getSalt(id);
      const addressToBe = await manager.getDeterministicAddress(salt);

      await manager.batchCreateWallet(id, id + 1, 5);

      const storedAddress = await manager.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(owner.address);
    });
  });
});
