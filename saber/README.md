# Saber StableSwap -- 5ive Migration

Saber's StableSwap protocol migrated from ~3,000 lines of Rust to ~250 lines of 5ive DSL.

## What is Saber StableSwap?

Saber is the original Solana stableswap -- a two-token AMM optimized for assets that should trade near parity (USDC/USDT, mSOL/SOL, etc.). It implements Curve Finance's StableSwap invariant:

```
A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
```

The amplification coefficient `A` controls how closely the curve approximates constant-sum (A = infinity) vs. constant-product (A = 0). Higher A means tighter spreads for same-peg assets.

## Instructions

| Instruction | Description |
|---|---|
| `initialize` | Create a new stable pool with token pair, amplification coefficient, and fee config |
| `deposit` | Add liquidity (one or both tokens), mint LP tokens proportional to invariant change |
| `withdraw` | Remove liquidity proportionally, burn LP tokens |
| `swap` | Exchange one token for the other using the StableSwap curve |
| `withdraw_one` | Remove liquidity as a single token (imbalanced withdrawal) |
| `ramp_a` | Begin gradually adjusting the amplification coefficient over time |
| `stop_ramp_a` | Cancel an ongoing A ramp, freeze at current value |
| `set_fees` | Update trade/withdraw/admin fee configuration |
| `pause` / `unpause` | Emergency controls to halt pool operations |
| `set_admin` | Transfer admin authority |
| `collect_admin_fees` | Withdraw accumulated protocol fees |

## Key Math

### `compute_d` -- Find the pool invariant

Uses Newton's method to solve for D given token balances and amplification A. For n=2:

```
d_p = D^3 / (4 * x * y)
D_new = (A*4*S + d_p*2) * D / ((A*4 - 1)*D + 3*d_p)
```

Converges when `|D_new - D_prev| <= 1`. Maximum 256 iterations.

### `compute_y` -- Find output balance

Given one token balance and the invariant D, solve for the other token's balance:

```
c = D^3 / (4 * A*4 * x)
b = x + D / (A*4)
y_new = (y^2 + c) / (2*y + b - D)
```

### Amplification ramping

A can be gradually adjusted between `initial_amp` and `target_amp` over a configurable duration (minimum 1 day). Linear interpolation between start and stop timestamps. Maximum 10x change per ramp.

### Fee structure

Four independent fee tiers using numerator/denominator pairs:
- **Trade fee** -- charged on swap output
- **Withdraw fee** -- charged on proportional and single-sided withdrawals
- **Admin trade fee** -- protocol's share of trade fees
- **Admin withdraw fee** -- protocol's share of withdraw fees

## Build

```bash
five build
five local execute build/main.five 0
```

## Deploy

```bash
five deploy build/main.five --cluster devnet
```

## Original Source

- [saber-hq/stable-swap](https://github.com/saber-hq/stable-swap) (Rust, ~3,000 SLoC)
- [Curve StableSwap whitepaper](https://curve.fi/files/stableswap-paper.pdf)

## License

MIT
