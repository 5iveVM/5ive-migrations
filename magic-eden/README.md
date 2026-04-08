# 5ive-magic-eden: Magic Eden Marketplace Migration

A complete 5ive DSL migration of Magic Eden -- the #1 NFT marketplace on Solana, covering listings, auctions, offers, launchpads, and royalty enforcement.

## What This Implements

Magic Eden is a full-featured NFT marketplace supporting fixed-price listings, timed auctions, buyer offers, collection-wide offers, and launchpad minting events. The marketplace enforces configurable royalty policies and collects fees on all trades.

### Key Innovation -- Royalty Policy Engine

Magic Eden supports three royalty enforcement modes:
- **Enforce (0):** Royalties are mandatory on every sale
- **Optional (1):** Buyer can choose to pay royalties
- **Ignore (2):** No royalties collected

Payment splits on every sale: seller receives `price - marketplace_fee - royalties`.

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Marketplace** | Global config: fees, volume, royalty policy | 512 |
| **Listing** | Fixed-price NFT listing with escrow | 512 |
| **Offer** | Buyer offer on specific NFT with escrowed payment | 512 |
| **Auction** | Timed auction with min bid and highest bidder tracking | 512 |
| **Launchpad** | Collection mint event with whitelist and public phases | 512 |
| **CollectionOffer** | Floor bid on any NFT in a collection | 512 |

### Instructions (22 total)

**Marketplace:**
1. `init_marketplace` -- Initialize with fee config and royalty policy

**Listings:**
2. `list_nft` -- Seller lists NFT at fixed price (NFT escrowed)
3. `delist_nft` -- Seller removes listing (NFT returned)
4. `buy_nft` -- Purchase listed NFT (atomic swap with payment splits)
5. `update_listing_price` -- Change listing price

**Offers:**
6. `make_offer` -- Buyer offers on specific NFT (payment escrowed)
7. `cancel_offer` -- Buyer cancels and reclaims escrowed funds
8. `accept_offer` -- Seller accepts offer (atomic swap)

**Auctions:**
9. `create_auction` -- Timed auction with minimum bid
10. `place_bid` -- Bid on auction (must outbid current highest; previous bidder refunded)
11. `cancel_bid` -- No-op safety check (refund happens on outbid)
12. `settle_auction` -- Highest bidder wins after end_time

**Launchpad:**
13. `create_launchpad` -- Collection mint event with whitelist + public phases
14. `mint_from_launchpad` -- Mint NFT during launch event

**Collection Offers:**
15. `create_collection_offer` -- Floor bid on any NFT in a collection (multi-fill)
16. `cancel_collection_offer` -- Cancel and reclaim remaining escrowed funds
17. `accept_collection_offer` -- Seller fills one unit of a collection offer

**Royalties & Fees:**
18. `set_royalty_policy` -- Change royalty enforcement mode
19. `set_marketplace_fee` -- Update marketplace fee (basis points)
20. `collect_marketplace_fees` -- Collect accumulated fees
21. `distribute_royalties` -- Distribute accumulated royalties to creators

**Admin:**
22. `set_authority` -- Transfer marketplace authority

## Key Design Decisions

### Payment Splits

Every sale (buy, accept_offer, settle_auction, accept_collection_offer) splits payment:
```
marketplace_fee = (price * fee_bps) / 10000
royalty_amount  = (price * royalty_bps) / 10000   (if policy != ignore)
seller_proceeds = price - marketplace_fee - royalty_amount
```

### NFT Escrow

Listed NFTs and auctioned NFTs are transferred to an escrow vault:
- Prevents double-listing or transfer while listed
- Escrow returns NFT on delist or failed auction (no bids)
- On purchase, NFT transfers from escrow directly to buyer

### Auction Mechanics

- Bids must exceed current highest bid and minimum bid
- Previous highest bidder is refunded immediately on outbid
- Settlement only allowed after end_time
- If no bids, NFT returns to seller
- Seller settles the auction (triggers payment splits)

### Launchpad Phases

| Phase | Time Window | Access |
|-------|-------------|--------|
| Whitelist | whitelist_start to public_start | Whitelisted wallets (verified off-chain) |
| Public | public_start to end_time | Open to all |

### Collection Offers

- Buyer specifies price per NFT and quantity desired
- Escrows `price * quantity` upfront
- Any holder of the collection can accept (fills one unit)
- Partial fills tracked via `filled` counter
- Cancel returns remaining unfilled escrow

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
magic-eden/
  src/
    main.v           -- Complete Magic Eden migration
```

## Source Protocol

- [Magic Eden](https://magiceden.io) -- Solana's leading NFT marketplace
- This migration faithfully represents listings, auctions, offers, launchpads, and royalty enforcement
