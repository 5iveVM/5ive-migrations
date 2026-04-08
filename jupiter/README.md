# 5ive Jupiter DEX Aggregator Migration

Jupiter DEX Aggregator (Solana's #1 swap router) rewritten in 5ive DSL. Implements the complete on-chain instruction set: multi-hop route execution, split routing, limit orders, DCA scheduling, and platform/referral fee splitting.

## What Jupiter Does

Jupiter aggregates liquidity across all Solana AMMs to find the best swap route for any token pair. Its off-chain SDK computes optimal routes (considering multi-hop paths, split routes, and price impact), then the on-chain program executes them trustlessly with slippage protection.

### Core Concepts

- **Route Execution**: Single-hop, 2-hop, and 3-hop swaps through sequential AMM pools
- **Split Routing**: Splitting large orders across 2 pools for the same pair to reduce price impact
- **Limit Orders**: On-chain order book with keeper-driven fills and cross-multiplication price checks
- **DCA (Dollar-Cost Averaging)**: Scheduled periodic buys with keeper-triggered execution
- **Platform Fees**: Configurable basis-point fee on all swap output with referral splitting

### Design Decisions for 5ive

Real Jupiter dispatches to arbitrary external AMMs via CPI at runtime. Since 5ive cannot dynamically dispatch to external programs, swap execution is modeled as internal constant-product AMM logic through Pool accounts. This preserves all the important patterns:

1. Route state tracking and slippage protection
2. Multi-hop execution with intermediate token accounting
3. Split routing logic with configurable split percentage
4. Limit order book with exact cross-multiplication price matching
5. DCA schedule management with keeper incentives
6. Fee splitting (platform + referral)

## Instructions Implemented

### Route Execution
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `initialize` | Set up Jupiter config (admin, platform fee, referral settings) |
| 2 | `route_swap` | Single-hop swap through one AMM pool |
| 3 | `route_swap_two_hop` | 2-hop swap (A->B->C through 2 pools) |
| 4 | `route_swap_three_hop` | 3-hop swap (A->B->C->D through 3 pools) |
| 5 | `split_route_swap` | Split input across 2 pools for same pair, combine output |

### Limit Orders
| # | Instruction | Description |
|---|-------------|-------------|
| 6 | `create_limit_order` | Place limit order with target price, escrow tokens |
| 7 | `cancel_limit_order` | Cancel unfilled order, refund escrowed tokens |
| 8 | `fill_limit_order` | Keeper fills order when price conditions met |
| 9 | `expire_limit_order` | Clean up expired order, refund remaining tokens |

### DCA (Dollar-Cost Averaging)
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `create_dca` | Create DCA schedule, escrow total input upfront |
| 11 | `execute_dca` | Keeper triggers next DCA cycle buy |
| 12 | `cancel_dca` | Cancel DCA, refund remaining escrowed tokens |
| 13 | `close_dca` | Close completed DCA account, reclaim rent |

### Platform Fees & Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 14 | `set_platform_fee` | Update platform fee basis points (max 10%) |
| 15 | `set_referral_fee` | Update referral share percentage (max 100%) |
| 16 | `collect_platform_fees` | Withdraw accumulated fees to fee collector |
| 17 | `set_authority` | Transfer admin to new authority |
| 18 | `pause` | Emergency pause all operations |
| 19 | `unpause` | Resume operations |

### Read-Only Queries
| Instruction | Description |
|-------------|-------------|
| `get_total_volume` | Total volume routed through Jupiter (u128) |
| `get_total_routes` | Total swap routes executed |
| `get_platform_fee_bps` | Current platform fee in basis points |
| `get_order_status` | Whether a limit order is active |
| `get_order_filled` | Amount of input filled on a limit order |
| `get_order_remaining` | Unfilled input remaining on a limit order |
| `get_dca_cycles_remaining` | Remaining DCA cycles |
| `get_dca_next_execution` | Timestamp of next DCA execution |
| `get_dca_total_output` | Total output received across all DCA cycles |
| `quote_swap` | Quote a single-hop swap without executing |
| `check_limit_price` | Check if limit order price condition is met |

## Account Structure

### JupiterConfig (512 bytes)
Global program configuration. One per deployment.

| Field | Type | Description |
|-------|------|-------------|
| authority | pubkey | Admin who can update config |
| platform_fee_bps | u64 | Fee in basis points (0-1000) |
| referral_fee_share | u64 | % of platform fee to referrer (0-100) |
| fee_collector | pubkey | Where platform fees accumulate |
| total_volume | u128 | Cumulative volume routed |
| total_routes_executed | u64 | Total swaps executed |
| is_paused | bool | Emergency pause flag |

### RouteState (512 bytes)
Created per swap execution. Records route details for analytics and verification.

| Field | Type | Description |
|-------|------|-------------|
| config | pubkey | Jupiter config reference |
| user | pubkey | Swapper |
| input_mint / output_mint | pubkey | Token pair |
| amount_in | u64 | Input amount |
| minimum_out | u64 | Slippage limit |
| actual_out | u64 | Actual output received |
| num_hops | u8 | Number of hops (1, 2, or 3) |
| platform_fee_amount | u64 | Fee charged |
| referral_fee_amount | u64 | Referral portion |
| timestamp | u64 | Execution time |

### LimitOrder (512 bytes)
On-chain limit order with partial fill support.

| Field | Type | Description |
|-------|------|-------------|
| owner | pubkey | Order creator |
| input_mint / output_mint | pubkey | Token pair |
| input_amount | u64 | Total input to sell |
| minimum_output | u64 | Minimum total output (defines target price) |
| filled_input / filled_output | u64 | Fill progress |
| expiry_timestamp | u64 | Order expiration |
| is_active | bool | Whether order can be filled |
| order_id | u64 | Unique identifier |

### DcaSchedule (512 bytes)
Dollar-cost averaging schedule.

| Field | Type | Description |
|-------|------|-------------|
| owner | pubkey | Schedule creator |
| input_mint / output_mint | pubkey | Token pair |
| amount_per_cycle | u64 | Input per execution |
| cycle_frequency | u64 | Seconds between executions |
| total_cycles | u64 | Total planned executions |
| cycles_executed | u64 | Completed executions |
| total_input_spent / total_output_received | u64 | Running totals |
| next_execution | u64 | Next eligible timestamp |
| is_active | bool | Whether schedule is live |
| min_output_per_cycle | u64 | Per-cycle slippage limit |

### Pool (512 bytes)
Internal AMM pool modeling external liquidity sources.

| Field | Type | Description |
|-------|------|-------------|
| token_a_mint / token_b_mint | pubkey | Token pair |
| token_a_vault / token_b_vault | pubkey | Token vaults |
| reserve_a / reserve_b | u64 | Pool reserves |
| fee_bps | u64 | Pool swap fee |
| is_active | bool | Pool status |

## Key Math

### Constant Product Swap
```
fee = (amount_in * fee_bps) / 10000
net_in = amount_in - fee
amount_out = (reserve_out * net_in) / (reserve_in + net_in)
```

### Platform Fee
```
platform_fee = (amount_out * platform_fee_bps) / 10000
referral_fee = (platform_fee * referral_fee_share) / 100
net_to_user = amount_out - platform_fee
```

### Limit Order Price Check (cross-multiplication)
```
// Avoids division, no rounding issues:
require(raw_output * order.input_amount >= order.minimum_output * fill_amount)
```

### DCA Timing
```
require(now >= schedule.next_execution)
schedule.next_execution = now + schedule.cycle_frequency
```

### Split Route
```
amount_leg_a = (total_input * split_bps) / 10000
amount_leg_b = total_input - amount_leg_a
total_output = execute(pool_a, leg_a) + execute(pool_b, leg_b)
```

## Build

```bash
five build
five deploy --cluster devnet
```

## Source Protocol

- **Jupiter**: https://jup.ag
- **Program ID**: `JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4`
- **Docs**: https://station.jup.ag/docs
