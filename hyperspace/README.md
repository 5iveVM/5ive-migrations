# 5ive-hyperspace: Hyperspace Arbitrage & MEV Protection Migration

A complete 5ive DSL migration of Hyperspace -- a cross-DEX arbitrage and MEV protection protocol for Solana.

## What This Implements

Hyperspace detects price discrepancies across AMM pools and executes atomic arbitrage trades, while also providing MEV protection for regular users through a private mempool and batch execution system.

### Key Innovations

**Cross-DEX Arbitrage:**
- 2-pool direct arb: buy cheap on pool A, sell expensive on pool B, profit atomically
- 3-hop triangular arb: A->B->C->A cycle extracts profit from multi-pair imbalances
- Flash loan arb: borrow from one pool, arb across another, repay + fee, keep the spread

**MEV Protection:**
- Users submit swaps to a protected queue (private mempool)
- Keepers batch-execute protected swaps atomically, eliminating sandwich attacks
- MEV rebates: if MEV value is captured during execution, users receive a rebate

**Staking for Priority:**
- Stake tokens for first-access to arb opportunities
- Proportional reward distribution from captured arb profits

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **ProtocolConfig** | Top-level config: admin, fees, profit split, DEX whitelist (8 slots), pause state, global stats | 1024 |
| **PoolSnapshot** | Cached AMM pool state: reserves, prices, DEX type, fee params, staleness tracking | 512 |
| **ArbOpportunity** | Detected arb route: buy/sell pools, expected profit, route type, execution status | 384 |
| **FlashLoanState** | Flash loan lifecycle: borrower, amount, fee, repayment status | 256 |
| **StakerRecord** | Per-staker state: staked amount, priority score, reward debt, accumulated rewards | 256 |
| **ProtectedSwap** | MEV-protected swap: user intent, slippage bounds, rebate tracking, batch ID | 384 |

### Instructions (26 total)

**Arbitrage Execution:**
1. `initialize` -- Set up protocol config (admin, fee collector, max flash loan, allowed DEXs)
2. `register_pool` -- Register an AMM pool as an arbitrage source (address, DEX type, reserves, fees)
3. `update_pool_state` -- Refresh cached pool reserves for price comparison
4. `execute_arb` -- Atomic 2-pool arbitrage (buy cheap, sell expensive, profit check, distribute)
5. `execute_triangular_arb` -- 3-hop triangular arbitrage (A->B->C->A with full profit validation)
6. `execute_flash_arb` -- Flash loan arbitrage: borrow, swap, repay + fee, keep profit

**MEV Protection:**
7. `submit_protected_swap` -- User submits a swap with MEV protection (private mempool entry)
8. `execute_protected_batch` -- Keeper executes a batch of protected swaps atomically
9. `set_protection_fee` -- Set the MEV protection service fee (in bps)
10. `claim_mev_rebate` -- User claims MEV rebate if value was captured during execution
11. `set_mev_rebate` -- Admin assigns a rebate amount to a protected swap

**Price Oracle / Monitoring:**
12. `snapshot_prices` -- Record current prices across registered pools
13. `detect_opportunity` -- Check if an arb opportunity exists between two pools (read-only)
14. `get_best_route` -- Find the most profitable arb direction between two pools

**Profit Distribution:**
15. `distribute_profits` -- Split arb profits: protocol fee, executor reward, stakers
16. `stake_for_priority` -- Stake tokens for priority access to arb opportunities
17. `unstake` -- Unstake tokens (partial or full)
18. `claim_staker_rewards` -- Claim accumulated arb profit share (proportional to stake)

**Admin:**
19. `set_max_flash_loan` -- Cap flash loan size
20. `set_profit_split` -- Configure profit distribution ratios (must sum to 100%)
21. `set_authority` -- Transfer admin
22. `pause` / `unpause` -- Emergency controls
23. `add_allowed_dex` -- Whitelist a DEX source (up to 8 slots)
24. `remove_allowed_dex` -- Remove a DEX from whitelist (swap-and-pop)
25. `deactivate_pool` -- Disable a pool from arbitrage
26. `reactivate_pool` -- Re-enable a disabled pool

**Read-Only Getters (19):**
- `get_pool_price_a_to_b`, `get_pool_price_b_to_a`
- `get_pool_reserves_a`, `get_pool_reserves_b`
- `get_total_arbs`, `get_total_profit`, `get_total_staked`
- `get_staker_amount`, `get_staker_priority`, `get_staker_rewards`
- `get_swap_status`, `get_swap_rebate`
- `get_flash_loan_status`
- `get_protection_fee`, `get_max_flash_loan`
- `get_profit_split_protocol`, `get_profit_split_executor`, `get_profit_split_stakers`
- `is_paused`

## Key Design Decisions

### Constant Product Swap Math

All arb calculations use the standard AMM formula with fees:
```
fee = amount_in * fee_numerator / fee_denominator
dx = amount_in - fee
amount_out = (reserve_out * dx) / (reserve_in + dx)
```

Profit is computed as `sell_output - buy_input` and must exceed both the caller's `min_profit` and the protocol's `min_profit_threshold`.

### Fixed DEX Whitelist (No Dynamic Arrays)

5ive DSL does not support dynamic arrays. The protocol uses 8 fixed `pubkey` slots for allowed DEXs, managed with `add_allowed_dex` (append) and `remove_allowed_dex` (swap-and-pop). This mirrors how other 5ive migrations handle fixed-slot collections.

### Staleness Enforcement

All price-sensitive operations (arb execution, batch execution) enforce a 20-slot staleness window on pool snapshots. This prevents executing against stale data that no longer reflects actual pool state.

### Profit Distribution

Arb profits are split three ways (configurable, must sum to 100%):
- **Protocol fee** (default 10%) -- collected by the fee collector
- **Executor reward** (default 60%) -- incentivizes keepers to run arb bots
- **Staker share** (default 30%) -- distributed proportionally to staked amounts

### Staker Reward Model

Uses a debt-based reward tracking model:
```
gross_reward = (staker_amount * total_staker_rewards) / total_staked
claimable = gross_reward - reward_debt
```
This ensures fair distribution regardless of when a staker entered.

### MEV Protection Flow

1. User calls `submit_protected_swap` with swap intent and slippage bounds
2. Swap enters a protected queue (not visible in public mempool)
3. Keeper calls `execute_protected_batch` to execute atomically
4. Protection fee deducted from output; slippage validated
5. If MEV was captured, admin assigns rebate via `set_mev_rebate`
6. User claims rebate via `claim_mev_rebate`

### Flash Loan Lifecycle

1. Executor initiates `execute_flash_arb` with borrow amount and fee
2. Tokens borrowed from source pool (reserves decremented)
3. Borrowed tokens swapped on target pool for intermediate token
4. Intermediate tokens swapped back on source pool
5. Source pool repaid (borrow_amount + flash_fee); remaining is profit
6. Flash loan state marked as repaid atomically within same instruction

### Scaling Constants

| Constant | Value | Usage |
|----------|-------|-------|
| PRICE_SCALE | 1,000,000 (1e6) | All price calculations |
| BPS_SCALE | 10,000 | Fees, profit splits, slippage |

### DEX Type Encoding

| Value | DEX |
|-------|-----|
| 0 | Orca |
| 1 | Raydium |
| 2 | Meteora |
| 3 | Saber |
| 4 | Other |

## Building

```bash
npm run build
```

## Testing

```bash
npm test
```

## Project Structure

```
hyperspace/
  five.toml          -- Project config
  src/
    main.v           -- Complete Hyperspace migration (~750 lines)
  build/             -- Compiled .five artifacts
```

## Source Protocol

- Hyperspace is inspired by Flashbots (Ethereum) and Jito (Solana) MEV protection patterns
- Cross-DEX arbitrage logic mirrors real-world arb bot strategies
- Flash loan mechanics follow the borrow-arb-repay atomic pattern used by DeFi protocols like Aave
- This migration faithfully represents the core mechanics in 5ive DSL
