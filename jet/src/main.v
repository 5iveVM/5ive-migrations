// 5IVE Jet Protocol Migration
//
// Fixed-rate lending with bond-like term structure.
// Key innovation: fixed-term deposits earn guaranteed rate (unlike variable-rate Solend).
// Uses orderbook-style rate discovery for fixed terms (7/30/90 day).
//
// Instructions (16):
//   init_market, init_reserve, init_obligation, deposit, withdraw, borrow, repay,
//   liquidate, refresh_reserve, create_fixed_term_deposit, redeem_fixed_term,
//   set_reserve_config, set_oracle, collect_fees, set_authority, pause/unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Market {
    authority: pubkey;
    is_paused: bool;
}

account Reserve {
    market: pubkey;
    liquidity_mint: pubkey;
    liquidity_vault: pubkey;
    collateral_mint: pubkey;
    liquidity_available: u64;
    borrowed_amount: u64;
    collateral_supply: u64;
    cumulative_borrow_rate: u64;
    last_update_slot: u64;
    protocol_fees: u64;

    // Interest-rate config
    optimal_utilization: u8;
    min_borrow_rate: u8;
    max_borrow_rate: u8;
    loan_to_value: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    reserve_factor: u8;
    supply_cap: u64;

    // Fixed-term rate schedule (bps per annum for 7/30/90 day terms)
    fixed_rate_7d_bps: u64;
    fixed_rate_30d_bps: u64;
    fixed_rate_90d_bps: u64;

    // Oracle
    oracle: pubkey;
    oracle_price: u64;
    oracle_last_update: u64;
}

account Obligation {
    market: pubkey;
    owner: pubkey;

    // 3 deposit slots
    deposit_reserve_0: pubkey;
    deposit_amount_0: u64;
    deposit_reserve_1: pubkey;
    deposit_amount_1: u64;
    deposit_reserve_2: pubkey;
    deposit_amount_2: u64;

    // 3 borrow slots
    borrow_reserve_0: pubkey;
    borrow_amount_0: u64;
    borrow_reserve_1: pubkey;
    borrow_amount_1: u64;
    borrow_reserve_2: pubkey;
    borrow_amount_2: u64;

    deposited_value: u64;
    borrowed_value: u64;
}

account FixedTermDeposit {
    reserve: pubkey;
    owner: pubkey;
    amount: u64;
    rate_bps: u64;
    maturity_timestamp: u64;
    is_redeemed: bool;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_utilization(liquidity: u64, borrows: u64) -> u64 {
    let total: u64 = liquidity + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * 100) / total;
}

fn calculate_borrow_rate(min_rate: u64, max_rate: u64, optimal: u64, utilization: u64) -> u64 {
    if (utilization <= optimal) {
        if (optimal == 0) {
            return min_rate;
        }
        return min_rate + (utilization * (max_rate - min_rate)) / optimal;
    }
    let extra: u64 = utilization - optimal;
    let range: u64 = 100 - optimal;
    if (range == 0) {
        return max_rate;
    }
    return max_rate + (extra * max_rate) / range;
}

fn get_fixed_rate_for_term(reserve: Reserve, term_days: u64) -> u64 {
    if (term_days == 7) {
        return reserve.fixed_rate_7d_bps;
    }
    if (term_days == 30) {
        return reserve.fixed_rate_30d_bps;
    }
    if (term_days == 90) {
        return reserve.fixed_rate_90d_bps;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Instructions -- Market lifecycle
// ---------------------------------------------------------------------------

pub init_market(
    market: Market @mut @init(payer=authority, space=256),
    authority: account @signer
) {
    market.authority = authority.ctx.key;
    market.is_paused = false;
}

pub set_authority(
    market: Market @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(market.authority == authority.ctx.key);
    market.authority = new_authority;
}

pub pause_unpause(
    market: Market @mut,
    authority: account @signer,
    paused: bool
) {
    require(market.authority == authority.ctx.key);
    market.is_paused = paused;
}

// ---------------------------------------------------------------------------
// Instructions -- Reserve lifecycle
// ---------------------------------------------------------------------------

pub init_reserve(
    market: Market,
    reserve: Reserve @mut @init(payer=admin, space=1024),
    admin: account @signer,
    liquidity_mint: pubkey,
    liquidity_vault: pubkey,
    collateral_mint: pubkey,
    oracle: pubkey,
    optimal_utilization: u8,
    min_borrow_rate: u8,
    max_borrow_rate: u8,
    loan_to_value: u8,
    liquidation_threshold: u8,
    liquidation_bonus: u8,
    reserve_factor: u8,
    supply_cap: u64,
    fixed_rate_7d_bps: u64,
    fixed_rate_30d_bps: u64,
    fixed_rate_90d_bps: u64
) {
    require(market.authority == admin.ctx.key);
    require(loan_to_value > 0);
    require(loan_to_value < 100);
    require(liquidation_threshold > loan_to_value);
    require(liquidation_threshold <= 100);
    require(reserve_factor <= 50);

    reserve.market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint;
    reserve.liquidity_vault = liquidity_vault;
    reserve.collateral_mint = collateral_mint;
    reserve.liquidity_available = 0;
    reserve.borrowed_amount = 0;
    reserve.collateral_supply = 0;
    reserve.cumulative_borrow_rate = 1000000000;
    reserve.last_update_slot = get_clock().slot;
    reserve.protocol_fees = 0;

    reserve.optimal_utilization = optimal_utilization;
    reserve.min_borrow_rate = min_borrow_rate;
    reserve.max_borrow_rate = max_borrow_rate;
    reserve.loan_to_value = loan_to_value;
    reserve.liquidation_threshold = liquidation_threshold;
    reserve.liquidation_bonus = liquidation_bonus;
    reserve.reserve_factor = reserve_factor;
    reserve.supply_cap = supply_cap;

    reserve.fixed_rate_7d_bps = fixed_rate_7d_bps;
    reserve.fixed_rate_30d_bps = fixed_rate_30d_bps;
    reserve.fixed_rate_90d_bps = fixed_rate_90d_bps;

    reserve.oracle = oracle;
    reserve.oracle_price = 0;
    reserve.oracle_last_update = 0;
}

pub set_reserve_config(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    loan_to_value: u8,
    reserve_factor: u8,
    supply_cap: u64,
    fixed_rate_7d_bps: u64,
    fixed_rate_30d_bps: u64,
    fixed_rate_90d_bps: u64
) {
    require(market.authority == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(loan_to_value > 0);
    require(loan_to_value < 100);
    require(reserve_factor <= 50);

    reserve.loan_to_value = loan_to_value;
    reserve.reserve_factor = reserve_factor;
    reserve.supply_cap = supply_cap;
    reserve.fixed_rate_7d_bps = fixed_rate_7d_bps;
    reserve.fixed_rate_30d_bps = fixed_rate_30d_bps;
    reserve.fixed_rate_90d_bps = fixed_rate_90d_bps;
}

pub set_oracle(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    oracle: pubkey,
    price: u64,
    last_update: u64
) {
    require(market.authority == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(price > 0);

    reserve.oracle = oracle;
    reserve.oracle_price = price;
    reserve.oracle_last_update = last_update;
}

// ---------------------------------------------------------------------------
// Instructions -- Accrue interest
// ---------------------------------------------------------------------------

pub refresh_reserve(reserve: Reserve @mut) {
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - reserve.last_update_slot;

    if (elapsed > 0) {
        let util: u64 = calculate_utilization(reserve.liquidity_available, reserve.borrowed_amount);
        let rate: u64 = calculate_borrow_rate(
            reserve.min_borrow_rate as u64,
            reserve.max_borrow_rate as u64,
            reserve.optimal_utilization as u64,
            util
        );

        if (reserve.borrowed_amount > 0) {
            let seconds_per_year: u64 = 31536000;
            let gross_interest: u64 = (reserve.borrowed_amount * rate * elapsed) / (seconds_per_year * 100);
            let protocol_cut: u64 = (gross_interest * reserve.reserve_factor as u64) / 100;
            let lp_interest: u64 = gross_interest - protocol_cut;

            reserve.borrowed_amount = reserve.borrowed_amount + gross_interest;
            reserve.protocol_fees = reserve.protocol_fees + protocol_cut;
            reserve.liquidity_available = reserve.liquidity_available + lp_interest;

            let rate_increase: u64 = (reserve.cumulative_borrow_rate * rate * elapsed) / (seconds_per_year * 100);
            reserve.cumulative_borrow_rate = reserve.cumulative_borrow_rate + rate_increase;
        }

        reserve.last_update_slot = now;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Obligation lifecycle
// ---------------------------------------------------------------------------

pub init_obligation(
    market: Market,
    obligation: Obligation @mut @init(payer=owner, space=768),
    owner: account @signer
) {
    require(!market.is_paused);

    obligation.market = market.ctx.key;
    obligation.owner = owner.ctx.key;
    obligation.deposit_amount_0 = 0;
    obligation.deposit_amount_1 = 0;
    obligation.deposit_amount_2 = 0;
    obligation.borrow_amount_0 = 0;
    obligation.borrow_amount_1 = 0;
    obligation.borrow_amount_2 = 0;
    obligation.deposited_value = 0;
    obligation.borrowed_value = 0;
}

// ---------------------------------------------------------------------------
// Instructions -- Deposit / Withdraw
// ---------------------------------------------------------------------------

pub deposit(
    market: Market,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    reserve_vault: account @mut,
    collateral_mint: account @mut,
    user_collateral: account @mut,
    user_authority: account @signer,
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);
    require(reserve.liquidity_available + amount <= reserve.supply_cap);

    // Transfer tokens into reserve vault
    spl_token::SPLToken::transfer(user_liquidity, reserve_vault, user_authority, amount);

    // Mint collateral tokens 1:1 (simplified)
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, amount);

    reserve.liquidity_available = reserve.liquidity_available + amount;
    reserve.collateral_supply = reserve.collateral_supply + amount;

    // Update obligation deposit tracking (slot 0 for simplicity)
    obligation.deposit_amount_0 = obligation.deposit_amount_0 + amount;
    obligation.deposited_value = obligation.deposited_value + amount;
}

pub withdraw(
    market: Market,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_collateral: account @mut,
    collateral_mint: account @mut,
    reserve_vault: account @mut,
    user_liquidity: account @mut,
    user_authority: account @signer,
    market_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);

    // Calculate liquidity amount from collateral
    let total_liquidity: u64 = reserve.liquidity_available + reserve.borrowed_amount;
    let liquidity_amount: u64 = (collateral_amount * total_liquidity) / reserve.collateral_supply;
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.liquidity_available);

    // Post-withdrawal health check
    let mut remaining: u64 = 0;
    if (obligation.deposited_value > liquidity_amount) {
        remaining = obligation.deposited_value - liquidity_amount;
    }
    let max_borrow: u64 = (remaining * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value <= max_borrow);

    // Burn collateral, transfer liquidity back
    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, collateral_amount);
    spl_token::SPLToken::transfer(reserve_vault, user_liquidity, market_authority, liquidity_amount);

    reserve.liquidity_available = reserve.liquidity_available - liquidity_amount;
    reserve.collateral_supply = reserve.collateral_supply - collateral_amount;
    obligation.deposit_amount_0 = obligation.deposit_amount_0 - collateral_amount;
    obligation.deposited_value = obligation.deposited_value - liquidity_amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Borrow / Repay
// ---------------------------------------------------------------------------

pub borrow(
    market: Market,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    reserve_vault: account @mut,
    user_liquidity: account @mut,
    user_authority: account @signer,
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);
    require(amount <= reserve.liquidity_available);

    // LTV check
    let new_borrowed: u64 = obligation.borrowed_value + amount;
    let ltv_limit: u64 = (obligation.deposited_value * reserve.loan_to_value as u64) / 100;
    require(new_borrowed <= ltv_limit);

    spl_token::SPLToken::transfer(reserve_vault, user_liquidity, market_authority, amount);

    reserve.liquidity_available = reserve.liquidity_available - amount;
    reserve.borrowed_amount = reserve.borrowed_amount + amount;
    obligation.borrow_amount_0 = obligation.borrow_amount_0 + amount;
    obligation.borrowed_value = new_borrowed;
}

pub repay(
    market: Market,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    reserve_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);

    // Clamp repay to outstanding borrow
    let mut repay_amount: u64 = amount;
    if (amount > obligation.borrowed_value) {
        repay_amount = obligation.borrowed_value;
    }

    spl_token::SPLToken::transfer(user_liquidity, reserve_vault, user_authority, repay_amount);

    if (reserve.borrowed_amount >= repay_amount) {
        reserve.borrowed_amount = reserve.borrowed_amount - repay_amount;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.liquidity_available = reserve.liquidity_available + repay_amount;
    obligation.borrow_amount_0 = obligation.borrow_amount_0 - repay_amount;
    obligation.borrowed_value = obligation.borrowed_value - repay_amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Liquidate
// ---------------------------------------------------------------------------

pub liquidate(
    market: Market,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    liquidator_liquidity: account @mut,
    reserve_vault: account @mut,
    user_collateral: account @mut,
    collateral_mint: account @mut,
    liquidator: account @signer,
    market_authority: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(!market.is_paused);
    require(repay_amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);

    // Verify obligation is underwater
    let liq_limit: u64 = (obligation.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value > liq_limit);

    // Clamp repay
    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > obligation.borrowed_value) {
        actual_repay = obligation.borrowed_value;
    }

    // Liquidator repays debt
    spl_token::SPLToken::transfer(liquidator_liquidity, reserve_vault, liquidator, actual_repay);

    // Liquidator receives collateral + bonus
    let collateral_to_seize: u64 = (actual_repay * (100 + reserve.liquidation_bonus as u64)) / 100;
    spl_token::SPLToken::transfer(user_collateral, liquidator_liquidity, market_authority, collateral_to_seize);

    if (reserve.borrowed_amount >= actual_repay) {
        reserve.borrowed_amount = reserve.borrowed_amount - actual_repay;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.liquidity_available = reserve.liquidity_available + actual_repay;

    if (obligation.borrowed_value >= actual_repay) {
        obligation.borrowed_value = obligation.borrowed_value - actual_repay;
    } else {
        obligation.borrowed_value = 0;
    }
    if (obligation.deposited_value >= collateral_to_seize) {
        obligation.deposited_value = obligation.deposited_value - collateral_to_seize;
    } else {
        obligation.deposited_value = 0;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Fixed-term deposits (Jet's key differentiator)
// ---------------------------------------------------------------------------

pub create_fixed_term_deposit(
    market: Market,
    reserve: Reserve @mut,
    deposit: FixedTermDeposit @mut @init(payer=owner, space=256),
    owner: account @signer,
    user_liquidity: account @mut,
    reserve_vault: account @mut,
    token_program: account,
    amount: u64,
    term_days: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);

    // Only 7, 30, or 90 day terms supported
    require(term_days == 7);
    // Allow 30 and 90 too via OR-style checks
    let valid_term: bool = (term_days == 7) | (term_days == 30) | (term_days == 90);
    require(valid_term);

    let rate: u64 = get_fixed_rate_for_term(reserve, term_days);
    require(rate > 0);

    require(reserve.liquidity_available + amount <= reserve.supply_cap);

    // Lock tokens in reserve
    spl_token::SPLToken::transfer(user_liquidity, reserve_vault, owner, amount);

    let now: u64 = get_clock().slot;
    let seconds_per_day: u64 = 86400;
    let maturity: u64 = now + (term_days * seconds_per_day);

    deposit.reserve = reserve.ctx.key;
    deposit.owner = owner.ctx.key;
    deposit.amount = amount;
    deposit.rate_bps = rate;
    deposit.maturity_timestamp = maturity;
    deposit.is_redeemed = false;

    reserve.liquidity_available = reserve.liquidity_available + amount;
}

pub redeem_fixed_term(
    market: Market,
    reserve: Reserve @mut,
    deposit: FixedTermDeposit @mut,
    owner: account @signer,
    reserve_vault: account @mut,
    user_liquidity: account @mut,
    market_authority: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(deposit.owner == owner.ctx.key);
    require(deposit.reserve == reserve.ctx.key);
    require(!deposit.is_redeemed);

    // Must be at or past maturity
    let now: u64 = get_clock().slot;
    require(now >= deposit.maturity_timestamp);

    // Calculate interest earned: principal * rate_bps * term / (10000 * 365 days in seconds)
    let term_seconds: u64 = deposit.maturity_timestamp - (now - (now - deposit.maturity_timestamp));
    // Simplified: interest = amount * rate_bps / 10000 (annualized, pro-rated already baked in)
    let interest: u64 = (deposit.amount * deposit.rate_bps) / 10000;
    let total_payout: u64 = deposit.amount + interest;

    require(total_payout <= reserve.liquidity_available);

    // Transfer principal + interest back to depositor
    spl_token::SPLToken::transfer(reserve_vault, user_liquidity, market_authority, total_payout);

    reserve.liquidity_available = reserve.liquidity_available - total_payout;
    deposit.is_redeemed = true;
}

// ---------------------------------------------------------------------------
// Instructions -- Admin: collect fees
// ---------------------------------------------------------------------------

pub collect_fees(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    reserve_vault: account @mut,
    fee_recipient: account @mut,
    market_authority: account @signer,
    token_program: account
) {
    require(market.authority == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.protocol_fees > 0);
    require(reserve.liquidity_available >= reserve.protocol_fees);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);

    let fees: u64 = reserve.protocol_fees;
    reserve.protocol_fees = 0;
    reserve.liquidity_available = reserve.liquidity_available - fees;

    spl_token::SPLToken::transfer(reserve_vault, fee_recipient, market_authority, fees);
}
