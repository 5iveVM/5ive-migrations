// Raydium AMM v4 -- Migrated to 5ive DSL
//
// Faithful reproduction of Raydium's constant-product AMM (x*y=k) with:
//   - Dual fee structure: LP fees retained in reserves, protocol PnL tracked separately
//   - Open-time gating: swaps blocked until pool.open_time
//   - Configurable parameters: fee rates, min/max trade size, trade limits
//   - Two swap variants: base_in (fixed input) and base_out (fixed output)
//   - Protocol PnL extraction by admin
//   - Emergency pause/unpause controls
//   - Authority transfer
//
// Original: ~6,000 SLoC Rust/Anchor
// 5ive:     ~350 SLoC

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account AmmPool {
    // Token configuration
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;

    // Reserves (LP-owned liquidity -- excludes accumulated PnL)
    reserve_a: u64;
    reserve_b: u64;
    lp_supply: u64;

    // Fee configuration
    // trade_fee = amount * trade_fee_numerator / trade_fee_denominator
    trade_fee_numerator: u64;
    trade_fee_denominator: u64;

    // pnl_fee is the protocol's cut of the trade_fee
    // pnl_fee = trade_fee * pnl_fee_numerator / pnl_fee_denominator
    pnl_fee_numerator: u64;
    pnl_fee_denominator: u64;

    // Accumulated protocol PnL (withdrawable by admin)
    pnl_token_a: u64;
    pnl_token_b: u64;

    // Trade size limits
    min_trade_amount: u64;
    max_trade_amount: u64;

    // Pool governance
    authority: pubkey;
    open_time: i64;
    status: u8;      // 0 = active, 1 = paused, 2 = disabled
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Calculate trade fee: (amount * numerator) / denominator
fn calc_trade_fee(amount: u64, numerator: u64, denominator: u64) -> u64 {
    if (denominator == 0) {
        return 0;
    }
    return (amount * numerator) / denominator;
}

// Calculate protocol PnL portion of a trade fee
fn calc_pnl_fee(trade_fee: u64, pnl_numerator: u64, pnl_denominator: u64) -> u64 {
    if (pnl_denominator == 0) {
        return 0;
    }
    return (trade_fee * pnl_numerator) / pnl_denominator;
}

// Ceiling division: (a + b - 1) / b -- ensures pool never loses value on base_out swaps
fn ceil_div(a: u64, b: u64) -> u64 {
    require(b > 0);
    return (a + b - 1) / b;
}

// Minimum of two u64 values
fn min_u64(a: u64, b: u64) -> u64 {
    if (a < b) {
        return a;
    }
    return b;
}

// ---------------------------------------------------------------------------
// Instruction 1: initialize
// Create a new AMM pool with token pair, fees, open_time, and initial liquidity
// ---------------------------------------------------------------------------

pub initialize(
    pool: AmmPool @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    token_program: account,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint_key: pubkey,
    trade_fee_numerator: u64,
    trade_fee_denominator: u64,
    pnl_fee_numerator: u64,
    pnl_fee_denominator: u64,
    open_time: i64,
    initial_amount_a: u64,
    initial_amount_b: u64,
    min_trade_amount: u64,
    max_trade_amount: u64
) {
    // Validate fee configuration
    require(trade_fee_denominator > 0);
    require(trade_fee_numerator < trade_fee_denominator);
    require(pnl_fee_denominator > 0);
    require(pnl_fee_numerator <= pnl_fee_denominator);

    // Validate initial liquidity
    require(initial_amount_a > 0);
    require(initial_amount_b > 0);

    // Validate trade limits
    require(max_trade_amount > min_trade_amount);

    // Validate vault accounts match
    require(pool_vault_a.ctx.key == token_a_vault);
    require(pool_vault_b.ctx.key == token_b_vault);
    require(lp_mint.ctx.key == lp_mint_key);

    // Initialize pool state
    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.lp_mint = lp_mint_key;

    pool.trade_fee_numerator = trade_fee_numerator;
    pool.trade_fee_denominator = trade_fee_denominator;
    pool.pnl_fee_numerator = pnl_fee_numerator;
    pool.pnl_fee_denominator = pnl_fee_denominator;

    pool.pnl_token_a = 0;
    pool.pnl_token_b = 0;

    pool.min_trade_amount = min_trade_amount;
    pool.max_trade_amount = max_trade_amount;

    pool.authority = creator.ctx.key;
    pool.open_time = open_time;
    pool.status = 0;

    // Seed initial liquidity: LP tokens = amount_a + amount_b (geometric approximation)
    let initial_lp: u64 = initial_amount_a + initial_amount_b;

    spl_token::SPLToken::transfer(user_token_a, pool_vault_a, creator, initial_amount_a);
    spl_token::SPLToken::transfer(user_token_b, pool_vault_b, creator, initial_amount_b);
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, initial_lp);

    pool.reserve_a = initial_amount_a;
    pool.reserve_b = initial_amount_b;
    pool.lp_supply = initial_lp;
}

// ---------------------------------------------------------------------------
// Instruction 2: deposit
// Add proportional liquidity to an existing pool, mint LP tokens
// ---------------------------------------------------------------------------

pub deposit(
    pool: AmmPool @mut @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    max_amount_a: u64,
    max_amount_b: u64,
    min_lp_amount: u64
) {
    require(pool.status == 0);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);
    require(pool.lp_supply > 0);
    require(max_amount_a > 0);
    require(max_amount_b > 0);

    // Validate vault accounts
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    // Calculate proportional LP tokens for each side
    let lp_from_a: u64 = (max_amount_a * pool.lp_supply) / pool.reserve_a;
    let lp_from_b: u64 = (max_amount_b * pool.lp_supply) / pool.reserve_b;

    // Mint the minimum to maintain price ratio (Raydium takes the lesser side)
    let lp_to_mint: u64 = min_u64(lp_from_a, lp_from_b);
    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_amount);

    // Back-calculate actual deposit amounts from the chosen LP amount
    let actual_amount_a: u64 = (lp_to_mint * pool.reserve_a) / pool.lp_supply;
    let actual_amount_b: u64 = (lp_to_mint * pool.reserve_b) / pool.lp_supply;
    require(actual_amount_a > 0);
    require(actual_amount_b > 0);
    require(actual_amount_a <= max_amount_a);
    require(actual_amount_b <= max_amount_b);

    // Transfer tokens and mint LP
    spl_token::SPLToken::transfer(user_token_a, pool_vault_a, user_authority, actual_amount_a);
    spl_token::SPLToken::transfer(user_token_b, pool_vault_b, user_authority, actual_amount_b);
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    pool.reserve_a = pool.reserve_a + actual_amount_a;
    pool.reserve_b = pool.reserve_b + actual_amount_b;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

// ---------------------------------------------------------------------------
// Instruction 3: withdraw
// Remove proportional liquidity, burn LP tokens
// ---------------------------------------------------------------------------

pub withdraw(
    pool: AmmPool @mut @signer,
    user_lp_account: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_a: u64,
    min_amount_b: u64
) {
    // Withdrawals are allowed even when paused (user fund safety)
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);

    // Validate vault accounts
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    // Pro-rata share of reserves
    let amount_a: u64 = (lp_amount * pool.reserve_a) / pool.lp_supply;
    let amount_b: u64 = (lp_amount * pool.reserve_b) / pool.lp_supply;
    require(amount_a > 0);
    require(amount_b > 0);
    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    // Burn LP, return tokens
    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);
    spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, amount_a);
    spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, amount_b);

    pool.reserve_a = pool.reserve_a - amount_a;
    pool.reserve_b = pool.reserve_b - amount_b;
    pool.lp_supply = pool.lp_supply - lp_amount;
}

// ---------------------------------------------------------------------------
// Instruction 4: swap_base_in
// Swap with a fixed input amount -- user specifies exact tokens in, gets
// variable tokens out. Classic x*y=k with fee splitting.
// ---------------------------------------------------------------------------

pub swap_base_in(
    pool: AmmPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_source_vault: account @mut,
    pool_dest_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    is_a_to_b: bool
) {
    require(pool.status == 0);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);

    // Open-time gating: swaps only work after scheduled open time
    let now: i64 = get_clock().unix_timestamp;
    require(now >= pool.open_time);

    // Trade size limits
    require(amount_in >= pool.min_trade_amount);
    require(amount_in <= pool.max_trade_amount);

    // Resolve directional reserves
    let mut reserve_in: u64 = 0;
    let mut reserve_out: u64 = 0;
    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_dest_vault.ctx.key == pool.token_b_vault);
        reserve_in = pool.reserve_a;
        reserve_out = pool.reserve_b;
    } else {
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_dest_vault.ctx.key == pool.token_a_vault);
        reserve_in = pool.reserve_b;
        reserve_out = pool.reserve_a;
    }

    // Step 1: Calculate total trade fee
    let trade_fee: u64 = calc_trade_fee(amount_in, pool.trade_fee_numerator, pool.trade_fee_denominator);

    // Step 2: Split fee into protocol PnL and LP portion
    let pnl_fee: u64 = calc_pnl_fee(trade_fee, pool.pnl_fee_numerator, pool.pnl_fee_denominator);
    let lp_fee: u64 = trade_fee - pnl_fee;

    // Step 3: Amount after all fees enter the constant-product formula
    let amount_in_after_fee: u64 = amount_in - trade_fee;
    require(amount_in_after_fee > 0);

    // Step 4: Constant product swap: dy = (y * dx) / (x + dx)
    let amount_out: u64 = (reserve_out * amount_in_after_fee) / (reserve_in + amount_in_after_fee);
    require(amount_out > 0);
    require(amount_out < reserve_out);
    require(amount_out >= min_amount_out);

    // Execute token transfers
    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_dest_vault, user_destination, pool, amount_out);

    // Update reserves: LP fee stays in reserves (benefits LPs), PnL tracked separately
    if (is_a_to_b) {
        pool.reserve_a = pool.reserve_a + amount_in - pnl_fee;
        pool.reserve_b = pool.reserve_b - amount_out;
        pool.pnl_token_a = pool.pnl_token_a + pnl_fee;
    } else {
        pool.reserve_b = pool.reserve_b + amount_in - pnl_fee;
        pool.reserve_a = pool.reserve_a - amount_out;
        pool.pnl_token_b = pool.pnl_token_b + pnl_fee;
    }
}

// ---------------------------------------------------------------------------
// Instruction 5: swap_base_out
// Swap with a fixed output amount -- user specifies exact tokens out, pays
// variable tokens in. Uses ceiling division to protect pool invariant.
// ---------------------------------------------------------------------------

pub swap_base_out(
    pool: AmmPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_source_vault: account @mut,
    pool_dest_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_out: u64,
    max_amount_in: u64,
    is_a_to_b: bool
) {
    require(pool.status == 0);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);

    // Open-time gating
    let now: i64 = get_clock().unix_timestamp;
    require(now >= pool.open_time);

    require(amount_out > 0);

    // Resolve directional reserves
    let mut reserve_in: u64 = 0;
    let mut reserve_out: u64 = 0;
    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_dest_vault.ctx.key == pool.token_b_vault);
        reserve_in = pool.reserve_a;
        reserve_out = pool.reserve_b;
    } else {
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_dest_vault.ctx.key == pool.token_a_vault);
        reserve_in = pool.reserve_b;
        reserve_out = pool.reserve_a;
    }

    // Ensure output doesn't exceed reserve
    require(amount_out < reserve_out);

    // Step 1: Inverse constant product -- how much input needed for desired output?
    // amount_in_before_fee = ceil(reserve_in * amount_out / (reserve_out - amount_out))
    let denominator: u64 = reserve_out - amount_out;
    let numerator: u64 = reserve_in * amount_out;
    let amount_in_before_fee: u64 = ceil_div(numerator, denominator);

    // Step 2: Gross up for trade fee
    // If amount_in_before_fee = amount_in * (1 - fee_rate), then:
    // amount_in = ceil(amount_in_before_fee * fee_denominator / (fee_denominator - fee_numerator))
    let fee_adjusted_denom: u64 = pool.trade_fee_denominator - pool.trade_fee_numerator;
    require(fee_adjusted_denom > 0);
    let amount_in: u64 = ceil_div(amount_in_before_fee * pool.trade_fee_denominator, fee_adjusted_denom);

    // Trade size limits on the calculated input
    require(amount_in >= pool.min_trade_amount);
    require(amount_in <= pool.max_trade_amount);
    require(amount_in <= max_amount_in);

    // Step 3: Calculate fee split
    let trade_fee: u64 = amount_in - amount_in_before_fee;
    let pnl_fee: u64 = calc_pnl_fee(trade_fee, pool.pnl_fee_numerator, pool.pnl_fee_denominator);

    // Execute token transfers
    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_dest_vault, user_destination, pool, amount_out);

    // Update reserves
    if (is_a_to_b) {
        pool.reserve_a = pool.reserve_a + amount_in - pnl_fee;
        pool.reserve_b = pool.reserve_b - amount_out;
        pool.pnl_token_a = pool.pnl_token_a + pnl_fee;
    } else {
        pool.reserve_b = pool.reserve_b + amount_in - pnl_fee;
        pool.reserve_a = pool.reserve_a - amount_out;
        pool.pnl_token_b = pool.pnl_token_b + pnl_fee;
    }
}

// ---------------------------------------------------------------------------
// Instruction 6: set_params
// Update pool parameters: fees, trade limits
// ---------------------------------------------------------------------------

pub set_params(
    pool: AmmPool @mut,
    authority: account @signer,
    new_trade_fee_numerator: u64,
    new_trade_fee_denominator: u64,
    new_pnl_fee_numerator: u64,
    new_pnl_fee_denominator: u64,
    new_min_trade_amount: u64,
    new_max_trade_amount: u64
) {
    require(pool.authority == authority.ctx.key);

    // Validate fee configuration
    require(new_trade_fee_denominator > 0);
    require(new_trade_fee_numerator < new_trade_fee_denominator);
    require(new_pnl_fee_denominator > 0);
    require(new_pnl_fee_numerator <= new_pnl_fee_denominator);

    // Validate trade limits
    require(new_max_trade_amount > new_min_trade_amount);

    pool.trade_fee_numerator = new_trade_fee_numerator;
    pool.trade_fee_denominator = new_trade_fee_denominator;
    pool.pnl_fee_numerator = new_pnl_fee_numerator;
    pool.pnl_fee_denominator = new_pnl_fee_denominator;
    pool.min_trade_amount = new_min_trade_amount;
    pool.max_trade_amount = new_max_trade_amount;
}

// ---------------------------------------------------------------------------
// Instruction 7: withdraw_pnl
// Extract accumulated protocol fees (PnL) from the pool
// ---------------------------------------------------------------------------

pub withdraw_pnl(
    pool: AmmPool @mut @signer,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    pnl_recipient_a: account @mut,
    pnl_recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);

    let pnl_a: u64 = pool.pnl_token_a;
    let pnl_b: u64 = pool.pnl_token_b;
    require(pnl_a > 0 || pnl_b > 0);

    // Validate vault accounts
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);

    // Transfer accumulated PnL to recipient
    if (pnl_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, pnl_recipient_a, pool, pnl_a);
        pool.pnl_token_a = 0;
        // PnL was already excluded from reserve tracking, so no reserve update needed.
        // The vault held pnl_a extra tokens beyond reserve_a; we're draining that excess.
    }

    if (pnl_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, pnl_recipient_b, pool, pnl_b);
        pool.pnl_token_b = 0;
    }
}

// ---------------------------------------------------------------------------
// Instruction 8: set_authority
// Transfer pool admin to a new authority
// ---------------------------------------------------------------------------

pub set_authority(
    pool: AmmPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Instruction 9: pause / unpause
// Emergency controls -- pause halts swaps and deposits, but allows withdrawals
// ---------------------------------------------------------------------------

pub pause(
    pool: AmmPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(pool.status == 0);
    pool.status = 1;
}

pub unpause(
    pool: AmmPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(pool.status == 1);
    pool.status = 0;
}

// ---------------------------------------------------------------------------
// Instruction: set_open_time
// Reschedule pool open time (only before pool has opened)
// ---------------------------------------------------------------------------

pub set_open_time(
    pool: AmmPool @mut,
    authority: account @signer,
    new_open_time: i64
) {
    require(pool.authority == authority.ctx.key);

    // Can only change open time before the pool has opened
    let now: i64 = get_clock().unix_timestamp;
    require(now < pool.open_time);
    require(new_open_time > now);

    pool.open_time = new_open_time;
}

// ---------------------------------------------------------------------------
// Read-only views
// ---------------------------------------------------------------------------

pub get_pool_reserves(pool: AmmPool) -> u64 {
    return pool.reserve_a;
}

pub get_pool_reserve_b(pool: AmmPool) -> u64 {
    return pool.reserve_b;
}

pub get_lp_supply(pool: AmmPool) -> u64 {
    return pool.lp_supply;
}

pub get_pnl_token_a(pool: AmmPool) -> u64 {
    return pool.pnl_token_a;
}

pub get_pnl_token_b(pool: AmmPool) -> u64 {
    return pool.pnl_token_b;
}

pub get_pool_status(pool: AmmPool) -> u8 {
    return pool.status;
}

pub get_pool_open_time(pool: AmmPool) -> i64 {
    return pool.open_time;
}
