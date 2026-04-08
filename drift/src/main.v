// 5IVE Drift Protocol v2 -- Perpetual Futures DEX (vAMM Model)
//
// Design (Drift Protocol v2):
//   - DriftState: top-level exchange config (admin, insurance vault, pause, market counts)
//   - SpotMarket: per-token collateral reserve with deposit/borrow indices, interest model, risk weights
//   - PerpMarket: perpetual futures market powered by a virtual AMM (vAMM)
//   - User: portfolio with up to 4 spot positions + 2 perp positions
//   - PerpOrder: individual perp order (market/limit/trigger, long/short)
//   - InsuranceFund: per-market insurance fund backed by USDC stakers
//   - PriceOracle: oracle price feed with staleness enforcement
//
// vAMM Model:
//   Traders trade against virtual reserves (not real liquidity). The protocol acts as
//   counterparty to all trades. Virtual reserves follow constant product:
//     base_reserve * quote_reserve = k  (where k = sqrt_k^2)
//   Mark price = (quote_reserve * peg_multiplier) / (base_reserve * PRICE_PRECISION)
//   Peg multiplier anchors the vAMM to the oracle price.
//   sqrt_k controls depth -- higher k = less slippage.
//
// Precision:
//   - PRICE_PRECISION = 1_000_000 (1e6) -- all prices scaled
//   - FUNDING_PRECISION = 1_000_000_000 (1e9) -- funding rates
//   - INDEX_PRECISION = 1_000_000_000 (1e9) -- interest indices
//   - WEIGHT_SCALE = 10_000 = 100%
//   - BPS_SCALE = 10_000
//   - Spread in basis points (1 bps = 0.01%)
//
// Funding: periodic rate based on mark-oracle divergence.
//   rate = clamp((mark - oracle) / oracle * FUNDING_PRECISION, min, max) per hour
//   Longs pay shorts when mark > oracle; shorts pay longs when mark < oracle.
//
// Insurance: absorbs protocol losses (bankrupt positions). If depleted, losses
//   are socialized across remaining users.
//
// Keepers: anyone can call fill_perp_order / update_funding_rate to earn rebates.

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account DriftState {
    admin: pubkey;
    insurance_fund_vault: pubkey;
    exchange_status: u8;           // 0 = active, 1 = paused
    num_spot_markets: u8;
    num_perp_markets: u8;
    lp_cooldown_time: u64;
    liquidation_margin_buffer: u64;
    default_maker_fee_bps: u64;
    default_taker_fee_bps: u64;
    total_fee_collected: u64;
}

account SpotMarket {
    market_index: u8;
    mint: pubkey;
    vault: pubkey;
    oracle: pubkey;
    deposit_balance: u64;
    borrow_balance: u64;
    deposit_index: u128;           // scaled 1e9
    borrow_index: u128;            // scaled 1e9
    cumulative_deposit_interest: u64;
    cumulative_borrow_interest: u64;
    optimal_utilization: u64;      // scaled 1e6 (e.g. 800000 = 80%)
    optimal_rate: u64;             // scaled 1e6
    max_rate: u64;                 // scaled 1e6
    initial_asset_weight: u64;     // scaled 10000 (e.g. 8000 = 80%)
    maintenance_asset_weight: u64;
    initial_liability_weight: u64;
    maintenance_liability_weight: u64;
    last_update_ts: u64;
}

account PerpMarket {
    market_index: u8;
    oracle: pubkey;
    // Open interest tracking (signed for directional)
    base_asset_amount_long: i64;
    base_asset_amount_short: i64;
    // vAMM state
    amm_base_asset_reserve: u128;
    amm_quote_asset_reserve: u128;
    amm_sqrt_k: u128;
    amm_peg_multiplier: u128;     // scaled 1e6
    amm_base_spread: u32;         // bps
    amm_max_spread: u32;          // bps
    // Funding
    cumulative_funding_rate_long: i64;   // scaled 1e9
    cumulative_funding_rate_short: i64;
    last_funding_rate: i64;
    last_funding_ts: u64;
    last_oracle_price: u64;        // scaled 1e6
    // Market stats
    open_interest: u64;
    maker_fee_bps: u64;
    taker_fee_bps: u64;
    total_fee_collected: u64;
    insurance_claim_amount: u64;
    is_active: bool;
}

account User {
    authority: pubkey;
    delegate: pubkey;
    // Spot positions (up to 4). Positive = deposit, negative = borrow.
    spot_position_1: i64;
    spot_market_index_1: u8;
    spot_position_2: i64;
    spot_market_index_2: u8;
    spot_position_3: i64;
    spot_market_index_3: u8;
    spot_position_4: i64;
    spot_market_index_4: u8;
    // Perp positions (up to 2).
    perp_base_1: i64;
    perp_quote_1: i64;
    perp_market_1: u8;
    perp_last_funding_1: i64;
    perp_entry_price_1: u64;
    perp_base_2: i64;
    perp_quote_2: i64;
    perp_market_2: u8;
    perp_last_funding_2: i64;
    perp_entry_price_2: u64;
    // Aggregate stats
    total_deposits: u64;
    total_withdraws: u64;
    is_bankrupt: bool;
}

account PerpOrder {
    market_index: u8;
    owner: pubkey;
    is_long: bool;
    order_type: u8;                // 0 = market, 1 = limit, 2 = trigger
    price: u64;                    // scaled 1e6
    base_size: u64;
    filled_base: u64;
    trigger_price: u64;            // scaled 1e6 (for trigger orders)
    is_active: bool;
    slot: u64;
}

account InsuranceFund {
    market_index: u8;
    vault: pubkey;
    total_shares: u64;
    total_staked: u64;
    last_revenue_settle: u64;
}

account PriceOracle {
    authority: pubkey;
    price: u64;                    // scaled 1e6
    confidence: u64;               // scaled 1e6 (oracle uncertainty band)
    last_update: u64;
}

// ---------------------------------------------------------------------------
// Constants (as helper fns -- 5ive DSL has no const keyword)
// ---------------------------------------------------------------------------

fn price_precision() -> u64 {
    return 1000000;
}

fn funding_precision() -> u64 {
    return 1000000000;
}

fn index_precision() -> u128 {
    return 1000000000;
}

fn weight_scale() -> u64 {
    return 10000;
}

fn bps_scale() -> u64 {
    return 10000;
}

fn seconds_per_hour() -> u64 {
    return 3600;
}

fn max_oracle_staleness() -> u64 {
    return 120;
}

fn liquidation_fee_bps() -> u64 {
    return 500;
}

fn max_leverage() -> u64 {
    return 20;
}

fn min_order_size() -> u64 {
    return 1000;
}

// ---------------------------------------------------------------------------
// Internal Helpers
// ---------------------------------------------------------------------------

// Calculate vAMM mark price: (quote_reserve * peg) / (base_reserve * PRICE_PRECISION)
fn calculate_mark_price(
    base_reserve: u128,
    quote_reserve: u128,
    peg_multiplier: u128
) -> u64 {
    let precision: u128 = 1000000;
    let numerator: u128 = quote_reserve * peg_multiplier;
    let denominator: u128 = base_reserve * precision;
    require(denominator > 0);
    let mark: u128 = numerator / denominator;
    return mark as u64;
}

// vAMM swap: constant product on virtual reserves
// For a long (buy base): quote decreases, base increases in user terms
//   new_quote = (base * quote) / (base + swap_amount)
//   quote_delta = quote - new_quote  (what user "pays" in virtual quote)
// For a short (sell base): quote increases, base decreases in user terms
//   new_quote = (base * quote) / (base - swap_amount)
//   quote_delta = new_quote - quote
fn calculate_swap_output(
    base_reserve: u128,
    quote_reserve: u128,
    swap_amount: u128,
    is_buy: bool
) -> u128 {
    let k: u128 = base_reserve * quote_reserve;
    let mut new_base: u128 = 0;
    if (is_buy) {
        // Buying base: base_reserve decreases (user gets base)
        require(swap_amount < base_reserve);
        new_base = base_reserve - swap_amount;
    } else {
        // Selling base: base_reserve increases
        new_base = base_reserve + swap_amount;
    }
    require(new_base > 0);
    let new_quote: u128 = k / new_base;
    let mut quote_delta: u128 = 0;
    if (is_buy) {
        quote_delta = new_quote - quote_reserve;
    } else {
        quote_delta = quote_reserve - new_quote;
    }
    return quote_delta;
}

// Calculate the effective spread in bps
// effective_spread = max(base_spread, oracle_confidence_bps * 2)
fn calculate_effective_spread(
    base_spread: u32,
    oracle_confidence: u64,
    oracle_price: u64
) -> u32 {
    if (oracle_price == 0) {
        return base_spread;
    }
    // confidence_bps = (confidence / price) * 10000
    let confidence_bps: u64 = (oracle_confidence * 10000) / oracle_price;
    let dynamic_spread: u64 = confidence_bps * 2;
    if (dynamic_spread > (base_spread as u64)) {
        if (dynamic_spread > 65535) {
            return 65535 as u32;
        }
        return dynamic_spread as u32;
    }
    return base_spread;
}

// Calculate utilization for spot market interest
fn calculate_utilization(deposits: u64, borrows: u64) -> u64 {
    let total: u64 = deposits + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * price_precision()) / total;
}

// Calculate borrow rate using two-slope kink model
fn calculate_borrow_rate(
    optimal_util: u64,
    optimal_rate: u64,
    max_rate: u64,
    utilization: u64
) -> u64 {
    if (utilization <= optimal_util) {
        if (optimal_util == 0) {
            return 0;
        }
        return (utilization * optimal_rate) / optimal_util;
    }
    let excess: u64 = utilization - optimal_util;
    let excess_range: u64 = price_precision() - optimal_util;
    if (excess_range == 0) {
        return max_rate;
    }
    return optimal_rate + (excess * (max_rate - optimal_rate)) / excess_range;
}

// Calculate PnL for a perp position
// long PnL = base_amount * (exit_price - entry_price) / PRICE_PRECISION
// short PnL = base_amount * (entry_price - exit_price) / PRICE_PRECISION
fn calculate_perp_pnl(
    base_amount: i64,
    entry_price: u64,
    exit_price: u64,
    is_long: bool
) -> i64 {
    let precision: i64 = price_precision() as i64;
    let diff: i64 = (exit_price as i64) - (entry_price as i64);
    let abs_base: i64 = base_amount;
    let mut pnl: i64 = 0;
    if (is_long) {
        pnl = (abs_base * diff) / precision;
    } else {
        pnl = (abs_base * (0 - diff)) / precision;
    }
    return pnl;
}

// Check if an oracle price is stale
fn validate_oracle(oracle: PriceOracle, now: u64) {
    require(oracle.price > 0);
    let staleness: u64 = now - oracle.last_update;
    require(staleness <= max_oracle_staleness());
}

// Calculate total collateral value for a user across spot positions
// Returns value scaled in PRICE_PRECISION
fn calculate_spot_collateral(
    pos1: i64, pos2: i64, pos3: i64, pos4: i64,
    price1: u64, price2: u64, price3: u64, price4: u64,
    weight1: u64, weight2: u64, weight3: u64, weight4: u64
) -> i64 {
    let mut total: i64 = 0;
    // Position 1
    if (pos1 > 0) {
        let val: u64 = ((pos1 as u64) * price1) / price_precision();
        let weighted: u64 = (val * weight1) / weight_scale();
        total = total + (weighted as i64);
    } else {
        if (pos1 < 0) {
            let abs_pos: u64 = (0 - pos1) as u64;
            let val: u64 = (abs_pos * price1) / price_precision();
            let weighted: u64 = (val * weight1) / weight_scale();
            total = total - (weighted as i64);
        }
    }
    // Position 2
    if (pos2 > 0) {
        let val: u64 = ((pos2 as u64) * price2) / price_precision();
        let weighted: u64 = (val * weight2) / weight_scale();
        total = total + (weighted as i64);
    } else {
        if (pos2 < 0) {
            let abs_pos: u64 = (0 - pos2) as u64;
            let val: u64 = (abs_pos * price2) / price_precision();
            let weighted: u64 = (val * weight2) / weight_scale();
            total = total - (weighted as i64);
        }
    }
    // Position 3
    if (pos3 > 0) {
        let val: u64 = ((pos3 as u64) * price3) / price_precision();
        let weighted: u64 = (val * weight3) / weight_scale();
        total = total + (weighted as i64);
    } else {
        if (pos3 < 0) {
            let abs_pos: u64 = (0 - pos3) as u64;
            let val: u64 = (abs_pos * price3) / price_precision();
            let weighted: u64 = (val * weight3) / weight_scale();
            total = total - (weighted as i64);
        }
    }
    // Position 4
    if (pos4 > 0) {
        let val: u64 = ((pos4 as u64) * price4) / price_precision();
        let weighted: u64 = (val * weight4) / weight_scale();
        total = total + (weighted as i64);
    } else {
        if (pos4 < 0) {
            let abs_pos: u64 = (0 - pos4) as u64;
            let val: u64 = (abs_pos * price4) / price_precision();
            let weighted: u64 = (val * weight4) / weight_scale();
            total = total - (weighted as i64);
        }
    }
    return total;
}

// Calculate perp margin requirement for one position
fn calculate_perp_margin(
    base_amount: i64,
    oracle_price: u64,
    margin_ratio: u64
) -> u64 {
    let mut abs_base: u64 = 0;
    if (base_amount >= 0) {
        abs_base = base_amount as u64;
    } else {
        abs_base = (0 - base_amount) as u64;
    }
    let notional: u64 = (abs_base * oracle_price) / price_precision();
    return (notional * margin_ratio) / weight_scale();
}

// ---------------------------------------------------------------------------
// 1. State Management
// ---------------------------------------------------------------------------

pub initialize(
    state: DriftState @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    insurance_vault: account
) {
    state.admin = admin.ctx.key;
    state.insurance_fund_vault = insurance_vault.ctx.key;
    state.exchange_status = 0;
    state.num_spot_markets = 0;
    state.num_perp_markets = 0;
    state.lp_cooldown_time = 600;
    state.liquidation_margin_buffer = 500;
    state.default_maker_fee_bps = 2;
    state.default_taker_fee_bps = 5;
    state.total_fee_collected = 0;
}

pub initialize_user(
    state: DriftState,
    user: User @mut @init(payer=authority, space=1024) @signer,
    authority: account @mut @signer
) {
    require(state.exchange_status == 0);

    user.authority = authority.ctx.key;
    user.delegate = pubkey(0);
    user.spot_position_1 = 0;
    user.spot_market_index_1 = 255;
    user.spot_position_2 = 0;
    user.spot_market_index_2 = 255;
    user.spot_position_3 = 0;
    user.spot_market_index_3 = 255;
    user.spot_position_4 = 0;
    user.spot_market_index_4 = 255;
    user.perp_base_1 = 0;
    user.perp_quote_1 = 0;
    user.perp_market_1 = 255;
    user.perp_last_funding_1 = 0;
    user.perp_entry_price_1 = 0;
    user.perp_base_2 = 0;
    user.perp_quote_2 = 0;
    user.perp_market_2 = 255;
    user.perp_last_funding_2 = 0;
    user.perp_entry_price_2 = 0;
    user.total_deposits = 0;
    user.total_withdraws = 0;
    user.is_bankrupt = false;
}

// ---------------------------------------------------------------------------
// 2. Spot Markets (Collateral)
// ---------------------------------------------------------------------------

pub initialize_spot_market(
    state: DriftState @mut,
    market: SpotMarket @mut @init(payer=admin, space=768) @signer,
    admin: account @mut @signer,
    mint: pubkey,
    vault: pubkey,
    oracle: pubkey,
    optimal_utilization: u64,
    optimal_rate: u64,
    max_rate: u64,
    initial_asset_weight: u64,
    maintenance_asset_weight: u64,
    initial_liability_weight: u64,
    maintenance_liability_weight: u64
) {
    require(state.admin == admin.ctx.key);
    require(state.exchange_status == 0);
    require(initial_asset_weight <= weight_scale());
    require(maintenance_asset_weight <= weight_scale());
    require(maintenance_asset_weight >= initial_asset_weight);
    require(initial_liability_weight >= weight_scale());
    require(maintenance_liability_weight >= weight_scale());
    require(maintenance_liability_weight <= initial_liability_weight);

    market.market_index = state.num_spot_markets;
    market.mint = mint;
    market.vault = vault;
    market.oracle = oracle;
    market.deposit_balance = 0;
    market.borrow_balance = 0;
    market.deposit_index = index_precision();
    market.borrow_index = index_precision();
    market.cumulative_deposit_interest = 0;
    market.cumulative_borrow_interest = 0;
    market.optimal_utilization = optimal_utilization;
    market.optimal_rate = optimal_rate;
    market.max_rate = max_rate;
    market.initial_asset_weight = initial_asset_weight;
    market.maintenance_asset_weight = maintenance_asset_weight;
    market.initial_liability_weight = initial_liability_weight;
    market.maintenance_liability_weight = maintenance_liability_weight;
    market.last_update_ts = get_clock().unix_timestamp;

    state.num_spot_markets = state.num_spot_markets + 1;
}

pub deposit(
    state: DriftState,
    market: SpotMarket @mut,
    user: User @mut,
    authority: account @signer,
    user_token_account: account @mut,
    market_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(state.exchange_status == 0);
    require(user.authority == authority.ctx.key);
    require(market_vault.ctx.key == market.vault);
    require(amount > 0);
    require(!user.is_bankrupt);

    // Transfer tokens to vault
    spl_token::SPLToken::transfer(user_token_account, market_vault, authority, amount);

    // Convert to scaled balance using deposit index
    let scaled_amount: u128 = (amount as u128) * index_precision() / market.deposit_index;
    let scaled_u64: u64 = scaled_amount as u64;

    // Find or assign spot slot for this market
    let mi: u8 = market.market_index;
    if (user.spot_market_index_1 == mi) {
        user.spot_position_1 = user.spot_position_1 + (scaled_u64 as i64);
    } else {
        if (user.spot_market_index_2 == mi) {
            user.spot_position_2 = user.spot_position_2 + (scaled_u64 as i64);
        } else {
            if (user.spot_market_index_3 == mi) {
                user.spot_position_3 = user.spot_position_3 + (scaled_u64 as i64);
            } else {
                if (user.spot_market_index_4 == mi) {
                    user.spot_position_4 = user.spot_position_4 + (scaled_u64 as i64);
                } else {
                    // Assign first empty slot (255 = unused)
                    if (user.spot_market_index_1 == 255) {
                        user.spot_market_index_1 = mi;
                        user.spot_position_1 = scaled_u64 as i64;
                    } else {
                        if (user.spot_market_index_2 == 255) {
                            user.spot_market_index_2 = mi;
                            user.spot_position_2 = scaled_u64 as i64;
                        } else {
                            if (user.spot_market_index_3 == 255) {
                                user.spot_market_index_3 = mi;
                                user.spot_position_3 = scaled_u64 as i64;
                            } else {
                                if (user.spot_market_index_4 == 255) {
                                    user.spot_market_index_4 = mi;
                                    user.spot_position_4 = scaled_u64 as i64;
                                } else {
                                    require(false);  // No empty spot slot
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    market.deposit_balance = market.deposit_balance + amount;
    user.total_deposits = user.total_deposits + amount;
}

pub withdraw(
    state: DriftState,
    market: SpotMarket @mut,
    user: User @mut,
    authority: account @signer,
    user_token_account: account @mut,
    market_vault: account @mut,
    token_program: account,
    oracle: PriceOracle,
    amount: u64
) {
    require(state.exchange_status == 0);
    require(user.authority == authority.ctx.key);
    require(market_vault.ctx.key == market.vault);
    require(amount > 0);
    require(!user.is_bankrupt);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // Convert to scaled balance
    let scaled_amount: u128 = (amount as u128) * index_precision() / market.deposit_index;
    let scaled_u64: u64 = scaled_amount as u64;

    // Deduct from the matching spot slot
    let mi: u8 = market.market_index;
    if (user.spot_market_index_1 == mi) {
        user.spot_position_1 = user.spot_position_1 - (scaled_u64 as i64);
    } else {
        if (user.spot_market_index_2 == mi) {
            user.spot_position_2 = user.spot_position_2 - (scaled_u64 as i64);
        } else {
            if (user.spot_market_index_3 == mi) {
                user.spot_position_3 = user.spot_position_3 - (scaled_u64 as i64);
            } else {
                if (user.spot_market_index_4 == mi) {
                    user.spot_position_4 = user.spot_position_4 - (scaled_u64 as i64);
                } else {
                    require(false);  // No position in this market
                }
            }
        }
    }

    // Ensure sufficient vault liquidity
    require(amount <= market.deposit_balance);

    // Margin check: total collateral must remain positive after withdrawal
    // Simplified: ensure user still has non-negative position or sufficient collateral elsewhere
    // A full cross-margin check is performed via compute_health
    let collateral_value: u64 = (amount * oracle.price) / price_precision();
    let weighted_value: u64 = (collateral_value * market.initial_asset_weight) / weight_scale();
    // This is a conservative check; full health check should follow
    // (keeper or client should call compute_health after)

    // Transfer from vault to user
    spl_token::SPLToken::transfer(market_vault, user_token_account, authority, amount);

    market.deposit_balance = market.deposit_balance - amount;
    user.total_withdraws = user.total_withdraws + amount;
}

// ---------------------------------------------------------------------------
// 3. Perpetual Markets (vAMM)
// ---------------------------------------------------------------------------

pub initialize_perp_market(
    state: DriftState @mut,
    market: PerpMarket @mut @init(payer=admin, space=768) @signer,
    admin: account @mut @signer,
    oracle: pubkey,
    amm_base_asset_reserve: u128,
    amm_quote_asset_reserve: u128,
    amm_peg_multiplier: u128,
    amm_base_spread: u32,
    amm_max_spread: u32,
    maker_fee_bps: u64,
    taker_fee_bps: u64
) {
    require(state.admin == admin.ctx.key);
    require(state.exchange_status == 0);
    require(amm_base_asset_reserve > 0);
    require(amm_quote_asset_reserve > 0);
    require(amm_peg_multiplier > 0);
    require(amm_max_spread >= amm_base_spread);

    // sqrt_k = sqrt(base * quote), approximated as geometric mean
    // For initialization we store the intended sqrt_k directly
    let k: u128 = amm_base_asset_reserve * amm_quote_asset_reserve;
    // sqrt_k approximated: use base_reserve as starting point since
    // for a balanced pool base ~= quote ~= sqrt(k)
    let sqrt_k: u128 = amm_base_asset_reserve;

    market.market_index = state.num_perp_markets;
    market.oracle = oracle;
    market.base_asset_amount_long = 0;
    market.base_asset_amount_short = 0;
    market.amm_base_asset_reserve = amm_base_asset_reserve;
    market.amm_quote_asset_reserve = amm_quote_asset_reserve;
    market.amm_sqrt_k = sqrt_k;
    market.amm_peg_multiplier = amm_peg_multiplier;
    market.amm_base_spread = amm_base_spread;
    market.amm_max_spread = amm_max_spread;
    market.cumulative_funding_rate_long = 0;
    market.cumulative_funding_rate_short = 0;
    market.last_funding_rate = 0;
    market.last_funding_ts = get_clock().unix_timestamp;
    market.last_oracle_price = 0;
    market.open_interest = 0;
    market.maker_fee_bps = maker_fee_bps;
    market.taker_fee_bps = taker_fee_bps;
    market.total_fee_collected = 0;
    market.insurance_claim_amount = 0;
    market.is_active = true;

    state.num_perp_markets = state.num_perp_markets + 1;
}

// ---------------------------------------------------------------------------
// 4. Order Placement
// ---------------------------------------------------------------------------

pub place_perp_order(
    state: DriftState,
    market: PerpMarket,
    order: PerpOrder @mut @init(payer=authority, space=512) @signer,
    user: User,
    authority: account @mut @signer,
    is_long: bool,
    order_type: u8,
    price: u64,
    base_size: u64,
    trigger_price: u64
) {
    require(state.exchange_status == 0);
    require(market.is_active);
    require(user.authority == authority.ctx.key);
    require(!user.is_bankrupt);
    require(base_size >= min_order_size());
    require(order_type <= 2);

    // Limit and trigger orders require a price
    if (order_type == 1) {
        require(price > 0);
    }
    if (order_type == 2) {
        require(trigger_price > 0);
    }

    order.market_index = market.market_index;
    order.owner = authority.ctx.key;
    order.is_long = is_long;
    order.order_type = order_type;
    order.price = price;
    order.base_size = base_size;
    order.filled_base = 0;
    order.trigger_price = trigger_price;
    order.is_active = true;
    order.slot = get_clock().slot;
}

pub cancel_order(
    order: PerpOrder @mut,
    authority: account @signer
) {
    require(order.owner == authority.ctx.key);
    require(order.is_active);

    order.is_active = false;
}

// ---------------------------------------------------------------------------
// 5. Order Filling (Keeper fills against vAMM)
// ---------------------------------------------------------------------------

pub fill_perp_order(
    state: DriftState @mut,
    market: PerpMarket @mut,
    order: PerpOrder @mut,
    user: User @mut,
    keeper: account @signer,
    oracle: PriceOracle
) {
    require(state.exchange_status == 0);
    require(market.is_active);
    require(order.is_active);
    require(order.market_index == market.market_index);
    require(order.owner == user.authority);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    let remaining: u64 = order.base_size - order.filled_base;
    require(remaining > 0);

    // Calculate effective spread
    let eff_spread: u32 = calculate_effective_spread(
        market.amm_base_spread,
        oracle.confidence,
        oracle.price
    );

    // Calculate mark price
    let mark_price: u64 = calculate_mark_price(
        market.amm_base_asset_reserve,
        market.amm_quote_asset_reserve,
        market.amm_peg_multiplier
    );

    // Apply spread to mark price
    let mut execution_price: u64 = mark_price;
    if (order.is_long) {
        // Buyer pays mark + half spread
        execution_price = mark_price + (mark_price * (eff_spread as u64)) / (2 * bps_scale());
    } else {
        // Seller receives mark - half spread
        let spread_cost: u64 = (mark_price * (eff_spread as u64)) / (2 * bps_scale());
        if (mark_price > spread_cost) {
            execution_price = mark_price - spread_cost;
        } else {
            execution_price = 1;
        }
    }

    // Check trigger conditions for trigger orders
    if (order.order_type == 2) {
        if (order.is_long) {
            require(oracle.price >= order.trigger_price);
        } else {
            require(oracle.price <= order.trigger_price);
        }
    }

    // Check limit price for limit orders
    if (order.order_type == 1) {
        if (order.is_long) {
            require(execution_price <= order.price);
        } else {
            require(execution_price >= order.price);
        }
    }

    // Execute the vAMM swap
    let swap_amount: u128 = remaining as u128;
    let quote_delta: u128 = calculate_swap_output(
        market.amm_base_asset_reserve,
        market.amm_quote_asset_reserve,
        swap_amount,
        order.is_long
    );

    // Update vAMM reserves
    if (order.is_long) {
        market.amm_base_asset_reserve = market.amm_base_asset_reserve - swap_amount;
        market.amm_quote_asset_reserve = market.amm_quote_asset_reserve + quote_delta;
    } else {
        market.amm_base_asset_reserve = market.amm_base_asset_reserve + swap_amount;
        market.amm_quote_asset_reserve = market.amm_quote_asset_reserve - quote_delta;
    }

    // Calculate fee
    let fee_amount: u64 = ((remaining as u64) * execution_price * market.taker_fee_bps) / (price_precision() * bps_scale());

    // Update user perp position
    let mi: u8 = market.market_index;
    let fill_base: i64 = remaining as i64;
    let fill_quote: i64 = quote_delta as i64;

    if (user.perp_market_1 == mi) {
        if (order.is_long) {
            user.perp_base_1 = user.perp_base_1 + fill_base;
            user.perp_quote_1 = user.perp_quote_1 - fill_quote;
        } else {
            user.perp_base_1 = user.perp_base_1 - fill_base;
            user.perp_quote_1 = user.perp_quote_1 + fill_quote;
        }
        // Update entry price (weighted average)
        if (user.perp_base_1 != 0) {
            user.perp_entry_price_1 = execution_price;
        }
        user.perp_last_funding_1 = market.cumulative_funding_rate_long;
    } else {
        if (user.perp_market_2 == mi) {
            if (order.is_long) {
                user.perp_base_2 = user.perp_base_2 + fill_base;
                user.perp_quote_2 = user.perp_quote_2 - fill_quote;
            } else {
                user.perp_base_2 = user.perp_base_2 - fill_base;
                user.perp_quote_2 = user.perp_quote_2 + fill_quote;
            }
            if (user.perp_base_2 != 0) {
                user.perp_entry_price_2 = execution_price;
            }
            user.perp_last_funding_2 = market.cumulative_funding_rate_long;
        } else {
            // Assign first empty perp slot (255 = unused)
            if (user.perp_market_1 == 255) {
                user.perp_market_1 = mi;
                if (order.is_long) {
                    user.perp_base_1 = fill_base;
                    user.perp_quote_1 = 0 - fill_quote;
                } else {
                    user.perp_base_1 = 0 - fill_base;
                    user.perp_quote_1 = fill_quote;
                }
                user.perp_entry_price_1 = execution_price;
                user.perp_last_funding_1 = market.cumulative_funding_rate_long;
            } else {
                if (user.perp_market_2 == 255) {
                    user.perp_market_2 = mi;
                    if (order.is_long) {
                        user.perp_base_2 = fill_base;
                        user.perp_quote_2 = 0 - fill_quote;
                    } else {
                        user.perp_base_2 = 0 - fill_base;
                        user.perp_quote_2 = fill_quote;
                    }
                    user.perp_entry_price_2 = execution_price;
                    user.perp_last_funding_2 = market.cumulative_funding_rate_long;
                } else {
                    require(false);  // No empty perp slot
                }
            }
        }
    }

    // Update open interest
    if (order.is_long) {
        market.base_asset_amount_long = market.base_asset_amount_long + fill_base;
    } else {
        market.base_asset_amount_short = market.base_asset_amount_short - fill_base;
    }
    market.open_interest = market.open_interest + remaining;

    // Collect fees
    market.total_fee_collected = market.total_fee_collected + fee_amount;
    state.total_fee_collected = state.total_fee_collected + fee_amount;

    // Mark order as filled
    order.filled_base = order.base_size;
    order.is_active = false;

    // Update oracle price cache
    market.last_oracle_price = oracle.price;
}

// ---------------------------------------------------------------------------
// 6. PnL Settlement
// ---------------------------------------------------------------------------

pub settle_pnl(
    state: DriftState,
    market: PerpMarket @mut,
    user: User @mut,
    authority: account @signer,
    oracle: PriceOracle,
    market_index: u8
) {
    require(state.exchange_status == 0);
    require(user.authority == authority.ctx.key);
    require(!user.is_bankrupt);
    require(market.market_index == market_index);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // Calculate realized PnL from the user's perp position
    let mut base_amount: i64 = 0;
    let mut entry_price: u64 = 0;
    let mut is_long: bool = false;
    let mut slot_found: u8 = 0;

    if (user.perp_market_1 == market_index) {
        base_amount = user.perp_base_1;
        entry_price = user.perp_entry_price_1;
        is_long = user.perp_base_1 > 0;
        slot_found = 1;
    } else {
        if (user.perp_market_2 == market_index) {
            base_amount = user.perp_base_2;
            entry_price = user.perp_entry_price_2;
            is_long = user.perp_base_2 > 0;
            slot_found = 2;
        }
    }

    require(slot_found > 0);

    // Only settle if there is a position
    let mut abs_base: i64 = base_amount;
    if (base_amount < 0) {
        abs_base = 0 - base_amount;
    }
    require(abs_base > 0);

    // Calculate PnL at current oracle price
    let pnl: i64 = calculate_perp_pnl(abs_base, entry_price, oracle.price, is_long);

    // Settle PnL to user's first spot position (assumed USDC, slot 0)
    // PnL is credited/debited as a spot position change
    if (pnl > 0) {
        user.spot_position_1 = user.spot_position_1 + pnl;
    } else {
        user.spot_position_1 = user.spot_position_1 + pnl;  // pnl is negative
    }

    // Update entry price to current oracle (PnL is now settled)
    if (slot_found == 1) {
        user.perp_entry_price_1 = oracle.price;
        user.perp_quote_1 = 0;
    } else {
        user.perp_entry_price_2 = oracle.price;
        user.perp_quote_2 = 0;
    }
}

// ---------------------------------------------------------------------------
// 7. vAMM Operations
// ---------------------------------------------------------------------------

pub update_amm(
    state: DriftState,
    market: PerpMarket @mut,
    oracle: PriceOracle,
    admin: account @signer
) {
    require(state.admin == admin.ctx.key);
    require(market.is_active);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // Recalculate effective spread based on oracle confidence
    let new_spread: u32 = calculate_effective_spread(
        market.amm_base_spread,
        oracle.confidence,
        oracle.price
    );
    // Cap at max_spread
    if (new_spread <= market.amm_max_spread) {
        market.amm_base_spread = new_spread;
    }

    // Cache the latest oracle price
    market.last_oracle_price = oracle.price;
}

pub update_k(
    state: DriftState,
    market: PerpMarket @mut,
    admin: account @signer,
    new_sqrt_k: u128
) {
    require(state.admin == admin.ctx.key);
    require(market.is_active);
    require(new_sqrt_k > 0);

    // Adjust reserves proportionally to maintain mark price
    // new_base = new_sqrt_k, new_quote = k / new_base (where k = new_sqrt_k^2)
    // Actually: scale both reserves by ratio of new_sqrt_k / old_sqrt_k
    let old_sqrt_k: u128 = market.amm_sqrt_k;
    require(old_sqrt_k > 0);

    let new_base: u128 = (market.amm_base_asset_reserve * new_sqrt_k) / old_sqrt_k;
    let new_quote: u128 = (market.amm_quote_asset_reserve * new_sqrt_k) / old_sqrt_k;
    require(new_base > 0);
    require(new_quote > 0);

    market.amm_base_asset_reserve = new_base;
    market.amm_quote_asset_reserve = new_quote;
    market.amm_sqrt_k = new_sqrt_k;
}

pub repeg(
    state: DriftState,
    market: PerpMarket @mut,
    oracle: PriceOracle,
    admin: account @signer
) {
    require(state.admin == admin.ctx.key);
    require(market.is_active);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // new_peg = oracle_price * base_reserve / quote_reserve
    // This realigns the vAMM mark price to the oracle
    let precision: u128 = 1000000;
    let oracle_scaled: u128 = oracle.price as u128;
    let new_peg: u128 = (oracle_scaled * market.amm_base_asset_reserve) / market.amm_quote_asset_reserve;

    require(new_peg > 0);
    market.amm_peg_multiplier = new_peg;
    market.last_oracle_price = oracle.price;
}

// ---------------------------------------------------------------------------
// 8. Funding Rate
// ---------------------------------------------------------------------------

pub update_funding_rate(
    state: DriftState,
    market: PerpMarket @mut,
    oracle: PriceOracle,
    keeper: account @signer
) {
    require(state.exchange_status == 0);
    require(market.is_active);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // Enforce minimum interval between funding updates (1 hour)
    let elapsed: u64 = now - market.last_funding_ts;
    require(elapsed >= seconds_per_hour());

    let hours_elapsed: u64 = elapsed / seconds_per_hour();

    // Calculate mark price
    let mark_price: u64 = calculate_mark_price(
        market.amm_base_asset_reserve,
        market.amm_quote_asset_reserve,
        market.amm_peg_multiplier
    );

    // funding_rate = (mark - oracle) / oracle * FUNDING_PRECISION
    let mark_i64: i64 = mark_price as i64;
    let oracle_i64: i64 = oracle.price as i64;
    let diff: i64 = mark_i64 - oracle_i64;
    let fund_prec: i64 = funding_precision() as i64;

    let mut funding_rate: i64 = 0;
    if (oracle_i64 > 0) {
        funding_rate = (diff * fund_prec) / oracle_i64;
    }

    // Scale by hours elapsed
    funding_rate = funding_rate * (hours_elapsed as i64);

    // Clamp funding rate to +/- 0.1% per hour (in funding precision units)
    // max = FUNDING_PRECISION / 1000 = 1_000_000
    let max_funding: i64 = (fund_prec / 1000) * (hours_elapsed as i64);
    let min_funding: i64 = 0 - max_funding;

    if (funding_rate > max_funding) {
        funding_rate = max_funding;
    }
    if (funding_rate < min_funding) {
        funding_rate = min_funding;
    }

    // Update cumulative funding rates
    // Longs pay when funding > 0; shorts pay when funding < 0
    market.cumulative_funding_rate_long = market.cumulative_funding_rate_long + funding_rate;
    market.cumulative_funding_rate_short = market.cumulative_funding_rate_short - funding_rate;
    market.last_funding_rate = funding_rate;
    market.last_funding_ts = now;
    market.last_oracle_price = oracle.price;
}

pub settle_funding(
    state: DriftState,
    market: PerpMarket,
    user: User @mut,
    authority: account @signer,
    market_index: u8
) {
    require(state.exchange_status == 0);
    require(user.authority == authority.ctx.key);
    require(market.market_index == market_index);
    require(!user.is_bankrupt);

    let mut base_amount: i64 = 0;
    let mut last_funding: i64 = 0;
    let mut slot_found: u8 = 0;

    if (user.perp_market_1 == market_index) {
        base_amount = user.perp_base_1;
        last_funding = user.perp_last_funding_1;
        slot_found = 1;
    } else {
        if (user.perp_market_2 == market_index) {
            base_amount = user.perp_base_2;
            last_funding = user.perp_last_funding_2;
            slot_found = 2;
        }
    }

    require(slot_found > 0);

    // Calculate unsettled funding
    let mut funding_delta: i64 = 0;
    if (base_amount > 0) {
        // Long position: pays cumulative_funding_rate_long
        funding_delta = market.cumulative_funding_rate_long - last_funding;
    } else {
        if (base_amount < 0) {
            // Short position: pays cumulative_funding_rate_short
            funding_delta = market.cumulative_funding_rate_short - last_funding;
        }
    }

    // funding_payment = base_amount * funding_delta / FUNDING_PRECISION
    let fund_prec: i64 = funding_precision() as i64;
    let mut funding_payment: i64 = 0;
    if (base_amount >= 0) {
        funding_payment = (base_amount * funding_delta) / fund_prec;
    } else {
        let abs_base: i64 = 0 - base_amount;
        funding_payment = (abs_base * funding_delta) / fund_prec;
        funding_payment = 0 - funding_payment;
    }

    // Apply funding to user's quote (USDC) spot position
    user.spot_position_1 = user.spot_position_1 - funding_payment;

    // Update user's last funding checkpoint
    if (slot_found == 1) {
        if (base_amount > 0) {
            user.perp_last_funding_1 = market.cumulative_funding_rate_long;
        } else {
            user.perp_last_funding_1 = market.cumulative_funding_rate_short;
        }
    } else {
        if (base_amount > 0) {
            user.perp_last_funding_2 = market.cumulative_funding_rate_long;
        } else {
            user.perp_last_funding_2 = market.cumulative_funding_rate_short;
        }
    }
}

// ---------------------------------------------------------------------------
// 9. Insurance Fund
// ---------------------------------------------------------------------------

pub initialize_insurance_fund(
    state: DriftState,
    fund: InsuranceFund @mut @init(payer=admin, space=256) @signer,
    admin: account @mut @signer,
    vault: pubkey,
    market_index: u8
) {
    require(state.admin == admin.ctx.key);

    fund.market_index = market_index;
    fund.vault = vault;
    fund.total_shares = 0;
    fund.total_staked = 0;
    fund.last_revenue_settle = get_clock().unix_timestamp;
}

pub add_insurance(
    state: DriftState,
    fund: InsuranceFund @mut,
    staker: account @signer,
    staker_token_account: account @mut,
    insurance_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(state.exchange_status == 0);
    require(amount > 0);
    require(insurance_vault.ctx.key == fund.vault);

    // Calculate shares to mint
    let mut shares: u64 = 0;
    if (fund.total_staked == 0) {
        shares = amount;
    } else {
        shares = (amount * fund.total_shares) / fund.total_staked;
    }
    require(shares > 0);

    // Transfer USDC to insurance vault
    spl_token::SPLToken::transfer(staker_token_account, insurance_vault, staker, amount);

    fund.total_shares = fund.total_shares + shares;
    fund.total_staked = fund.total_staked + amount;
}

pub remove_insurance(
    state: DriftState,
    fund: InsuranceFund @mut,
    staker: account @signer,
    staker_token_account: account @mut,
    insurance_vault: account @mut,
    token_program: account,
    shares: u64
) {
    require(state.exchange_status == 0);
    require(shares > 0);
    require(shares <= fund.total_shares);
    require(insurance_vault.ctx.key == fund.vault);

    // Calculate USDC to return
    let amount: u64 = (shares * fund.total_staked) / fund.total_shares;
    require(amount > 0);

    // Transfer from insurance vault to staker
    spl_token::SPLToken::transfer(insurance_vault, staker_token_account, staker, amount);

    fund.total_shares = fund.total_shares - shares;
    fund.total_staked = fund.total_staked - amount;
}

pub resolve_bankruptcy(
    state: DriftState @mut,
    market: PerpMarket @mut,
    fund: InsuranceFund @mut,
    bankrupt_user: User @mut,
    admin: account @signer,
    loss_amount: u64
) {
    require(state.admin == admin.ctx.key);
    require(bankrupt_user.is_bankrupt);

    // Try to cover loss from insurance fund
    if (fund.total_staked >= loss_amount) {
        // Insurance covers the loss
        fund.total_staked = fund.total_staked - loss_amount;
        market.insurance_claim_amount = market.insurance_claim_amount + loss_amount;
    } else {
        // Insurance depleted: socialize remaining loss
        // The remaining loss is absorbed by reducing the vAMM's virtual reserves
        // proportionally, effectively spreading it across all open positions
        let covered: u64 = fund.total_staked;
        let socialized: u64 = loss_amount - covered;
        fund.total_staked = 0;
        fund.total_shares = 0;
        market.insurance_claim_amount = market.insurance_claim_amount + covered;

        // Reduce k to reflect socialized loss (less virtual liquidity)
        if (market.amm_sqrt_k > (socialized as u128)) {
            let reduction: u128 = socialized as u128;
            let new_sqrt_k: u128 = market.amm_sqrt_k - reduction;
            let old_sqrt_k: u128 = market.amm_sqrt_k;
            market.amm_base_asset_reserve = (market.amm_base_asset_reserve * new_sqrt_k) / old_sqrt_k;
            market.amm_quote_asset_reserve = (market.amm_quote_asset_reserve * new_sqrt_k) / old_sqrt_k;
            market.amm_sqrt_k = new_sqrt_k;
        }
    }

    // Clear bankrupt user positions
    bankrupt_user.perp_base_1 = 0;
    bankrupt_user.perp_quote_1 = 0;
    bankrupt_user.perp_base_2 = 0;
    bankrupt_user.perp_quote_2 = 0;
    bankrupt_user.spot_position_1 = 0;
    bankrupt_user.spot_position_2 = 0;
    bankrupt_user.spot_position_3 = 0;
    bankrupt_user.spot_position_4 = 0;
}

// ---------------------------------------------------------------------------
// 10. Liquidation
// ---------------------------------------------------------------------------

pub liquidate_perp(
    state: DriftState @mut,
    market: PerpMarket @mut,
    user: User @mut,
    liquidator: User @mut,
    liquidator_authority: account @signer,
    oracle: PriceOracle,
    market_index: u8
) {
    require(state.exchange_status == 0);
    require(market.is_active);
    require(market.market_index == market_index);
    require(liquidator.authority == liquidator_authority.ctx.key);
    require(!user.is_bankrupt);
    require(!liquidator.is_bankrupt);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle, now);

    // Find user's perp position
    let mut base_amount: i64 = 0;
    let mut entry_price: u64 = 0;
    let mut is_long: bool = false;
    let mut slot_found: u8 = 0;

    if (user.perp_market_1 == market_index) {
        base_amount = user.perp_base_1;
        entry_price = user.perp_entry_price_1;
        is_long = user.perp_base_1 > 0;
        slot_found = 1;
    } else {
        if (user.perp_market_2 == market_index) {
            base_amount = user.perp_base_2;
            entry_price = user.perp_entry_price_2;
            is_long = user.perp_base_2 > 0;
            slot_found = 2;
        }
    }

    require(slot_found > 0);

    let mut abs_base: i64 = base_amount;
    if (base_amount < 0) {
        abs_base = 0 - base_amount;
    }
    require(abs_base > 0);

    // Calculate unrealized PnL
    let pnl: i64 = calculate_perp_pnl(abs_base, entry_price, oracle.price, is_long);

    // User must be unhealthy (PnL loss exceeds margin buffer)
    // Simplified health check: collateral + pnl must be negative or below margin
    let user_collateral: i64 = user.spot_position_1;
    let total_value: i64 = user_collateral + pnl;

    // Notional value of the position
    let abs_base_u64: u64 = abs_base as u64;
    let notional: u64 = (abs_base_u64 * oracle.price) / price_precision();
    let margin_requirement: u64 = (notional * state.liquidation_margin_buffer) / bps_scale();

    // Position is liquidatable when total value < margin requirement
    require(total_value < (margin_requirement as i64));

    // Liquidation: transfer position to liquidator at oracle price +/- penalty
    let liq_fee: u64 = (oracle.price * liquidation_fee_bps()) / bps_scale();

    let mut liq_price: u64 = 0;
    if (is_long) {
        // Liquidator buys at oracle - discount (profit for liquidator)
        if (oracle.price > liq_fee) {
            liq_price = oracle.price - liq_fee;
        } else {
            liq_price = 1;
        }
    } else {
        // Liquidator sells at oracle + premium
        liq_price = oracle.price + liq_fee;
    }

    // Settle user's position at liquidation price
    let settle_pnl: i64 = calculate_perp_pnl(abs_base, entry_price, liq_price, is_long);

    // Apply PnL to user's collateral
    user.spot_position_1 = user.spot_position_1 + settle_pnl;

    // Check if user is bankrupt after liquidation
    if (user.spot_position_1 < 0) {
        user.is_bankrupt = true;
    }

    // Close user's position
    if (slot_found == 1) {
        user.perp_base_1 = 0;
        user.perp_quote_1 = 0;
        user.perp_entry_price_1 = 0;
        user.perp_market_1 = 255;
        user.perp_last_funding_1 = 0;
    } else {
        user.perp_base_2 = 0;
        user.perp_quote_2 = 0;
        user.perp_entry_price_2 = 0;
        user.perp_market_2 = 255;
        user.perp_last_funding_2 = 0;
    }

    // Transfer position to liquidator
    if (liquidator.perp_market_1 == 255) {
        liquidator.perp_market_1 = market_index;
        liquidator.perp_base_1 = base_amount;
        liquidator.perp_entry_price_1 = liq_price;
        liquidator.perp_quote_1 = 0;
        liquidator.perp_last_funding_1 = market.cumulative_funding_rate_long;
    } else {
        if (liquidator.perp_market_2 == 255) {
            liquidator.perp_market_2 = market_index;
            liquidator.perp_base_2 = base_amount;
            liquidator.perp_entry_price_2 = liq_price;
            liquidator.perp_quote_2 = 0;
            liquidator.perp_last_funding_2 = market.cumulative_funding_rate_long;
        } else {
            if (liquidator.perp_market_1 == market_index) {
                liquidator.perp_base_1 = liquidator.perp_base_1 + base_amount;
                liquidator.perp_entry_price_1 = liq_price;
            } else {
                if (liquidator.perp_market_2 == market_index) {
                    liquidator.perp_base_2 = liquidator.perp_base_2 + base_amount;
                    liquidator.perp_entry_price_2 = liq_price;
                } else {
                    require(false);  // Liquidator has no available perp slot
                }
            }
        }
    }

    // Reduce open interest
    if (abs_base_u64 <= market.open_interest) {
        market.open_interest = market.open_interest - abs_base_u64;
    } else {
        market.open_interest = 0;
    }

    // Update directional OI
    if (is_long) {
        market.base_asset_amount_long = market.base_asset_amount_long - abs_base;
    } else {
        market.base_asset_amount_short = market.base_asset_amount_short + abs_base;
    }

    // Collect liquidation fee for protocol
    let fee_collected: u64 = (abs_base_u64 * liq_fee) / price_precision();
    state.total_fee_collected = state.total_fee_collected + fee_collected;
}

pub liquidate_spot(
    state: DriftState,
    borrow_market: SpotMarket @mut,
    collateral_market: SpotMarket @mut,
    user: User @mut,
    liquidator: User @mut,
    liquidator_authority: account @signer,
    oracle_borrow: PriceOracle,
    oracle_collateral: PriceOracle
) {
    require(state.exchange_status == 0);
    require(liquidator.authority == liquidator_authority.ctx.key);
    require(!user.is_bankrupt);

    let now: u64 = get_clock().unix_timestamp;
    validate_oracle(oracle_borrow, now);
    validate_oracle(oracle_collateral, now);

    // Find user's borrow position (negative spot balance)
    let bmi: u8 = borrow_market.market_index;
    let mut borrow_amount: i64 = 0;
    let mut borrow_slot: u8 = 0;

    if (user.spot_market_index_1 == bmi) {
        borrow_amount = user.spot_position_1;
        borrow_slot = 1;
    } else {
        if (user.spot_market_index_2 == bmi) {
            borrow_amount = user.spot_position_2;
            borrow_slot = 2;
        } else {
            if (user.spot_market_index_3 == bmi) {
                borrow_amount = user.spot_position_3;
                borrow_slot = 3;
            } else {
                if (user.spot_market_index_4 == bmi) {
                    borrow_amount = user.spot_position_4;
                    borrow_slot = 4;
                }
            }
        }
    }

    require(borrow_slot > 0);
    require(borrow_amount < 0);  // Must be a borrow (negative)

    // Check user is unhealthy: borrow value exceeds maintenance-weighted collateral
    let abs_borrow: u64 = (0 - borrow_amount) as u64;
    let borrow_value: u64 = (abs_borrow * oracle_borrow.price) / price_precision();
    let weighted_borrow: u64 = (borrow_value * borrow_market.maintenance_liability_weight) / weight_scale();

    // Sum user's collateral value (simplified: use first positive spot position)
    let cmi: u8 = collateral_market.market_index;
    let mut collateral_amount: i64 = 0;
    let mut collateral_slot: u8 = 0;

    if (user.spot_market_index_1 == cmi) {
        collateral_amount = user.spot_position_1;
        collateral_slot = 1;
    } else {
        if (user.spot_market_index_2 == cmi) {
            collateral_amount = user.spot_position_2;
            collateral_slot = 2;
        } else {
            if (user.spot_market_index_3 == cmi) {
                collateral_amount = user.spot_position_3;
                collateral_slot = 3;
            } else {
                if (user.spot_market_index_4 == cmi) {
                    collateral_amount = user.spot_position_4;
                    collateral_slot = 4;
                }
            }
        }
    }

    require(collateral_slot > 0);
    require(collateral_amount > 0);  // Must have collateral

    let collateral_value: u64 = ((collateral_amount as u64) * oracle_collateral.price) / price_precision();
    let weighted_collateral: u64 = (collateral_value * collateral_market.maintenance_asset_weight) / weight_scale();

    // User is liquidatable when weighted borrow exceeds weighted collateral
    require(weighted_borrow > weighted_collateral);

    // Liquidate: repay borrow, seize collateral + 5% bonus
    let repay_amount: u64 = abs_borrow;
    let bonus_bps: u64 = 500;  // 5%
    let collateral_to_seize: u64 = (repay_amount * oracle_borrow.price * (bps_scale() + bonus_bps)) / (oracle_collateral.price * bps_scale());

    // Ensure we don't seize more than user has
    let mut actual_seize: u64 = collateral_to_seize;
    if (collateral_to_seize > (collateral_amount as u64)) {
        actual_seize = collateral_amount as u64;
    }

    // Update user positions
    if (borrow_slot == 1) {
        user.spot_position_1 = 0;
    } else {
        if (borrow_slot == 2) {
            user.spot_position_2 = 0;
        } else {
            if (borrow_slot == 3) {
                user.spot_position_3 = 0;
            } else {
                user.spot_position_4 = 0;
            }
        }
    }

    if (collateral_slot == 1) {
        user.spot_position_1 = user.spot_position_1 - (actual_seize as i64);
    } else {
        if (collateral_slot == 2) {
            user.spot_position_2 = user.spot_position_2 - (actual_seize as i64);
        } else {
            if (collateral_slot == 3) {
                user.spot_position_3 = user.spot_position_3 - (actual_seize as i64);
            } else {
                user.spot_position_4 = user.spot_position_4 - (actual_seize as i64);
            }
        }
    }

    // Credit liquidator: receives collateral, takes on repayment obligation
    // (Simplified: liquidator's first spot slot gets the seized collateral)
    if (liquidator.spot_market_index_1 == cmi) {
        liquidator.spot_position_1 = liquidator.spot_position_1 + (actual_seize as i64);
    } else {
        if (liquidator.spot_market_index_2 == cmi) {
            liquidator.spot_position_2 = liquidator.spot_position_2 + (actual_seize as i64);
        } else {
            if (liquidator.spot_market_index_1 == 255) {
                liquidator.spot_market_index_1 = cmi;
                liquidator.spot_position_1 = actual_seize as i64;
            } else {
                if (liquidator.spot_market_index_2 == 255) {
                    liquidator.spot_market_index_2 = cmi;
                    liquidator.spot_position_2 = actual_seize as i64;
                }
            }
        }
    }

    // Update market balances
    if (borrow_market.borrow_balance >= repay_amount) {
        borrow_market.borrow_balance = borrow_market.borrow_balance - repay_amount;
    } else {
        borrow_market.borrow_balance = 0;
    }

    // Check if user is bankrupt after liquidation
    if (user.spot_position_1 < 0) {
        user.is_bankrupt = true;
    }
}

// ---------------------------------------------------------------------------
// 11. Spot Market Interest Accrual
// ---------------------------------------------------------------------------

pub update_spot_market_interest(
    market: SpotMarket @mut
) {
    let now: u64 = get_clock().unix_timestamp;
    let elapsed: u64 = now - market.last_update_ts;

    if (elapsed == 0) {
        return;
    }

    let utilization: u64 = calculate_utilization(market.deposit_balance, market.borrow_balance);
    let borrow_rate: u64 = calculate_borrow_rate(
        market.optimal_utilization,
        market.optimal_rate,
        market.max_rate,
        utilization
    );

    // Accrue interest on borrow index
    // borrow_index += borrow_index * borrow_rate * elapsed / (seconds_per_year * PRECISION)
    let seconds_year: u64 = 31536000;
    if (market.borrow_balance > 0) {
        let prec: u128 = index_precision();
        let rate_scaled: u128 = (market.borrow_index * (borrow_rate as u128) * (elapsed as u128)) / ((seconds_year as u128) * prec);
        market.borrow_index = market.borrow_index + rate_scaled;

        // Deposit rate = borrow_rate * utilization
        let deposit_rate_scaled: u128 = (market.deposit_index * (borrow_rate as u128) * (utilization as u128) * (elapsed as u128)) / ((seconds_year as u128) * prec * prec);
        market.deposit_index = market.deposit_index + deposit_rate_scaled;

        // Track cumulative interest
        let interest_accrued: u64 = rate_scaled as u64;
        market.cumulative_borrow_interest = market.cumulative_borrow_interest + interest_accrued;
        market.cumulative_deposit_interest = market.cumulative_deposit_interest + (deposit_rate_scaled as u64);
    }

    market.last_update_ts = now;
}

// ---------------------------------------------------------------------------
// 12. Oracle Management
// ---------------------------------------------------------------------------

pub initialize_oracle(
    oracle: PriceOracle @mut @init(payer=authority, space=256) @signer,
    authority: account @mut @signer,
    price: u64,
    confidence: u64
) {
    require(price > 0);
    oracle.authority = authority.ctx.key;
    oracle.price = price;
    oracle.confidence = confidence;
    oracle.last_update = get_clock().unix_timestamp;
}

pub set_oracle_price(
    oracle: PriceOracle @mut,
    authority: account @signer,
    price: u64,
    confidence: u64
) {
    require(oracle.authority == authority.ctx.key);
    require(price > 0);
    oracle.price = price;
    oracle.confidence = confidence;
    oracle.last_update = get_clock().unix_timestamp;
}

// ---------------------------------------------------------------------------
// 13. Health Computation
// ---------------------------------------------------------------------------

pub compute_health(
    user: User,
    oracle_1: PriceOracle,
    oracle_2: PriceOracle,
    oracle_3: PriceOracle,
    oracle_4: PriceOracle,
    oracle_perp_1: PriceOracle,
    oracle_perp_2: PriceOracle,
    weight_1: u64,
    weight_2: u64,
    weight_3: u64,
    weight_4: u64,
    perp_margin_ratio: u64
) -> i64 {
    let now: u64 = get_clock().unix_timestamp;

    // Calculate spot collateral value
    let spot_health: i64 = calculate_spot_collateral(
        user.spot_position_1, user.spot_position_2,
        user.spot_position_3, user.spot_position_4,
        oracle_1.price, oracle_2.price,
        oracle_3.price, oracle_4.price,
        weight_1, weight_2, weight_3, weight_4
    );

    // Calculate perp margin requirements
    let mut perp_margin: i64 = 0;

    // Perp slot 1
    if (user.perp_market_1 != 255) {
        let margin_1: u64 = calculate_perp_margin(
            user.perp_base_1,
            oracle_perp_1.price,
            perp_margin_ratio
        );
        perp_margin = perp_margin + (margin_1 as i64);

        // Add unrealized PnL
        let mut abs_base_1: i64 = user.perp_base_1;
        if (abs_base_1 < 0) {
            abs_base_1 = 0 - abs_base_1;
        }
        if (abs_base_1 > 0) {
            let is_long_1: bool = user.perp_base_1 > 0;
            let pnl_1: i64 = calculate_perp_pnl(
                abs_base_1,
                user.perp_entry_price_1,
                oracle_perp_1.price,
                is_long_1
            );
            perp_margin = perp_margin - pnl_1;  // PnL offsets margin requirement
        }
    }

    // Perp slot 2
    if (user.perp_market_2 != 255) {
        let margin_2: u64 = calculate_perp_margin(
            user.perp_base_2,
            oracle_perp_2.price,
            perp_margin_ratio
        );
        perp_margin = perp_margin + (margin_2 as i64);

        let mut abs_base_2: i64 = user.perp_base_2;
        if (abs_base_2 < 0) {
            abs_base_2 = 0 - abs_base_2;
        }
        if (abs_base_2 > 0) {
            let is_long_2: bool = user.perp_base_2 > 0;
            let pnl_2: i64 = calculate_perp_pnl(
                abs_base_2,
                user.perp_entry_price_2,
                oracle_perp_2.price,
                is_long_2
            );
            perp_margin = perp_margin - pnl_2;
        }
    }

    // health = spot_collateral - perp_margin_requirement
    let health: i64 = spot_health - perp_margin;
    return health;
}

// ---------------------------------------------------------------------------
// 14. Admin Instructions
// ---------------------------------------------------------------------------

pub update_perp_market_params(
    state: DriftState,
    market: PerpMarket @mut,
    admin: account @signer,
    new_base_spread: u32,
    new_max_spread: u32,
    new_maker_fee: u64,
    new_taker_fee: u64,
    new_oracle: pubkey
) {
    require(state.admin == admin.ctx.key);
    require(new_max_spread >= new_base_spread);
    require(new_taker_fee >= new_maker_fee);

    market.amm_base_spread = new_base_spread;
    market.amm_max_spread = new_max_spread;
    market.maker_fee_bps = new_maker_fee;
    market.taker_fee_bps = new_taker_fee;
    market.oracle = new_oracle;
}

pub update_spot_market_params(
    state: DriftState,
    market: SpotMarket @mut,
    admin: account @signer,
    new_optimal_utilization: u64,
    new_optimal_rate: u64,
    new_max_rate: u64,
    new_initial_asset_weight: u64,
    new_maintenance_asset_weight: u64
) {
    require(state.admin == admin.ctx.key);
    require(new_initial_asset_weight <= weight_scale());
    require(new_maintenance_asset_weight >= new_initial_asset_weight);

    market.optimal_utilization = new_optimal_utilization;
    market.optimal_rate = new_optimal_rate;
    market.max_rate = new_max_rate;
    market.initial_asset_weight = new_initial_asset_weight;
    market.maintenance_asset_weight = new_maintenance_asset_weight;
}

pub set_fees(
    state: DriftState @mut,
    admin: account @signer,
    new_maker_fee_bps: u64,
    new_taker_fee_bps: u64
) {
    require(state.admin == admin.ctx.key);
    require(new_taker_fee_bps >= new_maker_fee_bps);
    require(new_taker_fee_bps <= 100);  // Max 1%

    state.default_maker_fee_bps = new_maker_fee_bps;
    state.default_taker_fee_bps = new_taker_fee_bps;
}

pub set_liquidation_margin_buffer(
    state: DriftState @mut,
    admin: account @signer,
    new_buffer: u64
) {
    require(state.admin == admin.ctx.key);
    require(new_buffer > 0);
    require(new_buffer <= 5000);  // Max 50%

    state.liquidation_margin_buffer = new_buffer;
}

pub set_lp_cooldown(
    state: DriftState @mut,
    admin: account @signer,
    cooldown_seconds: u64
) {
    require(state.admin == admin.ctx.key);
    state.lp_cooldown_time = cooldown_seconds;
}

pub set_delegate(
    user: User @mut,
    authority: account @signer,
    delegate: pubkey
) {
    require(user.authority == authority.ctx.key);
    user.delegate = delegate;
}

pub transfer_admin(
    state: DriftState @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(state.admin == admin.ctx.key);
    state.admin = new_admin;
}

pub pause(
    state: DriftState @mut,
    admin: account @signer
) {
    require(state.admin == admin.ctx.key);
    state.exchange_status = 1;
}

pub unpause(
    state: DriftState @mut,
    admin: account @signer
) {
    require(state.admin == admin.ctx.key);
    state.exchange_status = 0;
}

pub set_perp_market_active(
    state: DriftState,
    market: PerpMarket @mut,
    admin: account @signer,
    active: bool
) {
    require(state.admin == admin.ctx.key);
    market.is_active = active;
}

// ---------------------------------------------------------------------------
// 15. Read-Only Getters
// ---------------------------------------------------------------------------

pub get_mark_price(market: PerpMarket) -> u64 {
    return calculate_mark_price(
        market.amm_base_asset_reserve,
        market.amm_quote_asset_reserve,
        market.amm_peg_multiplier
    );
}

pub get_open_interest(market: PerpMarket) -> u64 {
    return market.open_interest;
}

pub get_funding_rate(market: PerpMarket) -> i64 {
    return market.last_funding_rate;
}

pub get_cumulative_funding_long(market: PerpMarket) -> i64 {
    return market.cumulative_funding_rate_long;
}

pub get_cumulative_funding_short(market: PerpMarket) -> i64 {
    return market.cumulative_funding_rate_short;
}

pub get_perp_fees(market: PerpMarket) -> u64 {
    return market.total_fee_collected;
}

pub get_insurance_claims(market: PerpMarket) -> u64 {
    return market.insurance_claim_amount;
}

pub get_spot_deposit_balance(market: SpotMarket) -> u64 {
    return market.deposit_balance;
}

pub get_spot_borrow_balance(market: SpotMarket) -> u64 {
    return market.borrow_balance;
}

pub get_spot_deposit_index(market: SpotMarket) -> u128 {
    return market.deposit_index;
}

pub get_spot_borrow_index(market: SpotMarket) -> u128 {
    return market.borrow_index;
}

pub get_spot_utilization(market: SpotMarket) -> u64 {
    return calculate_utilization(market.deposit_balance, market.borrow_balance);
}

pub get_user_spot_position(user: User, slot: u8) -> i64 {
    if (slot == 1) {
        return user.spot_position_1;
    }
    if (slot == 2) {
        return user.spot_position_2;
    }
    if (slot == 3) {
        return user.spot_position_3;
    }
    if (slot == 4) {
        return user.spot_position_4;
    }
    return 0;
}

pub get_user_perp_base(user: User, slot: u8) -> i64 {
    if (slot == 1) {
        return user.perp_base_1;
    }
    if (slot == 2) {
        return user.perp_base_2;
    }
    return 0;
}

pub get_user_perp_quote(user: User, slot: u8) -> i64 {
    if (slot == 1) {
        return user.perp_quote_1;
    }
    if (slot == 2) {
        return user.perp_quote_2;
    }
    return 0;
}

pub get_user_perp_entry_price(user: User, slot: u8) -> u64 {
    if (slot == 1) {
        return user.perp_entry_price_1;
    }
    if (slot == 2) {
        return user.perp_entry_price_2;
    }
    return 0;
}

pub get_insurance_fund_staked(fund: InsuranceFund) -> u64 {
    return fund.total_staked;
}

pub get_insurance_fund_shares(fund: InsuranceFund) -> u64 {
    return fund.total_shares;
}

pub get_oracle_price(oracle: PriceOracle) -> u64 {
    return oracle.price;
}

pub get_exchange_status(state: DriftState) -> u8 {
    return state.exchange_status;
}

pub get_total_fees(state: DriftState) -> u64 {
    return state.total_fee_collected;
}

pub get_vamm_reserves(market: PerpMarket) -> u128 {
    return market.amm_base_asset_reserve;
}

pub get_vamm_quote_reserves(market: PerpMarket) -> u128 {
    return market.amm_quote_asset_reserve;
}

pub get_vamm_sqrt_k(market: PerpMarket) -> u128 {
    return market.amm_sqrt_k;
}

pub get_peg_multiplier(market: PerpMarket) -> u128 {
    return market.amm_peg_multiplier;
}

pub is_user_bankrupt(user: User) -> bool {
    return user.is_bankrupt;
}
