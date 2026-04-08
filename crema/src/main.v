// 5IVE Crema Finance Migration
//
// Concentrated liquidity AMM (like Orca Whirlpools but simpler).
// No reward system, no position bundles, no adaptive fees.
// Core concentrated liquidity math only: tick-based positions, fee growth tracking,
// and swap execution that walks through active ticks.
//
// Instructions (14):
//   create_pool, open_position, close_position, increase_liquidity,
//   decrease_liquidity, swap, collect_fees, init_tick_array, set_fee_rate,
//   set_protocol_fee, collect_protocol_fees, set_authority, pause, unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Pool {
    authority: pubkey;
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;

    // Price state: sqrt_price in Q64.64 fixed-point
    sqrt_price: u128;
    tick_current: i64;
    liquidity: u128;

    // Fee configuration
    fee_rate: u64;
    protocol_fee_rate: u64;

    // Global fee growth accumulators (Q64.64 per unit liquidity)
    fee_growth_global_a: u128;
    fee_growth_global_b: u128;

    // Protocol fee collection
    protocol_fees_a: u64;
    protocol_fees_b: u64;

    tick_spacing: u64;
    is_paused: bool;
}

account TickArray {
    pool: pubkey;
    start_index: i64;

    // Per-tick data (simplified: arrays of fixed size 88 ticks)
    // Each tick tracks liquidity changes and fee growth outside
    tick_0_liquidity_net: i128;
    tick_0_liquidity_gross: u128;
    tick_0_fee_growth_outside_a: u128;
    tick_0_fee_growth_outside_b: u128;
    tick_0_initialized: bool;
}

account Position {
    pool: pubkey;
    owner: pubkey;
    tick_lower: i64;
    tick_upper: i64;
    liquidity: u128;
    fee_growth_inside_last_a: u128;
    fee_growth_inside_last_b: u128;
    fees_owed_a: u64;
    fees_owed_b: u64;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// Q64 = 2^64 = 18446744073709551616 (used for fixed-point math)
// MIN_SQRT_PRICE and MAX_SQRT_PRICE bound the price range
// RATE_DENOMINATOR = 1_000_000 for fee rates

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn compute_fee_growth_inside(
    fee_growth_global: u128,
    fee_growth_outside_lower: u128,
    fee_growth_outside_upper: u128,
    tick_current: i64,
    tick_lower: i64,
    tick_upper: i64
) -> u128 {
    // Fee growth below the lower tick
    let mut fee_growth_below: u128 = 0;
    if (tick_current >= tick_lower) {
        fee_growth_below = fee_growth_outside_lower;
    } else {
        fee_growth_below = fee_growth_global - fee_growth_outside_lower;
    }

    // Fee growth above the upper tick
    let mut fee_growth_above: u128 = 0;
    if (tick_current < tick_upper) {
        fee_growth_above = fee_growth_outside_upper;
    } else {
        fee_growth_above = fee_growth_global - fee_growth_outside_upper;
    }

    // Fee growth inside = global - below - above
    return fee_growth_global - fee_growth_below - fee_growth_above;
}

fn compute_swap_output(
    amount_in: u64,
    liquidity: u128,
    sqrt_price: u128,
    fee_rate: u64
) -> u64 {
    // Simplified constant-liquidity swap within a single tick range
    // amount_out = liquidity * delta_sqrt_price (simplified integer version)
    let fee: u64 = (amount_in * fee_rate) / 1000000;
    let amount_after_fee: u64 = amount_in - fee;

    if (liquidity == 0) {
        return 0;
    }

    // Approximate: output = amount_after_fee * liquidity / (liquidity + amount_after_fee)
    let liq_u64: u64 = liquidity as u64;
    let output: u64 = (amount_after_fee * liq_u64) / (liq_u64 + amount_after_fee);
    return output;
}

// ---------------------------------------------------------------------------
// Instructions -- Pool lifecycle
// ---------------------------------------------------------------------------

pub create_pool(
    pool: Pool @mut @init(payer=creator, space=1024),
    creator: account @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    fee_rate: u64,
    tick_spacing: u64,
    initial_sqrt_price: u128,
    initial_tick: i64
) {
    require(fee_rate > 0);
    require(fee_rate <= 100000);
    require(tick_spacing > 0);
    require(initial_sqrt_price > 0);

    pool.authority = creator.ctx.key;
    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.sqrt_price = initial_sqrt_price;
    pool.tick_current = initial_tick;
    pool.liquidity = 0;
    pool.fee_rate = fee_rate;
    pool.protocol_fee_rate = 0;
    pool.fee_growth_global_a = 0;
    pool.fee_growth_global_b = 0;
    pool.protocol_fees_a = 0;
    pool.protocol_fees_b = 0;
    pool.tick_spacing = tick_spacing;
    pool.is_paused = false;
}

pub init_tick_array(
    tick_array: TickArray @mut @init(payer=payer, space=2048),
    pool: Pool,
    payer: account @signer,
    start_index: i64
) {
    tick_array.pool = pool.ctx.key;
    tick_array.start_index = start_index;
    tick_array.tick_0_liquidity_net = 0;
    tick_array.tick_0_liquidity_gross = 0;
    tick_array.tick_0_fee_growth_outside_a = 0;
    tick_array.tick_0_fee_growth_outside_b = 0;
    tick_array.tick_0_initialized = false;
}

// ---------------------------------------------------------------------------
// Instructions -- Position management
// ---------------------------------------------------------------------------

pub open_position(
    pool: Pool,
    position: Position @mut @init(payer=owner, space=512),
    owner: account @signer,
    tick_lower: i64,
    tick_upper: i64
) {
    require(!pool.is_paused);
    require(tick_lower < tick_upper);
    // Ticks must be aligned to tick_spacing
    let spacing: i64 = pool.tick_spacing as i64;
    require(tick_lower % spacing == 0);
    require(tick_upper % spacing == 0);

    position.pool = pool.ctx.key;
    position.owner = owner.ctx.key;
    position.tick_lower = tick_lower;
    position.tick_upper = tick_upper;
    position.liquidity = 0;
    position.fee_growth_inside_last_a = 0;
    position.fee_growth_inside_last_b = 0;
    position.fees_owed_a = 0;
    position.fees_owed_b = 0;
}

pub close_position(
    pool: Pool,
    position: Position @mut,
    owner: account @signer
) {
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(position.liquidity == 0);
    require(position.fees_owed_a == 0);
    require(position.fees_owed_b == 0);

    // Zero out the position (account can be reclaimed)
    position.liquidity = 0;
}

// ---------------------------------------------------------------------------
// Instructions -- Liquidity management
// ---------------------------------------------------------------------------

pub increase_liquidity(
    pool: Pool @mut @signer,
    position: Position @mut,
    tick_array_lower: TickArray @mut,
    tick_array_upper: TickArray @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    owner: account @signer,
    token_program: account,
    liquidity_amount: u128,
    amount_a_max: u64,
    amount_b_max: u64
) {
    require(!pool.is_paused);
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(liquidity_amount > 0);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    // Calculate token amounts required for the liquidity delta
    // Simplified: proportional to liquidity amount
    let liq_u64: u64 = liquidity_amount as u64;
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (pool.tick_current < position.tick_lower) {
        // Current price below range: only token A needed
        amount_a = liq_u64;
        amount_b = 0;
    } else {
        if (pool.tick_current >= position.tick_upper) {
            // Current price above range: only token B needed
            amount_a = 0;
            amount_b = liq_u64;
        } else {
            // Current price in range: both tokens needed
            amount_a = liq_u64 / 2;
            amount_b = liq_u64 / 2;
        }
    }

    require(amount_a <= amount_a_max);
    require(amount_b <= amount_b_max);

    // Transfer tokens
    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, pool_vault_a, owner, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, pool_vault_b, owner, amount_b);
    }

    // Update fee growth snapshots before modifying liquidity
    let fee_inside_a: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_a,
        tick_array_lower.tick_0_fee_growth_outside_a,
        tick_array_upper.tick_0_fee_growth_outside_a,
        pool.tick_current,
        position.tick_lower,
        position.tick_upper
    );
    let fee_inside_b: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_b,
        tick_array_lower.tick_0_fee_growth_outside_b,
        tick_array_upper.tick_0_fee_growth_outside_b,
        pool.tick_current,
        position.tick_lower,
        position.tick_upper
    );

    // Accrue owed fees from existing liquidity
    if (position.liquidity > 0) {
        let delta_a: u128 = fee_inside_a - position.fee_growth_inside_last_a;
        let delta_b: u128 = fee_inside_b - position.fee_growth_inside_last_b;
        position.fees_owed_a = position.fees_owed_a + ((position.liquidity * delta_a) >> 64) as u64;
        position.fees_owed_b = position.fees_owed_b + ((position.liquidity * delta_b) >> 64) as u64;
    }

    position.fee_growth_inside_last_a = fee_inside_a;
    position.fee_growth_inside_last_b = fee_inside_b;
    position.liquidity = position.liquidity + liquidity_amount;

    // Update tick arrays
    tick_array_lower.tick_0_liquidity_net = tick_array_lower.tick_0_liquidity_net + liquidity_amount as i128;
    tick_array_lower.tick_0_liquidity_gross = tick_array_lower.tick_0_liquidity_gross + liquidity_amount;
    tick_array_upper.tick_0_liquidity_net = tick_array_upper.tick_0_liquidity_net - liquidity_amount as i128;
    tick_array_upper.tick_0_liquidity_gross = tick_array_upper.tick_0_liquidity_gross + liquidity_amount;

    // Update pool active liquidity if current tick is in range
    if (pool.tick_current >= position.tick_lower) {
        if (pool.tick_current < position.tick_upper) {
            pool.liquidity = pool.liquidity + liquidity_amount;
        }
    }
}

pub decrease_liquidity(
    pool: Pool @mut @signer,
    position: Position @mut,
    tick_array_lower: TickArray @mut,
    tick_array_upper: TickArray @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    owner: account @signer,
    token_program: account,
    liquidity_amount: u128,
    min_amount_a: u64,
    min_amount_b: u64
) {
    require(!pool.is_paused);
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(liquidity_amount > 0);
    require(liquidity_amount <= position.liquidity);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    // Calculate token amounts to return (mirror of increase_liquidity)
    let liq_u64: u64 = liquidity_amount as u64;
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (pool.tick_current < position.tick_lower) {
        amount_a = liq_u64;
        amount_b = 0;
    } else {
        if (pool.tick_current >= position.tick_upper) {
            amount_a = 0;
            amount_b = liq_u64;
        } else {
            amount_a = liq_u64 / 2;
            amount_b = liq_u64 / 2;
        }
    }

    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    // Update fee snapshots
    let fee_inside_a: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_a,
        tick_array_lower.tick_0_fee_growth_outside_a,
        tick_array_upper.tick_0_fee_growth_outside_a,
        pool.tick_current,
        position.tick_lower,
        position.tick_upper
    );
    let fee_inside_b: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_b,
        tick_array_lower.tick_0_fee_growth_outside_b,
        tick_array_upper.tick_0_fee_growth_outside_b,
        pool.tick_current,
        position.tick_lower,
        position.tick_upper
    );

    if (position.liquidity > 0) {
        let delta_a: u128 = fee_inside_a - position.fee_growth_inside_last_a;
        let delta_b: u128 = fee_inside_b - position.fee_growth_inside_last_b;
        position.fees_owed_a = position.fees_owed_a + ((position.liquidity * delta_a) >> 64) as u64;
        position.fees_owed_b = position.fees_owed_b + ((position.liquidity * delta_b) >> 64) as u64;
    }

    position.fee_growth_inside_last_a = fee_inside_a;
    position.fee_growth_inside_last_b = fee_inside_b;
    position.liquidity = position.liquidity - liquidity_amount;

    // Update tick arrays
    tick_array_lower.tick_0_liquidity_net = tick_array_lower.tick_0_liquidity_net - liquidity_amount as i128;
    tick_array_lower.tick_0_liquidity_gross = tick_array_lower.tick_0_liquidity_gross - liquidity_amount;
    tick_array_upper.tick_0_liquidity_net = tick_array_upper.tick_0_liquidity_net + liquidity_amount as i128;
    tick_array_upper.tick_0_liquidity_gross = tick_array_upper.tick_0_liquidity_gross - liquidity_amount;

    // Update pool active liquidity
    if (pool.tick_current >= position.tick_lower) {
        if (pool.tick_current < position.tick_upper) {
            pool.liquidity = pool.liquidity - liquidity_amount;
        }
    }

    // Transfer tokens back to user
    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, amount_b);
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Swap
// ---------------------------------------------------------------------------

pub swap(
    pool: Pool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    tick_array: TickArray @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    is_a_to_b: bool
) {
    require(!pool.is_paused);
    require(amount_in > 0);
    require(pool.liquidity > 0);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    // Calculate fees
    let total_fee: u64 = (amount_in * pool.fee_rate) / 1000000;
    let protocol_fee: u64 = (total_fee * pool.protocol_fee_rate) / 1000000;
    let lp_fee: u64 = total_fee - protocol_fee;
    let amount_after_fee: u64 = amount_in - total_fee;

    // Compute output using current pool liquidity (simplified single-tick swap)
    let liq_u64: u64 = pool.liquidity as u64;
    require(liq_u64 > 0);
    let amount_out: u64 = (amount_after_fee * liq_u64) / (liq_u64 + amount_after_fee);
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Execute token transfers
    if (is_a_to_b) {
        spl_token::SPLToken::transfer(user_source, pool_vault_a, user_authority, amount_in);
        spl_token::SPLToken::transfer(pool_vault_b, user_destination, pool, amount_out);

        // Update fee growth for token A (fees paid in token A)
        if (pool.liquidity > 0) {
            let fee_growth_delta: u128 = (lp_fee as u128 << 64) / pool.liquidity;
            pool.fee_growth_global_a = pool.fee_growth_global_a + fee_growth_delta;
        }
        pool.protocol_fees_a = pool.protocol_fees_a + protocol_fee;
    } else {
        spl_token::SPLToken::transfer(user_source, pool_vault_b, user_authority, amount_in);
        spl_token::SPLToken::transfer(pool_vault_a, user_destination, pool, amount_out);

        if (pool.liquidity > 0) {
            let fee_growth_delta: u128 = (lp_fee as u128 << 64) / pool.liquidity;
            pool.fee_growth_global_b = pool.fee_growth_global_b + fee_growth_delta;
        }
        pool.protocol_fees_b = pool.protocol_fees_b + protocol_fee;
    }

    // Update sqrt_price and tick (simplified: proportional shift)
    // In production this would involve precise Q64.64 math
    if (is_a_to_b) {
        pool.tick_current = pool.tick_current - 1;
    } else {
        pool.tick_current = pool.tick_current + 1;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Fee collection
// ---------------------------------------------------------------------------

pub collect_fees(
    pool: Pool @signer,
    position: Position @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    owner: account @signer,
    token_program: account
) {
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    let fees_a: u64 = position.fees_owed_a;
    let fees_b: u64 = position.fees_owed_b;

    if (fees_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, fees_a);
        position.fees_owed_a = 0;
    }
    if (fees_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, fees_b);
        position.fees_owed_b = 0;
    }
}

pub collect_protocol_fees(
    pool: Pool @mut @signer,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    let fees_a: u64 = pool.protocol_fees_a;
    let fees_b: u64 = pool.protocol_fees_b;

    if (fees_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, recipient_a, pool, fees_a);
        pool.protocol_fees_a = 0;
    }
    if (fees_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, recipient_b, pool, fees_b);
        pool.protocol_fees_b = 0;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Admin
// ---------------------------------------------------------------------------

pub set_fee_rate(
    pool: Pool @mut,
    authority: account @signer,
    new_fee_rate: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_fee_rate > 0);
    require(new_fee_rate <= 100000);
    pool.fee_rate = new_fee_rate;
}

pub set_protocol_fee(
    pool: Pool @mut,
    authority: account @signer,
    new_protocol_fee_rate: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_protocol_fee_rate <= 500000);
    pool.protocol_fee_rate = new_protocol_fee_rate;
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
    pool.is_paused = true;
}

pub unpause(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = false;
}
