# Native V2 Core

This repository contains the open-source core smart contracts for [Native](https://defillama.com/protocol/native). The code is maintained at [Native-org/native-v2-core](https://github.com/Native-org/native-v2-core/).

Native V2 is an intent-based DeFi liquidity protocol that combines RFQ execution, inventory liquidity, and credit-backed market making.

**RFQ execution · Credit Vault · Yield-bearing LP tokens · Liquidity incentives**

## Overview

Users submit an intent to swap one asset for another. Native can execute the trade against a firm quote from a market maker or route to an approved external swap source, with the router enforcing the signed terms and minimum output.

For market makers, Native supports both fully funded inventory trading and credit-backed trading. In the latter model, liquidity resides in the credit vault and a market maker's resulting asset exposure is tracked as a position rather than requiring it to pre-fund every trade.

```text
LPs ──deposit──> NativeLPToken ──assets──> CreditVault
                                            │
User ──signed intent──> NativeRouter ──> NativeRFQPool
                                            │
                  RFQ market maker ─────────┴──> inventory or credit-backed settlement
```

## Trading and Credit Model

Native supports two primary settlement models:

1. **Inventory Pool** — a market maker settles a firm RFQ quote from its own treasury.
2. **Credit Pool** — a market maker settles through the `CreditVault`, subject to its configured credit and collateral settings.

For example, if Alice sells 10 ETH at 3,000 USDC per ETH, an inventory-based market maker needs 30,000 USDC available before execution. In the credit-backed model, the vault can provide that liquidity and record the market maker's resulting position:

```solidity
position[marketMaker][ETH] += 10;
position[marketMaker][USDC] -= 30_000;
```

Market makers can settle positions, repay borrowed assets, add or remove LP-token collateral, and be liquidated when necessary. Fees accrued from credit usage can be distributed to LPs.

## Contracts

### Core

- [`NativeRouter.sol`](./src/NativeRouter.sol) — the user-facing entry point for signed RFQ trades, native ETH/WETH handling, multicalls, widget fees, and approved external swaps.
- [`NativeRFQPool.sol`](./src/NativeRFQPool.sol) — verifies market-maker quotes and transfers assets from either an inventory treasury or the credit vault.
- [`CreditVault.sol`](./src/CreditVault.sol) — holds protocol liquidity and manages market support, positions, collateral, settlement, repayment, liquidation, and funding-fee accounting.
- [`NativeLPToken.sol`](./src/NativeLPToken.sol) — a share-based, yield-bearing LP token. Underlying assets are held in the `CreditVault` rather than the token contract.

### Periphery

- [`WrappedNLP.sol`](./src/WrappedNLP.sol) — wraps NLP into a fixed-balance token and supports deposit-and-wrap and instant redemption flows.
- [`WithdrawQueue.sol`](./src/WithdrawQueue.sol) — provides delayed wNLP withdrawals, redemption snapshots, and optional affiliate fees.
- [`Sentinel.sol`](./src/periphery/Sentinel.sol) — coordinates emergency pause and recovery operations for registered traders and credit pools.
- [`LiquidityPairing.sol`](./src/periphery/LiquidityPairing.sol) — creates protocol-specific liquidity pools: LPs stake Native LP tokens to dedicate liquidity to a partner protocol's market makers, while the partner funds up to additional reward tokens to incentivize deposits.

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git submodules initialized for `forge-std` and OpenZeppelin Contracts

```shell
git submodule update --init --recursive
```

### Build

```shell
forge build
```

### Test

```shell
forge test
```

If the local Foundry signature cache or OpenChain client is unavailable, run the complete suite offline:

```shell
forge test --offline
```

Run a single test contract or test case:

```shell
forge test --match-contract NativeRouterTest
forge test --match-test test_tradeRFQWithCredit
```

### Format

```shell
forge fmt
```

### Deployment scripts

Core deployment scripts live in [`script/`](./script), and network-specific settings are stored in [`script/chain-config/`](./script/chain-config). Scripts read their deployment configuration from environment variables; never commit private keys or other secrets.
