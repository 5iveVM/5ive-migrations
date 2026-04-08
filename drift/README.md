# 5ive-drift: Drift Protocol v2 Migration

A complete 5ive DSL migration of Drift Protocol v2 -- Solana's largest perpetual futures DEX, powered by a virtual AMM (vAMM) model.

## What This Implements

Drift Protocol v2 is a decentralized perpetual futures exchange where traders trade against a virtual AMM rather than against each other. The protocol acts as counterparty to all trades, with PnL settled from an insurance fund or socialized across users.

### Key Innovation -- vAMM

Unlike orderbook-based DEXes (Mango, Serum), Drift uses virtual reserves:
- Virtual base and quote reserves follow the constant product invariant (`base * quote = k`)
- Trades move the virtual price without requiring real token liquidity in the pool
- Mark price = `(quote_reserve * peg_multiplier) / (base_reserve * PRICE_PRECISION)`
- `sqrt_k` controls vAMM depth (higher = less slippage)
- `peg_multiplier` anchors mark price to the oracle via repegging
- Spread widens dynamically when oracle confidence is low

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **DriftState** | Top-level exchange config (admin, pause, fee defaults, market counts) | 512 |
| **SpotMarket** | Per-token collateral reserve with deposit/borrow indices, interest model, risk weights | 768 |
| **PerpMarket** | Perpetual futures market with vAMM state, funding, fees, open interest | 768 |
| **User** | Portfolio: 4 spot slots + 2 perp slots, cross-margined | 1024 |
| **PerpOrder** | Individual order (market/limit/trigger, long/short) | 512 |
| **InsuranceFund** | Per-market insurance fund backed by USDC stakers | 256 |
| **PriceOracle** | Oracle price feed with confidence band and staleness | 256 |

### Instructions (34 total)

**State Management:**
1. `initialize` -- Create Drift exchange state
2. `initialize_user` -- Create user portfolio account

**Spot Markets (Collateral):**
3. `initialize_spot_market` -- Register token with oracle, interest params, risk weights
4. `deposit` -- Deposit collateral (slot auto-assignment)
5. `withdraw` -- Withdraw with oracle validation and margin awareness

**Perpetual Markets (vAMM):**
6. `initialize_perp_market` -- Create perp market with vAMM parameters
7. `place_perp_order` -- Place market/limit/trigger order (long/short)
8. `cancel_order` -- Cancel an open order
9. `fill_perp_order` -- Keeper fills order against vAMM (spread-adjusted execution)
10. `settle_pnl` -- Settle realized PnL to user's USDC balance

**vAMM Operations:**
11. `update_amm` -- Recalculate spread from oracle confidence
12. `update_k` -- Adjust vAMM depth (proportional reserve scaling)
13. `repeg` -- Realign peg multiplier to oracle price

**Funding:**
14. `update_funding_rate` -- Calculate and apply funding (mark vs oracle, hourly, clamped)
15. `settle_funding` -- Settle accumulated funding for a user position

**Insurance Fund:**
16. `initialize_insurance_fund` -- Create per-market insurance fund
17. `add_insurance` -- Stake USDC, receive proportional shares
18. `remove_insurance` -- Unstake, burn shares, receive USDC
19. `resolve_bankruptcy` -- Cover losses from insurance; socialize if depleted

**Liquidation:**
20. `liquidate_perp` -- Liquidate unhealthy perp position (transfer to liquidator at discount)
21. `liquidate_spot` -- Liquidate unhealthy spot borrow (seize collateral + 5% bonus)

**Interest Accrual:**
22. `update_spot_market_interest` -- Accrue interest on deposit/borrow indices (kink model)

**Oracle:**
23. `initialize_oracle` -- Create oracle with price and confidence
24. `set_oracle_price` -- Update oracle price and confidence

**Health:**
25. `compute_health` -- Cross-margin health score (spot collateral - perp margin + unrealized PnL)

**Admin:**
26. `update_perp_market_params` -- Update spread, fees, oracle
27. `update_spot_market_params` -- Update interest curve, risk weights
28. `set_fees` -- Update default maker/taker fees
29. `set_liquidation_margin_buffer` -- Adjust liquidation threshold
30. `set_lp_cooldown` -- Adjust LP cooldown period
31. `set_delegate` -- Delegate trading authority
32. `transfer_admin` -- Transfer exchange ownership
33. `pause` / `unpause` -- Emergency controls
34. `set_perp_market_active` -- Toggle individual market

**Read-Only Getters (20):**
- `get_mark_price`, `get_open_interest`, `get_funding_rate`
- `get_cumulative_funding_long`, `get_cumulative_funding_short`
- `get_perp_fees`, `get_insurance_claims`
- `get_spot_deposit_balance`, `get_spot_borrow_balance`
- `get_spot_deposit_index`, `get_spot_borrow_index`, `get_spot_utilization`
- `get_user_spot_position`, `get_user_perp_base`, `get_user_perp_quote`, `get_user_perp_entry_price`
- `get_insurance_fund_staked`, `get_insurance_fund_shares`
- `get_oracle_price`, `get_exchange_status`, `get_total_fees`
- `get_vamm_reserves`, `get_vamm_quote_reserves`, `get_vamm_sqrt_k`, `get_peg_multiplier`
- `is_user_bankrupt`

## Key Design Decisions

### vAMM Constant Product

The virtual AMM uses the standard `x * y = k` invariant on virtual reserves. When a trader opens a long:
1. Base reserve decreases (trader "receives" virtual base)
2. Quote reserve increases to maintain k
3. Mark price rises (less base per quote)

The swap output is: `quote_delta = (base * quote) / (base - swap_amount) - quote`

Spread is applied on top: buyers pay `mark + spread/2`, sellers receive `mark - spread/2`.

### Dynamic Spread

Spread widens when oracle confidence is low:
```
effective_spread = max(base_spread, oracle_confidence_bps * 2)
```
This protects the vAMM during volatile or uncertain price conditions.

### Fixed Slots (No Dynamic Arrays)

5ive DSL does not support dynamic arrays. Each User has:
- **4 spot slots** (`spot_position_1..4`, `spot_market_index_1..4`) -- positive = deposit, negative = borrow
- **2 perp slots** (`perp_base_1..2`, `perp_market_1..2`)

Slots use index 255 as the "empty" sentinel. First deposit/trade auto-assigns the slot.

### Scaling Constants

| Constant | Value | Usage |
|----------|-------|-------|
| PRICE_PRECISION | 1,000,000 (1e6) | All prices |
| FUNDING_PRECISION | 1,000,000,000 (1e9) | Funding rates |
| INDEX_PRECISION | 1,000,000,000 (1e9) | Interest indices |
| WEIGHT_SCALE | 10,000 | Risk weights (10000 = 100%) |
| BPS_SCALE | 10,000 | Fees in basis points |

### Funding Rate

```
rate = clamp((mark_price - oracle_price) / oracle_price * FUNDING_PRECISION, -max, +max)
```
- Calculated hourly (minimum 1-hour interval enforced)
- Max rate: 0.1% per hour (FUNDING_PRECISION / 1000)
- Longs pay when funding > 0 (mark above oracle)
- Shorts pay when funding < 0 (mark below oracle)
- Cumulative rates tracked separately for longs and shorts

### Interest Rate Model

Two-slope kink model for spot markets:
- Below optimal utilization: linear from 0 to `optimal_rate`
- Above optimal utilization: steep linear from `optimal_rate` to `max_rate`
- Deposit rate = borrow_rate * utilization
- Interest accrues to deposit_index and borrow_index (scaled 1e9)

### Insurance and Socialization

1. Insurance fund stakers deposit USDC and receive proportional shares
2. When a user goes bankrupt, insurance fund covers the loss
3. If insurance is depleted, losses are socialized by reducing vAMM `sqrt_k`
4. Reduced k means less virtual liquidity and more slippage for all traders

### Liquidation

**Perp liquidation:**
- Triggered when user's total value (collateral + unrealized PnL) falls below margin requirement
- Liquidator receives the position at oracle price +/- 5% discount
- Bankrupt users (negative collateral after settlement) are flagged

**Spot liquidation:**
- Triggered when weighted borrow value exceeds weighted collateral value
- Liquidator repays borrow, seizes collateral + 5% bonus
- Uses maintenance weights for threshold check

### Oracle Staleness

All price-sensitive operations enforce a 120-second staleness window. Oracle confidence band is used to dynamically widen spreads during uncertain conditions.

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
drift/
  five.toml          -- Project config
  src/
    main.v           -- Complete Drift v2 migration (~1100 lines)
  build/             -- Compiled .five artifacts
```

## Source Protocol

- [Drift Protocol v2](https://github.com/drift-labs/protocol-v2) -- Rust/Anchor
- This migration faithfully represents the core mechanics in 5ive DSL
- The vAMM model, funding rate, insurance fund, and liquidation logic mirror the original design
