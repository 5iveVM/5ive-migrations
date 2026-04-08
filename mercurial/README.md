# Mercurial Finance (Stable AMM) -- 5ive Migration

Mercurial's multi-token stable AMM migrated from ~5,000 lines of Rust to ~750 lines of 5ive DSL.

## What is Mercurial Finance?

Mercurial is a multi-token stable AMM on Solana, analogous to Curve's 3pool/4pool. Unlike Saber (which supports exactly 2 tokens), Mercurial supports **2-4 token stable pools** with dynamic fees, amplification ramping, and vault strategies for idle liquidity yield optimization.

The protocol generalizes Curve's StableSwap invariant for N tokens (2 <= N <= 4):

```
A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
```

Where `A` is the amplification coefficient and `n` is the number of tokens in the pool.

## Instructions

| Instruction | Description |
|---|---|
| `create_pool` | Create a stable pool with 2-4 tokens, amplification coefficient, and fee config |
| `add_liquidity` | Deposit any combination of pool tokens, mint LP proportional to invariant change |
| `remove_liquidity` | Burn LP tokens, receive proportional share of all pool tokens |
| `remove_liquidity_one_token` | Withdraw as a single token with imbalance fee |
| `swap` | Swap between any two tokens in the pool using StableSwap math |
| `ramp_amplification` | Gradually change A coefficient over time (min 1 day, max 10x) |
| `stop_ramp` | Freeze A at its current interpolated value |
| `set_fees` | Update trade/admin/withdraw fee configuration |
| `create_vault` | Create a vault strategy for idle pool liquidity (yield optimization) |
| `deposit_to_vault` | Move idle liquidity from pool to vault strategy |
| `withdraw_from_vault` | Pull liquidity back from vault strategy to pool |
| `set_vault_strategy` | Configure or update vault yield strategy |
| `collect_admin_fees` | Withdraw accumulated admin fees from all pool tokens |
| `set_admin` | Transfer admin authority to a new address |
| `pause` | Emergency halt -- blocks swaps, deposits, and withdrawals |
| `unpause` | Resume pool operations after a pause |
| `get_reserve` | View reserve balance for a given token index |
| `get_lp_supply` | View current LP token supply |
| `get_amp` | View current interpolated amplification coefficient |
| `get_admin_fee` | View accumulated admin fee for a given token index |
| `get_num_tokens` | View the number of active tokens in the pool |

## Accounts

### StablePool

The central pool state account holding:
- **Token configuration**: `token_mint_1..4`, `vault_1..4` (unused slots zeroed)
- **Reserves**: `reserve_1..4` tracked on-chain for invariant math
- **Pool size**: `num_tokens` (2, 3, or 4)
- **LP tracking**: `lp_mint`, `lp_supply`
- **Amplification**: `initial_amp`, `target_amp`, `ramp_start_ts`, `ramp_stop_ts`
- **Fees**: trade/admin/withdraw fee numerator/denominator pairs
- **Admin fees**: `admin_fee_1..4` accumulated per token
- **Admin**: `admin` pubkey, `is_paused` flag

### Vault

Per-token vault strategy account for yield optimization on idle liquidity:
- `pool`, `token_mint`, `token_vault`
- `strategy_type` (0=lending, 1=staking, 2=farming)
- `strategy_program`, `deposited_amount`, `last_harvest_slot`
- `admin`, `is_active`

## Key Math

### N-token StableSwap invariant (`compute_d_N`)

Separate Newton's method implementations for N=2, 3, and 4 tokens. For N tokens:

```
ann = A * n^n
d_p = D^(n+1) / (n^n * prod(x_i))
D_new = (ann * S + d_p * n) * D / ((ann - 1) * D + (n+1) * d_p)
```

| N | n^n | d_p divisor per token |
|---|---|---|
| 2 | 4 | 2 * x_i |
| 3 | 27 | 3 * x_i |
| 4 | 256 | 4 * x_i |

Converges when `|D_new - D_prev| <= 1`. Maximum 256 iterations.

### Output balance (`compute_y_N`)

Given known token balances and invariant D, solve for the unknown balance via Newton's method:

```
c = D^(n+1) / (ann * n^(n-1) * prod(known_balances))
b = sum(known_balances) + D / ann
y_new = (y^2 + c) / (2*y + b - D)
```

### Amplification ramping

Linear interpolation between `initial_amp` and `target_amp` over `[ramp_start_ts, ramp_stop_ts]`. Enforced constraints:
- Minimum ramp duration: 1 day (86400 seconds)
- Maximum change per ramp: 10x
- Valid range: 1 <= A <= 1,000,000

### Fee structure

Four independent fee tiers using numerator/denominator pairs:
- **Trade fee** -- charged on swap output amount
- **Admin trade fee** -- protocol's share of trade fees
- **Withdraw fee** -- charged on proportional and single-sided withdrawals
- **Admin withdraw fee** -- protocol's share of withdraw fees

Imbalanced deposits and single-token withdrawals incur additional fees based on deviation from the ideal balanced state.

## Key differences from Saber migration

| Feature | Saber | Mercurial |
|---|---|---|
| Token count | 2 only | 2, 3, or 4 |
| Invariant math | N=2 specialized | Generalized for N=2,3,4 |
| Swap routing | A-to-B or B-to-A | Any pair via token index |
| Vault strategies | None | Lending, staking, farming |
| Account size | 1024 bytes | 2048 bytes |

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

- [mercurial-finance/mercurial-dynamic-amm-sdk](https://github.com/mercurial-finance/mercurial-dynamic-amm-sdk) (Rust, ~5,000 SLoC)
- [Curve StableSwap whitepaper](https://curve.fi/files/stableswap-paper.pdf)

## License

MIT
