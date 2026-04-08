// Saber StableSwap — migrated to 5ive DSL
//
// Implements Curve Finance's StableSwap invariant for 2-token stable pools.
// Invariant: A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
// Where n = 2, A = amplification coefficient.
//
// Original: ~3,000 lines of Rust  |  5ive: ~250 lines
// Source: https://github.com/saber-hq/stable-swap

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account StablePool {
    // Token configuration
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;

    // Pool reserves (tracked on-chain for invariant math)
    reserve_a: u64;
    reserve_b: u64;
    lp_supply: u64;

    // Amplification coefficient with time-ramping
    initial_amp: u64;
    target_amp: u64;
    ramp_start_ts: i64;
    ramp_stop_ts: i64;

    // Fee configuration (numerator/denominator pattern)
    trade_fee_numerator: u64;
    trade_fee_denominator: u64;
    withdraw_fee_numerator: u64;
    withdraw_fee_denominator: u64;
    admin_trade_fee_numerator: u64;
    admin_trade_fee_denominator: u64;
    admin_withdraw_fee_numerator: u64;
    admin_withdraw_fee_denominator: u64;

    // Admin fees accumulated
    admin_fee_a: u64;
    admin_fee_b: u64;

    // Administration
    admin: pubkey;
    is_paused: bool;
}

// ---------------------------------------------------------------------------
// Constants (embedded as fn to work within integer-only DSL)
// ---------------------------------------------------------------------------

// N_COINS = 2 for a two-token pool
// FEE_DENOMINATOR default = 10_000_000_000  (1e10, basis-point precision)
// MAX_AMP = 1_000_000
// MIN_RAMP_DURATION = 86400 (1 day in seconds)
// MAX_AMP_CHANGE = 10

// ---------------------------------------------------------------------------
// Internal math helpers
// ---------------------------------------------------------------------------

/// Compute the current amplification coefficient, interpolating linearly
/// between initial_amp and target_amp based on the current timestamp.
fn get_current_amp(
    initial_amp: u64,
    target_amp: u64,
    ramp_start_ts: i64,
    ramp_stop_ts: i64,
    current_ts: i64
) -> u64 {
    // If ramp hasn't started or timestamps are equal, return initial
    if (current_ts < ramp_start_ts) {
        return initial_amp;
    }
    // If ramp is complete, return target
    if (current_ts >= ramp_stop_ts) {
        return target_amp;
    }

    // Linear interpolation
    let elapsed: u64 = (current_ts - ramp_start_ts) as u64;
    let duration: u64 = (ramp_stop_ts - ramp_start_ts) as u64;

    if (target_amp >= initial_amp) {
        let delta: u64 = target_amp - initial_amp;
        return initial_amp + (delta * elapsed) / duration;
    } else {
        let delta: u64 = initial_amp - target_amp;
        return initial_amp - (delta * elapsed) / duration;
    }
}

/// Compute the StableSwap invariant D using Newton's method.
/// Invariant: A * n^n * S + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
/// For n=2: A * 4 * (x + y) + D = A * D * 4 + D^3 / (4 * x * y)
///
/// Newton's iteration:
///   d_prev = D
///   D_P = D^3 / (4 * x * y)     [= D^(n+1) / (n^n * prod)]
///   D = (A * 4 * S + D_P * 2) * D / ((A * 4 - 1) * D + 3 * D_P)
///
/// Converges when |D - d_prev| <= 1
fn compute_d(amount_a: u64, amount_b: u64, amp: u64) -> u64 {
    let sum: u64 = amount_a + amount_b;
    if (sum == 0) {
        return 0;
    }

    // ann = A * n^n = A * 4 (for n=2)
    let ann: u64 = amp * 4;

    let mut d: u64 = sum;
    let mut d_prev: u64 = 0;
    let mut i: u64 = 0;

    // Newton's method — up to 256 iterations
    while (i < 256) {
        // d_p = D^3 / (4 * x * y)
        // Computed as: d_p = D, then d_p = d_p * D / (2 * x), d_p = d_p * D / (2 * y)
        let mut d_p: u64 = d;
        d_p = (d_p * d) / (2 * amount_a);
        d_p = (d_p * d) / (2 * amount_b);

        d_prev = d;

        // Numerator:   (ann * sum + d_p * n_coins) * d
        // Denominator: (ann - 1) * d + (n_coins + 1) * d_p
        let numerator: u64 = (ann * sum + d_p * 2) * d;
        let denominator: u64 = (ann - 1) * d + 3 * d_p;

        d = numerator / denominator;

        // Check convergence: |d - d_prev| <= 1
        if (d > d_prev) {
            if (d - d_prev <= 1) {
                return d;
            }
        } else {
            if (d_prev - d <= 1) {
                return d;
            }
        }

        i = i + 1;
    }

    // Should converge well within 256 iterations for valid inputs
    return d;
}

/// Compute the output amount y given input x, invariant D, and amp A.
/// Solves the StableSwap equation for the second token balance.
///
/// For n=2, we solve:
///   y^2 + (S' + D/ann - D) * y = D^3 / (4 * ann * x)
/// Where S' = x (the new balance of the input token after swap)
///
/// Newton's iteration:
///   c  = D^3 / (4 * ann * x)
///   b  = x + D / ann
///   y  = (y^2 + c) / (2*y + b - D)
fn compute_y(x: u64, d: u64, amp: u64) -> u64 {
    let ann: u64 = amp * 4;

    // c = D^3 / (ann * n^n * prod(x_i'))
    // For n=2 with one known balance x: c = D^3 / (4 * ann * x)
    // Computed step by step to manage precision:
    let mut c: u64 = d;
    c = (c * d) / (2 * x);      // d^2 / (2*x)
    c = (c * d) / (2 * ann);    // d^3 / (4 * ann * x)

    // b = x + D / ann (but we subtract D at the end so b_adj = b - D)
    let b: u64 = x + d / ann;

    let mut y: u64 = d;
    let mut y_prev: u64 = 0;
    let mut i: u64 = 0;

    // Newton's method — up to 256 iterations
    while (i < 256) {
        y_prev = y;

        // y = (y^2 + c) / (2*y + b - D)
        let numerator: u64 = y * y + c;
        let denominator: u64 = 2 * y + b - d;
        y = numerator / denominator;

        // Check convergence
        if (y > y_prev) {
            if (y - y_prev <= 1) {
                return y;
            }
        } else {
            if (y_prev - y <= 1) {
                return y;
            }
        }

        i = i + 1;
    }

    return y;
}

/// Calculate fee: amount * numerator / denominator
/// Returns 0 if denominator is 0 (fees disabled).
fn calculate_fee(amount: u64, fee_numerator: u64, fee_denominator: u64) -> u64 {
    if (fee_denominator == 0) {
        return 0;
    }
    return (amount * fee_numerator) / fee_denominator;
}

// ---------------------------------------------------------------------------
// Public instructions
// ---------------------------------------------------------------------------

/// Initialize a new StableSwap pool.
pub initialize(
    pool: StablePool @mut @init(payer=admin, space=1024) @signer,
    admin: account @mut @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint: pubkey,
    amp: u64,
    trade_fee_numerator: u64,
    trade_fee_denominator: u64,
    withdraw_fee_numerator: u64,
    withdraw_fee_denominator: u64,
    admin_trade_fee_numerator: u64,
    admin_trade_fee_denominator: u64,
    admin_withdraw_fee_numerator: u64,
    admin_withdraw_fee_denominator: u64
) {
    // Validate amplification coefficient: 1 <= A <= 1,000,000
    require(amp >= 1);
    require(amp <= 1000000);

    // Validate fee structure
    require(trade_fee_denominator > 0);
    require(trade_fee_numerator <= trade_fee_denominator);
    require(withdraw_fee_denominator > 0);
    require(withdraw_fee_numerator <= withdraw_fee_denominator);
    require(admin_trade_fee_denominator > 0);
    require(admin_trade_fee_numerator <= admin_trade_fee_denominator);
    require(admin_withdraw_fee_denominator > 0);
    require(admin_withdraw_fee_numerator <= admin_withdraw_fee_denominator);

    // Token mints must differ
    require(token_a_mint != token_b_mint);

    // Token configuration
    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.lp_mint = lp_mint;

    // Initial reserves
    pool.reserve_a = 0;
    pool.reserve_b = 0;
    pool.lp_supply = 0;

    // Amplification — no ramp at initialization
    pool.initial_amp = amp;
    pool.target_amp = amp;
    pool.ramp_start_ts = 0;
    pool.ramp_stop_ts = 0;

    // Fee configuration
    pool.trade_fee_numerator = trade_fee_numerator;
    pool.trade_fee_denominator = trade_fee_denominator;
    pool.withdraw_fee_numerator = withdraw_fee_numerator;
    pool.withdraw_fee_denominator = withdraw_fee_denominator;
    pool.admin_trade_fee_numerator = admin_trade_fee_numerator;
    pool.admin_trade_fee_denominator = admin_trade_fee_denominator;
    pool.admin_withdraw_fee_numerator = admin_withdraw_fee_numerator;
    pool.admin_withdraw_fee_denominator = admin_withdraw_fee_denominator;

    // Admin fees start at zero
    pool.admin_fee_a = 0;
    pool.admin_fee_b = 0;

    // Administration
    pool.admin = admin.ctx.key;
    pool.is_paused = false;
}

/// Deposit both tokens into the pool and mint LP tokens.
/// On first deposit, LP tokens = invariant D.
/// On subsequent deposits, LP tokens are proportional to the change in D,
/// with withdraw fees charged on any imbalanced deposit.
pub deposit(
    pool: StablePool @mut @signer,
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
    min_lp_amount: u64
) {
    require(!pool.is_paused);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    // At least one token amount must be positive
    require(amount_a > 0 || amount_b > 0);

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    let new_reserve_a: u64 = pool.reserve_a + amount_a;
    let new_reserve_b: u64 = pool.reserve_b + amount_b;

    // Compute invariant before and after deposit
    let d0: u64 = compute_d(pool.reserve_a, pool.reserve_b, amp);
    let d1: u64 = compute_d(new_reserve_a, new_reserve_b, amp);
    require(d1 > d0);

    let mut lp_to_mint: u64 = 0;

    if (pool.lp_supply == 0) {
        // First deposit: LP tokens = D
        lp_to_mint = d1;
    } else {
        // Proportional LP minting with imbalance fee
        // Ideal balanced deposit would change each reserve by d1/d0
        // Fee is charged on the difference from ideal

        let ideal_a: u64 = (pool.reserve_a * d1) / d0;
        let ideal_b: u64 = (pool.reserve_b * d1) / d0;

        // Compute imbalance: |actual - ideal| for each token
        let mut diff_a: u64 = 0;
        if (new_reserve_a > ideal_a) {
            diff_a = new_reserve_a - ideal_a;
        } else {
            diff_a = ideal_a - new_reserve_a;
        }

        let mut diff_b: u64 = 0;
        if (new_reserve_b > ideal_b) {
            diff_b = new_reserve_b - ideal_b;
        } else {
            diff_b = ideal_b - new_reserve_b;
        }

        // Withdraw fee on imbalance
        let fee_a: u64 = calculate_fee(diff_a, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
        let fee_b: u64 = calculate_fee(diff_b, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);

        // Admin portion of the fee
        let admin_fee_a: u64 = calculate_fee(fee_a, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
        let admin_fee_b: u64 = calculate_fee(fee_b, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
        pool.admin_fee_a = pool.admin_fee_a + admin_fee_a;
        pool.admin_fee_b = pool.admin_fee_b + admin_fee_b;

        // Adjusted reserves after fee
        let adjusted_a: u64 = new_reserve_a - fee_a;
        let adjusted_b: u64 = new_reserve_b - fee_b;
        let d2: u64 = compute_d(adjusted_a, adjusted_b, amp);

        // LP tokens proportional to D increase
        lp_to_mint = (pool.lp_supply * (d2 - d0)) / d0;
    }

    require(lp_to_mint >= min_lp_amount);
    require(lp_to_mint > 0);

    // Transfer tokens in
    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, pool_token_a_vault, user_authority, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, pool_token_b_vault, user_authority, amount_b);
    }

    // Mint LP tokens
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    // Update state
    pool.reserve_a = new_reserve_a;
    pool.reserve_b = new_reserve_b;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

/// Withdraw both tokens proportionally by burning LP tokens.
pub withdraw(
    pool: StablePool @mut @signer,
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

    // Proportional withdrawal: each token = reserve * lp_amount / lp_supply
    let amount_a: u64 = (pool.reserve_a * lp_amount) / pool.lp_supply;
    let amount_b: u64 = (pool.reserve_b * lp_amount) / pool.lp_supply;

    // Apply withdraw fee
    let fee_a: u64 = calculate_fee(amount_a, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
    let fee_b: u64 = calculate_fee(amount_b, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);

    let out_a: u64 = amount_a - fee_a;
    let out_b: u64 = amount_b - fee_b;

    require(out_a > 0);
    require(out_b > 0);
    require(out_a >= min_amount_a);
    require(out_b >= min_amount_b);

    // Admin portion of withdraw fee
    let admin_fee_a: u64 = calculate_fee(fee_a, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
    let admin_fee_b: u64 = calculate_fee(fee_b, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
    pool.admin_fee_a = pool.admin_fee_a + admin_fee_a;
    pool.admin_fee_b = pool.admin_fee_b + admin_fee_b;

    // Burn LP tokens
    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);

    // Transfer tokens out
    spl_token::SPLToken::transfer(pool_token_a_vault, user_token_a, pool, out_a);
    spl_token::SPLToken::transfer(pool_token_b_vault, user_token_b, pool, out_b);

    // Update state
    pool.reserve_a = pool.reserve_a - amount_a;
    pool.reserve_b = pool.reserve_b - amount_b;
    pool.lp_supply = pool.lp_supply - lp_amount;
}

/// Swap one token for the other using the StableSwap curve.
pub swap(
    pool: StablePool @mut @signer,
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

    // Validate vault accounts based on swap direction
    let mut source_reserve: u64 = 0;
    let mut dest_reserve: u64 = 0;
    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_destination_vault.ctx.key == pool.token_b_vault);
        source_reserve = pool.reserve_a;
        dest_reserve = pool.reserve_b;
    } else {
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_destination_vault.ctx.key == pool.token_a_vault);
        source_reserve = pool.reserve_b;
        dest_reserve = pool.reserve_a;
    }

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // Compute invariant D from current reserves
    let d: u64 = compute_d(pool.reserve_a, pool.reserve_b, amp);

    // New source balance after receiving user's tokens
    let new_source: u64 = source_reserve + amount_in;

    // Compute new destination balance from the invariant
    let new_dest: u64 = compute_y(new_source, d, amp);

    // Gross output before fees
    let gross_amount_out: u64 = dest_reserve - new_dest;
    require(gross_amount_out > 0);

    // Trade fee
    let trade_fee: u64 = calculate_fee(gross_amount_out, pool.trade_fee_numerator, pool.trade_fee_denominator);

    // Admin trade fee (portion of the trade fee)
    let admin_fee: u64 = calculate_fee(trade_fee, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);

    // Net output to user
    let amount_out: u64 = gross_amount_out - trade_fee;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Execute token transfers
    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, pool, amount_out);

    // Update reserves and admin fees
    if (is_a_to_b) {
        pool.reserve_a = pool.reserve_a + amount_in;
        pool.reserve_b = pool.reserve_b - amount_out - admin_fee;
        pool.admin_fee_b = pool.admin_fee_b + admin_fee;
    } else {
        pool.reserve_b = pool.reserve_b + amount_in;
        pool.reserve_a = pool.reserve_a - amount_out - admin_fee;
        pool.admin_fee_a = pool.admin_fee_a + admin_fee;
    }
}

/// Withdraw liquidity as a single token by burning LP tokens.
/// Uses the StableSwap curve to determine how much of one token the LP
/// share is worth, then charges a withdraw fee on the imbalance.
pub withdraw_one(
    pool: StablePool @mut @signer,
    user_lp_account: account @mut,
    user_token_out: account @mut,
    pool_token_out_vault: account @mut,
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

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // Current invariant
    let d0: u64 = compute_d(pool.reserve_a, pool.reserve_b, amp);

    // New invariant after burning LP tokens
    let d1: u64 = d0 - (d0 * lp_amount) / pool.lp_supply;

    // Determine which token to withdraw and compute new balance
    let mut withdraw_reserve: u64 = 0;
    let mut other_reserve: u64 = 0;
    if (is_token_a) {
        require(pool_token_out_vault.ctx.key == pool.token_a_vault);
        withdraw_reserve = pool.reserve_a;
        other_reserve = pool.reserve_b;
    } else {
        require(pool_token_out_vault.ctx.key == pool.token_b_vault);
        withdraw_reserve = pool.reserve_b;
        other_reserve = pool.reserve_a;
    }

    // New balance of the withdrawal token given d1
    let new_withdraw_balance: u64 = compute_y(other_reserve, d1, amp);

    // Gross amount out (before fees)
    let gross_amount_out: u64 = withdraw_reserve - new_withdraw_balance;
    require(gross_amount_out > 0);

    // Withdraw fee on the full amount (single-sided is maximally imbalanced)
    let withdraw_fee: u64 = calculate_fee(gross_amount_out, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
    let admin_fee: u64 = calculate_fee(withdraw_fee, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);

    let amount_out: u64 = gross_amount_out - withdraw_fee;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Burn LP tokens
    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);

    // Transfer token out
    spl_token::SPLToken::transfer(pool_token_out_vault, user_token_out, pool, amount_out);

    // Update state
    if (is_token_a) {
        pool.reserve_a = pool.reserve_a - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_a = pool.admin_fee_a + admin_fee;
    } else {
        pool.reserve_b = pool.reserve_b - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_b = pool.admin_fee_b + admin_fee;
    }
    pool.lp_supply = pool.lp_supply - lp_amount;
}

// ---------------------------------------------------------------------------
// Admin instructions
// ---------------------------------------------------------------------------

/// Begin ramping the amplification coefficient from current_a to target_a
/// over the given duration. Enforces minimum ramp time (1 day) and maximum
/// change factor (10x per ramp).
pub ramp_a(
    pool: StablePool @mut,
    admin: account @signer,
    target_amp: u64,
    ramp_stop_ts: i64
) {
    require(pool.admin == admin.ctx.key);
    require(!pool.is_paused);

    let current_ts: i64 = get_clock().unix_timestamp;
    let current_amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // Validate target amp: 1 <= target <= 1,000,000
    require(target_amp >= 1);
    require(target_amp <= 1000000);

    // Minimum ramp duration: 1 day (86400 seconds)
    require(ramp_stop_ts >= current_ts + 86400);

    // Maximum 10x change per ramp
    if (target_amp > current_amp) {
        require(target_amp <= current_amp * 10);
    } else {
        require(current_amp <= target_amp * 10);
    }

    pool.initial_amp = current_amp;
    pool.target_amp = target_amp;
    pool.ramp_start_ts = current_ts;
    pool.ramp_stop_ts = ramp_stop_ts;
}

/// Stop an ongoing amplification ramp, freezing A at its current value.
pub stop_ramp_a(
    pool: StablePool @mut,
    admin: account @signer
) {
    require(pool.admin == admin.ctx.key);

    let current_ts: i64 = get_clock().unix_timestamp;
    let current_amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    pool.initial_amp = current_amp;
    pool.target_amp = current_amp;
    pool.ramp_start_ts = current_ts;
    pool.ramp_stop_ts = current_ts;
}

/// Update fee configuration. Only callable by admin.
pub set_fees(
    pool: StablePool @mut,
    admin: account @signer,
    trade_fee_numerator: u64,
    trade_fee_denominator: u64,
    withdraw_fee_numerator: u64,
    withdraw_fee_denominator: u64,
    admin_trade_fee_numerator: u64,
    admin_trade_fee_denominator: u64,
    admin_withdraw_fee_numerator: u64,
    admin_withdraw_fee_denominator: u64
) {
    require(pool.admin == admin.ctx.key);

    require(trade_fee_denominator > 0);
    require(trade_fee_numerator <= trade_fee_denominator);
    require(withdraw_fee_denominator > 0);
    require(withdraw_fee_numerator <= withdraw_fee_denominator);
    require(admin_trade_fee_denominator > 0);
    require(admin_trade_fee_numerator <= admin_trade_fee_denominator);
    require(admin_withdraw_fee_denominator > 0);
    require(admin_withdraw_fee_numerator <= admin_withdraw_fee_denominator);

    pool.trade_fee_numerator = trade_fee_numerator;
    pool.trade_fee_denominator = trade_fee_denominator;
    pool.withdraw_fee_numerator = withdraw_fee_numerator;
    pool.withdraw_fee_denominator = withdraw_fee_denominator;
    pool.admin_trade_fee_numerator = admin_trade_fee_numerator;
    pool.admin_trade_fee_denominator = admin_trade_fee_denominator;
    pool.admin_withdraw_fee_numerator = admin_withdraw_fee_numerator;
    pool.admin_withdraw_fee_denominator = admin_withdraw_fee_denominator;
}

/// Pause the pool. Blocks swaps, deposits, and withdrawals.
pub pause(
    pool: StablePool @mut,
    admin: account @signer
) {
    require(pool.admin == admin.ctx.key);
    require(!pool.is_paused);
    pool.is_paused = true;
}

/// Unpause the pool.
pub unpause(
    pool: StablePool @mut,
    admin: account @signer
) {
    require(pool.admin == admin.ctx.key);
    require(pool.is_paused);
    pool.is_paused = false;
}

/// Transfer admin authority to a new address.
pub set_admin(
    pool: StablePool @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(pool.admin == admin.ctx.key);
    pool.admin = new_admin;
}

/// Collect accumulated admin fees from the pool vaults.
pub collect_admin_fees(
    pool: StablePool @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    admin: account @signer,
    token_program: account
) {
    require(pool.admin == admin.ctx.key);
    require(pool_token_a_vault.ctx.key == pool.token_a_vault);
    require(pool_token_b_vault.ctx.key == pool.token_b_vault);

    let fee_a: u64 = pool.admin_fee_a;
    let fee_b: u64 = pool.admin_fee_b;

    if (fee_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, pool, fee_a);
        pool.admin_fee_a = 0;
    }

    if (fee_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, pool, fee_b);
        pool.admin_fee_b = 0;
    }
}
