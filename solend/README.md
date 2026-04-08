# Solend -- 5ive DSL Migration

A faithful 5ive DSL migration of [Solend](https://solend.fi), Solana's largest lending/borrowing protocol.

## What is Solend?

Solend is a decentralized lending and borrowing protocol on Solana. Users deposit tokens to earn interest, borrow against their collateral, and participate in liquidations. It introduced flash loans to Solana DeFi and uses a two-slope interest rate model for capital efficiency.

## How this differs from 5ive-lending

The existing `5ive-lending` is a simplified lending protocol. This Solend migration adds the full protocol surface:

| Feature | 5ive-lending | Solend migration |
|---|---|---|
| Interest precision | u64 (RATE_SCALE=10^9) | WAD-scaled u128 (10^18 via hi/lo split) |
| Interest rate model | Single-slope (min to max) | Two-slope kink (min -> optimal -> max) |
| cToken exchange rate | 1:1 (no growth) | Grows as interest accrues |
| Obligation structure | Single deposit + borrow value | 3 deposit slots + 3 borrow slots (multi-asset) |
| Flash loans | Not supported | Full begin/end with fee in bps |
| Borrow fee | None | Configurable bps fee on new borrows |
| Protocol liquidation fee | None | Portion of liquidation bonus to protocol |
| Deposit/borrow limits | Supply cap only | Both deposit_limit and borrow_limit per reserve |
| Liquidation close factor | No limit | 50% max close factor |
| Oracle | Basic | Staleness-enforced (100-slot window) |
| Pause/unpause | Single toggle | Separate pause/unpause with guards |

## Account Structure

### LendingMarket
Top-level market account. Stores owner authority, oracle program reference, pause state, and reserve count.

### Reserve
One per supported token. Contains:
- **Vault references**: liquidity supply vault, collateral mint, fee receiver, oracle
- **State**: available liquidity, WAD-scaled borrowed amount, cumulative borrow rate, price, cToken supply, accumulated fees
- **Config**: two-slope rate model params (min/optimal/max rates, optimal utilization), LTV, liquidation threshold + bonus, flash loan fee bps, borrow fee bps, deposit/borrow limits, host fee %, protocol liquidation fee %

### Obligation
Per-user position account with 3 deposit slots and 3 borrow slots, supporting multi-asset collateral and multi-asset borrowing.

### FlashLoanReceipt
Ephemeral receipt created at `flash_loan_begin`, verified and marked repaid at `flash_loan_end`.

### PriceOracle
Simple oracle with price, decimals, authority, and last update slot. Staleness enforced at 100 slots.

## Instructions (18 total)

### Market Management
1. `init_lending_market` -- Create market with owner and oracle program
2. `set_lending_market_owner` -- Transfer ownership
3. `pause_lending_market` / `unpause_lending_market` -- Emergency controls

### Reserve Management
4. `init_reserve` -- Create reserve with full config (rates, fees, caps, thresholds)
5. `refresh_reserve` -- Accrue compound interest, update oracle price, update cumulative rate
6. `set_reserve_config` -- Update all reserve parameters

### Deposit / Withdraw
7. `deposit_reserve_liquidity` -- Deposit tokens, receive cTokens at exchange rate
8. `redeem_reserve_collateral` -- Burn cTokens, receive underlying at exchange rate

### Obligations
9. `init_obligation` -- Create user obligation with zeroed slots
10. `refresh_obligation` -- Recalculate health from reserve prices (per-reserve)
11. `deposit_obligation_collateral` -- Add cTokens as collateral (auto-assigns to slots)
12. `withdraw_obligation_collateral` -- Remove collateral (health check enforced)
13. `borrow_obligation_liquidity` -- Borrow with LTV check, borrow fee deducted
14. `repay_obligation_liquidity` -- Repay borrows (clamped to outstanding)

### Liquidation
15. `liquidate_obligation` -- Liquidate unhealthy position; 50% close factor, bonus split between liquidator and protocol

### Flash Loans
16. `flash_loan_begin` -- Borrow without collateral, creates receipt
17. `flash_loan_end` -- Verify principal + fee repayment, or revert

### Admin
18. `withdraw_protocol_fees` -- Collect accumulated protocol fees from reserve

### Oracle
- `init_oracle` / `update_oracle` -- Price feed management

### Read-only Views
- `get_reserve_utilization` -- Current utilization rate
- `get_reserve_borrow_rate` -- Current annualized borrow rate
- `get_exchange_rate` -- cToken exchange rate (scaled by 10^9)
- `get_obligation_health` -- Health factor (>100 = healthy, <100 = liquidatable)
- `get_total_liquidity` -- Total reserve liquidity (available + borrowed)

## Key Math

### WAD Precision
Interest calculations use 10^18 (WAD) fixed-point math. Since 5ive DSL only supports u64, WAD values are stored as hi/lo u64 pairs and computed with scaled arithmetic (10^9 intermediates) to avoid overflow while preserving precision.

### Two-Slope Interest Rate Model
```
if utilization <= optimal_utilization:
    rate = min_rate + utilization * (optimal_rate - min_rate) / optimal_util
else:
    rate = optimal_rate + (util - optimal) * (max_rate - optimal_rate) / (100 - optimal)
```

### cToken Exchange Rate
```
exchange_rate = total_liquidity / collateral_supply
deposit:  cTokens = amount * collateral_supply / total_liquidity
redeem:   liquidity = cTokens * total_liquidity / collateral_supply
```

The exchange rate increases over time as interest accrues, making cTokens worth more underlying tokens.

### Compound Interest
```
interest = borrowed_wad * borrow_rate * slots_elapsed / (SLOTS_PER_YEAR * 100)
new_borrowed_wad = borrowed_wad + interest
new_cumulative_rate = old_rate + old_rate * borrow_rate * slots / (SLOTS_PER_YEAR * 100)
```

### Flash Loan Fee
```
fee = amount * flash_loan_fee_bps / 10000  (minimum 1 token)
```

## Source

`src/main.v` -- Complete 5ive DSL migration (~900 lines)
