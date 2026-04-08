// Apricot Finance — Yield/Lending with Apricot Assist (Auto-Deleverage)
// 5ive DSL migration: faithful representation of Apricot's on-chain mechanics
//
// Key features beyond standard lending:
//   - Apricot Assist: auto-deleverage protection that sells collateral to repay
//     borrows when health drops below a user-configured threshold
//   - X-Farm: cross-protocol yield farming with auto-compound
//   - Flash liquidation: flash loan + liquidation in one tx
//   - Two-slope kink interest rate model
//   - Multi-asset obligations: 3 deposit + 3 borrow slots
//   - Cross-collateral support across reserves
//
// Accounts:
//   Market       — top-level market with admin, oracle program, pause state
//   Reserve      — per-token reserve with two-slope interest, oracle, weights
//   UserAccount  — per-user position: 3 deposit + 3 borrow slots, assist config
//   Farm         — yield farming pool for LP tokens
//   StakeRecord  — per-user staking position in a farm
//   PriceOracle  — price feed with staleness enforcement

use std::interfaces::spl_token;

// -----------------------------------------------------------------
// Accounts
// -----------------------------------------------------------------

account Market {
    admin: pubkey;
    oracle_program: pubkey;
    is_paused: bool;
    num_reserves: u8;
    protocol_fees_collected: u64;
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
    borrowed_amount_wads_lo: u64;
    cumulative_borrow_rate_lo: u64;
    market_price: u64;
    last_update_slot: u64;
    collateral_mint_supply: u64;
    accumulated_protocol_fees: u64;

    // Config -- two-slope kink interest rate model
    optimal_utilization_rate: u8;
    loan_to_value_ratio: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    min_borrow_rate: u8;
    optimal_borrow_rate: u8;
    max_borrow_rate: u8;

    // Weight for cross-collateral (percentage, e.g. 100 = full weight)
    collateral_weight: u8;

    // Caps
    deposit_limit: u64;
    borrow_limit: u64;
}

account UserAccount {
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
    borrow_amount_wads_lo_1: u64;
    borrow_market_value_1: u64;

    borrow_reserve_2: pubkey;
    borrow_amount_wads_lo_2: u64;
    borrow_market_value_2: u64;

    borrow_reserve_3: pubkey;
    borrow_amount_wads_lo_3: u64;
    borrow_market_value_3: u64;

    // Apricot Assist config
    assist_enabled: bool;
    assist_threshold: u64;       // health factor threshold (scaled by 100, e.g. 110 = 1.1x)
    assist_target_health: u64;   // target health after assist (scaled, e.g. 150 = 1.5x)
    assist_fee_bps: u64;         // fee charged on assist execution (in bps)
}

account Farm {
    market: pubkey;
    admin: pubkey;
    stake_mint: pubkey;          // LP token to stake
    reward_mint: pubkey;         // reward token
    reward_vault: pubkey;        // vault holding reward tokens
    total_staked: u64;
    reward_per_token_stored: u64;
    last_reward_update_slot: u64;
    reward_rate: u64;            // rewards per slot
    is_active: bool;
}

account StakeRecord {
    farm: pubkey;
    owner: pubkey;
    staked_amount: u64;
    reward_debt: u64;
    pending_rewards: u64;
}

account PriceOracle {
    authority: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

// -----------------------------------------------------------------
// Constants (inline)
// -----------------------------------------------------------------

// SCALE = 10^9 (used for WAD-lite precision)
// SLOTS_PER_YEAR ~= 63_072_000 (2 slots/sec * 31_536_000 sec/year)
// ORACLE_STALE_SLOTS = 100
// MAX_DEPOSITS = 3
// MAX_BORROWS = 3
// HEALTH_SCALE = 100 (health factor 1.0 = 100)
// CLOSE_FACTOR = 50 (max 50% of borrow liquidated per tx)
// ASSIST_DEFAULT_THRESHOLD = 110 (1.1x health)
// ASSIST_DEFAULT_TARGET = 150 (1.5x health)
// ASSIST_MAX_FEE_BPS = 500 (5%)

// -----------------------------------------------------------------
// Internal helpers
// -----------------------------------------------------------------

fn to_wad_lo(amount: u64) -> u64 {
    return amount * 1000000000;
}

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

// Two-slope kink interest rate model
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

// Deposit: calculate aTokens to mint given deposited liquidity
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

// Redeem: calculate liquidity returned for burned aTokens
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

// Calculate health factor (scaled by 100): deposited_value * 100 / borrowed_value
// Returns 0 if no borrows (healthy), otherwise scaled health
fn calculate_health_factor(deposited_value: u64, borrowed_value: u64, liq_threshold: u64) -> u64 {
    if (borrowed_value == 0) {
        return 10000;
    }
    let weighted_deposit: u64 = (deposited_value * liq_threshold) / 100;
    return (weighted_deposit * 100) / borrowed_value;
}

// Calculate collateral to sell for assist deleverage
// Sells enough collateral to bring health back to target
// repay_amount = (target * borrowed - deposited * liq_threshold * 100) / (target - liq_threshold * 100)
fn calculate_assist_repay(
    deposited_value: u64,
    borrowed_value: u64,
    liq_threshold: u64,
    target_health: u64
) -> u64 {
    let weighted_deposit: u64 = (deposited_value * liq_threshold) / 100;
    let current_health: u64 = (weighted_deposit * 100) / borrowed_value;

    // How much borrow must be repaid to reach target health
    // target_health = (deposited - repay) * liq_threshold / (borrowed - repay) * 100
    // Simplified: repay = (target * borrowed - weighted_deposit * 100) / (target - liq_threshold)
    let numerator: u64 = target_health * borrowed_value;
    let denominator: u64 = target_health;

    if (numerator <= weighted_deposit * 100) {
        return 0;
    }

    let deficit: u64 = numerator - (weighted_deposit * 100);
    if (denominator == 0) {
        return 0;
    }
    return deficit / denominator;
}

// Update farm reward accounting
fn update_farm_rewards(
    total_staked: u64,
    reward_per_token_stored: u64,
    last_update_slot: u64,
    reward_rate: u64,
    current_slot: u64
) -> u64 {
    if (total_staked == 0) {
        return reward_per_token_stored;
    }
    let slots_elapsed: u64 = current_slot - last_update_slot;
    let new_rewards: u64 = (slots_elapsed * reward_rate * 1000000000) / total_staked;
    return reward_per_token_stored + new_rewards;
}

// Calculate pending rewards for a staker
fn calculate_pending(
    staked_amount: u64,
    reward_per_token: u64,
    reward_debt: u64
) -> u64 {
    let earned: u64 = (staked_amount * reward_per_token) / 1000000000;
    if (earned <= reward_debt) {
        return 0;
    }
    return earned - reward_debt;
}

// -----------------------------------------------------------------
// 1. init_market -- Create lending market
// -----------------------------------------------------------------

pub init_market(
    market: Market @mut @init(payer=admin, space=600),
    admin: account @signer,
    oracle_program: pubkey
) {
    market.admin = admin.ctx.key;
    market.oracle_program = oracle_program;
    market.is_paused = false;
    market.num_reserves = 0;
    market.protocol_fees_collected = 0;
}

// -----------------------------------------------------------------
// 2. init_reserve -- Register token with interest params, oracle, weights
// -----------------------------------------------------------------

pub init_reserve(
    market: Market @mut,
    reserve: Reserve @mut @init(payer=admin, space=1200),
    liquidity_mint: spl_token::Mint @serializer("raw"),
    liquidity_supply_vault: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    fee_receiver: spl_token::TokenAccount @mut @serializer("raw"),
    oracle: account,
    admin: account @signer,
    config_optimal_utilization: u8,
    config_ltv: u8,
    config_liquidation_threshold: u8,
    config_liquidation_bonus: u8,
    config_min_borrow_rate: u8,
    config_optimal_borrow_rate: u8,
    config_max_borrow_rate: u8,
    config_collateral_weight: u8,
    config_deposit_limit: u64,
    config_borrow_limit: u64
) {
    require(market.admin == admin.ctx.key);
    require(config_ltv > 0);
    require(config_ltv < 100);
    require(config_liquidation_threshold > config_ltv);
    require(config_liquidation_threshold <= 100);
    require(config_liquidation_bonus <= 25);
    require(config_optimal_utilization <= 100);
    require(config_min_borrow_rate <= config_optimal_borrow_rate);
    require(config_optimal_borrow_rate <= config_max_borrow_rate);
    require(config_collateral_weight <= 100);
    require(config_deposit_limit > 0);
    require(config_borrow_limit > 0);

    reserve.market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint.ctx.key;
    reserve.liquidity_supply_vault = liquidity_supply_vault.ctx.key;
    reserve.collateral_mint = collateral_mint.ctx.key;
    reserve.fee_receiver = fee_receiver.ctx.key;
    reserve.oracle = oracle.ctx.key;

    // State -- initial
    reserve.available_amount = 0;
    reserve.borrowed_amount_wads_lo = 0;
    reserve.cumulative_borrow_rate_lo = 1000000000;
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
    reserve.collateral_weight = config_collateral_weight;
    reserve.deposit_limit = config_deposit_limit;
    reserve.borrow_limit = config_borrow_limit;

    market.num_reserves = market.num_reserves + 1;
}

// -----------------------------------------------------------------
// 3. deposit -- Deposit tokens, receive aTokens
// -----------------------------------------------------------------

pub deposit(
    market: Market,
    reserve: Reserve @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == reserve_liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);

    // Enforce deposit limit
    require(reserve.available_amount + amount <= reserve.deposit_limit);

    // Calculate aTokens using exchange rate
    let collateral_amount: u64 = liquidity_to_collateral(
        amount,
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
    require(collateral_amount > 0);

    // Transfer liquidity from user to reserve vault
    spl_token::SPLToken::transfer(user_liquidity, reserve_liquidity_supply, user_authority, amount);

    // Mint aTokens to user
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, collateral_amount);

    reserve.available_amount = reserve.available_amount + amount;
    reserve.collateral_mint_supply = reserve.collateral_mint_supply + collateral_amount;
    reserve.last_update_slot = get_clock().slot;
}

// -----------------------------------------------------------------
// 4. withdraw -- Burn aTokens, receive underlying
// -----------------------------------------------------------------

pub withdraw(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount,
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    reserve_liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
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
    require(user_account.owner == user_authority.ctx.key);

    // Calculate underlying liquidity using exchange rate
    let liquidity_amount: u64 = collateral_to_liquidity(
        collateral_amount,
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.available_amount);

    // Post-withdrawal health check: remaining collateral must cover borrows
    let mut remaining_deposit: u64 = 0;
    if (user_account.deposited_value > liquidity_amount) {
        remaining_deposit = user_account.deposited_value - liquidity_amount;
    }
    let max_after_withdraw: u64 = (remaining_deposit * reserve.liquidation_threshold as u64) / 100;
    require(user_account.borrowed_value <= max_after_withdraw);

    // Burn aTokens from user
    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, collateral_amount);

    // Transfer liquidity to user
    spl_token::SPLToken::transfer(reserve_liquidity_supply, user_liquidity, market_authority, liquidity_amount);

    reserve.available_amount = reserve.available_amount - liquidity_amount;
    reserve.collateral_mint_supply = reserve.collateral_mint_supply - collateral_amount;
    reserve.last_update_slot = get_clock().slot;
}

// -----------------------------------------------------------------
// 5. borrow -- Borrow against collateral (LTV check)
// -----------------------------------------------------------------

pub borrow(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(user_account.owner == user_authority.ctx.key);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == liquidity_supply.ctx.key);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Enforce borrow limit
    let borrowed_real: u64 = from_wad_lo(reserve.borrowed_amount_wads_lo);
    require(borrowed_real + amount <= reserve.borrow_limit);

    // LTV check
    let new_borrowed_value: u64 = user_account.borrowed_value + amount;
    let ltv_limit: u64 = (user_account.deposited_value * reserve.loan_to_value_ratio as u64) / 100;
    let liquidation_limit: u64 = (user_account.deposited_value * reserve.liquidation_threshold as u64) / 100;

    require(new_borrowed_value <= ltv_limit);
    require(new_borrowed_value <= liquidation_limit);
    require(amount <= reserve.available_amount);

    reserve.available_amount = reserve.available_amount - amount;
    reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo + to_wad_lo(amount);

    user_account.borrowed_value = new_borrowed_value;
    user_account.allowed_borrow_value = ltv_limit;

    spl_token::SPLToken::transfer(liquidity_supply, user_liquidity, market_authority, amount);
}

// -----------------------------------------------------------------
// 6. repay -- Repay borrowed tokens
// -----------------------------------------------------------------

pub repay(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Clamp repay to outstanding borrow
    let mut repay_amount: u64 = amount;
    if (amount > user_account.borrowed_value) {
        repay_amount = user_account.borrowed_value;
    }

    spl_token::SPLToken::transfer(user_liquidity, liquidity_supply, user_authority, repay_amount);

    if (reserve.borrowed_amount_wads_lo >= to_wad_lo(repay_amount)) {
        reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo - to_wad_lo(repay_amount);
    } else {
        reserve.borrowed_amount_wads_lo = 0;
    }
    reserve.available_amount = reserve.available_amount + repay_amount;

    user_account.borrowed_value = user_account.borrowed_value - repay_amount;
}

// -----------------------------------------------------------------
// 7. refresh_reserve -- Accrue interest, update oracle price
// -----------------------------------------------------------------

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
            let new_borrowed_lo: u64 = compound_interest(old_borrowed_lo, borrow_rate, slots_elapsed);

            let interest_wad_lo: u64 = new_borrowed_lo - old_borrowed_lo;
            let interest_real: u64 = from_wad_lo(interest_wad_lo);

            // Protocol fee: 10% of interest to protocol
            let protocol_fee: u64 = interest_real / 10;

            reserve.borrowed_amount_wads_lo = new_borrowed_lo;
            reserve.accumulated_protocol_fees = reserve.accumulated_protocol_fees + protocol_fee;

            // Update cumulative borrow rate
            reserve.cumulative_borrow_rate_lo = update_cumulative_rate(
                reserve.cumulative_borrow_rate_lo,
                borrow_rate,
                slots_elapsed
            );
        }

        reserve.last_update_slot = current_slot;
    }
}

// -----------------------------------------------------------------
// 8. enable_assist -- User opts into auto-deleverage protection
// -----------------------------------------------------------------

pub enable_assist(
    user_account: UserAccount @mut,
    owner: account @signer
) {
    require(user_account.owner == owner.ctx.key);
    require(!user_account.assist_enabled);

    user_account.assist_enabled = true;
    // Set defaults if not already configured
    if (user_account.assist_threshold == 0) {
        user_account.assist_threshold = 110;
    }
    if (user_account.assist_target_health == 0) {
        user_account.assist_target_health = 150;
    }
    if (user_account.assist_fee_bps == 0) {
        user_account.assist_fee_bps = 50;
    }
}

// -----------------------------------------------------------------
// 9. disable_assist -- User opts out
// -----------------------------------------------------------------

pub disable_assist(
    user_account: UserAccount @mut,
    owner: account @signer
) {
    require(user_account.owner == owner.ctx.key);
    require(user_account.assist_enabled);

    user_account.assist_enabled = false;
}

// -----------------------------------------------------------------
// 10. set_assist_threshold -- Set health factor that triggers assist
// -----------------------------------------------------------------

pub set_assist_threshold(
    user_account: UserAccount @mut,
    owner: account @signer,
    threshold: u64,
    target_health: u64
) {
    require(user_account.owner == owner.ctx.key);
    // Threshold must be above 100 (= 1.0x health) to be meaningful
    require(threshold > 100);
    require(threshold <= 200);
    // Target must be above threshold
    require(target_health > threshold);
    require(target_health <= 500);

    user_account.assist_threshold = threshold;
    user_account.assist_target_health = target_health;
}

// -----------------------------------------------------------------
// 11. execute_assist -- Bot triggers auto-deleverage when health drops
// -----------------------------------------------------------------
// Sells collateral to repay borrow, bringing health back to target.
// Anyone can call this (permissionless crank) when conditions are met.

pub execute_assist(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount @mut,
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    executor: account @signer,
    executor_reward_account: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(user_account.assist_enabled);
    require(user_account.borrowed_value > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);

    // Verify oracle freshness
    let now: u64 = get_clock().slot;
    require(now - oracle_state.last_update <= 100);
    require(oracle_state.price > 0);

    // Check health is below assist threshold
    let liq_threshold: u64 = reserve.liquidation_threshold as u64;
    let health: u64 = calculate_health_factor(
        user_account.deposited_value,
        user_account.borrowed_value,
        liq_threshold
    );
    require(health < user_account.assist_threshold);

    // Calculate how much to repay to reach target health
    let repay_amount: u64 = calculate_assist_repay(
        user_account.deposited_value,
        user_account.borrowed_value,
        liq_threshold,
        user_account.assist_target_health
    );
    require(repay_amount > 0);

    // Clamp to outstanding borrow
    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > user_account.borrowed_value) {
        actual_repay = user_account.borrowed_value;
    }

    // Calculate collateral to burn (at 1:1 price, collateral covers repay)
    let collateral_to_sell: u64 = liquidity_to_collateral(
        actual_repay,
        reserve.available_amount,
        reserve.borrowed_amount_wads_lo,
        reserve.collateral_mint_supply
    );
    require(collateral_to_sell > 0);

    // Assist fee goes to executor as incentive
    let assist_fee: u64 = (actual_repay * user_account.assist_fee_bps) / 10000;

    // Burn collateral from user (sells their position)
    spl_token::SPLToken::burn(user_collateral, collateral_mint, market_authority, collateral_to_sell);

    // Repay borrow from reserve liquidity (collateral is converted to repayment)
    // Net effect: user's collateral decreases, borrow decreases, health improves
    if (reserve.borrowed_amount_wads_lo >= to_wad_lo(actual_repay)) {
        reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo - to_wad_lo(actual_repay);
    } else {
        reserve.borrowed_amount_wads_lo = 0;
    }

    reserve.collateral_mint_supply = reserve.collateral_mint_supply - collateral_to_sell;

    // Pay executor fee from reserve liquidity
    if (assist_fee > 0) {
        require(assist_fee <= reserve.available_amount);
        spl_token::SPLToken::transfer(liquidity_supply, executor_reward_account, market_authority, assist_fee);
        reserve.available_amount = reserve.available_amount - assist_fee;
    }

    // Update user account
    if (user_account.borrowed_value >= actual_repay) {
        user_account.borrowed_value = user_account.borrowed_value - actual_repay;
    } else {
        user_account.borrowed_value = 0;
    }

    // Reduce deposited value by collateral sold (priced via oracle)
    let collateral_value: u64 = actual_repay + assist_fee;
    if (user_account.deposited_value >= collateral_value) {
        user_account.deposited_value = user_account.deposited_value - collateral_value;
    } else {
        user_account.deposited_value = 0;
    }

    user_account.last_update_slot = now;
}

// -----------------------------------------------------------------
// 12. set_assist_fee -- Fee charged for assist execution
// -----------------------------------------------------------------

pub set_assist_fee(
    market: Market,
    user_account: UserAccount @mut,
    owner: account @signer,
    fee_bps: u64
) {
    require(user_account.owner == owner.ctx.key);
    require(fee_bps <= 500);

    user_account.assist_fee_bps = fee_bps;
}

// -----------------------------------------------------------------
// 13. create_farm -- Create yield farming pool
// -----------------------------------------------------------------

pub create_farm(
    market: Market,
    farm: Farm @mut @init(payer=admin, space=800),
    admin: account @signer,
    stake_mint: pubkey,
    reward_mint: pubkey,
    reward_vault: pubkey,
    reward_rate: u64
) {
    require(market.admin == admin.ctx.key);
    require(reward_rate > 0);

    farm.market = market.ctx.key;
    farm.admin = admin.ctx.key;
    farm.stake_mint = stake_mint;
    farm.reward_mint = reward_mint;
    farm.reward_vault = reward_vault;
    farm.total_staked = 0;
    farm.reward_per_token_stored = 0;
    farm.last_reward_update_slot = get_clock().slot;
    farm.reward_rate = reward_rate;
    farm.is_active = true;
}

// -----------------------------------------------------------------
// 14. stake -- Stake LP tokens to earn rewards
// -----------------------------------------------------------------

pub stake(
    farm: Farm @mut,
    stake_record: StakeRecord @mut @init(payer=staker, space=400),
    user_stake_token: spl_token::TokenAccount @mut @serializer("raw"),
    farm_stake_vault: spl_token::TokenAccount @mut @serializer("raw"),
    staker: account @signer,
    token_program: account,
    amount: u64
) {
    require(farm.is_active);
    require(amount > 0);

    let current_slot: u64 = get_clock().slot;

    // Update global reward accounting
    let new_reward_per_token: u64 = update_farm_rewards(
        farm.total_staked,
        farm.reward_per_token_stored,
        farm.last_reward_update_slot,
        farm.reward_rate,
        current_slot
    );
    farm.reward_per_token_stored = new_reward_per_token;
    farm.last_reward_update_slot = current_slot;

    // If existing stake record, accumulate pending rewards
    if (stake_record.staked_amount > 0) {
        let pending: u64 = calculate_pending(
            stake_record.staked_amount,
            new_reward_per_token,
            stake_record.reward_debt
        );
        stake_record.pending_rewards = stake_record.pending_rewards + pending;
    } else {
        // New stake record
        stake_record.farm = farm.ctx.key;
        stake_record.owner = staker.ctx.key;
        stake_record.pending_rewards = 0;
    }

    // Transfer LP tokens from user to farm vault
    spl_token::SPLToken::transfer(user_stake_token, farm_stake_vault, staker, amount);

    stake_record.staked_amount = stake_record.staked_amount + amount;
    stake_record.reward_debt = (stake_record.staked_amount * new_reward_per_token) / 1000000000;
    farm.total_staked = farm.total_staked + amount;
}

// -----------------------------------------------------------------
// 15. unstake -- Unstake LP tokens
// -----------------------------------------------------------------

pub unstake(
    farm: Farm @mut,
    stake_record: StakeRecord @mut,
    farm_stake_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_stake_token: spl_token::TokenAccount @mut @serializer("raw"),
    farm_authority: account @signer,
    staker: account @signer,
    token_program: account,
    amount: u64
) {
    require(stake_record.owner == staker.ctx.key);
    require(stake_record.farm == farm.ctx.key);
    require(amount > 0);
    require(amount <= stake_record.staked_amount);

    let current_slot: u64 = get_clock().slot;

    // Update global reward accounting
    let new_reward_per_token: u64 = update_farm_rewards(
        farm.total_staked,
        farm.reward_per_token_stored,
        farm.last_reward_update_slot,
        farm.reward_rate,
        current_slot
    );
    farm.reward_per_token_stored = new_reward_per_token;
    farm.last_reward_update_slot = current_slot;

    // Accumulate pending rewards
    let pending: u64 = calculate_pending(
        stake_record.staked_amount,
        new_reward_per_token,
        stake_record.reward_debt
    );
    stake_record.pending_rewards = stake_record.pending_rewards + pending;

    // Transfer LP tokens back to user
    spl_token::SPLToken::transfer(farm_stake_vault, user_stake_token, farm_authority, amount);

    stake_record.staked_amount = stake_record.staked_amount - amount;
    stake_record.reward_debt = (stake_record.staked_amount * new_reward_per_token) / 1000000000;
    farm.total_staked = farm.total_staked - amount;
}

// -----------------------------------------------------------------
// 16. claim_rewards -- Claim accumulated farming rewards
// -----------------------------------------------------------------

pub claim_rewards(
    farm: Farm @mut,
    stake_record: StakeRecord @mut,
    reward_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_reward_account: spl_token::TokenAccount @mut @serializer("raw"),
    farm_authority: account @signer,
    staker: account @signer,
    token_program: account
) {
    require(stake_record.owner == staker.ctx.key);
    require(stake_record.farm == farm.ctx.key);
    require(reward_vault.ctx.key == farm.reward_vault);

    let current_slot: u64 = get_clock().slot;

    // Update global reward accounting
    let new_reward_per_token: u64 = update_farm_rewards(
        farm.total_staked,
        farm.reward_per_token_stored,
        farm.last_reward_update_slot,
        farm.reward_rate,
        current_slot
    );
    farm.reward_per_token_stored = new_reward_per_token;
    farm.last_reward_update_slot = current_slot;

    // Calculate total claimable
    let pending: u64 = calculate_pending(
        stake_record.staked_amount,
        new_reward_per_token,
        stake_record.reward_debt
    );
    let total_claimable: u64 = stake_record.pending_rewards + pending;
    require(total_claimable > 0);

    // Transfer rewards to user
    spl_token::SPLToken::transfer(reward_vault, user_reward_account, farm_authority, total_claimable);

    stake_record.pending_rewards = 0;
    stake_record.reward_debt = (stake_record.staked_amount * new_reward_per_token) / 1000000000;
}

// -----------------------------------------------------------------
// 17. compound -- Auto-reinvest rewards back into position
// -----------------------------------------------------------------
// Converts earned rewards into additional stake. In a real deployment this
// would route through a DEX to swap reward_mint -> stake_mint. Here we
// model the simplified case where reward_mint == stake_mint (single-sided).

pub compound(
    farm: Farm @mut,
    stake_record: StakeRecord @mut,
    reward_vault: spl_token::TokenAccount @mut @serializer("raw"),
    farm_stake_vault: spl_token::TokenAccount @mut @serializer("raw"),
    farm_authority: account @signer,
    staker: account @signer,
    token_program: account
) {
    require(farm.is_active);
    require(stake_record.owner == staker.ctx.key);
    require(stake_record.farm == farm.ctx.key);
    require(reward_vault.ctx.key == farm.reward_vault);

    let current_slot: u64 = get_clock().slot;

    // Update global reward accounting
    let new_reward_per_token: u64 = update_farm_rewards(
        farm.total_staked,
        farm.reward_per_token_stored,
        farm.last_reward_update_slot,
        farm.reward_rate,
        current_slot
    );
    farm.reward_per_token_stored = new_reward_per_token;
    farm.last_reward_update_slot = current_slot;

    // Calculate total claimable
    let pending: u64 = calculate_pending(
        stake_record.staked_amount,
        new_reward_per_token,
        stake_record.reward_debt
    );
    let total_claimable: u64 = stake_record.pending_rewards + pending;
    require(total_claimable > 0);

    // Re-stake rewards: transfer from reward vault to stake vault
    spl_token::SPLToken::transfer(reward_vault, farm_stake_vault, farm_authority, total_claimable);

    // Update staking state
    stake_record.staked_amount = stake_record.staked_amount + total_claimable;
    stake_record.pending_rewards = 0;
    stake_record.reward_debt = (stake_record.staked_amount * new_reward_per_token) / 1000000000;
    farm.total_staked = farm.total_staked + total_claimable;
}

// -----------------------------------------------------------------
// 18. liquidate -- Standard liquidation with bonus
// -----------------------------------------------------------------

pub liquidate(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount @mut,
    liquidator_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(repay_amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);

    let current_slot: u64 = get_clock().slot;

    // Accrue interest before liquidation
    let slots_elapsed: u64 = current_slot - reserve.last_update_slot;
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
            let new_borrowed_lo: u64 = compound_interest(old_borrowed_lo, borrow_rate, slots_elapsed);
            let interest_wad_lo: u64 = new_borrowed_lo - old_borrowed_lo;
            let interest_real: u64 = from_wad_lo(interest_wad_lo);
            let protocol_fee: u64 = interest_real / 10;

            reserve.borrowed_amount_wads_lo = new_borrowed_lo;
            reserve.accumulated_protocol_fees = reserve.accumulated_protocol_fees + protocol_fee;
            reserve.cumulative_borrow_rate_lo = update_cumulative_rate(
                reserve.cumulative_borrow_rate_lo,
                borrow_rate,
                slots_elapsed
            );
        }
        reserve.last_update_slot = current_slot;
    }

    // Verify oracle freshness
    require(current_slot - oracle_state.last_update <= 100);
    require(oracle_state.price > 0);

    // Check position is liquidatable
    let liquidation_limit: u64 = (user_account.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(user_account.borrowed_value > liquidation_limit);

    // 50% close factor: cannot liquidate more than half
    let max_repay: u64 = user_account.borrowed_value / 2;
    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > max_repay) {
        actual_repay = max_repay;
    }
    if (actual_repay > user_account.borrowed_value) {
        actual_repay = user_account.borrowed_value;
    }

    // Liquidator repays debt
    spl_token::SPLToken::transfer(liquidator_liquidity, liquidity_supply, liquidator, actual_repay);

    // Liquidator receives collateral + bonus
    let collateral_to_seize: u64 = (actual_repay * (100 + reserve.liquidation_bonus as u64)) / 100;
    spl_token::SPLToken::transfer(user_collateral, liquidator_liquidity, market_authority, collateral_to_seize);

    // Update reserve
    if (reserve.borrowed_amount_wads_lo >= to_wad_lo(actual_repay)) {
        reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo - to_wad_lo(actual_repay);
    } else {
        reserve.borrowed_amount_wads_lo = 0;
    }
    reserve.available_amount = reserve.available_amount + actual_repay;

    // Update user account
    if (user_account.borrowed_value >= actual_repay) {
        user_account.borrowed_value = user_account.borrowed_value - actual_repay;
    } else {
        user_account.borrowed_value = 0;
    }
    if (user_account.deposited_value >= collateral_to_seize) {
        user_account.deposited_value = user_account.deposited_value - collateral_to_seize;
    } else {
        user_account.deposited_value = 0;
    }
}

// -----------------------------------------------------------------
// 19. flash_liquidate -- Flash loan + liquidation in one tx
// -----------------------------------------------------------------
// Liquidator borrows from the reserve, liquidates, repays in same tx.
// No upfront capital needed. Flash loan fee applies.

pub flash_liquidate(
    market: Market,
    reserve: Reserve @mut,
    user_account: UserAccount @mut,
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    flash_borrower_account: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(repay_amount > 0);
    require(reserve.market == market.ctx.key);
    require(reserve.liquidity_supply_vault == liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);

    let current_slot: u64 = get_clock().slot;

    // Verify oracle freshness
    require(current_slot - oracle_state.last_update <= 100);
    require(oracle_state.price > 0);

    // Check position is liquidatable
    let liquidation_limit: u64 = (user_account.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(user_account.borrowed_value > liquidation_limit);

    // 50% close factor
    let max_repay: u64 = user_account.borrowed_value / 2;
    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > max_repay) {
        actual_repay = max_repay;
    }
    if (actual_repay > user_account.borrowed_value) {
        actual_repay = user_account.borrowed_value;
    }

    // Flash borrow from reserve
    require(actual_repay <= reserve.available_amount);
    spl_token::SPLToken::transfer(liquidity_supply, flash_borrower_account, market_authority, actual_repay);

    // Flash loan fee (30 bps default, minimum 1 token)
    let mut flash_fee: u64 = (actual_repay * 30) / 10000;
    if (flash_fee == 0) {
        flash_fee = 1;
    }

    // Liquidate: seize collateral with bonus
    let collateral_to_seize: u64 = (actual_repay * (100 + reserve.liquidation_bonus as u64)) / 100;
    spl_token::SPLToken::transfer(user_collateral, flash_borrower_account, market_authority, collateral_to_seize);

    // Repay flash loan + fee back to reserve
    let total_repay_flash: u64 = actual_repay + flash_fee;
    spl_token::SPLToken::transfer(flash_borrower_account, liquidity_supply, liquidator, total_repay_flash);

    // Update reserve state
    if (reserve.borrowed_amount_wads_lo >= to_wad_lo(actual_repay)) {
        reserve.borrowed_amount_wads_lo = reserve.borrowed_amount_wads_lo - to_wad_lo(actual_repay);
    } else {
        reserve.borrowed_amount_wads_lo = 0;
    }
    reserve.available_amount = reserve.available_amount + actual_repay + flash_fee;
    reserve.accumulated_protocol_fees = reserve.accumulated_protocol_fees + flash_fee;

    // Update user account
    if (user_account.borrowed_value >= actual_repay) {
        user_account.borrowed_value = user_account.borrowed_value - actual_repay;
    } else {
        user_account.borrowed_value = 0;
    }
    if (user_account.deposited_value >= collateral_to_seize) {
        user_account.deposited_value = user_account.deposited_value - collateral_to_seize;
    } else {
        user_account.deposited_value = 0;
    }
}

// -----------------------------------------------------------------
// 20. set_oracle -- Update price oracle
// -----------------------------------------------------------------

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

pub set_oracle(
    oracle: PriceOracle @mut,
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

// -----------------------------------------------------------------
// 21. set_authority -- Transfer market admin
// -----------------------------------------------------------------

pub set_authority(
    market: Market @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(market.admin == admin.ctx.key);
    market.admin = new_admin;
}

// -----------------------------------------------------------------
// 22. pause / unpause -- Emergency controls
// -----------------------------------------------------------------

pub pause(
    market: Market @mut,
    admin: account @signer
) {
    require(market.admin == admin.ctx.key);
    require(!market.is_paused);
    market.is_paused = true;
}

pub unpause(
    market: Market @mut,
    admin: account @signer
) {
    require(market.admin == admin.ctx.key);
    require(market.is_paused);
    market.is_paused = false;
}

// -----------------------------------------------------------------
// 23. collect_protocol_fees -- Withdraw accumulated protocol fees
// -----------------------------------------------------------------

pub collect_protocol_fees(
    reserve: Reserve @mut,
    market: Market @mut,
    admin: account @signer,
    fee_recipient: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    token_program: account
) {
    require(market.admin == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.accumulated_protocol_fees > 0);
    require(reserve.available_amount >= reserve.accumulated_protocol_fees);

    let fees: u64 = reserve.accumulated_protocol_fees;
    reserve.accumulated_protocol_fees = 0;
    reserve.available_amount = reserve.available_amount - fees;

    spl_token::SPLToken::transfer(liquidity_supply, fee_recipient, market_authority, fees);

    market.protocol_fees_collected = market.protocol_fees_collected + fees;
}

// -----------------------------------------------------------------
// Init user account
// -----------------------------------------------------------------

pub init_user_account(
    market: Market,
    user_account: UserAccount @mut @init(payer=owner, space=2000),
    owner: account @signer
) {
    require(!market.is_paused);
    user_account.market = market.ctx.key;
    user_account.owner = owner.ctx.key;
    user_account.last_update_slot = get_clock().slot;

    user_account.deposited_value = 0;
    user_account.borrowed_value = 0;
    user_account.allowed_borrow_value = 0;
    user_account.unhealthy_borrow_value = 0;

    user_account.num_deposits = 0;
    user_account.num_borrows = 0;

    // Zero all deposit slots
    user_account.deposit_amount_1 = 0;
    user_account.deposit_market_value_1 = 0;
    user_account.deposit_amount_2 = 0;
    user_account.deposit_market_value_2 = 0;
    user_account.deposit_amount_3 = 0;
    user_account.deposit_market_value_3 = 0;

    // Zero all borrow slots
    user_account.borrow_amount_wads_lo_1 = 0;
    user_account.borrow_market_value_1 = 0;
    user_account.borrow_amount_wads_lo_2 = 0;
    user_account.borrow_market_value_2 = 0;
    user_account.borrow_amount_wads_lo_3 = 0;
    user_account.borrow_market_value_3 = 0;

    // Apricot Assist defaults (disabled)
    user_account.assist_enabled = false;
    user_account.assist_threshold = 110;
    user_account.assist_target_health = 150;
    user_account.assist_fee_bps = 50;
}

// -----------------------------------------------------------------
// Refresh user account (recalculate health from reserve prices)
// -----------------------------------------------------------------

pub refresh_user_account(
    market: Market,
    user_account: UserAccount @mut,
    reserve: Reserve,
    owner: account @signer
) {
    require(!market.is_paused);
    require(user_account.market == market.ctx.key);
    require(user_account.owner == owner.ctx.key);
    require(reserve.market == market.ctx.key);
    require(reserve.market_price > 0);

    let price: u64 = reserve.market_price;
    let ltv: u64 = reserve.loan_to_value_ratio as u64;
    let liq_threshold: u64 = reserve.liquidation_threshold as u64;
    let weight: u64 = reserve.collateral_weight as u64;
    let reserve_key: pubkey = reserve.ctx.key;

    // Recalculate deposit slot values for this reserve
    let mut total_deposited: u64 = 0;
    let mut total_allowed: u64 = 0;
    let mut total_unhealthy: u64 = 0;

    // Slot 1
    if (user_account.deposit_amount_1 > 0) {
        if (user_account.deposit_reserve_1 == reserve_key) {
            let value: u64 = (user_account.deposit_amount_1 * price * weight) / (1000000 * 100);
            user_account.deposit_market_value_1 = value;
        }
        total_deposited = total_deposited + user_account.deposit_market_value_1;
    }

    // Slot 2
    if (user_account.deposit_amount_2 > 0) {
        if (user_account.deposit_reserve_2 == reserve_key) {
            let value: u64 = (user_account.deposit_amount_2 * price * weight) / (1000000 * 100);
            user_account.deposit_market_value_2 = value;
        }
        total_deposited = total_deposited + user_account.deposit_market_value_2;
    }

    // Slot 3
    if (user_account.deposit_amount_3 > 0) {
        if (user_account.deposit_reserve_3 == reserve_key) {
            let value: u64 = (user_account.deposit_amount_3 * price * weight) / (1000000 * 100);
            user_account.deposit_market_value_3 = value;
        }
        total_deposited = total_deposited + user_account.deposit_market_value_3;
    }

    // Recalculate borrow slot values
    let mut total_borrowed: u64 = 0;

    // Borrow slot 1
    if (user_account.borrow_amount_wads_lo_1 > 0) {
        if (user_account.borrow_reserve_1 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(user_account.borrow_amount_wads_lo_1);
            let value: u64 = (borrow_real * price) / 1000000;
            user_account.borrow_market_value_1 = value;
        }
        total_borrowed = total_borrowed + user_account.borrow_market_value_1;
    }

    // Borrow slot 2
    if (user_account.borrow_amount_wads_lo_2 > 0) {
        if (user_account.borrow_reserve_2 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(user_account.borrow_amount_wads_lo_2);
            let value: u64 = (borrow_real * price) / 1000000;
            user_account.borrow_market_value_2 = value;
        }
        total_borrowed = total_borrowed + user_account.borrow_market_value_2;
    }

    // Borrow slot 3
    if (user_account.borrow_amount_wads_lo_3 > 0) {
        if (user_account.borrow_reserve_3 == reserve_key) {
            let borrow_real: u64 = from_wad_lo(user_account.borrow_amount_wads_lo_3);
            let value: u64 = (borrow_real * price) / 1000000;
            user_account.borrow_market_value_3 = value;
        }
        total_borrowed = total_borrowed + user_account.borrow_market_value_3;
    }

    // Update aggregated values
    user_account.deposited_value = total_deposited;
    user_account.borrowed_value = total_borrowed;
    user_account.allowed_borrow_value = (total_deposited * ltv) / 100;
    user_account.unhealthy_borrow_value = (total_deposited * liq_threshold) / 100;
    user_account.last_update_slot = get_clock().slot;
}

// -----------------------------------------------------------------
// Set reserve config
// -----------------------------------------------------------------

pub set_reserve_config(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    new_optimal_utilization: u8,
    new_ltv: u8,
    new_liquidation_threshold: u8,
    new_liquidation_bonus: u8,
    new_min_borrow_rate: u8,
    new_optimal_borrow_rate: u8,
    new_max_borrow_rate: u8,
    new_collateral_weight: u8,
    new_deposit_limit: u64,
    new_borrow_limit: u64
) {
    require(market.admin == admin.ctx.key);
    require(reserve.market == market.ctx.key);
    require(new_ltv > 0);
    require(new_ltv < 100);
    require(new_liquidation_threshold > new_ltv);
    require(new_liquidation_threshold <= 100);
    require(new_liquidation_bonus <= 25);
    require(new_optimal_utilization <= 100);
    require(new_min_borrow_rate <= new_optimal_borrow_rate);
    require(new_optimal_borrow_rate <= new_max_borrow_rate);
    require(new_collateral_weight <= 100);

    reserve.optimal_utilization_rate = new_optimal_utilization;
    reserve.loan_to_value_ratio = new_ltv;
    reserve.liquidation_threshold = new_liquidation_threshold;
    reserve.liquidation_bonus = new_liquidation_bonus;
    reserve.min_borrow_rate = new_min_borrow_rate;
    reserve.optimal_borrow_rate = new_optimal_borrow_rate;
    reserve.max_borrow_rate = new_max_borrow_rate;
    reserve.collateral_weight = new_collateral_weight;
    reserve.deposit_limit = new_deposit_limit;
    reserve.borrow_limit = new_borrow_limit;
}

// -----------------------------------------------------------------
// Read-only views
// -----------------------------------------------------------------

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
    let borrowed: u64 = from_wad_lo(reserve.borrowed_amount_wads_lo);
    let total_liquidity: u64 = reserve.available_amount + borrowed;
    if (reserve.collateral_mint_supply == 0) {
        return 1000000000;
    }
    return (total_liquidity * 1000000000) / reserve.collateral_mint_supply;
}

pub get_health_factor(user_account: UserAccount, reserve: Reserve) -> u64 {
    return calculate_health_factor(
        user_account.deposited_value,
        user_account.borrowed_value,
        reserve.liquidation_threshold as u64
    );
}

pub get_total_liquidity(reserve: Reserve) -> u64 {
    let borrowed: u64 = from_wad_lo(reserve.borrowed_amount_wads_lo);
    return reserve.available_amount + borrowed;
}

pub get_assist_status(user_account: UserAccount) -> u64 {
    if (user_account.assist_enabled) {
        return 1;
    }
    return 0;
}
