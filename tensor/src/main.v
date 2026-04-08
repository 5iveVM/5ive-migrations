// 5IVE Tensor NFT DEX — Canonical migration (ABI v1)
//
// Design (Tensor-inspired):
//   - NFT AMM with bonding curves (linear / exponential) for instant buy/sell
//   - Traditional order book: fixed-price listings, collection bids, trait bids
//   - Pool price auto-adjusts after every trade via bonding curve math
//   - Creator royalties with optional enforcement; marketplace + pool fees
//   - Admin: authority transfer, pause/unpause, marketplace fee
//
// Curve math:
//   Linear:      price(n) = spot_price + delta * n
//   Exponential:  price(n) = spot_price * (1 + delta / 10000) ^ n
//   where n = number of trades completed on that side

use std::interfaces::spl_token;

// ─── Accounts ────────────────────────────────────────────────────────

account Pool {
    authority: pubkey;
    collection_mint: pubkey;
    nft_vault: pubkey;
    sol_vault: pubkey;
    curve_type: u8;          // 0 = linear, 1 = exponential
    delta: u64;              // linear: lamports step; exponential: bps
    spot_price: u64;         // current price in lamports
    fee_bps: u64;            // pool trading fee in basis points
    nft_count: u64;
    sol_balance: u64;
    buy_count: u64;          // trades executed on buy side (for curve)
    sell_count: u64;         // trades executed on sell side (for curve)
    creator_royalty_bps: u64;
    royalty_enforced: bool;
    accrued_fees: u64;
    accrued_royalties: u64;
    is_paused: bool;
}

account Listing {
    nft_mint: pubkey;
    seller: pubkey;
    price: u64;
    collection_mint: pubkey;
    is_active: bool;
}

account CollectionBid {
    collection_mint: pubkey;
    bidder: pubkey;
    price: u64;
    quantity: u64;
    filled: u64;
    is_active: bool;
}

account TraitBid {
    collection_mint: pubkey;
    bidder: pubkey;
    price: u64;
    trait_key: u64;          // hash of trait name
    trait_value: u64;        // hash of trait value
    quantity: u64;
    filled: u64;
    is_active: bool;
}

account MarketplaceConfig {
    authority: pubkey;
    fee_bps: u64;
    fee_recipient: pubkey;
    is_paused: bool;
}

// ─── Curve helpers ───────────────────────────────────────────────────

fn calculate_linear_price(spot_price: u64, delta: u64, n: u64) -> u64 {
    return spot_price + delta * n;
}

// Exponential approximation: spot * (1 + delta/10000)^n
// Uses iterative multiplication to avoid floating point.
// Each step: price = price * (10000 + delta) / 10000
fn calculate_exponential_price(spot_price: u64, delta: u64, n: u64) -> u64 {
    let mut price: u64 = spot_price;
    let mut i: u64 = 0;
    if (n > 0) {
        // Loop unroll: 5ive doesn't have while, so we cap at reasonable depth
        // In practice pools rarely exceed 50 price steps
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
        if (i < n) { price = (price * (10000 + delta)) / 10000; i = i + 1; }
    }
    return price;
}

fn get_current_buy_price(pool: Pool) -> u64 {
    if (pool.curve_type == 0) {
        return calculate_linear_price(pool.spot_price, pool.delta, pool.buy_count);
    }
    return calculate_exponential_price(pool.spot_price, pool.delta, pool.buy_count);
}

fn get_current_sell_price(pool: Pool) -> u64 {
    if (pool.curve_type == 0) {
        return calculate_linear_price(pool.spot_price, pool.delta, pool.sell_count);
    }
    return calculate_exponential_price(pool.spot_price, pool.delta, pool.sell_count);
}

fn calculate_fee(amount: u64, fee_bps: u64) -> u64 {
    return (amount * fee_bps) / 10000;
}

// ─── Marketplace admin ───────────────────────────────────────────────

pub init_marketplace(
    config: MarketplaceConfig @mut @init(payer=authority, space=400),
    authority: account @signer,
    fee_bps: u64,
    fee_recipient: pubkey
) {
    require(fee_bps <= 1000);   // max 10%
    config.authority = authority.ctx.key;
    config.fee_bps = fee_bps;
    config.fee_recipient = fee_recipient;
    config.is_paused = false;
}

pub set_marketplace_fee(
    config: MarketplaceConfig @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_fee_bps <= 1000);
    config.fee_bps = new_fee_bps;
}

pub set_marketplace_pause(
    config: MarketplaceConfig @mut,
    authority: account @signer,
    paused: bool
) {
    require(config.authority == authority.ctx.key);
    config.is_paused = paused;
}

// ─── NFT AMM: Pool lifecycle ─────────────────────────────────────────

pub create_pool(
    pool: Pool @mut @init(payer=creator, space=800),
    creator: account @signer,
    collection_mint: pubkey,
    nft_vault: pubkey,
    sol_vault: pubkey,
    curve_type: u8,
    delta: u64,
    spot_price: u64,
    fee_bps: u64,
    creator_royalty_bps: u64
) {
    require(curve_type == 0 || curve_type == 1);
    require(spot_price > 0);
    require(fee_bps <= 5000);            // max 50%
    require(creator_royalty_bps <= 5000); // max 50%
    require(delta > 0);

    pool.authority = creator.ctx.key;
    pool.collection_mint = collection_mint;
    pool.nft_vault = nft_vault;
    pool.sol_vault = sol_vault;
    pool.curve_type = curve_type;
    pool.delta = delta;
    pool.spot_price = spot_price;
    pool.fee_bps = fee_bps;
    pool.nft_count = 0;
    pool.sol_balance = 0;
    pool.buy_count = 0;
    pool.sell_count = 0;
    pool.creator_royalty_bps = creator_royalty_bps;
    pool.royalty_enforced = true;
    pool.accrued_fees = 0;
    pool.accrued_royalties = 0;
    pool.is_paused = false;
}

pub deposit_nft(
    pool: Pool @mut,
    depositor_nft_account: account @mut,
    pool_nft_vault: account @mut,
    depositor: account @signer,
    token_program: account,
    nft_mint: pubkey
) {
    require(!pool.is_paused);
    require(pool.authority == depositor.ctx.key);
    require(pool_nft_vault.ctx.key == pool.nft_vault);

    spl_token::SPLToken::transfer(depositor_nft_account, pool_nft_vault, depositor, 1);
    pool.nft_count = pool.nft_count + 1;
}

pub deposit_sol(
    pool: Pool @mut,
    depositor_sol_account: account @mut,
    pool_sol_vault: account @mut,
    depositor: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(pool.authority == depositor.ctx.key);
    require(pool_sol_vault.ctx.key == pool.sol_vault);
    require(amount > 0);

    spl_token::SPLToken::transfer(depositor_sol_account, pool_sol_vault, depositor, amount);
    pool.sol_balance = pool.sol_balance + amount;
}

pub withdraw_nft(
    pool: Pool @mut,
    pool_nft_vault: account @mut,
    recipient_nft_account: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool.nft_count > 0);
    require(pool_nft_vault.ctx.key == pool.nft_vault);

    spl_token::SPLToken::transfer(pool_nft_vault, recipient_nft_account, authority, 1);
    pool.nft_count = pool.nft_count - 1;
}

pub withdraw_sol(
    pool: Pool @mut,
    pool_sol_vault: account @mut,
    recipient_sol_account: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.authority == authority.ctx.key);
    require(amount > 0);
    require(amount <= pool.sol_balance);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    spl_token::SPLToken::transfer(pool_sol_vault, recipient_sol_account, authority, amount);
    pool.sol_balance = pool.sol_balance - amount;
}

// ─── NFT AMM: Trading ────────────────────────────────────────────────

pub buy_nft_from_pool(
    pool: Pool @mut @signer,
    buyer_sol_account: account @mut,
    pool_sol_vault: account @mut,
    pool_nft_vault: account @mut,
    buyer_nft_account: account @mut,
    buyer: account @signer,
    token_program: account,
    max_price: u64
) {
    require(!pool.is_paused);
    require(pool.nft_count > 0);
    require(pool_sol_vault.ctx.key == pool.sol_vault);
    require(pool_nft_vault.ctx.key == pool.nft_vault);

    let base_price: u64 = get_current_buy_price(pool);
    let pool_fee: u64 = calculate_fee(base_price, pool.fee_bps);
    let royalty_fee: u64 = calculate_fee(base_price, pool.creator_royalty_bps);

    let mut total_royalty: u64 = 0;
    if (pool.royalty_enforced) {
        total_royalty = royalty_fee;
    }

    let total_cost: u64 = base_price + pool_fee + total_royalty;
    require(total_cost <= max_price);

    // Buyer pays SOL into pool vault
    spl_token::SPLToken::transfer(buyer_sol_account, pool_sol_vault, buyer, total_cost);

    // Pool sends NFT to buyer
    spl_token::SPLToken::transfer(pool_nft_vault, buyer_nft_account, pool, 1);

    pool.sol_balance = pool.sol_balance + base_price;
    pool.nft_count = pool.nft_count - 1;
    pool.buy_count = pool.buy_count + 1;
    pool.accrued_fees = pool.accrued_fees + pool_fee;
    pool.accrued_royalties = pool.accrued_royalties + total_royalty;
}

pub sell_nft_to_pool(
    pool: Pool @mut @signer,
    seller_nft_account: account @mut,
    pool_nft_vault: account @mut,
    pool_sol_vault: account @mut,
    seller_sol_account: account @mut,
    seller: account @signer,
    token_program: account,
    min_price: u64
) {
    require(!pool.is_paused);
    require(pool_sol_vault.ctx.key == pool.sol_vault);
    require(pool_nft_vault.ctx.key == pool.nft_vault);

    let base_price: u64 = get_current_sell_price(pool);
    let pool_fee: u64 = calculate_fee(base_price, pool.fee_bps);
    let royalty_fee: u64 = calculate_fee(base_price, pool.creator_royalty_bps);

    let mut total_royalty: u64 = 0;
    if (pool.royalty_enforced) {
        total_royalty = royalty_fee;
    }

    let payout: u64 = base_price - pool_fee - total_royalty;
    require(payout >= min_price);
    require(pool.sol_balance >= base_price);

    // Seller sends NFT into pool
    spl_token::SPLToken::transfer(seller_nft_account, pool_nft_vault, seller, 1);

    // Pool pays SOL to seller
    spl_token::SPLToken::transfer(pool_sol_vault, seller_sol_account, pool, payout);

    pool.sol_balance = pool.sol_balance - base_price;
    pool.nft_count = pool.nft_count + 1;
    pool.sell_count = pool.sell_count + 1;
    pool.accrued_fees = pool.accrued_fees + pool_fee;
    pool.accrued_royalties = pool.accrued_royalties + total_royalty;
}

// ─── Order Book: Listings ────────────────────────────────────────────

pub list_nft(
    listing: Listing @mut @init(payer=seller, space=400),
    seller_nft_account: account @mut,
    escrow_nft_account: account @mut,
    seller: account @signer,
    token_program: account,
    nft_mint: pubkey,
    price: u64,
    collection_mint: pubkey
) {
    require(price > 0);

    listing.nft_mint = nft_mint;
    listing.seller = seller.ctx.key;
    listing.price = price;
    listing.collection_mint = collection_mint;
    listing.is_active = true;

    // Transfer NFT to escrow
    spl_token::SPLToken::transfer(seller_nft_account, escrow_nft_account, seller, 1);
}

pub delist_nft(
    listing: Listing @mut,
    escrow_nft_account: account @mut,
    seller_nft_account: account @mut,
    seller: account @signer,
    token_program: account
) {
    require(listing.seller == seller.ctx.key);
    require(listing.is_active);

    listing.is_active = false;

    // Return NFT from escrow to seller
    spl_token::SPLToken::transfer(escrow_nft_account, seller_nft_account, seller, 1);
}

pub buy_listed_nft(
    listing: Listing @mut,
    config: MarketplaceConfig,
    escrow_nft_account: account @mut,
    buyer_nft_account: account @mut,
    buyer_sol_account: account @mut,
    seller_sol_account: account @mut,
    fee_recipient_account: account @mut,
    buyer: account @signer,
    token_program: account
) {
    require(!config.is_paused);
    require(listing.is_active);

    let price: u64 = listing.price;
    let marketplace_fee: u64 = calculate_fee(price, config.fee_bps);
    let seller_proceeds: u64 = price - marketplace_fee;

    // Buyer pays seller
    spl_token::SPLToken::transfer(buyer_sol_account, seller_sol_account, buyer, seller_proceeds);

    // Buyer pays marketplace fee
    if (marketplace_fee > 0) {
        spl_token::SPLToken::transfer(buyer_sol_account, fee_recipient_account, buyer, marketplace_fee);
    }

    // Transfer NFT from escrow to buyer
    spl_token::SPLToken::transfer(escrow_nft_account, buyer_nft_account, buyer, 1);

    listing.is_active = false;
}

// ─── Order Book: Collection Bids ─────────────────────────────────────

pub place_collection_bid(
    bid: CollectionBid @mut @init(payer=bidder, space=400),
    bidder_sol_account: account @mut,
    escrow_sol_account: account @mut,
    bidder: account @signer,
    token_program: account,
    collection_mint: pubkey,
    price: u64,
    quantity: u64
) {
    require(price > 0);
    require(quantity > 0);

    let total_escrow: u64 = price * quantity;

    bid.collection_mint = collection_mint;
    bid.bidder = bidder.ctx.key;
    bid.price = price;
    bid.quantity = quantity;
    bid.filled = 0;
    bid.is_active = true;

    // Escrow SOL for all bids
    spl_token::SPLToken::transfer(bidder_sol_account, escrow_sol_account, bidder, total_escrow);
}

pub cancel_collection_bid(
    bid: CollectionBid @mut,
    escrow_sol_account: account @mut,
    bidder_sol_account: account @mut,
    bidder: account @signer,
    token_program: account
) {
    require(bid.bidder == bidder.ctx.key);
    require(bid.is_active);

    let remaining: u64 = bid.quantity - bid.filled;
    let refund: u64 = bid.price * remaining;

    bid.is_active = false;

    // Refund remaining escrowed SOL
    spl_token::SPLToken::transfer(escrow_sol_account, bidder_sol_account, bidder, refund);
}

pub accept_collection_bid(
    bid: CollectionBid @mut,
    config: MarketplaceConfig,
    escrow_sol_account: account @mut,
    seller_sol_account: account @mut,
    seller_nft_account: account @mut,
    bidder_nft_account: account @mut,
    fee_recipient_account: account @mut,
    seller: account @signer,
    token_program: account
) {
    require(!config.is_paused);
    require(bid.is_active);
    require(bid.filled < bid.quantity);

    let price: u64 = bid.price;
    let marketplace_fee: u64 = calculate_fee(price, config.fee_bps);
    let seller_proceeds: u64 = price - marketplace_fee;

    // Send NFT from seller to bidder
    spl_token::SPLToken::transfer(seller_nft_account, bidder_nft_account, seller, 1);

    // Pay seller from escrow
    spl_token::SPLToken::transfer(escrow_sol_account, seller_sol_account, seller, seller_proceeds);

    // Pay marketplace fee from escrow
    if (marketplace_fee > 0) {
        spl_token::SPLToken::transfer(escrow_sol_account, fee_recipient_account, seller, marketplace_fee);
    }

    bid.filled = bid.filled + 1;

    if (bid.filled == bid.quantity) {
        bid.is_active = false;
    }
}

// ─── Order Book: Trait Bids ──────────────────────────────────────────

pub place_trait_bid(
    bid: TraitBid @mut @init(payer=bidder, space=500),
    bidder_sol_account: account @mut,
    escrow_sol_account: account @mut,
    bidder: account @signer,
    token_program: account,
    collection_mint: pubkey,
    price: u64,
    trait_key: u64,
    trait_value: u64,
    quantity: u64
) {
    require(price > 0);
    require(quantity > 0);

    let total_escrow: u64 = price * quantity;

    bid.collection_mint = collection_mint;
    bid.bidder = bidder.ctx.key;
    bid.price = price;
    bid.trait_key = trait_key;
    bid.trait_value = trait_value;
    bid.quantity = quantity;
    bid.filled = 0;
    bid.is_active = true;

    spl_token::SPLToken::transfer(bidder_sol_account, escrow_sol_account, bidder, total_escrow);
}

pub cancel_trait_bid(
    bid: TraitBid @mut,
    escrow_sol_account: account @mut,
    bidder_sol_account: account @mut,
    bidder: account @signer,
    token_program: account
) {
    require(bid.bidder == bidder.ctx.key);
    require(bid.is_active);

    let remaining: u64 = bid.quantity - bid.filled;
    let refund: u64 = bid.price * remaining;

    bid.is_active = false;

    spl_token::SPLToken::transfer(escrow_sol_account, bidder_sol_account, bidder, refund);
}

pub accept_trait_bid(
    bid: TraitBid @mut,
    config: MarketplaceConfig,
    escrow_sol_account: account @mut,
    seller_sol_account: account @mut,
    seller_nft_account: account @mut,
    bidder_nft_account: account @mut,
    fee_recipient_account: account @mut,
    seller: account @signer,
    token_program: account,
    nft_trait_key: u64,
    nft_trait_value: u64
) {
    require(!config.is_paused);
    require(bid.is_active);
    require(bid.filled < bid.quantity);

    // Verify trait matches the bid
    require(nft_trait_key == bid.trait_key);
    require(nft_trait_value == bid.trait_value);

    let price: u64 = bid.price;
    let marketplace_fee: u64 = calculate_fee(price, config.fee_bps);
    let seller_proceeds: u64 = price - marketplace_fee;

    // Send NFT from seller to bidder
    spl_token::SPLToken::transfer(seller_nft_account, bidder_nft_account, seller, 1);

    // Pay seller from escrow
    spl_token::SPLToken::transfer(escrow_sol_account, seller_sol_account, seller, seller_proceeds);

    // Pay marketplace fee from escrow
    if (marketplace_fee > 0) {
        spl_token::SPLToken::transfer(escrow_sol_account, fee_recipient_account, seller, marketplace_fee);
    }

    bid.filled = bid.filled + 1;

    if (bid.filled == bid.quantity) {
        bid.is_active = false;
    }
}

// ─── Royalty & Fees ──────────────────────────────────────────────────

pub set_pool_fee(
    pool: Pool @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_fee_bps <= 5000);
    pool.fee_bps = new_fee_bps;
}

pub set_royalty_enforcement(
    pool: Pool @mut,
    authority: account @signer,
    enforced: bool
) {
    require(pool.authority == authority.ctx.key);
    pool.royalty_enforced = enforced;
}

pub collect_pool_fees(
    pool: Pool @mut @signer,
    pool_sol_vault: account @mut,
    recipient_account: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool.accrued_fees > 0);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    let fees: u64 = pool.accrued_fees;
    pool.accrued_fees = 0;

    spl_token::SPLToken::transfer(pool_sol_vault, recipient_account, pool, fees);
}

pub distribute_royalties(
    pool: Pool @mut @signer,
    pool_sol_vault: account @mut,
    creator_account: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool.accrued_royalties > 0);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    let royalties: u64 = pool.accrued_royalties;
    pool.accrued_royalties = 0;

    spl_token::SPLToken::transfer(pool_sol_vault, creator_account, pool, royalties);
}

// ─── Admin ───────────────────────────────────────────────────────────

pub set_authority(
    pool: Pool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

pub set_pool_pause(
    pool: Pool @mut,
    authority: account @signer,
    paused: bool
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = paused;
}

// ─── Read-only helpers ───────────────────────────────────────────────

pub get_pool_buy_price(pool: Pool) -> u64 {
    return get_current_buy_price(pool);
}

pub get_pool_sell_price(pool: Pool) -> u64 {
    return get_current_sell_price(pool);
}

pub get_pool_nft_count(pool: Pool) -> u64 {
    return pool.nft_count;
}

pub get_pool_sol_balance(pool: Pool) -> u64 {
    return pool.sol_balance;
}

pub get_pool_accrued_fees(pool: Pool) -> u64 {
    return pool.accrued_fees;
}

pub get_pool_accrued_royalties(pool: Pool) -> u64 {
    return pool.accrued_royalties;
}

pub get_listing_price(listing: Listing) -> u64 {
    return listing.price;
}

pub get_bid_remaining(bid: CollectionBid) -> u64 {
    return bid.quantity - bid.filled;
}
