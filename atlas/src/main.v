// Atlas Protocol DEX — 5ive DSL Migration
//
// Hybrid DEX: weighted AMM pools + on-chain order book + cross-margin + yield vaults.
// Designed for professional traders needing deep liquidity and advanced order types.
//
// Architecture:
//   - Weighted constant product pools (Balancer-style: x^w_a * y^w_b = k)
//   - Central limit order book with limit, stop, and TWAP orders
//   - Unified cross-margin account across all markets
//   - Auto-compounding yield vaults for idle margin deposits
//   - Protocol fee collection on swaps, trades, and vault yield

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account WeightedPool {
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;
    reserve_a: u64;
    reserve_b: u64;
    weight_a: u16;
    weight_b: u16;
    lp_supply: u64;
    swap_fee_bps: u64;
    protocol_fee_bps: u64;
    protocol_fees_a: u64;
    protocol_fees_b: u64;
    authority: pubkey;
    is_paused: bool;
}

account OrderBookMarket {
    base_mint: pubkey;
    quote_mint: pubkey;
    base_vault: pubkey;
    quote_vault: pubkey;
    tick_size: u64;
    min_order_size: u64;
    maker_fee_bps: u64;
    taker_fee_bps: u64;
    total_volume: u128;
    authority: pubkey;
    is_active: bool;
}

account Order {
    market: pubkey;
    owner: pubkey;
    side: u8;
    order_type: u8;
    price: u64;
    size: u64;
    filled: u64;
    trigger_price: u64;
    twap_interval: u64;
    twap_remaining_chunks: u64;
    twap_last_executed: u64;
    order_id: u64;
    is_active: bool;
}

account MarginAccount {
    owner: pubkey;
    total_collateral_value: u64;
    total_liabilities: u64;
    deposit_1_mint: pubkey;
    deposit_1_amount: u64;
    deposit_2_mint: pubkey;
    deposit_2_amount: u64;
    deposit_3_mint: pubkey;
    deposit_3_amount: u64;
    deposit_4_mint: pubkey;
    deposit_4_amount: u64;
    position_1_market: pubkey;
    position_1_size: i64;
    position_1_entry_price: u64;
    position_2_market: pubkey;
    position_2_size: i64;
    position_2_entry_price: u64;
}

account YieldVault {
    underlying_mint: pubkey;
    vault_shares_mint: pubkey;
    underlying_vault: pubkey;
    total_deposited: u64;
    total_shares: u64;
    accumulated_yield: u64;
    last_compound: u64;
    strategy_type: u8;
    apy_estimate_bps: u64;
    authority: pubkey;
}

account GlobalConfig {
    authority: pubkey;
    next_order_id: u64;
    maintenance_ratio_bps: u64;
    is_global_pause: bool;
}

// ---------------------------------------------------------------------------
// Internal Helpers
// ---------------------------------------------------------------------------

fn compute_weighted_swap(
    reserve_in: u64,
    reserve_out: u64,
    amount_in: u64,
    weight_in: u64,
    weight_out: u64
) -> u64 {
    // Linearised weighted constant product:
    // amount_out = reserve_out * amount_in * weight_in / ((reserve_in + amount_in) * weight_out)
    let numerator: u64 = reserve_out * amount_in * weight_in;
    let denominator: u64 = (reserve_in + amount_in) * weight_out;
    require(denominator > 0);
    return numerator / denominator;
}

fn compute_imbalance_fee(amount: u64, fee_bps: u64) -> u64 {
    // Extra fee for single-sided liquidity to compensate for pool imbalance
    return (amount * fee_bps) / 10000;
}

fn compute_margin_health(collateral: u64, liabilities: u64) -> u64 {
    // health = collateral * 10000 / liabilities (bps representation)
    if (liabilities == 0) {
        return 100000;
    }
    return (collateral * 10000) / liabilities;
}

fn compute_vault_shares(amount: u64, total_shares: u64, total_deposited: u64) -> u64 {
    if (total_shares == 0) {
        return amount;
    }
    return (amount * total_shares) / total_deposited;
}

fn compute_vault_withdraw_amount(shares: u64, total_shares: u64, total_deposited: u64) -> u64 {
    require(total_shares > 0);
    return (shares * total_deposited) / total_shares;
}

// ---------------------------------------------------------------------------
// AMM Pool Instructions
// ---------------------------------------------------------------------------

// 1. create_weighted_pool — Create a pool with configurable token weights
pub create_weighted_pool(
    pool: WeightedPool @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    config: GlobalConfig,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint: pubkey,
    weight_a: u16,
    weight_b: u16,
    swap_fee_bps: u64,
    protocol_fee_bps: u64
) {
    require(!config.is_global_pause);
    require(weight_a > 0);
    require(weight_b > 0);
    require(weight_a + weight_b == 10000);
    require(swap_fee_bps <= 1000);
    require(protocol_fee_bps <= swap_fee_bps);

    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.lp_mint = lp_mint;
    pool.reserve_a = 0;
    pool.reserve_b = 0;
    pool.weight_a = weight_a;
    pool.weight_b = weight_b;
    pool.lp_supply = 0;
    pool.swap_fee_bps = swap_fee_bps;
    pool.protocol_fee_bps = protocol_fee_bps;
    pool.protocol_fees_a = 0;
    pool.protocol_fees_b = 0;
    pool.authority = creator.ctx.key;
    pool.is_paused = false;
}

// 2. add_liquidity — Deposit tokens proportionally to weights, receive LP tokens
pub add_liquidity(
    pool: WeightedPool @mut @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64,
    min_lp_out: u64
) {
    require(!pool.is_paused);
    require(amount_a > 0);
    require(amount_b > 0);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    let mut lp_to_mint: u64 = 0;

    if (pool.lp_supply == 0) {
        // Bootstrap: initial liquidity
        lp_to_mint = amount_a + amount_b;
    } else {
        // Proportional deposit: LP minted based on the smaller ratio
        let lp_from_a: u64 = (amount_a * pool.lp_supply) / pool.reserve_a;
        let lp_from_b: u64 = (amount_b * pool.lp_supply) / pool.reserve_b;
        if (lp_from_a < lp_from_b) {
            lp_to_mint = lp_from_a;
        } else {
            lp_to_mint = lp_from_b;
        }
    }

    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_out);

    spl_token::SPLToken::transfer(user_token_a, pool_token_a_vault, user_authority, amount_a);
    spl_token::SPLToken::transfer(user_token_b, pool_token_b_vault, user_authority, amount_b);
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    pool.reserve_a = pool.reserve_a + amount_a;
    pool.reserve_b = pool.reserve_b + amount_b;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

// 3. add_single_sided_liquidity — Deposit only one token (with imbalance fee)
pub add_single_sided_liquidity(
    pool: WeightedPool @mut @signer,
    user_token: account @mut,
    pool_vault: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64,
    min_lp_out: u64,
    is_token_a: bool
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(pool.lp_supply > 0);

    let mut reserve: u64 = 0;
    let mut weight: u64 = 0;

    if (is_token_a) {
        require(pool_vault.ctx.key == pool.token_a_vault);
        reserve = pool.reserve_a;
        weight = pool.weight_a as u64;
    } else {
        require(pool_vault.ctx.key == pool.token_b_vault);
        reserve = pool.reserve_b;
        weight = pool.weight_b as u64;
    }

    require(reserve > 0);

    // Imbalance fee: extra charge for single-sided deposit
    let imbalance_fee: u64 = compute_imbalance_fee(amount, pool.swap_fee_bps);
    let effective_amount: u64 = amount - imbalance_fee;
    require(effective_amount > 0);

    // LP minted proportional to effective deposit relative to the reserve share
    // Adjusted by weight: lp = lp_supply * effective_amount * weight / (reserve * 10000)
    let lp_to_mint: u64 = (pool.lp_supply * effective_amount * weight) / (reserve * 10000);
    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_out);

    spl_token::SPLToken::transfer(user_token, pool_vault, user_authority, amount);
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    if (is_token_a) {
        pool.reserve_a = pool.reserve_a + amount;
        pool.protocol_fees_a = pool.protocol_fees_a + imbalance_fee;
    } else {
        pool.reserve_b = pool.reserve_b + amount;
        pool.protocol_fees_b = pool.protocol_fees_b + imbalance_fee;
    }

    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

// 4. remove_liquidity — Burn LP, receive tokens proportionally
pub remove_liquidity(
    pool: WeightedPool @mut @signer,
    user_lp_account: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_a: u64,
    min_amount_b: u64
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    let amount_a: u64 = (lp_amount * pool.reserve_a) / pool.lp_supply;
    let amount_b: u64 = (lp_amount * pool.reserve_b) / pool.lp_supply;
    require(amount_a > 0);
    require(amount_b > 0);
    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);
    spl_token::SPLToken::transfer(pool_token_a_vault, user_token_a, pool, amount_a);
    spl_token::SPLToken::transfer(pool_token_b_vault, user_token_b, pool, amount_b);

    pool.reserve_a = pool.reserve_a - amount_a;
    pool.reserve_b = pool.reserve_b - amount_b;
    pool.lp_supply = pool.lp_supply - lp_amount;
}

// 5. remove_single_sided — Withdraw as single token
pub remove_single_sided(
    pool: WeightedPool @mut @signer,
    user_lp_account: account @mut,
    user_token: account @mut,
    pool_vault: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_out: u64,
    is_token_a: bool
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(lp_mint.ctx.key == pool.lp_mint);

    let mut reserve: u64 = 0;
    let mut weight: u64 = 0;

    if (is_token_a) {
        require(pool_vault.ctx.key == pool.token_a_vault);
        reserve = pool.reserve_a;
        weight = pool.weight_a as u64;
    } else {
        require(pool_vault.ctx.key == pool.token_b_vault);
        reserve = pool.reserve_b;
        weight = pool.weight_b as u64;
    }

    require(reserve > 0);

    // Amount out proportional to LP share, adjusted by weight
    // base_amount = reserve * lp_amount / lp_supply
    let base_amount: u64 = (reserve * lp_amount) / pool.lp_supply;

    // Apply weight scaling: single-sided gets proportional to its weight share
    // amount_out = base_amount * 10000 / weight  (amplified for single token)
    let amount_out_raw: u64 = (base_amount * 10000) / weight;

    // Imbalance fee for withdrawing single-sided
    let imbalance_fee: u64 = compute_imbalance_fee(amount_out_raw, pool.swap_fee_bps);
    let amount_out: u64 = amount_out_raw - imbalance_fee;

    require(amount_out > 0);
    require(amount_out < reserve);
    require(amount_out >= min_amount_out);

    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);
    spl_token::SPLToken::transfer(pool_vault, user_token, pool, amount_out);

    if (is_token_a) {
        pool.reserve_a = pool.reserve_a - amount_out;
        pool.protocol_fees_a = pool.protocol_fees_a + imbalance_fee;
    } else {
        pool.reserve_b = pool.reserve_b - amount_out;
        pool.protocol_fees_b = pool.protocol_fees_b + imbalance_fee;
    }

    pool.lp_supply = pool.lp_supply - lp_amount;
}

// 6. pool_swap — Swap through the weighted pool
pub pool_swap(
    pool: WeightedPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_source_vault: account @mut,
    pool_destination_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    is_a_to_b: bool
) {
    require(!pool.is_paused);
    require(amount_in > 0);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);

    let mut reserve_in: u64 = 0;
    let mut reserve_out: u64 = 0;
    let mut weight_in: u64 = 0;
    let mut weight_out: u64 = 0;

    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_destination_vault.ctx.key == pool.token_b_vault);
        reserve_in = pool.reserve_a;
        reserve_out = pool.reserve_b;
        weight_in = pool.weight_a as u64;
        weight_out = pool.weight_b as u64;
    } else {
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_destination_vault.ctx.key == pool.token_a_vault);
        reserve_in = pool.reserve_b;
        reserve_out = pool.reserve_a;
        weight_in = pool.weight_b as u64;
        weight_out = pool.weight_a as u64;
    }

    // Deduct fees before swap
    let total_fee: u64 = (amount_in * pool.swap_fee_bps) / 10000;
    let protocol_fee: u64 = (amount_in * pool.protocol_fee_bps) / 10000;
    let lp_fee: u64 = total_fee - protocol_fee;
    let amount_in_after_fee: u64 = amount_in - total_fee;
    require(amount_in_after_fee > 0);

    // Weighted constant product swap
    let amount_out: u64 = compute_weighted_swap(
        reserve_in,
        reserve_out,
        amount_in_after_fee,
        weight_in,
        weight_out
    );

    require(amount_out > 0);
    require(amount_out < reserve_out);
    require(amount_out >= min_amount_out);

    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, pool, amount_out);

    if (is_a_to_b) {
        pool.reserve_a = pool.reserve_a + amount_in - protocol_fee;
        pool.reserve_b = pool.reserve_b - amount_out;
        pool.protocol_fees_a = pool.protocol_fees_a + protocol_fee;
    } else {
        pool.reserve_b = pool.reserve_b + amount_in - protocol_fee;
        pool.reserve_a = pool.reserve_a - amount_out;
        pool.protocol_fees_b = pool.protocol_fees_b + protocol_fee;
    }
}

// ---------------------------------------------------------------------------
// Order Book Instructions
// ---------------------------------------------------------------------------

// 7. create_orderbook_market — Initialize an order book market
pub create_orderbook_market(
    market: OrderBookMarket @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    config: GlobalConfig,
    base_mint: pubkey,
    quote_mint: pubkey,
    base_vault: pubkey,
    quote_vault: pubkey,
    tick_size: u64,
    min_order_size: u64,
    maker_fee_bps: u64,
    taker_fee_bps: u64
) {
    require(!config.is_global_pause);
    require(tick_size > 0);
    require(min_order_size > 0);
    require(maker_fee_bps <= 500);
    require(taker_fee_bps <= 500);

    market.base_mint = base_mint;
    market.quote_mint = quote_mint;
    market.base_vault = base_vault;
    market.quote_vault = quote_vault;
    market.tick_size = tick_size;
    market.min_order_size = min_order_size;
    market.maker_fee_bps = maker_fee_bps;
    market.taker_fee_bps = taker_fee_bps;
    market.total_volume = 0 as u128;
    market.authority = creator.ctx.key;
    market.is_active = true;
}

// 8. place_limit_order — Place limit order (bid/ask, price, size)
pub place_limit_order(
    market: OrderBookMarket,
    order: Order @mut @init(payer=trader, space=512),
    config: GlobalConfig @mut,
    trader: account @mut @signer,
    user_token: account @mut,
    market_vault: account @mut,
    token_program: account,
    side: u8,
    price: u64,
    size: u64
) {
    require(market.is_active);
    require(!config.is_global_pause);
    require(side <= 1);
    require(price > 0);
    require(size >= market.min_order_size);
    require(price % market.tick_size == 0);

    // Lock funds: bids lock quote (price * size / 1e6), asks lock base
    if (side == 0) {
        // Bid: lock quote tokens
        let quote_required: u64 = (price * size) / 1000000;
        require(quote_required > 0);
        require(market_vault.ctx.key == market.quote_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, quote_required);
    } else {
        // Ask: lock base tokens
        require(market_vault.ctx.key == market.base_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, size);
    }

    order.market = market.ctx.key;
    order.owner = trader.ctx.key;
    order.side = side;
    order.order_type = 0;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.trigger_price = 0;
    order.twap_interval = 0;
    order.twap_remaining_chunks = 0;
    order.twap_last_executed = 0;
    order.order_id = config.next_order_id;
    order.is_active = true;

    config.next_order_id = config.next_order_id + 1;
}

// 9. place_stop_order — Place a stop-loss/stop-limit order
pub place_stop_order(
    market: OrderBookMarket,
    order: Order @mut @init(payer=trader, space=512),
    config: GlobalConfig @mut,
    trader: account @mut @signer,
    user_token: account @mut,
    market_vault: account @mut,
    token_program: account,
    side: u8,
    price: u64,
    size: u64,
    trigger_price: u64
) {
    require(market.is_active);
    require(!config.is_global_pause);
    require(side <= 1);
    require(price > 0);
    require(size >= market.min_order_size);
    require(trigger_price > 0);
    require(price % market.tick_size == 0);

    // Lock funds same as limit order
    if (side == 0) {
        let quote_required: u64 = (price * size) / 1000000;
        require(quote_required > 0);
        require(market_vault.ctx.key == market.quote_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, quote_required);
    } else {
        require(market_vault.ctx.key == market.base_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, size);
    }

    order.market = market.ctx.key;
    order.owner = trader.ctx.key;
    order.side = side;
    order.order_type = 1;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.trigger_price = trigger_price;
    order.twap_interval = 0;
    order.twap_remaining_chunks = 0;
    order.twap_last_executed = 0;
    order.order_id = config.next_order_id;
    order.is_active = true;

    config.next_order_id = config.next_order_id + 1;
}

// 10. place_twap_order — Time-weighted order execution over intervals
pub place_twap_order(
    market: OrderBookMarket,
    order: Order @mut @init(payer=trader, space=512),
    config: GlobalConfig @mut,
    trader: account @mut @signer,
    user_token: account @mut,
    market_vault: account @mut,
    token_program: account,
    side: u8,
    price: u64,
    total_size: u64,
    num_chunks: u64,
    interval: u64
) {
    require(market.is_active);
    require(!config.is_global_pause);
    require(side <= 1);
    require(price > 0);
    require(total_size >= market.min_order_size);
    require(num_chunks > 0);
    require(num_chunks <= 100);
    require(interval > 0);
    require(price % market.tick_size == 0);

    // Lock full amount upfront
    if (side == 0) {
        let quote_required: u64 = (price * total_size) / 1000000;
        require(quote_required > 0);
        require(market_vault.ctx.key == market.quote_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, quote_required);
    } else {
        require(market_vault.ctx.key == market.base_vault);
        spl_token::SPLToken::transfer(user_token, market_vault, trader, total_size);
    }

    let now: u64 = get_clock().unix_timestamp as u64;

    order.market = market.ctx.key;
    order.owner = trader.ctx.key;
    order.side = side;
    order.order_type = 2;
    order.price = price;
    order.size = total_size;
    order.filled = 0;
    order.trigger_price = 0;
    order.twap_interval = interval;
    order.twap_remaining_chunks = num_chunks;
    order.twap_last_executed = now;
    order.order_id = config.next_order_id;
    order.is_active = true;

    config.next_order_id = config.next_order_id + 1;
}

// 11. cancel_order — Cancel a single order
pub cancel_order(
    market: OrderBookMarket,
    order: Order @mut,
    owner: account @mut @signer,
    user_token: account @mut,
    market_vault: account @mut,
    token_program: account
) {
    require(order.owner == owner.ctx.key);
    require(order.market == market.ctx.key);
    require(order.is_active);

    let remaining_size: u64 = order.size - order.filled;
    require(remaining_size > 0);

    // Refund locked funds
    if (order.side == 0) {
        // Bid: refund quote
        let quote_refund: u64 = (order.price * remaining_size) / 1000000;
        require(market_vault.ctx.key == market.quote_vault);
        spl_token::SPLToken::transfer(market_vault, user_token, market, quote_refund);
    } else {
        // Ask: refund base
        require(market_vault.ctx.key == market.base_vault);
        spl_token::SPLToken::transfer(market_vault, user_token, market, remaining_size);
    }

    order.is_active = false;
}

// 12. cancel_all_orders — Cancel all user orders in a market (batch of up to 4)
pub cancel_all_orders(
    market: OrderBookMarket,
    order_1: Order @mut,
    order_2: Order @mut,
    order_3: Order @mut,
    order_4: Order @mut,
    owner: account @mut @signer,
    user_base_token: account @mut,
    user_quote_token: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    token_program: account
) {
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    let mut total_base_refund: u64 = 0;
    let mut total_quote_refund: u64 = 0;

    // Order 1
    if (order_1.is_active) {
        require(order_1.owner == owner.ctx.key);
        require(order_1.market == market.ctx.key);
        let rem_1: u64 = order_1.size - order_1.filled;
        if (order_1.side == 0) {
            total_quote_refund = total_quote_refund + (order_1.price * rem_1) / 1000000;
        } else {
            total_base_refund = total_base_refund + rem_1;
        }
        order_1.is_active = false;
    }

    // Order 2
    if (order_2.is_active) {
        require(order_2.owner == owner.ctx.key);
        require(order_2.market == market.ctx.key);
        let rem_2: u64 = order_2.size - order_2.filled;
        if (order_2.side == 0) {
            total_quote_refund = total_quote_refund + (order_2.price * rem_2) / 1000000;
        } else {
            total_base_refund = total_base_refund + rem_2;
        }
        order_2.is_active = false;
    }

    // Order 3
    if (order_3.is_active) {
        require(order_3.owner == owner.ctx.key);
        require(order_3.market == market.ctx.key);
        let rem_3: u64 = order_3.size - order_3.filled;
        if (order_3.side == 0) {
            total_quote_refund = total_quote_refund + (order_3.price * rem_3) / 1000000;
        } else {
            total_base_refund = total_base_refund + rem_3;
        }
        order_3.is_active = false;
    }

    // Order 4
    if (order_4.is_active) {
        require(order_4.owner == owner.ctx.key);
        require(order_4.market == market.ctx.key);
        let rem_4: u64 = order_4.size - order_4.filled;
        if (order_4.side == 0) {
            total_quote_refund = total_quote_refund + (order_4.price * rem_4) / 1000000;
        } else {
            total_base_refund = total_base_refund + rem_4;
        }
        order_4.is_active = false;
    }

    // Batch refund transfers
    if (total_base_refund > 0) {
        spl_token::SPLToken::transfer(base_vault, user_base_token, market, total_base_refund);
    }

    if (total_quote_refund > 0) {
        spl_token::SPLToken::transfer(quote_vault, user_quote_token, market, total_quote_refund);
    }
}

// 13. match_orders — Crank: match crossing bid and ask orders
pub match_orders(
    market: OrderBookMarket @mut @signer,
    bid_order: Order @mut,
    ask_order: Order @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    bid_owner_quote: account @mut,
    bid_owner_base: account @mut,
    ask_owner_base: account @mut,
    ask_owner_quote: account @mut,
    cranker: account @signer,
    token_program: account,
    oracle_price: u64
) {
    require(market.is_active);
    require(bid_order.is_active);
    require(ask_order.is_active);
    require(bid_order.market == market.ctx.key);
    require(ask_order.market == market.ctx.key);
    require(bid_order.side == 0);
    require(ask_order.side == 1);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    // Stop order trigger checks
    if (bid_order.order_type == 1) {
        // Stop-buy: oracle must be >= trigger
        require(oracle_price >= bid_order.trigger_price);
    }
    if (ask_order.order_type == 1) {
        // Stop-sell: oracle must be <= trigger
        require(oracle_price <= ask_order.trigger_price);
    }

    // TWAP chunk check for bid
    let mut bid_available: u64 = bid_order.size - bid_order.filled;
    if (bid_order.order_type == 2) {
        let now: u64 = get_clock().unix_timestamp as u64;
        require(now >= bid_order.twap_last_executed + bid_order.twap_interval);
        require(bid_order.twap_remaining_chunks > 0);
        let chunk_size: u64 = (bid_order.size - bid_order.filled) / bid_order.twap_remaining_chunks;
        if (chunk_size < bid_available) {
            bid_available = chunk_size;
        }
    }

    // TWAP chunk check for ask
    let mut ask_available: u64 = ask_order.size - ask_order.filled;
    if (ask_order.order_type == 2) {
        let now_ask: u64 = get_clock().unix_timestamp as u64;
        require(now_ask >= ask_order.twap_last_executed + ask_order.twap_interval);
        require(ask_order.twap_remaining_chunks > 0);
        let ask_chunk: u64 = (ask_order.size - ask_order.filled) / ask_order.twap_remaining_chunks;
        if (ask_chunk < ask_available) {
            ask_available = ask_chunk;
        }
    }

    // Price crossing: bid price must be >= ask price
    require(bid_order.price >= ask_order.price);

    // Fill at the maker (resting) price — take the bid price as execution price
    let exec_price: u64 = bid_order.price;

    // Matched quantity is the minimum of both available
    let mut fill_size: u64 = bid_available;
    if (ask_available < fill_size) {
        fill_size = ask_available;
    }
    require(fill_size > 0);

    // Quote amount exchanged
    let quote_amount: u64 = (exec_price * fill_size) / 1000000;
    require(quote_amount > 0);

    // Fees
    let maker_fee: u64 = (quote_amount * market.maker_fee_bps) / 10000;
    let taker_fee: u64 = (quote_amount * market.taker_fee_bps) / 10000;

    // Transfer base tokens from ask escrow to bid owner
    let base_to_buyer: u64 = fill_size;
    spl_token::SPLToken::transfer(base_vault, bid_owner_base, market, base_to_buyer);

    // Transfer quote tokens from bid escrow to ask owner (minus maker fee)
    let quote_to_seller: u64 = quote_amount - maker_fee;
    spl_token::SPLToken::transfer(quote_vault, ask_owner_quote, market, quote_to_seller);

    // Update fills
    bid_order.filled = bid_order.filled + fill_size;
    ask_order.filled = ask_order.filled + fill_size;

    // Update TWAP state
    if (bid_order.order_type == 2) {
        let now_b: u64 = get_clock().unix_timestamp as u64;
        bid_order.twap_last_executed = now_b;
        bid_order.twap_remaining_chunks = bid_order.twap_remaining_chunks - 1;
    }
    if (ask_order.order_type == 2) {
        let now_a: u64 = get_clock().unix_timestamp as u64;
        ask_order.twap_last_executed = now_a;
        ask_order.twap_remaining_chunks = ask_order.twap_remaining_chunks - 1;
    }

    // Deactivate fully filled orders
    if (bid_order.filled >= bid_order.size) {
        bid_order.is_active = false;
    }
    if (ask_order.filled >= ask_order.size) {
        ask_order.is_active = false;
    }
    // TWAP orders with no remaining chunks are done
    if (bid_order.order_type == 2) {
        if (bid_order.twap_remaining_chunks == 0) {
            bid_order.is_active = false;
        }
    }
    if (ask_order.order_type == 2) {
        if (ask_order.twap_remaining_chunks == 0) {
            ask_order.is_active = false;
        }
    }

    // Track volume (add taker fee to total as protocol revenue)
    let volume_delta: u128 = quote_amount as u128;
    market.total_volume = market.total_volume + volume_delta;
}

// ---------------------------------------------------------------------------
// Cross-Margin Instructions
// ---------------------------------------------------------------------------

// 14. create_margin_account — Create unified margin account
pub create_margin_account(
    margin: MarginAccount @mut @init(payer=owner, space=1024),
    owner: account @mut @signer,
    config: GlobalConfig
) {
    require(!config.is_global_pause);

    margin.owner = owner.ctx.key;
    margin.total_collateral_value = 0;
    margin.total_liabilities = 0;
    margin.deposit_1_mint = owner.ctx.key;
    margin.deposit_1_amount = 0;
    margin.deposit_2_mint = owner.ctx.key;
    margin.deposit_2_amount = 0;
    margin.deposit_3_mint = owner.ctx.key;
    margin.deposit_3_amount = 0;
    margin.deposit_4_mint = owner.ctx.key;
    margin.deposit_4_amount = 0;
    margin.position_1_market = owner.ctx.key;
    margin.position_1_size = 0;
    margin.position_1_entry_price = 0;
    margin.position_2_market = owner.ctx.key;
    margin.position_2_size = 0;
    margin.position_2_entry_price = 0;
}

// 15. deposit_margin — Deposit collateral into margin account
pub deposit_margin(
    margin: MarginAccount @mut,
    owner: account @mut @signer,
    user_token: account @mut,
    margin_vault: account @mut,
    token_program: account,
    config: GlobalConfig,
    mint: pubkey,
    amount: u64,
    slot_index: u8,
    oracle_price: u64
) {
    require(!config.is_global_pause);
    require(margin.owner == owner.ctx.key);
    require(amount > 0);
    require(oracle_price > 0);
    require(slot_index >= 1);
    require(slot_index <= 4);

    spl_token::SPLToken::transfer(user_token, margin_vault, owner, amount);

    // Update the deposit slot
    if (slot_index == 1) {
        margin.deposit_1_mint = mint;
        margin.deposit_1_amount = margin.deposit_1_amount + amount;
    }
    if (slot_index == 2) {
        margin.deposit_2_mint = mint;
        margin.deposit_2_amount = margin.deposit_2_amount + amount;
    }
    if (slot_index == 3) {
        margin.deposit_3_mint = mint;
        margin.deposit_3_amount = margin.deposit_3_amount + amount;
    }
    if (slot_index == 4) {
        margin.deposit_4_mint = mint;
        margin.deposit_4_amount = margin.deposit_4_amount + amount;
    }

    // Update collateral value (oracle_price is price per token in quote units)
    let deposit_value: u64 = (amount * oracle_price) / 1000000;
    margin.total_collateral_value = margin.total_collateral_value + deposit_value;
}

// 16. withdraw_margin — Withdraw from margin (with health check)
pub withdraw_margin(
    margin: MarginAccount @mut,
    owner: account @mut @signer,
    user_token: account @mut,
    margin_vault: account @mut,
    token_program: account,
    config: GlobalConfig,
    amount: u64,
    slot_index: u8,
    oracle_price: u64
) {
    require(!config.is_global_pause);
    require(margin.owner == owner.ctx.key);
    require(amount > 0);
    require(oracle_price > 0);
    require(slot_index >= 1);
    require(slot_index <= 4);

    // Check sufficient balance in the slot
    let mut slot_balance: u64 = 0;
    if (slot_index == 1) {
        slot_balance = margin.deposit_1_amount;
    }
    if (slot_index == 2) {
        slot_balance = margin.deposit_2_amount;
    }
    if (slot_index == 3) {
        slot_balance = margin.deposit_3_amount;
    }
    if (slot_index == 4) {
        slot_balance = margin.deposit_4_amount;
    }
    require(amount <= slot_balance);

    // Compute withdrawal value
    let withdraw_value: u64 = (amount * oracle_price) / 1000000;
    require(margin.total_collateral_value >= withdraw_value);

    // Post-withdrawal health check
    let new_collateral: u64 = margin.total_collateral_value - withdraw_value;
    let health: u64 = compute_margin_health(new_collateral, margin.total_liabilities);
    require(health >= config.maintenance_ratio_bps);

    spl_token::SPLToken::transfer(margin_vault, user_token, owner, amount);

    // Update the deposit slot
    if (slot_index == 1) {
        margin.deposit_1_amount = margin.deposit_1_amount - amount;
    }
    if (slot_index == 2) {
        margin.deposit_2_amount = margin.deposit_2_amount - amount;
    }
    if (slot_index == 3) {
        margin.deposit_3_amount = margin.deposit_3_amount - amount;
    }
    if (slot_index == 4) {
        margin.deposit_4_amount = margin.deposit_4_amount - amount;
    }

    margin.total_collateral_value = new_collateral;
}

// 17. compute_margin_health — Calculate cross-market health factor (view-like)
pub get_margin_health(
    margin: MarginAccount,
    config: GlobalConfig
) -> u64 {
    let health: u64 = compute_margin_health(margin.total_collateral_value, margin.total_liabilities);
    return health;
}

// 18. liquidate_margin — Liquidate unhealthy margin account
pub liquidate_margin(
    margin: MarginAccount @mut,
    config: GlobalConfig,
    liquidator: account @mut @signer,
    liquidator_token: account @mut,
    margin_vault: account @mut,
    liquidator_receive: account @mut,
    token_program: account,
    repay_amount: u64,
    oracle_price: u64,
    slot_index: u8
) {
    require(!config.is_global_pause);
    require(repay_amount > 0);
    require(oracle_price > 0);
    require(slot_index >= 1);
    require(slot_index <= 4);

    // Verify the account is unhealthy
    let health: u64 = compute_margin_health(margin.total_collateral_value, margin.total_liabilities);
    require(health < config.maintenance_ratio_bps);

    // Clamp repay to outstanding liabilities
    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > margin.total_liabilities) {
        actual_repay = margin.total_liabilities;
    }

    // Liquidator pays off debt
    spl_token::SPLToken::transfer(liquidator_token, margin_vault, liquidator, actual_repay);

    // Liquidator receives collateral + 5% bonus
    let collateral_value: u64 = (actual_repay * 10500) / 10000;
    let collateral_tokens: u64 = (collateral_value * 1000000) / oracle_price;

    // Check slot has enough
    let mut slot_balance: u64 = 0;
    if (slot_index == 1) {
        slot_balance = margin.deposit_1_amount;
    }
    if (slot_index == 2) {
        slot_balance = margin.deposit_2_amount;
    }
    if (slot_index == 3) {
        slot_balance = margin.deposit_3_amount;
    }
    if (slot_index == 4) {
        slot_balance = margin.deposit_4_amount;
    }

    let mut seize_amount: u64 = collateral_tokens;
    if (seize_amount > slot_balance) {
        seize_amount = slot_balance;
    }

    spl_token::SPLToken::transfer(margin_vault, liquidator_receive, liquidator, seize_amount);

    // Update slot
    if (slot_index == 1) {
        margin.deposit_1_amount = margin.deposit_1_amount - seize_amount;
    }
    if (slot_index == 2) {
        margin.deposit_2_amount = margin.deposit_2_amount - seize_amount;
    }
    if (slot_index == 3) {
        margin.deposit_3_amount = margin.deposit_3_amount - seize_amount;
    }
    if (slot_index == 4) {
        margin.deposit_4_amount = margin.deposit_4_amount - seize_amount;
    }

    // Update margin account state
    let seized_value: u64 = (seize_amount * oracle_price) / 1000000;
    if (margin.total_collateral_value >= seized_value) {
        margin.total_collateral_value = margin.total_collateral_value - seized_value;
    } else {
        margin.total_collateral_value = 0;
    }

    if (margin.total_liabilities >= actual_repay) {
        margin.total_liabilities = margin.total_liabilities - actual_repay;
    } else {
        margin.total_liabilities = 0;
    }
}

// ---------------------------------------------------------------------------
// Yield Vault Instructions
// ---------------------------------------------------------------------------

// 19. create_vault — Create auto-compounding yield vault
pub create_vault(
    vault: YieldVault @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    config: GlobalConfig,
    underlying_mint: pubkey,
    vault_shares_mint: pubkey,
    underlying_vault: pubkey,
    strategy_type: u8,
    apy_estimate_bps: u64
) {
    require(!config.is_global_pause);
    require(strategy_type <= 3);
    require(apy_estimate_bps <= 50000);

    vault.underlying_mint = underlying_mint;
    vault.vault_shares_mint = vault_shares_mint;
    vault.underlying_vault = underlying_vault;
    vault.total_deposited = 0;
    vault.total_shares = 0;
    vault.accumulated_yield = 0;
    vault.last_compound = get_clock().unix_timestamp as u64;
    vault.strategy_type = strategy_type;
    vault.apy_estimate_bps = apy_estimate_bps;
    vault.authority = creator.ctx.key;
}

// 20. vault_deposit — Deposit tokens into vault, receive vault shares
pub vault_deposit(
    vault: YieldVault @mut @signer,
    user_token: account @mut,
    vault_token_account: account @mut,
    shares_mint: account @mut,
    user_shares_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64,
    min_shares_out: u64
) {
    require(amount > 0);
    require(vault_token_account.ctx.key == vault.underlying_vault);
    require(shares_mint.ctx.key == vault.vault_shares_mint);

    let shares_to_mint: u64 = compute_vault_shares(amount, vault.total_shares, vault.total_deposited);
    require(shares_to_mint > 0);
    require(shares_to_mint >= min_shares_out);

    spl_token::SPLToken::transfer(user_token, vault_token_account, user_authority, amount);
    spl_token::SPLToken::mint_to(shares_mint, user_shares_account, vault, shares_to_mint);

    vault.total_deposited = vault.total_deposited + amount;
    vault.total_shares = vault.total_shares + shares_to_mint;
}

// 21. vault_withdraw — Burn shares, receive tokens + yield
pub vault_withdraw(
    vault: YieldVault @mut @signer,
    user_shares_account: account @mut,
    user_token: account @mut,
    vault_token_account: account @mut,
    shares_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    shares_amount: u64,
    min_amount_out: u64
) {
    require(shares_amount > 0);
    require(shares_amount <= vault.total_shares);
    require(vault_token_account.ctx.key == vault.underlying_vault);
    require(shares_mint.ctx.key == vault.vault_shares_mint);

    let amount_out: u64 = compute_vault_withdraw_amount(shares_amount, vault.total_shares, vault.total_deposited);
    require(amount_out > 0);
    require(amount_out <= vault.total_deposited);
    require(amount_out >= min_amount_out);

    spl_token::SPLToken::burn(user_shares_account, shares_mint, user_authority, shares_amount);
    spl_token::SPLToken::transfer(vault_token_account, user_token, vault, amount_out);

    vault.total_deposited = vault.total_deposited - amount_out;
    vault.total_shares = vault.total_shares - shares_amount;
}

// 22. compound_vault — Reinvest accrued yield (permissionless crank)
pub compound_vault(
    vault: YieldVault @mut,
    cranker: account @signer,
    yield_amount: u64
) {
    require(yield_amount > 0);
    require(vault.total_deposited > 0);

    let now: u64 = get_clock().unix_timestamp as u64;
    require(now > vault.last_compound);

    // Compound: add yield to total_deposited so share price appreciates
    vault.total_deposited = vault.total_deposited + yield_amount;
    vault.accumulated_yield = vault.accumulated_yield + yield_amount;
    vault.last_compound = now;
}

// ---------------------------------------------------------------------------
// Admin Instructions
// ---------------------------------------------------------------------------

// Global config initialization
pub init_global_config(
    config: GlobalConfig @mut @init(payer=admin, space=256),
    admin: account @mut @signer,
    maintenance_ratio_bps: u64
) {
    require(maintenance_ratio_bps >= 10000);
    require(maintenance_ratio_bps <= 50000);

    config.authority = admin.ctx.key;
    config.next_order_id = 1;
    config.maintenance_ratio_bps = maintenance_ratio_bps;
    config.is_global_pause = false;
}

// 23. set_pool_weights — Rebalance pool weights over time
pub set_pool_weights(
    pool: WeightedPool @mut,
    authority: account @signer,
    new_weight_a: u16,
    new_weight_b: u16
) {
    require(pool.authority == authority.ctx.key);
    require(new_weight_a > 0);
    require(new_weight_b > 0);
    require(new_weight_a + new_weight_b == 10000);

    pool.weight_a = new_weight_a;
    pool.weight_b = new_weight_b;
}

// 24. set_fees — Update trading fees
pub set_pool_fees(
    pool: WeightedPool @mut,
    authority: account @signer,
    new_swap_fee_bps: u64,
    new_protocol_fee_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_swap_fee_bps <= 1000);
    require(new_protocol_fee_bps <= new_swap_fee_bps);

    pool.swap_fee_bps = new_swap_fee_bps;
    pool.protocol_fee_bps = new_protocol_fee_bps;
}

pub set_market_fees(
    market: OrderBookMarket @mut,
    authority: account @signer,
    new_maker_fee_bps: u64,
    new_taker_fee_bps: u64
) {
    require(market.authority == authority.ctx.key);
    require(new_maker_fee_bps <= 500);
    require(new_taker_fee_bps <= 500);

    market.maker_fee_bps = new_maker_fee_bps;
    market.taker_fee_bps = new_taker_fee_bps;
}

// 25. set_authority — Transfer admin
pub set_pool_authority(
    pool: WeightedPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

pub set_market_authority(
    market: OrderBookMarket @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(market.authority == authority.ctx.key);
    market.authority = new_authority;
}

pub set_vault_authority(
    vault: YieldVault @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(vault.authority == authority.ctx.key);
    vault.authority = new_authority;
}

pub set_global_authority(
    config: GlobalConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

// 26. pause / unpause — Emergency controls
pub pause_pool(
    pool: WeightedPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = true;
}

pub unpause_pool(
    pool: WeightedPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = false;
}

pub pause_market(
    market: OrderBookMarket @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    market.is_active = false;
}

pub unpause_market(
    market: OrderBookMarket @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    market.is_active = true;
}

pub global_pause(
    config: GlobalConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    config.is_global_pause = true;
}

pub global_unpause(
    config: GlobalConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    config.is_global_pause = false;
}

// ---------------------------------------------------------------------------
// Protocol Fee Collection
// ---------------------------------------------------------------------------

pub collect_pool_protocol_fees(
    pool: WeightedPool @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64
) {
    require(pool.authority == authority.ctx.key);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);
    require(amount_a <= pool.protocol_fees_a);
    require(amount_b <= pool.protocol_fees_b);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, pool, amount_a);
        pool.reserve_a = pool.reserve_a - amount_a;
        pool.protocol_fees_a = pool.protocol_fees_a - amount_a;
    }

    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, pool, amount_b);
        pool.reserve_b = pool.reserve_b - amount_b;
        pool.protocol_fees_b = pool.protocol_fees_b - amount_b;
    }
}

// ---------------------------------------------------------------------------
// Read-only Helpers (view functions)
// ---------------------------------------------------------------------------

pub get_pool_reserves_a(pool: WeightedPool) -> u64 {
    return pool.reserve_a;
}

pub get_pool_reserves_b(pool: WeightedPool) -> u64 {
    return pool.reserve_b;
}

pub get_pool_weights(pool: WeightedPool) -> u64 {
    // Returns weight_a as u64 (weight_b = 10000 - weight_a)
    return pool.weight_a as u64;
}

pub get_pool_lp_supply(pool: WeightedPool) -> u64 {
    return pool.lp_supply;
}

pub get_market_volume(market: OrderBookMarket) -> u128 {
    return market.total_volume;
}

pub get_order_status(order: Order) -> u64 {
    return order.filled;
}

pub get_vault_total_deposited(vault: YieldVault) -> u64 {
    return vault.total_deposited;
}

pub get_vault_total_shares(vault: YieldVault) -> u64 {
    return vault.total_shares;
}

pub get_vault_accumulated_yield(vault: YieldVault) -> u64 {
    return vault.accumulated_yield;
}
