# Anchor Protocol Lending -- 5ive DSL Migration

A faithful 5ive DSL migration of [Anchor Protocol](https://anchorprotocol.com), the fixed-rate yield lending protocol originally from Terra, adapted to Solana.

## What is Anchor Protocol?

Anchor Protocol was a lending protocol best known for its stable ~20% APY on deposits. Instead of floating market-driven rates, Anchor targeted a fixed deposit yield and used a yield reserve plus staked-collateral rewards (bAssets) to subsidize the difference when borrow interest fell short.

## How this differs from 5ive-lending

The existing `5ive-lending` is an Aave/Solend-style variable-rate lending protocol. This Anchor migration implements a fundamentally different economic model:

| Feature | 5ive-lending | Anchor migration |
|---|---|---|
| Deposit rate | Floating (market-driven) | Fixed target (subsidized) |
| Yield reserve | None | Buffer fund subsidizes deposit rates |
| Collateral types | Generic tokens | bAsset-aware (captures staking yield) |
| Liquidation model | Instant with bonus | Queue-based with discount tiers (1-30%) |
| Rate adjustment | Utilization curve | Dynamic rebalancing to maintain target |
| aToken model | cToken (exchange rate) | aToken with deposit index growth |
| Interest indices | WAD (10^18) | u128 hi/lo pairs (10^18 scale) |
| Borrow rate | Two-slope kink | Derived from target rate / utilization |
| Multi-collateral | Single reserve | 2 collateral slots per position |
| Reserve funding | Protocol fees | Admin-funded yield reserve |

## Account Structure

### AnchorMarket
Top-level market account. Stores authority, borrow/aToken mints, vaults, target and current rates, deposit/borrow indices (hi/lo u64 pairs for 10^18 precision), yield reserve balance, and pause state.

### CollateralConfig
One per accepted collateral type. Contains mint, vault, oracle reference, LTV ratio, liquidation threshold/bonus (all in bps), bAsset flag with reward rate, deposit totals, and active status. Up to 10 collateral types per market.

### UserPosition
Per-user position with deposit shares (aToken), borrow shares, and 2 collateral slots (config pubkey + amount each). Tracks last-seen deposit and borrow indices for accrual.

### LiquidationBid
Liquidator's bid in the queue. Specifies discount tier (1-30%), bid amount, filled amount, and collateral received (pending claim). Funds locked on submission, refundable on cancel.

### OraclePrice
Price feed per collateral config. Stores price, decimals, and last update slot. Staleness enforced at 100 slots on all price-sensitive operations.

## Instructions (27 total)

### Market Setup
1. **initialize_market** -- Create market with target deposit rate, borrow/aToken mints, yield reserve vault
2. **register_collateral** -- Register collateral type with LTV, liquidation params, bAsset config
3. **register_borrow_token** -- Validate/update borrow token configuration
4. **fund_yield_reserve** -- Admin deposits tokens into yield reserve

### Deposits (Earn Side)
5. **deposit_stable** -- Deposit stablecoins, receive aTokens at deposit index exchange rate
6. **withdraw_stable** -- Burn aTokens, receive stablecoins at current exchange rate (includes yield)
7. **accrue_yield** -- Core yield engine: accrues borrow interest, distributes to depositors, subsidizes from yield reserve if needed

### Borrowing
8. **deposit_collateral** -- Deposit collateral to slot 1 or 2
9. **withdraw_collateral** -- Remove collateral with health check
10. **borrow** -- Borrow stablecoins against collateral (LTV check)
11. **repay** -- Repay borrowed stablecoins (clamped to outstanding)

### bAsset Yield Capture
12. **claim_basset_rewards** -- Capture staking rewards: 80% to yield reserve
13. **distribute_basset_rewards** -- Allocate rewards: 80% reserve, 20% borrower rate discount

### Liquidation Queue
14. **submit_liquidation_bid** -- Place a bid at discount tier (1-30%), funds locked
15. **cancel_liquidation_bid** -- Cancel bid, receive unfilled refund
16. **execute_liquidation** -- Execute against unhealthy position using lowest-discount bids
17. **claim_liquidation_collateral** -- Winning bidder claims seized collateral

### Rate Management
18. **update_target_rate** -- Governance adjusts target deposit APY (max 50%)
19. **rebalance_rates** -- Recalculate borrow rate from target rate, utilization, and reserve health
20. **withdraw_yield_reserve_surplus** -- Withdraw excess reserve beyond 1-year safety buffer

### Admin
21. **set_authority** -- Transfer market admin
22. **pause** -- Emergency pause
23. **unpause** -- Resume operations
24. **set_collateral_params** -- Update LTV, liquidation, bAsset params for a collateral type

### Oracle
25. **init_oracle** -- Create price feed for a collateral config
26. **update_oracle** -- Update price feed

### Position
27. **init_position** -- Create user position account

### Read-only Views
- **get_deposit_value** -- User's deposit value (shares x deposit index)
- **get_borrow_value** -- User's borrow value (shares x borrow index)
- **get_utilization** -- Market utilization in bps
- **get_yield_reserve** -- Current yield reserve balance
- **get_atoken_exchange_rate** -- Current deposit index (aToken exchange rate)
- **get_effective_deposit_rate** -- Current effective deposit rate (bps)
- **get_effective_borrow_rate** -- Current effective borrow rate (bps)
- **get_health_factor** -- Position health (>10000 = healthy, <10000 = liquidatable)

## Key Math

### Fixed Rate Yield Distribution (accrue_yield)
```
interest_earned = total_borrows * borrow_rate_bps * slots_elapsed / (SLOTS_PER_YEAR * BPS)
yield_needed    = total_deposits * target_rate_bps * slots_elapsed / (SLOTS_PER_YEAR * BPS)

if interest_earned >= yield_needed:
    depositors get yield_needed
    surplus -> yield_reserve
else:
    deficit = yield_needed - interest_earned
    if yield_reserve >= deficit:
        depositors get yield_needed (fully subsidized)
        yield_reserve -= deficit
    else:
        depositors get interest_earned + remaining_reserve
        effective rate reduced proportionally
```

### Rate Rebalancing
```
utilization = total_borrows / total_deposits  (in bps)
borrow_rate = target_deposit_rate / utilization

if yield_reserve > 1 year of target yield:
    borrow_rate *= 0.9  (10% discount for healthy reserve)

clamped to [100, 10000] bps  (1% to 100%)
```

### aToken Exchange Rate
```
deposit:  shares = amount * INDEX_INIT / deposit_index
withdraw: amount = shares * deposit_index / INDEX_INIT
```
Rate grows as `deposit_index` increases through `accrue_yield`, making aTokens worth more over time.

### Liquidation Queue
```
Bidders place bids at discount tiers (1-30%)
Execute fills lowest discount first (best for borrower)
collateral_value = repay_amount * (10000 + discount_tier * 100) / 10000
collateral_tokens = collateral_value * 10^decimals / oracle_price
```

### bAsset Rewards
```
reward = total_basset_deposited * basset_reward_rate * slots / (SLOTS_PER_YEAR * BPS)
80% -> yield reserve (subsidizes deposit rate)
20% -> borrower rate discount (reduces outstanding borrows)
```

### Index Precision
Interest indices use 10^18 scale stored as hi/lo u64 pairs. At genesis both deposit and borrow indices start at 10^18 (1.0). Intermediate calculations use 10^9 decomposition to avoid u64 overflow while preserving precision.

## Source

`src/main.v` -- Complete 5ive DSL migration (~700 lines)
