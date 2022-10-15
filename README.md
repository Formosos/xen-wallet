# XEN Wallet

## Summary

XEN wallet is a wallet management tool for the ZEN crypto token. It contains a safe stakes function for the deployer and rewards early adopters with an internal ERC20 (name to be determined) token.

## Deployment & Tests

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat run scripts/deploy.ts
```

## Frontend

`frontend` contains the code for a ReactJs app that interacts with the `XENWallet` contract. Mints and stakes are derived from the original `XENCrypto` contract. The corresponding proxy addresses can be found through `addressResolver` in the `XENWallet` contract. For convenience you may call `getActiveWallets(...)`.
