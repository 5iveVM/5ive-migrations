# 5ive Orca Whirlpools Migration

Orca Whirlpools (concentrated liquidity AMM) rewritten in 5ive DSL. This is the most complex migration in the collection -- it implements Uniswap V3-style concentrated liquidity with Q64.64 fixed-point math, tick arrays, and per-position fee accounting, all in pure integer arithmetic.

## What Orca Whirlpools Does

Whirlpools is a concentrated liquidity automated market maker (CLMM) on Solana. Instead of spreading liquidity across all prices like a constant product AMM (x*y=k), liquidity providers concentrate their capital into specific price ranges. This gives LPs dramatically better capital efficiency and traders tighter spreads.

### Core Concepts

- **Ticks**: Discrete price points where `price = 1.0001^tick`. Range: [-443636, +443636]
- **sqrt_price**: Prices stored as `sqrt(price) * 2^64` in Q64.64 fixed-point (u128)
- **Positions**: Each LP provides liquidity between a `tick_lower` and `tick_upper`
- **Tick Arrays**: Groups of 88 ticks stored in accounts for efficient on-chain traversal
- **Fee Growth**: Global accumulation per unit of liquidity, with per-tick "outside" tracking

## Instructions Implemented

### Pool Lifecycle
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `initialize_config` | Create protocol config (fee authority, collect authority) |
| 2 | `initialize_pool` | Create pool with token pair, tick spacing, initial sqrt_price |
| 3 | `initialize_fee_tier` | Set fee rate for a tick spacing |
| 4 | `initialize_tick_array` | Create tick array account for a tick range |

### Position Management
| # | Instruction | Description |
|---|-------------|-------------|
| 5 | `open_position` | Create LP position with tick_lower, tick_upper |
| 6 | `close_position` | Close position (must have zero liquidity) |

### Liquidity
| # | Instruction | Description |
|---|-------------|-------------|
| 7 | `increase_liquidity` | Add liquidity to a position, deposit tokens |
| 8 | `decrease_liquidity` | Remove liquidity, withdraw tokens |

### Swaps
| # | Instruction | Description |
|---|-------------|-------------|
| 9 | `swap` | Execute swap (a_to_b or b_to_a), walks through tick arrays |

### Fee Collection
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `collect_fees` | Collect accumulated trading fees for a position |
| 11 | `collect_protocol_fees` | Admin collects protocol fee share |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 12 | `set_fee_rate` | Update pool fee rate |
| 13 | `set_protocol_fee_rate` | Update protocol fee share |

## Key Math

### Q64.64 Fixed-Point Arithmetic

All prices and fee growth values use Q64.64 encoding:
- Scale factor: `2^64 = 18,446,744,073,709,551,616`
- Multiply: `(a * b) >> 64` (split into hi/lo to avoid u128 overflow)
- Divide: `(a << 64) / b` (decomposed to stay within u128)

### Tick-to-SqrtPrice Conversion

Uses binary exponentiation with precomputed lookup tables:
- `sqrt(1.0001)^(2^i)` for i=0..18 covers the full tick range
- O(log n) multiplications instead of O(n) iteration
- Separate tables for positive ticks (multiply up) and negative ticks (multiply down)

### Swap Math

For each swap step within a tick range:
- `amount_a = liquidity * (sqrt_upper - sqrt_lower) / (sqrt_upper * sqrt_lower)`
- `amount_b = liquidity * (sqrt_upper - sqrt_lower) / SCALE`
- When a tick boundary is crossed, `liquidity_net` is flipped to update active liquidity

### Liquidity Math

Given token amounts and a price range:
- `liquidity_from_a = amount_a * sqrt_lower * sqrt_upper / (sqrt_upper - sqrt_lower)`
- `liquidity_from_b = amount_b * SCALE / (sqrt_upper - sqrt_lower)`

## Account Structure

```
WhirlpoolConfig (256 bytes)
  fee_authority, collect_protocol_fees_authority, default_protocol_fee_rate

Whirlpool (1024 bytes)
  config, token_mint_a/b, token_vault_a/b, sqrt_price, tick_current_index,
  liquidity, fee_rate, protocol_fee_rate, fee_growth_global_a/b,
  protocol_fees_a/b, tick_spacing, authority

TickArray (2048 bytes)
  pool, start_tick_index, tick_spacing,
  active tick buffer: index, initialized, liquidity_net, liquidity_gross,
  fee_growth_outside_a/b

Position (512 bytes)
  pool, owner, tick_lower/upper_index, liquidity,
  fee_growth_inside_a/b, fees_owed_a/b

FeeTier (256 bytes)
  config, tick_spacing, fee_rate
```

## Comparison

| Metric | Orca (Rust/Anchor) | 5ive DSL |
|--------|-------------------|----------|
| Source lines | ~15,000 | ~1,500 |
| Bytecode | ~300 KB | ~5 KB |
| Build time | Minutes | Seconds |
| Dependencies | anchor, spl-token, spl-math | std only |

## Build & Test

```bash
five build
five local execute build/main.five 0
```

## Design Decisions

1. **Tick array simplification**: The original stores 88 ticks per array in a Rust `[Tick; 88]`. 5ive models this as a single active-tick buffer per array account -- the off-chain client loads the correct array for the current swap step, matching Orca's actual on-chain access pattern.

2. **Binary exponentiation for tick math**: Instead of iterating tick-by-tick (O(n)), we use precomputed power-of-2 tables for `sqrt(1.0001)^(2^i)`, giving O(log n) tick-to-sqrt_price conversion.

3. **Fee growth tracking**: Faithful to Orca's model -- global fee growth per token, per-tick "outside" growth, and position-level "inside" snapshots that allow accurate fee accrual regardless of when a position was last touched.

4. **Swap as single-step**: Each `swap` call processes one tick-range step. Multi-tick swaps are composed by the client calling `swap` repeatedly with the appropriate tick arrays, exactly mirroring Orca's off-chain SDK pattern.

## License

MIT
