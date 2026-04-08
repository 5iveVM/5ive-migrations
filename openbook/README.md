# 5ive-openbook: OpenBook (Serum v2) Migration

A complete 5ive DSL migration of OpenBook -- Solana's OG central limit order book (CLOB) with self-custodial settlement.

## What This Implements

OpenBook (originally Serum) is the foundational on-chain order book that underpins much of Solana DeFi. Every trade matches on-chain with full self-custody -- users maintain OpenOrders accounts that track their free and locked balances, and a permissionless crank mechanism processes fills asynchronously.

### Key Mechanics

- **Central limit order book**: Bids and asks matched on-chain at price-time priority
- **Self-custodial**: Users' funds stay in their OpenOrders accounts until explicitly settled
- **Crank model**: Permissionless `match_orders` + `consume_events` calls process fills
- **Order types**: Limit, immediate-or-cancel (IOC), post-only
- **Fee model**: Separate maker/taker fees in basis points

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Market** | Market config: mints, vaults, bids/asks, event queue, fees, authority | 1024 |
| **OpenOrders** | Per-user balance tracking: base/quote free/locked, order count | 512 |
| **Order** | Individual order: side, price, size, fill state, type, timestamps | 512 |
| **EventNode** | Fill/cancel event for crank consumption | 256 |

### Instructions (18 total)

**Market Lifecycle:**
1. `create_market` -- Initialize a new order book market
2. `set_market_authority` -- Transfer market admin
3. `set_fee_rates` -- Update maker/taker fee rates
4. `disable_market` -- Kill switch to halt new orders
5. `close_market` -- Finalize market closure (all orders must be settled)

**Open Orders:**
6. `init_open_orders` -- Create user's balance tracking account
7. `close_open_orders` -- Close account when all balances are zero

**Order Placement:**
8. `place_order` -- Place limit/IOC/post-only order (unified entry)
9. `new_order_v3` -- Serum v3-compatible order placement with self-trade behavior

**Order Cancellation:**
10. `cancel_order` -- Cancel by order ID
11. `cancel_order_by_client_id` -- Cancel by client-assigned ID
12. `cancel_all` -- Batch cancel entry point

**Crank (Matching):**
13. `match_orders` -- Permissionless matching of maker against taker
14. `consume_events` -- Process fill events

**Settlement:**
15. `settle_funds` -- Transfer free balances from OpenOrders to user wallets

**Admin:**
16. `prune_orders` -- Authority force-cancels stale orders
17. `sweep_fees` -- Collect accumulated protocol fees

## Original vs 5ive

| Metric | Rust/Anchor | 5ive DSL |
|--------|-------------|----------|
| Code size | ~12,000 SLoC | ~500 SLoC |
| Bytecode | ~300 KB | ~3 KB |
| Compute | Baseline | ~60% less |

## Build & Test

```bash
five build
five local execute build/main.five 0
```

## Migration Notes

The original OpenBook uses an on-chain red-black tree for the order book, which is abstracted here to per-order accounts. The matching engine walks the book in production -- this migration represents single-match-per-crank invocations. Event queue processing and the full self-trade behavior matrix (decrement_take, cancel_provide, abort) are faithfully preserved.
