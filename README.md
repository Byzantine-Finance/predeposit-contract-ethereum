# `ByzantineDeposit` Contract Specification

## Overview

The primary purpose of the `ByzantineDeposit` contract is to serve as a pre-deposit mechanism for the Byzantine protocol, specifically targeting early liquidity providers. The commited liquidity will rewarded by Byzantine points calculated off-chain through the events emitted by the contract.

This contract ensures that deposits are securely stored while maintaining the integrity of the underlying assets.

## Specification record

### Accepted Tokens

| Token    | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ETH`    | Accepted by default and recognized by canonical address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`. <br/> See function `depositETH()`                                                                                                                                                                                                                                                                                                                                     |
| `stETH`  | Accepted by default.<br/> To prevent the loss of the PoS rewards (rebasing mechanism), **the contract automatically wraps `stETH` into `wstETH` upon deposit**. This ensures that users do not miss out on staking rewards while using the contract.<br/> This is the `wsETH` amount which is stored in the `depositedAmount` mapping, therefore, during withdrawal / move of `stETH`, users must input the amount of `wstETH` they got. <br/>See function `depositERC20()` |
| `wstETH` | Accepted by default.                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `ERC20`  | As long as the token has been whitelisted by the `owner`.<br/> It could be `wBTC`, `iBTC`, `USDC`, `eigen` and other `LSTs` or `stablecoin`.<br/> See function `addDepositToken()` and `depositERC20()`                                                                                                                                                                                                                                                                     |

### Whitelisting of Deposit Tokens

The contract allows for the whitelisting of additional deposit tokens by the `owner`. It is his duty to be careful to not add rebasing or "[exotic ERC20](https://github.com/d-xo/weird-erc20)" tokens. This flexibility enables the inclusion of various ERC20 tokens while maintaining security and control.

### Depositor Whitelisting

Depositors must be whitelisted to interact with the contract (see mapping `canDeposit`). However, there is an option to enable permissionless deposits, allowing anybody to participate in the deposit process and earn points. That feature is controlled by the `owner` and can be reverted.

### Move stake to Byzantine vaults

When Byzantine contracts will be live on mainnet, depositors will have to explicitly move their tokens to the Byzantine vaults of their choice. It's not "all-or-nothing". It is possible to invest in multiple Byzantine vaults. See function `moveToVault()`.

Tokens can only be moved to Byzantine vaults that have been pre-approved by the contract administrator. This ensures that only trusted vaults are utilized for token transfers.

### Pausable Functionality

The contract includes the ability to pause specific functionalities, including:

- Deposits - flag `PAUSED_DEPOSITS`
- Moves to vaults - flag `PAUSED_VAULTS_MOVES`

Only registers pausers and unpausers recorded in the [`PauserRegistry`](src/permissions/PauserRegistry.sol) contract have the right pause and unpause the contract's functionalities.

This feature enhances security by allowing the contract owner to halt operations in case of emergencies. It will also block the moves to vaults as long as Byzantine protocol is not live on mainnet.

## Audits

Audited by security industry leaders:

- [Spearbit](https://spearbit.com/): [audit report](audits/Byzantine%20Deposit%20-%20Spearbit%20-%20Jan%202025.pdf)
- [Hacken](https://hacken.io/): [audit report](audits/Byzantine%20Deposit%20-%20Hacken%20-%20Jan%202025.pdf)

## Current Mainnet Deployment

###### Deposit Contract

| Name                                           | Address                                                                                                                 |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| [`ByzantineDeposit`](src/ByzantineDeposit.sol) | [`0xbA98A4d436e79639A1598aFc988eFB7A828d7F08`](https://etherscan.io/address/0xbA98A4d436e79639A1598aFc988eFB7A828d7F08) |

###### Multisigs

| Name                                                   | Address                                                                                                                 |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| [`PauserRegistry`](src/permissions/PauserRegistry.sol) | [`0xf21189365131551Ba4c3613252B1bcCdA60BD1e6`](https://etherscan.io/address/0xf21189365131551Ba4c3613252B1bcCdA60BD1e6) |
