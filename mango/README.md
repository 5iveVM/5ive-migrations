# 5ive-mango: Mango Markets v4 Migration

A complete 5ive DSL migration of Mango Markets v4 -- a cross-margined derivatives exchange supporting spot margin trading, perpetual futures, flash loans, and liquidation.

## What This Implements

Mango Markets v4 is a decentralized derivatives exchange on Solana where users deposit collateral and trade multiple markets with shared (cross) margin. All deposits and positions contribute to a single health score.

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **MangoGroup** | Top-level exchange instance (admin, insurance, pause) | 512 |
| **TokenBank** | Per-token reserve with indices, interest model, risk weights | 768 |
| **MangoAccount** | User portfolio: 4 token slots + 2 perp slots, cross-margined | 1024 |
| **PerpMarket** | Perpetual futures market (oracle, funding, fees) | 768 |
| **PerpOrder** | Individual order on a perp market | 512 |
| **PriceOracle** | Oracle price feed | 256 |
| **FlashLoanState** | Tracks in-flight flash loans | 256 |

### Instructions (21 total)

**Group & Account Management:**
1. `create_group` -- Create exchange instance
2. `create_account` -- Create user portfolio account
3. `close_account` -- Close account (must have no positions)

**Token Banking (Spot Margin):**
4. `register_token` -- Register token with oracle, interest params, weights
5. `deposit` -- Deposit tokens as collateral
6. `withdraw` -- Withdraw with health check (init weights)
7. `flash_loan_begin` -- Borrow tokens for 1 tx
8. `flash_loan_end` -- Repay flash loan + fee

**Perpetual Markets:**
9. `create_perp_market` -- Create perpetual futures market
10. `place_perp_order` -- Place long/short order
11. `cancel_perp_order` -- Cancel open order
12. `consume_perp_events` -- Match orders, settle trades
13. `settle_perp_pnl` -- Settle realized PnL between two accounts
14. `update_funding` -- Update funding rate (mark vs oracle)

**Health & Liquidation:**
15. `compute_health` -- Calculate cross-margin health score
16. `liquidate_token` -- Liquidate unhealthy token position
17. `liquidate_perp` -- Liquidate perp position at oracle + bonus

**Admin & Oracle:**
18. `set_oracle` / `set_bank_oracle` / `set_perp_oracle` -- Update prices
19. `update_interest` -- Accrue compound interest on deposits/borrows
20. `set_fees` -- Update maker/taker fees
21. `pause` / `unpause` -- Emergency controls

**Additional Admin:**
- `set_delegate` -- Delegate trading authority
- `transfer_admin` -- Transfer group ownership
- `update_token_weights` -- Adjust risk weights
- `update_interest_params` -- Adjust interest rate curve
- `update_funding_params` -- Adjust funding rate bounds
- `set_perp_market_active` -- Toggle market

**Read-Only Getters:**
- `get_health`, `get_token_deposit`, `get_perp_base_position`, `get_perp_quote_position`
- `get_deposit_index`, `get_borrow_index`, `get_oracle_price`
- `get_perp_open_interest`, `get_perp_funding`, `get_perp_fees`
- `get_fees_accrued`, `get_utilization`

## Key Design Decisions

### Fixed Slots (No Dynamic Arrays)
5ive DSL does not support dynamic arrays. Each MangoAccount has:
- **4 token slots** (`token_deposit_1..4`, `token_bank_1..4`) -- positive = deposit, negative = borrow
- **2 perp slots** (`perp_base_position_1..2`, `perp_market_1..2`)

Slots are assigned on first use and identified by matching the bank/market pubkey.

### Scaling Constants
- **Index scale**: 1,000,000 (1e6) -- deposit and borrow indices start here
- **Weight scale**: 10,000 = 100% -- `init_asset_weight` of 8000 = 80%
- **BPS scale**: 10,000 = 100% -- fees in basis points
- **Funding rate**: i64 scaled by 1e6

### Interest Rate Model
Two-slope kink model (like Aave/Compound):
- Below optimal utilization: linear interpolation from `rate_0` to `rate_1`
- Above optimal utilization: steep linear from `rate_1` to `max_rate`
- Deposit rate derived from borrow rate and utilization

### Cross-Margin Health Calculation
```
health = sum(token_value_i * weight_i) + sum(perp_value_j)
```
Where:
- Token value = `raw_deposit * index / 1e6 * oracle_price`
- Weight = `init_asset_weight` for new borrows (stricter), `maint_asset_weight` for liquidation
- Perp value = `base_position * oracle_price + quote_position`

Account is healthy when `health >= 0`.

### Funding Rate
```
rate = clamp((mark_price - oracle_price) / oracle_price * 1e6, min_rate, max_rate)
```
Scaled by hours elapsed. Longs pay shorts when mark > oracle (positive funding).

### Liquidation
- **Token liquidation**: Liquidator repays liability, receives asset + 5% bonus
- **Perp liquidation**: Position transferred at oracle price +/- 2.5% bonus

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
mango/
  five.toml          -- Project config
  src/
    main.v           -- Complete Mango v4 migration
  build/             -- Compiled .five artifacts
```

## Source Protocol

- [Mango Markets v4](https://github.com/blockworks-foundation/mango-v4) -- Rust/Anchor
- This migration faithfully represents the core mechanics in 5ive DSL
