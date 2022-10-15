import { ethers } from "hardhat";

async function main() {
  const Wallet = await ethers.getContractFactory("XENWallet");
  const wallet = await Wallet.deploy();
  await wallet.deployed();
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
