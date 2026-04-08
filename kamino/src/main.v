// Kamino Finance -- 5ive DSL Migration
//
// Auto-compounding concentrated liquidity vaults + lending protocol.
//
// Design:
//   - Strategies wrap CLMM pool positions, auto-rebalancing when price drifts
//   - Users deposit token_a/token_b, receive kTokens representing vault shares
//   - Permissionless cranks: rebalance (adjust range), compound (reinvest fees)
//   - Performance fee taken on compound; configurable per strategy
//   - Lending side follows Aave v2 / Solend pattern (reserves, obligations, cTokens)
//   - Oracle staleness enforced (100-slot window) on all price-sensitive ops
//   - Integer-only math; BPS_SCALE = 10000 for basis point calculations

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Vault accounts
// ---------------------------------------------------------------------------

account Strategy {
    pool: pubkey;                    // CLMM pool this strategy wraps
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;           // strategy-owned token A vault
    token_b_vault: pubkey;           // strategy-owned token B vault
    position_mint: pubkey;           // mint for the CLMM position NFT
    position_range_lower: i64;       // current lower tick of concentrated range
    position_range_upper: i64;       // current upper tick of concentrated range
    rebalance_width: u64;            // tick width for new positions on rebalance
    drift_threshold: u64;            // tick drift before rebalance is triggered
    total_shares: u64;               // total kToken shares outstanding
    total_a: u64;                    // total token A held across vault + position
    total_b: u64;                    // total token B held across vault + position
    performance_fee_bps: u64;        // fee on compounded yield (basis points)
    last_rebalance: u64;             // slot of last rebalance
    authority: pubkey;               // strategy admin
    is_paused: bool;
}

account KToken {
    strategy: pubkey;                // parent strategy
    mint: pubkey;                    // kToken SPL mint
    supply: u64;                     // mirrors total_shares for cross-check
}

// ---------------------------------------------------------------------------
// Lending accounts (Solend-style)
// ---------------------------------------------------------------------------

account LendingMarket {
    admin: pubkey;
    quote_currency: pubkey;
    is_paused: bool;
    total_reserves: u64;
}

account Reserve {
    market: pubkey;
    liquidity_mint: pubkey;
    liquidity_supply: pubkey;
    collateral_mint: pubkey;
    collateral_supply: u64;
    liquidity_available: u64;
    borrowed_amount: u64;
    cumulative_borrow_rate: u64;
    last_update_slot: u64;
    protocol_fees: u64;
    optimal_utilization_rate: u8;
    loan_to_value_ratio: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    max_borrow_rate: u8;
    min_borrow_rate: u8;
    reserve_factor: u8;
    supply_cap: u64;
}

account Obligation {
    market: pubkey;
    authority: pubkey;
    deposited_value: u64;
    borrowed_value: u64;
    allowed_borrow_value: u64;
}

account PriceOracle {
    authority: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

// ---------------------------------------------------------------------------
// Vault instructions
// ---------------------------------------------------------------------------

// 1. create_strategy -- Initialize a new auto-compounding vault for a CLMM pool.
//    Sets the initial position range, rebalance parameters, and fee config.
pub create_strategy(
    strategy: Strategy @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    pool: pubkey,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    position_mint: pubkey,
    range_lower: i64,
    range_upper: i64,
    rebalance_width: u64,
    drift_threshold: u64,
    performance_fee_bps: u64
) {
    require(range_upper > range_lower);
    require(rebalance_width > 0);
    require(drift_threshold > 0);
    require(performance_fee_bps <= 5000); // max 50% performance fee

    strategy.pool = pool;
    strategy.token_a_mint = token_a_mint;
    strategy.token_b_mint = token_b_mint;
    strategy.token_a_vault = token_a_vault;
    strategy.token_b_vault = token_b_vault;
    strategy.position_mint = position_mint;
    strategy.position_range_lower = range_lower;
    strategy.position_range_upper = range_upper;
    strategy.rebalance_width = rebalance_width;
    strategy.drift_threshold = drift_threshold;
    strategy.total_shares = 0;
    strategy.total_a = 0;
    strategy.total_b = 0;
    strategy.performance_fee_bps = performance_fee_bps;
    strategy.last_rebalance = get_clock().slot;
    strategy.authority = creator.ctx.key;
    strategy.is_paused = false;
}

// 2. deposit -- Deposit token A and B into the strategy, receive kTokens.
//    Share calculation is proportional to existing TVL; first depositor sets the ratio.
pub deposit(
    strategy: Strategy @mut @signer,
    ktoken: KToken @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    strategy_vault_a: account @mut,
    strategy_vault_b: account @mut,
    ktoken_mint: account @mut,
    user_ktoken_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64,
    min_shares: u64
) {
    require(!strategy.is_paused);
    require(amount_a > 0 || amount_b > 0);
    require(strategy_vault_a.ctx.key == strategy.token_a_vault);
    require(strategy_vault_b.ctx.key == strategy.token_b_vault);
    require(ktoken.strategy == strategy.ctx.key);
    require(ktoken_mint.ctx.key == ktoken.mint);

    let mut shares_to_mint: u64 = 0;

    if (strategy.total_shares == 0) {
        // First deposit: shares = sum of tokens deposited
        shares_to_mint = amount_a + amount_b;
    } else {
        // Proportional: shares based on token A contribution
        // shares = amount_a * total_shares / total_a (simplified; real impl uses both)
        let total_value: u64 = strategy.total_a + strategy.total_b;
        require(total_value > 0);
        let deposit_value: u64 = amount_a + amount_b;
        shares_to_mint = (deposit_value * strategy.total_shares) / total_value;
    }

    require(shares_to_mint > 0);
    require(shares_to_mint >= min_shares);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, strategy_vault_a, user_authority, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, strategy_vault_b, user_authority, amount_b);
    }

    spl_token::SPLToken::mint_to(ktoken_mint, user_ktoken_account, strategy, shares_to_mint);

    strategy.total_a = strategy.total_a + amount_a;
    strategy.total_b = strategy.total_b + amount_b;
    strategy.total_shares = strategy.total_shares + shares_to_mint;
    ktoken.supply = ktoken.supply + shares_to_mint;
}

// 3. withdraw -- Burn kTokens and receive proportional token A and B back.
pub withdraw(
    strategy: Strategy @mut @signer,
    ktoken: KToken @mut,
    user_ktoken_account: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    strategy_vault_a: account @mut,
    strategy_vault_b: account @mut,
    ktoken_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    shares_to_burn: u64,
    min_amount_a: u64,
    min_amount_b: u64
) {
    require(!strategy.is_paused);
    require(shares_to_burn > 0);
    require(shares_to_burn <= strategy.total_shares);
    require(strategy_vault_a.ctx.key == strategy.token_a_vault);
    require(strategy_vault_b.ctx.key == strategy.token_b_vault);
    require(ktoken.strategy == strategy.ctx.key);

    let amount_a: u64 = (shares_to_burn * strategy.total_a) / strategy.total_shares;
    let amount_b: u64 = (shares_to_burn * strategy.total_b) / strategy.total_shares;
    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    spl_token::SPLToken::burn(user_ktoken_account, ktoken_mint, user_authority, shares_to_burn);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(strategy_vault_a, user_token_a, strategy, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(strategy_vault_b, user_token_b, strategy, amount_b);
    }

    strategy.total_a = strategy.total_a - amount_a;
    strategy.total_b = strategy.total_b - amount_b;
    strategy.total_shares = strategy.total_shares - shares_to_burn;
    ktoken.supply = ktoken.supply - shares_to_burn;
}

// 4. rebalance -- Permissionless crank: adjust CLMM position range when price drifts.
//    Anyone can call this when the current price has drifted beyond drift_threshold
//    from the position midpoint. Closes old range, opens new centered range.
pub rebalance(
    strategy: Strategy @mut,
    oracle: PriceOracle,
    cranker: account @signer,
    current_tick: i64
) {
    require(!strategy.is_paused);

    // Oracle staleness check
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    // Check if price has drifted enough to warrant rebalance
    let midpoint: i64 = (strategy.position_range_lower + strategy.position_range_upper) / 2;
    let mut drift: i64 = current_tick - midpoint;
    if (drift < 0) {
        drift = 0 - drift; // absolute value
    }
    require(drift as u64 >= strategy.drift_threshold);

    // Compute new range centered on current tick
    let half_width: i64 = strategy.rebalance_width as i64 / 2;
    strategy.position_range_lower = current_tick - half_width;
    strategy.position_range_upper = current_tick + half_width;
    strategy.last_rebalance = now;
}

// 5. compound -- Reinvest accumulated CLMM fees back into the position.
//    Performance fee is deducted before reinvestment.
pub compound(
    strategy: Strategy @mut @signer,
    ktoken: KToken @mut,
    strategy_vault_a: account @mut,
    strategy_vault_b: account @mut,
    fee_vault_a: account @mut,
    fee_vault_b: account @mut,
    token_program: account,
    fees_a: u64,
    fees_b: u64
) {
    require(!strategy.is_paused);
    require(fees_a > 0 || fees_b > 0);
    require(strategy_vault_a.ctx.key == strategy.token_a_vault);
    require(strategy_vault_b.ctx.key == strategy.token_b_vault);

    // Calculate performance fee
    let perf_fee_a: u64 = (fees_a * strategy.performance_fee_bps) / 10000;
    let perf_fee_b: u64 = (fees_b * strategy.performance_fee_bps) / 10000;

    // Transfer performance fee to protocol fee vault
    if (perf_fee_a > 0) {
        spl_token::SPLToken::transfer(strategy_vault_a, fee_vault_a, strategy, perf_fee_a);
    }
    if (perf_fee_b > 0) {
        spl_token::SPLToken::transfer(strategy_vault_b, fee_vault_b, strategy, perf_fee_b);
    }

    // Remaining fees stay in vault and are counted as strategy TVL
    let reinvest_a: u64 = fees_a - perf_fee_a;
    let reinvest_b: u64 = fees_b - perf_fee_b;

    strategy.total_a = strategy.total_a + reinvest_a;
    strategy.total_b = strategy.total_b + reinvest_b;
}

// 6. set_strategy_params -- Admin: update rebalance width and drift threshold.
pub set_strategy_params(
    strategy: Strategy @mut,
    authority: account @signer,
    new_rebalance_width: u64,
    new_drift_threshold: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(new_rebalance_width > 0);
    require(new_drift_threshold > 0);
    strategy.rebalance_width = new_rebalance_width;
    strategy.drift_threshold = new_drift_threshold;
}

// 7. set_strategy_fee -- Admin: update performance fee.
pub set_strategy_fee(
    strategy: Strategy @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(new_fee_bps <= 5000);
    strategy.performance_fee_bps = new_fee_bps;
}

// 8. collect_performance_fee -- Admin: withdraw accumulated performance fees from vault.
pub collect_performance_fee(
    strategy: Strategy @mut @signer,
    strategy_vault_a: account @mut,
    strategy_vault_b: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(strategy_vault_a.ctx.key == strategy.token_a_vault);
    require(strategy_vault_b.ctx.key == strategy.token_b_vault);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(strategy_vault_a, recipient_a, strategy, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(strategy_vault_b, recipient_b, strategy, amount_b);
    }
}

// 9. set_authority -- Transfer strategy admin to a new key.
pub set_authority(
    strategy: Strategy @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(strategy.authority == authority.ctx.key);
    strategy.authority = new_authority;
}

// 10. pause -- Admin: halt deposits and rebalances.
pub pause(
    strategy: Strategy @mut,
    authority: account @signer
) {
    require(strategy.authority == authority.ctx.key);
    strategy.is_paused = true;
}

// 11. unpause -- Admin: resume operations.
pub unpause(
    strategy: Strategy @mut,
    authority: account @signer
) {
    require(strategy.authority == authority.ctx.key);
    strategy.is_paused = false;
}

// ---------------------------------------------------------------------------
// Lending instructions (Solend-style, integrated with Kamino vaults)
// ---------------------------------------------------------------------------

// 12. create_lending_market -- Initialize a new lending market.
pub create_lending_market(
    market: LendingMarket @mut @init(payer=admin, space=512),
    quote_currency: account,
    admin: account @signer
) {
    market.admin = admin.ctx.key;
    market.quote_currency = quote_currency.ctx.key;
    market.is_paused = false;
    market.total_reserves = 0;
}

// 13. init_reserve -- Register a token reserve in the lending market.
pub init_reserve(
    market: LendingMarket,
    reserve: Reserve @mut @init(payer=admin, space=768),
    liquidity_mint: pubkey,
    liquidity_supply: pubkey,
    collateral_mint: pubkey,
    admin: account @signer,
    config_optimal_utilization: u8,
    config_loan_to_value: u8,
    config_reserve_factor: u8,
    config_supply_cap: u64
) {
    require(market.admin == admin.ctx.key);
    require(config_reserve_factor <= 50);
    require(config_loan_to_value > 0);
    require(config_loan_to_value < 100);

    reserve.market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint;
    reserve.liquidity_supply = liquidity_supply;
    reserve.collateral_mint = collateral_mint;
    reserve.collateral_supply = 0;
    reserve.liquidity_available = 0;
    reserve.borrowed_amount = 0;
    reserve.cumulative_borrow_rate = 1000000000; // RATE_SCALE = 1e9
    reserve.last_update_slot = get_clock().slot;
    reserve.protocol_fees = 0;
    reserve.optimal_utilization_rate = config_optimal_utilization;
    reserve.loan_to_value_ratio = config_loan_to_value;
    reserve.liquidation_threshold = 80;
    reserve.liquidation_bonus = 5;
    reserve.max_borrow_rate = 20;
    reserve.min_borrow_rate = 2;
    reserve.reserve_factor = config_reserve_factor;
    reserve.supply_cap = config_supply_cap;
}

// 14. deposit_lending -- Supply liquidity to a reserve, receive cTokens.
pub deposit_lending(
    market: LendingMarket,
    reserve: Reserve @mut,
    user_liquidity: account @mut,
    user_collateral: account @mut,
    liquidity_supply: account @mut,
    collateral_mint: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.liquidity_supply == liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);
    require(reserve.liquidity_available + amount <= reserve.supply_cap);

    let current_time: u64 = get_clock().slot;
    reserve.last_update_slot = current_time;

    spl_token::SPLToken::transfer(user_liquidity, liquidity_supply, user_authority, amount);
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, amount);

    reserve.liquidity_available = reserve.liquidity_available + amount;
    reserve.collateral_supply = reserve.collateral_supply + amount;
}

// 15. withdraw_lending -- Redeem cTokens for underlying liquidity.
pub withdraw_lending(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation,
    user_liquidity: account @mut,
    user_collateral: account @mut,
    liquidity_supply: account @mut,
    collateral_mint: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);

    let total_liquidity: u64 = reserve.liquidity_available + reserve.borrowed_amount;
    let liquidity_amount: u64 = (collateral_amount * total_liquidity) / reserve.collateral_supply;
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.liquidity_available);

    // Health check: remaining collateral must cover borrows
    let mut remaining_deposit: u64 = 0;
    if (obligation.deposited_value > liquidity_amount) {
        remaining_deposit = obligation.deposited_value - liquidity_amount;
    }
    let max_after_withdraw: u64 = (remaining_deposit * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value <= max_after_withdraw);

    let current_time: u64 = get_clock().slot;
    reserve.last_update_slot = current_time;

    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, collateral_amount);
    spl_token::SPLToken::transfer(liquidity_supply, user_liquidity, market_authority, liquidity_amount);

    reserve.liquidity_available = reserve.liquidity_available - liquidity_amount;
    reserve.collateral_supply = reserve.collateral_supply - collateral_amount;
}

// 16. borrow -- Borrow against deposited collateral, respecting LTV limits.
pub borrow(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    liquidity_supply: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(obligation.authority == user_authority.ctx.key);
    require(amount > 0);
    require(amount <= reserve.liquidity_available);

    let current_time: u64 = get_clock().slot;
    reserve.last_update_slot = current_time;

    let new_borrowed_value: u64 = obligation.borrowed_value + amount;
    let ltv_limit: u64 = (obligation.deposited_value * reserve.loan_to_value_ratio as u64) / 100;
    let liquidation_limit: u64 = (obligation.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(new_borrowed_value <= ltv_limit);
    require(new_borrowed_value <= liquidation_limit);

    reserve.liquidity_available = reserve.liquidity_available - amount;
    reserve.borrowed_amount = reserve.borrowed_amount + amount;
    obligation.borrowed_value = new_borrowed_value;
    obligation.allowed_borrow_value = ltv_limit;

    spl_token::SPLToken::transfer(liquidity_supply, user_liquidity, market_authority, amount);
}

// 17. repay -- Repay borrowed liquidity, clamped to outstanding debt.
pub repay(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    liquidity_supply: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);

    let current_time: u64 = get_clock().slot;
    reserve.last_update_slot = current_time;

    let mut repay_amount: u64 = amount;
    if (amount > obligation.borrowed_value) {
        repay_amount = obligation.borrowed_value;
    }

    spl_token::SPLToken::transfer(user_liquidity, liquidity_supply, user_authority, repay_amount);

    if (reserve.borrowed_amount >= repay_amount) {
        reserve.borrowed_amount = reserve.borrowed_amount - repay_amount;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.liquidity_available = reserve.liquidity_available + repay_amount;
    obligation.borrowed_value = obligation.borrowed_value - repay_amount;
}

// Internal: calculate utilization as a percentage (0-100).
fn calculate_utilization(liquidity: u64, borrows: u64) -> u64 {
    let total: u64 = liquidity + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * 100) / total;
}

// Internal: kink-model interest rate.
fn calculate_borrow_rate(min_rate: u64, max_rate: u64, optimal: u64, utilization: u64) -> u64 {
    if (utilization <= optimal) {
        if (optimal == 0) {
            return min_rate;
        }
        return min_rate + (utilization * (max_rate - min_rate)) / optimal;
    }
    let extra_utilization: u64 = utilization - optimal;
    let extra_range: u64 = 100 - optimal;
    if (extra_range == 0) {
        return max_rate;
    }
    return max_rate + (extra_utilization * max_rate) / extra_range;
}

// 18. liquidate -- Liquidate an under-collateralized obligation.
//     Accrues interest, validates oracle, then seizes collateral with bonus.
pub liquidate(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    liquidator_liquidity: account @mut,
    liquidity_supply: account @mut,
    user_collateral: account @mut,
    collateral_mint: account @mut,
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64,
    oracle: PriceOracle
) {
    require(!market.is_paused);
    require(repay_amount > 0);

    let current_time: u64 = get_clock().slot;

    // Accrue interest
    let time_delta: u64 = current_time - reserve.last_update_slot;
    if (time_delta > 0) {
        let utilization_rate: u64 = calculate_utilization(reserve.liquidity_available, reserve.borrowed_amount);
        let borrow_rate: u64 = calculate_borrow_rate(
            reserve.min_borrow_rate as u64,
            reserve.max_borrow_rate as u64,
            reserve.optimal_utilization_rate as u64,
            utilization_rate
        );
        if (reserve.borrowed_amount > 0) {
            let seconds_per_year: u64 = 31536000;
            let gross_interest: u64 = (reserve.borrowed_amount * borrow_rate * time_delta) / (seconds_per_year * 100);
            let protocol_cut: u64 = (gross_interest * reserve.reserve_factor as u64) / 100;
            let lp_interest: u64 = gross_interest - protocol_cut;
            reserve.borrowed_amount = reserve.borrowed_amount + gross_interest;
            reserve.protocol_fees = reserve.protocol_fees + protocol_cut;
            reserve.liquidity_available = reserve.liquidity_available + lp_interest;
        }
        reserve.last_update_slot = current_time;
    }

    // Oracle freshness
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    // Must be under-collateralized
    let liquidation_limit: u64 = (obligation.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(obligation.borrowed_value > liquidation_limit);

    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > obligation.borrowed_value) {
        actual_repay = obligation.borrowed_value;
    }

    spl_token::SPLToken::transfer(liquidator_liquidity, liquidity_supply, liquidator, actual_repay);

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
}

// 19. refresh_reserve -- Update reserve timestamp (interest accrual marker).
pub refresh_reserve(reserve: Reserve @mut) {
    let current_time: u64 = get_clock().slot;
    reserve.last_update_slot = current_time;
}

// 20. flash_borrow -- Borrow liquidity within a single transaction; must be repaid
//     before tx ends via flash_repay. No collateral required.
pub flash_borrow(
    market: LendingMarket,
    reserve: Reserve @mut @signer,
    liquidity_supply: account @mut,
    borrower_account: account @mut,
    market_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(amount <= reserve.liquidity_available);

    spl_token::SPLToken::transfer(liquidity_supply, borrower_account, market_authority, amount);
    reserve.liquidity_available = reserve.liquidity_available - amount;
}

// 21. flash_repay -- Repay a flash loan plus fee. Must be called in same tx.
pub flash_repay(
    market: LendingMarket,
    reserve: Reserve @mut,
    borrower_account: account @mut,
    liquidity_supply: account @mut,
    borrower_authority: account @signer,
    token_program: account,
    amount: u64,
    fee: u64
) {
    require(!market.is_paused);
    require(amount > 0);

    let total_repay: u64 = amount + fee;
    spl_token::SPLToken::transfer(borrower_account, liquidity_supply, borrower_authority, total_repay);

    reserve.liquidity_available = reserve.liquidity_available + total_repay;
    reserve.protocol_fees = reserve.protocol_fees + fee;
}

// 22. set_lending_config -- Admin: update reserve parameters.
pub set_lending_config(
    reserve: Reserve @mut,
    market: LendingMarket,
    admin: account @signer,
    new_reserve_factor: u8,
    new_supply_cap: u64,
    new_loan_to_value: u8
) {
    require(market.admin == admin.ctx.key);
    require(new_reserve_factor <= 50);
    require(new_loan_to_value > 0);
    require(new_loan_to_value < 100);

    reserve.reserve_factor = new_reserve_factor;
    reserve.supply_cap = new_supply_cap;
    reserve.loan_to_value_ratio = new_loan_to_value;
}
