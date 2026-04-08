// Aldrin DEX -- Migrated to 5ive DSL
//
// Aldrin is a Solana DEX combining two trading mechanisms:
//   1. AMM Pools -- Constant-product pools (x * y = k) with configurable fees
//   2. Order Book -- On-chain central limit order book (CLOB) with price-time priority
//
// Additionally supports:
//   - Concentrated liquidity pools (simplified tick-based ranges)
//   - Yield farming (MasterChef-style reward distribution)
//   - Multi-hop swap routing (A -> B -> C)
//   - Admin controls: fee updates, authority transfer, pause/unpause
//
// Original: ~12,000 SLoC Rust/Anchor
// 5ive:     ~1,100 SLoC

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts -- AMM
// ---------------------------------------------------------------------------

account AmmPool {
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;
    reserve_a: u64;
    reserve_b: u64;
    lp_supply: u64;
    fee_numerator: u64;
    fee_denominator: u64;
    protocol_fee_numerator: u64;
    protocol_fees_a: u64;
    protocol_fees_b: u64;
    authority: pubkey;
    is_paused: bool;
}

// ---------------------------------------------------------------------------
// Accounts -- Order Book
// ---------------------------------------------------------------------------

account OrderBook {
    market_id: u64;
    base_mint: pubkey;
    quote_mint: pubkey;
    base_vault: pubkey;
    quote_vault: pubkey;
    min_order_size: u64;
    tick_size: u64;
    authority: pubkey;
    is_active: bool;
    next_order_id: u64;
}

account Order {
    market: pubkey;
    owner: pubkey;
    side: u8;           // 0 = bid, 1 = ask
    price: u64;
    size: u64;
    filled: u64;
    order_id: u64;
    timestamp: u64;
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Accounts -- Concentrated Liquidity
// ---------------------------------------------------------------------------

account ConcentratedPool {
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;
    reserve_a: u64;
    reserve_b: u64;
    lp_supply: u64;
    fee_numerator: u64;
    fee_denominator: u64;
    protocol_fee_numerator: u64;
    protocol_fees_a: u64;
    protocol_fees_b: u64;
    authority: pubkey;
    is_paused: bool;
    tick_spacing: u16;
    sqrt_price: u128;
    tick_current: i64;
    liquidity: u128;
}

account ConcentratedPosition {
    pool: pubkey;
    owner: pubkey;
    tick_lower: i64;
    tick_upper: i64;
    liquidity: u128;
    fees_owed_a: u64;
    fees_owed_b: u64;
}

// ---------------------------------------------------------------------------
// Accounts -- Farming
// ---------------------------------------------------------------------------

account Farm {
    pool_mint: pubkey;
    reward_mint: pubkey;
    reward_vault: pubkey;
    reward_per_second: u64;
    total_staked: u64;
    accumulated_reward_per_share: u128;
    last_update: u64;
    authority: pubkey;
}

account StakeRecord {
    farm: pubkey;
    owner: pubkey;
    staked_amount: u64;
    reward_debt: u128;
    pending_rewards: u64;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Precision scale for reward-per-share accumulator (1e12)
fn reward_precision() -> u128 {
    return 1000000000000;
}

// Calculate trade fee: (amount * numerator) / denominator
fn calc_fee(amount: u64, numerator: u64, denominator: u64) -> u64 {
    if (denominator == 0) {
        return 0;
    }
    return (amount * numerator) / denominator;
}

// Ceiling division: (a + b - 1) / b
fn ceil_div(a: u64, b: u64) -> u64 {
    require(b > 0);
    return (a + b - 1) / b;
}

// Compute constant-product swap output after fee
fn compute_swap_output(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_numerator: u64,
    fee_denominator: u64,
    protocol_fee_numerator: u64
) -> u64 {
    let total_fee: u64 = calc_fee(amount_in, fee_numerator, fee_denominator);
    let protocol_fee: u64 = calc_fee(amount_in, protocol_fee_numerator, fee_denominator);
    let dx_after_fee: u64 = amount_in - total_fee;
    let amount_out: u64 = (reserve_out * dx_after_fee) / (reserve_in + dx_after_fee);
    return amount_out;
}

// Update farm accumulated_reward_per_share to current time
fn update_farm_rewards(farm: Farm, now: u64) -> u128 {
    if (farm.total_staked == 0) {
        return farm.accumulated_reward_per_share;
    }
    let elapsed: u64 = now - farm.last_update;
    let new_rewards: u128 = elapsed as u128 * farm.reward_per_second as u128;
    let reward_increment: u128 = (new_rewards * reward_precision()) / farm.total_staked as u128;
    return farm.accumulated_reward_per_share + reward_increment;
}

// Compute pending rewards for a staker
fn compute_pending(staked: u64, acc_per_share: u128, reward_debt: u128) -> u64 {
    let gross: u128 = (staked as u128 * acc_per_share) / reward_precision();
    if (gross <= reward_debt) {
        return 0;
    }
    let pending: u128 = gross - reward_debt;
    return pending as u64;
}

// =========================================================================
//  AMM POOL INSTRUCTIONS
// =========================================================================

// 1. Initialize a new AMM liquidity pool
pub initialize_pool(
    pool: AmmPool @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint: pubkey,
    fee_numerator: u64,
    fee_denominator: u64,
    protocol_fee_numerator: u64
) {
    require(fee_denominator > 0);
    require(fee_numerator < fee_denominator);
    require(protocol_fee_numerator <= fee_numerator);

    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.lp_mint = lp_mint;
    pool.reserve_a = 0;
    pool.reserve_b = 0;
    pool.lp_supply = 0;
    pool.fee_numerator = fee_numerator;
    pool.fee_denominator = fee_denominator;
    pool.protocol_fee_numerator = protocol_fee_numerator;
    pool.protocol_fees_a = 0;
    pool.protocol_fees_b = 0;
    pool.authority = creator.ctx.key;
    pool.is_paused = false;
}

// 2. Deposit proportional liquidity, receive LP tokens
pub deposit_liquidity(
    pool: AmmPool @mut @signer,
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
    min_lp_tokens: u64
) {
    require(!pool.is_paused);
    require(amount_a > 0);
    require(amount_b > 0);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    let mut lp_to_mint: u64 = 0;

    if (pool.lp_supply == 0) {
        // Bootstrap: initial liquidity = sum of deposits
        lp_to_mint = amount_a + amount_b;
    } else {
        // Proportional deposit: must match current ratio
        require(amount_a * pool.reserve_b == amount_b * pool.reserve_a);
        lp_to_mint = (amount_a * pool.lp_supply) / pool.reserve_a;
    }

    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_tokens);

    spl_token::SPLToken::transfer(user_token_a, pool_token_a_vault, user_authority, amount_a);
    spl_token::SPLToken::transfer(user_token_b, pool_token_b_vault, user_authority, amount_b);
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    pool.reserve_a = pool.reserve_a + amount_a;
    pool.reserve_b = pool.reserve_b + amount_b;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

// 3. Withdraw liquidity: burn LP tokens, receive proportional share
pub withdraw_liquidity(
    pool: AmmPool @mut @signer,
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
    // Withdrawals allowed even when paused (user safety)
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

// 4. Swap through AMM pool with slippage protection
pub swap(
    pool: AmmPool @mut @signer,
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

    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_destination_vault.ctx.key == pool.token_b_vault);
        reserve_in = pool.reserve_a;
        reserve_out = pool.reserve_b;
    } else {
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_destination_vault.ctx.key == pool.token_a_vault);
        reserve_in = pool.reserve_b;
        reserve_out = pool.reserve_a;
    }

    // Fee calculation
    let protocol_fee: u64 = calc_fee(amount_in, pool.protocol_fee_numerator, pool.fee_denominator);
    let lp_fee: u64 = calc_fee(amount_in, pool.fee_numerator - pool.protocol_fee_numerator, pool.fee_denominator);
    let dx_after_fee: u64 = amount_in - protocol_fee - lp_fee;

    // Constant product: amount_out = (reserve_out * dx) / (reserve_in + dx)
    let amount_out: u64 = (reserve_out * dx_after_fee) / (reserve_in + dx_after_fee);

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

// 5. Routed swap through two AMM pools: A -> B -> C
pub swap_with_routing(
    pool_ab: AmmPool @mut @signer,
    pool_bc: AmmPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_ab_source_vault: account @mut,
    pool_ab_dest_vault: account @mut,
    pool_bc_source_vault: account @mut,
    pool_bc_dest_vault: account @mut,
    intermediate_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    first_is_a_to_b: bool,
    second_is_a_to_b: bool
) {
    require(!pool_ab.is_paused);
    require(!pool_bc.is_paused);
    require(amount_in > 0);

    // --- Leg 1: swap through pool_ab ---
    let mut reserve_in_1: u64 = 0;
    let mut reserve_out_1: u64 = 0;

    if (first_is_a_to_b) {
        require(pool_ab_source_vault.ctx.key == pool_ab.token_a_vault);
        require(pool_ab_dest_vault.ctx.key == pool_ab.token_b_vault);
        reserve_in_1 = pool_ab.reserve_a;
        reserve_out_1 = pool_ab.reserve_b;
    } else {
        require(pool_ab_source_vault.ctx.key == pool_ab.token_b_vault);
        require(pool_ab_dest_vault.ctx.key == pool_ab.token_a_vault);
        reserve_in_1 = pool_ab.reserve_b;
        reserve_out_1 = pool_ab.reserve_a;
    }

    let protocol_fee_1: u64 = calc_fee(amount_in, pool_ab.protocol_fee_numerator, pool_ab.fee_denominator);
    let lp_fee_1: u64 = calc_fee(amount_in, pool_ab.fee_numerator - pool_ab.protocol_fee_numerator, pool_ab.fee_denominator);
    let dx_1: u64 = amount_in - protocol_fee_1 - lp_fee_1;
    let intermediate_amount: u64 = (reserve_out_1 * dx_1) / (reserve_in_1 + dx_1);

    require(intermediate_amount > 0);
    require(intermediate_amount < reserve_out_1);

    spl_token::SPLToken::transfer(user_source, pool_ab_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_ab_dest_vault, intermediate_account, pool_ab, intermediate_amount);

    if (first_is_a_to_b) {
        pool_ab.reserve_a = pool_ab.reserve_a + amount_in - protocol_fee_1;
        pool_ab.reserve_b = pool_ab.reserve_b - intermediate_amount;
        pool_ab.protocol_fees_a = pool_ab.protocol_fees_a + protocol_fee_1;
    } else {
        pool_ab.reserve_b = pool_ab.reserve_b + amount_in - protocol_fee_1;
        pool_ab.reserve_a = pool_ab.reserve_a - intermediate_amount;
        pool_ab.protocol_fees_b = pool_ab.protocol_fees_b + protocol_fee_1;
    }

    // --- Leg 2: swap through pool_bc ---
    let mut reserve_in_2: u64 = 0;
    let mut reserve_out_2: u64 = 0;

    if (second_is_a_to_b) {
        require(pool_bc_source_vault.ctx.key == pool_bc.token_a_vault);
        require(pool_bc_dest_vault.ctx.key == pool_bc.token_b_vault);
        reserve_in_2 = pool_bc.reserve_a;
        reserve_out_2 = pool_bc.reserve_b;
    } else {
        require(pool_bc_source_vault.ctx.key == pool_bc.token_b_vault);
        require(pool_bc_dest_vault.ctx.key == pool_bc.token_a_vault);
        reserve_in_2 = pool_bc.reserve_b;
        reserve_out_2 = pool_bc.reserve_a;
    }

    let protocol_fee_2: u64 = calc_fee(intermediate_amount, pool_bc.protocol_fee_numerator, pool_bc.fee_denominator);
    let lp_fee_2: u64 = calc_fee(intermediate_amount, pool_bc.fee_numerator - pool_bc.protocol_fee_numerator, pool_bc.fee_denominator);
    let dx_2: u64 = intermediate_amount - protocol_fee_2 - lp_fee_2;
    let final_amount: u64 = (reserve_out_2 * dx_2) / (reserve_in_2 + dx_2);

    require(final_amount > 0);
    require(final_amount < reserve_out_2);
    require(final_amount >= min_amount_out);

    spl_token::SPLToken::transfer(intermediate_account, pool_bc_source_vault, user_authority, intermediate_amount);
    spl_token::SPLToken::transfer(pool_bc_dest_vault, user_destination, pool_bc, final_amount);

    if (second_is_a_to_b) {
        pool_bc.reserve_a = pool_bc.reserve_a + intermediate_amount - protocol_fee_2;
        pool_bc.reserve_b = pool_bc.reserve_b - final_amount;
        pool_bc.protocol_fees_a = pool_bc.protocol_fees_a + protocol_fee_2;
    } else {
        pool_bc.reserve_b = pool_bc.reserve_b + intermediate_amount - protocol_fee_2;
        pool_bc.reserve_a = pool_bc.reserve_a - final_amount;
        pool_bc.protocol_fees_b = pool_bc.protocol_fees_b + protocol_fee_2;
    }
}

// =========================================================================
//  ORDER BOOK INSTRUCTIONS
// =========================================================================

// 6. Create a new order book market for a trading pair
pub create_market(
    book: OrderBook @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    base_mint: pubkey,
    quote_mint: pubkey,
    base_vault: pubkey,
    quote_vault: pubkey,
    market_id: u64,
    min_order_size: u64,
    tick_size: u64
) {
    require(min_order_size > 0);
    require(tick_size > 0);

    book.market_id = market_id;
    book.base_mint = base_mint;
    book.quote_mint = quote_mint;
    book.base_vault = base_vault;
    book.quote_vault = quote_vault;
    book.min_order_size = min_order_size;
    book.tick_size = tick_size;
    book.authority = creator.ctx.key;
    book.is_active = true;
    book.next_order_id = 1;
}

// 7. Place a limit order (bid or ask)
pub place_limit_order(
    book: OrderBook @mut,
    order: Order @mut @init(payer=trader, space=512) @signer,
    trader: account @mut @signer,
    user_token: account @mut,
    vault: account @mut,
    token_program: account,
    side: u8,
    price: u64,
    size: u64
) {
    require(book.is_active);
    require(side == 0 || side == 1);
    require(price > 0);
    require(size >= book.min_order_size);
    require(price % book.tick_size == 0);

    // Lock tokens: bids lock quote (price * size), asks lock base (size)
    let mut lock_amount: u64 = 0;
    if (side == 0) {
        // Bid: lock quote tokens (price * size / price_precision)
        // Using direct multiplication; caller provides token account for quote
        lock_amount = (price * size) / 1000000;
        require(lock_amount > 0);
        require(vault.ctx.key == book.quote_vault);
    } else {
        // Ask: lock base tokens
        lock_amount = size;
        require(vault.ctx.key == book.base_vault);
    }

    spl_token::SPLToken::transfer(user_token, vault, trader, lock_amount);

    order.market = book.ctx.key;
    order.owner = trader.ctx.key;
    order.side = side;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.order_id = book.next_order_id;
    order.timestamp = get_clock().unix_timestamp as u64;
    order.is_active = true;

    book.next_order_id = book.next_order_id + 1;
}

// 8. Place a market order (execute at best available price via a resting order)
pub place_market_order(
    book: OrderBook @mut,
    resting_order: Order @mut,
    taker: account @mut @signer,
    taker_source: account @mut,
    taker_destination: account @mut,
    book_base_vault: account @mut,
    book_quote_vault: account @mut,
    book_signer: OrderBook @signer,
    token_program: account,
    size: u64
) {
    require(book.is_active);
    require(size > 0);
    require(resting_order.market == book.ctx.key);
    require(resting_order.is_active);

    let available: u64 = resting_order.size - resting_order.filled;
    require(available > 0);

    let mut fill_size: u64 = size;
    if (fill_size > available) {
        fill_size = available;
    }

    let quote_amount: u64 = (resting_order.price * fill_size) / 1000000;
    require(quote_amount > 0);

    if (resting_order.side == 0) {
        // Resting order is a bid: taker sells base, receives quote
        // Taker sends base to base_vault; taker receives quote from quote_vault
        require(book_base_vault.ctx.key == book.base_vault);
        require(book_quote_vault.ctx.key == book.quote_vault);

        spl_token::SPLToken::transfer(taker_source, book_base_vault, taker, fill_size);
        spl_token::SPLToken::transfer(book_quote_vault, taker_destination, book_signer, quote_amount);
    } else {
        // Resting order is an ask: taker buys base, pays quote
        // Taker sends quote to quote_vault; taker receives base from base_vault
        require(book_base_vault.ctx.key == book.base_vault);
        require(book_quote_vault.ctx.key == book.quote_vault);

        spl_token::SPLToken::transfer(taker_source, book_quote_vault, taker, quote_amount);
        spl_token::SPLToken::transfer(book_base_vault, taker_destination, book_signer, fill_size);
    }

    resting_order.filled = resting_order.filled + fill_size;
    if (resting_order.filled == resting_order.size) {
        resting_order.is_active = false;
    }
}

// 9. Cancel an open order, refund locked tokens
pub cancel_order(
    book: OrderBook @mut @signer,
    order: Order @mut,
    trader: account @signer,
    vault: account @mut,
    user_token: account @mut,
    token_program: account
) {
    require(order.market == book.ctx.key);
    require(order.owner == trader.ctx.key);
    require(order.is_active);

    let remaining: u64 = order.size - order.filled;
    require(remaining > 0);

    let mut refund_amount: u64 = 0;
    if (order.side == 0) {
        // Bid: refund quote
        refund_amount = (order.price * remaining) / 1000000;
        require(vault.ctx.key == book.quote_vault);
    } else {
        // Ask: refund base
        refund_amount = remaining;
        require(vault.ctx.key == book.base_vault);
    }

    spl_token::SPLToken::transfer(vault, user_token, book, refund_amount);
    order.is_active = false;
}

// 10. Cancel all open orders for a user (cancels two orders per call; chain for more)
//     On-chain iteration is limited; the client calls repeatedly with batched orders.
pub cancel_all_orders(
    book: OrderBook @mut @signer,
    order_a: Order @mut,
    order_b: Order @mut,
    trader: account @signer,
    base_vault: account @mut,
    quote_vault: account @mut,
    user_base: account @mut,
    user_quote: account @mut,
    token_program: account
) {
    require(base_vault.ctx.key == book.base_vault);
    require(quote_vault.ctx.key == book.quote_vault);

    // Cancel order A
    if (order_a.is_active) {
        require(order_a.market == book.ctx.key);
        require(order_a.owner == trader.ctx.key);
        let remaining_a: u64 = order_a.size - order_a.filled;
        if (remaining_a > 0) {
            if (order_a.side == 0) {
                let refund_a: u64 = (order_a.price * remaining_a) / 1000000;
                spl_token::SPLToken::transfer(quote_vault, user_quote, book, refund_a);
            } else {
                spl_token::SPLToken::transfer(base_vault, user_base, book, remaining_a);
            }
        }
        order_a.is_active = false;
    }

    // Cancel order B
    if (order_b.is_active) {
        require(order_b.market == book.ctx.key);
        require(order_b.owner == trader.ctx.key);
        let remaining_b: u64 = order_b.size - order_b.filled;
        if (remaining_b > 0) {
            if (order_b.side == 0) {
                let refund_b: u64 = (order_b.price * remaining_b) / 1000000;
                spl_token::SPLToken::transfer(quote_vault, user_quote, book, refund_b);
            } else {
                spl_token::SPLToken::transfer(base_vault, user_base, book, remaining_b);
            }
        }
        order_b.is_active = false;
    }
}

// 11. Match crossing orders (crank): match a bid and ask, settle trade
pub match_orders(
    book: OrderBook @mut @signer,
    bid: Order @mut,
    ask: Order @mut,
    book_base_vault: account @mut,
    book_quote_vault: account @mut,
    token_program: account
) {
    require(book.is_active);
    require(bid.market == book.ctx.key);
    require(ask.market == book.ctx.key);
    require(bid.is_active);
    require(ask.is_active);
    require(bid.side == 0);
    require(ask.side == 1);

    // Price-time priority: bid price must be >= ask price for a match
    require(bid.price >= ask.price);

    // Fill at the resting (earlier) order's price -- price-time priority
    let mut fill_price: u64 = 0;
    if (bid.timestamp <= ask.timestamp) {
        fill_price = bid.price;
    } else {
        fill_price = ask.price;
    }

    let bid_remaining: u64 = bid.size - bid.filled;
    let ask_remaining: u64 = ask.size - ask.filled;

    let mut fill_size: u64 = bid_remaining;
    if (ask_remaining < fill_size) {
        fill_size = ask_remaining;
    }
    require(fill_size > 0);

    // Update fill amounts
    bid.filled = bid.filled + fill_size;
    ask.filled = ask.filled + fill_size;

    if (bid.filled == bid.size) {
        bid.is_active = false;
    }
    if (ask.filled == ask.size) {
        ask.is_active = false;
    }

    // Tokens are already locked in vaults from place_limit_order.
    // Matching just records the fills; settlement happens in settle_funds.
}

// 12. Settle matched trades: transfer tokens to users
pub settle_funds(
    book: OrderBook @mut @signer,
    order: Order @mut,
    trader: account @signer,
    book_base_vault: account @mut,
    book_quote_vault: account @mut,
    user_base: account @mut,
    user_quote: account @mut,
    token_program: account
) {
    require(order.market == book.ctx.key);
    require(order.owner == trader.ctx.key);
    require(order.filled > 0);
    require(book_base_vault.ctx.key == book.base_vault);
    require(book_quote_vault.ctx.key == book.quote_vault);

    // Settle entire filled amount
    let filled: u64 = order.filled;
    let quote_value: u64 = (order.price * filled) / 1000000;

    if (order.side == 0) {
        // Bid was filled: trader bought base, release base tokens to trader
        // Excess quote (if fill_price < bid_price) stays in vault (simplification)
        spl_token::SPLToken::transfer(book_base_vault, user_base, book, filled);
    } else {
        // Ask was filled: trader sold base, release quote tokens to trader
        spl_token::SPLToken::transfer(book_quote_vault, user_quote, book, quote_value);
    }

    // Reset filled to 0 after settlement
    order.filled = 0;
    if (!order.is_active) {
        // Fully filled and settled -- no-op, order stays inactive
    }
}

// =========================================================================
//  CONCENTRATED LIQUIDITY INSTRUCTIONS
// =========================================================================

// 13. Create a concentrated liquidity pool
pub create_concentrated_pool(
    cpool: ConcentratedPool @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint: pubkey,
    fee_numerator: u64,
    fee_denominator: u64,
    protocol_fee_numerator: u64,
    tick_spacing: u16,
    initial_sqrt_price: u128
) {
    require(fee_denominator > 0);
    require(fee_numerator < fee_denominator);
    require(protocol_fee_numerator <= fee_numerator);
    require(tick_spacing > 0);
    require(initial_sqrt_price > 0);

    cpool.token_a_mint = token_a_mint;
    cpool.token_b_mint = token_b_mint;
    cpool.token_a_vault = token_a_vault;
    cpool.token_b_vault = token_b_vault;
    cpool.lp_mint = lp_mint;
    cpool.reserve_a = 0;
    cpool.reserve_b = 0;
    cpool.lp_supply = 0;
    cpool.fee_numerator = fee_numerator;
    cpool.fee_denominator = fee_denominator;
    cpool.protocol_fee_numerator = protocol_fee_numerator;
    cpool.protocol_fees_a = 0;
    cpool.protocol_fees_b = 0;
    cpool.authority = creator.ctx.key;
    cpool.is_paused = false;
    cpool.tick_spacing = tick_spacing;
    cpool.sqrt_price = initial_sqrt_price;
    cpool.tick_current = 0;
    cpool.liquidity = 0;
}

// 14. Add concentrated liquidity in a price range [tick_lower, tick_upper]
pub add_concentrated_liquidity(
    cpool: ConcentratedPool @mut @signer,
    position: ConcentratedPosition @mut @init(payer=provider, space=512) @signer,
    provider: account @mut @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    token_program: account,
    tick_lower: i64,
    tick_upper: i64,
    liquidity_amount: u128,
    max_amount_a: u64,
    max_amount_b: u64
) {
    require(!cpool.is_paused);
    require(tick_lower < tick_upper);
    require(liquidity_amount > 0);
    require(pool_token_a_vault.ctx.key == cpool.token_a_vault);
    require(pool_token_b_vault.ctx.key == cpool.token_b_vault);

    // Tick alignment
    require(tick_lower % cpool.tick_spacing as i64 == 0);
    require(tick_upper % cpool.tick_spacing as i64 == 0);

    // Compute token amounts needed based on current tick vs position range
    // Simplified model: if current tick is within range, need both tokens;
    // if below range, only token A; if above range, only token B.
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (cpool.tick_current < tick_lower) {
        // Current price below range: position is entirely token A
        amount_a = liquidity_amount as u64;
        amount_b = 0;
    } else {
        if (cpool.tick_current >= tick_upper) {
            // Current price above range: position is entirely token B
            amount_a = 0;
            amount_b = liquidity_amount as u64;
        } else {
            // Current price within range: need proportional amounts
            // Simplified: split liquidity proportionally by tick position
            let range: u64 = (tick_upper - tick_lower) as u64;
            let lower_portion: u64 = (cpool.tick_current - tick_lower) as u64;
            let upper_portion: u64 = (tick_upper - cpool.tick_current) as u64;
            amount_a = (liquidity_amount as u64 * upper_portion) / range;
            amount_b = (liquidity_amount as u64 * lower_portion) / range;
        }
    }

    require(amount_a <= max_amount_a);
    require(amount_b <= max_amount_b);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, pool_token_a_vault, provider, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, pool_token_b_vault, provider, amount_b);
    }

    position.pool = cpool.ctx.key;
    position.owner = provider.ctx.key;
    position.tick_lower = tick_lower;
    position.tick_upper = tick_upper;
    position.liquidity = liquidity_amount;
    position.fees_owed_a = 0;
    position.fees_owed_b = 0;

    cpool.reserve_a = cpool.reserve_a + amount_a;
    cpool.reserve_b = cpool.reserve_b + amount_b;

    // Add liquidity to pool if current tick is within position range
    if (cpool.tick_current >= tick_lower) {
        if (cpool.tick_current < tick_upper) {
            cpool.liquidity = cpool.liquidity + liquidity_amount;
        }
    }
}

// 15. Remove concentrated liquidity from a position
pub remove_concentrated_liquidity(
    cpool: ConcentratedPool @mut @signer,
    position: ConcentratedPosition @mut,
    owner: account @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    token_program: account,
    liquidity_to_remove: u128,
    min_amount_a: u64,
    min_amount_b: u64
) {
    // Withdrawals allowed even when paused (user safety)
    require(position.pool == cpool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(liquidity_to_remove > 0);
    require(liquidity_to_remove <= position.liquidity);
    require(pool_token_a_vault.ctx.key == cpool.token_a_vault);
    require(pool_token_b_vault.ctx.key == cpool.token_b_vault);

    // Compute token amounts to return (mirrors add logic)
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (cpool.tick_current < position.tick_lower) {
        amount_a = liquidity_to_remove as u64;
        amount_b = 0;
    } else {
        if (cpool.tick_current >= position.tick_upper) {
            amount_a = 0;
            amount_b = liquidity_to_remove as u64;
        } else {
            let range: u64 = (position.tick_upper - position.tick_lower) as u64;
            let lower_portion: u64 = (cpool.tick_current - position.tick_lower) as u64;
            let upper_portion: u64 = (position.tick_upper - cpool.tick_current) as u64;
            amount_a = (liquidity_to_remove as u64 * upper_portion) / range;
            amount_b = (liquidity_to_remove as u64 * lower_portion) / range;
        }
    }

    // Include accrued fees
    let fee_a: u64 = (position.fees_owed_a * liquidity_to_remove as u64) / position.liquidity as u64;
    let fee_b: u64 = (position.fees_owed_b * liquidity_to_remove as u64) / position.liquidity as u64;
    amount_a = amount_a + fee_a;
    amount_b = amount_b + fee_b;

    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, user_token_a, cpool, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, user_token_b, cpool, amount_b);
    }

    position.liquidity = position.liquidity - liquidity_to_remove;
    position.fees_owed_a = position.fees_owed_a - fee_a;
    position.fees_owed_b = position.fees_owed_b - fee_b;

    if (cpool.reserve_a >= amount_a) {
        cpool.reserve_a = cpool.reserve_a - amount_a;
    } else {
        cpool.reserve_a = 0;
    }
    if (cpool.reserve_b >= amount_b) {
        cpool.reserve_b = cpool.reserve_b - amount_b;
    } else {
        cpool.reserve_b = 0;
    }

    // Remove liquidity from pool if current tick is within position range
    if (cpool.tick_current >= position.tick_lower) {
        if (cpool.tick_current < position.tick_upper) {
            if (cpool.liquidity >= liquidity_to_remove) {
                cpool.liquidity = cpool.liquidity - liquidity_to_remove;
            } else {
                cpool.liquidity = 0;
            }
        }
    }
}

// 16. Swap through concentrated liquidity
pub concentrated_swap(
    cpool: ConcentratedPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    is_a_to_b: bool
) {
    require(!cpool.is_paused);
    require(amount_in > 0);
    require(cpool.liquidity > 0);

    if (is_a_to_b) {
        require(pool_token_a_vault.ctx.key == cpool.token_a_vault);
        require(pool_token_b_vault.ctx.key == cpool.token_b_vault);
    } else {
        require(pool_token_a_vault.ctx.key == cpool.token_b_vault);
        require(pool_token_b_vault.ctx.key == cpool.token_a_vault);
    }

    // Fee calculation
    let total_fee: u64 = calc_fee(amount_in, cpool.fee_numerator, cpool.fee_denominator);
    let protocol_fee: u64 = calc_fee(amount_in, cpool.protocol_fee_numerator, cpool.fee_denominator);
    let dx_after_fee: u64 = amount_in - total_fee;

    // Concentrated liquidity swap: amount_out = (L * dx) / (sqrt_p * (L + dx * sqrt_p))
    // Simplified to constant-product within active tick range:
    // amount_out = (reserve_out * dx) / (reserve_in + dx)
    let mut amount_out: u64 = 0;

    if (is_a_to_b) {
        require(cpool.reserve_b > 0);
        amount_out = (cpool.reserve_b * dx_after_fee) / (cpool.reserve_a + dx_after_fee);
    } else {
        require(cpool.reserve_a > 0);
        amount_out = (cpool.reserve_a * dx_after_fee) / (cpool.reserve_b + dx_after_fee);
    }

    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    spl_token::SPLToken::transfer(user_source, pool_token_a_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_token_b_vault, user_destination, cpool, amount_out);

    if (is_a_to_b) {
        cpool.reserve_a = cpool.reserve_a + amount_in - protocol_fee;
        cpool.reserve_b = cpool.reserve_b - amount_out;
        cpool.protocol_fees_a = cpool.protocol_fees_a + protocol_fee;
    } else {
        cpool.reserve_b = cpool.reserve_b + amount_in - protocol_fee;
        cpool.reserve_a = cpool.reserve_a - amount_out;
        cpool.protocol_fees_b = cpool.protocol_fees_b + protocol_fee;
    }

    // Update sqrt_price based on new reserves (simplified)
    // sqrt_price ~= sqrt(reserve_b / reserve_a) * 2^64
    // Approximation: shift proportionally by trade impact
    if (is_a_to_b) {
        // Price of A in terms of B decreased (more A, less B)
        if (cpool.reserve_a > 0) {
            cpool.sqrt_price = (cpool.sqrt_price * cpool.reserve_b as u128) / (cpool.reserve_b as u128 + amount_out as u128);
        }
    } else {
        // Price of A in terms of B increased (less A, more B)
        if (cpool.reserve_b > 0) {
            cpool.sqrt_price = (cpool.sqrt_price * (cpool.reserve_a as u128 + amount_out as u128)) / cpool.reserve_a as u128;
        }
    }
}

// =========================================================================
//  FARMING / REWARDS INSTRUCTIONS
// =========================================================================

// 17. Create a yield farm for an LP token
pub create_farm(
    farm: Farm @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    pool_mint: pubkey,
    reward_mint: pubkey,
    reward_vault: pubkey,
    reward_per_second: u64
) {
    require(reward_per_second > 0);

    farm.pool_mint = pool_mint;
    farm.reward_mint = reward_mint;
    farm.reward_vault = reward_vault;
    farm.reward_per_second = reward_per_second;
    farm.total_staked = 0;
    farm.accumulated_reward_per_share = 0;
    farm.last_update = get_clock().unix_timestamp as u64;
    farm.authority = creator.ctx.key;
}

// 18. Stake LP tokens to earn rewards
pub stake_lp(
    farm: Farm @mut,
    record: StakeRecord @mut @init(payer=staker, space=512) @signer,
    staker: account @mut @signer,
    user_lp_account: account @mut,
    farm_lp_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(amount > 0);

    let now: u64 = get_clock().unix_timestamp as u64;

    // Update global reward accumulator
    let new_acc: u128 = update_farm_rewards(farm, now);
    farm.accumulated_reward_per_share = new_acc;
    farm.last_update = now;

    // Transfer LP tokens to farm
    spl_token::SPLToken::transfer(user_lp_account, farm_lp_vault, staker, amount);

    record.farm = farm.ctx.key;
    record.owner = staker.ctx.key;
    record.staked_amount = amount;
    record.reward_debt = (amount as u128 * farm.accumulated_reward_per_share) / reward_precision();
    record.pending_rewards = 0;

    farm.total_staked = farm.total_staked + amount;
}

// 19. Unstake LP tokens
pub unstake_lp(
    farm: Farm @mut @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    user_lp_account: account @mut,
    farm_lp_vault: account @mut,
    reward_vault: account @mut,
    user_reward_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(record.farm == farm.ctx.key);
    require(record.owner == owner.ctx.key);
    require(amount > 0);
    require(amount <= record.staked_amount);

    let now: u64 = get_clock().unix_timestamp as u64;

    // Update global reward accumulator
    let new_acc: u128 = update_farm_rewards(farm, now);
    farm.accumulated_reward_per_share = new_acc;
    farm.last_update = now;

    // Calculate and distribute pending rewards before unstaking
    let pending: u64 = compute_pending(record.staked_amount, farm.accumulated_reward_per_share, record.reward_debt);
    let total_pending: u64 = pending + record.pending_rewards;

    if (total_pending > 0) {
        spl_token::SPLToken::transfer(reward_vault, user_reward_account, farm, total_pending);
    }

    // Return staked LP tokens
    spl_token::SPLToken::transfer(farm_lp_vault, user_lp_account, farm, amount);

    record.staked_amount = record.staked_amount - amount;
    record.reward_debt = (record.staked_amount as u128 * farm.accumulated_reward_per_share) / reward_precision();
    record.pending_rewards = 0;

    farm.total_staked = farm.total_staked - amount;
}

// 20. Claim accumulated farming rewards (without unstaking)
pub claim_rewards(
    farm: Farm @mut @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    reward_vault: account @mut,
    user_reward_account: account @mut,
    token_program: account
) {
    require(record.farm == farm.ctx.key);
    require(record.owner == owner.ctx.key);
    require(record.staked_amount > 0);

    let now: u64 = get_clock().unix_timestamp as u64;

    // Update global reward accumulator
    let new_acc: u128 = update_farm_rewards(farm, now);
    farm.accumulated_reward_per_share = new_acc;
    farm.last_update = now;

    // Calculate pending rewards
    let pending: u64 = compute_pending(record.staked_amount, farm.accumulated_reward_per_share, record.reward_debt);
    let total_pending: u64 = pending + record.pending_rewards;

    require(total_pending > 0);

    spl_token::SPLToken::transfer(reward_vault, user_reward_account, farm, total_pending);

    record.reward_debt = (record.staked_amount as u128 * farm.accumulated_reward_per_share) / reward_precision();
    record.pending_rewards = 0;
}

// 21. Admin: add rewards to farm vault
pub update_rewards(
    farm: Farm @mut,
    admin: account @signer,
    admin_reward_account: account @mut,
    reward_vault: account @mut,
    token_program: account,
    amount: u64,
    new_reward_per_second: u64
) {
    require(farm.authority == admin.ctx.key);
    require(amount > 0);
    require(reward_vault.ctx.key == farm.reward_vault);

    let now: u64 = get_clock().unix_timestamp as u64;

    // Update accumulator before changing rate
    let new_acc: u128 = update_farm_rewards(farm, now);
    farm.accumulated_reward_per_share = new_acc;
    farm.last_update = now;

    // Transfer new reward tokens to vault
    spl_token::SPLToken::transfer(admin_reward_account, reward_vault, admin, amount);

    // Update emission rate
    if (new_reward_per_second > 0) {
        farm.reward_per_second = new_reward_per_second;
    }
}

// =========================================================================
//  ADMIN INSTRUCTIONS
// =========================================================================

// 22. Update AMM pool fee rates
pub set_pool_fees(
    pool: AmmPool @mut,
    authority: account @signer,
    new_fee_numerator: u64,
    new_protocol_fee_numerator: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_fee_numerator < pool.fee_denominator);
    require(new_protocol_fee_numerator <= new_fee_numerator);

    pool.fee_numerator = new_fee_numerator;
    pool.protocol_fee_numerator = new_protocol_fee_numerator;
}

// Set concentrated pool fee rates
pub set_concentrated_pool_fees(
    cpool: ConcentratedPool @mut,
    authority: account @signer,
    new_fee_numerator: u64,
    new_protocol_fee_numerator: u64
) {
    require(cpool.authority == authority.ctx.key);
    require(new_fee_numerator < cpool.fee_denominator);
    require(new_protocol_fee_numerator <= new_fee_numerator);

    cpool.fee_numerator = new_fee_numerator;
    cpool.protocol_fee_numerator = new_protocol_fee_numerator;
}

// 23. Transfer admin authority (AMM pool)
pub set_pool_authority(
    pool: AmmPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

// Transfer admin authority (order book)
pub set_market_authority(
    book: OrderBook @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(book.authority == authority.ctx.key);
    book.authority = new_authority;
}

// Transfer admin authority (concentrated pool)
pub set_concentrated_pool_authority(
    cpool: ConcentratedPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(cpool.authority == authority.ctx.key);
    cpool.authority = new_authority;
}

// Transfer admin authority (farm)
pub set_farm_authority(
    farm: Farm @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(farm.authority == authority.ctx.key);
    farm.authority = new_authority;
}

// 24. Pause / unpause AMM pool
pub set_pool_paused(
    pool: AmmPool @mut,
    authority: account @signer,
    paused: bool
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = paused;
}

// Pause / unpause concentrated pool
pub set_concentrated_pool_paused(
    cpool: ConcentratedPool @mut,
    authority: account @signer,
    paused: bool
) {
    require(cpool.authority == authority.ctx.key);
    cpool.is_paused = paused;
}

// Activate / deactivate order book market
pub set_market_active(
    book: OrderBook @mut,
    authority: account @signer,
    active: bool
) {
    require(book.authority == authority.ctx.key);
    book.is_active = active;
}

// Collect protocol fees from AMM pool
pub collect_protocol_fees(
    pool: AmmPool @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);

    let fees_a: u64 = pool.protocol_fees_a;
    let fees_b: u64 = pool.protocol_fees_b;

    if (fees_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, pool, fees_a);
        pool.reserve_a = pool.reserve_a - fees_a;
        pool.protocol_fees_a = 0;
    }
    if (fees_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, pool, fees_b);
        pool.reserve_b = pool.reserve_b - fees_b;
        pool.protocol_fees_b = 0;
    }
}

// Collect protocol fees from concentrated pool
pub collect_concentrated_protocol_fees(
    cpool: ConcentratedPool @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(cpool.authority == authority.ctx.key);
    require(pool_token_a_vault.ctx.key == cpool.token_a_vault);
    require(pool_token_b_vault.ctx.key == cpool.token_b_vault);

    let fees_a: u64 = cpool.protocol_fees_a;
    let fees_b: u64 = cpool.protocol_fees_b;

    if (fees_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, cpool, fees_a);
        cpool.reserve_a = cpool.reserve_a - fees_a;
        cpool.protocol_fees_a = 0;
    }
    if (fees_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, cpool, fees_b);
        cpool.reserve_b = cpool.reserve_b - fees_b;
        cpool.protocol_fees_b = 0;
    }
}

// =========================================================================
//  VIEW / QUERY HELPERS
// =========================================================================

pub get_pool_reserves_a(pool: AmmPool) -> u64 {
    return pool.reserve_a;
}

pub get_pool_reserves_b(pool: AmmPool) -> u64 {
    return pool.reserve_b;
}

pub get_pool_lp_supply(pool: AmmPool) -> u64 {
    return pool.lp_supply;
}

pub get_concentrated_liquidity(cpool: ConcentratedPool) -> u128 {
    return cpool.liquidity;
}

pub get_concentrated_sqrt_price(cpool: ConcentratedPool) -> u128 {
    return cpool.sqrt_price;
}

pub get_farm_total_staked(farm: Farm) -> u64 {
    return farm.total_staked;
}

pub get_farm_reward_rate(farm: Farm) -> u64 {
    return farm.reward_per_second;
}

pub get_stake_amount(record: StakeRecord) -> u64 {
    return record.staked_amount;
}

pub get_order_status(order: Order) -> u8 {
    if (order.is_active) {
        return 1;
    }
    return 0;
}

pub get_order_remaining(order: Order) -> u64 {
    if (!order.is_active) {
        return 0;
    }
    return order.size - order.filled;
}
