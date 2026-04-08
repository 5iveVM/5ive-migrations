# Marinade Finance (Liquid Staking) -- 5ive Migration

Marinade Finance, Solana's #1 liquid staking protocol, migrated from ~12,000 lines of Rust to ~450 lines of 5ive DSL.

## What is Marinade?

Marinade lets users deposit SOL and receive mSOL -- a liquid staking token that appreciates over time as validator staking rewards accrue. Unlike native staking which locks SOL for an epoch, mSOL can be traded, used as collateral, or instantly redeemed via the liquidity pool.

### mSOL Exchange Rate

The core mechanic: mSOL price rises as staking rewards flow into `total_sol_staked` while `msol_supply` stays constant.

```
msol_amount = (sol_deposited * msol_supply) / total_sol_staked
sol_amount  = (msol_burned * total_sol_staked) / msol_supply
```

At genesis the rate is 1:1. After one year of ~7% staking APY, 1 mSOL = ~1.07 SOL.

## Instructions

### Core Operations

| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `initialize` | Create the stake pool with fee config, validator limits, and mSOL/LP mints |
| 2 | `deposit` | Deposit SOL, receive mSOL at current exchange rate (minus deposit fee) |
| 3 | `liquid_unstake` | Instant unstake: burn mSOL, receive SOL from liquidity pool (higher fee) |
| 4 | `order_unstake` | Delayed unstake: burn mSOL, create ticket redeemable after epoch boundary |
| 5 | `claim_unstake` | Claim SOL from a completed delayed unstake ticket |

### Validator Management

| # | Instruction | Description |
|---|-------------|-------------|
| 6 | `add_validator` | Add a validator to the pool with an initial score |
| 7 | `remove_validator` | Deactivate a validator (authority only) |
| 8 | `stake_to_validator` | Delegate SOL from pool reserve to a validator via Stake Program CPI |
| 9 | `unstake_from_validator` | Deactivate stake from a validator back to pool |
| 10 | `update_validator_score` | Adjust a validator's delegation weight |
| 11 | `merge_validator_stakes` | Consolidate stake accounts after rebalancing |
| 12 | `withdraw_stake_to_reserve` | Pull deactivated stake back to pool reserve |

### Liquidity Pool (for instant unstake)

| # | Instruction | Description |
|---|-------------|-------------|
| 13 | `add_liquidity` | Deposit SOL into the liquidity pool, receive LP tokens |
| 14 | `remove_liquidity` | Burn LP tokens, withdraw proportional SOL |

### Admin

| # | Instruction | Description |
|---|-------------|-------------|
| 15 | `update_fees` | Change deposit, withdraw, and instant unstake fee rates |
| 16 | `set_authority` | Transfer admin to a new pubkey |
| 17 | `pause` / `unpause` | Emergency controls to halt/resume pool operations |
| 18 | `update_epoch` | Checkpoint staking rewards (increases exchange rate) |
| 19 | `collect_treasury_fees` | Withdraw accumulated protocol fees |

### Read-only Helpers

| Function | Returns |
|----------|---------|
| `get_msol_exchange_rate` | Current mSOL:SOL rate (scaled by 1e9) |
| `quote_deposit` | mSOL a user would receive for a given SOL deposit |
| `quote_liquid_unstake` | SOL a user would receive for instant unstake |
| `quote_order_unstake` | SOL a user would receive for delayed unstake |
| `is_ticket_claimable` | Whether a delayed unstake ticket is redeemable |

## Account Structure

```
StakePool (1024 bytes)
  authority, msol_mint, total_sol_staked, msol_supply,
  deposit_fee_bps, withdraw_fee_bps, instant_unstake_fee_bps,
  treasury, treasury_fees_sol, lp_mint, lp_sol_reserves,
  lp_msol_reserves, lp_supply, num_validators, max_validators,
  min_stake_lamports, last_epoch, is_paused, reserve_pda

ValidatorRecord (512 bytes)
  pool, vote_account, stake_account, active_stake,
  score, last_epoch, is_active

UnstakeTicket (256 bytes)
  pool, owner, msol_amount, sol_amount,
  created_epoch, is_claimed
```

## Key Math

### Fee Calculation

All fees use basis points (bps): `fee = (amount * fee_bps) / 10000`

Maximum 10% (1000 bps) on any fee type. Three independent fee tiers:
- **Deposit fee** -- charged on SOL going in
- **Withdraw fee** -- charged on delayed unstake
- **Instant unstake fee** -- charged on liquid unstake (typically highest)

### LP Token Minting

The liquidity pool uses standard proportional minting:
```
lp_tokens = (sol_amount * lp_supply) / lp_sol_reserves
```

Bootstrap case (empty pool): `lp_tokens = sol_amount` (1:1).

### Epoch Rewards

`update_epoch` adds staking rewards to `total_sol_staked`, appreciating the mSOL exchange rate. Called once per epoch by the pool operator.

## Stake Program CPI

The migration uses a raw interface to the native Stake Program for:
- `delegate_stake` -- delegate SOL to a validator
- `deactivate_stake` -- begin unstaking from a validator
- `merge` -- consolidate stake accounts
- `withdraw` -- pull deactivated stake back to reserve
- `split` -- (available in interface, used for advanced rebalancing)

## Comparison

| Metric | Marinade (Rust) | 5ive DSL |
|--------|-----------------|----------|
| Source lines | ~12,000 | ~450 |
| Bytecode | ~200 KB | ~4 KB |
| Build time | Minutes | Seconds |
| Dependencies | anchor, spl-token, spl-stake-pool | std only |

## Build & Test

```bash
five build
five local execute build/main.five 0
```

## Deploy

```bash
five deploy build/main.five --cluster devnet
```

## Design Decisions

1. **Unified fee accounting**: Treasury fees accumulate on-chain in `treasury_fees_sol` and are collected via a single `collect_treasury_fees` instruction, avoiding per-transaction treasury transfers.

2. **Epoch-based reward checkpointing**: Rather than computing compound interest on-chain, `update_epoch` accepts the total epoch rewards as a parameter. The pool operator (or a cranker) calls this once per epoch, keeping on-chain math simple.

3. **LP pool for instant unstake**: The liquidity pool is a separate SOL reserve funded by LPs who earn trading fees from instant unstake operations. This decouples instant liquidity from the staked SOL, matching Marinade's architecture.

4. **Validator scores**: Score-weighted delegation is tracked per validator. The off-chain delegation bot reads scores to decide how to distribute stake, while on-chain logic enforces authority checks and bookkeeping.

5. **Delayed unstake tickets**: Each `order_unstake` creates an `UnstakeTicket` account. Tickets become claimable when `current_epoch > created_epoch`, matching Solana's epoch-boundary stake deactivation timing.

## Original Source

- [marinade-finance/liquid-staking-program](https://github.com/marinade-finance/liquid-staking-program) (Rust, ~12,000 SLoC)
- [Marinade Documentation](https://docs.marinade.finance/)

## License

MIT
