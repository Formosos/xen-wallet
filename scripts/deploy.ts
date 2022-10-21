import { ethers, network } from "hardhat";
import hre from "hardhat";

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

  const MathLib = await ethers.getContractFactory("Math");
  const _math = await MathLib.connect(deployer).deploy();

  const XEN = await ethers.getContractFactory("XENCrypto", {
    libraries: {
      Math: _math.address,
    },
  });
  const _xen = await XEN.connect(deployer).deploy();
  await _xen.deployed();

  const Wallet = await ethers.getContractFactory("XENWallet");
  const _wallet = await Wallet.connect(deployer).deploy();
  await _wallet.deployed();
  await _wallet.initialize(_xen.address);

  const Manager = await ethers.getContractFactory("XENWalletManager");
  const _manager = await Manager.connect(deployer).deploy(
    _xen.address,
    _wallet.address
  );
  await _manager.deployed();

  const _ownToken = await _manager.ownToken();

  if (network.name != "localhost" && network.name != "hardhat") {
    console.log("Deployments done, waiting for etherscan verifications");
    // Wait for the contracts to be propagated inside Etherscan
    await new Promise((f) => setTimeout(f, 60000));

    await verify(_math.address, []);
    await verify(_xen.address, []);
    await verify(_wallet.address, []);
    await verify(_manager.address, [_xen.address, _wallet.address]);
    await verify(_ownToken, [_manager.address]);
  }

  console.log("Deployments done");
  console.log(`XENCrypto: ${_xen.address}, Initial wallet: ${_wallet.address}, 
  Wallet manager: ${_manager.address}, Own token: ${_ownToken}, Math library: ${_math.address}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
