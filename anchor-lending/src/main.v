// Anchor Protocol Lending -- 5ive DSL Migration
//
// Anchor was originally a Terra lending protocol known for its fixed-rate
// yield model (~20% APY on deposits). This migration adapts the concept
// to Solana, preserving the core innovations:
//
//   - Fixed deposit rate: target a stable APY instead of floating rates
//   - Yield reserve: buffer fund that subsidizes deposit rates when
//     borrow interest falls short
//   - Staked collateral (bAssets): borrowers deposit liquid staking
//     tokens; protocol captures staking yield to fund the reserve
//   - Liquidation queue: liquidators bid at discount tiers (1-30%)
//     instead of instant liquidation
//   - Dynamic rate rebalancing: borrow rate adjusted to maintain the
//     target deposit rate given current utilization
//
// Math is integer-only. Indices use u128 (10^18 scale) stored as
// hi/lo u64 pairs. Rates are in basis points (bps, 1/10000).
// Time uses slot-based deltas with SLOTS_PER_YEAR = 63_072_000.

use std::interfaces::spl_token;

// ─────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────

account AnchorMarket {
    authority: pubkey;
    borrow_mint: pubkey;
    borrow_vault: pubkey;
    atoken_mint: pubkey;
    yield_reserve_vault: pubkey;
    target_deposit_rate_bps: u64;
    current_deposit_rate_bps: u64;
    current_borrow_rate_bps: u64;
    total_deposits: u64;
    total_borrows: u64;
    deposit_index_hi: u64;
    deposit_index_lo: u64;
    borrow_index_hi: u64;
    borrow_index_lo: u64;
    yield_reserve_balance: u64;
    last_update_slot: u64;
    num_collateral_types: u8;
    is_paused: bool;
}

account CollateralConfig {
    market: pubkey;
    collateral_mint: pubkey;
    collateral_vault: pubkey;
    oracle: pubkey;
    ltv_ratio: u16;
    liquidation_threshold: u16;
    liquidation_bonus: u16;
    total_deposited: u64;
    is_basset: bool;
    basset_reward_rate: u64;
    is_active: bool;
}

account UserPosition {
    market: pubkey;
    owner: pubkey;
    deposit_shares: u64;
    borrow_shares: u64;
    collateral_1_config: pubkey;
    collateral_1_amount: u64;
    collateral_2_config: pubkey;
    collateral_2_amount: u64;
    last_deposit_index_hi: u64;
    last_deposit_index_lo: u64;
    last_borrow_index_hi: u64;
    last_borrow_index_lo: u64;
}

account LiquidationBid {
    market: pubkey;
    bidder: pubkey;
    bid_amount: u64;
    discount_tier: u8;
    filled_amount: u64;
    collateral_received: u64;
    is_active: bool;
}

account OraclePrice {
    collateral_config: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

// ─────────────────────────────────────────────────────────────────
// Constants (inline)
// ─────────────────────────────────────────────────────────────────

// INDEX_SCALE = 10^18 stored as lo=10^18 (fits u64 max ~1.8*10^19)
// INDEX_INIT_LO = 1_000_000_000_000_000_000  (1.0 scaled)
// SCALE9 = 1_000_000_000  (10^9, intermediate scaling)
// SLOTS_PER_YEAR = 63_072_000  (2 slots/sec * 31_536_000 sec/year)
// BPS_SCALE = 10_000
// ORACLE_STALE_SLOTS = 100
// MAX_DISCOUNT_TIER = 30  (30% max liquidation discount)
// BASSET_RESERVE_SHARE = 80  (80% of bAsset rewards -> yield reserve)
// BASSET_BORROWER_SHARE = 20 (20% -> borrower rate discount)

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// Scale down a u64 by 10^9 for safe intermediate multiplication
fn scale_down(v: u64) -> u64 {
    return v / 1000000000;
}

// Multiply two index-scaled values: (a * b) / 10^18
// Uses 10^9 decomposition to avoid overflow
fn idx_mul(a_lo: u64, b_lo: u64) -> u64 {
    if (a_lo == 0) {
        return 0;
    }
    if (b_lo == 0) {
        return 0;
    }
    let a_s: u64 = a_lo / 1000000000;
    let b_s: u64 = b_lo / 1000000000;
    return a_s * b_s;
}

// Divide with index scale: (a * 10^18) / b
// Approximated via (a * 10^9 / b) * 10^9
fn idx_div(a_lo: u64, b_lo: u64) -> u64 {
    require(b_lo > 0);
    let a_s: u64 = a_lo * 1000000000;
    return (a_s / b_lo) * 1000000000;
}

// Convert a real token amount to index representation (amount * 10^9)
// We use 10^9 intermediate scale to stay within u64 range
fn to_index_lo(amount: u64) -> u64 {
    return amount * 1000000000;
}

// Convert index lo back to token amount
fn from_index_lo(lo: u64) -> u64 {
    return lo / 1000000000;
}

// Calculate time-weighted interest: principal * rate_bps * slots / (SLOTS_PER_YEAR * BPS_SCALE)
fn calc_interest(principal: u64, rate_bps: u64, slots_elapsed: u64) -> u64 {
    if (principal == 0) {
        return 0;
    }
    if (rate_bps == 0) {
        return 0;
    }
    if (slots_elapsed == 0) {
        return 0;
    }
    // principal * rate_bps * slots_elapsed / (63_072_000 * 10_000)
    // = principal * rate_bps * slots_elapsed / 630_720_000_000
    // Break into steps to avoid overflow:
    // step1 = principal * rate_bps (safe if principal < ~10^14 and rate < 10^5)
    // step2 = step1 / 630720  (reduce denominator in parts)
    // step3 = step2 * slots_elapsed / 1000000
    let step1: u64 = (principal / 10000) * rate_bps;
    let step2: u64 = (step1 * slots_elapsed) / 63072000;
    return step2;
}

// Collateral value in borrow token terms: amount * price / 10^decimals
fn collateral_value(amount: u64, price: u64, decimals: u8) -> u64 {
    if (amount == 0) {
        return 0;
    }
    let mut divisor: u64 = 1;
    let mut i: u8 = 0;
    // 10^decimals via loop
    if (decimals >= 1) {
        divisor = 10;
    }
    if (decimals >= 2) {
        divisor = 100;
    }
    if (decimals >= 3) {
        divisor = 1000;
    }
    if (decimals >= 4) {
        divisor = 10000;
    }
    if (decimals >= 5) {
        divisor = 100000;
    }
    if (decimals >= 6) {
        divisor = 1000000;
    }
    if (decimals >= 7) {
        divisor = 10000000;
    }
    if (decimals >= 8) {
        divisor = 100000000;
    }
    if (decimals >= 9) {
        divisor = 1000000000;
    }
    if (decimals == 0) {
        divisor = 1;
    }
    return (amount * price) / divisor;
}

// Get total collateral value for a user position in borrow token terms
fn get_user_collateral_value(
    position: UserPosition,
    config1: CollateralConfig,
    oracle1: OraclePrice,
    config2: CollateralConfig,
    oracle2: OraclePrice
) -> u64 {
    let mut total: u64 = 0;
    if (position.collateral_1_amount > 0) {
        total = total + collateral_value(position.collateral_1_amount, oracle1.price, oracle1.decimals);
    }
    if (position.collateral_2_amount > 0) {
        total = total + collateral_value(position.collateral_2_amount, oracle2.price, oracle2.decimals);
    }
    return total;
}

// Get LTV-weighted borrow limit for a user position
fn get_user_borrow_limit(
    position: UserPosition,
    config1: CollateralConfig,
    oracle1: OraclePrice,
    config2: CollateralConfig,
    oracle2: OraclePrice
) -> u64 {
    let mut total: u64 = 0;
    if (position.collateral_1_amount > 0) {
        let val: u64 = collateral_value(position.collateral_1_amount, oracle1.price, oracle1.decimals);
        total = total + (val * config1.ltv_ratio as u64) / 10000;
    }
    if (position.collateral_2_amount > 0) {
        let val: u64 = collateral_value(position.collateral_2_amount, oracle2.price, oracle2.decimals);
        total = total + (val * config2.ltv_ratio as u64) / 10000;
    }
    return total;
}

// Get liquidation threshold value for a user position
fn get_user_liquidation_threshold(
    position: UserPosition,
    config1: CollateralConfig,
    oracle1: OraclePrice,
    config2: CollateralConfig,
    oracle2: OraclePrice
) -> u64 {
    let mut total: u64 = 0;
    if (position.collateral_1_amount > 0) {
        let val: u64 = collateral_value(position.collateral_1_amount, oracle1.price, oracle1.decimals);
        total = total + (val * config1.liquidation_threshold as u64) / 10000;
    }
    if (position.collateral_2_amount > 0) {
        let val: u64 = collateral_value(position.collateral_2_amount, oracle2.price, oracle2.decimals);
        total = total + (val * config2.liquidation_threshold as u64) / 10000;
    }
    return total;
}

// ─────────────────────────────────────────────────────────────────
// 1. initialize_market
// ─────────────────────────────────────────────────────────────────

pub initialize_market(
    market: AnchorMarket @mut @init(payer=authority, space=800),
    authority: account @signer,
    borrow_mint: spl_token::Mint @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    atoken_mint: spl_token::Mint @mut @serializer("raw"),
    yield_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    target_deposit_rate_bps: u64
) {
    require(target_deposit_rate_bps > 0);
    require(target_deposit_rate_bps <= 5000);

    market.authority = authority.ctx.key;
    market.borrow_mint = borrow_mint.ctx.key;
    market.borrow_vault = borrow_vault.ctx.key;
    market.atoken_mint = atoken_mint.ctx.key;
    market.yield_reserve_vault = yield_reserve_vault.ctx.key;
    market.target_deposit_rate_bps = target_deposit_rate_bps;
    market.current_deposit_rate_bps = target_deposit_rate_bps;
    market.current_borrow_rate_bps = target_deposit_rate_bps;
    market.total_deposits = 0;
    market.total_borrows = 0;
    // Index starts at 1.0 (10^18) -> lo = 10^18, hi = 0
    market.deposit_index_hi = 0;
    market.deposit_index_lo = 1000000000000000000;
    market.borrow_index_hi = 0;
    market.borrow_index_lo = 1000000000000000000;
    market.yield_reserve_balance = 0;
    market.last_update_slot = get_clock().slot;
    market.num_collateral_types = 0;
    market.is_paused = false;
}

// ─────────────────────────────────────────────────────────────────
// 2. register_collateral
// ─────────────────────────────────────────────────────────────────

pub register_collateral(
    market: AnchorMarket @mut,
    config: CollateralConfig @mut @init(payer=authority, space=600),
    authority: account @signer,
    collateral_mint: spl_token::Mint @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    oracle: OraclePrice,
    ltv_ratio: u16,
    liquidation_threshold: u16,
    liquidation_bonus: u16,
    is_basset: bool,
    basset_reward_rate: u64
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_paused);
    require(ltv_ratio > 0);
    require(ltv_ratio < 10000);
    require(liquidation_threshold > ltv_ratio);
    require(liquidation_threshold <= 9500);
    require(liquidation_bonus > 0);
    require(liquidation_bonus <= 3000);
    require(market.num_collateral_types < 10);

    config.market = market.ctx.key;
    config.collateral_mint = collateral_mint.ctx.key;
    config.collateral_vault = collateral_vault.ctx.key;
    config.oracle = oracle.ctx.key;
    config.ltv_ratio = ltv_ratio;
    config.liquidation_threshold = liquidation_threshold;
    config.liquidation_bonus = liquidation_bonus;
    config.total_deposited = 0;
    config.is_basset = is_basset;
    config.basset_reward_rate = basset_reward_rate;
    config.is_active = true;

    market.num_collateral_types = market.num_collateral_types + 1;
}

// ─────────────────────────────────────────────────────────────────
// 3. register_borrow_token  (validates borrow side config)
// ─────────────────────────────────────────────────────────────────

pub register_borrow_token(
    market: AnchorMarket @mut,
    authority: account @signer,
    borrow_mint: spl_token::Mint @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    atoken_mint: spl_token::Mint @mut @serializer("raw")
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_paused);
    // Re-register / validate that mint matches
    require(market.borrow_mint == borrow_mint.ctx.key);
    market.borrow_vault = borrow_vault.ctx.key;
    market.atoken_mint = atoken_mint.ctx.key;
}

// ─────────────────────────────────────────────────────────────────
// 4. fund_yield_reserve
// ─────────────────────────────────────────────────────────────────

pub fund_yield_reserve(
    market: AnchorMarket @mut,
    authority: account @signer,
    funder_token: spl_token::TokenAccount @mut @serializer("raw"),
    yield_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_paused);
    require(amount > 0);
    require(market.yield_reserve_vault == yield_reserve_vault.ctx.key);

    spl_token::SPLToken::transfer(funder_token, yield_reserve_vault, authority, amount);

    market.yield_reserve_balance = market.yield_reserve_balance + amount;
}

// ─────────────────────────────────────────────────────────────────
// 5. deposit_stable  (Earn side: deposit stablecoins, receive aTokens)
// ─────────────────────────────────────────────────────────────────

pub deposit_stable(
    market: AnchorMarket @mut,
    position: UserPosition @mut,
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    atoken_mint: spl_token::Mint @mut @serializer("raw"),
    user_atoken: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    depositor: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(position.market == market.ctx.key);
    require(position.owner == depositor.ctx.key);
    require(market.borrow_vault == borrow_vault.ctx.key);
    require(market.atoken_mint == atoken_mint.ctx.key);

    // aToken exchange rate: aTokens = amount * atoken_supply / total_underlying
    // If first deposit, 1:1
    let mut shares: u64 = amount;
    if (market.total_deposits > 0) {
        // Use deposit index to compute shares
        // shares = amount * INDEX_INIT / current_deposit_index
        let index_init: u64 = 1000000000000000000;
        shares = (amount * index_init) / market.deposit_index_lo;
        if (shares == 0) {
            shares = 1;
        }
    }

    spl_token::SPLToken::transfer(user_token, borrow_vault, depositor, amount);
    spl_token::SPLToken::mint_to(atoken_mint, user_atoken, market_authority, shares);

    market.total_deposits = market.total_deposits + amount;
    position.deposit_shares = position.deposit_shares + shares;
    position.last_deposit_index_hi = market.deposit_index_hi;
    position.last_deposit_index_lo = market.deposit_index_lo;
}

// ─────────────────────────────────────────────────────────────────
// 6. withdraw_stable  (Burn aTokens, receive stablecoins + yield)
// ─────────────────────────────────────────────────────────────────

pub withdraw_stable(
    market: AnchorMarket @mut,
    position: UserPosition @mut,
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    atoken_mint: spl_token::Mint @mut @serializer("raw"),
    user_atoken: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    depositor: account @signer,
    token_program: account,
    shares_to_burn: u64
) {
    require(!market.is_paused);
    require(shares_to_burn > 0);
    require(position.market == market.ctx.key);
    require(position.owner == depositor.ctx.key);
    require(position.deposit_shares >= shares_to_burn);
    require(market.borrow_vault == borrow_vault.ctx.key);
    require(market.atoken_mint == atoken_mint.ctx.key);

    // Redeem value: shares * current_deposit_index / INDEX_INIT
    let index_init: u64 = 1000000000000000000;
    let redeem_amount: u64 = (shares_to_burn * market.deposit_index_lo) / index_init;
    require(redeem_amount > 0);
    require(redeem_amount <= market.total_deposits);

    spl_token::SPLToken::burn(user_atoken, atoken_mint, depositor, shares_to_burn);
    spl_token::SPLToken::transfer(borrow_vault, user_token, market_authority, redeem_amount);

    market.total_deposits = market.total_deposits - redeem_amount;
    position.deposit_shares = position.deposit_shares - shares_to_burn;
    position.last_deposit_index_hi = market.deposit_index_hi;
    position.last_deposit_index_lo = market.deposit_index_lo;
}

// ─────────────────────────────────────────────────────────────────
// 7. accrue_yield  (Update deposit index, distribute yield)
// ─────────────────────────────────────────────────────────────────

pub accrue_yield(
    market: AnchorMarket @mut,
    market_authority: account @signer
) {
    require(!market.is_paused);
    let now: u64 = get_clock().slot;
    let slots_elapsed: u64 = now - market.last_update_slot;
    if (slots_elapsed == 0) {
        return;
    }

    // Interest earned from borrows
    let interest_earned: u64 = calc_interest(market.total_borrows, market.current_borrow_rate_bps, slots_elapsed);

    // Yield needed to meet target deposit rate
    let yield_needed: u64 = calc_interest(market.total_deposits, market.target_deposit_rate_bps, slots_elapsed);

    // Update borrow index
    if (market.total_borrows > 0) {
        let borrow_index_delta: u64 = (market.borrow_index_lo * market.current_borrow_rate_bps * slots_elapsed) / (63072000 * 10000);
        market.borrow_index_lo = market.borrow_index_lo + borrow_index_delta;
    }

    // Track borrows growth from interest
    market.total_borrows = market.total_borrows + interest_earned;

    // Fixed rate mechanism: subsidize or accumulate
    let mut actual_deposit_yield: u64 = 0;
    if (interest_earned >= yield_needed) {
        // Surplus: borrow interest covers target; excess to yield reserve
        actual_deposit_yield = yield_needed;
        let surplus: u64 = interest_earned - yield_needed;
        market.yield_reserve_balance = market.yield_reserve_balance + surplus;
        market.current_deposit_rate_bps = market.target_deposit_rate_bps;
    } else {
        // Deficit: draw from yield reserve to meet target
        let deficit: u64 = yield_needed - interest_earned;
        if (market.yield_reserve_balance >= deficit) {
            // Full subsidy: depositors get target rate
            actual_deposit_yield = yield_needed;
            market.yield_reserve_balance = market.yield_reserve_balance - deficit;
            market.current_deposit_rate_bps = market.target_deposit_rate_bps;
        } else {
            // Partial subsidy: deposit rate reduced proportionally
            actual_deposit_yield = interest_earned + market.yield_reserve_balance;
            market.yield_reserve_balance = 0;
            // Compute effective rate: actual_yield * BPS_SCALE * SLOTS_PER_YEAR / (deposits * slots)
            if (market.total_deposits > 0) {
                let effective_bps: u64 = (actual_deposit_yield * 10000 * 63072000) / (market.total_deposits * slots_elapsed);
                market.current_deposit_rate_bps = effective_bps;
            }
        }
    }

    // Update deposit index: index *= (1 + actual_rate * slots / (SLOTS_PER_YEAR * BPS))
    if (market.total_deposits > 0) {
        let deposit_index_delta: u64 = (market.deposit_index_lo * market.current_deposit_rate_bps * slots_elapsed) / (63072000 * 10000);
        market.deposit_index_lo = market.deposit_index_lo + deposit_index_delta;
    }

    market.total_deposits = market.total_deposits + actual_deposit_yield;
    market.last_update_slot = now;
}

// ─────────────────────────────────────────────────────────────────
// 8. deposit_collateral
// ─────────────────────────────────────────────────────────────────

pub deposit_collateral(
    market: AnchorMarket,
    config: CollateralConfig @mut,
    position: UserPosition @mut,
    user_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    depositor: account @signer,
    token_program: account,
    amount: u64,
    slot_index: u8
) {
    require(!market.is_paused);
    require(amount > 0);
    require(config.is_active);
    require(config.market == market.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == depositor.ctx.key);
    require(config.collateral_vault == collateral_vault.ctx.key);
    require(slot_index == 1 || slot_index == 2);

    spl_token::SPLToken::transfer(user_collateral_token, collateral_vault, depositor, amount);

    config.total_deposited = config.total_deposited + amount;

    if (slot_index == 1) {
        // Assign or add to slot 1
        if (position.collateral_1_amount == 0) {
            position.collateral_1_config = config.ctx.key;
        }
        require(position.collateral_1_config == config.ctx.key);
        position.collateral_1_amount = position.collateral_1_amount + amount;
    } else {
        // Assign or add to slot 2
        if (position.collateral_2_amount == 0) {
            position.collateral_2_config = config.ctx.key;
        }
        require(position.collateral_2_config == config.ctx.key);
        position.collateral_2_amount = position.collateral_2_amount + amount;
    }
}

// ─────────────────────────────────────────────────────────────────
// 9. withdraw_collateral
// ─────────────────────────────────────────────────────────────────

pub withdraw_collateral(
    market: AnchorMarket,
    config1: CollateralConfig @mut,
    config2: CollateralConfig,
    position: UserPosition @mut,
    oracle1: OraclePrice,
    oracle2: OraclePrice,
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    withdrawer: account @signer,
    token_program: account,
    amount: u64,
    slot_index: u8
) {
    require(!market.is_paused);
    require(amount > 0);
    require(config1.is_active);
    require(config1.market == market.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == withdrawer.ctx.key);
    require(config1.collateral_vault == collateral_vault.ctx.key);
    require(slot_index == 1 || slot_index == 2);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle1.last_update <= 100);
    require(now - oracle2.last_update <= 100);

    // Withdraw from the specified slot
    if (slot_index == 1) {
        require(position.collateral_1_config == config1.ctx.key);
        require(position.collateral_1_amount >= amount);
        position.collateral_1_amount = position.collateral_1_amount - amount;
    } else {
        require(position.collateral_2_config == config1.ctx.key);
        require(position.collateral_2_amount >= amount);
        position.collateral_2_amount = position.collateral_2_amount - amount;
    }

    config1.total_deposited = config1.total_deposited - amount;

    // Health check after withdrawal: borrow_value <= liquidation_threshold_value
    if (position.borrow_shares > 0) {
        let liq_threshold: u64 = get_user_liquidation_threshold(position, config1, oracle1, config2, oracle2);
        // Compute current borrow value from shares and index
        let index_init: u64 = 1000000000000000000;
        let borrow_value: u64 = (position.borrow_shares * market.borrow_index_lo) / index_init;
        require(borrow_value <= liq_threshold);
    }

    spl_token::SPLToken::transfer(collateral_vault, user_collateral_token, market_authority, amount);
}

// ─────────────────────────────────────────────────────────────────
// 10. borrow
// ─────────────────────────────────────────────────────────────────

pub borrow(
    market: AnchorMarket @mut,
    config1: CollateralConfig,
    config2: CollateralConfig,
    position: UserPosition @mut,
    oracle1: OraclePrice,
    oracle2: OraclePrice,
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    borrower: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(position.market == market.ctx.key);
    require(position.owner == borrower.ctx.key);
    require(market.borrow_vault == borrow_vault.ctx.key);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle1.last_update <= 100);
    require(now - oracle2.last_update <= 100);

    // Convert amount to borrow shares
    let index_init: u64 = 1000000000000000000;
    let new_shares: u64 = (amount * index_init) / market.borrow_index_lo;
    require(new_shares > 0);

    let new_total_shares: u64 = position.borrow_shares + new_shares;

    // Current borrow value after adding new shares
    let new_borrow_value: u64 = (new_total_shares * market.borrow_index_lo) / index_init;

    // LTV check: borrow_value <= borrow_limit
    let borrow_limit: u64 = get_user_borrow_limit(position, config1, oracle1, config2, oracle2);
    require(new_borrow_value <= borrow_limit);

    // Sufficient liquidity check
    require(amount <= market.total_deposits - market.total_borrows + market.total_borrows);
    // Actual liquidity in vault
    let available: u64 = market.total_deposits - market.total_borrows;
    require(amount <= available);

    spl_token::SPLToken::transfer(borrow_vault, user_token, market_authority, amount);

    market.total_borrows = market.total_borrows + amount;
    position.borrow_shares = new_total_shares;
    position.last_borrow_index_hi = market.borrow_index_hi;
    position.last_borrow_index_lo = market.borrow_index_lo;
}

// ─────────────────────────────────────────────────────────────────
// 11. repay
// ─────────────────────────────────────────────────────────────────

pub repay(
    market: AnchorMarket @mut,
    position: UserPosition @mut,
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    repayer: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(position.market == market.ctx.key);
    require(position.owner == repayer.ctx.key);
    require(market.borrow_vault == borrow_vault.ctx.key);
    require(position.borrow_shares > 0);

    // Compute outstanding borrow value
    let index_init: u64 = 1000000000000000000;
    let outstanding: u64 = (position.borrow_shares * market.borrow_index_lo) / index_init;

    // Clamp repay amount
    let mut repay_amount: u64 = amount;
    if (repay_amount > outstanding) {
        repay_amount = outstanding;
    }

    // Compute shares to retire
    let shares_to_retire: u64 = (repay_amount * index_init) / market.borrow_index_lo;
    let mut actual_shares: u64 = shares_to_retire;
    if (actual_shares > position.borrow_shares) {
        actual_shares = position.borrow_shares;
    }

    spl_token::SPLToken::transfer(user_token, borrow_vault, repayer, repay_amount);

    position.borrow_shares = position.borrow_shares - actual_shares;
    if (market.total_borrows >= repay_amount) {
        market.total_borrows = market.total_borrows - repay_amount;
    } else {
        market.total_borrows = 0;
    }

    position.last_borrow_index_hi = market.borrow_index_hi;
    position.last_borrow_index_lo = market.borrow_index_lo;
}

// ─────────────────────────────────────────────────────────────────
// 12. claim_basset_rewards  (Capture staking rewards from bAsset collateral)
// ─────────────────────────────────────────────────────────────────

pub claim_basset_rewards(
    market: AnchorMarket @mut,
    config: CollateralConfig,
    yield_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    reward_source: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(config.is_basset);
    require(config.is_active);
    require(config.market == market.ctx.key);
    require(market.yield_reserve_vault == yield_reserve_vault.ctx.key);

    let now: u64 = get_clock().slot;
    let slots_elapsed: u64 = now - market.last_update_slot;

    // reward_amount = total_deposited * basset_reward_rate * slots / (SLOTS_PER_YEAR * BPS)
    let reward_amount: u64 = calc_interest(config.total_deposited, config.basset_reward_rate, slots_elapsed);
    require(reward_amount > 0);

    // 80% to yield reserve, 20% stays as borrower rate discount (accounted in rebalance)
    let reserve_share: u64 = (reward_amount * 80) / 100;

    spl_token::SPLToken::transfer(reward_source, yield_reserve_vault, market_authority, reserve_share);

    market.yield_reserve_balance = market.yield_reserve_balance + reserve_share;
}

// ─────────────────────────────────────────────────────────────────
// 13. distribute_basset_rewards
// ─────────────────────────────────────────────────────────────────

pub distribute_basset_rewards(
    market: AnchorMarket @mut,
    config: CollateralConfig,
    yield_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    reward_source: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(config.is_basset);
    require(config.is_active);
    require(config.market == market.ctx.key);
    require(market.yield_reserve_vault == yield_reserve_vault.ctx.key);

    let now: u64 = get_clock().slot;
    let slots_elapsed: u64 = now - market.last_update_slot;

    let reward_amount: u64 = calc_interest(config.total_deposited, config.basset_reward_rate, slots_elapsed);

    // 20% applied as borrower rate discount (reduces effective borrow rate)
    let borrower_discount: u64 = (reward_amount * 20) / 100;

    // Apply discount: reduce total borrows by discount amount (lowers interest owed)
    if (borrower_discount > 0) {
        if (market.total_borrows >= borrower_discount) {
            market.total_borrows = market.total_borrows - borrower_discount;
        } else {
            market.total_borrows = 0;
        }
    }

    // Remaining 80% -> yield reserve (if not already claimed via claim_basset_rewards)
    let reserve_portion: u64 = (reward_amount * 80) / 100;
    if (reserve_portion > 0) {
        spl_token::SPLToken::transfer(reward_source, yield_reserve_vault, market_authority, reserve_portion);
        market.yield_reserve_balance = market.yield_reserve_balance + reserve_portion;
    }
}

// ─────────────────────────────────────────────────────────────────
// 14. submit_liquidation_bid
// ─────────────────────────────────────────────────────────────────

pub submit_liquidation_bid(
    market: AnchorMarket,
    bid: LiquidationBid @mut @init(payer=bidder, space=400),
    bidder: account @signer,
    bidder_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    bid_amount: u64,
    discount_tier: u8
) {
    require(!market.is_paused);
    require(bid_amount > 0);
    require(discount_tier >= 1);
    require(discount_tier <= 30);
    require(market.borrow_vault == borrow_vault.ctx.key);

    // Lock bid funds in the borrow vault
    spl_token::SPLToken::transfer(bidder_token, borrow_vault, bidder, bid_amount);

    bid.market = market.ctx.key;
    bid.bidder = bidder.ctx.key;
    bid.bid_amount = bid_amount;
    bid.discount_tier = discount_tier;
    bid.filled_amount = 0;
    bid.collateral_received = 0;
    bid.is_active = true;
}

// ─────────────────────────────────────────────────────────────────
// 15. cancel_liquidation_bid
// ─────────────────────────────────────────────────────────────────

pub cancel_liquidation_bid(
    market: AnchorMarket,
    bid: LiquidationBid @mut,
    bidder: account @signer,
    bidder_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account
) {
    require(bid.bidder == bidder.ctx.key);
    require(bid.is_active);
    require(bid.market == market.ctx.key);
    require(market.borrow_vault == borrow_vault.ctx.key);

    // Refund unfilled portion
    let unfilled: u64 = bid.bid_amount - bid.filled_amount;
    require(unfilled > 0);

    spl_token::SPLToken::transfer(borrow_vault, bidder_token, market_authority, unfilled);

    bid.is_active = false;
}

// ─────────────────────────────────────────────────────────────────
// 16. execute_liquidation
// ─────────────────────────────────────────────────────────────────

pub execute_liquidation(
    market: AnchorMarket @mut,
    config1: CollateralConfig @mut,
    config2: CollateralConfig,
    position: UserPosition @mut,
    oracle1: OraclePrice,
    oracle2: OraclePrice,
    bid: LiquidationBid @mut,
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64,
    collateral_slot: u8
) {
    require(!market.is_paused);
    require(repay_amount > 0);
    require(bid.is_active);
    require(bid.market == market.ctx.key);
    require(config1.market == market.ctx.key);
    require(position.market == market.ctx.key);
    require(collateral_slot == 1 || collateral_slot == 2);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle1.last_update <= 100);
    require(now - oracle2.last_update <= 100);

    // Verify position is unhealthy: borrow_value > liquidation_threshold
    let index_init: u64 = 1000000000000000000;
    let borrow_value: u64 = (position.borrow_shares * market.borrow_index_lo) / index_init;
    let liq_threshold: u64 = get_user_liquidation_threshold(position, config1, oracle1, config2, oracle2);
    require(borrow_value > liq_threshold);

    // Clamp repay to bid remaining and outstanding borrow
    let bid_remaining: u64 = bid.bid_amount - bid.filled_amount;
    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > bid_remaining) {
        actual_repay = bid_remaining;
    }
    if (actual_repay > borrow_value) {
        actual_repay = borrow_value;
    }
    require(actual_repay > 0);

    // Collateral to seize: repay_amount * (10000 + discount_bps * 100) / 10000
    // discount_tier is 1-30 representing percentage, convert to bps
    let discount_bps: u64 = bid.discount_tier as u64 * 100;
    let collateral_token_value: u64 = (actual_repay * (10000 + discount_bps)) / 10000;

    // Convert collateral value to token amount using oracle price
    let mut collateral_amount: u64 = 0;
    if (collateral_slot == 1) {
        require(position.collateral_1_config == config1.ctx.key);
        require(config1.collateral_vault == collateral_vault.ctx.key);
        // collateral_amount = collateral_value_in_borrow_terms / (price / 10^decimals)
        // = collateral_token_value * 10^decimals / price
        let mut divisor: u64 = 1;
        if (oracle1.decimals >= 1) { divisor = 10; }
        if (oracle1.decimals >= 2) { divisor = 100; }
        if (oracle1.decimals >= 3) { divisor = 1000; }
        if (oracle1.decimals >= 4) { divisor = 10000; }
        if (oracle1.decimals >= 5) { divisor = 100000; }
        if (oracle1.decimals >= 6) { divisor = 1000000; }
        if (oracle1.decimals >= 7) { divisor = 10000000; }
        if (oracle1.decimals >= 8) { divisor = 100000000; }
        if (oracle1.decimals >= 9) { divisor = 1000000000; }
        if (oracle1.decimals == 0) { divisor = 1; }
        collateral_amount = (collateral_token_value * divisor) / oracle1.price;
        if (collateral_amount > position.collateral_1_amount) {
            collateral_amount = position.collateral_1_amount;
        }
        position.collateral_1_amount = position.collateral_1_amount - collateral_amount;
    } else {
        require(position.collateral_2_config == config1.ctx.key);
        require(config1.collateral_vault == collateral_vault.ctx.key);
        let mut divisor: u64 = 1;
        if (oracle1.decimals >= 1) { divisor = 10; }
        if (oracle1.decimals >= 2) { divisor = 100; }
        if (oracle1.decimals >= 3) { divisor = 1000; }
        if (oracle1.decimals >= 4) { divisor = 10000; }
        if (oracle1.decimals >= 5) { divisor = 100000; }
        if (oracle1.decimals >= 6) { divisor = 1000000; }
        if (oracle1.decimals >= 7) { divisor = 10000000; }
        if (oracle1.decimals >= 8) { divisor = 100000000; }
        if (oracle1.decimals >= 9) { divisor = 1000000000; }
        if (oracle1.decimals == 0) { divisor = 1; }
        collateral_amount = (collateral_token_value * divisor) / oracle1.price;
        if (collateral_amount > position.collateral_2_amount) {
            collateral_amount = position.collateral_2_amount;
        }
        position.collateral_2_amount = position.collateral_2_amount - collateral_amount;
    }

    require(collateral_amount > 0);

    // Transfer collateral to bid (held for claim)
    // Collateral stays in vault; bid records what's owed
    config1.total_deposited = config1.total_deposited - collateral_amount;

    // Update bid
    bid.filled_amount = bid.filled_amount + actual_repay;
    bid.collateral_received = bid.collateral_received + collateral_amount;

    // Retire borrow shares
    let shares_to_retire: u64 = (actual_repay * index_init) / market.borrow_index_lo;
    let mut actual_shares: u64 = shares_to_retire;
    if (actual_shares > position.borrow_shares) {
        actual_shares = position.borrow_shares;
    }
    position.borrow_shares = position.borrow_shares - actual_shares;

    // Update market borrows (repay reduces outstanding borrows)
    if (market.total_borrows >= actual_repay) {
        market.total_borrows = market.total_borrows - actual_repay;
    } else {
        market.total_borrows = 0;
    }

    // Mark bid inactive if fully filled
    if (bid.filled_amount >= bid.bid_amount) {
        bid.is_active = false;
    }
}

// ─────────────────────────────────────────────────────────────────
// 17. claim_liquidation_collateral
// ─────────────────────────────────────────────────────────────────

pub claim_liquidation_collateral(
    market: AnchorMarket,
    bid: LiquidationBid @mut,
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    bidder_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    bidder: account @signer,
    token_program: account
) {
    require(bid.bidder == bidder.ctx.key);
    require(bid.market == market.ctx.key);
    require(bid.collateral_received > 0);

    let claim_amount: u64 = bid.collateral_received;

    spl_token::SPLToken::transfer(collateral_vault, bidder_collateral, market_authority, claim_amount);

    bid.collateral_received = 0;
}

// ─────────────────────────────────────────────────────────────────
// 18. update_target_rate  (Governance adjusts target deposit APY)
// ─────────────────────────────────────────────────────────────────

pub update_target_rate(
    market: AnchorMarket @mut,
    authority: account @signer,
    new_target_rate_bps: u64
) {
    require(market.authority == authority.ctx.key);
    require(new_target_rate_bps > 0);
    require(new_target_rate_bps <= 5000);
    market.target_deposit_rate_bps = new_target_rate_bps;
}

// ─────────────────────────────────────────────────────────────────
// 19. rebalance_rates
// ─────────────────────────────────────────────────────────────────

pub rebalance_rates(
    market: AnchorMarket @mut,
    authority: account @signer
) {
    require(!market.is_paused);

    // Utilization = total_borrows / total_deposits (in bps)
    let mut utilization_bps: u64 = 0;
    if (market.total_deposits > 0) {
        utilization_bps = (market.total_borrows * 10000) / market.total_deposits;
    }

    // Target: borrow_rate = target_deposit_rate / utilization + yield_reserve_adjustment
    // If utilization is 0, use a minimum borrow rate equal to target
    let mut new_borrow_rate_bps: u64 = market.target_deposit_rate_bps;

    if (utilization_bps > 0) {
        // Base borrow rate = target_deposit_rate * 10000 / utilization
        new_borrow_rate_bps = (market.target_deposit_rate_bps * 10000) / utilization_bps;

        // Yield reserve adjustment: if reserve is large, reduce borrow rate slightly
        // If reserve can cover > 1 year of target yield, reduce by 10%
        let annual_yield_needed: u64 = (market.total_deposits * market.target_deposit_rate_bps) / 10000;
        if (annual_yield_needed > 0) {
            if (market.yield_reserve_balance > annual_yield_needed) {
                // Reduce borrow rate by 10% since reserve is healthy
                new_borrow_rate_bps = (new_borrow_rate_bps * 90) / 100;
            }
        }
    }

    // Clamp borrow rate: minimum 100 bps (1%), maximum 10000 bps (100%)
    if (new_borrow_rate_bps < 100) {
        new_borrow_rate_bps = 100;
    }
    if (new_borrow_rate_bps > 10000) {
        new_borrow_rate_bps = 10000;
    }

    market.current_borrow_rate_bps = new_borrow_rate_bps;
}

// ─────────────────────────────────────────────────────────────────
// 20. withdraw_yield_reserve_surplus
// ─────────────────────────────────────────────────────────────────

pub withdraw_yield_reserve_surplus(
    market: AnchorMarket @mut,
    authority: account @signer,
    yield_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    recipient: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_paused);
    require(amount > 0);
    require(market.yield_reserve_vault == yield_reserve_vault.ctx.key);

    // Only withdraw surplus beyond a safety buffer (1 year of target yield)
    let annual_yield_needed: u64 = (market.total_deposits * market.target_deposit_rate_bps) / 10000;
    let safety_buffer: u64 = annual_yield_needed;
    require(market.yield_reserve_balance > safety_buffer);

    let surplus: u64 = market.yield_reserve_balance - safety_buffer;
    require(amount <= surplus);

    spl_token::SPLToken::transfer(yield_reserve_vault, recipient, market_authority, amount);

    market.yield_reserve_balance = market.yield_reserve_balance - amount;
}

// ─────────────────────────────────────────────────────────────────
// 21. set_authority
// ─────────────────────────────────────────────────────────────────

pub set_authority(
    market: AnchorMarket @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(market.authority == authority.ctx.key);
    market.authority = new_authority;
}

// ─────────────────────────────────────────────────────────────────
// 22. pause
// ─────────────────────────────────────────────────────────────────

pub pause(
    market: AnchorMarket @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_paused);
    market.is_paused = true;
}

// ─────────────────────────────────────────────────────────────────
// 23. unpause
// ─────────────────────────────────────────────────────────────────

pub unpause(
    market: AnchorMarket @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(market.is_paused);
    market.is_paused = false;
}

// ─────────────────────────────────────────────────────────────────
// 24. set_collateral_params
// ─────────────────────────────────────────────────────────────────

pub set_collateral_params(
    market: AnchorMarket,
    config: CollateralConfig @mut,
    authority: account @signer,
    new_ltv_ratio: u16,
    new_liquidation_threshold: u16,
    new_liquidation_bonus: u16,
    new_basset_reward_rate: u64,
    new_is_active: bool
) {
    require(market.authority == authority.ctx.key);
    require(config.market == market.ctx.key);
    require(new_ltv_ratio > 0);
    require(new_ltv_ratio < 10000);
    require(new_liquidation_threshold > new_ltv_ratio);
    require(new_liquidation_threshold <= 9500);
    require(new_liquidation_bonus > 0);
    require(new_liquidation_bonus <= 3000);

    config.ltv_ratio = new_ltv_ratio;
    config.liquidation_threshold = new_liquidation_threshold;
    config.liquidation_bonus = new_liquidation_bonus;
    config.basset_reward_rate = new_basset_reward_rate;
    config.is_active = new_is_active;
}

// ─────────────────────────────────────────────────────────────────
// Oracle Management
// ─────────────────────────────────────────────────────────────────

pub init_oracle(
    oracle: OraclePrice @mut @init(payer=authority, space=300),
    authority: account @signer,
    collateral_config: CollateralConfig,
    price: u64,
    decimals: u8
) {
    require(price > 0);
    oracle.collateral_config = collateral_config.ctx.key;
    oracle.price = price;
    oracle.decimals = decimals;
    oracle.last_update = get_clock().slot;
}

pub update_oracle(
    oracle: OraclePrice @mut,
    authority: account @signer,
    price: u64,
    decimals: u8
) {
    require(price > 0);
    oracle.price = price;
    oracle.decimals = decimals;
    oracle.last_update = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// User Position Initialization
// ─────────────────────────────────────────────────────────────────

pub init_position(
    market: AnchorMarket,
    position: UserPosition @mut @init(payer=owner, space=600),
    owner: account @signer
) {
    position.market = market.ctx.key;
    position.owner = owner.ctx.key;
    position.deposit_shares = 0;
    position.borrow_shares = 0;
    position.collateral_1_amount = 0;
    position.collateral_2_amount = 0;
    position.last_deposit_index_hi = 0;
    position.last_deposit_index_lo = 1000000000000000000;
    position.last_borrow_index_hi = 0;
    position.last_borrow_index_lo = 1000000000000000000;
}

// ─────────────────────────────────────────────────────────────────
// Read-only Views
// ─────────────────────────────────────────────────────────────────

pub get_deposit_value(market: AnchorMarket, position: UserPosition) -> u64 {
    let index_init: u64 = 1000000000000000000;
    return (position.deposit_shares * market.deposit_index_lo) / index_init;
}

pub get_borrow_value(market: AnchorMarket, position: UserPosition) -> u64 {
    let index_init: u64 = 1000000000000000000;
    return (position.borrow_shares * market.borrow_index_lo) / index_init;
}

pub get_utilization(market: AnchorMarket) -> u64 {
    if (market.total_deposits == 0) {
        return 0;
    }
    return (market.total_borrows * 10000) / market.total_deposits;
}

pub get_yield_reserve(market: AnchorMarket) -> u64 {
    return market.yield_reserve_balance;
}

pub get_atoken_exchange_rate(market: AnchorMarket) -> u64 {
    // Returns deposit_index_lo (scaled 10^18)
    // At genesis = 10^18 (1:1). Grows as yield accrues.
    return market.deposit_index_lo;
}

pub get_effective_deposit_rate(market: AnchorMarket) -> u64 {
    return market.current_deposit_rate_bps;
}

pub get_effective_borrow_rate(market: AnchorMarket) -> u64 {
    return market.current_borrow_rate_bps;
}

pub get_health_factor(
    market: AnchorMarket,
    position: UserPosition,
    config1: CollateralConfig,
    oracle1: OraclePrice,
    config2: CollateralConfig,
    oracle2: OraclePrice
) -> u64 {
    // Health = liquidation_threshold_value * 10000 / borrow_value
    // > 10000 = healthy, < 10000 = liquidatable
    let index_init: u64 = 1000000000000000000;
    let borrow_value: u64 = (position.borrow_shares * market.borrow_index_lo) / index_init;
    if (borrow_value == 0) {
        return 99999;
    }
    let liq_threshold: u64 = get_user_liquidation_threshold(position, config1, oracle1, config2, oracle2);
    return (liq_threshold * 10000) / borrow_value;
}
