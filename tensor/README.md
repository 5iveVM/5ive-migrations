# 5ive Migration: Tensor NFT DEX

A complete 5ive DSL migration of Tensor, Solana's leading NFT marketplace and DEX. Combines an NFT AMM (bonding curve pools for instant buy/sell) with a traditional order book (listings, collection bids, trait bids).

## Architecture

```
tensor/
  src/
    main.v          # Full 5ive DSL program (25 instructions + helpers)
  README.md
```

## Account Model

| Account           | Purpose                                              |
|--------------------|------------------------------------------------------|
| `Pool`             | NFT AMM pool: bonding curve config, NFT/SOL balances, fees, royalties |
| `Listing`          | Fixed-price NFT listing on the order book             |
| `CollectionBid`    | Floor bid on any NFT in a collection                  |
| `TraitBid`         | Bid targeting NFTs with specific traits               |
| `MarketplaceConfig`| Global marketplace fee settings and pause state       |

## Instructions (25)

### NFT AMM (Bonding Curves)

| #  | Instruction          | Description                                        |
|----|----------------------|----------------------------------------------------|
| 1  | `create_pool`        | Create pool with curve type (linear/exp), delta, spot price, fee |
| 2  | `deposit_nft`        | Deposit NFT into pool (sell-side liquidity)         |
| 3  | `deposit_sol`        | Deposit SOL into pool (buy-side liquidity)          |
| 4  | `buy_nft_from_pool`  | Instant buy at current curve price + fees           |
| 5  | `sell_nft_to_pool`   | Instant sell at current curve price - fees          |
| 6  | `withdraw_nft`       | Owner removes NFT from pool                        |
| 7  | `withdraw_sol`       | Owner removes SOL from pool                        |

### Order Book

| #  | Instruction           | Description                                       |
|----|-----------------------|---------------------------------------------------|
| 8  | `list_nft`            | List NFT at fixed price (escrowed)                |
| 9  | `delist_nft`          | Cancel listing, return NFT to seller              |
| 10 | `buy_listed_nft`      | Purchase listed NFT, marketplace fee deducted     |
| 11 | `place_collection_bid`| Bid on any NFT in a collection (SOL escrowed)     |
| 12 | `cancel_collection_bid`| Cancel bid, refund remaining SOL                 |
| 13 | `accept_collection_bid`| Seller fills a collection bid with their NFT     |
| 14 | `place_trait_bid`     | Bid on NFTs with specific trait key/value         |
| 15 | `cancel_trait_bid`    | Cancel trait bid, refund remaining SOL            |
| 16 | `accept_trait_bid`    | Seller fills a trait bid (trait verified on-chain) |

### Royalties and Fees

| #  | Instruction            | Description                                      |
|----|------------------------|--------------------------------------------------|
| 17 | `set_pool_fee`         | Update pool trading fee (bps)                    |
| 18 | `set_royalty_enforcement`| Toggle creator royalty enforcement              |
| 19 | `collect_pool_fees`    | Withdraw accumulated pool trading fees           |
| 20 | `distribute_royalties` | Send accrued royalties to creator                |

### Admin

| #  | Instruction            | Description                                      |
|----|------------------------|--------------------------------------------------|
| 21 | `set_authority`        | Transfer pool authority to new key               |
| 22 | `set_pool_pause`       | Pause/unpause a pool                             |
| 23 | `init_marketplace`     | Initialize marketplace config                    |
| 24 | `set_marketplace_fee`  | Update global marketplace fee (bps)              |
| 25 | `set_marketplace_pause`| Pause/unpause the marketplace                    |

## Bonding Curve Math

**Linear curve:**
```
price(n) = spot_price + delta * n
```

**Exponential curve:**
```
price(n) = spot_price * (1 + delta/10000)^n
```

Where `n` is the number of trades executed on that side of the pool. After each buy, `buy_count` increments, raising the buy price. After each sell, `sell_count` increments, adjusting the sell price. This creates automatic price discovery.

## Fee Flow

```
Buy from pool:
  total_cost = base_price + pool_fee + royalty (if enforced)
  pool receives base_price, fees/royalties accrue in pool

Sell to pool:
  payout = base_price - pool_fee - royalty (if enforced)
  pool pays seller the payout, fees/royalties accrue in pool

Order book (listing/bid):
  marketplace_fee deducted from sale price
  seller receives price - marketplace_fee
```

## DSL Patterns Used

- `account` structs with typed fields (`pubkey`, `u64`, `u8`, `bool`)
- `@mut @init(payer=..., space=...)` for account initialization
- `@signer` for authority verification
- `require(...)` for all validation checks
- `spl_token::SPLToken::transfer(from, to, authority, amount)` for token moves
- `fn` for private helpers; `pub` for on-chain instructions
- `let mut` for mutable locals; `if/else` for control flow

## Source Protocol

- **Tensor** - https://tensor.trade
- Solana's #1 NFT marketplace by volume
- Combines AMM liquidity pools with order book trading
- Supports creator royalty enforcement
