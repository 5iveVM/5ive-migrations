# 5ive Hadeswap Migration

Hadeswap (NFT AMM with bonding curves) rewritten in 5ive DSL. Instant buy/sell NFTs through liquidity pools with linear or exponential bonding curves. Predecessor to Tensor AMM.

## What Hadeswap Does

Hadeswap is an NFT AMM on Solana where pools hold NFTs and SOL. A bonding curve (linear or exponential) determines the price, which automatically adjusts after each trade. Pool owners can set the curve parameters and earn fees from trades.

### Core Concepts

- **Pool types**: Buy-only (0), Sell-only (1), Trade/two-way (2)
- **Curve types**: Linear (0) -- price changes by +/- delta per trade; Exponential (1) -- price changes by delta bps per trade
- **Spot price**: Current price point on the bonding curve; moves up on buys, down on sells
- **Delta**: Step size for price adjustments (flat amount for linear, bps for exponential)
- **NFTs as SPL tokens**: Each NFT is an SPL token with supply=1, transferred via spl_token::transfer

## Instructions Implemented

### Pool Lifecycle
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_pool` | Create pool with collection, curve type, spot price, delta, fee |

### Deposit Assets
| # | Instruction | Description |
|---|-------------|-------------|
| 2 | `deposit_nft_to_pool` | Pool owner deposits NFT (sell/trade pools) |
| 3 | `deposit_sol_to_pool` | Pool owner deposits SOL (buy/trade pools) |

### Trading
| # | Instruction | Description |
|---|-------------|-------------|
| 4 | `buy_nft` | Buy NFT from pool at current spot price + fee |
| 5 | `sell_nft` | Sell NFT to pool at current spot price - fee |

### Withdraw Assets
| # | Instruction | Description |
|---|-------------|-------------|
| 6 | `withdraw_nft` | Owner withdraws NFT from pool |
| 7 | `withdraw_sol` | Owner withdraws SOL from pool |

### Pool Configuration
| # | Instruction | Description |
|---|-------------|-------------|
| 8 | `modify_pool` | Change delta, fee, spot price |
| 9 | `close_pool` | Close empty pool |
| 10 | `set_pool_type` | Switch between buy/sell/trade |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 11 | `collect_fees` | Withdraw accumulated trading fees |
| 12 | `set_authority` | Transfer pool authority |
| 13 | `pause` | Deactivate pool |
| 14 | `unpause` | Reactivate pool |

## Accounts

- **Pool** -- authority, collection_mint, pool_type (u8), curve_type (u8), spot_price, delta, fee_bps, sol_balance, nft_count, total_volume, is_active
- **PoolNft** -- pool, nft_mint (tracks each NFT in the pool)

## Key Math

- **Linear curve**: After buy: `new_price = spot + delta`. After sell: `new_price = spot - delta`.
- **Exponential curve**: After buy: `new_price = spot + spot * delta / 10000`. After sell: `new_price = spot - spot * delta / 10000`.
- **Sell payout**: `payout = spot_price - (spot_price * fee_bps / 10000)`
- **Buy cost**: `cost = spot_price + (spot_price * fee_bps / 10000)`
