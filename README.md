# Native v2 Core

Native is an `intents-based`, `chain-abstraction` liquidity infrastructure that transforms the traditional inventory-based trading paradigm into a credit-based system.

## How Native V2 Core Works

When users want to swap token X for token Y, their options are typically limited to either CEX or AMM exchanges like Uniswap. With AMMs, users often face slippage losses, especially when trading tokens with insufficient liquidity.

To address this challenge, Native supports three quoting mechanisms:

1. RFQ Mode: Native's partnered market makers provide firm, zero-slippage quotes
2. Traditional AMM quotes: Routing through protocols like `Uniswap` or `1inch`

Native automatically selects the better quote for the swapper.

## Credit Margin Engine

While Native may appear to be a traditional RFQ system, it goes beyond by supporting a transition from `inventory-based` to `credit-based` trading.

For example: 

If Alice wants to sell 10 ETH at 3000 USDC each to a market maker, traditional inventory-based systems would require the market maker to hold 30,000 USDC. However, with Native's credit-based system, market makers can borrow assets from Native's credit vault contract (subject to their credit limit). Market makers only need to pay borrowing fees after a certain period (rates reference perpetual DEX funding rates).

Market makers can choose to operate purely on the credit-based model or utilize both modes simultaneously, significantly improving capital efficiency.

## Repository Structure

[`NativeLPToken.sol`](./src/NativeLPToken.sol) is a yield-bearing token. Each underlying asset corresponds to a unique LP token contract. LP investors can deposit assets through this contract, but unlike traditional ERC20 tokens, deposited assets are transferred to the `CreditVault` contract instead of remaining in the LP token contract.

The yield for NativeLPToken comes from borrowing fees generated when market makers utilize funds from the credit vault.

[`CreditVault.sol`](./src/CreditVault.sol) is Native's core contract holding most assets. All market maker swaps using credit vault assets are executed through this contract.

Example: When Alice sells one ETH at 3000 USDC/ETH, and Halo (market maker) trades using the credit vault, the position changes are reflected as:

```solidity
position[halo][ETH] += 1;
position[halo][USDC] -= 3000;
```

The CreditVault contract provides key functions:
* `settle`: Market makers can close positions
* `repay`: Market makers can repay borrowed assets
* `addCollateral`: Market makers can provide NativeLPToken as collateral
* `removeCollateral`: Market makers can reduce collateral
* `liquidation`: Trusted liquidators can liquidate underwater market maker positions

[`NativeRouter.sol`](./src/NativeRouter.sol) serves as the sole entry point for on-chain interactions between swappers and Native, similar to other DeFi router contracts. Users execute trades by calling the Router contract with Native-provided `calldata` containing market maker-signed quote signatures.

[`NativeRFQPool.sol`](./src/NativeRFQPool.sol) is a supporting contract. Native supports two pool types:

1. `CreditPool`: Uses CreditVault as treasury, handling trades through the credit vault contract
2. `Inventory Pool`: Uses market maker's EOA account as treasury for direct asset exchange

Both pools use the `NativeRFQPool` template contract, primarily differing in their `treasury` address.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```