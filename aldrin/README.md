# Aldrin DEX -- 5ive DSL Migration

**A full-featured Solana DEX (AMM + CLOB + concentrated liquidity + farming), rewritten from ~12,000 lines of Rust to ~1,100 lines of 5ive.**

Aldrin is a composable Solana DEX that combines two trading mechanisms -- constant-product AMM pools and an on-chain central limit order book (CLOB) -- with concentrated liquidity and yield farming. This migration faithfully reproduces all core on-chain logic in 5ive DSL.

## What's Covered

### AMM Pool (Constant Product)

| Instruction | Description |
|-------------|-------------|
| `initialize_pool` | Create pool with token pair, fee config |
| `deposit_liquidity` | Add proportional liquidity (bootstrap or proportional), mint LP tokens |
| `withdraw_liquidity` | Burn LP tokens, receive pro-rata share (works when paused) |
| `swap` | Constant-product swap with fee splitting and slippage protection |
| `swap_with_routing` | Multi-hop swap through two pools (A -> B -> C) |

### Order Book (CLOB)

| Instruction | Description |
|-------------|-------------|
| `create_market` | Initialize order book for a trading pair |
| `place_limit_order` | Place bid/ask at a specific price with token locking |
| `place_market_order` | Execute against a resting order at its price |
| `cancel_order` | Cancel open order, refund locked tokens |
| `cancel_all_orders` | Batch cancel two orders per call (chain for more) |
| `match_orders` | Crank: match crossing bid/ask with price-time priority |
| `settle_funds` | Settle matched trades, release tokens to users |

### Concentrated Liquidity

| Instruction | Description |
|-------------|-------------|
| `create_concentrated_pool` | Pool with tick-based ranges and sqrt_price tracking |
| `add_concentrated_liquidity` | Provide liquidity in [tick_lower, tick_upper] range |
| `remove_concentrated_liquidity` | Remove position liquidity with accrued fees |
| `concentrated_swap` | Swap through concentrated liquidity with price update |

### Farming / Rewards

| Instruction | Description |
|-------------|-------------|
| `create_farm` | Create yield farm for an LP token (MasterChef model) |
| `stake_lp` | Stake LP tokens to earn rewards |
| `unstake_lp` | Unstake with automatic reward payout |
| `claim_rewards` | Claim accumulated rewards without unstaking |
| `update_rewards` | Admin: fund farm vault and update emission rate |

### Admin

| Instruction | Description |
|-------------|-------------|
| `set_pool_fees` / `set_concentrated_pool_fees` | Update fee rates |
| `set_pool_authority` / `set_market_authority` / etc. | Transfer admin |
| `set_pool_paused` / `set_concentrated_pool_paused` | Emergency pause |
| `set_market_active` | Activate/deactivate order book |
| `collect_protocol_fees` / `collect_concentrated_protocol_fees` | Withdraw protocol revenue |

## Key Design Decisions

### Dual Trading Engine

Aldrin's distinguishing feature is combining AMM and CLOB. The AMM handles passive liquidity with constant-product pricing, while the order book serves active traders who want price control. Both operate independently with separate account structures, allowing composability.

### Fee Architecture

```
total_fee    = amount_in * fee_numerator / fee_denominator
protocol_fee = amount_in * protocol_fee_numerator / fee_denominator
lp_fee       = total_fee - protocol_fee (stays in reserves)
```

LP fees compound automatically by remaining in pool reserves, increasing LP token value over time. Protocol fees accumulate separately and are withdrawable by the admin.

### Order Book Mechanics

- **Token locking**: Bids lock quote tokens, asks lock base tokens at order placement
- **Price-time priority**: When matching, the earlier (resting) order's price is used
- **Partial fills**: Orders track `filled` vs `size`, remaining is refundable on cancel
- **Batch operations**: `cancel_all_orders` processes two orders per call; clients chain multiple calls
- **Two-phase settlement**: `match_orders` records fills, `settle_funds` transfers tokens

### Concentrated Liquidity

Simplified tick-based model inspired by Uniswap V3 / Orca Whirlpools:

- Positions specify `[tick_lower, tick_upper]` range aligned to `tick_spacing`
- Token requirements depend on current tick vs position range
- Active liquidity only counts positions whose range includes the current tick
- `sqrt_price` (u128) tracks the current price and updates on each swap

### Farming Rewards (MasterChef)

```
accumulated_reward_per_share += (elapsed * reward_per_second * 1e12) / total_staked
pending = (staked * acc_per_share / 1e12) - reward_debt
```

Global accumulator updates lazily on every stake/unstake/claim. Each user's `reward_debt` snapshots their checkpoint, ensuring fair distribution proportional to stake duration.

### Safety

- Withdrawals (LP and concentrated) work even when the pool is paused
- All vault accounts validated against stored pubkeys before any transfer
- Slippage protection on every swap variant
- Order cancellation always refunds remaining tokens

## Account Layout

```
AmmPool (1024 bytes)
  token_a_mint            pubkey    Token A mint
  token_b_mint            pubkey    Token B mint
  token_a_vault           pubkey    Pool vault for token A
  token_b_vault           pubkey    Pool vault for token B
  lp_mint                 pubkey    LP token mint
  reserve_a               u64       Token A reserves
  reserve_b               u64       Token B reserves
  lp_supply               u64       Outstanding LP tokens
  fee_numerator           u64       Total fee numerator
  fee_denominator         u64       Fee denominator
  protocol_fee_numerator  u64       Protocol's share of fees
  protocol_fees_a         u64       Accumulated protocol fees (A)
  protocol_fees_b         u64       Accumulated protocol fees (B)
  authority               pubkey    Admin authority
  is_paused               bool      Emergency pause flag

OrderBook (512 bytes)
  market_id               u64       Unique market identifier
  base_mint               pubkey    Base token mint
  quote_mint              pubkey    Quote token mint
  base_vault              pubkey    Base token vault
  quote_vault             pubkey    Quote token vault
  min_order_size          u64       Minimum order size
  tick_size               u64       Price tick granularity
  authority               pubkey    Admin authority
  is_active               bool      Market active flag
  next_order_id           u64       Auto-incrementing order ID

Order (512 bytes)
  market                  pubkey    Parent order book
  owner                   pubkey    Order owner
  side                    u8        0=bid, 1=ask
  price                   u64       Limit price (scaled by 1e6)
  size                    u64       Total order size
  filled                  u64       Amount filled
  order_id                u64       Unique order ID
  timestamp               u64       Placement time
  is_active               bool      Whether order is live

ConcentratedPool (1024 bytes)
  (AmmPool fields)        ...       Same as AmmPool
  tick_spacing            u16       Tick alignment granularity
  sqrt_price              u128      Current sqrt price
  tick_current            i64       Current tick index
  liquidity               u128      Active liquidity in range

ConcentratedPosition (512 bytes)
  pool                    pubkey    Parent concentrated pool
  owner                   pubkey    Position owner
  tick_lower              i64       Lower tick boundary
  tick_upper              i64       Upper tick boundary
  liquidity               u128      Position liquidity
  fees_owed_a             u64       Accrued fees (token A)
  fees_owed_b             u64       Accrued fees (token B)

Farm (512 bytes)
  pool_mint               pubkey    LP token mint to stake
  reward_mint             pubkey    Reward token mint
  reward_vault            pubkey    Reward token vault
  reward_per_second       u64       Emission rate
  total_staked            u64       Total LP tokens staked
  accumulated_reward_per_share u128 Global reward accumulator (scaled 1e12)
  last_update             u64       Last update timestamp
  authority               pubkey    Farm admin

StakeRecord (512 bytes)
  farm                    pubkey    Parent farm
  owner                   pubkey    Staker
  staked_amount           u64       Tokens staked
  reward_debt             u128      Reward debt checkpoint
  pending_rewards         u64       Unclaimed rewards
```

## Comparison

| Metric | Rust/Anchor (Original) | 5ive DSL |
|--------|----------------------|----------|
| Source lines | ~12,000 | ~1,100 |
| Instructions | 24+ | 28 (pub fns) |
| Account types | 7 | 7 |
| Bytecode | ~400 KB | ~8 KB |
| Deploy cost | ~6 SOL | ~0.06 SOL |
| Compute units | Baseline | ~60% less |
| Build time | Minutes (Rust compile) | Seconds |

## Build

```bash
five build
five local execute build/main.five 0   # Test initialize_pool
five local execute build/main.five 3   # Test swap
five local execute build/main.five 6   # Test place_limit_order
five local execute build/main.five 13  # Test create_concentrated_pool
five local execute build/main.five 17  # Test stake_lp
```

## Deploy

```bash
five deploy build/main.five --cluster devnet
```

## Original Protocol

- **Name**: Aldrin DEX
- **Category**: AMM + CLOB + Concentrated Liquidity + Farming
- **Chain**: Solana
- **Notable**: One of the few Solana DEXes combining AMM and order book in a single protocol

## License

MIT
