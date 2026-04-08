// 5IVE Hadeswap Migration
//
// NFT AMM -- bonding curve pools for instant NFT buy/sell.
// Like Tensor/sudoswap but simpler. Each pool holds NFTs of a collection
// and SOL, with a bonding curve (linear or exponential) determining prices.
//
// Pool types: buy_only (0), sell_only (1), trade (2)
// Curve types: linear (0), exponential (1)
//
// Instructions (14):
//   create_pool, deposit_nft_to_pool, deposit_sol_to_pool, buy_nft, sell_nft,
//   withdraw_nft, withdraw_sol, modify_pool, close_pool, set_pool_type,
//   collect_fees, set_authority, pause, unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Pool {
    authority: pubkey;
    collection_mint: pubkey;
    pool_type: u8;
    curve_type: u8;
    spot_price: u64;
    delta: u64;
    fee_bps: u64;
    sol_balance: u64;
    nft_count: u64;
    total_volume: u64;
    accumulated_fees: u64;
    sol_vault: pubkey;
    is_active: bool;
}

account PoolNft {
    pool: pubkey;
    nft_mint: pubkey;
    nft_vault: pubkey;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// pool_type: 0 = buy_only (pool buys NFTs, holds SOL)
//            1 = sell_only (pool sells NFTs, holds NFTs)
//            2 = trade (pool both buys and sells, holds both)
// curve_type: 0 = linear (price changes by +/- delta each trade)
//             1 = exponential (price changes by */(1+delta/10000) each trade)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_buy_price(spot_price: u64, curve_type: u8, delta: u64) -> u64 {
    // Buy from pool = user pays spot_price + delta adjustment
    // For buying, price goes UP after purchase (demand drives price)
    return spot_price;
}

fn calculate_sell_price(spot_price: u64, curve_type: u8, delta: u64, fee_bps: u64) -> u64 {
    // Sell to pool = user receives spot_price minus fee
    let fee: u64 = (spot_price * fee_bps) / 10000;
    if (spot_price > fee) {
        return spot_price - fee;
    }
    return 0;
}

fn adjust_price_after_buy(spot_price: u64, curve_type: u8, delta: u64) -> u64 {
    if (curve_type == 0) {
        // Linear: increase by delta
        return spot_price + delta;
    }
    // Exponential: increase by delta bps (delta = basis points multiplier)
    return spot_price + (spot_price * delta) / 10000;
}

fn adjust_price_after_sell(spot_price: u64, curve_type: u8, delta: u64) -> u64 {
    if (curve_type == 0) {
        // Linear: decrease by delta
        if (spot_price > delta) {
            return spot_price - delta;
        }
        return 0;
    }
    // Exponential: decrease by delta bps
    let decrease: u64 = (spot_price * delta) / 10000;
    if (spot_price > decrease) {
        return spot_price - decrease;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Instructions -- Pool lifecycle
// ---------------------------------------------------------------------------

pub create_pool(
    pool: Pool @mut @init(payer=creator, space=512),
    creator: account @signer,
    collection_mint: pubkey,
    sol_vault: pubkey,
    pool_type: u8,
    curve_type: u8,
    spot_price: u64,
    delta: u64,
    fee_bps: u64
) {
    require(pool_type <= 2);
    require(curve_type <= 1);
    require(spot_price > 0);
    require(fee_bps <= 5000);

    pool.authority = creator.ctx.key;
    pool.collection_mint = collection_mint;
    pool.pool_type = pool_type;
    pool.curve_type = curve_type;
    pool.spot_price = spot_price;
    pool.delta = delta;
    pool.fee_bps = fee_bps;
    pool.sol_balance = 0;
    pool.nft_count = 0;
    pool.total_volume = 0;
    pool.accumulated_fees = 0;
    pool.sol_vault = sol_vault;
    pool.is_active = true;
}

// ---------------------------------------------------------------------------
// Instructions -- Deposit assets into pool
// ---------------------------------------------------------------------------

pub deposit_nft_to_pool(
    pool: Pool @mut,
    pool_nft: PoolNft @mut @init(payer=owner, space=256),
    owner: account @signer,
    nft_mint: pubkey,
    user_nft_account: account @mut,
    pool_nft_vault: account @mut,
    token_program: account
) {
    require(pool.is_active);
    require(pool.authority == owner.ctx.key);
    // Pool must accept NFTs (sell_only or trade)
    require(pool.pool_type == 1 | pool.pool_type == 2);

    // Transfer NFT (amount = 1 for NFTs)
    spl_token::SPLToken::transfer(user_nft_account, pool_nft_vault, owner, 1);

    pool_nft.pool = pool.ctx.key;
    pool_nft.nft_mint = nft_mint;
    pool_nft.nft_vault = pool_nft_vault.ctx.key;

    pool.nft_count = pool.nft_count + 1;
}

pub deposit_sol_to_pool(
    pool: Pool @mut,
    owner: account @signer,
    user_sol: account @mut,
    pool_sol_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(pool.is_active);
    require(pool.authority == owner.ctx.key);
    // Pool must accept SOL (buy_only or trade)
    require(pool.pool_type == 0 | pool.pool_type == 2);
    require(amount > 0);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    spl_token::SPLToken::transfer(user_sol, pool_sol_vault, owner, amount);
    pool.sol_balance = pool.sol_balance + amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Buy / Sell NFTs
// ---------------------------------------------------------------------------

pub buy_nft(
    pool: Pool @mut @signer,
    pool_nft: PoolNft @mut,
    buyer: account @signer,
    buyer_sol: account @mut,
    pool_sol_vault: account @mut,
    pool_nft_vault: account @mut,
    buyer_nft_account: account @mut,
    token_program: account,
    max_price: u64
) {
    require(pool.is_active);
    require(pool.nft_count > 0);
    // Pool must sell NFTs (sell_only or trade)
    require(pool.pool_type == 1 | pool.pool_type == 2);
    require(pool_nft.pool == pool.ctx.key);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    // Calculate price buyer must pay
    let price: u64 = pool.spot_price;
    let fee: u64 = (price * pool.fee_bps) / 10000;
    let total_cost: u64 = price + fee;
    require(total_cost <= max_price);

    // Buyer pays SOL
    spl_token::SPLToken::transfer(buyer_sol, pool_sol_vault, buyer, total_cost);

    // Pool transfers NFT to buyer
    spl_token::SPLToken::transfer(pool_nft_vault, buyer_nft_account, pool, 1);

    // Update pool state
    pool.sol_balance = pool.sol_balance + price;
    pool.accumulated_fees = pool.accumulated_fees + fee;
    pool.nft_count = pool.nft_count - 1;
    pool.total_volume = pool.total_volume + price;

    // Adjust spot price upward after buy (fewer NFTs = higher price)
    pool.spot_price = adjust_price_after_buy(pool.spot_price, pool.curve_type, pool.delta);
}

pub sell_nft(
    pool: Pool @mut @signer,
    pool_nft: PoolNft @mut @init(payer=seller, space=256),
    seller: account @signer,
    seller_nft_account: account @mut,
    pool_nft_vault: account @mut,
    pool_sol_vault: account @mut,
    seller_sol: account @mut,
    nft_mint: pubkey,
    token_program: account,
    min_price: u64
) {
    require(pool.is_active);
    // Pool must buy NFTs (buy_only or trade)
    require(pool.pool_type == 0 | pool.pool_type == 2);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    // Calculate price pool pays to seller (minus fee)
    let sell_price: u64 = calculate_sell_price(pool.spot_price, pool.curve_type, pool.delta, pool.fee_bps);
    require(sell_price > 0);
    require(sell_price >= min_price);
    require(sell_price <= pool.sol_balance);

    // Seller transfers NFT to pool
    spl_token::SPLToken::transfer(seller_nft_account, pool_nft_vault, seller, 1);

    // Pool pays seller in SOL
    spl_token::SPLToken::transfer(pool_sol_vault, seller_sol, pool, sell_price);

    // Track NFT in pool
    pool_nft.pool = pool.ctx.key;
    pool_nft.nft_mint = nft_mint;
    pool_nft.nft_vault = pool_nft_vault.ctx.key;

    // Update pool state
    let fee: u64 = pool.spot_price - sell_price;
    pool.sol_balance = pool.sol_balance - sell_price;
    pool.accumulated_fees = pool.accumulated_fees + fee;
    pool.nft_count = pool.nft_count + 1;
    pool.total_volume = pool.total_volume + pool.spot_price;

    // Adjust spot price downward after sell (more NFTs = lower price)
    pool.spot_price = adjust_price_after_sell(pool.spot_price, pool.curve_type, pool.delta);
}

// ---------------------------------------------------------------------------
// Instructions -- Withdraw assets from pool
// ---------------------------------------------------------------------------

pub withdraw_nft(
    pool: Pool @mut @signer,
    pool_nft: PoolNft @mut,
    owner: account @signer,
    pool_nft_vault: account @mut,
    user_nft_account: account @mut,
    token_program: account
) {
    require(pool.authority == owner.ctx.key);
    require(pool_nft.pool == pool.ctx.key);
    require(pool.nft_count > 0);

    spl_token::SPLToken::transfer(pool_nft_vault, user_nft_account, pool, 1);
    pool.nft_count = pool.nft_count - 1;
}

pub withdraw_sol(
    pool: Pool @mut @signer,
    owner: account @signer,
    pool_sol_vault: account @mut,
    user_sol: account @mut,
    token_program: account,
    amount: u64
) {
    require(pool.authority == owner.ctx.key);
    require(amount > 0);
    require(amount <= pool.sol_balance);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    spl_token::SPLToken::transfer(pool_sol_vault, user_sol, pool, amount);
    pool.sol_balance = pool.sol_balance - amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Pool modification
// ---------------------------------------------------------------------------

pub modify_pool(
    pool: Pool @mut,
    authority: account @signer,
    new_delta: u64,
    new_fee_bps: u64,
    new_spot_price: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_spot_price > 0);
    require(new_fee_bps <= 5000);

    pool.delta = new_delta;
    pool.fee_bps = new_fee_bps;
    pool.spot_price = new_spot_price;
}

pub set_pool_type(
    pool: Pool @mut,
    authority: account @signer,
    new_pool_type: u8
) {
    require(pool.authority == authority.ctx.key);
    require(new_pool_type <= 2);
    pool.pool_type = new_pool_type;
}

pub close_pool(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(pool.nft_count == 0);
    require(pool.sol_balance == 0);

    pool.is_active = false;
}

// ---------------------------------------------------------------------------
// Instructions -- Admin
// ---------------------------------------------------------------------------

pub collect_fees(
    pool: Pool @mut @signer,
    authority: account @signer,
    pool_sol_vault: account @mut,
    fee_recipient: account @mut,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool.accumulated_fees > 0);
    require(pool_sol_vault.ctx.key == pool.sol_vault);

    let fees: u64 = pool.accumulated_fees;
    pool.accumulated_fees = 0;

    spl_token::SPLToken::transfer(pool_sol_vault, fee_recipient, pool, fees);
    pool.sol_balance = pool.sol_balance - fees;
}

pub set_authority(
    pool: Pool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

pub pause(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_active = false;
}

pub unpause(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_active = true;
}
