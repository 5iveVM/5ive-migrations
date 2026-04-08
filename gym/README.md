# Gym Liquidity Bootstrapping & Incentive Protocol

A 5ive DSL migration of the Gym liquidity protocol -- tools for new tokens to bootstrap liquidity through Liquidity Bootstrapping Pools (LBPs), bonding curves, reward vaults, and liquidity locks.

## Overview

Gym provides the complete liquidity lifecycle for new token launches. Projects can use LBPs for fair price discovery, bonding curves for continuous token sale, reward vaults to incentivize LP providers, and liquidity locks to signal long-term commitment.

## Architecture

### Accounts

| Account | Description |
|---------|-------------|
| **LBP** | Liquidity Bootstrapping Pool: token pair, time-weighted shifting weights, reserves, fees |
| **BondingCurve** | Programmable pricing curve: linear/exponential/sigmoid, slope, supply, reserve, graduation threshold |
| **RewardVault** | Staking reward distribution: stake/reward mints, emission rate, accumulated rewards |
| **StakePosition** | Per-user stake: amount, reward debt, pending rewards |
| **LiquidityLock** | LP token lock: amount, unlock time, lock status |

### Curve Types

- `0` -- Linear: `price = base + slope * supply / 1000`
- `1` -- Exponential: `price = base + base * slope * supply / 1000000`
- `2` -- Sigmoid: `price = base + slope * supply / (1000 + supply)`

### LBP Weight Mechanics

Weights are expressed in basis points (10000 = 100%). A typical LBP starts at 9000/1000 (90% project token / 10% quote token) and shifts linearly to 5000/5000 (50/50) over the pool duration. This creates natural sell pressure that enables fair price discovery.

## Instructions (22)

### Liquidity Bootstrapping Pool
1. `create_lbp` -- Create a pool with time-weighted shifting weights
2. `update_lbp_weights` -- Crank: advance weight shift based on elapsed time
3. `swap_lbp` -- Swap during the LBP (price discovery via weighted AMM)
4. `close_lbp` -- End the LBP, withdraw remaining tokens

### Bonding Curves
5. `create_bonding_curve` -- Create a bonding curve (linear, exponential, sigmoid)
6. `buy_from_curve` -- Buy tokens (price increases with supply)
7. `sell_to_curve` -- Sell tokens back (price decreases)
8. `graduate_curve` -- Migrate to AMM when market cap hits threshold

### Reward Vaults
9. `create_reward_vault` -- Create a reward distribution vault
10. `fund_vault` -- Deposit reward tokens into the vault
11. `stake_for_rewards` -- Stake LP tokens to earn rewards
12. `unstake` -- Unstake LP tokens
13. `claim_rewards` -- Claim accumulated rewards
14. `set_reward_rate` -- Update emission rate
15. `compound_rewards` -- Auto-reinvest rewards (when reward = stake token)

### Liquidity Locks
16. `lock_liquidity` -- Lock LP tokens for a duration
17. `unlock_liquidity` -- Unlock after duration expires
18. `extend_lock` -- Extend lock duration (can only increase)

### Admin
19. `set_lbp_authority` / `set_curve_authority` / `set_vault_authority` -- Transfer authority
20. `set_fees` -- Update LBP fee parameters
21. `set_lbp_paused` / `set_curve_paused` / `set_vault_paused` -- Pause/unpause
22. `collect_protocol_fees` -- Withdraw accumulated protocol fees

## Graduation Flow

1. Project creates a bonding curve with a `graduation_threshold`
2. Users buy tokens, reserve balance grows
3. When `reserve_balance >= graduation_threshold`, authority calls `graduate_curve`
4. All reserves migrate to a proper AMM pool (e.g. 5ive-amm)
5. Bonding curve is permanently marked as graduated

## Build

```bash
5ive build gym/src/main.v
```
