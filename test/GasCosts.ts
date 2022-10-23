import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { XENCrypto, XENWallet, XENWalletManager } from "../typechain-types";
import { MockDeployer } from "../typechain-types/contracts/mock";

// Run only for manual gas cost checks
describe("Gas costs", function () {
  const walletsToCreate = 10;

  it("Regular create", async function () {
    const Deployer = await ethers.getContractFactory("MockDeployer");
    const deployer = (await Deployer.deploy()) as MockDeployer;
    await deployer.deployWallets(walletsToCreate);
  });

  it("Batch create", async function () {
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

    const Manager = await ethers.getContractFactory("XENWalletManager");
    const _manager = await Manager.deploy(_xen.address, _wallet.address);

    const start = 1;

    await _manager.batchCreateWallets(walletsToCreate, 5);
  });
});
