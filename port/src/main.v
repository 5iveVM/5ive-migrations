// 5IVE Port Finance Migration
//
// Variable-rate lending (Aave-style) with PORT staking incentives.
// Key difference from Solend: flash loans + PORT token mining rewards for borrowers/lenders.
// Two-slope interest rate model with kink at optimal utilization.
//
// Instructions (18):
//   init_market, init_reserve, deposit_reserve, redeem_collateral, init_obligation,
//   deposit_collateral, withdraw_collateral, borrow, repay, liquidate, flash_loan,
//   refresh_reserve, refresh_obligation, claim_port_reward, set_reserve_config,
//   set_oracle, collect_fees, set_authority

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

    // Two-slope interest rate config
    optimal_utilization: u8;
    base_rate_bps: u64;
    slope_1_bps: u64;
    slope_2_bps: u64;
    loan_to_value: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    reserve_factor: u8;
    supply_cap: u64;

    // PORT mining incentive rate (tokens per slot per unit borrowed)
    port_mining_rate: u64;

    // Flash loan fee in bps
    flash_loan_fee_bps: u64;
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

    // PORT reward tracking
    pending_port_reward: u64;
    last_reward_slot: u64;
}

account OraclePrice {
    authority: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_utilization(liquidity: u64, borrows: u64) -> u64 {
    let total: u64 = liquidity + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * 10000) / total;
}

// Two-slope interest rate: below kink use slope_1, above kink use slope_2
fn calculate_two_slope_rate(
    base_bps: u64,
    slope_1: u64,
    slope_2: u64,
    optimal_bps: u64,
    utilization_bps: u64
) -> u64 {
    if (utilization_bps <= optimal_bps) {
        if (optimal_bps == 0) {
            return base_bps;
        }
        return base_bps + (utilization_bps * slope_1) / optimal_bps;
    }
    let base_at_kink: u64 = base_bps + slope_1;
    let excess: u64 = utilization_bps - optimal_bps;
    let remaining: u64 = 10000 - optimal_bps;
    if (remaining == 0) {
        return base_at_kink;
    }
    return base_at_kink + (excess * slope_2) / remaining;
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
    optimal_utilization: u8,
    base_rate_bps: u64,
    slope_1_bps: u64,
    slope_2_bps: u64,
    loan_to_value: u8,
    liquidation_threshold: u8,
    liquidation_bonus: u8,
    reserve_factor: u8,
    supply_cap: u64,
    port_mining_rate: u64,
    flash_loan_fee_bps: u64
) {
    require(market.authority == admin.ctx.key);
    require(loan_to_value > 0);
    require(loan_to_value < 100);
    require(liquidation_threshold > loan_to_value);
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
    reserve.base_rate_bps = base_rate_bps;
    reserve.slope_1_bps = slope_1_bps;
    reserve.slope_2_bps = slope_2_bps;
    reserve.loan_to_value = loan_to_value;
    reserve.liquidation_threshold = liquidation_threshold;
    reserve.liquidation_bonus = liquidation_bonus;
    reserve.reserve_factor = reserve_factor;
    reserve.supply_cap = supply_cap;
    reserve.port_mining_rate = port_mining_rate;
    reserve.flash_loan_fee_bps = flash_loan_fee_bps;
}

pub set_reserve_config(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    loan_to_value: u8,
    reserve_factor: u8,
    supply_cap: u64,
    port_mining_rate: u64,
    flash_loan_fee_bps: u64
) {
    require(market.authority == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(loan_to_value > 0);
    require(loan_to_value < 100);
    require(reserve_factor <= 50);

    reserve.loan_to_value = loan_to_value;
    reserve.reserve_factor = reserve_factor;
    reserve.supply_cap = supply_cap;
    reserve.port_mining_rate = port_mining_rate;
    reserve.flash_loan_fee_bps = flash_loan_fee_bps;
}

pub set_oracle(
    oracle: OraclePrice @mut,
    authority: account @signer,
    price: u64,
    decimals: u8
) {
    require(oracle.authority == authority.ctx.key);
    require(price > 0);
    oracle.price = price;
    oracle.decimals = decimals;
    oracle.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// Instructions -- Refresh (accrue interest)
// ---------------------------------------------------------------------------

pub refresh_reserve(reserve: Reserve @mut) {
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - reserve.last_update_slot;

    if (elapsed > 0) {
        let util_bps: u64 = calculate_utilization(reserve.liquidity_available, reserve.borrowed_amount);
        let rate_bps: u64 = calculate_two_slope_rate(
            reserve.base_rate_bps,
            reserve.slope_1_bps,
            reserve.slope_2_bps,
            reserve.optimal_utilization as u64 * 100,
            util_bps
        );

        if (reserve.borrowed_amount > 0) {
            let seconds_per_year: u64 = 31536000;
            let gross_interest: u64 = (reserve.borrowed_amount * rate_bps * elapsed) / (seconds_per_year * 10000);
            let protocol_cut: u64 = (gross_interest * reserve.reserve_factor as u64) / 100;
            let lp_interest: u64 = gross_interest - protocol_cut;

            reserve.borrowed_amount = reserve.borrowed_amount + gross_interest;
            reserve.protocol_fees = reserve.protocol_fees + protocol_cut;
            reserve.liquidity_available = reserve.liquidity_available + lp_interest;

            let rate_inc: u64 = (reserve.cumulative_borrow_rate * rate_bps * elapsed) / (seconds_per_year * 10000);
            reserve.cumulative_borrow_rate = reserve.cumulative_borrow_rate + rate_inc;
        }

        reserve.last_update_slot = now;
    }
}

pub refresh_obligation(
    market: Market,
    obligation: Obligation @mut,
    reserve: Reserve,
    oracle: OraclePrice
) {
    require(!market.is_paused);
    require(obligation.market == market.ctx.key);
    require(reserve.market == market.ctx.key);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    obligation.deposited_value = oracle.price;
    let ltv: u64 = reserve.loan_to_value as u64;
    obligation.deposited_value = obligation.deposit_amount_0;
}

// ---------------------------------------------------------------------------
// Instructions -- Deposit / Redeem collateral
// ---------------------------------------------------------------------------

pub deposit_reserve(
    market: Market,
    reserve: Reserve @mut,
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
    require(reserve_vault.ctx.key == reserve.liquidity_vault);
    require(reserve.liquidity_available + amount <= reserve.supply_cap);

    spl_token::SPLToken::transfer(user_liquidity, reserve_vault, user_authority, amount);
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, amount);

    reserve.liquidity_available = reserve.liquidity_available + amount;
    reserve.collateral_supply = reserve.collateral_supply + amount;
}

pub redeem_collateral(
    market: Market,
    reserve: Reserve @mut,
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
    require(reserve_vault.ctx.key == reserve.liquidity_vault);

    let total_liq: u64 = reserve.liquidity_available + reserve.borrowed_amount;
    let liq_amount: u64 = (collateral_amount * total_liq) / reserve.collateral_supply;
    require(liq_amount > 0);
    require(liq_amount <= reserve.liquidity_available);

    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, collateral_amount);
    spl_token::SPLToken::transfer(reserve_vault, user_liquidity, market_authority, liq_amount);

    reserve.liquidity_available = reserve.liquidity_available - liq_amount;
    reserve.collateral_supply = reserve.collateral_supply - collateral_amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Obligation deposit / withdraw collateral
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
    obligation.pending_port_reward = 0;
    obligation.last_reward_slot = get_clock().slot;
}

pub deposit_collateral(
    market: Market,
    reserve: Reserve,
    obligation: Obligation @mut,
    user_collateral: account @mut,
    obligation_collateral: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(obligation.owner == user_authority.ctx.key);
    require(obligation.market == market.ctx.key);
    require(reserve.market == market.ctx.key);

    spl_token::SPLToken::transfer(user_collateral, obligation_collateral, user_authority, amount);

    obligation.deposit_amount_0 = obligation.deposit_amount_0 + amount;
    obligation.deposited_value = obligation.deposited_value + amount;
}

pub withdraw_collateral(
    market: Market,
    reserve: Reserve,
    obligation: Obligation @mut,
    obligation_collateral: account @mut,
    user_collateral: account @mut,
    user_authority: account @signer,
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(obligation.owner == user_authority.ctx.key);
    require(obligation.market == market.ctx.key);

    require(amount <= obligation.deposit_amount_0);

    // Health check after withdrawal
    let remaining: u64 = obligation.deposited_value - amount;
    let max_borrow: u64 = (remaining * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value <= max_borrow);

    spl_token::SPLToken::transfer(obligation_collateral, user_collateral, market_authority, amount);

    obligation.deposit_amount_0 = obligation.deposit_amount_0 - amount;
    obligation.deposited_value = obligation.deposited_value - amount;
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
    require(obligation.owner == user_authority.ctx.key);
    require(obligation.market == market.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);
    require(amount <= reserve.liquidity_available);

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
    require(obligation.market == market.ctx.key);

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
    borrower_collateral: account @mut,
    liquidator: account @signer,
    market_authority: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(!market.is_paused);
    require(repay_amount > 0);
    require(reserve.market == market.ctx.key);
    require(obligation.market == market.ctx.key);

    let liq_limit: u64 = (obligation.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value > liq_limit);

    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > obligation.borrowed_value) {
        actual_repay = obligation.borrowed_value;
    }

    spl_token::SPLToken::transfer(liquidator_liquidity, reserve_vault, liquidator, actual_repay);

    let collateral_seized: u64 = (actual_repay * (100 + reserve.liquidation_bonus as u64)) / 100;
    spl_token::SPLToken::transfer(borrower_collateral, liquidator_liquidity, market_authority, collateral_seized);

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
    if (obligation.deposited_value >= collateral_seized) {
        obligation.deposited_value = obligation.deposited_value - collateral_seized;
    } else {
        obligation.deposited_value = 0;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Flash loan (Port's key feature)
// ---------------------------------------------------------------------------

pub flash_loan(
    market: Market,
    reserve: Reserve @mut,
    reserve_vault: account @mut,
    borrower_account: account @mut,
    borrower: account @signer,
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve_vault.ctx.key == reserve.liquidity_vault);
    require(amount <= reserve.liquidity_available);

    // Calculate fee
    let fee: u64 = (amount * reserve.flash_loan_fee_bps) / 10000;
    require(fee > 0);
    let repay_amount: u64 = amount + fee;

    // Lend out the tokens
    spl_token::SPLToken::transfer(reserve_vault, borrower_account, market_authority, amount);

    // Borrower must repay in same tx (atomic) -- we immediately pull back principal + fee
    spl_token::SPLToken::transfer(borrower_account, reserve_vault, borrower, repay_amount);

    // Fee split: protocol takes reserve_factor %, LPs get the rest
    let protocol_fee: u64 = (fee * reserve.reserve_factor as u64) / 100;
    reserve.protocol_fees = reserve.protocol_fees + protocol_fee;
    reserve.liquidity_available = reserve.liquidity_available + (fee - protocol_fee);
}

// ---------------------------------------------------------------------------
// Instructions -- PORT mining reward
// ---------------------------------------------------------------------------

pub claim_port_reward(
    market: Market,
    reserve: Reserve,
    obligation: Obligation @mut,
    port_reward_vault: account @mut,
    user_port_account: account @mut,
    user_authority: account @signer,
    market_authority: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(obligation.owner == user_authority.ctx.key);
    require(obligation.market == market.ctx.key);
    require(reserve.market == market.ctx.key);

    // Accrue pending rewards
    let now: u64 = get_clock().slot;
    let slots_elapsed: u64 = now - obligation.last_reward_slot;

    // Reward = borrow_amount * mining_rate * slots_elapsed / 1_000_000_000
    let new_reward: u64 = (obligation.borrow_amount_0 * reserve.port_mining_rate * slots_elapsed) / 1000000000;
    let total_reward: u64 = obligation.pending_port_reward + new_reward;

    require(total_reward > 0);

    spl_token::SPLToken::transfer(port_reward_vault, user_port_account, market_authority, total_reward);

    obligation.pending_port_reward = 0;
    obligation.last_reward_slot = now;
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
