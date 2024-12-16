# Native v2 Core

## What's new in v2

### Remove Compound Code

The V1 code was overly bloated, inheriting too much unnecessary code from `Compound`

### Remove Upgradeable Model
 
We discarded `upgradeable` model and continue using `non-upgradeable` model, we believe this is more safer

### New LP Token 

LP token is a `yield-bearing` token, similar to `Lido`'s `stETH`

### Auto-sign

which is built on the `RFQ` (Request for Quote)

`RFQ Mechanism`

1. The swapper submits a price inquiry request to the Native API.
2. The Native backend forwards this inquiry to a partner private market maker (`PMM`).
3. The PMM returns a signed quote.
4. The Native backend builds all information into `calldata` and sends it back to the swapper.
5. The swapper invokes the NativeRouter contract to complete the trade.

 `Auto-sign Mechanism`

 1. Market makers actively push their signed order books to the Native backend.
 2. The Native backend uses this order book to match and complete transactions directly based on the swapper's trade request.

 `Benefits for Auto-sign`
 1. The swapper's trade request interacts solely with the Native API.
 3. This streamlined process significantly reduces transaction latency and improve the success rate

### Funding rate Fee

The `V1` LP token was based on Compound's `cToken`, accruing borrow fees as interest. To streamline the contract, we removed unnecessary Compound code.

In `V2`, market makers borrow LP token assets from the `Credit Vault` for quotes, with a funding rate mechanism replacing automatic interest. The funding fee rate updates every 8 hours. Timely repayment incurs no fee; otherwise, the fee is distributed to LP holders via the `distributeYield` interface.


Due to the need for `compatibility` with V1's existing interface, the RFQ trading logic and data structure remain largely unchanged.

## Architecture

Native `V2` still follows the Native `V1` architecture, with slight differences in the `Auto-sign` flow. For details, you can refer to the the Auto-sign section above.

# WIP

* more documentation 
* gas optimization
* more `foundry`invariant test 
* `echina `(property-based) test
* formal verification `certora`

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