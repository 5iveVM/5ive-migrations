// Mercurial Finance (Stable AMM) -- migrated to 5ive DSL
//
// Multi-token stable AMM on Solana (like Curve's 3pool/4pool).
// Unlike Saber (2 tokens only), Mercurial supports 2-4 token stable pools
// with dynamic fees, amplification ramping, and vault strategies for
// idle liquidity yield optimization.
//
// StableSwap invariant generalized for N tokens (2 <= N <= 4):
//   A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
//
// Original: ~5,000 lines of Rust  |  5ive: ~750 lines
// Source: https://github.com/mercurial-finance/mercurial-dynamic-amm-sdk

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account StablePool {
    // Token mints (up to 4; unused slots set to system program / zero pubkey)
    token_mint_1: pubkey;
    token_mint_2: pubkey;
    token_mint_3: pubkey;
    token_mint_4: pubkey;

    // Token vaults (pool-owned ATAs holding reserves)
    vault_1: pubkey;
    vault_2: pubkey;
    vault_3: pubkey;
    vault_4: pubkey;

    // On-chain tracked reserves per token
    reserve_1: u64;
    reserve_2: u64;
    reserve_3: u64;
    reserve_4: u64;

    // Number of active tokens in this pool (2, 3, or 4)
    num_tokens: u8;

    // LP mint and tracked supply
    lp_mint: pubkey;
    lp_supply: u64;

    // Amplification coefficient with time-ramping
    initial_amp: u64;
    target_amp: u64;
    ramp_start_ts: i64;
    ramp_stop_ts: i64;

    // Fee configuration (numerator/denominator for basis-point precision)
    trade_fee_numerator: u64;
    trade_fee_denominator: u64;
    admin_trade_fee_numerator: u64;
    admin_trade_fee_denominator: u64;
    withdraw_fee_numerator: u64;
    withdraw_fee_denominator: u64;
    admin_withdraw_fee_numerator: u64;
    admin_withdraw_fee_denominator: u64;

    // Accumulated admin fees per token
    admin_fee_1: u64;
    admin_fee_2: u64;
    admin_fee_3: u64;
    admin_fee_4: u64;

    // Administration
    admin: pubkey;
    is_paused: bool;
}

account Vault {
    pool: pubkey;
    token_mint: pubkey;
    token_vault: pubkey;
    strategy_type: u8;
    strategy_program: pubkey;
    deposited_amount: u64;
    last_harvest_slot: u64;
    admin: pubkey;
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

// MAX_TOKENS = 4
// MIN_AMP = 1
// MAX_AMP = 1_000_000
// MIN_RAMP_DURATION = 86400 (1 day in seconds)
// MAX_AMP_CHANGE = 10x per ramp
// ZERO_PUBKEY used for unused token slots

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
    if (current_ts < ramp_start_ts) {
        return initial_amp;
    }
    if (current_ts >= ramp_stop_ts) {
        return target_amp;
    }

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

/// Compute the StableSwap invariant D for a 2-token pool using Newton's method.
/// Invariant: A * 4 * (x + y) + D = A * D * 4 + D^3 / (4 * x * y)
fn compute_d_2(x1: u64, x2: u64, amp: u64) -> u64 {
    let sum: u64 = x1 + x2;
    if (sum == 0) {
        return 0;
    }

    let ann: u64 = amp * 4;
    let mut d: u64 = sum;
    let mut d_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        let mut d_p: u64 = d;
        d_p = (d_p * d) / (2 * x1);
        d_p = (d_p * d) / (2 * x2);

        d_prev = d;

        let numerator: u64 = (ann * sum + d_p * 2) * d;
        let denominator: u64 = (ann - 1) * d + 3 * d_p;
        d = numerator / denominator;

        if (d > d_prev) {
            if (d - d_prev <= 1) { return d; }
        } else {
            if (d_prev - d <= 1) { return d; }
        }

        i = i + 1;
    }
    return d;
}

/// Compute the StableSwap invariant D for a 3-token pool using Newton's method.
/// For n=3: ann = A * 27, d_p = D^4 / (27 * x1 * x2 * x3)
fn compute_d_3(x1: u64, x2: u64, x3: u64, amp: u64) -> u64 {
    let sum: u64 = x1 + x2 + x3;
    if (sum == 0) {
        return 0;
    }

    // ann = A * n^n = A * 27
    let ann: u64 = amp * 27;
    let mut d: u64 = sum;
    let mut d_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        // d_p = D^(n+1) / (n^n * prod(x_i))
        // = D^4 / (27 * x1 * x2 * x3)
        // Computed stepwise: d_p = D, then *= D/(3*x_i) for each token
        let mut d_p: u64 = d;
        d_p = (d_p * d) / (3 * x1);
        d_p = (d_p * d) / (3 * x2);
        d_p = (d_p * d) / (3 * x3);

        d_prev = d;

        // D = (ann * S + d_p * n) * D / ((ann - 1) * D + (n + 1) * d_p)
        let numerator: u64 = (ann * sum + d_p * 3) * d;
        let denominator: u64 = (ann - 1) * d + 4 * d_p;
        d = numerator / denominator;

        if (d > d_prev) {
            if (d - d_prev <= 1) { return d; }
        } else {
            if (d_prev - d <= 1) { return d; }
        }

        i = i + 1;
    }
    return d;
}

/// Compute the StableSwap invariant D for a 4-token pool using Newton's method.
/// For n=4: ann = A * 256, d_p = D^5 / (256 * x1 * x2 * x3 * x4)
fn compute_d_4(x1: u64, x2: u64, x3: u64, x4: u64, amp: u64) -> u64 {
    let sum: u64 = x1 + x2 + x3 + x4;
    if (sum == 0) {
        return 0;
    }

    // ann = A * n^n = A * 256
    let ann: u64 = amp * 256;
    let mut d: u64 = sum;
    let mut d_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        let mut d_p: u64 = d;
        d_p = (d_p * d) / (4 * x1);
        d_p = (d_p * d) / (4 * x2);
        d_p = (d_p * d) / (4 * x3);
        d_p = (d_p * d) / (4 * x4);

        d_prev = d;

        // D = (ann * S + d_p * n) * D / ((ann - 1) * D + (n + 1) * d_p)
        let numerator: u64 = (ann * sum + d_p * 4) * d;
        let denominator: u64 = (ann - 1) * d + 5 * d_p;
        d = numerator / denominator;

        if (d > d_prev) {
            if (d - d_prev <= 1) { return d; }
        } else {
            if (d_prev - d <= 1) { return d; }
        }

        i = i + 1;
    }
    return d;
}

/// Dispatch compute_d to the right N-token variant based on num_tokens.
fn compute_d(r1: u64, r2: u64, r3: u64, r4: u64, num_tokens: u8, amp: u64) -> u64 {
    if (num_tokens == 2) {
        return compute_d_2(r1, r2, amp);
    }
    if (num_tokens == 3) {
        return compute_d_3(r1, r2, r3, amp);
    }
    return compute_d_4(r1, r2, r3, r4, amp);
}

/// Compute the output balance y for a 2-token pool given the other balance x,
/// invariant D, and amplification A. Newton's method.
fn compute_y_2(x: u64, d: u64, amp: u64) -> u64 {
    let ann: u64 = amp * 4;

    let mut c: u64 = d;
    c = (c * d) / (2 * x);
    c = (c * d) / (2 * ann);

    let b: u64 = x + d / ann;

    let mut y: u64 = d;
    let mut y_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        y_prev = y;
        let numerator: u64 = y * y + c;
        let denominator: u64 = 2 * y + b - d;
        y = numerator / denominator;

        if (y > y_prev) {
            if (y - y_prev <= 1) { return y; }
        } else {
            if (y_prev - y <= 1) { return y; }
        }

        i = i + 1;
    }
    return y;
}

/// Compute output balance y for a 3-token pool given two known balances,
/// invariant D, and amplification A.
/// sum_others = sum of the two known token balances
/// prod_factor: iterative product D/(n*x_i) for each known balance
fn compute_y_3(other_1: u64, other_2: u64, d: u64, amp: u64) -> u64 {
    let ann: u64 = amp * 27;
    let sum_others: u64 = other_1 + other_2;

    // c = D^(n+1) / (n^n * prod(known_balances) * n)
    // For n=3, 2 known: c = D^4 / (27 * other_1 * other_2 * 3)
    // Stepwise: c = D, c = c*D/(3*other_1), c = c*D/(3*other_2), c = c*D/(3*ann) ...
    // Actually: c = D^(n+1) / (ann * n^n * prod_known)
    // but for Newton on y: c = D^(n+1) / (ann * prod_known * n^(n-1)... )
    // Correct formulation for compute_y with n=3:
    //   c = D^3 / (ann * 9 * other_1 * other_2)  -- simplified from the general form
    //   b = sum_others + D/ann
    //   y_new = (y^2 + c) / (2*y + b - D)
    let mut c: u64 = d;
    c = (c * d) / (3 * other_1);
    c = (c * d) / (3 * other_2);
    c = c / ann;    // effectively D^3 / (9 * other_1 * other_2 * ann)

    let b: u64 = sum_others + d / ann;

    let mut y: u64 = d;
    let mut y_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        y_prev = y;
        let numerator: u64 = y * y + c;
        let denominator: u64 = 2 * y + b - d;
        y = numerator / denominator;

        if (y > y_prev) {
            if (y - y_prev <= 1) { return y; }
        } else {
            if (y_prev - y <= 1) { return y; }
        }

        i = i + 1;
    }
    return y;
}

/// Compute output balance y for a 4-token pool given three known balances.
fn compute_y_4(other_1: u64, other_2: u64, other_3: u64, d: u64, amp: u64) -> u64 {
    let ann: u64 = amp * 256;
    let sum_others: u64 = other_1 + other_2 + other_3;

    // c = D^4 / (256 * other_1 * other_2 * other_3 * ann)
    let mut c: u64 = d;
    c = (c * d) / (4 * other_1);
    c = (c * d) / (4 * other_2);
    c = (c * d) / (4 * other_3);
    c = c / ann;

    let b: u64 = sum_others + d / ann;

    let mut y: u64 = d;
    let mut y_prev: u64 = 0;
    let mut i: u64 = 0;

    while (i < 256) {
        y_prev = y;
        let numerator: u64 = y * y + c;
        let denominator: u64 = 2 * y + b - d;
        y = numerator / denominator;

        if (y > y_prev) {
            if (y - y_prev <= 1) { return y; }
        } else {
            if (y_prev - y <= 1) { return y; }
        }

        i = i + 1;
    }
    return y;
}

/// Calculate fee: amount * numerator / denominator.
/// Returns 0 if denominator is 0 (fees disabled).
fn calculate_fee(amount: u64, fee_numerator: u64, fee_denominator: u64) -> u64 {
    if (fee_denominator == 0) {
        return 0;
    }
    return (amount * fee_numerator) / fee_denominator;
}

/// Absolute difference helper (no signed arithmetic needed).
fn abs_diff(a: u64, b: u64) -> u64 {
    if (a > b) {
        return a - b;
    }
    return b - a;
}

// ---------------------------------------------------------------------------
// Public instructions
// ---------------------------------------------------------------------------

/// Create a new multi-token stable pool with 2-4 tokens.
/// Unused token slots (mint/vault) should be set to the system program pubkey.
pub create_pool(
    pool: StablePool @mut @init(payer=admin, space=2048) @signer,
    admin: account @mut @signer,
    token_mint_1: pubkey,
    token_mint_2: pubkey,
    token_mint_3: pubkey,
    token_mint_4: pubkey,
    vault_1: pubkey,
    vault_2: pubkey,
    vault_3: pubkey,
    vault_4: pubkey,
    lp_mint: pubkey,
    num_tokens: u8,
    amp: u64,
    trade_fee_numerator: u64,
    trade_fee_denominator: u64,
    admin_trade_fee_numerator: u64,
    admin_trade_fee_denominator: u64,
    withdraw_fee_numerator: u64,
    withdraw_fee_denominator: u64,
    admin_withdraw_fee_numerator: u64,
    admin_withdraw_fee_denominator: u64
) {
    // Must be 2, 3, or 4 tokens
    require(num_tokens >= 2);
    require(num_tokens <= 4);

    // Validate amplification: 1 <= A <= 1,000,000
    require(amp >= 1);
    require(amp <= 1000000);

    // Validate fee structure
    require(trade_fee_denominator > 0);
    require(trade_fee_numerator <= trade_fee_denominator);
    require(admin_trade_fee_denominator > 0);
    require(admin_trade_fee_numerator <= admin_trade_fee_denominator);
    require(withdraw_fee_denominator > 0);
    require(withdraw_fee_numerator <= withdraw_fee_denominator);
    require(admin_withdraw_fee_denominator > 0);
    require(admin_withdraw_fee_numerator <= admin_withdraw_fee_denominator);

    // All active token mints must be distinct
    require(token_mint_1 != token_mint_2);
    if (num_tokens >= 3) {
        require(token_mint_3 != token_mint_1);
        require(token_mint_3 != token_mint_2);
    }
    if (num_tokens >= 4) {
        require(token_mint_4 != token_mint_1);
        require(token_mint_4 != token_mint_2);
        require(token_mint_4 != token_mint_3);
    }

    // Token configuration
    pool.token_mint_1 = token_mint_1;
    pool.token_mint_2 = token_mint_2;
    pool.token_mint_3 = token_mint_3;
    pool.token_mint_4 = token_mint_4;
    pool.vault_1 = vault_1;
    pool.vault_2 = vault_2;
    pool.vault_3 = vault_3;
    pool.vault_4 = vault_4;
    pool.num_tokens = num_tokens;

    // Reserves start at zero
    pool.reserve_1 = 0;
    pool.reserve_2 = 0;
    pool.reserve_3 = 0;
    pool.reserve_4 = 0;

    // LP mint
    pool.lp_mint = lp_mint;
    pool.lp_supply = 0;

    // Amplification -- no ramp at initialization
    pool.initial_amp = amp;
    pool.target_amp = amp;
    pool.ramp_start_ts = 0;
    pool.ramp_stop_ts = 0;

    // Fee configuration
    pool.trade_fee_numerator = trade_fee_numerator;
    pool.trade_fee_denominator = trade_fee_denominator;
    pool.admin_trade_fee_numerator = admin_trade_fee_numerator;
    pool.admin_trade_fee_denominator = admin_trade_fee_denominator;
    pool.withdraw_fee_numerator = withdraw_fee_numerator;
    pool.withdraw_fee_denominator = withdraw_fee_denominator;
    pool.admin_withdraw_fee_numerator = admin_withdraw_fee_numerator;
    pool.admin_withdraw_fee_denominator = admin_withdraw_fee_denominator;

    // Admin fees start at zero
    pool.admin_fee_1 = 0;
    pool.admin_fee_2 = 0;
    pool.admin_fee_3 = 0;
    pool.admin_fee_4 = 0;

    // Administration
    pool.admin = admin.ctx.key;
    pool.is_paused = false;
}

/// Add liquidity to a multi-token stable pool. Any combination of token
/// amounts is valid (one-sided, balanced, or partial). Mints LP tokens
/// proportional to the change in invariant D, with imbalance fees.
pub add_liquidity(
    pool: StablePool @mut @signer,
    user_token_1: account @mut,
    user_token_2: account @mut,
    user_token_3: account @mut,
    user_token_4: account @mut,
    pool_vault_1: account @mut,
    pool_vault_2: account @mut,
    pool_vault_3: account @mut,
    pool_vault_4: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_1: u64,
    amount_2: u64,
    amount_3: u64,
    amount_4: u64,
    min_lp_amount: u64
) {
    require(!pool.is_paused);
    require(lp_mint.ctx.key == pool.lp_mint);
    require(pool_vault_1.ctx.key == pool.vault_1);
    require(pool_vault_2.ctx.key == pool.vault_2);

    // At least one deposit amount must be positive
    require(amount_1 > 0 || amount_2 > 0 || amount_3 > 0 || amount_4 > 0);

    // Validate vault keys for active tokens
    if (pool.num_tokens >= 3) {
        require(pool_vault_3.ctx.key == pool.vault_3);
    }
    if (pool.num_tokens >= 4) {
        require(pool_vault_4.ctx.key == pool.vault_4);
    }

    // Unused token slots must have zero deposit
    if (pool.num_tokens < 4) {
        require(amount_4 == 0);
    }
    if (pool.num_tokens < 3) {
        require(amount_3 == 0);
    }

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // New reserves after deposit
    let new_r1: u64 = pool.reserve_1 + amount_1;
    let new_r2: u64 = pool.reserve_2 + amount_2;
    let new_r3: u64 = pool.reserve_3 + amount_3;
    let new_r4: u64 = pool.reserve_4 + amount_4;

    // Compute invariant before and after
    let d0: u64 = compute_d(pool.reserve_1, pool.reserve_2, pool.reserve_3, pool.reserve_4, pool.num_tokens, amp);
    let d1: u64 = compute_d(new_r1, new_r2, new_r3, new_r4, pool.num_tokens, amp);
    require(d1 > d0);

    let mut lp_to_mint: u64 = 0;

    if (pool.lp_supply == 0) {
        // First deposit: LP tokens = D
        lp_to_mint = d1;
    } else {
        // Compute ideal balanced reserves and charge imbalance fee on deviation
        let ideal_r1: u64 = (pool.reserve_1 * d1) / d0;
        let ideal_r2: u64 = (pool.reserve_2 * d1) / d0;

        let diff_1: u64 = abs_diff(new_r1, ideal_r1);
        let diff_2: u64 = abs_diff(new_r2, ideal_r2);

        let fee_1: u64 = calculate_fee(diff_1, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
        let fee_2: u64 = calculate_fee(diff_2, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);

        let admin_f1: u64 = calculate_fee(fee_1, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
        let admin_f2: u64 = calculate_fee(fee_2, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
        pool.admin_fee_1 = pool.admin_fee_1 + admin_f1;
        pool.admin_fee_2 = pool.admin_fee_2 + admin_f2;

        let mut adj_r1: u64 = new_r1 - fee_1;
        let mut adj_r2: u64 = new_r2 - fee_2;
        let mut adj_r3: u64 = new_r3;
        let mut adj_r4: u64 = new_r4;

        if (pool.num_tokens >= 3) {
            let ideal_r3: u64 = (pool.reserve_3 * d1) / d0;
            let diff_3: u64 = abs_diff(new_r3, ideal_r3);
            let fee_3: u64 = calculate_fee(diff_3, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
            let admin_f3: u64 = calculate_fee(fee_3, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
            pool.admin_fee_3 = pool.admin_fee_3 + admin_f3;
            adj_r3 = new_r3 - fee_3;
        }

        if (pool.num_tokens >= 4) {
            let ideal_r4: u64 = (pool.reserve_4 * d1) / d0;
            let diff_4: u64 = abs_diff(new_r4, ideal_r4);
            let fee_4: u64 = calculate_fee(diff_4, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
            let admin_f4: u64 = calculate_fee(fee_4, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);
            pool.admin_fee_4 = pool.admin_fee_4 + admin_f4;
            adj_r4 = new_r4 - fee_4;
        }

        let d2: u64 = compute_d(adj_r1, adj_r2, adj_r3, adj_r4, pool.num_tokens, amp);
        lp_to_mint = (pool.lp_supply * (d2 - d0)) / d0;
    }

    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_amount);

    // Transfer tokens in
    if (amount_1 > 0) {
        spl_token::SPLToken::transfer(user_token_1, pool_vault_1, user_authority, amount_1);
    }
    if (amount_2 > 0) {
        spl_token::SPLToken::transfer(user_token_2, pool_vault_2, user_authority, amount_2);
    }
    if (amount_3 > 0) {
        spl_token::SPLToken::transfer(user_token_3, pool_vault_3, user_authority, amount_3);
    }
    if (amount_4 > 0) {
        spl_token::SPLToken::transfer(user_token_4, pool_vault_4, user_authority, amount_4);
    }

    // Mint LP tokens
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    // Update state
    pool.reserve_1 = new_r1;
    pool.reserve_2 = new_r2;
    pool.reserve_3 = new_r3;
    pool.reserve_4 = new_r4;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
}

/// Remove liquidity proportionally from all pool tokens by burning LP.
pub remove_liquidity(
    pool: StablePool @mut @signer,
    user_lp_account: account @mut,
    user_token_1: account @mut,
    user_token_2: account @mut,
    user_token_3: account @mut,
    user_token_4: account @mut,
    pool_vault_1: account @mut,
    pool_vault_2: account @mut,
    pool_vault_3: account @mut,
    pool_vault_4: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_1: u64,
    min_amount_2: u64,
    min_amount_3: u64,
    min_amount_4: u64
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(lp_mint.ctx.key == pool.lp_mint);
    require(pool_vault_1.ctx.key == pool.vault_1);
    require(pool_vault_2.ctx.key == pool.vault_2);

    if (pool.num_tokens >= 3) {
        require(pool_vault_3.ctx.key == pool.vault_3);
    }
    if (pool.num_tokens >= 4) {
        require(pool_vault_4.ctx.key == pool.vault_4);
    }

    // Proportional share of each reserve
    let out_1: u64 = (pool.reserve_1 * lp_amount) / pool.lp_supply;
    let out_2: u64 = (pool.reserve_2 * lp_amount) / pool.lp_supply;

    // Apply withdraw fee
    let fee_1: u64 = calculate_fee(out_1, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
    let fee_2: u64 = calculate_fee(out_2, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
    let net_1: u64 = out_1 - fee_1;
    let net_2: u64 = out_2 - fee_2;

    // Admin portion of withdraw fees
    let adm_1: u64 = calculate_fee(fee_1, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
    let adm_2: u64 = calculate_fee(fee_2, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
    pool.admin_fee_1 = pool.admin_fee_1 + adm_1;
    pool.admin_fee_2 = pool.admin_fee_2 + adm_2;

    require(net_1 > 0);
    require(net_2 > 0);
    require(net_1 >= min_amount_1);
    require(net_2 >= min_amount_2);

    // Burn LP tokens first
    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);

    // Transfer tokens out
    spl_token::SPLToken::transfer(pool_vault_1, user_token_1, pool, net_1);
    spl_token::SPLToken::transfer(pool_vault_2, user_token_2, pool, net_2);

    pool.reserve_1 = pool.reserve_1 - out_1;
    pool.reserve_2 = pool.reserve_2 - out_2;

    if (pool.num_tokens >= 3) {
        let out_3: u64 = (pool.reserve_3 * lp_amount) / pool.lp_supply;
        let fee_3: u64 = calculate_fee(out_3, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
        let net_3: u64 = out_3 - fee_3;
        let adm_3: u64 = calculate_fee(fee_3, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
        pool.admin_fee_3 = pool.admin_fee_3 + adm_3;
        require(net_3 >= min_amount_3);
        spl_token::SPLToken::transfer(pool_vault_3, user_token_3, pool, net_3);
        pool.reserve_3 = pool.reserve_3 - out_3;
    }

    if (pool.num_tokens >= 4) {
        let out_4: u64 = (pool.reserve_4 * lp_amount) / pool.lp_supply;
        let fee_4: u64 = calculate_fee(out_4, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
        let net_4: u64 = out_4 - fee_4;
        let adm_4: u64 = calculate_fee(fee_4, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);
        pool.admin_fee_4 = pool.admin_fee_4 + adm_4;
        require(net_4 >= min_amount_4);
        spl_token::SPLToken::transfer(pool_vault_4, user_token_4, pool, net_4);
        pool.reserve_4 = pool.reserve_4 - out_4;
    }

    pool.lp_supply = pool.lp_supply - lp_amount;
}

/// Withdraw all liquidity as a single token by burning LP tokens.
/// Uses the StableSwap curve to compute how much of one token the LP
/// share is worth, with withdraw fee on the imbalanced amount.
pub remove_liquidity_one_token(
    pool: StablePool @mut @signer,
    user_lp_account: account @mut,
    user_token_out: account @mut,
    pool_token_out_vault: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_out: u64,
    token_index: u8
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(token_index >= 1);
    require(token_index <= pool.num_tokens);

    // Validate the output vault matches the selected token
    if (token_index == 1) {
        require(pool_token_out_vault.ctx.key == pool.vault_1);
    }
    if (token_index == 2) {
        require(pool_token_out_vault.ctx.key == pool.vault_2);
    }
    if (token_index == 3) {
        require(pool_token_out_vault.ctx.key == pool.vault_3);
    }
    if (token_index == 4) {
        require(pool_token_out_vault.ctx.key == pool.vault_4);
    }

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // Current and post-burn invariants
    let d0: u64 = compute_d(pool.reserve_1, pool.reserve_2, pool.reserve_3, pool.reserve_4, pool.num_tokens, amp);
    let d1: u64 = d0 - (d0 * lp_amount) / pool.lp_supply;

    // Compute new balance of the withdrawal token using compute_y
    // We need the other token balances and solve for the target token
    let mut withdraw_reserve: u64 = 0;
    let mut new_balance: u64 = 0;

    if (pool.num_tokens == 2) {
        if (token_index == 1) {
            withdraw_reserve = pool.reserve_1;
            new_balance = compute_y_2(pool.reserve_2, d1, amp);
        } else {
            withdraw_reserve = pool.reserve_2;
            new_balance = compute_y_2(pool.reserve_1, d1, amp);
        }
    }

    if (pool.num_tokens == 3) {
        if (token_index == 1) {
            withdraw_reserve = pool.reserve_1;
            new_balance = compute_y_3(pool.reserve_2, pool.reserve_3, d1, amp);
        }
        if (token_index == 2) {
            withdraw_reserve = pool.reserve_2;
            new_balance = compute_y_3(pool.reserve_1, pool.reserve_3, d1, amp);
        }
        if (token_index == 3) {
            withdraw_reserve = pool.reserve_3;
            new_balance = compute_y_3(pool.reserve_1, pool.reserve_2, d1, amp);
        }
    }

    if (pool.num_tokens == 4) {
        if (token_index == 1) {
            withdraw_reserve = pool.reserve_1;
            new_balance = compute_y_4(pool.reserve_2, pool.reserve_3, pool.reserve_4, d1, amp);
        }
        if (token_index == 2) {
            withdraw_reserve = pool.reserve_2;
            new_balance = compute_y_4(pool.reserve_1, pool.reserve_3, pool.reserve_4, d1, amp);
        }
        if (token_index == 3) {
            withdraw_reserve = pool.reserve_3;
            new_balance = compute_y_4(pool.reserve_1, pool.reserve_2, pool.reserve_4, d1, amp);
        }
        if (token_index == 4) {
            withdraw_reserve = pool.reserve_4;
            new_balance = compute_y_4(pool.reserve_1, pool.reserve_2, pool.reserve_3, d1, amp);
        }
    }

    let gross_amount_out: u64 = withdraw_reserve - new_balance;
    require(gross_amount_out > 0);

    // Withdraw fee (single-sided is maximally imbalanced)
    let withdraw_fee: u64 = calculate_fee(gross_amount_out, pool.withdraw_fee_numerator, pool.withdraw_fee_denominator);
    let admin_fee: u64 = calculate_fee(withdraw_fee, pool.admin_withdraw_fee_numerator, pool.admin_withdraw_fee_denominator);

    let amount_out: u64 = gross_amount_out - withdraw_fee;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Burn LP tokens
    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);

    // Transfer token out
    spl_token::SPLToken::transfer(pool_token_out_vault, user_token_out, pool, amount_out);

    // Update reserve and admin fee for the withdrawn token
    if (token_index == 1) {
        pool.reserve_1 = pool.reserve_1 - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_1 = pool.admin_fee_1 + admin_fee;
    }
    if (token_index == 2) {
        pool.reserve_2 = pool.reserve_2 - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_2 = pool.admin_fee_2 + admin_fee;
    }
    if (token_index == 3) {
        pool.reserve_3 = pool.reserve_3 - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_3 = pool.admin_fee_3 + admin_fee;
    }
    if (token_index == 4) {
        pool.reserve_4 = pool.reserve_4 - gross_amount_out + (withdraw_fee - admin_fee);
        pool.admin_fee_4 = pool.admin_fee_4 + admin_fee;
    }

    pool.lp_supply = pool.lp_supply - lp_amount;
}

/// Swap between any two tokens in the pool using the StableSwap curve.
/// source_index and dest_index are 1-based token indices (1..4).
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
    source_index: u8,
    dest_index: u8
) {
    require(!pool.is_paused);
    require(amount_in > 0);
    require(source_index >= 1);
    require(source_index <= pool.num_tokens);
    require(dest_index >= 1);
    require(dest_index <= pool.num_tokens);
    require(source_index != dest_index);

    // Validate source vault
    if (source_index == 1) { require(pool_source_vault.ctx.key == pool.vault_1); }
    if (source_index == 2) { require(pool_source_vault.ctx.key == pool.vault_2); }
    if (source_index == 3) { require(pool_source_vault.ctx.key == pool.vault_3); }
    if (source_index == 4) { require(pool_source_vault.ctx.key == pool.vault_4); }

    // Validate destination vault
    if (dest_index == 1) { require(pool_destination_vault.ctx.key == pool.vault_1); }
    if (dest_index == 2) { require(pool_destination_vault.ctx.key == pool.vault_2); }
    if (dest_index == 3) { require(pool_destination_vault.ctx.key == pool.vault_3); }
    if (dest_index == 4) { require(pool_destination_vault.ctx.key == pool.vault_4); }

    // Read reserves for source and destination
    let mut source_reserve: u64 = 0;
    let mut dest_reserve: u64 = 0;
    if (source_index == 1) { source_reserve = pool.reserve_1; }
    if (source_index == 2) { source_reserve = pool.reserve_2; }
    if (source_index == 3) { source_reserve = pool.reserve_3; }
    if (source_index == 4) { source_reserve = pool.reserve_4; }
    if (dest_index == 1) { dest_reserve = pool.reserve_1; }
    if (dest_index == 2) { dest_reserve = pool.reserve_2; }
    if (dest_index == 3) { dest_reserve = pool.reserve_3; }
    if (dest_index == 4) { dest_reserve = pool.reserve_4; }

    require(source_reserve > 0);
    require(dest_reserve > 0);

    let current_ts: i64 = get_clock().unix_timestamp;
    let amp: u64 = get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );

    // Compute invariant D from current reserves
    let d: u64 = compute_d(pool.reserve_1, pool.reserve_2, pool.reserve_3, pool.reserve_4, pool.num_tokens, amp);

    // New source balance after receiving user's tokens
    let new_source: u64 = source_reserve + amount_in;

    // Build updated reserves and compute new dest balance via compute_y
    // We create a modified reserve set where source is updated, then solve for dest
    let mut r1: u64 = pool.reserve_1;
    let mut r2: u64 = pool.reserve_2;
    let mut r3: u64 = pool.reserve_3;
    let mut r4: u64 = pool.reserve_4;

    // Update the source reserve in our working copy
    if (source_index == 1) { r1 = new_source; }
    if (source_index == 2) { r2 = new_source; }
    if (source_index == 3) { r3 = new_source; }
    if (source_index == 4) { r4 = new_source; }

    // Compute new dest balance using the appropriate compute_y variant
    let mut new_dest: u64 = 0;

    if (pool.num_tokens == 2) {
        // For 2-token: the "other" balance is the updated source
        if (dest_index == 1) {
            new_dest = compute_y_2(r2, d, amp);
        } else {
            new_dest = compute_y_2(r1, d, amp);
        }
    }

    if (pool.num_tokens == 3) {
        if (dest_index == 1) {
            new_dest = compute_y_3(r2, r3, d, amp);
        }
        if (dest_index == 2) {
            new_dest = compute_y_3(r1, r3, d, amp);
        }
        if (dest_index == 3) {
            new_dest = compute_y_3(r1, r2, d, amp);
        }
    }

    if (pool.num_tokens == 4) {
        if (dest_index == 1) {
            new_dest = compute_y_4(r2, r3, r4, d, amp);
        }
        if (dest_index == 2) {
            new_dest = compute_y_4(r1, r3, r4, d, amp);
        }
        if (dest_index == 3) {
            new_dest = compute_y_4(r1, r2, r4, d, amp);
        }
        if (dest_index == 4) {
            new_dest = compute_y_4(r1, r2, r3, d, amp);
        }
    }

    // Gross output before fees
    let gross_amount_out: u64 = dest_reserve - new_dest;
    require(gross_amount_out > 0);

    // Trade fee on output
    let trade_fee: u64 = calculate_fee(gross_amount_out, pool.trade_fee_numerator, pool.trade_fee_denominator);
    let admin_fee: u64 = calculate_fee(trade_fee, pool.admin_trade_fee_numerator, pool.admin_trade_fee_denominator);

    let amount_out: u64 = gross_amount_out - trade_fee;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Execute token transfers
    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, pool, amount_out);

    // Update reserves
    if (source_index == 1) { pool.reserve_1 = pool.reserve_1 + amount_in; }
    if (source_index == 2) { pool.reserve_2 = pool.reserve_2 + amount_in; }
    if (source_index == 3) { pool.reserve_3 = pool.reserve_3 + amount_in; }
    if (source_index == 4) { pool.reserve_4 = pool.reserve_4 + amount_in; }

    if (dest_index == 1) {
        pool.reserve_1 = pool.reserve_1 - amount_out - admin_fee;
        pool.admin_fee_1 = pool.admin_fee_1 + admin_fee;
    }
    if (dest_index == 2) {
        pool.reserve_2 = pool.reserve_2 - amount_out - admin_fee;
        pool.admin_fee_2 = pool.admin_fee_2 + admin_fee;
    }
    if (dest_index == 3) {
        pool.reserve_3 = pool.reserve_3 - amount_out - admin_fee;
        pool.admin_fee_3 = pool.admin_fee_3 + admin_fee;
    }
    if (dest_index == 4) {
        pool.reserve_4 = pool.reserve_4 - amount_out - admin_fee;
        pool.admin_fee_4 = pool.admin_fee_4 + admin_fee;
    }
}

// ---------------------------------------------------------------------------
// Amplification ramping
// ---------------------------------------------------------------------------

/// Begin ramping the amplification coefficient from current value to target_amp
/// over the given duration. Minimum ramp time is 1 day, maximum 10x change.
pub ramp_amplification(
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
pub stop_ramp(
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

// ---------------------------------------------------------------------------
// Fee management
// ---------------------------------------------------------------------------

/// Update the pool's fee configuration. Only callable by admin.
pub set_fees(
    pool: StablePool @mut,
    admin: account @signer,
    trade_fee_numerator: u64,
    trade_fee_denominator: u64,
    admin_trade_fee_numerator: u64,
    admin_trade_fee_denominator: u64,
    withdraw_fee_numerator: u64,
    withdraw_fee_denominator: u64,
    admin_withdraw_fee_numerator: u64,
    admin_withdraw_fee_denominator: u64
) {
    require(pool.admin == admin.ctx.key);

    require(trade_fee_denominator > 0);
    require(trade_fee_numerator <= trade_fee_denominator);
    require(admin_trade_fee_denominator > 0);
    require(admin_trade_fee_numerator <= admin_trade_fee_denominator);
    require(withdraw_fee_denominator > 0);
    require(withdraw_fee_numerator <= withdraw_fee_denominator);
    require(admin_withdraw_fee_denominator > 0);
    require(admin_withdraw_fee_numerator <= admin_withdraw_fee_denominator);

    pool.trade_fee_numerator = trade_fee_numerator;
    pool.trade_fee_denominator = trade_fee_denominator;
    pool.admin_trade_fee_numerator = admin_trade_fee_numerator;
    pool.admin_trade_fee_denominator = admin_trade_fee_denominator;
    pool.withdraw_fee_numerator = withdraw_fee_numerator;
    pool.withdraw_fee_denominator = withdraw_fee_denominator;
    pool.admin_withdraw_fee_numerator = admin_withdraw_fee_numerator;
    pool.admin_withdraw_fee_denominator = admin_withdraw_fee_denominator;
}

// ---------------------------------------------------------------------------
// Vault strategies (idle liquidity yield optimization)
// ---------------------------------------------------------------------------

/// Create a vault for a pool token to earn yield on idle liquidity.
pub create_vault(
    vault: Vault @mut @init(payer=admin, space=512) @signer,
    pool: StablePool,
    admin: account @mut @signer,
    token_mint: pubkey,
    token_vault: pubkey,
    strategy_type: u8,
    strategy_program: pubkey
) {
    require(pool.admin == admin.ctx.key);

    // Validate that the token_mint belongs to this pool
    let mut valid_token: bool = false;
    if (token_mint == pool.token_mint_1) { valid_token = true; }
    if (token_mint == pool.token_mint_2) { valid_token = true; }
    if (pool.num_tokens >= 3) {
        if (token_mint == pool.token_mint_3) { valid_token = true; }
    }
    if (pool.num_tokens >= 4) {
        if (token_mint == pool.token_mint_4) { valid_token = true; }
    }
    require(valid_token);

    // strategy_type: 0 = lending, 1 = staking, 2 = farming
    require(strategy_type <= 2);

    vault.pool = pool.ctx.key;
    vault.token_mint = token_mint;
    vault.token_vault = token_vault;
    vault.strategy_type = strategy_type;
    vault.strategy_program = strategy_program;
    vault.deposited_amount = 0;
    vault.last_harvest_slot = get_clock().slot;
    vault.admin = admin.ctx.key;
    vault.is_active = true;
}

/// Deposit idle pool liquidity into a vault strategy for yield.
pub deposit_to_vault(
    pool: StablePool @mut @signer,
    vault: Vault @mut,
    pool_token_vault: account @mut,
    strategy_account: account @mut,
    admin: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.admin == admin.ctx.key);
    require(vault.pool == pool.ctx.key);
    require(vault.is_active);
    require(!pool.is_paused);
    require(amount > 0);

    // Validate the vault's token_vault matches a pool vault
    if (vault.token_mint == pool.token_mint_1) {
        require(pool_token_vault.ctx.key == pool.vault_1);
        require(amount <= pool.reserve_1);
    }
    if (vault.token_mint == pool.token_mint_2) {
        require(pool_token_vault.ctx.key == pool.vault_2);
        require(amount <= pool.reserve_2);
    }
    if (vault.token_mint == pool.token_mint_3) {
        require(pool_token_vault.ctx.key == pool.vault_3);
        require(amount <= pool.reserve_3);
    }
    if (vault.token_mint == pool.token_mint_4) {
        require(pool_token_vault.ctx.key == pool.vault_4);
        require(amount <= pool.reserve_4);
    }

    // Transfer tokens from pool vault to strategy
    spl_token::SPLToken::transfer(pool_token_vault, strategy_account, pool, amount);

    vault.deposited_amount = vault.deposited_amount + amount;
    vault.last_harvest_slot = get_clock().slot;
}

/// Withdraw liquidity from a vault strategy back to the pool.
pub withdraw_from_vault(
    pool: StablePool @mut @signer,
    vault: Vault @mut,
    pool_token_vault: account @mut,
    strategy_account: account @mut,
    strategy_authority: account @signer,
    admin: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.admin == admin.ctx.key);
    require(vault.pool == pool.ctx.key);
    require(amount > 0);
    require(amount <= vault.deposited_amount);

    // Transfer tokens from strategy back to pool vault
    spl_token::SPLToken::transfer(strategy_account, pool_token_vault, strategy_authority, amount);

    vault.deposited_amount = vault.deposited_amount - amount;
    vault.last_harvest_slot = get_clock().slot;
}

/// Configure or update the vault yield strategy.
pub set_vault_strategy(
    vault: Vault @mut,
    pool: StablePool,
    admin: account @signer,
    new_strategy_type: u8,
    new_strategy_program: pubkey,
    is_active: bool
) {
    require(pool.admin == admin.ctx.key);
    require(vault.pool == pool.ctx.key);
    require(new_strategy_type <= 2);

    // Cannot change strategy while funds are deposited
    if (new_strategy_type != vault.strategy_type) {
        require(vault.deposited_amount == 0);
    }

    vault.strategy_type = new_strategy_type;
    vault.strategy_program = new_strategy_program;
    vault.is_active = is_active;
}

// ---------------------------------------------------------------------------
// Admin instructions
// ---------------------------------------------------------------------------

/// Collect accumulated admin fees from the pool vaults.
pub collect_admin_fees(
    pool: StablePool @mut @signer,
    pool_vault_1: account @mut,
    pool_vault_2: account @mut,
    pool_vault_3: account @mut,
    pool_vault_4: account @mut,
    recipient_1: account @mut,
    recipient_2: account @mut,
    recipient_3: account @mut,
    recipient_4: account @mut,
    admin: account @signer,
    token_program: account
) {
    require(pool.admin == admin.ctx.key);
    require(pool_vault_1.ctx.key == pool.vault_1);
    require(pool_vault_2.ctx.key == pool.vault_2);

    if (pool.admin_fee_1 > 0) {
        spl_token::SPLToken::transfer(pool_vault_1, recipient_1, pool, pool.admin_fee_1);
        pool.admin_fee_1 = 0;
    }

    if (pool.admin_fee_2 > 0) {
        spl_token::SPLToken::transfer(pool_vault_2, recipient_2, pool, pool.admin_fee_2);
        pool.admin_fee_2 = 0;
    }

    if (pool.num_tokens >= 3) {
        require(pool_vault_3.ctx.key == pool.vault_3);
        if (pool.admin_fee_3 > 0) {
            spl_token::SPLToken::transfer(pool_vault_3, recipient_3, pool, pool.admin_fee_3);
            pool.admin_fee_3 = 0;
        }
    }

    if (pool.num_tokens >= 4) {
        require(pool_vault_4.ctx.key == pool.vault_4);
        if (pool.admin_fee_4 > 0) {
            spl_token::SPLToken::transfer(pool_vault_4, recipient_4, pool, pool.admin_fee_4);
            pool.admin_fee_4 = 0;
        }
    }
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

// ---------------------------------------------------------------------------
// View helpers
// ---------------------------------------------------------------------------

pub get_reserve(pool: StablePool, token_index: u8) -> u64 {
    if (token_index == 1) { return pool.reserve_1; }
    if (token_index == 2) { return pool.reserve_2; }
    if (token_index == 3) { return pool.reserve_3; }
    return pool.reserve_4;
}

pub get_lp_supply(pool: StablePool) -> u64 {
    return pool.lp_supply;
}

pub get_amp(pool: StablePool) -> u64 {
    let current_ts: i64 = get_clock().unix_timestamp;
    return get_current_amp(
        pool.initial_amp, pool.target_amp,
        pool.ramp_start_ts, pool.ramp_stop_ts, current_ts
    );
}

pub get_admin_fee(pool: StablePool, token_index: u8) -> u64 {
    if (token_index == 1) { return pool.admin_fee_1; }
    if (token_index == 2) { return pool.admin_fee_2; }
    if (token_index == 3) { return pool.admin_fee_3; }
    return pool.admin_fee_4;
}

pub get_num_tokens(pool: StablePool) -> u8 {
    return pool.num_tokens;
}
