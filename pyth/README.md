# Pyth Network Oracle -- 5ive DSL Migration

A complete migration of the Pyth Network price oracle to the 5ive DSL. Pyth is Solana's #1 oracle, powering 300+ DeFi protocols with real-time price data from institutional publishers.

## What This Implements

The core on-chain logic of the Pyth oracle:

- **Product registration** -- assets like SOL/USD, BTC/USD with metadata
- **Price feed management** -- per-asset feeds with price, confidence, exponent, status
- **Publisher authorization** -- permissioned data providers who submit quotes
- **Price aggregation** -- weighted median of publisher prices with confidence-based weighting
- **Staleness detection** -- automatic stale price rejection based on slot age
- **Consumer APIs** -- safe and unsafe price reads with configurable staleness windows

## Architecture

```
OracleConfig (1 per deployment)
  |
  +-- Product (1 per asset, e.g., SOL/USD)
  |     |
  |     +-- PriceFeed (1 per product)
  |           |
  |           +-- PublisherPrice (1 per authorized publisher)
  |           +-- PublisherPrice ...
  |           +-- PublisherPrice ...
  |
  +-- Product (BTC/USD)
        |
        +-- PriceFeed
              +-- PublisherPrice ...
```

## Account Layout

| Account | Key Fields | Space |
|---------|-----------|-------|
| OracleConfig | authority, staleness_slots, num_products | 256 |
| Product | symbol (u64 pair), asset_type, price_account, num_publishers | 512 |
| PriceFeed | price (i64), confidence (u64), exponent (i64), status (u8), last_slot, min_publishers | 512 |
| PublisherPrice | feed, publisher, price (i64), confidence (u64), last_slot, status, is_active | 512 |

## Instructions

### Admin (authority-gated)

| Instruction | Description |
|-------------|-------------|
| `init_mapping` | Bootstrap the oracle with staleness config |
| `add_product` | Register a new tradeable asset |
| `add_price` | Create a price feed for a product |
| `add_publisher` | Authorize a publisher for a feed |
| `del_publisher` | Revoke a publisher's authorization |
| `set_min_publishers` | Set minimum publishers for valid aggregation |
| `update_staleness` | Change the staleness window (slots) |
| `transfer_authority` | Transfer admin to a new key |
| `set_product_active` | Pause/unpause a product |

### Core Operations

| Instruction | Description |
|-------------|-------------|
| `update_price` | Publisher submits price + confidence + status |
| `aggregate_price` | Compute weighted median from up to 8 publisher quotes |

### Consumer APIs

| Instruction | Description |
|-------------|-------------|
| `get_price` | Read aggregated price (staleness-checked) |
| `get_price_with_confidence` | Read price; confidence available on feed account |
| `get_price_no_older_than` | Read price with custom max age |
| `get_price_unsafe` | Read price without staleness check |
| `is_price_stale` | Check if price exceeds staleness window |
| `get_feed_status` | Read feed status (0=unknown, 1=trading, 2=halted) |
| `get_feed_confidence` | Read aggregate confidence interval |
| `get_feed_exponent` | Read price exponent (e.g., -8) |
| `get_feed_last_slot` | Read slot of last aggregation |
| `get_num_publishers` | Read number of active publishers |

## Aggregation Algorithm

The aggregation uses a **weighted median** approach:

1. **Collect** -- Gather all publisher quotes that are fresh (within staleness window), active, and in trading status
2. **Weight** -- Assign each quote a weight inversely proportional to its confidence interval (tighter confidence = more weight)
3. **Sort** -- Bubble sort all quotes by price (ascending)
4. **Median** -- Walk sorted prices accumulating weights; the median is the price where cumulative weight crosses 50% of total weight
5. **Confidence** -- Aggregate confidence is the weighted mean absolute deviation (MAD) of publisher prices from the median

This matches Pyth's real aggregation philosophy: publishers with tighter confidence intervals have more influence on the final price, and the confidence of the aggregate reflects the spread of publisher opinions.

## Price Representation

- **Price**: `i64` (signed -- supports negative values for derivatives)
- **Exponent**: `i64` (e.g., -8 means actual price = price * 10^-8)
- **Confidence**: `u64` (always positive, same exponent as price)
- **Status**: `u8` (0 = unknown, 1 = trading, 2 = halted)

Example: SOL/USD at $150.25 with exponent -8:
- price = 15025000000 (i64)
- confidence = 1000000 (u64, representing $0.01 uncertainty)
- exponent = -8 (i64)

## Build & Test

```bash
five build
five local execute build/main.five 0   # init_mapping
five local execute build/main.five 1   # add_product
five local execute build/main.five 6   # update_price
five local execute build/main.five 7   # aggregate_price
five local execute build/main.five 8   # get_price
```

Deploy to devnet:

```bash
five deploy build/main.five --cluster devnet
```

## Migration Notes

- The original Pyth oracle is ~8,000 lines of Rust. This 5ive migration is ~450 lines.
- Symbols are stored as a u64 pair (symbol_high, symbol_low) since 5ive does not have native string types. This encodes up to 16 bytes of symbol data.
- The aggregation instruction accepts up to 8 publisher accounts per call. For feeds with more publishers, the aggregation can be extended or called in batches.
- Off-chain publisher infrastructure (price fetching, submission scheduling) is out of scope -- those are off-chain agents that submit standard Solana transactions.

## License

MIT
