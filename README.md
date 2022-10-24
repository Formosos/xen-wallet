# XEN Wallet Manager

## Summary

XEN wallet is a wallet management tool for the XEN crypto token. It enables users to batch create XEN wallets and mint their rewards.

## Functionalities

The project's main contract is `XENWalletManager` which creates and manages XEN wallets. This chapter introduces the main functionalities of the contracts.

### XENWalletManager contract

#### Deployment arguments (constructor)

The contract requires three arguments upon deployment:
1. `xenCrypto`: The address of the already deployed XENCrypto contract to utilize
1. `walletImplementation`: The address of the already deployed XENWallet reference implementation. One wallet needs to be deployed in advance so all subsequent wallets can copy that contract's code
1. `rescueFeeAddress`: Address which receives rescue fees from the contract

#### `batchCreateWallets`

Creates the desired amount of wallet contracts. Each wallet is a separate contract in a unique address.
Upon creation each wallet is entered into the XENCrypto contract (`claimRank`).
In theory this function can create any number of wallets but the blockchain's block limits limit the amount to somewhere around 100-200 per transaction.

Inputs:
1. `amount`: How many wallets to create
1. `term`: For how many days the wallet is to be locked in XENCrypto

This function can be called multiple times by the same caller so wallets can be created at different times with different terms.

#### `getWallets`

Returns the desired user's wallets.

Inputs:
1. `owner`: Return wallets for the given owner address
1. `_startId`: Index of wallets to start from. The first wallet is index 0.
1. `_endId`: Index of wallets to end to.

The wallet indexes can be used to limit the amount of wallets returned. Trying to return too many wallets at a time will lead to issues.

#### `getUserInfos`

Returns XENCrypto contract's `MintInfo` data.

Inputs:
1. `owners`: An array of addresses for which to get the data.

Trying to return too much data at a a time will lead to issues.

#### `batchClaimAndTransferMintReward`

Batch claims wallet rewards from the XENCrypto contract.

Inputs:
1. `_startId`: Starting index for the wallets to claim rewards for
1. `_endId`: Ending index.

The caller has to make sure, in advance, that all the wallets to be claimed are valid for claiming. One failing claim will revert the whole transaction.

Trying to claim too many wallets in one transaction will cause the entire transaction to revert.

This function will also mint YEN tokens - more details about that are provided later in this document.

#### `batchClaimMintRewardRescue`

Used to rescue wallets whose XEN rewards are about to expire.

Inputs: 
1. `walletOwner`: The owner whose wallets to rescue
1. `_startId`: Starting index for the wallets to rescue
1. `_endId`: Ending index.

A rescue can only be performed if the wallet's maturity has been exceeded by at least 2 days.

A rescue fee of 20% (of both XEN and YEN tokens) is deducted for each wallet and sent to the rescue address given in the contract constructor.

### XENWallet contract

This contract is usable only through the manager contract. It mostly contains functionality to claim rank and claim rewards - it does not contain much logic.

## Minting

When user batch claims (function `batchClaimAndTransferMintReward`) rewards he may be minted also YEN tokens. YEN tokens are minted if the wallet's *term* has been more than 50 days.

YEN token minting has also a reward multiplier. TODO: is this needed? If yes, please write unit tests for it Philipp.

## Deployment & Tests

### Installation

1. Install packages: `npm i`
1. Run tests: `npx hardhat test`

### Local deployment

You can deploy the contracts with script *scripts/deploy.ts*. Local Hardhat deployment can be done by:

1. Start a Hardhat node: `npx hardhat node`
1. Deploy: `npx hardhat run scripts/deploy.ts`

### Goerli deployment

If you want to deploy to a live test network (Goerli) you should:

1. Setup environment variables in a file called `.env`. More details can be found in file `env.example`.
1. Deploy: `npx hardhat run scripts/deploy.ts --network goerli`

The deploy script performes the following actions:
1. Deploys all the needed contracts (including a new instance of XENCrypto) 
1. Verifies all of the deployed contracts in Etherscan
1. Writes the contract addresses [here](contract_addresses.md). This file therefore contains the latest Goerli deployment addresses

## Frontend

`frontend` contains the code for a ReactJs app that interacts with the `XENWallet` contract. Mints and stakes are derived from the original `XENCrypto` contract. The corresponding proxy addresses can be found through `addressResolver` in the `XENWallet` contract. For convenience you may call `getActiveWallets(...)`.

TODO
