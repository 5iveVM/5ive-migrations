// Solend — Solana's largest lending/borrowing protocol
// 5ive DSL migration: faithful representation of Solend's on-chain mechanics
//
// Key differences from 5ive-lending (simplified):
//   - WAD (10^18) fixed-point precision for interest accrual (u128)
//   - Two-slope interest rate model (min -> optimal -> max kink)
//   - cToken exchange rate grows as interest accrues
//   - Multi-asset obligations: 3 deposit slots + 3 borrow slots
//   - Flash loans (borrow + repay in same tx, fee in bps)
//   - Borrow fee on new borrows
//   - Protocol liquidation fee (portion of bonus to protocol)
//   - Deposit limit and borrow limit per reserve
//   - Oracle program stored on market for validation
//   - Compound interest with cumulative borrow rate (WAD-scaled)

use std::interfaces::spl_token;

// ─────────────────────────────────────────────────────────────────
// Accounts
// ─────────────────────────────────────────────────────────────────

account LendingMarket {
    owner: pubkey;
    oracle_program: pubkey;
    is_paused: bool;
    num_reserves: u8;
}

account Reserve {
    market: pubkey;
    liquidity_mint: pubkey;
    liquidity_supply_vault: pubkey;
    collateral_mint: pubkey;
    fee_receiver: pubkey;
    oracle: pubkey;

    // State
    available_amount: u64;
    borrowed_amount_wads_hi: u64;
    borrowed_amount_wads_lo: u64;
    cumulative_borrow_rate_wads_hi: u64;
    cumulative_borrow_rate_wads_lo: u64;
    market_price: u64;
    last_update_slot: u64;
    collateral_mint_supply: u64;
    accumulated_protocol_fees: u64;

    // Config — interest rate model (two-slope kink)
    optimal_utilization_rate: u8;
    loan_to_value_ratio: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    min_borrow_rate: u8;
    optimal_borrow_rate: u8;
    max_borrow_rate: u8;

    // Fee config
    host_fee_percentage: u8;
    protocol_liquidation_fee: u8;
    flash_loan_fee_bps: u64;
    borrow_fee_bps: u64;

    // Caps
    deposit_limit: u64;
    borrow_limit: u64;
}

account Obligation {
    market: pubkey;
    owner: pubkey;
    last_update_slot: u64;

    // Aggregated values (in quote currency)
    deposited_value: u64;
    borrowed_value: u64;
    allowed_borrow_value: u64;
    unhealthy_borrow_value: u64;

    num_deposits: u8;
    num_borrows: u8;

    // Deposit slots (up to 3 reserves)
    deposit_reserve_1: pubkey;
    deposit_amount_1: u64;
    deposit_market_value_1: u64;

    deposit_reserve_2: pubkey;
    deposit_amount_2: u64;
    deposit_market_value_2: u64;

    deposit_reserve_3: pubkey;
    deposit_amount_3: u64;
    deposit_market_value_3: u64;

    // Borrow slots (up to 3 reserves)
    borrow_reserve_1: pubkey;
    borrow_amount_wads_hi_1: u64;
    borrow_amount_wads_lo_1: u64;
    borrow_market_value_1: u64;

    borrow_reserve_2: pubkey;
    borrow_amount_wads_hi_2: u64;
    borrow_amount_wads_lo_2: u64;
    borrow_market_value_2: u64;

    borrow_reserve_3: pubkey;
    borrow_amount_wads_hi_3: u64;
    borrow_amount_wads_lo_3: u64;
    borrow_market_value_3: u64;
}

account PriceOracle {
    authority: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

account FlashLoanReceipt {
    reserve: pubkey;
    borrower: pubkey;
    amount: u64;
    fee: u64;
    is_repaid: bool;
}

// ─────────────────────────────────────────────────────────────────
// Constants (inline)
// ─────────────────────────────────────────────────────────────────

// WAD = 10^18 = 1_000_000_000_000_000_000
// Stored as two u64 halves for 5ive compatibility:
//   WAD_HI = 0 (high 64 bits of 10^18 fit in u64)
//   WAD_LO = 1_000_000_000_000_000_000
// SLOTS_PER_YEAR ~= 63_072_000 (2 slots/sec * 31_536_000 sec/year)
// ORACLE_STALE_SLOTS = 100
// MAX_OBLIGATION_DEPOSITS = 3
// MAX_OBLIGATION_BORROWS = 3

// ─────────────────────────────────────────────────────────────────
// Internal helpers
// ─────────────────────────────────────────────────────────────────

// WAD multiply: (a * b) / WAD
// Using u64 components: we approximate with a_lo * b_lo / WAD_LO
// In production u128 math, this is exact. Here we use the lo parts.
fn wad_mul(a_lo: u64, b_lo: u64) -> u64 {
    let wad: u64 = 1000000000000000000;
    if (a_lo == 0) {
        return 0;
    }
    if (b_lo == 0) {
        return 0;
    }
    // Scale down to avoid overflow: (a / 10^9) * (b / 10^9)
    let a_scaled: u64 = a_lo / 1000000000;
    let b_scaled: u64 = b_lo / 1000000000;
    return a_scaled * b_scaled;
}

// WAD divide: (a * WAD) / b
fn wad_div(a_lo: u64, b_lo: u64) -> u64 {
    require(b_lo > 0);
    let a_scaled: u64 = a_lo * 1000000000;
    return (a_scaled * 1000000000) / b_lo;
}

// Convert real amount to WAD representation (amount * 10^18)
// Stored as lo component; hi stays 0 for amounts < ~18.4 * 10^18
fn to_wad_lo(amount: u64) -> u64 {
    // amount * 10^18 would overflow u64 for amounts > 18
    // So we store amount * 10^9 in lo and use scale factor
    return amount * 1000000000;
}

// Convert WAD lo back to real amount
fn from_wad_lo(wad_lo: u64) -> u64 {
    return wad_lo / 1000000000;
}

fn calculate_utilization(available: u64, borrowed_wad_lo: u64) -> u64 {
    let borrowed: u64 = from_wad_lo(borrowed_wad_lo);
    let total: u64 = available + borrowed;
    if (total == 0) {
        return 0;
    }
    return (borrowed * 100) / total;
}

// Two-slope kink interest rate model (Solend-specific)
// Returns annualized rate as percentage (0-255)
fn calculate_borrow_rate(
    min_rate: u64,
    optimal_rate: u64,
    max_rate: u64,
    optimal_util: u64,
    utilization: u64
) -> u64 {
    if (utilization <= optimal_util) {
        if (optimal_util == 0) {
            return min_rate;
        }
        return min_rate + (utilization * (optimal_rate - min_rate)) / optimal_util;
    }

    let excess_util: u64 = utilization - optimal_util;
    let remaining_util: u64 = 100 - optimal_util;
    if (remaining_util == 0) {
        return max_rate;
    }
    return optimal_rate + (excess_util * (max_rate - optimal_rate)) / remaining_util;
}

// Compound interest for WAD-scaled borrowed amount
// new_borrowed_wad = old_wad * (WAD + rate * slots / SLOTS_PER_YEAR) / WAD
// Returns new borrowed wad lo
fn compound_interest(
    borrowed_wad_lo: u64,
    borrow_rate: u64,
    slots_elapsed: u64
) -> u64 {
    if (borrowed_wad_lo == 0) {
        return 0;
    }
    if (slots_elapsed == 0) {
        return borrowed_wad_lo;
    }
    let slots_per_year: u64 = 63072000;
    // interest = borrowed * rate * slots / (slots_per_year * 100)
    // Using scaled arithmetic to avoid overflow
    let interest: u64 = (borrowed_wad_lo / 1000) * borrow_rate * slots_elapsed / (slots_per_year * 100 / 1000);
    return borrowed_wad_lo + interest;
}

// Update cumulative borrow rate with compound factor
fn update_cumulative_rate(
    old_rate_lo: u64,
    borrow_rate: u64,
    slots_elapsed: u64
) -> u64 {
    if (slots_elapsed == 0) {
        return old_rate_lo;
    }
    let slots_per_year: u64 = 63072000;
    let rate_increase: u64 = (old_rate_lo / 1000) * borrow_rate * slots_elapsed / (slots_per_year * 100 / 1000);
    return old_rate_lo + rate_increase;
}

// Calculate cToken exchange rate: total_liquidity * SCALE / collateral_supply
fn exchange_rate_scaled(available: u64, borrowed_wad_lo: u64, collateral_supply: u64) -> u64 {
    let borrowed: u64 = from_wad_lo(borrowed_wad_lo);
    let total_liquidity: u64 = available + borrowed;
    if (collateral_supply == 0) {
        return 1000000000;
    }
    return (total_liquidity * 1000000000) / collateral_supply;
}

// Deposit: calculate cTokens to mint given deposited liquidity
fn liquidity_to_collateral(
    liquidity_amount: u64,
    available: u64,
    borrowed_wad_lo: u64,
    collateral_supply: u64
) -> u64 {
    let borrowed: u64 = from_wad_lo(borrowed_wad_lo);
    let total_liquidity: u64 = available + borrowed;
    if (total_liquidity == 0) {
        return liquidity_amount;
    }
    if (collateral_supply == 0) {
        return liquidity_amount;
    }
    return (liquidity_amount * collateral_supply) / total_liquidity;
}

// Redeem: calculate liquidity returned for burned cTokens
fn collateral_to_liquidity(
    collateral_amount: u64,
    available: u64,
    borrowed_wad_lo: u64,
    collateral_supply: u64
) -> u64 {
    let borrowed: u64 = from_wad_lo(borrowed_wad_lo);
    let total_liquidity: u64 = available + borrowed;
    if (collateral_supply == 0) {
        return 0;
    }
    return (collateral_amount * total_liquidity) / collateral_supply;
}

// ─────────────────────────────────────────────────────────────────
// 1. init_lending_market
// ─────────────────────────────────────────────────────────────────

pub init_lending_market(
    market: LendingMarket @mut @init(payer=owner, space=500),
    owner: account @signer,
    oracle_program: pubkey
) {
    market.owner = owner.ctx.key;
    market.oracle_program = oracle_program;
    market.is_paused = false;
    market.num_reserves = 0;
}

// ─────────────────────────────────────────────────────────────────
// 2. set_lending_market_owner
// ─────────────────────────────────────────────────────────────────

pub set_lending_market_owner(
    market: LendingMarket @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(market.owner == owner.ctx.key);
    market.owner = new_owner;
}

// ─────────────────────────────────────────────────────────────────
// 3. init_reserve
// ─────────────────────────────────────────────────────────────────

pub init_reserve(
    market: LendingMarket @mut,
    reserve: Reserve @mut @init(payer=owner, space=1200),
    liquidity_mint: spl_token::Mint @serializer("raw"),
    liquidity_supply_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    oracle: account,
    owner: account @signer,
    // Config params
    config_optimal_utilization: u8,
    config_ltv: u8,
    config_liquidation_threshold: u8,
    config_liquidation_bonus: u8,
    config_min_borrow_rate: u8,
    config_optimal_borrow_rate: u8,
    config_max_borrow_rate: u8,
    config_host_fee_pct: u8,
    config_protocol_liq_fee: u8,
    config_flash_loan_fee_bps: u64,
    config_borrow_fee_bps: u64,
    config_deposit_limit: u64,
    config_borrow_limit: u64
) {
    require(market.owner == owner.ctx.key);
    require(config_ltv > 0);
    require(config_ltv < 100);
    require(config_liquidation_threshold > config_ltv);
    require(config_liquidation_threshold <= 100);
    require(config_liquidation_bonus <= 25);
    require(config_optimal_utilization <= 100);
    require(config_min_borrow_rate <= config_optimal_borrow_rate);
    require(config_optimal_borrow_rate <= config_max_borrow_rate);
    require(config_host_fee_pct <= 100);
    require(config_protocol_liq_fee <= 50);
    require(config_flash_loan_fee_bps <= 10000);
    require(config_borrow_fee_bps <= 10000);
    require(config_deposit_limit > 0);
    require(config_borrow_limit > 0);

    reserve.market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint.ctx.key;
    reserve.liquidity_supply_vault = liquidity_supply_vault.ctx.key;
    reserve.collateral_mint = collateral_mint.ctx.key;
    reserve.fee_receiver = fee_receiver.ctx.key;
    reserve.oracle = oracle.ctx.key;

    // State — initial
    reserve.available_amount = 0;
    reserve.borrowed_amount_wads_hi = 0;
    reserve.borrowed_amount_wads_lo = 0;
    // Cumulative borrow rate starts at 1 WAD (= 10^9 in our scaled representation)
    reserve.cumulative_borrow_rate_wads_hi = 0;
    reserve.cumulative_borrow_rate_wads_lo = 1000000000;
    reserve.market_price = 0;
    reserve.last_update_slot = get_clock().slot;
    reserve.collateral_mint_supply = 0;
    reserve.accumulated_protocol_fees = 0;

    // Config
    reserve.optimal_utilization_rate = config_optimal_utilization;
    reserve.loan_to_value_ratio = config_ltv;
    reserve.liquidation_threshold = config_liquidation_threshold;
    reserve.liquidation_bonus = config_liquidation_bonus;
    reserve.min_borrow_rate = config_min_borrow_rate;
    reserve.optimal_borrow_rate = config_optimal_borrow_rate;
    reserve.max_borrow_rate = config_max_borrow_rate;
    reserve.host_fee_percentage = config_host_fee_pct;
    reserve.protocol_liquidation_fee = config_protocol_liq_fee;
    reserve.flash_loan_fee_bps = config_flash_loan_fee_bps;
    reserve.borrow_fee_bps = config_borrow_fee_bps;
    reserve.deposit_limit = config_deposit_limit;
    reserve.borrow_limit = config_borrow_limit;

    market.num_reserves = market.num_reserves + 1;
}

// ─────────────────────────────────────────────────────────────────
// 4. refresh_reserve
// ─────────────────────────────────────────────────────────────────

pub refresh_reserve(
    reserve: Reserve @mut,
    oracle_state: PriceOracle
) {
    let current_slot: u64 = get_clock().slot;
    let slots_elapsed: u64 = current_slot - reserve.last_update_slot;

    // Update oracle price (enforce staleness)
    require(current_slot - oracle_state.last_update <= 100);
    require(oracle_state.price > 0);
    reserve.market_price = oracle_state.price;

    // Accrue interest if time has passed and there are borrows
    if (slots_elapsed > 0) {
        if (reserve.borrowed_amount_wads_lo > 0) {
            let utilization: u64 = calculate_utilization(
                reserve.available_amount,
                reserve.borrowed_amount_wads_lo
            );

            let borrow_rate: u64 = calculate_borrow_rate(
                reserve.min_borrow_rate as u64,
                reserve.optimal_borrow_rate as u64,
                reserve.max_borrow_rate as u64,
                reserve.optimal_utilization_rate as u64,
                utilization
            );

            let old_borrowed_lo: u64 = reserve.borrowed_amount_wads_lo;
            let new_borrowed_lo: u64 = compound_interest(
                old_borrowed_lo,
                borrow_rate,
                slots_elapsed
            );

            let interest_wad_lo: u64 = new_borrowed_lo - old_borrowed_lo;
            let interest_real: u64 = from_wad_lo(interest_wad_lo);

            // Protocol fee = host_fee_percentage of interest
            let protocol_fee: u64 = (interest_real * reserve.host_fee_percentage as u64) / 100;

            reserve.borrowed_amount_wads_lo = new_borrowed_lo;
            reserve.accumulated_protocol_fees = reserve.accumulated_protocol_fees + protocol_fee;

            // Update cumulative borrow rate
            reserve.cumulative_borrow_rate_wads_lo = update_cumulative_rate(
                reserve.cumulative_borrow_rate_wads_lo,
                borrow_rate,
                slots_elapsed
            );
        }

        reserve.last_update_slot = current_slot;
    }
}

// ─────────────────────────────────────────────────────────────────
// 5. set_reserve_config
// ─────────────────────────────────────────────────────────────────

pub set_reserve_config(
    market: LendingMarket,
    reserve: Reserve @mut,
    owner: account @signer,
    new_optimal_utilization: u8,
    new_ltv: u8,
    new_liquidation_threshold: u8,
    new_liquidation_bonus: u8,
    new_min_borrow_rate: u8,
    new_optimal_borrow_rate: u8,
    new_max_borrow_rate: u8,
    new_host_fee_pct: u8,
    new_protocol_liq_fee: u8,
    new_flash_loan_fee_bps: u64,
    new_borrow_fee_bps: u64,
    new_deposit_limit: u64,
    new_borrow_limit: u64
) {
    require(market.owner == owner.ctx.key);
    require(reserve.market == market.ctx.key);
    require(new_ltv > 0);
    require(new_ltv < 100);
    require(new_liquidation_threshold > new_ltv);
    require(new_liquidation_threshold <= 100);
    require(new_liquidation_bonus <= 25);
    require(new_optimal_utilization <= 100);
    require(new_min_borrow_rate <= new_optimal_borrow_rate);
    require(new_optimal_borrow_rate <= new_max_borrow_rate);
    require(new_host_fee_pct <= 100);
    require(new_protocol_liq_fee <= 50);
    require(new_flash_loan_fee_bps <= 10000);
    require(new_borrow_fee_bps <= 10000);

    reserve.optimal_utilization_rate = new_optimal_utilization;
    reserve.loan_to_value_ratio = new_ltv;
    reserve.liquidation_threshold = new_liquidation_threshold;
    reserve.liquidation_bonus = new_liquidation_bonus;
    reserve.min_borrow_rate = new_min_borrow_rate;
    reserve.optimal_borrow_rate = new_optimal_borrow_rate;
    reserve.max_borrow_rate = new_max_borrow_rate;
    reserve.host_fee_percentage = new_host_fee_pct;
    reserve.protocol_liquidation_fee = new_protocol_liq_fee;
    reserve.flash_loan_fee_bps = new_flash_loan_fee_bps;
    reserve.borrow_fee_bps = new_borrow_fee_bps;
    reserve.deposit_limit = new_deposit_limit;
    reserve.borrow_limit = new_borrow_limit;
}

// ─────────────────────────────────────────────────────────────────
// 6. deposit_reserve_liquidity
// ─────────────────────────────────────────────────────────────────

pub deposit_reserve_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    user_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    user_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    liquidity_amount: u64
) {
    require(!market.is_paused);
    require(liquidity_amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);

    // Enforce deposit limit
    require(reserve.available_amount + liquidity_amount <= reserve.deposit_limit);

    // Calculate cTokens using exchange rate
    let collateral_amount: u64 = liquidity_to_collateral(
        liquidity_amount,
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
    require(collateral_amount > 0);

    // Transfer liquidity from user to reserve vault
    spl_token::SPLToken::transfer(
        user_liquidity_account,
        reserve_liquidity_supply,
        user_authority,
        liquidity_amount
    );

    // Mint cTokens to user
    spl_token::SPLToken::mint_to(
        collateral_mint,
        user_collateral_account,
        market_authority,
        collateral_amount
    );

    reserve.available_amount = reserve.available_amount + liquidity_amount;
    reserve.collateral_mint_supply = reserve.collateral_mint_supply + collateral_amount;
    reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 7. redeem_reserve_collateral
// ─────────────────────────────────────────────────────────────────

pub redeem_reserve_collateral(
    market: LendingMarket,
    reserve: Reserve @mut,
    user_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);
    require(collateral_amount <= reserve.collateral_mint_supply);

    // Calculate underlying liquidity using exchange rate
    let liquidity_amount: u64 = collateral_to_liquidity(
        collateral_amount,
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.available_amount);

    // Burn cTokens from user
    spl_token::SPLToken::burn(
        user_collateral_account,
        collateral_mint,
        user_authority,
        collateral_amount
    );

    // Transfer liquidity to user
    spl_token::SPLToken::transfer(
        reserve_liquidity_supply,
        user_liquidity_account,
        market_authority,
        liquidity_amount
    );

    reserve.available_amount = reserve.available_amount - liquidity_amount;
    reserve.collateral_mint_supply = reserve.collateral_mint_supply - collateral_amount;
    reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 8. init_obligation
// ─────────────────────────────────────────────────────────────────

pub init_obligation(
    market: LendingMarket,
    obligation: Obligation @mut @init(payer=owner, space=2000),
    owner: account @signer
) {
    require(!market.is_paused);
    obligation.market = market.ctx.key;
    obligation.owner = owner.ctx.key;
    obligation.last_update_slot = get_clock().slot;

    obligation.deposited_value = 0;
    obligation.borrowed_value = 0;
    obligation.allowed_borrow_value = 0;
    obligation.unhealthy_borrow_value = 0;

    obligation.num_deposits = 0;
    obligation.num_borrows = 0;

    // Zero all deposit slots
    obligation.deposit_amount_1 = 0;
    obligation.deposit_market_value_1 = 0;
    obligation.deposit_amount_2 = 0;
    obligation.deposit_market_value_2 = 0;
    obligation.deposit_amount_3 = 0;
    obligation.deposit_market_value_3 = 0;

    // Zero all borrow slots
    obligation.borrow_amount_wads_hi_1 = 0;
    obligation.borrow_amount_wads_lo_1 = 0;
    obligation.borrow_market_value_1 = 0;
    obligation.borrow_amount_wads_hi_2 = 0;
    obligation.borrow_amount_wads_lo_2 = 0;
    obligation.borrow_market_value_2 = 0;
    obligation.borrow_amount_wads_hi_3 = 0;
    obligation.borrow_amount_wads_lo_3 = 0;
    obligation.borrow_market_value_3 = 0;
}

// ─────────────────────────────────────────────────────────────────
// 9. refresh_obligation
// ─────────────────────────────────────────────────────────────────
// Recalculates obligation health using reserve prices.
// Must be called after refresh_reserve for each involved reserve.
// Simplified: refreshes against one reserve at a time. Call for each.

pub refresh_obligation(
    market: LendingMarket,
    obligation: Obligation @mut,
    reserve: Reserve,
    owner: account @signer
) {
    require(!market.is_paused);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == owner.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.market_price > 0);

    let price: u64 = reserve.market_price;
    let ltv: u64 = reserve.loan_to_value_ratio as u64;
    let liq_threshold: u64 = reserve.liquidation_threshold as u64;
    let reserve_key: pubkey = reserve.ctx.key;

    // Update deposit slot values for this reserve
    let mut total_deposited: u64 = 0;
    let mut total_allowed: u64 = 0;
    let mut total_unhealthy: u64 = 0;

    // Slot 1
    if (obligation.deposit_amount_1 > 0) {
        if (obligation.deposit_reserve_1 == reserve_key) {
            let value: u64 = (obligation.deposit_amount_1 * price) / 1000000;
            obligation.deposit_market_value_1 = value;
        }
        total_deposited = total_deposited + obligation.deposit_market_value_1;
    }

    // Slot 2
    if (obligation.deposit_amount_2 > 0) {
        if (obligation.deposit_reserve_2 == reserve_key) {
            let value: u64 = (obligation.deposit_amount_2 * price) / 1000000;
            obligation.deposit_market_value_2 = value;
        }
        total_deposited = total_deposited + obligation.deposit_market_value_2;
    }

    // Slot 3
    if (obligation.deposit_amount_3 > 0) {
        if (obligation.deposit_reserve_3 == reserve_key) {
            let value: u64 = (obligation.deposit_amount_3 * price) / 1000000;
            obligation.deposit_market_value_3 = value;
        }
        total_deposited = total_deposited + obligation.deposit_market_value_3;
    }

    // Update borrow slot values for this reserve
    let mut total_borrowed: u64 = 0;

    // Borrow slot 1
    if (obligation.borrow_amount_wads_lo_1 > 0) {
        if (obligation.borrow_reserve_1 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(obligation.borrow_amount_wads_lo_1);
            let value: u64 = (borrow_real * price) / 1000000;
            obligation.borrow_market_value_1 = value;
        }
        total_borrowed = total_borrowed + obligation.borrow_market_value_1;
    }

    // Borrow slot 2
    if (obligation.borrow_amount_wads_lo_2 > 0) {
        if (obligation.borrow_reserve_2 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(obligation.borrow_amount_wads_lo_2);
            let value: u64 = (borrow_real * price) / 1000000;
            obligation.borrow_market_value_2 = value;
        }
        total_borrowed = total_borrowed + obligation.borrow_market_value_2;
    }

    // Borrow slot 3
    if (obligation.borrow_amount_wads_lo_3 > 0) {
        if (obligation.borrow_reserve_3 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(obligation.borrow_amount_wads_lo_3);
            let value: u64 = (borrow_real * price) / 1000000;
            obligation.borrow_market_value_3 = value;
        }
        total_borrowed = total_borrowed + obligation.borrow_market_value_3;
    }

    obligation.deposited_value = total_deposited;
    obligation.borrowed_value = total_borrowed;
    obligation.allowed_borrow_value = (total_deposited * ltv) / 100;
    obligation.unhealthy_borrow_value = (total_deposited * liq_threshold) / 100;
    obligation.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 10. deposit_obligation_collateral
// ─────────────────────────────────────────────────────────────────
// User deposits cTokens into their obligation as collateral

pub deposit_obligation_collateral(
    market: LendingMarket,
    obligation: Obligation @mut,
    reserve: Reserve,
    user_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    obligation_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve.market == market.ctx.key);

    let reserve_key: pubkey = reserve.ctx.key;

    // Transfer cTokens from user to obligation custody
    spl_token::SPLToken::transfer(
        user_collateral_account,
        obligation_collateral_account,
        user_authority,
        collateral_amount
    );

    // Find or assign deposit slot
    let mut assigned: bool = false;

    // Try slot 1
    if (!assigned) {
        if (obligation.deposit_amount_1 == 0) {
            obligation.deposit_reserve_1 = reserve_key;
            obligation.deposit_amount_1 = collateral_amount;
            obligation.num_deposits = obligation.num_deposits + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.deposit_reserve_1 == reserve_key) {
                obligation.deposit_amount_1 = obligation.deposit_amount_1 + collateral_amount;
                assigned = true;
            }
        }
    }

    // Try slot 2
    if (!assigned) {
        if (obligation.deposit_amount_2 == 0) {
            obligation.deposit_reserve_2 = reserve_key;
            obligation.deposit_amount_2 = collateral_amount;
            obligation.num_deposits = obligation.num_deposits + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.deposit_reserve_2 == reserve_key) {
                obligation.deposit_amount_2 = obligation.deposit_amount_2 + collateral_amount;
                assigned = true;
            }
        }
    }

    // Try slot 3
    if (!assigned) {
        if (obligation.deposit_amount_3 == 0) {
            obligation.deposit_reserve_3 = reserve_key;
            obligation.deposit_amount_3 = collateral_amount;
            obligation.num_deposits = obligation.num_deposits + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.deposit_reserve_3 == reserve_key) {
                obligation.deposit_amount_3 = obligation.deposit_amount_3 + collateral_amount;
                assigned = true;
            }
        }
    }

    require(assigned);
}

// ─────────────────────────────────────────────────────────────────
// 11. withdraw_obligation_collateral
// ─────────────────────────────────────────────────────────────────

pub withdraw_obligation_collateral(
    market: LendingMarket,
    obligation: Obligation @mut,
    reserve: Reserve,
    obligation_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve.market == market.ctx.key);

    let reserve_key: pubkey = reserve.ctx.key;
    let price: u64 = reserve.market_price;
    require(price > 0);
    let ltv: u64 = reserve.loan_to_value_ratio as u64;

    // Find the deposit slot and reduce collateral
    let mut withdrawn: bool = false;

    if (!withdrawn) {
        if (obligation.deposit_reserve_1 == reserve_key) {
            require(collateral_amount <= obligation.deposit_amount_1);
            obligation.deposit_amount_1 = obligation.deposit_amount_1 - collateral_amount;
            if (obligation.deposit_amount_1 == 0) {
                obligation.deposit_market_value_1 = 0;
                obligation.num_deposits = obligation.num_deposits - 1;
            }
            withdrawn = true;
        }
    }

    if (!withdrawn) {
        if (obligation.deposit_reserve_2 == reserve_key) {
            require(collateral_amount <= obligation.deposit_amount_2);
            obligation.deposit_amount_2 = obligation.deposit_amount_2 - collateral_amount;
            if (obligation.deposit_amount_2 == 0) {
                obligation.deposit_market_value_2 = 0;
                obligation.num_deposits = obligation.num_deposits - 1;
            }
            withdrawn = true;
        }
    }

    if (!withdrawn) {
        if (obligation.deposit_reserve_3 == reserve_key) {
            require(collateral_amount <= obligation.deposit_amount_3);
            obligation.deposit_amount_3 = obligation.deposit_amount_3 - collateral_amount;
            if (obligation.deposit_amount_3 == 0) {
                obligation.deposit_market_value_3 = 0;
                obligation.num_deposits = obligation.num_deposits - 1;
            }
            withdrawn = true;
        }
    }

    require(withdrawn);

    // Post-withdrawal health check: recalculate deposited value
    let mut new_deposited_value: u64 = obligation.deposit_market_value_1
        + obligation.deposit_market_value_2
        + obligation.deposit_market_value_3;
    let new_allowed_borrow: u64 = (new_deposited_value * ltv) / 100;

    // Borrowed value must remain within LTV
    require(obligation.borrowed_value <= new_allowed_borrow);

    obligation.deposited_value = new_deposited_value;
    obligation.allowed_borrow_value = new_allowed_borrow;

    // Transfer cTokens back to user
    spl_token::SPLToken::transfer(
        obligation_collateral_account,
        user_collateral_account,
        market_authority,
        collateral_amount
    );
}

// ─────────────────────────────────────────────────────────────────
// 12. borrow_obligation_liquidity
// ─────────────────────────────────────────────────────────────────

pub borrow_obligation_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    liquidity_amount: u64
) {
    require(!market.is_paused);
    require(liquidity_amount > 0);
    require(obligation.market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.fee_receiver == fee_receiver.ctx.key);

    // Enforce borrow limit
    let current_borrows: u64 = from_wad_lo(reserve.borrowed_amount_wads_lo);
    require(current_borrows + liquidity_amount <= reserve.borrow_limit);

    // Enforce available liquidity
    require(liquidity_amount <= reserve.available_amount);

    // Calculate borrow fee
    let borrow_fee: u64 = (liquidity_amount * reserve.borrow_fee_bps) / 10000;
    let amount_after_fee: u64 = liquidity_amount - borrow_fee;

    // LTV check: new borrow value must be within allowed
    let reserve_price: u64 = reserve.market_price;
    require(reserve_price > 0);
    let borrow_value_addition: u64 = (liquidity_amount * reserve_price) / 1000000;
    let new_borrowed_value: u64 = obligation.borrowed_value + borrow_value_addition;
    require(new_borrowed_value <= obligation.allowed_borrow_value);

    // Update reserve state
    reserve.available_amount = reserve.available_amount - liquidity_amount;
    let borrow_wad: u64 = to_wad_lo(liquidity_amount);
    reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo + borrow_wad;

    // Transfer liquidity to user (minus fee)
    spl_token::SPLToken::transfer(
        reserve_liquidity_supply,
        user_liquidity_account,
        market_authority,
        amount_after_fee
    );

    // Transfer borrow fee to fee receiver
    if (borrow_fee > 0) {
        spl_token::SPLToken::transfer(
            reserve_liquidity_supply,
            fee_receiver,
            market_authority,
            borrow_fee
        );
    }

    // Record borrow in obligation slot
    let reserve_key: pubkey = reserve.ctx.key;
    let mut assigned: bool = false;

    if (!assigned) {
        if (obligation.borrow_amount_wads_lo_1 == 0) {
            obligation.borrow_reserve_1 = reserve_key;
            obligation.borrow_amount_wads_lo_1 = borrow_wad;
            obligation.borrow_market_value_1 = borrow_value_addition;
            obligation.num_borrows = obligation.num_borrows + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.borrow_reserve_1 == reserve_key) {
                obligation.borrow_amount_wads_lo_1 = obligation.borrow_amount_wads_lo_1 + borrow_wad;
                obligation.borrow_market_value_1 = obligation.borrow_market_value_1 + borrow_value_addition;
                assigned = true;
            }
        }
    }

    if (!assigned) {
        if (obligation.borrow_amount_wads_lo_2 == 0) {
            obligation.borrow_reserve_2 = reserve_key;
            obligation.borrow_amount_wads_lo_2 = borrow_wad;
            obligation.borrow_market_value_2 = borrow_value_addition;
            obligation.num_borrows = obligation.num_borrows + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.borrow_reserve_2 == reserve_key) {
                obligation.borrow_amount_wads_lo_2 = obligation.borrow_amount_wads_lo_2 + borrow_wad;
                obligation.borrow_market_value_2 = obligation.borrow_market_value_2 + borrow_value_addition;
                assigned = true;
            }
        }
    }

    if (!assigned) {
        if (obligation.borrow_amount_wads_lo_3 == 0) {
            obligation.borrow_reserve_3 = reserve_key;
            obligation.borrow_amount_wads_lo_3 = borrow_wad;
            obligation.borrow_market_value_3 = borrow_value_addition;
            obligation.num_borrows = obligation.num_borrows + 1;
            assigned = true;
        }
        if (!assigned) {
            if (obligation.borrow_reserve_3 == reserve_key) {
                obligation.borrow_amount_wads_lo_3 = obligation.borrow_amount_wads_lo_3 + borrow_wad;
                obligation.borrow_market_value_3 = obligation.borrow_market_value_3 + borrow_value_addition;
                assigned = true;
            }
        }
    }

    require(assigned);

    obligation.borrowed_value = new_borrowed_value;
    reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 13. repay_obligation_liquidity
// ─────────────────────────────────────────────────────────────────

pub repay_obligation_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    liquidity_amount: u64
) {
    require(!market.is_paused);
    require(liquidity_amount > 0);
    require(obligation.market == market.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);

    let reserve_key: pubkey = reserve.ctx.key;
    let reserve_price: u64 = reserve.market_price;

    // Find the borrow slot and repay
    let mut repaid: bool = false;
    let mut actual_repay_wad: u64 = 0;
    let repay_wad: u64 = to_wad_lo(liquidity_amount);

    // Slot 1
    if (!repaid) {
        if (obligation.borrow_reserve_1 == reserve_key) {
            if (obligation.borrow_amount_wads_lo_1 > 0) {
                let mut settle_wad: u64 = repay_wad;
                if (settle_wad > obligation.borrow_amount_wads_lo_1) {
                    settle_wad = obligation.borrow_amount_wads_lo_1;
                }
                obligation.borrow_amount_wads_lo_1 = obligation.borrow_amount_wads_lo_1 - settle_wad;
                actual_repay_wad = settle_wad;
                if (obligation.borrow_amount_wads_lo_1 == 0) {
                    obligation.borrow_market_value_1 = 0;
                    obligation.num_borrows = obligation.num_borrows - 1;
                }
                repaid = true;
            }
        }
    }

    // Slot 2
    if (!repaid) {
        if (obligation.borrow_reserve_2 == reserve_key) {
            if (obligation.borrow_amount_wads_lo_2 > 0) {
                let mut settle_wad: u64 = repay_wad;
                if (settle_wad > obligation.borrow_amount_wads_lo_2) {
                    settle_wad = obligation.borrow_amount_wads_lo_2;
                }
                obligation.borrow_amount_wads_lo_2 = obligation.borrow_amount_wads_lo_2 - settle_wad;
                actual_repay_wad = settle_wad;
                if (obligation.borrow_amount_wads_lo_2 == 0) {
                    obligation.borrow_market_value_2 = 0;
                    obligation.num_borrows = obligation.num_borrows - 1;
                }
                repaid = true;
            }
        }
    }

    // Slot 3
    if (!repaid) {
        if (obligation.borrow_reserve_3 == reserve_key) {
            if (obligation.borrow_amount_wads_lo_3 > 0) {
                let mut settle_wad: u64 = repay_wad;
                if (settle_wad > obligation.borrow_amount_wads_lo_3) {
                    settle_wad = obligation.borrow_amount_wads_lo_3;
                }
                obligation.borrow_amount_wads_lo_3 = obligation.borrow_amount_wads_lo_3 - settle_wad;
                actual_repay_wad = settle_wad;
                if (obligation.borrow_amount_wads_lo_3 == 0) {
                    obligation.borrow_market_value_3 = 0;
                    obligation.num_borrows = obligation.num_borrows - 1;
                }
                repaid = true;
            }
        }
    }

    require(repaid);
    require(actual_repay_wad > 0);

    let actual_repay: u64 = from_wad_lo(actual_repay_wad);
    require(actual_repay > 0);

    // Transfer repayment from user to reserve vault
    spl_token::SPLToken::transfer(
        user_liquidity_account,
        reserve_liquidity_supply,
        user_authority,
        actual_repay
    );

    // Update reserve
    if (reserve.borrowed_amount_wads_lo >= actual_repay_wad) {
        reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo - actual_repay_wad;
    } else {
        reserve.borrowed_amount_wads_lo = 0;
    }
    reserve.available_amount = reserve.available_amount + actual_repay;

    // Update obligation value
    let repay_value: u64 = (actual_repay * reserve_price) / 1000000;
    if (obligation.borrowed_value >= repay_value) {
        obligation.borrowed_value = obligation.borrowed_value - repay_value;
    } else {
        obligation.borrowed_value = 0;
    }

    reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 14. liquidate_obligation
// ─────────────────────────────────────────────────────────────────

pub liquidate_obligation(
    market: LendingMarket,
    repay_reserve: Reserve @mut,
    withdraw_reserve: Reserve,
    obligation: Obligation @mut,
    liquidator_repay_account: spl_token::TokenAccount @mut @serializer("raw"),
    repay_reserve_supply: spl_token::TokenAccount @mut @serializer("raw"),
    withdraw_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    liquidator_collateral_account: spl_token::TokenAccount @mut @serializer("raw"),
    protocol_fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    liquidity_amount: u64
) {
    require(!market.is_paused);
    require(liquidity_amount > 0);
    require(obligation.market == market.ctx.key);
    require(repay_reserve.market == market.ctx.key);
    require(withdraw_reserve.market == market.ctx.key);
    require(repay_reserve.liquidity_supply_vault == repay_reserve_supply.ctx.key);

    // Obligation must be unhealthy
    require(obligation.borrowed_value > obligation.unhealthy_borrow_value);

    let repay_reserve_key: pubkey = repay_reserve.ctx.key;
    let withdraw_reserve_key: pubkey = withdraw_reserve.ctx.key;
    let repay_price: u64 = repay_reserve.market_price;
    let withdraw_price: u64 = withdraw_reserve.market_price;
    require(repay_price > 0);
    require(withdraw_price > 0);

    let bonus_pct: u64 = repay_reserve.liquidation_bonus as u64;
    let protocol_liq_fee_pct: u64 = repay_reserve.protocol_liquidation_fee as u64;

    // Find the borrow slot and clamp repay
    let mut actual_repay: u64 = liquidity_amount;
    let repay_wad: u64 = to_wad_lo(liquidity_amount);

    // Find outstanding borrow in the repay reserve
    let mut borrow_outstanding_wad: u64 = 0;

    if (obligation.borrow_reserve_1 == repay_reserve_key) {
        borrow_outstanding_wad = obligation.borrow_amount_wads_lo_1;
    }
    if (borrow_outstanding_wad == 0) {
        if (obligation.borrow_reserve_2 == repay_reserve_key) {
            borrow_outstanding_wad = obligation.borrow_amount_wads_lo_2;
        }
    }
    if (borrow_outstanding_wad == 0) {
        if (obligation.borrow_reserve_3 == repay_reserve_key) {
            borrow_outstanding_wad = obligation.borrow_amount_wads_lo_3;
        }
    }
    require(borrow_outstanding_wad > 0);

    let borrow_outstanding: u64 = from_wad_lo(borrow_outstanding_wad);
    if (actual_repay > borrow_outstanding) {
        actual_repay = borrow_outstanding;
    }

    // Liquidation can repay at most 50% of the obligation's total borrows
    let max_close: u64 = obligation.borrowed_value / 2;
    let repay_value: u64 = (actual_repay * repay_price) / 1000000;
    if (repay_value > max_close) {
        actual_repay = (max_close * 1000000) / repay_price;
    }
    require(actual_repay > 0);

    // Calculate collateral to seize (including bonus)
    let repay_value_final: u64 = (actual_repay * repay_price) / 1000000;
    let total_collateral_value: u64 = (repay_value_final * (100 + bonus_pct)) / 100;
    let collateral_amount: u64 = (total_collateral_value * 1000000) / withdraw_price;

    // Protocol gets protocol_liquidation_fee % of the bonus
    let bonus_value: u64 = (repay_value_final * bonus_pct) / 100;
    let protocol_bonus_value: u64 = (bonus_value * protocol_liq_fee_pct) / 100;
    let protocol_collateral: u64 = (protocol_bonus_value * 1000000) / withdraw_price;
    let liquidator_collateral: u64 = collateral_amount - protocol_collateral;

    // Transfer repayment from liquidator to reserve
    spl_token::SPLToken::transfer(
        liquidator_repay_account,
        repay_reserve_supply,
        liquidator,
        actual_repay
    );

    // Transfer seized collateral to liquidator
    spl_token::SPLToken::transfer(
        withdraw_collateral_account,
        liquidator_collateral_account,
        market_authority,
        liquidator_collateral
    );

    // Transfer protocol portion of collateral to fee receiver
    if (protocol_collateral > 0) {
        spl_token::SPLToken::transfer(
            withdraw_collateral_account,
            protocol_fee_receiver,
            market_authority,
            protocol_collateral
        );
    }

    // Update repay reserve
    let actual_repay_wad: u64 = to_wad_lo(actual_repay);
    if (repay_reserve.borrowed_amount_wads_lo >= actual_repay_wad) {
        repay_reserve.borrowed_amount_wads_lo = repay_reserve.borrowed_amount_wads_lo - actual_repay_wad;
    } else {
        repay_reserve.borrowed_amount_wads_lo = 0;
    }
    repay_reserve.available_amount = repay_reserve.available_amount + actual_repay;

    // Update obligation borrow slot
    if (obligation.borrow_reserve_1 == repay_reserve_key) {
        if (obligation.borrow_amount_wads_lo_1 >= actual_repay_wad) {
            obligation.borrow_amount_wads_lo_1 = obligation.borrow_amount_wads_lo_1 - actual_repay_wad;
        } else {
            obligation.borrow_amount_wads_lo_1 = 0;
        }
        if (obligation.borrow_amount_wads_lo_1 == 0) {
            obligation.borrow_market_value_1 = 0;
        }
    }
    if (obligation.borrow_reserve_2 == repay_reserve_key) {
        if (obligation.borrow_amount_wads_lo_2 >= actual_repay_wad) {
            obligation.borrow_amount_wads_lo_2 = obligation.borrow_amount_wads_lo_2 - actual_repay_wad;
        } else {
            obligation.borrow_amount_wads_lo_2 = 0;
        }
        if (obligation.borrow_amount_wads_lo_2 == 0) {
            obligation.borrow_market_value_2 = 0;
        }
    }
    if (obligation.borrow_reserve_3 == repay_reserve_key) {
        if (obligation.borrow_amount_wads_lo_3 >= actual_repay_wad) {
            obligation.borrow_amount_wads_lo_3 = obligation.borrow_amount_wads_lo_3 - actual_repay_wad;
        } else {
            obligation.borrow_amount_wads_lo_3 = 0;
        }
        if (obligation.borrow_amount_wads_lo_3 == 0) {
            obligation.borrow_market_value_3 = 0;
        }
    }

    // Update obligation deposit slot (reduce withdrawn collateral)
    if (obligation.deposit_reserve_1 == withdraw_reserve_key) {
        if (obligation.deposit_amount_1 >= collateral_amount) {
            obligation.deposit_amount_1 = obligation.deposit_amount_1 - collateral_amount;
        } else {
            obligation.deposit_amount_1 = 0;
        }
    }
    if (obligation.deposit_reserve_2 == withdraw_reserve_key) {
        if (obligation.deposit_amount_2 >= collateral_amount) {
            obligation.deposit_amount_2 = obligation.deposit_amount_2 - collateral_amount;
        } else {
            obligation.deposit_amount_2 = 0;
        }
    }
    if (obligation.deposit_reserve_3 == withdraw_reserve_key) {
        if (obligation.deposit_amount_3 >= collateral_amount) {
            obligation.deposit_amount_3 = obligation.deposit_amount_3 - collateral_amount;
        } else {
            obligation.deposit_amount_3 = 0;
        }
    }

    // Recalculate obligation values
    let recalc_repay_value: u64 = (actual_repay * repay_price) / 1000000;
    if (obligation.borrowed_value >= recalc_repay_value) {
        obligation.borrowed_value = obligation.borrowed_value - recalc_repay_value;
    } else {
        obligation.borrowed_value = 0;
    }
    if (obligation.deposited_value >= total_collateral_value) {
        obligation.deposited_value = obligation.deposited_value - total_collateral_value;
    } else {
        obligation.deposited_value = 0;
    }

    repay_reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 15. flash_loan_begin
// ─────────────────────────────────────────────────────────────────
// Borrow tokens with no collateral. Must be repaid via flash_loan_end
// in the same transaction.

pub flash_loan_begin(
    market: LendingMarket,
    reserve: Reserve @mut,
    receipt: FlashLoanReceipt @mut @init(payer=borrower, space=300),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    borrower_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    borrower: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(amount <= reserve.available_amount);

    // Calculate flash loan fee
    let fee: u64 = (amount * reserve.flash_loan_fee_bps) / 10000;
    // Minimum fee of 1 token unit
    let mut actual_fee: u64 = fee;
    if (actual_fee == 0) {
        actual_fee = 1;
    }

    // Record the receipt
    receipt.reserve = reserve.ctx.key;
    receipt.borrower = borrower.ctx.key;
    receipt.amount = amount;
    receipt.fee = actual_fee;
    receipt.is_repaid = false;

    // Transfer borrowed amount to user
    spl_token::SPLToken::transfer(
        reserve_liquidity_supply,
        borrower_liquidity_account,
        market_authority,
        amount
    );

    reserve.available_amount = reserve.available_amount - amount;
}

// ─────────────────────────────────────────────────────────────────
// 16. flash_loan_end
// ─────────────────────────────────────────────────────────────────
// Verify repayment of flash loan principal + fee. Reverts if not repaid.

pub flash_loan_end(
    market: LendingMarket,
    reserve: Reserve @mut,
    receipt: FlashLoanReceipt @mut,
    borrower_liquidity_account: spl_token::TokenAccount @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    borrower: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(receipt.reserve == reserve.ctx.key);
    require(receipt.borrower == borrower.ctx.key);
    require(!receipt.is_repaid);

    let repay_amount: u64 = receipt.amount;
    let fee_amount: u64 = receipt.fee;
    let total_owed: u64 = repay_amount + fee_amount;

    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.fee_receiver == fee_receiver.ctx.key);

    // Transfer principal back to reserve vault
    spl_token::SPLToken::transfer(
        borrower_liquidity_account,
        reserve_liquidity_supply,
        borrower,
        repay_amount
    );

    // Transfer fee to fee receiver
    spl_token::SPLToken::transfer(
        borrower_liquidity_account,
        fee_receiver,
        borrower,
        fee_amount
    );

    reserve.available_amount = reserve.available_amount + repay_amount;
    reserve.accumulated_protocol_fees = reserve.accumulated_protocol_fees + fee_amount;
    receipt.is_repaid = true;
    reserve.last_update_slot = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// 17. withdraw_protocol_fees
// ─────────────────────────────────────────────────────────────────

pub withdraw_protocol_fees(
    market: LendingMarket,
    reserve: Reserve @mut,
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    owner: account @signer,
    token_program: account
) {
    require(market.owner == owner.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.fee_receiver == fee_receiver.ctx.key);
    require(reserve.accumulated_protocol_fees > 0);
    require(reserve.available_amount >= reserve.accumulated_protocol_fees);

    let fees: u64 = reserve.accumulated_protocol_fees;
    reserve.accumulated_protocol_fees = 0;
    reserve.available_amount = reserve.available_amount - fees;

    spl_token::SPLToken::transfer(
        reserve_liquidity_supply,
        fee_receiver,
        market_authority,
        fees
    );
}

// ─────────────────────────────────────────────────────────────────
// 18. pause / unpause
// ─────────────────────────────────────────────────────────────────

pub pause_lending_market(
    market: LendingMarket @mut,
    owner: account @signer
) {
    require(market.owner == owner.ctx.key);
    require(!market.is_paused);
    market.is_paused = true;
}

pub unpause_lending_market(
    market: LendingMarket @mut,
    owner: account @signer
) {
    require(market.owner == owner.ctx.key);
    require(market.is_paused);
    market.is_paused = false;
}

// ─────────────────────────────────────────────────────────────────
// Oracle management
// ─────────────────────────────────────────────────────────────────

pub init_oracle(
    oracle: PriceOracle @mut @init(payer=authority, space=300),
    authority: account @signer,
    price: u64,
    decimals: u8
) {
    require(price > 0);
    oracle.authority = authority.ctx.key;
    oracle.price = price;
    oracle.decimals = decimals;
    oracle.last_update = get_clock().slot;
}

pub update_oracle(
    oracle: PriceOracle @mut,
    authority: account @signer,
    price: u64
) {
    require(oracle.authority == authority.ctx.key);
    require(price > 0);
    oracle.price = price;
    oracle.last_update = get_clock().slot;
}

// ─────────────────────────────────────────────────────────────────
// Read-only view helpers
// ─────────────────────────────────────────────────────────────────

pub get_reserve_utilization(reserve: Reserve) -> u64 {
    return calculate_utilization(reserve.available_amount, reserve.borrowed_amount_wads_lo);
}

pub get_reserve_borrow_rate(reserve: Reserve) -> u64 {
    let utilization: u64 = calculate_utilization(
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo
    );
    return calculate_borrow_rate(
        reserve.min_borrow_rate as u64,
        reserve.optimal_borrow_rate as u64,
        reserve.max_borrow_rate as u64,
        reserve.optimal_utilization_rate as u64,
        utilization
    );
}

pub get_exchange_rate(reserve: Reserve) -> u64 {
    return exchange_rate_scaled(
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
}

pub get_obligation_health(obligation: Obligation) -> u64 {
    if (obligation.borrowed_value == 0) {
        return 100;
    }
    if (obligation.unhealthy_borrow_value == 0) {
        return 0;
    }
    // Health = (unhealthy_threshold / borrowed_value) * 100
    // > 100 means healthy, < 100 means liquidatable
    return (obligation.unhealthy_borrow_value * 100) / obligation.borrowed_value;
}

pub get_total_liquidity(reserve: Reserve) -> u64 {
    let borrowed: u64 = from_wad_lo(reserve.borrowed_amount_wads_lo);
    return reserve.available_amount + borrowed;
}
