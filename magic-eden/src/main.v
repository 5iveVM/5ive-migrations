// 5IVE Magic Eden Protocol -- NFT marketplace
//
// Design (Magic Eden v2-inspired):
//   - Fixed-price listings, offers, and timed auctions
//   - Launchpad for collection mints (whitelist + public phases)
//   - Royalty enforcement policy: enforce, optional, or ignore
//   - Payment splits: seller receives price - marketplace_fee - royalties
//   - Offers escrow SOL/tokens; collection offers bid on any NFT in a collection
//   - All prices in lamports (u64); royalties in basis points
//   - NFT transfers via spl_token (NFTs are mints with supply=1)
//   - Timestamps via get_clock().unix_timestamp

use std::interfaces::spl_token;

account Marketplace {
    authority: pubkey;
    fee_bps: u64;                  // marketplace fee in basis points
    fee_collector: pubkey;
    total_volume: u64;             // cumulative trade volume in lamports
    total_sales: u64;              // total number of sales completed
    royalty_policy: u8;            // 0=enforce, 1=optional, 2=ignore
    is_active: bool;
}

account Listing {
    marketplace: pubkey;
    seller: pubkey;
    nft_mint: pubkey;
    price: u64;                    // listing price in lamports
    escrow_vault: pubkey;          // vault holding the listed NFT
    created_at: u64;
    is_active: bool;
}

account Offer {
    marketplace: pubkey;
    buyer: pubkey;
    nft_mint: pubkey;
    price: u64;                    // offer price in lamports
    escrow_vault: pubkey;          // vault holding escrowed payment tokens
    expires_at: u64;               // offer expiration timestamp
    is_active: bool;
}

account Auction {
    marketplace: pubkey;
    seller: pubkey;
    nft_mint: pubkey;
    min_bid: u64;                  // minimum starting bid
    highest_bid: u64;
    highest_bidder: pubkey;
    start_time: u64;
    end_time: u64;
    is_settled: bool;
}

account Launchpad {
    marketplace: pubkey;
    collection_mint: pubkey;       // collection identifier
    price: u64;                    // mint price per NFT
    max_supply: u64;
    minted: u64;
    whitelist_start: u64;
    public_start: u64;
    end_time: u64;
    authority: pubkey;
}

account CollectionOffer {
    marketplace: pubkey;
    buyer: pubkey;
    collection_mint: pubkey;
    price: u64;                    // offer price per NFT
    quantity: u64;                 // number of NFTs buyer wants
    filled: u64;                   // number already filled
    escrow_vault: pubkey;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Calculate marketplace fee: (price * fee_bps) / 10000
fn calculate_fee(price: u64, fee_bps: u64) -> u64 {
    return (price * fee_bps) / 10000;
}

// Calculate royalty amount: (price * royalty_bps) / 10000
fn calculate_royalty(price: u64, royalty_bps: u64) -> u64 {
    return (price * royalty_bps) / 10000;
}

// ---------------------------------------------------------------------------
// Marketplace initialization
// ---------------------------------------------------------------------------

pub init_marketplace(
    marketplace: Marketplace @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    fee_collector: pubkey,
    fee_bps: u64,
    royalty_policy: u8
) {
    require(fee_bps <= 1000);      // max 10%
    require(royalty_policy <= 2);   // 0=enforce, 1=optional, 2=ignore

    marketplace.authority = authority.ctx.key;
    marketplace.fee_bps = fee_bps;
    marketplace.fee_collector = fee_collector;
    marketplace.total_volume = 0;
    marketplace.total_sales = 0;
    marketplace.royalty_policy = royalty_policy;
    marketplace.is_active = true;
}

// ---------------------------------------------------------------------------
// Fixed-price listings
// ---------------------------------------------------------------------------

// Seller lists an NFT at a fixed price
pub list_nft(
    marketplace: Marketplace,
    listing: Listing @mut @init(payer=seller, space=512) @signer,
    seller: account @mut @signer,
    seller_nft_account: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    nft_mint: pubkey,
    price: u64
) {
    require(marketplace.is_active);
    require(price > 0);

    // Transfer NFT from seller to escrow vault
    spl_token::SPLToken::transfer(seller_nft_account, escrow_vault, seller, 1);

    listing.marketplace = marketplace.ctx.key;
    listing.seller = seller.ctx.key;
    listing.nft_mint = nft_mint;
    listing.price = price;
    listing.escrow_vault = escrow_vault.ctx.key;
    listing.created_at = get_clock().unix_timestamp;
    listing.is_active = true;
}

// Seller delists an NFT -- returns NFT from escrow
pub delist_nft(
    listing: Listing @mut,
    seller: account @signer,
    seller_nft_account: account @mut,
    escrow_vault: account @mut,
    token_program: account
) {
    require(listing.is_active);
    require(listing.seller == seller.ctx.key);
    require(escrow_vault.ctx.key == listing.escrow_vault);

    // Return NFT to seller
    spl_token::SPLToken::transfer(escrow_vault, seller_nft_account, seller, 1);

    listing.is_active = false;
}

// Buyer purchases a listed NFT -- atomic swap: payment to seller, NFT to buyer
// Splits payment: seller gets price - marketplace_fee - royalties
pub buy_nft(
    marketplace: Marketplace @mut,
    listing: Listing @mut,
    buyer: account @mut @signer,
    buyer_payment: account @mut,
    buyer_nft_account: account @mut,
    seller_payment: account @mut,
    fee_collector_account: account @mut,
    royalty_recipient: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    royalty_bps: u64
) {
    require(marketplace.is_active);
    require(listing.is_active);
    require(escrow_vault.ctx.key == listing.escrow_vault);
    require(fee_collector_account.ctx.key == marketplace.fee_collector);

    let price: u64 = listing.price;

    // Calculate fee splits
    let marketplace_fee: u64 = calculate_fee(price, marketplace.fee_bps);

    let mut royalty_amount: u64 = 0;
    if (marketplace.royalty_policy == 0) {
        // Enforce: royalties are mandatory
        royalty_amount = calculate_royalty(price, royalty_bps);
    } else if (marketplace.royalty_policy == 1) {
        // Optional: buyer-specified royalty (can be 0)
        royalty_amount = calculate_royalty(price, royalty_bps);
    }
    // royalty_policy == 2: ignore, royalty_amount stays 0

    let seller_proceeds: u64 = price - marketplace_fee - royalty_amount;
    require(seller_proceeds > 0);

    // Transfer payment from buyer
    spl_token::SPLToken::transfer(buyer_payment, seller_payment, buyer, seller_proceeds);
    spl_token::SPLToken::transfer(buyer_payment, fee_collector_account, buyer, marketplace_fee);

    if (royalty_amount > 0) {
        spl_token::SPLToken::transfer(buyer_payment, royalty_recipient, buyer, royalty_amount);
    }

    // Transfer NFT from escrow to buyer
    spl_token::SPLToken::transfer(escrow_vault, buyer_nft_account, buyer, 1);

    listing.is_active = false;

    marketplace.total_volume = marketplace.total_volume + price;
    marketplace.total_sales = marketplace.total_sales + 1;
}

// Update the listing price
pub update_listing_price(
    listing: Listing @mut,
    seller: account @signer,
    new_price: u64
) {
    require(listing.is_active);
    require(listing.seller == seller.ctx.key);
    require(new_price > 0);

    listing.price = new_price;
}

// ---------------------------------------------------------------------------
// Offers
// ---------------------------------------------------------------------------

// Buyer makes an offer on a specific NFT, escrowing payment tokens
pub make_offer(
    marketplace: Marketplace,
    offer: Offer @mut @init(payer=buyer, space=512) @signer,
    buyer: account @mut @signer,
    buyer_payment: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    nft_mint: pubkey,
    price: u64,
    expires_at: u64
) {
    require(marketplace.is_active);
    require(price > 0);

    let now: u64 = get_clock().unix_timestamp;
    require(expires_at > now);

    // Escrow the offer amount
    spl_token::SPLToken::transfer(buyer_payment, escrow_vault, buyer, price);

    offer.marketplace = marketplace.ctx.key;
    offer.buyer = buyer.ctx.key;
    offer.nft_mint = nft_mint;
    offer.price = price;
    offer.escrow_vault = escrow_vault.ctx.key;
    offer.expires_at = expires_at;
    offer.is_active = true;
}

// Buyer cancels their offer and reclaims escrowed funds
pub cancel_offer(
    offer: Offer @mut,
    buyer: account @signer,
    buyer_payment: account @mut,
    escrow_vault: account @mut,
    token_program: account
) {
    require(offer.is_active);
    require(offer.buyer == buyer.ctx.key);
    require(escrow_vault.ctx.key == offer.escrow_vault);

    // Return escrowed payment to buyer
    spl_token::SPLToken::transfer(escrow_vault, buyer_payment, buyer, offer.price);

    offer.is_active = false;
}

// Seller accepts an offer -- atomic swap: NFT to buyer, payment to seller
pub accept_offer(
    marketplace: Marketplace @mut,
    offer: Offer @mut,
    seller: account @signer,
    seller_nft_account: account @mut,
    seller_payment: account @mut,
    buyer_nft_account: account @mut,
    fee_collector_account: account @mut,
    royalty_recipient: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    royalty_bps: u64
) {
    require(marketplace.is_active);
    require(offer.is_active);
    require(escrow_vault.ctx.key == offer.escrow_vault);

    let now: u64 = get_clock().unix_timestamp;
    require(now <= offer.expires_at);

    let price: u64 = offer.price;

    // Calculate splits
    let marketplace_fee: u64 = calculate_fee(price, marketplace.fee_bps);
    let mut royalty_amount: u64 = 0;
    if (marketplace.royalty_policy == 0) {
        royalty_amount = calculate_royalty(price, royalty_bps);
    } else if (marketplace.royalty_policy == 1) {
        royalty_amount = calculate_royalty(price, royalty_bps);
    }

    let seller_proceeds: u64 = price - marketplace_fee - royalty_amount;
    require(seller_proceeds > 0);

    // Transfer payment from escrow to seller, fee collector, and royalty recipient
    spl_token::SPLToken::transfer(escrow_vault, seller_payment, seller, seller_proceeds);
    spl_token::SPLToken::transfer(escrow_vault, fee_collector_account, seller, marketplace_fee);
    if (royalty_amount > 0) {
        spl_token::SPLToken::transfer(escrow_vault, royalty_recipient, seller, royalty_amount);
    }

    // Transfer NFT from seller to buyer
    spl_token::SPLToken::transfer(seller_nft_account, buyer_nft_account, seller, 1);

    offer.is_active = false;

    marketplace.total_volume = marketplace.total_volume + price;
    marketplace.total_sales = marketplace.total_sales + 1;
}

// ---------------------------------------------------------------------------
// Auctions
// ---------------------------------------------------------------------------

// Create a timed auction for an NFT
pub create_auction(
    marketplace: Marketplace,
    auction: Auction @mut @init(payer=seller, space=512) @signer,
    seller: account @mut @signer,
    seller_nft_account: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    nft_mint: pubkey,
    min_bid: u64,
    start_time: u64,
    end_time: u64
) {
    require(marketplace.is_active);
    require(min_bid > 0);
    require(end_time > start_time);

    let now: u64 = get_clock().unix_timestamp;
    require(start_time >= now);

    // Transfer NFT to escrow
    spl_token::SPLToken::transfer(seller_nft_account, escrow_vault, seller, 1);

    auction.marketplace = marketplace.ctx.key;
    auction.seller = seller.ctx.key;
    auction.nft_mint = nft_mint;
    auction.min_bid = min_bid;
    auction.highest_bid = 0;
    auction.highest_bidder = seller.ctx.key;  // sentinel: no bidder yet
    auction.start_time = start_time;
    auction.end_time = end_time;
    auction.is_settled = false;
}

// Place a bid on an auction -- must outbid current highest
pub place_bid(
    auction: Auction @mut,
    bidder: account @mut @signer,
    bidder_payment: account @mut,
    escrow_vault: account @mut,
    previous_bidder_refund: account @mut,
    token_program: account,
    bid_amount: u64
) {
    require(!auction.is_settled);

    let now: u64 = get_clock().unix_timestamp;
    require(now >= auction.start_time);
    require(now < auction.end_time);

    require(bid_amount >= auction.min_bid);
    require(bid_amount > auction.highest_bid);

    // Refund previous highest bidder (if any)
    if (auction.highest_bid > 0) {
        spl_token::SPLToken::transfer(escrow_vault, previous_bidder_refund, bidder, auction.highest_bid);
    }

    // Escrow new bid
    spl_token::SPLToken::transfer(bidder_payment, escrow_vault, bidder, bid_amount);

    auction.highest_bid = bid_amount;
    auction.highest_bidder = bidder.ctx.key;
}

// Cancel a bid -- only allowed if you are not the highest bidder
// (Highest bidder must wait for auction end or be outbid)
pub cancel_bid(
    auction: Auction,
    bidder: account @signer
) {
    require(!auction.is_settled);

    // Only non-highest bidders can cancel (their funds were already refunded on outbid)
    // This is a no-op safety check; actual refund happened in place_bid
    require(auction.highest_bidder != bidder.ctx.key);
}

// Settle the auction after end_time -- highest bidder wins
pub settle_auction(
    marketplace: Marketplace @mut,
    auction: Auction @mut,
    seller_payment: account @mut,
    winner_nft_account: account @mut,
    fee_collector_account: account @mut,
    royalty_recipient: account @mut,
    escrow_vault: account @mut,
    seller: account @signer,
    token_program: account,
    royalty_bps: u64
) {
    require(!auction.is_settled);
    require(auction.seller == seller.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    require(now >= auction.end_time);

    if (auction.highest_bid > 0) {
        // Auction had bids -- transfer NFT to winner, payment to seller
        let price: u64 = auction.highest_bid;

        let marketplace_fee: u64 = calculate_fee(price, marketplace.fee_bps);
        let mut royalty_amount: u64 = 0;
        if (marketplace.royalty_policy == 0) {
            royalty_amount = calculate_royalty(price, royalty_bps);
        } else if (marketplace.royalty_policy == 1) {
            royalty_amount = calculate_royalty(price, royalty_bps);
        }

        let seller_proceeds: u64 = price - marketplace_fee - royalty_amount;
        require(seller_proceeds > 0);

        // Payment splits from escrow
        spl_token::SPLToken::transfer(escrow_vault, seller_payment, seller, seller_proceeds);
        spl_token::SPLToken::transfer(escrow_vault, fee_collector_account, seller, marketplace_fee);
        if (royalty_amount > 0) {
            spl_token::SPLToken::transfer(escrow_vault, royalty_recipient, seller, royalty_amount);
        }

        // NFT to winner
        spl_token::SPLToken::transfer(escrow_vault, winner_nft_account, seller, 1);

        marketplace.total_volume = marketplace.total_volume + price;
        marketplace.total_sales = marketplace.total_sales + 1;
    } else {
        // No bids -- return NFT to seller
        spl_token::SPLToken::transfer(escrow_vault, seller_payment, seller, 1);
    }

    auction.is_settled = true;
}

// ---------------------------------------------------------------------------
// Launchpad -- collection mint events
// ---------------------------------------------------------------------------

// Create a launchpad for a new collection mint
pub create_launchpad(
    marketplace: Marketplace,
    launchpad: Launchpad @mut @init(payer=authority, space=512) @signer,
    authority: account @mut @signer,
    collection_mint: pubkey,
    price: u64,
    max_supply: u64,
    whitelist_start: u64,
    public_start: u64,
    end_time: u64
) {
    require(marketplace.is_active);
    require(price > 0);
    require(max_supply > 0);
    require(whitelist_start < public_start);
    require(public_start < end_time);

    launchpad.marketplace = marketplace.ctx.key;
    launchpad.collection_mint = collection_mint;
    launchpad.price = price;
    launchpad.max_supply = max_supply;
    launchpad.minted = 0;
    launchpad.whitelist_start = whitelist_start;
    launchpad.public_start = public_start;
    launchpad.end_time = end_time;
    launchpad.authority = authority.ctx.key;
}

// Mint an NFT during a launchpad event
pub mint_from_launchpad(
    marketplace: Marketplace @mut,
    launchpad: Launchpad @mut,
    minter: account @mut @signer,
    minter_payment: account @mut,
    fee_collector_account: account @mut,
    creator_payment: account @mut,
    nft_mint: account @mut,
    minter_nft_account: account @mut,
    token_program: account
) {
    require(marketplace.is_active);
    require(launchpad.minted < launchpad.max_supply);

    let now: u64 = get_clock().unix_timestamp;
    require(now >= launchpad.whitelist_start);
    require(now <= launchpad.end_time);

    // After whitelist_start but before public_start = whitelist phase
    // Whitelist verification would be checked off-chain / via merkle proof account
    // After public_start = open to all

    let price: u64 = launchpad.price;
    let marketplace_fee: u64 = calculate_fee(price, marketplace.fee_bps);
    let creator_proceeds: u64 = price - marketplace_fee;
    require(creator_proceeds > 0);

    // Payment: fee to marketplace, remainder to creator
    spl_token::SPLToken::transfer(minter_payment, fee_collector_account, minter, marketplace_fee);
    spl_token::SPLToken::transfer(minter_payment, creator_payment, minter, creator_proceeds);

    // Mint NFT to buyer (actual mint via spl_token::mint_to)
    spl_token::SPLToken::mint_to(nft_mint, minter_nft_account, minter, 1);

    launchpad.minted = launchpad.minted + 1;

    marketplace.total_volume = marketplace.total_volume + price;
    marketplace.total_sales = marketplace.total_sales + 1;
}

// ---------------------------------------------------------------------------
// Collection offers
// ---------------------------------------------------------------------------

// Create an offer on any NFT in a collection (floor bid)
pub create_collection_offer(
    marketplace: Marketplace,
    col_offer: CollectionOffer @mut @init(payer=buyer, space=512) @signer,
    buyer: account @mut @signer,
    buyer_payment: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    collection_mint: pubkey,
    price: u64,
    quantity: u64
) {
    require(marketplace.is_active);
    require(price > 0);
    require(quantity > 0);

    // Escrow total payment: price * quantity
    let total_escrow: u64 = price * quantity;
    spl_token::SPLToken::transfer(buyer_payment, escrow_vault, buyer, total_escrow);

    col_offer.marketplace = marketplace.ctx.key;
    col_offer.buyer = buyer.ctx.key;
    col_offer.collection_mint = collection_mint;
    col_offer.price = price;
    col_offer.quantity = quantity;
    col_offer.filled = 0;
    col_offer.escrow_vault = escrow_vault.ctx.key;
}

// Cancel a collection offer and reclaim remaining escrowed funds
pub cancel_collection_offer(
    col_offer: CollectionOffer @mut,
    buyer: account @signer,
    buyer_payment: account @mut,
    escrow_vault: account @mut,
    token_program: account
) {
    require(col_offer.buyer == buyer.ctx.key);
    require(col_offer.filled < col_offer.quantity);
    require(escrow_vault.ctx.key == col_offer.escrow_vault);

    let remaining_quantity: u64 = col_offer.quantity - col_offer.filled;
    let refund_amount: u64 = remaining_quantity * col_offer.price;

    spl_token::SPLToken::transfer(escrow_vault, buyer_payment, buyer, refund_amount);

    // Mark fully filled to deactivate
    col_offer.filled = col_offer.quantity;
}

// Seller accepts a collection offer -- sells their NFT from that collection
pub accept_collection_offer(
    marketplace: Marketplace @mut,
    col_offer: CollectionOffer @mut,
    seller: account @signer,
    seller_nft_account: account @mut,
    seller_payment: account @mut,
    buyer_nft_account: account @mut,
    fee_collector_account: account @mut,
    royalty_recipient: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    royalty_bps: u64
) {
    require(marketplace.is_active);
    require(col_offer.filled < col_offer.quantity);
    require(escrow_vault.ctx.key == col_offer.escrow_vault);

    let price: u64 = col_offer.price;

    let marketplace_fee: u64 = calculate_fee(price, marketplace.fee_bps);
    let mut royalty_amount: u64 = 0;
    if (marketplace.royalty_policy == 0) {
        royalty_amount = calculate_royalty(price, royalty_bps);
    } else if (marketplace.royalty_policy == 1) {
        royalty_amount = calculate_royalty(price, royalty_bps);
    }

    let seller_proceeds: u64 = price - marketplace_fee - royalty_amount;
    require(seller_proceeds > 0);

    // Payment from escrow to seller
    spl_token::SPLToken::transfer(escrow_vault, seller_payment, seller, seller_proceeds);
    spl_token::SPLToken::transfer(escrow_vault, fee_collector_account, seller, marketplace_fee);
    if (royalty_amount > 0) {
        spl_token::SPLToken::transfer(escrow_vault, royalty_recipient, seller, royalty_amount);
    }

    // NFT from seller to buyer
    spl_token::SPLToken::transfer(seller_nft_account, buyer_nft_account, seller, 1);

    col_offer.filled = col_offer.filled + 1;

    marketplace.total_volume = marketplace.total_volume + price;
    marketplace.total_sales = marketplace.total_sales + 1;
}

// ---------------------------------------------------------------------------
// Marketplace admin
// ---------------------------------------------------------------------------

// Set the royalty enforcement policy
pub set_royalty_policy(
    marketplace: Marketplace @mut,
    authority: account @signer,
    new_policy: u8
) {
    require(marketplace.authority == authority.ctx.key);
    require(new_policy <= 2);  // 0=enforce, 1=optional, 2=ignore

    marketplace.royalty_policy = new_policy;
}

// Update marketplace fee
pub set_marketplace_fee(
    marketplace: Marketplace @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(marketplace.authority == authority.ctx.key);
    require(new_fee_bps <= 1000);  // max 10%

    marketplace.fee_bps = new_fee_bps;
}

// Collect marketplace fees from the fee collector account
pub collect_marketplace_fees(
    marketplace: Marketplace,
    authority: account @signer,
    fee_vault: account @mut,
    recipient: account @mut,
    token_program: account,
    amount: u64
) {
    require(marketplace.authority == authority.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(fee_vault, recipient, authority, amount);
}

// Distribute royalties to creator (manual distribution from accumulated royalties)
pub distribute_royalties(
    marketplace: Marketplace,
    authority: account @signer,
    royalty_vault: account @mut,
    creator_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(marketplace.authority == authority.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(royalty_vault, creator_account, authority, amount);
}

// Transfer marketplace authority
pub set_authority(
    marketplace: Marketplace @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(marketplace.authority == authority.ctx.key);

    marketplace.authority = new_authority;
}
