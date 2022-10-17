import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { XENCrypto, XENWallet, XENWalletFactory } from "../typechain-types";
import { MockDeployer } from "../typechain-types/contracts/mock";

// Run only for manual gas cost checks
describe("Gas costs", function () {
  const walletsToCreate = 10;

  it("Regular create", async function () {
    const Deployer = await ethers.getContractFactory("MockDeployer");
    const deployer = await Deployer.deploy() as MockDeployer;
    await deployer.deployWallets(walletsToCreate);
  });

  it("Batch create", async function () {
    const [_owner, _otherAccount] = await ethers.getSigners();

    const XEN = await ethers.getContractFactory("XENCrypto");
    const _xen = await XEN.deploy();

    const Wallet = await ethers.getContractFactory("XENWallet");
    const _wallet = await Wallet.deploy();

    const Factory = await ethers.getContractFactory("XENWalletFactory");
    const _factory = await Factory.deploy(_xen.address, _wallet.address);

    const start = 1;

    await _factory.batchCreateWallet(start, start + walletsToCreate, 5);
  });
});

