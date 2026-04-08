// 5IVE Francium Protocol -- Leveraged Yield Farming Migration
//
// Francium enables leveraged yield farming on Solana. Users deposit collateral,
// borrow additional tokens from lending pools, enter LP positions, and stake
// for amplified farming rewards.
//
// Design:
//   - LendingPool: isolated per-token pool where lenders earn interest
//   - FarmStrategy: defines an LP pair, farm program, max leverage, liquidation params
//   - LeveragedPosition: per-user position tracking collateral, borrows, LP tokens
//   - Interest accrues via supply/borrow index model (scaled by 1e9)
//   - Health factor = (collateral_value * liq_threshold) / borrowed_value
//   - Liquidation when health < 100 (i.e. < 1.0x); liquidator gets bonus
//   - All math integer-only; ratios scaled by 100 or 10000

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account LendingPool {
    token_mint: pubkey;
    supply_vault: pubkey;
    total_supplied: u64;
    total_borrowed: u64;
    supply_index: u64;       // scaled by 1e9; tracks lender earnings
    borrow_index: u64;       // scaled by 1e9; tracks borrower debt growth
    interest_model: u8;      // 0 = linear, 1 = kink, 2 = flat
    last_update: u64;        // slot of last accrual
    authority: pubkey;
    is_paused: bool;
}

account LeveragedPosition {
    owner: pubkey;
    farm_strategy: pubkey;
    collateral_amount: u64;
    borrowed_amount: u64;
    lp_tokens_held: u64;
    leverage_ratio: u64;     // scaled by 100 (e.g. 300 = 3x)
    entry_price: u64;        // price at position open (for PnL tracking)
    health_factor: u64;      // scaled by 100; must stay >= 100
    is_active: bool;
}

account FarmStrategy {
    pool_a_mint: pubkey;
    pool_b_mint: pubkey;
    lp_mint: pubkey;
    farm_program: pubkey;
    reward_mint: pubkey;
    max_leverage: u64;       // scaled by 100 (e.g. 500 = 5x)
    liq_threshold: u64;      // scaled by 100 (e.g. 85 = 85%)
    liq_bonus: u64;          // scaled by 100 (e.g. 5 = 5%)
    authority: pubkey;
    is_paused: bool;
}

// ---------------------------------------------------------------------------
// Constants (inline)
// ---------------------------------------------------------------------------
// INDEX_SCALE = 1_000_000_000  (1e9)
// SLOTS_PER_YEAR = 63_072_000  (~400ms slots)

// ---------------------------------------------------------------------------
// Lending Pool
// ---------------------------------------------------------------------------

// 1. create_lending_pool -- initialize an isolated lending pool for a token
pub create_lending_pool(
    pool: LendingPool @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    token_mint: pubkey,
    supply_vault: pubkey,
    interest_model: u8
) {
    require(interest_model <= 2);

    pool.token_mint = token_mint;
    pool.supply_vault = supply_vault;
    pool.total_supplied = 0;
    pool.total_borrowed = 0;
    pool.supply_index = 1000000000;   // 1.0 scaled
    pool.borrow_index = 1000000000;
    pool.interest_model = interest_model;
    pool.last_update = get_clock().slot;
    pool.authority = creator.ctx.key;
    pool.is_paused = false;
}

// 2. supply -- lend tokens into the pool and earn interest
pub supply(
    pool: LendingPool @mut,
    user_token: account @mut,
    pool_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(pool_vault.ctx.key == pool.supply_vault);

    spl_token::SPLToken::transfer(user_token, pool_vault, user_authority, amount);

    pool.total_supplied = pool.total_supplied + amount;
    pool.last_update = get_clock().slot;
}

// 3. withdraw_supply -- withdraw lent tokens plus earned interest
pub withdraw_supply(
    pool: LendingPool @mut @signer,
    pool_vault: account @mut,
    user_token: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(pool_vault.ctx.key == pool.supply_vault);

    // Cannot withdraw more than available (supplied minus borrowed)
    let available: u64 = pool.total_supplied - pool.total_borrowed;
    require(amount <= available);

    spl_token::SPLToken::transfer(pool_vault, user_token, pool, amount);

    pool.total_supplied = pool.total_supplied - amount;
    pool.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// Farm Strategy
// ---------------------------------------------------------------------------

// 4. create_farm_strategy -- define an LP pair farming configuration
pub create_farm_strategy(
    strategy: FarmStrategy @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    pool_a_mint: pubkey,
    pool_b_mint: pubkey,
    lp_mint: pubkey,
    farm_program: pubkey,
    reward_mint: pubkey,
    max_leverage: u64,
    liq_threshold: u64,
    liq_bonus: u64
) {
    // Max leverage between 1x (100) and 6x (600)
    require(max_leverage >= 100);
    require(max_leverage <= 600);
    // Liquidation threshold 50-95%
    require(liq_threshold >= 50);
    require(liq_threshold <= 95);
    // Liquidation bonus 1-15%
    require(liq_bonus >= 1);
    require(liq_bonus <= 15);

    strategy.pool_a_mint = pool_a_mint;
    strategy.pool_b_mint = pool_b_mint;
    strategy.lp_mint = lp_mint;
    strategy.farm_program = farm_program;
    strategy.reward_mint = reward_mint;
    strategy.max_leverage = max_leverage;
    strategy.liq_threshold = liq_threshold;
    strategy.liq_bonus = liq_bonus;
    strategy.authority = creator.ctx.key;
    strategy.is_paused = false;
}

// ---------------------------------------------------------------------------
// Leveraged Positions
// ---------------------------------------------------------------------------

// 5. open_leveraged_position -- deposit collateral, borrow, enter LP, stake
pub open_leveraged_position(
    position: LeveragedPosition @mut @init(payer=user, space=512) @signer,
    strategy: FarmStrategy,
    pool: LendingPool @mut,
    user: account @mut @signer,
    user_collateral: account @mut,
    pool_vault: account @mut,
    token_program: account,
    collateral_amount: u64,
    leverage_ratio: u64,
    entry_price: u64
) {
    require(!strategy.is_paused);
    require(!pool.is_paused);
    require(collateral_amount > 0);
    require(leverage_ratio >= 100);
    require(leverage_ratio <= strategy.max_leverage);
    require(entry_price > 0);
    require(pool_vault.ctx.key == pool.supply_vault);

    // Calculate borrow: total_position = collateral * leverage / 100
    // borrow = total_position - collateral
    let total_position: u64 = (collateral_amount * leverage_ratio) / 100;
    let borrow_amount: u64 = total_position - collateral_amount;

    // Ensure pool has enough liquidity to borrow
    let available: u64 = pool.total_supplied - pool.total_borrowed;
    require(borrow_amount <= available);

    // Transfer collateral from user
    spl_token::SPLToken::transfer(user_collateral, pool_vault, user, collateral_amount);

    // Update pool borrows
    pool.total_borrowed = pool.total_borrowed + borrow_amount;

    // LP tokens = total_position (simplified 1:1 for DSL)
    let lp_tokens: u64 = total_position;

    // Initial health factor: (collateral * liq_threshold) / borrow
    let mut health: u64 = 10000;  // default max health
    if (borrow_amount > 0) {
        health = (collateral_amount * strategy.liq_threshold) / borrow_amount;
    }

    position.owner = user.ctx.key;
    position.farm_strategy = strategy.ctx.key;
    position.collateral_amount = collateral_amount;
    position.borrowed_amount = borrow_amount;
    position.lp_tokens_held = lp_tokens;
    position.leverage_ratio = leverage_ratio;
    position.entry_price = entry_price;
    position.health_factor = health;
    position.is_active = true;
}

// 6. close_position -- unstake, remove LP, repay borrow, return remainder
pub close_position(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool: LendingPool @mut @signer,
    pool_vault: account @mut,
    user_token: account @mut,
    user: account @signer,
    token_program: account
) {
    require(position.owner == user.ctx.key);
    require(position.is_active);
    require(pool_vault.ctx.key == pool.supply_vault);

    // LP tokens convert back to underlying (simplified 1:1)
    let total_value: u64 = position.lp_tokens_held;

    // Repay borrow first
    let mut repay: u64 = position.borrowed_amount;
    if (repay > total_value) {
        repay = total_value;
    }

    // Remainder goes to user
    let remainder: u64 = total_value - repay;

    // Update pool
    if (pool.total_borrowed >= repay) {
        pool.total_borrowed = pool.total_borrowed - repay;
    } else {
        pool.total_borrowed = 0;
    }

    // Transfer remainder to user
    if (remainder > 0) {
        spl_token::SPLToken::transfer(pool_vault, user_token, pool, remainder);
    }

    position.collateral_amount = 0;
    position.borrowed_amount = 0;
    position.lp_tokens_held = 0;
    position.health_factor = 0;
    position.is_active = false;
}

// 7. add_collateral -- top up collateral to improve health factor
pub add_collateral(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    user_token: account @mut,
    pool_vault: account @mut,
    user: account @signer,
    token_program: account,
    amount: u64
) {
    require(position.owner == user.ctx.key);
    require(position.is_active);
    require(amount > 0);
    require(pool_vault.ctx.key == strategy.pool_a_mint);  // collateral vault

    spl_token::SPLToken::transfer(user_token, pool_vault, user, amount);

    position.collateral_amount = position.collateral_amount + amount;

    // Recalculate health
    if (position.borrowed_amount > 0) {
        position.health_factor = (position.collateral_amount * strategy.liq_threshold) / position.borrowed_amount;
    } else {
        position.health_factor = 10000;
    }
}

// 8. remove_collateral -- withdraw excess collateral with health check
pub remove_collateral(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool_vault: account @mut,
    user_token: account @mut,
    user: account @signer,
    token_program: account,
    amount: u64
) {
    require(position.owner == user.ctx.key);
    require(position.is_active);
    require(amount > 0);
    require(amount < position.collateral_amount);

    let new_collateral: u64 = position.collateral_amount - amount;

    // Health check: must remain >= 100 (1.0x) after removal
    if (position.borrowed_amount > 0) {
        let new_health: u64 = (new_collateral * strategy.liq_threshold) / position.borrowed_amount;
        require(new_health >= 100);
        position.health_factor = new_health;
    }

    spl_token::SPLToken::transfer(pool_vault, user_token, user, amount);
    position.collateral_amount = new_collateral;
}

// 9. increase_leverage -- borrow more to amplify position
pub increase_leverage(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool: LendingPool @mut,
    user: account @signer,
    new_leverage: u64
) {
    require(position.owner == user.ctx.key);
    require(position.is_active);
    require(!pool.is_paused);
    require(new_leverage > position.leverage_ratio);
    require(new_leverage <= strategy.max_leverage);

    // Additional borrow
    let new_total: u64 = (position.collateral_amount * new_leverage) / 100;
    let old_total: u64 = (position.collateral_amount * position.leverage_ratio) / 100;
    let additional_borrow: u64 = new_total - old_total;

    let available: u64 = pool.total_supplied - pool.total_borrowed;
    require(additional_borrow <= available);

    pool.total_borrowed = pool.total_borrowed + additional_borrow;
    position.borrowed_amount = position.borrowed_amount + additional_borrow;
    position.lp_tokens_held = position.lp_tokens_held + additional_borrow;
    position.leverage_ratio = new_leverage;

    // Update health
    if (position.borrowed_amount > 0) {
        position.health_factor = (position.collateral_amount * strategy.liq_threshold) / position.borrowed_amount;
    }
}

// 10. decrease_leverage -- repay some borrow to reduce exposure
pub decrease_leverage(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool: LendingPool @mut,
    user: account @signer,
    new_leverage: u64
) {
    require(position.owner == user.ctx.key);
    require(position.is_active);
    require(new_leverage >= 100);
    require(new_leverage < position.leverage_ratio);

    let new_total: u64 = (position.collateral_amount * new_leverage) / 100;
    let old_total: u64 = (position.collateral_amount * position.leverage_ratio) / 100;
    let repay_amount: u64 = old_total - new_total;

    // Clamp to borrowed
    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > position.borrowed_amount) {
        actual_repay = position.borrowed_amount;
    }

    if (pool.total_borrowed >= actual_repay) {
        pool.total_borrowed = pool.total_borrowed - actual_repay;
    } else {
        pool.total_borrowed = 0;
    }

    position.borrowed_amount = position.borrowed_amount - actual_repay;
    position.lp_tokens_held = position.lp_tokens_held - actual_repay;
    position.leverage_ratio = new_leverage;

    // Update health
    if (position.borrowed_amount > 0) {
        position.health_factor = (position.collateral_amount * strategy.liq_threshold) / position.borrowed_amount;
    } else {
        position.health_factor = 10000;
    }
}

// 11. harvest_and_compound -- crank: claim farm rewards, compound into position
pub harvest_and_compound(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    reward_source: account @mut,
    pool_vault: account @mut,
    cranker: account @signer,
    token_program: account,
    reward_amount: u64
) {
    require(position.is_active);
    require(!strategy.is_paused);
    require(reward_amount > 0);

    // Rewards are swapped to underlying and added to LP position
    spl_token::SPLToken::transfer(reward_source, pool_vault, cranker, reward_amount);

    position.lp_tokens_held = position.lp_tokens_held + reward_amount;
    position.collateral_amount = position.collateral_amount + reward_amount;

    // Health improves as collateral grows
    if (position.borrowed_amount > 0) {
        position.health_factor = (position.collateral_amount * strategy.liq_threshold) / position.borrowed_amount;
    }
}

// ---------------------------------------------------------------------------
// Liquidation
// ---------------------------------------------------------------------------

// 12. liquidate_position -- if health factor < 100, liquidator repays and seizes collateral
pub liquidate_position(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool: LendingPool @mut @signer,
    liquidator_token: account @mut,
    pool_vault: account @mut,
    liquidator_receive: account @mut,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(position.is_active);
    require(position.health_factor < 100);  // undercollateralized
    require(repay_amount > 0);

    // Clamp to outstanding borrow
    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > position.borrowed_amount) {
        actual_repay = position.borrowed_amount;
    }

    // Liquidator repays debt
    spl_token::SPLToken::transfer(liquidator_token, pool_vault, liquidator, actual_repay);

    // Liquidator receives collateral + bonus
    let seize_amount: u64 = (actual_repay * (100 + strategy.liq_bonus)) / 100;
    let mut actual_seize: u64 = seize_amount;
    if (actual_seize > position.collateral_amount) {
        actual_seize = position.collateral_amount;
    }

    spl_token::SPLToken::transfer(pool_vault, liquidator_receive, pool, actual_seize);

    // Update pool
    if (pool.total_borrowed >= actual_repay) {
        pool.total_borrowed = pool.total_borrowed - actual_repay;
    } else {
        pool.total_borrowed = 0;
    }

    position.borrowed_amount = position.borrowed_amount - actual_repay;
    position.collateral_amount = position.collateral_amount - actual_seize;

    // Recalculate health
    if (position.borrowed_amount > 0) {
        position.health_factor = (position.collateral_amount * strategy.liq_threshold) / position.borrowed_amount;
    } else {
        position.health_factor = 10000;
        position.is_active = false;
    }
}

// 13. emergency_close -- force-close position regardless of state
pub emergency_close(
    position: LeveragedPosition @mut,
    strategy: FarmStrategy,
    pool: LendingPool @mut @signer,
    pool_vault: account @mut,
    user_token: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(strategy.authority == authority.ctx.key);
    require(position.is_active);

    // Repay whatever possible from LP
    let total_value: u64 = position.lp_tokens_held;
    let mut repay: u64 = position.borrowed_amount;
    if (repay > total_value) {
        repay = total_value;
    }
    let remainder: u64 = total_value - repay;

    if (pool.total_borrowed >= repay) {
        pool.total_borrowed = pool.total_borrowed - repay;
    } else {
        pool.total_borrowed = 0;
    }

    if (remainder > 0) {
        spl_token::SPLToken::transfer(pool_vault, user_token, pool, remainder);
    }

    position.collateral_amount = 0;
    position.borrowed_amount = 0;
    position.lp_tokens_held = 0;
    position.health_factor = 0;
    position.is_active = false;
}

// ---------------------------------------------------------------------------
// Admin Configuration
// ---------------------------------------------------------------------------

// 14. set_interest_model -- change the interest rate model for a pool
pub set_interest_model(
    pool: LendingPool @mut,
    authority: account @signer,
    new_model: u8
) {
    require(pool.authority == authority.ctx.key);
    require(new_model <= 2);
    pool.interest_model = new_model;
}

// 15. set_max_leverage -- update max leverage for a strategy
pub set_max_leverage(
    strategy: FarmStrategy @mut,
    authority: account @signer,
    new_max: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(new_max >= 100);
    require(new_max <= 600);
    strategy.max_leverage = new_max;
}

// 16. set_liquidation_bonus -- update liquidation incentive
pub set_liquidation_bonus(
    strategy: FarmStrategy @mut,
    authority: account @signer,
    new_bonus: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(new_bonus >= 1);
    require(new_bonus <= 15);
    strategy.liq_bonus = new_bonus;
}

// 17. set_fees -- update strategy liquidation threshold
pub set_fees(
    strategy: FarmStrategy @mut,
    authority: account @signer,
    new_liq_threshold: u64
) {
    require(strategy.authority == authority.ctx.key);
    require(new_liq_threshold >= 50);
    require(new_liq_threshold <= 95);
    strategy.liq_threshold = new_liq_threshold;
}

// 18. collect_protocol_fees -- withdraw accrued protocol interest from pool
pub collect_protocol_fees(
    pool: LendingPool @mut @signer,
    pool_vault: account @mut,
    fee_recipient: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.authority == authority.ctx.key);
    require(pool_vault.ctx.key == pool.supply_vault);
    require(amount > 0);

    // Protocol fees come from interest spread; ensure pool remains solvent
    let available: u64 = pool.total_supplied - pool.total_borrowed;
    require(amount <= available);

    spl_token::SPLToken::transfer(pool_vault, fee_recipient, pool, amount);
    pool.total_supplied = pool.total_supplied - amount;
}

// 19. set_authority -- transfer control of pool or strategy
pub set_authority(
    pool: LendingPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

// 20a. pause -- halt lending pool operations
pub pause(
    pool: LendingPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(!pool.is_paused);
    pool.is_paused = true;
}

// 20b. unpause -- resume lending pool operations
pub unpause(
    pool: LendingPool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(pool.is_paused);
    pool.is_paused = false;
}
