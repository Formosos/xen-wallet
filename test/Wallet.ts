import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { XENCrypto, XENWallet, XENWalletFactory } from "../typechain-types";

describe("Wallet", function () {

  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployWalletFixture() {
    // Contracts are deployed using the first signer/account by default
    const [_owner, _otherAccount] = await ethers.getSigners();

    const XEN = await ethers.getContractFactory("XENCrypto");
    const _xen = await XEN.deploy();

    const Wallet = await ethers.getContractFactory("XENWallet");
    const _wallet = await Wallet.deploy();
    await _wallet.initialize(_xen.address);

    const Factory = await ethers.getContractFactory("XENWalletFactory");
    const _factory = await Factory.deploy(_xen.address, _wallet.address);

    return { _xen, _wallet, _factory, _owner, _otherAccount };
  }

  let xen : XENCrypto, wallet : XENWallet, factory : XENWalletFactory, owner : SignerWithAddress;

  beforeEach(async function () {
    const { _xen, _wallet, _factory, _owner } = await loadFixture(deployWalletFixture);

    xen = _xen;
    wallet = _wallet;
    factory  = _factory;
    owner = _owner;
  });

  describe("Deployment", function () {
    it("Should set the right values", async function () {

      const walletXen = await wallet.XENCrypto();
      const factoryXen = await factory.XENCrypto();
      const factoryDeployer = await factory.deployer();
      const factoryImplementation = await factory.implementation();

      expect(walletXen).to.equal(xen.address);
      expect(factoryXen).to.equal(xen.address);
      expect(factoryDeployer).to.equal(owner.address);
      expect(factoryImplementation).to.equal(wallet.address);
    });
  });

  describe("Cloning", function () {
    beforeEach(async function () {
      
    });

    it("Sets right mapping", async function () {
      const id = 1;
      const salt = await factory.getSalt(id);
      const addressToBe = await factory.getDeterministicAddress(salt);

      await factory.createWallet(id, 5);

      const storedAddress = await factory.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(owner.address);
    });

    it("Batch cloning sets right mapping", async function () {
      const id = 1;
      const salt = await factory.getSalt(id);
      const addressToBe = await factory.getDeterministicAddress(salt);

      await factory.batchCreateWallet(id, id + 1, 5);

      const storedAddress = await factory.reverseAddressResolver(addressToBe);

      expect(storedAddress).to.equal(owner.address);
    });
  });
});
