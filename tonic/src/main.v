// Tonic Lending Protocol — Isolated lending markets on Solana
// 5ive DSL migration: faithful representation of Tonic's on-chain mechanics
//
// Key design (isolated market model):
//   - Each market is a standalone pool: ONE collateral mint + ONE borrow mint
//   - No cross-collateral — deposits in SOL/USDC market can't back ETH/USDC borrows
//   - Permissionless market creation (anyone can spin up a lending pair)
//   - Two-slope kink interest rate model (base -> slope1 @ optimal -> slope2 @ 100%)
//   - Share-based accounting for supply and borrow positions (scaled 10^18)
//   - Index-based compound interest accrual per slot
//   - Flash loans with fee (borrow + repay in same tx)
//   - Auto-deleverage: force-close positions when utilization exceeds emergency threshold
//   - Liquidation: max 50% per tx, liquidator bonus + optional protocol fee
//   - Oracle staleness check (100-slot window)

use std::interfaces::spl_token;

// ─────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────

account GlobalConfig {
    admin: pubkey;
    protocol_fee_bps: u64;
    flash_loan_fee_bps: u64;
    liquidation_protocol_fee_bps: u64;
    auto_deleverage_threshold: u64;
    treasury: pubkey;
    num_markets: u64;
    is_paused: bool;
}

account IsolatedMarket {
    config: pubkey;
    collateral_mint: pubkey;
    borrow_mint: pubkey;
    collateral_vault: pubkey;
    borrow_vault: pubkey;
    oracle: pubkey;

    // Supply state
    total_collateral_deposited: u64;
    total_borrow_supplied: u64;
    total_borrowed: u64;

    // Interest indices (scaled 10^18)
    borrow_rate_per_slot: u64;
    supply_rate_per_slot: u64;
    borrow_index: u128;
    supply_index: u128;
    last_update_slot: u64;

    // Risk parameters (all in bps, 10000 = 100%)
    ltv_ratio: u16;
    liquidation_threshold: u16;
    liquidation_bonus: u16;
    max_utilization: u16;

    // Interest rate model params
    optimal_utilization: u16;
    base_rate: u64;
    slope1: u64;
    slope2: u64;

    // Protocol fee accumulators
    protocol_fees_borrow: u64;
    protocol_fees_collateral: u64;

    // Status flags
    is_active: bool;
    is_deprecated: bool;
}

account UserPosition {
    market: pubkey;
    owner: pubkey;
    collateral_deposited: u64;
    borrow_shares: u64;
    supply_shares: u64;
    last_borrow_index: u128;
    last_supply_index: u128;
}

account FlashLoanReceipt {
    market: pubkey;
    borrower: pubkey;
    amount: u64;
    fee: u64;
    is_repaid: bool;
    slot: u64;
}

account OraclePrice {
    market: pubkey;
    collateral_price: u64;
    borrow_price: u64;
    collateral_decimals: u8;
    borrow_decimals: u8;
    last_update: u64;
}

// ─────────────────────────────────────────────────────────────────
// Constants (inline)
// ─────────────────────────────────────────────────────────────────

// INDEX_SCALE = 10^18 = 1_000_000_000_000_000_000  (u128)
// BPS_SCALE   = 10000
// ORACLE_STALE_SLOTS = 100
// MAX_LIQUIDATION_RATIO = 5000 (50% of borrow per tx)
// SLOTS_PER_YEAR ~= 63_072_000 (2 slots/sec * 31_536_000 sec/yr)

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// Calculate utilization in bps: (borrowed * 10000) / (supplied + borrowed)
fn calc_utilization_bps(supplied: u64, borrowed: u64) -> u64 {
    let total: u64 = supplied + borrowed;
    if (total == 0) {
        return 0;
    }
    return (borrowed * 10000) / total;
}

// Two-slope kink interest rate model
// Returns annualized borrow rate (scaled same as base_rate / slope units)
// If utilization <= optimal:  rate = base + (util * slope1) / 10000
// If utilization >  optimal:  rate = base + slope1 + ((util - optimal) * slope2) / (10000 - optimal)
fn calc_borrow_rate(
    base_rate: u64,
    slope1: u64,
    slope2: u64,
    optimal_util: u64,
    utilization: u64
) -> u64 {
    if (utilization <= optimal_util) {
        if (optimal_util == 0) {
            return base_rate;
        }
        return base_rate + (utilization * slope1) / 10000;
    }

    let extra_util: u64 = utilization - optimal_util;
    let remaining: u64 = 10000 - optimal_util;
    if (remaining == 0) {
        return base_rate + slope1;
    }
    return base_rate + slope1 + (extra_util * slope2) / remaining;
}

// Calculate supply rate from borrow rate:
//   supply_rate = borrow_rate * utilization * (10000 - protocol_fee_bps) / (10000 * 10000)
fn calc_supply_rate(borrow_rate: u64, utilization: u64, protocol_fee_bps: u64) -> u64 {
    let net_factor: u64 = 10000 - protocol_fee_bps;
    return (borrow_rate * utilization * net_factor) / (10000 * 10000);
}

// Convert amount to shares:  shares = amount * 10^18 / index
fn amount_to_shares(amount: u64, index: u128) -> u64 {
    if (index == 0 as u128) {
        return amount;
    }
    let scaled: u128 = amount as u128 * 1000000000000000000 as u128;
    return (scaled / index) as u64;
}

// Convert shares to amount:  amount = shares * index / 10^18
fn shares_to_amount(shares: u64, index: u128) -> u64 {
    let scaled: u128 = shares as u128 * index;
    return (scaled / 1000000000000000000 as u128) as u64;
}

// Compute health factor (in bps):
//   health = (collateral_value * ltv_bps) / borrow_value
// Returns value in bps — must be >= 10000 for healthy
fn calc_health_bps(
    collateral_amount: u64,
    collateral_price: u64,
    collateral_decimals: u8,
    borrow_shares: u64,
    borrow_index: u128,
    borrow_price: u64,
    borrow_decimals: u8,
    ltv_bps: u64
) -> u64 {
    let borrow_amount: u64 = shares_to_amount(borrow_shares, borrow_index);
    if (borrow_amount == 0) {
        return 99999;
    }

    // Normalize to same decimals: value = amount * price
    // collateral_value = collateral_amount * collateral_price (in base units)
    // borrow_value     = borrow_amount * borrow_price
    // health = collateral_value * ltv_bps / (borrow_value * 10000)
    let collateral_value: u128 = collateral_amount as u128 * collateral_price as u128;
    let borrow_value: u128 = borrow_amount as u128 * borrow_price as u128;

    // Adjust for decimal difference: normalize both to same precision
    // collateral_adj = collateral_value * 10^borrow_decimals
    // borrow_adj     = borrow_value * 10^collateral_decimals
    let mut collateral_adj: u128 = collateral_value;
    let mut borrow_adj: u128 = borrow_value;

    // Scale collateral up by borrow_decimals
    let mut i: u8 = 0;
    while (i < borrow_decimals) {
        collateral_adj = collateral_adj * 10 as u128;
        i = i + 1;
    }

    // Scale borrow up by collateral_decimals
    let mut j: u8 = 0;
    while (j < collateral_decimals) {
        borrow_adj = borrow_adj * 10 as u128;
        j = j + 1;
    }

    if (borrow_adj == 0 as u128) {
        return 99999;
    }

    let health: u128 = (collateral_adj * ltv_bps as u128) / borrow_adj;
    return health as u64;
}

// Check liquidation threshold (similar to health but uses liq threshold instead of LTV)
fn calc_liq_health_bps(
    collateral_amount: u64,
    collateral_price: u64,
    collateral_decimals: u8,
    borrow_shares: u64,
    borrow_index: u128,
    borrow_price: u64,
    borrow_decimals: u8,
    liq_threshold_bps: u64
) -> u64 {
    let borrow_amount: u64 = shares_to_amount(borrow_shares, borrow_index);
    if (borrow_amount == 0) {
        return 99999;
    }

    let collateral_value: u128 = collateral_amount as u128 * collateral_price as u128;
    let borrow_value: u128 = borrow_amount as u128 * borrow_price as u128;

    let mut collateral_adj: u128 = collateral_value;
    let mut borrow_adj: u128 = borrow_value;

    let mut i: u8 = 0;
    while (i < borrow_decimals) {
        collateral_adj = collateral_adj * 10 as u128;
        i = i + 1;
    }
    let mut j: u8 = 0;
    while (j < collateral_decimals) {
        borrow_adj = borrow_adj * 10 as u128;
        j = j + 1;
    }

    if (borrow_adj == 0 as u128) {
        return 99999;
    }

    let health: u128 = (collateral_adj * liq_threshold_bps as u128) / borrow_adj;
    return health as u64;
}

// ─────────────────────────────────────────────────────────────────
// Market Management
// ─────────────────────────────────────────────────────────────────

pub init_global_config(
    config: GlobalConfig @mut @init(payer=admin, space=500),
    admin: account @signer,
    treasury: pubkey,
    protocol_fee_bps: u64,
    flash_loan_fee_bps: u64,
    liquidation_protocol_fee_bps: u64,
    auto_deleverage_threshold: u64
) {
    require(protocol_fee_bps <= 5000);
    require(flash_loan_fee_bps <= 1000);
    require(liquidation_protocol_fee_bps <= 5000);
    require(auto_deleverage_threshold > 0);
    require(auto_deleverage_threshold <= 10000);

    config.admin = admin.ctx.key;
    config.protocol_fee_bps = protocol_fee_bps;
    config.flash_loan_fee_bps = flash_loan_fee_bps;
    config.liquidation_protocol_fee_bps = liquidation_protocol_fee_bps;
    config.auto_deleverage_threshold = auto_deleverage_threshold;
    config.treasury = treasury;
    config.num_markets = 0;
    config.is_paused = false;
}

pub set_global_config(
    config: GlobalConfig @mut,
    admin: account @signer,
    protocol_fee_bps: u64,
    flash_loan_fee_bps: u64,
    liquidation_protocol_fee_bps: u64,
    auto_deleverage_threshold: u64
) {
    require(config.admin == admin.ctx.key);
    require(protocol_fee_bps <= 5000);
    require(flash_loan_fee_bps <= 1000);
    require(liquidation_protocol_fee_bps <= 5000);
    require(auto_deleverage_threshold > 0);
    require(auto_deleverage_threshold <= 10000);

    config.protocol_fee_bps = protocol_fee_bps;
    config.flash_loan_fee_bps = flash_loan_fee_bps;
    config.liquidation_protocol_fee_bps = liquidation_protocol_fee_bps;
    config.auto_deleverage_threshold = auto_deleverage_threshold;
}

pub set_admin(
    config: GlobalConfig @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(config.admin == admin.ctx.key);
    config.admin = new_admin;
}

pub create_market(
    config: GlobalConfig @mut,
    market: IsolatedMarket @mut @init(payer=creator, space=1024),
    creator: account @signer,
    collateral_mint: pubkey,
    borrow_mint: pubkey,
    collateral_vault: pubkey,
    borrow_vault: pubkey,
    oracle: pubkey,
    ltv_ratio: u16,
    liquidation_threshold: u16,
    liquidation_bonus: u16,
    max_utilization: u16,
    optimal_utilization: u16,
    base_rate: u64,
    slope1: u64,
    slope2: u64
) {
    require(!config.is_paused);
    // Validate risk params (all in bps, max 10000)
    require(ltv_ratio > 0);
    require(ltv_ratio < liquidation_threshold);
    require(liquidation_threshold <= 9500);
    require(liquidation_bonus > 0);
    require(liquidation_bonus <= 5000);
    require(max_utilization > 0);
    require(max_utilization <= 10000);
    require(optimal_utilization > 0);
    require(optimal_utilization < 10000);

    market.config = config.ctx.key;
    market.collateral_mint = collateral_mint;
    market.borrow_mint = borrow_mint;
    market.collateral_vault = collateral_vault;
    market.borrow_vault = borrow_vault;
    market.oracle = oracle;

    market.total_collateral_deposited = 0;
    market.total_borrow_supplied = 0;
    market.total_borrowed = 0;

    // Initialize indices to 1.0 (10^18)
    market.borrow_index = 1000000000000000000 as u128;
    market.supply_index = 1000000000000000000 as u128;
    market.borrow_rate_per_slot = 0;
    market.supply_rate_per_slot = 0;
    market.last_update_slot = get_clock().slot;

    market.ltv_ratio = ltv_ratio;
    market.liquidation_threshold = liquidation_threshold;
    market.liquidation_bonus = liquidation_bonus;
    market.max_utilization = max_utilization;

    market.optimal_utilization = optimal_utilization;
    market.base_rate = base_rate;
    market.slope1 = slope1;
    market.slope2 = slope2;

    market.protocol_fees_borrow = 0;
    market.protocol_fees_collateral = 0;

    market.is_active = true;
    market.is_deprecated = false;

    config.num_markets = config.num_markets + 1;
}

pub update_market_config(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer,
    ltv_ratio: u16,
    liquidation_threshold: u16,
    liquidation_bonus: u16,
    max_utilization: u16,
    optimal_utilization: u16,
    base_rate: u64,
    slope1: u64,
    slope2: u64
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    require(ltv_ratio > 0);
    require(ltv_ratio < liquidation_threshold);
    require(liquidation_threshold <= 9500);
    require(liquidation_bonus > 0);
    require(liquidation_bonus <= 5000);
    require(max_utilization > 0);
    require(max_utilization <= 10000);
    require(optimal_utilization > 0);
    require(optimal_utilization < 10000);

    market.ltv_ratio = ltv_ratio;
    market.liquidation_threshold = liquidation_threshold;
    market.liquidation_bonus = liquidation_bonus;
    market.max_utilization = max_utilization;
    market.optimal_utilization = optimal_utilization;
    market.base_rate = base_rate;
    market.slope1 = slope1;
    market.slope2 = slope2;
}

pub set_market_oracle(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer,
    new_oracle: pubkey
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    market.oracle = new_oracle;
}

pub close_market(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    require(market.is_active);
    market.is_active = false;
    market.is_deprecated = true;
}

pub pause_market(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    market.is_active = false;
}

pub unpause_market(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    require(!market.is_deprecated);
    market.is_active = true;
}

// ─────────────────────────────────────────────────────────────────
// User Position Init
// ─────────────────────────────────────────────────────────────────

pub init_position(
    market: IsolatedMarket,
    position: UserPosition @mut @init(payer=owner, space=500),
    owner: account @signer
) {
    require(market.is_active);
    position.market = market.ctx.key;
    position.owner = owner.ctx.key;
    position.collateral_deposited = 0;
    position.borrow_shares = 0;
    position.supply_shares = 0;
    position.last_borrow_index = market.borrow_index;
    position.last_supply_index = market.supply_index;
}

// ─────────────────────────────────────────────────────────────────
// Interest Accrual (permissionless crank)
// ─────────────────────────────────────────────────────────────────

pub accrue_interest(
    config: GlobalConfig,
    market: IsolatedMarket @mut
) {
    require(market.config == config.ctx.key);

    let current_slot: u64 = get_clock().slot;
    let slots_elapsed: u64 = current_slot - market.last_update_slot;

    if (slots_elapsed == 0) {
        return;
    }

    // Calculate current utilization
    let utilization: u64 = calc_utilization_bps(
        market.total_borrow_supplied,
        market.total_borrowed
    );

    // Calculate annualized borrow rate
    let annual_borrow_rate: u64 = calc_borrow_rate(
        market.base_rate,
        market.slope1,
        market.slope2,
        market.optimal_utilization as u64,
        utilization
    );

    // Convert annual rate to per-slot rate
    // borrow_rate_per_slot = annual_rate / SLOTS_PER_YEAR
    let slots_per_year: u64 = 63072000;
    let borrow_rate_per_slot: u64 = annual_borrow_rate / slots_per_year;

    // Calculate supply rate per slot
    let annual_supply_rate: u64 = calc_supply_rate(
        annual_borrow_rate,
        utilization,
        config.protocol_fee_bps
    );
    let supply_rate_per_slot: u64 = annual_supply_rate / slots_per_year;

    // Update indices:
    //   new_borrow_index = old * (10^18 + borrow_rate_per_slot * slots) / 10^18
    //   new_supply_index = old * (10^18 + supply_rate_per_slot * slots) / 10^18
    let index_scale: u128 = 1000000000000000000 as u128;

    let borrow_accrual: u128 = index_scale + (borrow_rate_per_slot as u128 * slots_elapsed as u128);
    let new_borrow_index: u128 = (market.borrow_index * borrow_accrual) / index_scale;

    let supply_accrual: u128 = index_scale + (supply_rate_per_slot as u128 * slots_elapsed as u128);
    let new_supply_index: u128 = (market.supply_index * supply_accrual) / index_scale;

    // Calculate interest earned and protocol fee
    let old_borrowed: u64 = market.total_borrowed;
    let new_borrowed_128: u128 = old_borrowed as u128 * borrow_accrual / index_scale;
    let new_borrowed: u64 = new_borrowed_128 as u64;
    let interest_earned: u64 = new_borrowed - old_borrowed;
    let protocol_fee_share: u64 = (interest_earned * config.protocol_fee_bps) / 10000;

    // Update market state
    market.borrow_index = new_borrow_index;
    market.supply_index = new_supply_index;
    market.borrow_rate_per_slot = borrow_rate_per_slot;
    market.supply_rate_per_slot = supply_rate_per_slot;
    market.total_borrowed = new_borrowed;
    market.protocol_fees_borrow = market.protocol_fees_borrow + protocol_fee_share;
    market.last_update_slot = current_slot;
}

// ─────────────────────────────────────────────────────────────────
// Oracle
// ─────────────────────────────────────────────────────────────────

pub init_oracle(
    oracle: OraclePrice @mut @init(payer=authority, space=300),
    authority: account @signer,
    market: pubkey,
    collateral_price: u64,
    borrow_price: u64,
    collateral_decimals: u8,
    borrow_decimals: u8
) {
    require(collateral_price > 0);
    require(borrow_price > 0);

    oracle.market = market;
    oracle.collateral_price = collateral_price;
    oracle.borrow_price = borrow_price;
    oracle.collateral_decimals = collateral_decimals;
    oracle.borrow_decimals = borrow_decimals;
    oracle.last_update = get_clock().slot;
}

pub refresh_oracle(
    oracle: OraclePrice @mut,
    authority: account @signer,
    collateral_price: u64,
    borrow_price: u64
) {
    require(collateral_price > 0);
    require(borrow_price > 0);

    oracle.collateral_price = collateral_price;
    oracle.borrow_price = borrow_price;
    oracle.last_update = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// Supply Side — Collateral Deposits
// ─────────────────────────────────────────────────────────────────

pub deposit_collateral(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    user_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.is_active);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(collateral_vault.ctx.key == market.collateral_vault);
    require(amount > 0);

    spl_token::SPLToken::transfer(user_collateral_token, collateral_vault, user_authority, amount);

    position.collateral_deposited = position.collateral_deposited + amount;
    market.total_collateral_deposited = market.total_collateral_deposited + amount;
}

pub withdraw_collateral(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    oracle: OraclePrice,
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(collateral_vault.ctx.key == market.collateral_vault);
    require(oracle.market == market.ctx.key);
    require(amount > 0);
    require(amount <= position.collateral_deposited);

    // Oracle staleness check (100 slots)
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Post-withdrawal health check
    let remaining_collateral: u64 = position.collateral_deposited - amount;
    if (position.borrow_shares > 0) {
        let health: u64 = calc_health_bps(
            remaining_collateral,
            oracle.collateral_price,
            oracle.collateral_decimals,
            position.borrow_shares,
            market.borrow_index,
            oracle.borrow_price,
            oracle.borrow_decimals,
            market.ltv_ratio as u64
        );
        require(health >= 10000);
    }

    spl_token::SPLToken::transfer(collateral_vault, user_collateral_token, market_authority, amount);

    position.collateral_deposited = position.collateral_deposited - amount;
    market.total_collateral_deposited = market.total_collateral_deposited - amount;
}

// ─────────────────────────────────────────────────────────────────
// Supply Side — Borrow Token Supply (lenders earn interest)
// ─────────────────────────────────────────────────────────────────

pub deposit_borrow_token(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.is_active);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(amount > 0);

    spl_token::SPLToken::transfer(user_borrow_token, borrow_vault, user_authority, amount);

    // Convert amount to supply shares
    let new_shares: u64 = amount_to_shares(amount, market.supply_index);
    require(new_shares > 0);

    position.supply_shares = position.supply_shares + new_shares;
    position.last_supply_index = market.supply_index;
    market.total_borrow_supplied = market.total_borrow_supplied + amount;
}

pub withdraw_borrow_token(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    shares_to_withdraw: u64
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(shares_to_withdraw > 0);
    require(shares_to_withdraw <= position.supply_shares);

    // Convert shares to token amount (includes accrued interest)
    let withdraw_amount: u64 = shares_to_amount(shares_to_withdraw, market.supply_index);
    require(withdraw_amount > 0);

    // Ensure enough liquidity available (supplied - borrowed)
    let available_liquidity: u64 = market.total_borrow_supplied - market.total_borrowed;
    require(withdraw_amount <= available_liquidity);

    spl_token::SPLToken::transfer(borrow_vault, user_borrow_token, market_authority, withdraw_amount);

    position.supply_shares = position.supply_shares - shares_to_withdraw;
    position.last_supply_index = market.supply_index;

    if (market.total_borrow_supplied >= withdraw_amount) {
        market.total_borrow_supplied = market.total_borrow_supplied - withdraw_amount;
    } else {
        market.total_borrow_supplied = 0;
    }
}

// ─────────────────────────────────────────────────────────────────
// Borrowing
// ─────────────────────────────────────────────────────────────────

pub borrow(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    oracle: OraclePrice,
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.is_active);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(oracle.market == market.ctx.key);
    require(amount > 0);
    require(position.collateral_deposited > 0);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Check available liquidity
    let available_liquidity: u64 = market.total_borrow_supplied - market.total_borrowed;
    require(amount <= available_liquidity);

    // Check utilization cap
    let new_total_borrowed: u64 = market.total_borrowed + amount;
    let new_util: u64 = calc_utilization_bps(
        market.total_borrow_supplied,
        new_total_borrowed
    );
    require(new_util <= market.max_utilization as u64);

    // Convert amount to borrow shares
    let new_borrow_shares: u64 = amount_to_shares(amount, market.borrow_index);
    require(new_borrow_shares > 0);

    // LTV health check after borrowing
    let total_borrow_shares: u64 = position.borrow_shares + new_borrow_shares;
    let health: u64 = calc_health_bps(
        position.collateral_deposited,
        oracle.collateral_price,
        oracle.collateral_decimals,
        total_borrow_shares,
        market.borrow_index,
        oracle.borrow_price,
        oracle.borrow_decimals,
        market.ltv_ratio as u64
    );
    require(health >= 10000);

    spl_token::SPLToken::transfer(borrow_vault, user_borrow_token, market_authority, amount);

    position.borrow_shares = total_borrow_shares;
    position.last_borrow_index = market.borrow_index;
    market.total_borrowed = new_total_borrowed;
}

pub repay(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(position.owner == user_authority.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(amount > 0);
    require(position.borrow_shares > 0);

    // Calculate current outstanding borrow
    let outstanding: u64 = shares_to_amount(position.borrow_shares, market.borrow_index);

    // Clamp repay to outstanding
    let mut repay_amount: u64 = amount;
    if (repay_amount > outstanding) {
        repay_amount = outstanding;
    }

    spl_token::SPLToken::transfer(user_borrow_token, borrow_vault, user_authority, repay_amount);

    // Calculate shares being repaid
    let shares_repaid: u64 = amount_to_shares(repay_amount, market.borrow_index);

    if (shares_repaid >= position.borrow_shares) {
        // Full repayment
        position.borrow_shares = 0;
    } else {
        position.borrow_shares = position.borrow_shares - shares_repaid;
    }
    position.last_borrow_index = market.borrow_index;

    if (market.total_borrowed >= repay_amount) {
        market.total_borrowed = market.total_borrowed - repay_amount;
    } else {
        market.total_borrowed = 0;
    }
    market.total_borrow_supplied = market.total_borrow_supplied + repay_amount;
}

// ─────────────────────────────────────────────────────────────────
// Liquidation
// ─────────────────────────────────────────────────────────────────

pub liquidate(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    oracle: OraclePrice,
    liquidator_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    liquidator_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(oracle.market == market.ctx.key);
    require(collateral_vault.ctx.key == market.collateral_vault);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(repay_amount > 0);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Verify position is unhealthy (below liquidation threshold)
    let liq_health: u64 = calc_liq_health_bps(
        position.collateral_deposited,
        oracle.collateral_price,
        oracle.collateral_decimals,
        position.borrow_shares,
        market.borrow_index,
        oracle.borrow_price,
        oracle.borrow_decimals,
        market.liquidation_threshold as u64
    );
    require(liq_health < 10000);

    // Max 50% of outstanding borrow per liquidation tx
    let outstanding: u64 = shares_to_amount(position.borrow_shares, market.borrow_index);
    let max_repay: u64 = outstanding / 2;

    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > max_repay) {
        actual_repay = max_repay;
    }
    if (actual_repay > outstanding) {
        actual_repay = outstanding;
    }

    // Liquidator repays borrow tokens
    spl_token::SPLToken::transfer(liquidator_borrow_token, borrow_vault, liquidator, actual_repay);

    // Calculate collateral to seize:
    //   borrow_value = actual_repay * borrow_price
    //   collateral_to_seize = borrow_value * (10000 + liquidation_bonus) / (collateral_price * 10000)
    // Adjusted for decimal differences
    let repay_value: u128 = actual_repay as u128 * oracle.borrow_price as u128;
    let bonus_factor: u128 = 10000 as u128 + market.liquidation_bonus as u128;

    // Scale for decimal alignment
    let mut repay_adj: u128 = repay_value;
    let mut price_adj: u128 = oracle.collateral_price as u128;

    let mut i: u8 = 0;
    while (i < oracle.collateral_decimals) {
        repay_adj = repay_adj * 10 as u128;
        i = i + 1;
    }
    let mut j: u8 = 0;
    while (j < oracle.borrow_decimals) {
        price_adj = price_adj * 10 as u128;
        j = j + 1;
    }

    let collateral_to_seize_128: u128 = (repay_adj * bonus_factor) / (price_adj * 10000 as u128);
    let mut collateral_to_seize: u64 = collateral_to_seize_128 as u64;

    // Clamp to available collateral
    if (collateral_to_seize > position.collateral_deposited) {
        collateral_to_seize = position.collateral_deposited;
    }

    // Transfer seized collateral to liquidator
    spl_token::SPLToken::transfer(collateral_vault, liquidator_collateral_token, market_authority, collateral_to_seize);

    // Update position
    let shares_repaid: u64 = amount_to_shares(actual_repay, market.borrow_index);
    if (shares_repaid >= position.borrow_shares) {
        position.borrow_shares = 0;
    } else {
        position.borrow_shares = position.borrow_shares - shares_repaid;
    }
    position.collateral_deposited = position.collateral_deposited - collateral_to_seize;
    position.last_borrow_index = market.borrow_index;

    // Update market state
    if (market.total_borrowed >= actual_repay) {
        market.total_borrowed = market.total_borrowed - actual_repay;
    } else {
        market.total_borrowed = 0;
    }
    market.total_borrow_supplied = market.total_borrow_supplied + actual_repay;
    market.total_collateral_deposited = market.total_collateral_deposited - collateral_to_seize;
}

pub liquidate_with_protocol_fee(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    oracle: OraclePrice,
    liquidator_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    liquidator_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    protocol_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(oracle.market == market.ctx.key);
    require(collateral_vault.ctx.key == market.collateral_vault);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(repay_amount > 0);

    // Oracle staleness
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Verify unhealthy
    let liq_health: u64 = calc_liq_health_bps(
        position.collateral_deposited,
        oracle.collateral_price,
        oracle.collateral_decimals,
        position.borrow_shares,
        market.borrow_index,
        oracle.borrow_price,
        oracle.borrow_decimals,
        market.liquidation_threshold as u64
    );
    require(liq_health < 10000);

    // Max 50% of outstanding
    let outstanding: u64 = shares_to_amount(position.borrow_shares, market.borrow_index);
    let max_repay: u64 = outstanding / 2;

    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > max_repay) {
        actual_repay = max_repay;
    }
    if (actual_repay > outstanding) {
        actual_repay = outstanding;
    }

    // Liquidator repays
    spl_token::SPLToken::transfer(liquidator_borrow_token, borrow_vault, liquidator, actual_repay);

    // Calculate total collateral to seize (same as liquidate)
    let repay_value: u128 = actual_repay as u128 * oracle.borrow_price as u128;
    let bonus_factor: u128 = 10000 as u128 + market.liquidation_bonus as u128;

    let mut repay_adj: u128 = repay_value;
    let mut price_adj: u128 = oracle.collateral_price as u128;

    let mut i: u8 = 0;
    while (i < oracle.collateral_decimals) {
        repay_adj = repay_adj * 10 as u128;
        i = i + 1;
    }
    let mut j: u8 = 0;
    while (j < oracle.borrow_decimals) {
        price_adj = price_adj * 10 as u128;
        j = j + 1;
    }

    let total_seize_128: u128 = (repay_adj * bonus_factor) / (price_adj * 10000 as u128);
    let mut total_seize: u64 = total_seize_128 as u64;

    if (total_seize > position.collateral_deposited) {
        total_seize = position.collateral_deposited;
    }

    // Split seized collateral: protocol gets its cut of the bonus portion
    // bonus_collateral = total_seize - base_seize (where base_seize = seize at no bonus)
    let base_seize_128: u128 = (repay_adj * 10000 as u128) / (price_adj * 10000 as u128);
    let base_seize: u64 = base_seize_128 as u64;

    let mut bonus_collateral: u64 = 0;
    if (total_seize > base_seize) {
        bonus_collateral = total_seize - base_seize;
    }

    // Protocol takes liquidation_protocol_fee_bps of the bonus
    let protocol_cut: u64 = (bonus_collateral * config.liquidation_protocol_fee_bps) / 10000;
    let liquidator_receives: u64 = total_seize - protocol_cut;

    // Transfer to liquidator
    spl_token::SPLToken::transfer(collateral_vault, liquidator_collateral_token, market_authority, liquidator_receives);

    // Transfer protocol fee to protocol account
    if (protocol_cut > 0) {
        spl_token::SPLToken::transfer(collateral_vault, protocol_collateral_token, market_authority, protocol_cut);
        market.protocol_fees_collateral = market.protocol_fees_collateral + protocol_cut;
    }

    // Update position
    let shares_repaid: u64 = amount_to_shares(actual_repay, market.borrow_index);
    if (shares_repaid >= position.borrow_shares) {
        position.borrow_shares = 0;
    } else {
        position.borrow_shares = position.borrow_shares - shares_repaid;
    }
    position.collateral_deposited = position.collateral_deposited - total_seize;
    position.last_borrow_index = market.borrow_index;

    // Update market
    if (market.total_borrowed >= actual_repay) {
        market.total_borrowed = market.total_borrowed - actual_repay;
    } else {
        market.total_borrowed = 0;
    }
    market.total_borrow_supplied = market.total_borrow_supplied + actual_repay;
    market.total_collateral_deposited = market.total_collateral_deposited - total_seize;
}

// ─────────────────────────────────────────────────────────────────
// Flash Loans
// ─────────────────────────────────────────────────────────────────

pub flash_borrow(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    receipt: FlashLoanReceipt @mut @init(payer=borrower, space=300),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    borrower: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(market.is_active);
    require(market.config == config.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(amount > 0);

    // Check available liquidity
    let available: u64 = market.total_borrow_supplied - market.total_borrowed;
    require(amount <= available);

    // Calculate fee
    let fee: u64 = (amount * config.flash_loan_fee_bps) / 10000;
    require(fee > 0);

    // Create receipt
    receipt.market = market.ctx.key;
    receipt.borrower = borrower.ctx.key;
    receipt.amount = amount;
    receipt.fee = fee;
    receipt.is_repaid = false;
    receipt.slot = get_clock().slot;

    // Transfer tokens to borrower
    spl_token::SPLToken::transfer(borrow_vault, user_borrow_token, market_authority, amount);
}

pub flash_repay(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    receipt: FlashLoanReceipt @mut,
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    borrower: account @signer,
    token_program: account
) {
    require(market.config == config.ctx.key);
    require(receipt.market == market.ctx.key);
    require(receipt.borrower == borrower.ctx.key);
    require(!receipt.is_repaid);

    // Must repay in same slot (same transaction)
    let now: u64 = get_clock().slot;
    require(now == receipt.slot);

    // Repay amount + fee
    let repay_total: u64 = receipt.amount + receipt.fee;
    spl_token::SPLToken::transfer(user_borrow_token, borrow_vault, borrower, repay_total);

    receipt.is_repaid = true;

    // Fee goes to protocol and suppliers
    let protocol_share: u64 = (receipt.fee * config.protocol_fee_bps) / 10000;
    market.protocol_fees_borrow = market.protocol_fees_borrow + protocol_share;

    // Remaining fee benefits suppliers via increased supply
    let supplier_share: u64 = receipt.fee - protocol_share;
    market.total_borrow_supplied = market.total_borrow_supplied + supplier_share;
}

// ─────────────────────────────────────────────────────────────────
// Auto-Deleverage (emergency mechanism)
// ─────────────────────────────────────────────────────────────────

pub auto_deleverage(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    position: UserPosition @mut,
    oracle: OraclePrice,
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    cranker: account @signer,
    token_program: account
) {
    require(!config.is_paused);
    require(market.config == config.ctx.key);
    require(position.market == market.ctx.key);
    require(oracle.market == market.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(collateral_vault.ctx.key == market.collateral_vault);
    require(position.borrow_shares > 0);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // ADL triggers when utilization exceeds the emergency threshold
    let utilization: u64 = calc_utilization_bps(
        market.total_borrow_supplied,
        market.total_borrowed
    );
    require(utilization > config.auto_deleverage_threshold);

    // Force-close the entire borrow position at current oracle price (no bonus)
    let borrow_amount: u64 = shares_to_amount(position.borrow_shares, market.borrow_index);

    // Calculate collateral equivalent at oracle price (1:1 value, no bonus/penalty)
    let repay_value: u128 = borrow_amount as u128 * oracle.borrow_price as u128;

    let mut repay_adj: u128 = repay_value;
    let mut price_adj: u128 = oracle.collateral_price as u128;

    let mut i: u8 = 0;
    while (i < oracle.collateral_decimals) {
        repay_adj = repay_adj * 10 as u128;
        i = i + 1;
    }
    let mut j: u8 = 0;
    while (j < oracle.borrow_decimals) {
        price_adj = price_adj * 10 as u128;
        j = j + 1;
    }

    let collateral_to_take_128: u128 = (repay_adj) / price_adj;
    let mut collateral_to_take: u64 = collateral_to_take_128 as u64;

    if (collateral_to_take > position.collateral_deposited) {
        collateral_to_take = position.collateral_deposited;
    }

    // Seize collateral to vault (protocol keeps it to offset bad debt or redistribute)
    // Position owner gets remaining collateral back
    let remaining_collateral: u64 = position.collateral_deposited - collateral_to_take;

    if (remaining_collateral > 0) {
        spl_token::SPLToken::transfer(collateral_vault, user_collateral_token, market_authority, remaining_collateral);
    }

    // Clear the position
    position.borrow_shares = 0;
    position.collateral_deposited = 0;
    position.last_borrow_index = market.borrow_index;

    // Update market
    if (market.total_borrowed >= borrow_amount) {
        market.total_borrowed = market.total_borrowed - borrow_amount;
    } else {
        market.total_borrowed = 0;
    }
    market.total_collateral_deposited = market.total_collateral_deposited - position.collateral_deposited;
    // Note: collateral_to_take stays in vault as protocol reserve for bad debt coverage
}

// ─────────────────────────────────────────────────────────────────
// Admin — Fee Collection
// ─────────────────────────────────────────────────────────────────

pub collect_protocol_fees(
    config: GlobalConfig,
    market: IsolatedMarket @mut,
    admin: account @signer,
    borrow_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_vault: spl_token::TokenAccount @mut @serializer("raw"),
    treasury_borrow_token: spl_token::TokenAccount @mut @serializer("raw"),
    treasury_collateral_token: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account
) {
    require(config.admin == admin.ctx.key);
    require(market.config == config.ctx.key);
    require(borrow_vault.ctx.key == market.borrow_vault);
    require(collateral_vault.ctx.key == market.collateral_vault);

    // Collect borrow-side fees
    let borrow_fees: u64 = market.protocol_fees_borrow;
    if (borrow_fees > 0) {
        spl_token::SPLToken::transfer(borrow_vault, treasury_borrow_token, market_authority, borrow_fees);
        market.protocol_fees_borrow = 0;
    }

    // Collect collateral-side fees (from liquidation protocol cuts)
    let collateral_fees: u64 = market.protocol_fees_collateral;
    if (collateral_fees > 0) {
        spl_token::SPLToken::transfer(collateral_vault, treasury_collateral_token, market_authority, collateral_fees);
        market.protocol_fees_collateral = 0;
    }
}

// ─────────────────────────────────────────────────────────────────
// Exposed Calculation Helpers (read-only / test-friendly)
// ─────────────────────────────────────────────────────────────────

pub get_utilization(supplied: u64, borrowed: u64) -> u64 {
    return calc_utilization_bps(supplied, borrowed);
}

pub get_borrow_rate(
    base_rate: u64,
    slope1: u64,
    slope2: u64,
    optimal_util: u64,
    utilization: u64
) -> u64 {
    return calc_borrow_rate(base_rate, slope1, slope2, optimal_util, utilization);
}

pub get_supply_rate(
    borrow_rate: u64,
    utilization: u64,
    protocol_fee_bps: u64
) -> u64 {
    return calc_supply_rate(borrow_rate, utilization, protocol_fee_bps);
}

pub get_position_health(
    market: IsolatedMarket,
    position: UserPosition,
    oracle: OraclePrice
) -> u64 {
    require(oracle.market == market.ctx.key);
    require(position.market == market.ctx.key);

    return calc_health_bps(
        position.collateral_deposited,
        oracle.collateral_price,
        oracle.collateral_decimals,
        position.borrow_shares,
        market.borrow_index,
        oracle.borrow_price,
        oracle.borrow_decimals,
        market.ltv_ratio as u64
    );
}

pub get_outstanding_borrow(
    market: IsolatedMarket,
    position: UserPosition
) -> u64 {
    require(position.market == market.ctx.key);
    return shares_to_amount(position.borrow_shares, market.borrow_index);
}

pub get_supply_value(
    market: IsolatedMarket,
    position: UserPosition
) -> u64 {
    require(position.market == market.ctx.key);
    return shares_to_amount(position.supply_shares, market.supply_index);
}
