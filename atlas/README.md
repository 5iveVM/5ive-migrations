# Atlas Protocol DEX -- 5ive DSL Migration

A complete 5ive DSL migration of the Atlas Protocol hybrid DEX, combining weighted AMM pools with an on-chain order book, cross-margin accounts, and auto-compounding yield vaults.

## Architecture

Atlas is designed for professional traders who need deep liquidity and advanced order types in a single unified protocol.

### Four Subsystems

1. **Weighted AMM Pools** -- Balancer-style constant product pools with configurable token weights (e.g., 80/20, 50/50, 60/40). Weights are expressed in basis points out of 10,000.

2. **Order Book** -- Central limit order book supporting three order types:
   - **Limit orders** -- Standard bid/ask at a specified price
   - **Stop orders** -- Trigger at an oracle price threshold (stop-loss / stop-buy)
   - **TWAP orders** -- Large orders split into N chunks executed over time intervals

3. **Cross-Margin** -- Unified margin account with up to 4 deposit slots and 2 position slots. Health factor computed as `collateral * 10000 / liabilities` (basis points). Accounts below the maintenance ratio are liquidatable with a 5% bonus.

4. **Yield Vaults** -- Auto-compounding vaults where idle deposits earn yield. Share price appreciates as `compound_vault` is cranked. Shares follow the standard `shares = amount * total_shares / total_deposited` formula.

## Accounts

| Account | Purpose | Space |
|---------|---------|-------|
| `GlobalConfig` | Protocol-wide settings, order ID counter, pause state | 256 |
| `WeightedPool` | AMM pool state, reserves, weights, fees | 1024 |
| `OrderBookMarket` | Order book market config, vaults, fee tiers | 1024 |
| `Order` | Individual order (limit/stop/TWAP) | 512 |
| `MarginAccount` | Cross-margin deposits and positions | 1024 |
| `YieldVault` | Auto-compounding vault state | 512 |

## Instructions

### AMM Pool (6 instructions)

| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_weighted_pool` | Create a pool with configurable weights (bps, must sum to 10000) |
| 2 | `add_liquidity` | Deposit both tokens proportionally, receive LP tokens |
| 3 | `add_single_sided_liquidity` | Deposit one token with imbalance fee |
| 4 | `remove_liquidity` | Burn LP, receive both tokens proportionally |
| 5 | `remove_single_sided` | Burn LP, withdraw as single token with fee |
| 6 | `pool_swap` | Weighted constant product swap with fee deduction |

### Order Book (7 instructions)

| # | Instruction | Description |
|---|-------------|-------------|
| 7 | `create_orderbook_market` | Initialize market with tick size, min order, fee tiers |
| 8 | `place_limit_order` | Place bid/ask at price, funds locked in escrow |
| 9 | `place_stop_order` | Stop-loss/stop-buy with trigger price |
| 10 | `place_twap_order` | Split order into N chunks over time intervals |
| 11 | `cancel_order` | Cancel single order, refund locked funds |
| 12 | `cancel_all_orders` | Batch cancel up to 4 orders, batch refund |
| 13 | `match_orders` | Permissionless crank: match crossing bid/ask |

### Cross-Margin (5 instructions)

| # | Instruction | Description |
|---|-------------|-------------|
| 14 | `create_margin_account` | Create unified margin account (4 deposit + 2 position slots) |
| 15 | `deposit_margin` | Deposit collateral with oracle-priced valuation |
| 16 | `withdraw_margin` | Withdraw with post-withdrawal health check |
| 17 | `get_margin_health` | View: compute health factor (bps) |
| 18 | `liquidate_margin` | Liquidate unhealthy account (5% bonus to liquidator) |

### Yield Vaults (4 instructions)

| # | Instruction | Description |
|---|-------------|-------------|
| 19 | `create_vault` | Create auto-compounding vault with strategy type |
| 20 | `vault_deposit` | Deposit tokens, receive proportional vault shares |
| 21 | `vault_withdraw` | Burn shares, receive tokens at appreciated share price |
| 22 | `compound_vault` | Permissionless crank: reinvest yield, appreciating share price |

### Admin (10+ instructions)

| # | Instruction | Description |
|---|-------------|-------------|
| -- | `init_global_config` | Initialize protocol config with maintenance ratio |
| 23 | `set_pool_weights` | Rebalance pool weights |
| 24 | `set_pool_fees` / `set_market_fees` | Update fee parameters |
| 25 | `set_*_authority` | Transfer admin for pool/market/vault/global |
| 26 | `pause_*` / `unpause_*` / `global_pause` | Emergency controls |
| -- | `collect_pool_protocol_fees` | Withdraw accumulated protocol fees |

## Key Math

### Weighted Pool Swap
```
amount_out = reserve_out * amount_in * weight_in / ((reserve_in + amount_in) * weight_out)
```
Linearised approximation of the Balancer weighted constant product formula, safe for integer arithmetic.

### Order Matching
- Bids and asks cross when `bid.price >= ask.price`
- Execution price = bid price (maker priority)
- Quote amount = `exec_price * fill_size / 1e6`
- Maker/taker fees deducted from quote side

### Stop Orders
- Stop-buy triggers when `oracle_price >= trigger_price`
- Stop-sell triggers when `oracle_price <= trigger_price`

### TWAP Execution
- Total order split into `num_chunks` pieces
- One chunk executable per `interval` seconds
- Chunk size = `remaining_size / remaining_chunks`

### Margin Health
```
health_bps = total_collateral_value * 10000 / total_liabilities
```
Accounts below `maintenance_ratio_bps` (set in GlobalConfig) are liquidatable.

### Vault Share Price
```
shares_out = amount * total_shares / total_deposited
amount_out = shares * total_deposited / total_shares
```
`compound_vault` increases `total_deposited`, making each share worth more underlying tokens.

## Fee Structure

- **Pool swap fees**: Configurable up to 10% (1000 bps). Split between LP fee and protocol fee.
- **Single-sided liquidity**: Imbalance fee equal to `swap_fee_bps` applied to deposit/withdrawal.
- **Order book maker fee**: Up to 5% (500 bps), deducted from quote on fill.
- **Order book taker fee**: Up to 5% (500 bps), tracked for protocol revenue.
- **Liquidation bonus**: Fixed 5% on seized collateral.

## File Structure

```
atlas/
  README.md          # This file
  src/
    main.v           # Complete 5ive DSL program
```

## DSL Patterns Used

- `use std::interfaces::spl_token;` for SPL Token CPI (transfer, mint_to, burn)
- `account Name { field: type; }` for on-chain account definitions
- `pub fn()` for on-chain instructions, `fn helper()` for internal pure functions
- `@mut @init(payer=x, space=N)` for account initialization
- `@signer` for signature verification
- `account.ctx.key` for pubkey access
- `require(condition)` for assertions
- `get_clock().unix_timestamp` for time reads
- `as u64` / `as u128` for integer casting
- `let mut` for mutable locals
- Integer-only arithmetic throughout
