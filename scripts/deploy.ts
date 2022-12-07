import { ethers, network } from "hardhat";
import hre from "hardhat";
import * as fs from "fs";

const addressFile = "contract_addresses.md";

const verify = async (addr: string, args: any[]) => {
  try {
    await hre.run("verify:verify", {
      address: addr,
      constructorArguments: args,
    });
  } catch (ex: any) {
    if (ex.toString().indexOf("Already Verified") == -1) {
      throw ex;
    }
  }
};

async function main() {
  console.log("Starting deployments");
  const accounts = await hre.ethers.getSigners();

  const deployer = accounts[0];
  const feeReceiver = process.env.GOERLI_FEE_RECEIVER_ADDRESS;

  if (!feeReceiver || !deployer) {
    throw "Invalid config";
  }

  const MathLib = await ethers.getContractFactory("Math");
  const _math = await MathLib.connect(deployer).deploy();

  const XEN = await ethers.getContractFactory("XENCrypto", {
    libraries: {
      Math: _math.address,
    },
  });

  let xenAddress = process.env.GOERLI_XEN_ADDRESS;
  let xenDeployed = false;

  if (!xenAddress) {
    console.log("No XEN address set, deploying a new one");
    const _xen = await XEN.connect(deployer).deploy();
    await _xen.deployed();
    xenAddress = _xen.address;
    xenDeployed = true;
  }

  const Wallet = await ethers.getContractFactory("XENWallet");
  const _wallet = await Wallet.connect(deployer).deploy();
  await _wallet.deployed();
  await _wallet.initialize(xenAddress, deployer.address);

  const Manager = await ethers.getContractFactory("XENWalletManager");
  const _manager = await Manager.connect(deployer).deploy(
    xenAddress,
    _wallet.address,
    feeReceiver
  );
  await _manager.deployed();

  const _xelToken = await _manager.xelCrypto();

  if (network.name != "localhost" && network.name != "hardhat") {
    console.log("Deployments done, waiting for etherscan verifications");
    // Wait for the contracts to be propagated inside Etherscan
    await new Promise((f) => setTimeout(f, 60000));

    await verify(_math.address, []);
    if (xenDeployed) {
      await verify(xenAddress, []);
    }

    await verify(_wallet.address, []);
    await verify(_manager.address, [xenAddress, _wallet.address, feeReceiver]);
    await verify(_xelToken, [_manager.address]);

    if (fs.existsSync(addressFile)) {
      fs.rmSync(addressFile);
    }

    fs.appendFileSync(
      addressFile,
      "This file contains the latest test deployment addresses in the Goerli network<br/>"
    );

    const writeAddr = (addr: string, name: string) => {
      fs.appendFileSync(
        addressFile,
        `${name}: [https://goerli.etherscan.io/address/${addr}](https://goerli.etherscan.io/address/${addr})<br/>`
      );
    };

    writeAddr(_manager.address, "Wallet manager");
    writeAddr(xenAddress, "XENCrypto");
    writeAddr(_wallet.address, "Initial wallet");
    writeAddr(_xelToken, "XEL token");
    writeAddr(_math.address, "Math library");
  }

  console.log("Deployments done");
  console.log(`XENCrypto: ${xenAddress}, Initial wallet: ${_wallet.address}, 
  Wallet manager: ${_manager.address}, XEL token: ${_xelToken}, Math library: ${_math.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
