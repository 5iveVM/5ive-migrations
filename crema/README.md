# 5ive Crema Finance Migration

Crema Finance (concentrated liquidity AMM) rewritten in 5ive DSL. Like Orca Whirlpools but simpler: no reward system, no position bundles, no adaptive fees. Core concentrated liquidity math only.

## What Crema Finance Does

Crema is a concentrated liquidity AMM on Solana where LPs provide liquidity within specific price ranges (tick_lower to tick_upper) for dramatically better capital efficiency vs constant-product AMMs. Fees accrue only to in-range positions.

### Core Concepts

- **Ticks**: Discrete price points; positions span [tick_lower, tick_upper]
- **sqrt_price**: Price stored as sqrt(price) in Q64.64 fixed-point (u128)
- **Tick arrays**: Groups of ticks stored in accounts with liquidity_net/gross + fee_growth_outside
- **Fee growth**: Global per-unit-liquidity accumulator; positions track "inside" growth snapshots
- **Concentrated liquidity**: Only token A needed below range, only token B above, both in range

## Instructions Implemented

### Pool Lifecycle
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_pool` | Create pool with token pair, fee_rate, tick_spacing, initial price |
| 2 | `init_tick_array` | Create tick array for a tick range |

### Position Management
| # | Instruction | Description |
|---|-------------|-------------|
| 3 | `open_position` | Create LP position with tick_lower, tick_upper |
| 4 | `close_position` | Close position (must have zero liquidity and fees) |

### Liquidity
| # | Instruction | Description |
|---|-------------|-------------|
| 5 | `increase_liquidity` | Add liquidity, deposit tokens, accrue fees |
| 6 | `decrease_liquidity` | Remove liquidity, withdraw tokens |

### Swap
| # | Instruction | Description |
|---|-------------|-------------|
| 7 | `swap` | Execute swap through pool liquidity (a_to_b or b_to_a) |

### Fee Collection
| # | Instruction | Description |
|---|-------------|-------------|
| 8 | `collect_fees` | Collect accumulated trading fees for a position |
| 9 | `collect_protocol_fees` | Admin collects protocol fee share |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `set_fee_rate` | Update pool fee rate |
| 11 | `set_protocol_fee` | Update protocol fee share |
| 12 | `set_authority` | Transfer pool authority |
| 13 | `pause` | Pause pool |
| 14 | `unpause` | Unpause pool |

## Accounts

- **Pool** -- token mints/vaults, sqrt_price (u128), tick_current (i64), liquidity (u128), fee_rate, fee_growth_global_a/b (u128)
- **TickArray** -- pool, start_index, per-tick: liquidity_net (i128), liquidity_gross (u128), fee_growth_outside_a/b (u128)
- **Position** -- pool, owner, tick_lower/upper, liquidity (u128), fee_growth_inside_last_a/b, fees_owed_a/b

## Key Math

- Fee growth inside = global - below - above (Uniswap V3 formula)
- Swap output: `amount_out = (amount_after_fee * liquidity) / (liquidity + amount_after_fee)`
- Fee distribution: `fee_growth_delta = (lp_fee << 64) / liquidity` (Q64.64)
- Position fees: `owed += (liquidity * (fee_inside - last_snapshot)) >> 64`
