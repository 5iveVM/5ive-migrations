# 5ive-tulip: Tulip Protocol Migration

A complete 5ive DSL migration of Tulip Protocol -- Solana's yield aggregator with auto-compounding vaults that farm across DeFi.

## What This Implements

Tulip Protocol is a yield aggregator that abstracts DeFi yield strategies into simple vault deposits. Users deposit tokens, receive shares, and the protocol auto-compounds rewards to grow the share price over time.

### Key Innovation -- Strategy Vaults

Unlike manual farming, Tulip automates the entire yield loop:
- **Lending vaults** (strategy 0): Deposit to highest-rate lending protocol
- **AMM LP vaults** (strategy 1): Provide LP, auto-compound farm rewards
- **Leveraged vaults** (strategy 2): Borrow + farm for amplified yield
- Permissionless `compound()` crank harvests rewards and redeposits
- Share price appreciates as underlying grows -- no user action needed

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Vault** | Core vault: underlying token, shares, strategy, fees, deposit cap | 512 |
| **LendingOptimizer** | Tracks 3 lending platforms with rates + allocations | 256 |
| **LeveragedVault** | Borrow state, leverage ratio, health factor for leveraged strategy | 256 |

### Instructions (18 total)

**Vault Lifecycle:**
1. `create_vault` -- Initialize vault with strategy type, fee config, deposit cap
2. `deposit` -- Deposit underlying tokens, receive proportional vault shares
3. `withdraw` -- Burn shares, receive underlying + accumulated yield
4. `compound` -- Permissionless crank: harvest rewards, redeposit (share price rises)

**Lending Optimizer:**
5. `create_lending_optimizer` -- Attach optimizer to a lending vault
6. `rebalance_lending` -- Move funds to whichever lender has the highest rate

**Leveraged Vault:**
7. `create_leveraged_vault` -- Attach borrow config to a leveraged vault (1-5x)
8. `deleverage` -- Repay borrowed funds to reduce leverage and improve health

**Configuration:**
9. `set_strategy` -- Change strategy type (only when vault is empty)
10. `set_performance_fee` -- Update performance fee (max 2000 bps / 20%)
11. `set_management_fee` -- Update management fee (max 500 bps / 5%)
12. `collect_fees` -- Authority withdraws accrued management fees
13. `emergency_withdraw` -- Bypass strategy, return underlying (works when paused)
14. `set_authority` -- Transfer vault ownership
15. `pause` -- Halt deposits, withdrawals, compounding
16. `unpause` -- Resume normal vault operations
17. `set_max_deposit` -- Update vault deposit cap
18. `update_vault_metrics` -- Refresh accounting after external state changes

## Fee Model

- **Performance fee**: Taken from yield at compound time (0-2000 bps)
- **Management fee**: Annualized fee on TVL, collected by authority (0-500 bps)
- All fees in basis points (1 bps = 0.01%)

## Original Protocol

- **Chain**: Solana
- **Category**: Yield Aggregator / Vault
- **Reference**: [tulip.garden](https://tulip.garden/)
