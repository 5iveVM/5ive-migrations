# 5ive-zeta: Zeta Markets Migration

A complete 5ive DSL migration of Zeta Markets -- on-chain options and perpetual futures with European-style options settlement.

## What This Implements

Zeta Markets is a derivatives protocol offering European options (exercise at expiry only) and perpetual futures. It features cross-margin accounts, on-chain order matching via cranking, simplified Greeks computation, and oracle-based settlement.

### Key Innovation -- Options + Perps Unified Margin

Unlike separate options and perps platforms, Zeta uses a single margin account:
- Margin balance backs both options and perp positions
- Options writers lock collateral at strike price
- Perp positions use virtual AMM reserves for mark price
- Liquidation considers total portfolio margin requirement

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Exchange** | Top-level config: authority, oracle program, pause state | 512 |
| **MarketGroup** | Options series: underlying, quote, expiry, strike count | 512 |
| **OptionsMarket** | Individual option: strike, call/put, open interest, volume | 512 |
| **PerpMarket** | Perpetual futures: virtual reserves, funding rate | 512 |
| **MarginAccount** | Cross-margin: balance, 3 deposit slots, 2 options slots, 1 perp slot | 1024 |
| **Order** | Individual order: market, side, price, size, fill state | 512 |

### Instructions (22 total)

**Exchange Setup:**
1. `initialize_exchange` -- Create exchange with oracle program
2. `initialize_market_group` -- Create options series (underlying, expiry)
3. `create_options_market` -- Create option (strike + call/put)
4. `create_perp_market` -- Create perpetual futures market with virtual AMM

**Margin:**
5. `create_margin_account` -- Create cross-margin account
6. `deposit_margin` -- Deposit USDC collateral
7. `withdraw_margin` -- Withdraw with margin health check

**Trading:**
8. `place_order` -- Place buy/sell order on options or perps
9. `cancel_order` -- Cancel an open order
10. `crank_market` -- Match crossing orders (keeper-operated)

**Options Settlement:**
11. `settle_expired_options` -- Mark expired group; prep for exercise
12. `exercise_option` -- Holder exercises ITM option at expiry
13. `mint_option` -- Write option: lock collateral, create short position
14. `burn_option` -- Close written option: return locked collateral

**Oracle:**
15. `update_oracle` -- Update price feed (authorized oracle)

**Greeks:**
16. `compute_greeks` -- Calculate simplified delta for an options market

**Funding (Perps):**
17. `update_funding` -- Calculate and apply funding rate (hourly, clamped)

**Liquidation:**
18. `liquidate` -- Liquidate undercollateralized margin account

**Admin:**
19. `set_fees` -- Update trading fees
20. `collect_fees` -- Collect accumulated trading fees
21. `set_authority` -- Transfer exchange authority
22. `pause_exchange` / `unpause_exchange` -- Emergency controls

## Key Design Decisions

### Options Math (Integer-Only)

**Call payout:** `max(0, oracle_price - strike_price) * size`
**Put payout:** `max(0, strike_price - oracle_price) * size`

All prices scaled by PRICE_SCALE (1,000,000). Options are European-style: exercise only at expiry. ITM options auto-exercise; OTM expire worthless.

### Options Writing

Writing (selling) an option:
1. Lock `strike_price * size` as collateral from margin balance
2. Receive premium immediately
3. Position recorded as short (is_long = false)
4. At expiry: if ITM, collateral pays out to holder; if OTM, collateral returned

### Greeks (Simplified Integer Approximation)

Delta computed as integer scaled by 1000:
- ATM options: delta ~ 500 (0.5)
- Deep ITM calls: delta ~ 1000 (1.0)
- Deep OTM calls: delta ~ 0
- Moneyness-based: `delta = 500 +/- (moneyness * 500) / price`

Full Black-Scholes is not feasible with integer-only math. This approximation provides directional exposure information sufficient for margin calculations.

### Perpetual Funding Rate

```
mark_price = quote_reserve * PRICE_SCALE / base_reserve
funding_rate = (mark_price - oracle_price) * FUNDING_SCALE / oracle_price
```
- Calculated hourly (minimum 3600 seconds between updates)
- Clamped to max 0.1% per hour
- Positive = longs pay shorts (mark above oracle)
- Negative = shorts pay longs (mark below oracle)

### Cross-Margin Architecture

Fixed-slot design (no dynamic arrays in 5ive DSL):
- **3 deposit slots** for collateral tokens
- **2 options position slots** (market + size + direction + entry price)
- **1 perp position slot** (market + size + entry price + last funding)
- Empty slots use owner pubkey as sentinel

### Margin Requirements

| Margin Type | Requirement |
|-------------|-------------|
| Initial (orders) | 10% of notional |
| Maintenance (liquidation) | 5% of notional |
| Options writing | 100% of strike * size |

### Liquidation

Triggered when `balance < maintenance_margin`:
1. Liquidator receives positions at oracle price
2. 5% of remaining balance kept as liquidation bonus
3. Options positions are closed (collateral released)
4. Perp position transferred to liquidator at current oracle price

### Scaling Constants

| Constant | Value | Usage |
|----------|-------|-------|
| PRICE_SCALE | 1,000,000 (1e6) | All prices |
| FUNDING_SCALE | 1,000,000,000 (1e9) | Funding rates |
| Max Funding | 0.1% per hour | Funding rate cap |

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
zeta/
  src/
    main.v           -- Complete Zeta Markets migration
```

## Source Protocol

- [Zeta Markets](https://github.com/zetamarkets/sdk) -- Rust/Anchor
- This migration faithfully represents European options, perpetual futures, cross-margin, and oracle-based settlement
