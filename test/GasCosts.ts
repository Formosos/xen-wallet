import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { XENCrypto, XENWallet, XENWalletManager } from "../typechain-types";
import { MockDeployer } from "../typechain-types/contracts/mock";

// Run only for manual gas cost checks
xdescribe("Gas costs", function () {
  const walletsToCreate = 50;

  xit("Regular create", async function () {
    const Deployer = await ethers.getContractFactory("MockDeployer");
    const deployer = (await Deployer.deploy()) as MockDeployer;
    await deployer.deployWallets(walletsToCreate);
  });

  xit("Batch create", async function () {
    const [_owner, _feeReceiver, _otherAccount] = await ethers.getSigners();

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
    const _manager = await Manager.deploy(
      _xen.address,
      _wallet.address,
      _feeReceiver.address
    );

    const start = 1;

    await _manager.batchCreateWallets(walletsToCreate, 50);
  });

  xit("Mint amount calculations", async function () {
    const Manager = await ethers.getContractFactory("MockManager");
    const manager = await Manager.deploy(
      ethers.constants.AddressZero,
      ethers.constants.AddressZero,
      ethers.constants.AddressZero
    );

    const original = 100000000;

    await timeTravel(1000);
    const res = await manager.getAdjustedMint(original, 10);
    const gas = await manager.estimateGas.getAdjustedMint(original, 10);
    console.log("gas", gas.toString());
    console.log("target value: 4317, got value " + res.toString());
    expect(res).to.equal(4267);
  });

  xit("Manager deployment", async function () {
    const [_owner, _feeReceiver, _otherAccount] = await ethers.getSigners();

    const Manager = await ethers.getContractFactory("XENWalletManager");
    const _manager = await Manager.deploy(
      ethers.constants.AddressZero,
      ethers.constants.AddressZero,
      ethers.constants.AddressZero
    );
  });
});

export const timeTravel = async (days: number) => {
  const seconds = 24 * 60 * 60 * days;
  await network.provider.send("evm_increaseTime", [seconds]);
  await network.provider.send("evm_mine");
};
