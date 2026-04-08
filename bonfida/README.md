# 5ive Bonfida Migration -- DEX + Solana Name Service

Bonfida's two flagship Solana products rewritten in 5ive DSL: the Serum-based central limit order book (CLOB) DEX and the Solana Name Service (SNS / .sol domains). Implements the complete on-chain instruction set across both protocols: order placement/matching/settlement for the DEX, and domain registration/renewal/subdomain/reverse-lookup for the name service.

## What Bonfida Does

### Part 1: Bonfida DEX (CLOB)

A fully on-chain central limit order book exchange originally built on top of Serum/OpenBook. Traders place limit, IOC, and post-only orders that are matched by crankers using price-time priority.

- **Order Book**: Bids sorted descending by price, asks ascending. Match when bid >= ask price.
- **Order Types**: Limit (resting), IOC (fill-or-kill remainder), Post-Only (reject if would cross).
- **OpenOrders**: Per-user per-market account that locks deposited funds until orders fill or cancel.
- **Crank Model**: External crankers call `match_orders` to cross bids/asks, producing settlement events. `consume_events` finalizes them. `settle_funds` transfers filled tokens to user wallets.
- **Fees**: Configurable maker/taker basis points per market.

### Part 2: Solana Name Service (SNS)

The .sol domain name system. Users register human-readable names (e.g., `alice.sol`) that resolve to Solana addresses, with time-based expiration, subdomains, and reverse lookups.

- **Registration**: Pay a fee, get a domain that maps a name hash to a resolver address.
- **Renewal**: Extend expiration by paying a renewal fee.
- **Subdomains**: Create names under a parent (e.g., `mail.alice.sol`), inheriting parent expiry.
- **Reverse Records**: Map addresses back to domain names for display.
- **Domain Hashing**: Names stored as pubkey-sized hashes since 5ive uses fixed-size fields.

### Design Decisions for 5ive

1. Domain names are represented as pubkey-sized hashes (keccak256) since 5ive accounts use fixed-size fields -- no variable-length strings.
2. The order book is modeled with discrete Order accounts rather than a contiguous memory slab, preserving the matching logic and fund locking semantics.
3. `cancel_all_orders` takes two representative orders as arguments since 5ive cannot iterate over unbounded account sets in a single instruction.
4. Settlement events are explicit SettlementRecord accounts rather than an append-only queue, preserving the produce/consume pattern.
5. QUOTE_PRECISION is 1,000,000 (6 decimals) for all quote-side calculations.

## Instructions Implemented

### DEX -- Order Book

| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_market` | Initialize a new trading market with base/quote mints, vaults, and fee config |
| 2 | `init_open_orders` | Create a user's open orders account for a market |
| 3 | `place_order` | Place a limit/IOC/post-only order, locking funds in open orders |
| 4 | `cancel_order` | Cancel an active order, unlocking remaining funds |
| 5 | `cancel_all_orders` | Cancel multiple orders for a user in one instruction |
| 6 | `match_orders` | Crank: match a crossing bid and ask, produce settlement |
| 7 | `settle_funds` | Transfer filled base/quote tokens from open orders to user wallets |
| 8 | `consume_events` | Finalize settlement events from the event queue |
| 9 | `close_open_orders` | Close an empty open orders account, reclaim rent |
| 10 | `set_market_fees` | Update maker/taker fee basis points |
| 11 | `pause_market` | Emergency: deactivate a market |
| 11 | `unpause_market` | Emergency: reactivate a market |

### Name Service -- .sol Domains

| # | Instruction | Description |
|---|-------------|-------------|
| 12 | `init_name_service` | Initialize config with fees, treasury, name length limits |
| 13 | `register_name` | Register a new .sol domain, pay fee, set resolver |
| 14 | `renew_name` | Extend domain expiration, pay renewal fee |
| 15 | `transfer_name` | Transfer domain ownership to a new address |
| 16 | `update_resolver` | Change the address a domain resolves to |
| 17 | `delete_name` | Delete an expired or owned domain |
| 18 | `create_subdomain` | Create a subdomain under an owned parent domain |
| 19 | `transfer_subdomain` | Transfer subdomain ownership |
| 20 | `delete_subdomain` | Delete a subdomain (owner, parent owner, or expired) |
| 21 | `create_reverse_record` | Map an address back to a domain name |
| 22 | `delete_reverse_record` | Remove a reverse mapping |
| 23 | `set_registration_fee` | Admin: update domain registration fee |
| 24 | `set_renewal_fee` | Admin: update domain renewal fee |
| 25 | `set_name_service_authority` | Admin: transfer name service authority |

### Read-Only Queries

| Instruction | Description |
|-------------|-------------|
| `get_market_volume` | Total volume traded on a market (u128) |
| `get_order_status` | Whether an order is active |
| `get_order_filled_size` | Amount filled on an order |
| `get_order_remaining_size` | Unfilled size remaining |
| `get_open_orders_base_free` | Unsettled base available for withdrawal |
| `get_open_orders_quote_free` | Unsettled quote available for withdrawal |
| `get_open_orders_base_locked` | Base locked in active orders |
| `get_open_orders_quote_locked` | Quote locked in active orders |
| `get_maker_fee_bps` | Market's maker fee in basis points |
| `get_taker_fee_bps` | Market's taker fee in basis points |
| `get_domain_owner` | Current owner of a domain |
| `get_domain_resolver` | Address a domain resolves to |
| `get_domain_expiry` | Domain expiration timestamp |
| `get_subdomain_resolver` | Address a subdomain resolves to |
| `get_subdomain_expiry` | Subdomain expiration timestamp |
| `get_reverse_name` | Domain name hash for a reverse record |
| `get_registration_fee` | Current registration fee |
| `get_renewal_fee` | Current renewal fee |
| `is_domain_expired` | Whether a domain has expired |
| `is_reverse_active` | Whether a reverse record is active |

## Account Structure

### Market (512 bytes)
One per trading pair. Holds vault references, fee config, and cumulative volume.

| Field | Type | Description |
|-------|------|-------------|
| base_mint | pubkey | Base token mint |
| quote_mint | pubkey | Quote token mint |
| base_vault | pubkey | Base token vault |
| quote_vault | pubkey | Quote token vault |
| bids_account | pubkey | Bids book reference |
| asks_account | pubkey | Asks book reference |
| event_queue | pubkey | Event queue reference |
| min_order_size | u64 | Minimum order size |
| tick_size | u64 | Price tick increment |
| maker_fee_bps | u64 | Maker fee (0-500 bps) |
| taker_fee_bps | u64 | Taker fee (0-500 bps) |
| total_volume | u128 | Cumulative trade volume |
| authority | pubkey | Market admin |
| is_active | bool | Trading enabled flag |

### Order (512 bytes)
Individual order on the book.

| Field | Type | Description |
|-------|------|-------------|
| market | pubkey | Parent market |
| owner | pubkey | Order placer |
| side | u8 | 0=bid, 1=ask |
| price | u64 | Limit price |
| size | u64 | Total order size |
| filled_size | u64 | Amount already filled |
| order_id | u64 | Unique order ID |
| client_order_id | u64 | Client-assigned ID |
| timestamp | u64 | Placement time |
| is_active | bool | Order is live |
| order_type | u8 | 0=limit, 1=IOC, 2=post_only |

### OpenOrders (512 bytes)
Per-user per-market fund custody.

| Field | Type | Description |
|-------|------|-------------|
| market | pubkey | Parent market |
| owner | pubkey | Account owner |
| base_free | u64 | Base available to settle |
| base_locked | u64 | Base locked in orders |
| quote_free | u64 | Quote available to settle |
| quote_locked | u64 | Quote locked in orders |
| num_orders | u8 | Active order count |

### SettlementRecord (512 bytes)
Trade settlement event produced by matching.

| Field | Type | Description |
|-------|------|-------------|
| market | pubkey | Parent market |
| maker | pubkey | Maker address |
| taker | pubkey | Taker address |
| price | u64 | Match price |
| size | u64 | Fill size |
| maker_fee | u64 | Fee charged to maker |
| taker_fee | u64 | Fee charged to taker |
| timestamp | u64 | Match time |

### NameServiceConfig (512 bytes)
Global name service configuration.

| Field | Type | Description |
|-------|------|-------------|
| admin | pubkey | Service admin |
| registration_fee | u64 | Fee to register a name |
| renewal_fee | u64 | Fee to renew a name |
| treasury | pubkey | Fee recipient |
| min_name_length | u8 | Minimum name length |
| max_name_length | u8 | Maximum name length |

### DomainRecord (512 bytes)
A registered .sol domain.

| Field | Type | Description |
|-------|------|-------------|
| name_hash | pubkey | Keccak256 hash of the domain string |
| owner | pubkey | Current owner |
| resolver | pubkey | Address this name resolves to |
| parent_hash | pubkey | Parent domain hash (root for TLDs) |
| created_at | u64 | Registration timestamp |
| expires_at | u64 | Expiration timestamp |
| is_transferable | bool | Whether transfers are allowed |

### SubdomainRecord (512 bytes)
A subdomain under a parent domain.

| Field | Type | Description |
|-------|------|-------------|
| parent_hash | pubkey | Parent domain's name hash |
| subdomain_hash | pubkey | This subdomain's name hash |
| owner | pubkey | Subdomain owner |
| resolver | pubkey | Address this subdomain resolves to |
| expires_at | u64 | Inherited from parent at creation |

### ReverseRecord (512 bytes)
Maps an address back to a domain name.

| Field | Type | Description |
|-------|------|-------------|
| address | pubkey | The Solana address |
| name_hash | pubkey | Domain name hash it maps to |
| is_active | bool | Whether the mapping is live |

### NameRegistry (512 bytes)
Registry entry linking name metadata.

| Field | Type | Description |
|-------|------|-------------|
| owner | pubkey | Registry owner |
| class_authority | pubkey | Class-level authority |
| parent | pubkey | Parent registry/config |
| data_hash | pubkey | Hash of stored data |
| expiry_timestamp | u64 | Expiration |
| is_active | bool | Active flag |

## Key Math

### Order Matching (Price-Time Priority)
```
// Match when bid price >= ask price
require(bid_order.price >= ask_order.price)

// Fill at maker's price
fill_size = min(bid_remaining, ask_remaining)
quote_amount = (fill_size * match_price) / 1000000
```

### Fee Calculation
```
QUOTE_PRECISION = 1000000

maker_fee = (size * price * maker_fee_bps) / (10000 * QUOTE_PRECISION)
taker_fee = (size * price * taker_fee_bps) / (10000 * QUOTE_PRECISION)
```

### IOC (Immediate-or-Cancel)
```
// After matching, cancel any unfilled remainder
if order_type == 1 && filled < total:
    unlock remaining funds
    deactivate order
```

### Post-Only
```
// Rejected at match time if it would cross the book
require(bid_order.order_type != 2)
require(ask_order.order_type != 2)
```

### Domain Renewal
```
// Extend from current expiry if still active, from now if expired
if domain.expires_at < now:
    new_expiry = now + duration
else:
    new_expiry = domain.expires_at + duration
```

### Subdomain Expiry Inheritance
```
subdomain.expires_at = parent_domain.expires_at
```

## Build

```bash
five build
five deploy --cluster devnet
```

## Source Protocols

- **Bonfida DEX**: https://bonfida.org
- **Solana Name Service**: https://sns.id
- **SNS Program ID**: `namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX`
- **Bonfida DEX Program ID**: `9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin`
- **Docs**: https://docs.bonfida.org
