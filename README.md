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
1. `startId`: Index of wallets to start from. The first wallet is index 0.
1. `endId`: Index of wallets to end to.

The wallet indexes can be used to limit the amount of wallets returned. Trying to return too many wallets at a time will lead to issues.

#### `getUserInfos`

Returns XENCrypto contract's `MintInfo` data.

Inputs:

1. `owners`: An array of addresses for which to get the data.

Trying to return too much data at a a time will lead to issues.

#### `batchClaimAndTransferMintReward`

Batch claims wallet rewards from the XENCrypto contract.

Inputs:

1. `startId`: Starting index for the wallets to claim rewards for
1. `endId`: Ending index.

The caller has to make sure, in advance, that all the wallets to be claimed are valid for claiming. One failing claim will revert the whole transaction.

Trying to claim too many wallets in one transaction will cause the entire transaction to revert.

This function will also mint XEL tokens - more details about that are provided later in this document.

### XENWallet contract

This contract is usable only through the manager contract. It mostly contains functionality to claim rank and claim rewards - it does not contain much logic.

## Minting

When user batch claims (function `batchClaimAndTransferMintReward`) rewards he may be minted also XEL tokens. XEL tokens are minted if the wallet's _term_ has been more than 50 days.

XEL token minting has also a reward multiplier.

#### `getCumulativeWeeklyRewardMultiplier`

XEL is minted based on the amount of XEN claimed times a reward multiplier that is derived from our reward curve.

The reward curve is defined by `0.102586724 * 0.95^x` with `x` being the number of weeks that have passed. To derive the reward multiplier from this curve we need to sum up the multiplier from the curve for each week in which the user has claimed.

This calculation is simplified by providing directly all the summed multiplier combinations. So instead of providing the weekly reward for week 1 `0.102586724 * 0.95^1` and for week 2 `0.102586724 * 0.95^2`; we provide the sum for week 1 `0.102586724 * 0.95^1` week 2 `0.102586724 * 0.95^1 + 0.102586724 * 0.95^2`. If we want to calculate the weekly reward we then simply need to subtract the summed / cumulative reward from week 2 and week 1.

All of the cumulative rewards are stored in the `cumulativeWeeklyRewardMultiplier` lookup table. Since partial weekly rewards are possible; a floor division is applied to derive the weekly index. To compensate for the floor division we add one weekly reward multiplier by default.

#### `getRewardMultiplier`

Used to estimate and derive the mint reward multiplier for XEL.

Inputs:

1. `finalWeek`: The the number of weeks that has elapsed or will elapse until maturity
1. `termWeeks`: The term limit in weeks

To estimate or calculate the mint reward we need to do a backwards calculation. When will the claim end and be minted is defined by `finalWeek`. The number of `termWeeks` is then subtracted accordingly to derive the reward multiplier as described in `getCumulativeRewardMultiplier`.

## Deployment & Tests

### Installation

1. Install packages: `npm i`
1. Run tests: `npx hardhat test`

### Local deployment

You can deploy the contracts with script _scripts/deploy.ts_. Local Hardhat deployment can be done by:

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

### Generate reward multiplier lookup table

To generate the lookup table of cumulative weekly reward multipliers run `npm run precalc`. The generated text file (`precalculateRates.txt`) is then directly used inside the main `XENWalletManager.sol` contract.
