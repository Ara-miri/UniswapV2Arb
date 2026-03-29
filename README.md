# UniswapV2Arb

A Solidity smart contract for detecting and executing arbitrage opportunities across Uniswap V2 compatible DEXes on Ethereum mainnet. Supports 2-hop and 3-hop trades across multiple routers with on-chain path scanning.

## Features

- **Dual-DEX arbitrage** — 2-hop trade across two different routers
- **Tri-DEX arbitrage** — 3-hop trade across three different routers
- **Path trading** — 4-hop trade on a single router
- **On-chain path scanner** — scans registered `ArbPath` structs to find profitable routes
- **Router registry** — whitelist of approved routers with O(1) lookup via mapping
- **Safe token approvals** — uses OpenZeppelin's `SafeERC20.forceApprove` for non-standard tokens

## Supported DEXes (Ethereum Mainnet)

| DEX            | Router Address                               |
| -------------- | -------------------------------------------- |
| Uniswap V2     | `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` |
| SushiSwap      | `0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F` |
| PancakeSwap V2 | `0xEfF92A263d31888d860bD50809A8D171709b7b1c` |

NOTE: Feel free to add more DEXs but make sure they have liquidities, or desired pools are available.

## Installation

```bash
git clone https://github.com/Ara-miri/UniswapV2Arb.git
cd UniswapV2Arb
forge install
```

## Usage

```bash

# Run mainnet fork tests
forge test --match-path test/UniswapV2ArbMainnetFork.t.sol --fork-url $MAINNET_RPC_URL -vv

# Run fork tests pinned to a specific block for deterministic results
forge test --match-path test/UniswapV2ArbMainnetFork.t.sol --fork-url $MAINNET_RPC_URL --fork-block-number 21900000 -vv
```

Set your RPC URL in `.env`:

```bash
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
```

## Contract Overview

### Router Registry

Routers must be registered before use. The registry uses a `mapping(address => bool)` for O(1) validation in `swap()`, alongside an array for enumeration via `getRouters()`.

```solidity
address[] memory routers = new address[](2);
routers[0] = UNISWAP_V2_ROUTER;
routers[1] = SUSHISWAP_ROUTER;
arb.addRouters(routers);
```

### Path Registration

Register `ArbPath` structs for `findPath` to scan:

```solidity
arb.addPath(WBTC, USDC, UNI);   // baseAsset → WBTC → USDC → UNI → baseAsset
```

### Trade Execution

Always estimate before executing:

```solidity
uint256 estimate = arb.estimateDualDexTrade(router1, router2, token1, token2, amount);
if (estimate > amount) {
    arb.dualDexTrade(router1, router2, token1, token2, amount);
}
```

## Testing

The test suite has two layers:

**Mock tests** (`UniswapV2ArbMock.t.sol`) — isolated unit tests using `MockERC20` and `MockRouter` contracts with configurable exchange rates. Fast, deterministic, no network dependency.

**Fork tests** (`UniswapV2ArbMainnetFork.t.sol`) — integration tests against real mainnet state using `vm.createFork`. Tests run against live Uniswap V2, SushiSwap, and PancakeSwap pools with real token contracts.

## Testing Challenges

### USDT Non-Standard Approval

USDT on Ethereum mainnet does not return a `bool` from `approve()`, contrary to the ERC20 standard. Calling `IERC20.approve()` on USDT causes a silent revert when Solidity tries to ABI-decode the empty return value as `bool`. This manifested as a mysterious `EvmError: Revert` immediately after an `Approval` event in the trace with no error data.

The fix was replacing `IERC20.approve()` with OpenZeppelin's `SafeERC20.forceApprove()`, which handles tokens that return nothing, return `false`, or require a reset to zero before a new approval.

### PancakeSwap Init Code Hash

PancakeSwap V2 on Ethereum uses a different `INIT_CODE_PAIR_HASH` than Uniswap V2 to compute pair addresses internally. This caused `swapExactTokensForTokens` to silently revert on certain token pairs — the router computed a pair address with no deployed code. The fix was to only use PancakeSwap for pairs where its pools are confirmed to exist with sufficient liquidity (WETH/USDC, WETH/USDT, WETH/WBTC).

### Pool Liquidity Discovery

Not every token pair has deep liquidity on every DEX. Naively assuming pools exist led to tests returning 0 or reverting unexpectedly. The solution was a diagnostic test that calls `getAmountOutMin` for each token/router combination and logs results, then only writing tests for combinations where all hops return non-zero values. DAI was excluded from PancakeSwap tests entirely after this revealed no DAI pools on that router.

### Delta-Only Trading

`dualDexTrade` and `triDexTrade` snapshot the contract's intermediate token balance before each leg and compute `tradeableAmount = balanceAfter - balanceBefore`. This ensures any pre-existing token balance is never accidentally swept into a trade. Tests verify this explicitly by pre-seeding the contract with intermediate tokens and asserting those balances are unchanged after execution.

## Limitations

- No flash loan support — the contract must hold capital upfront
- `tradePath` uses a single router for all 4 hops — cannot exploit cross-DEX price differences
- `amountOutMin` is hardcoded to `1` in `swap()` — no slippage protection against sandwich attacks
- Not production-ready for competitive mainnet arbitrage against MEV bots

## License

This project is licensed under the **MIT License** [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
