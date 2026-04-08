// 5IVE Hyperspace Protocol - Cross-DEX Arbitrage & MEV Protection (ABI v1)
//
// Design (Flashbots/Jito-inspired):
//   - Cross-DEX arbitrage: detect price discrepancies, execute atomic arb trades
//   - Triangular arbitrage: 3-hop A->B->C->A profit extraction
//   - Flash loan arbitrage: borrow, arb, repay + fee, keep profit
//   - MEV protection: private mempool for user swaps, batch execution
//   - MEV rebates: captured MEV value returned to affected users
//   - Staking for priority: stake tokens for first-access to arb opportunities
//   - Profit distribution: protocol fee, executor reward, staker share
//   - Oracle snapshots: multi-pool price monitoring for opportunity detection
//   - Admin: pause, fee config, DEX whitelist, authority transfer

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account ProtocolConfig {
    authority: pubkey;
    fee_collector: pubkey;
    max_flash_loan: u64;
    protection_fee_bps: u64;
    min_profit_threshold: u64;
    profit_split_protocol_bps: u64;
    profit_split_executor_bps: u64;
    profit_split_stakers_bps: u64;
    total_arbs_executed: u64;
    total_profit_captured: u64;
    total_staked: u64;
    total_staker_rewards: u64;
    allowed_dex_count: u8;
    allowed_dex_1: pubkey;
    allowed_dex_2: pubkey;
    allowed_dex_3: pubkey;
    allowed_dex_4: pubkey;
    allowed_dex_5: pubkey;
    allowed_dex_6: pubkey;
    allowed_dex_7: pubkey;
    allowed_dex_8: pubkey;
    is_paused: bool;
}

account PoolSnapshot {
    config: pubkey;
    pool_address: pubkey;
    dex_type: u8;
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    reserve_a: u64;
    reserve_b: u64;
    price_a_to_b: u64;
    price_b_to_a: u64;
    fee_numerator: u64;
    fee_denominator: u64;
    last_update: u64;
    is_active: bool;
}

account ArbOpportunity {
    config: pubkey;
    pool_buy: pubkey;
    pool_sell: pubkey;
    token_in_mint: pubkey;
    token_out_mint: pubkey;
    expected_profit: u64;
    route_type: u8;
    buy_amount: u64;
    sell_amount: u64;
    created_at: u64;
    executed: bool;
}

account FlashLoanState {
    config: pubkey;
    borrower: pubkey;
    source_pool: pubkey;
    borrow_amount: u64;
    fee_amount: u64;
    repaid: bool;
    created_at: u64;
}

account StakerRecord {
    config: pubkey;
    authority: pubkey;
    staked_amount: u64;
    reward_debt: u64;
    accumulated_rewards: u64;
    stake_timestamp: u64;
    priority_score: u64;
}

account ProtectedSwap {
    config: pubkey;
    user: pubkey;
    input_mint: pubkey;
    output_mint: pubkey;
    amount_in: u64;
    min_amount_out: u64;
    max_slippage_bps: u64;
    mev_rebate: u64;
    submitted_at: u64;
    executed: bool;
    batch_id: u64;
}

// DEX_TYPE constants: 0 = Orca, 1 = Raydium, 2 = Meteora, 3 = Saber, 4 = Other
// ROUTE_TYPE constants: 0 = Direct (2-pool), 1 = Triangular (3-hop)
// PRICE_SCALE = 1_000_000 (1e6)
// BPS_SCALE = 10_000

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_swap_output(
    amount_in: u64,
    reserve_in: u64,
    reserve_out: u64,
    fee_num: u64,
    fee_den: u64
) -> u64 {
    // Constant product AMM: dy = (y * dx_after_fee) / (x + dx_after_fee)
    let fee: u64 = (amount_in * fee_num) / fee_den;
    let dx: u64 = amount_in - fee;
    let numerator: u64 = reserve_out * dx;
    let denominator: u64 = reserve_in + dx;
    if (denominator == 0) {
        return 0;
    }
    return numerator / denominator;
}

fn calculate_price(reserve_a: u64, reserve_b: u64) -> u64 {
    // price_a_to_b = (reserve_b * 1_000_000) / reserve_a
    if (reserve_a == 0) {
        return 0;
    }
    return (reserve_b * 1000000) / reserve_a;
}

fn is_dex_allowed(config: ProtocolConfig, dex_address: pubkey) -> bool {
    if (config.allowed_dex_count >= 1) {
        if (config.allowed_dex_1 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 2) {
        if (config.allowed_dex_2 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 3) {
        if (config.allowed_dex_3 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 4) {
        if (config.allowed_dex_4 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 5) {
        if (config.allowed_dex_5 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 6) {
        if (config.allowed_dex_6 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 7) {
        if (config.allowed_dex_7 == dex_address) { return true; }
    }
    if (config.allowed_dex_count >= 8) {
        if (config.allowed_dex_8 == dex_address) { return true; }
    }
    return false;
}

fn set_dex_slot(config: ProtocolConfig @mut, index: u8, dex: pubkey) {
    if (index == 0) { config.allowed_dex_1 = dex; }
    if (index == 1) { config.allowed_dex_2 = dex; }
    if (index == 2) { config.allowed_dex_3 = dex; }
    if (index == 3) { config.allowed_dex_4 = dex; }
    if (index == 4) { config.allowed_dex_5 = dex; }
    if (index == 5) { config.allowed_dex_6 = dex; }
    if (index == 6) { config.allowed_dex_7 = dex; }
    if (index == 7) { config.allowed_dex_8 = dex; }
}

fn get_dex_slot(config: ProtocolConfig, index: u8) -> pubkey {
    if (index == 0) { return config.allowed_dex_1; }
    if (index == 1) { return config.allowed_dex_2; }
    if (index == 2) { return config.allowed_dex_3; }
    if (index == 3) { return config.allowed_dex_4; }
    if (index == 4) { return config.allowed_dex_5; }
    if (index == 5) { return config.allowed_dex_6; }
    if (index == 6) { return config.allowed_dex_7; }
    return config.allowed_dex_8;
}

// ---------------------------------------------------------------------------
// 1. Initialize -- Set up protocol config
// ---------------------------------------------------------------------------

pub initialize(
    config: ProtocolConfig @mut @init(payer=admin, space=1024),
    admin: account @signer,
    fee_collector: pubkey,
    max_flash_loan: u64,
    min_profit_threshold: u64
) {
    require(max_flash_loan > 0);
    require(min_profit_threshold > 0);

    config.authority = admin.ctx.key;
    config.fee_collector = fee_collector;
    config.max_flash_loan = max_flash_loan;
    config.protection_fee_bps = 50;
    config.min_profit_threshold = min_profit_threshold;

    // Default profit split: 10% protocol, 60% executor, 30% stakers (in bps)
    config.profit_split_protocol_bps = 1000;
    config.profit_split_executor_bps = 6000;
    config.profit_split_stakers_bps = 3000;

    config.total_arbs_executed = 0;
    config.total_profit_captured = 0;
    config.total_staked = 0;
    config.total_staker_rewards = 0;
    config.allowed_dex_count = 0;
    config.is_paused = false;
}

// ---------------------------------------------------------------------------
// 2. Register Pool -- Register an AMM pool as an arbitrage source
// ---------------------------------------------------------------------------

pub register_pool(
    config: ProtocolConfig,
    snapshot: PoolSnapshot @mut @init(payer=admin, space=512),
    admin: account @signer,
    pool_address: pubkey,
    dex_type: u8,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    reserve_a: u64,
    reserve_b: u64,
    fee_numerator: u64,
    fee_denominator: u64
) {
    require(config.authority == admin.ctx.key);
    require(!config.is_paused);
    require(dex_type <= 4);
    require(reserve_a > 0);
    require(reserve_b > 0);
    require(fee_denominator > 0);
    require(fee_numerator < fee_denominator);

    snapshot.config = config.ctx.key;
    snapshot.pool_address = pool_address;
    snapshot.dex_type = dex_type;
    snapshot.token_a_mint = token_a_mint;
    snapshot.token_b_mint = token_b_mint;
    snapshot.reserve_a = reserve_a;
    snapshot.reserve_b = reserve_b;
    snapshot.price_a_to_b = calculate_price(reserve_a, reserve_b);
    snapshot.price_b_to_a = calculate_price(reserve_b, reserve_a);
    snapshot.fee_numerator = fee_numerator;
    snapshot.fee_denominator = fee_denominator;
    snapshot.last_update = get_clock().slot;
    snapshot.is_active = true;
}

// ---------------------------------------------------------------------------
// 3. Update Pool State -- Refresh cached pool reserves for price comparison
// ---------------------------------------------------------------------------

pub update_pool_state(
    config: ProtocolConfig,
    snapshot: PoolSnapshot @mut,
    updater: account @signer,
    new_reserve_a: u64,
    new_reserve_b: u64
) {
    require(!config.is_paused);
    require(snapshot.config == config.ctx.key);
    require(snapshot.is_active);
    require(new_reserve_a > 0);
    require(new_reserve_b > 0);

    snapshot.reserve_a = new_reserve_a;
    snapshot.reserve_b = new_reserve_b;
    snapshot.price_a_to_b = calculate_price(new_reserve_a, new_reserve_b);
    snapshot.price_b_to_a = calculate_price(new_reserve_b, new_reserve_a);
    snapshot.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// 4. Execute Arb -- Atomic arbitrage between 2 pools (buy cheap, sell expensive)
// ---------------------------------------------------------------------------

pub execute_arb(
    config: ProtocolConfig @mut,
    pool_buy: PoolSnapshot @mut,
    pool_sell: PoolSnapshot @mut,
    executor: account @signer,
    executor_token_in: spl_token::TokenAccount @mut @serializer("raw"),
    executor_token_mid: spl_token::TokenAccount @mut @serializer("raw"),
    executor_token_out: spl_token::TokenAccount @mut @serializer("raw"),
    buy_vault_in: spl_token::TokenAccount @mut @serializer("raw"),
    buy_vault_out: spl_token::TokenAccount @mut @serializer("raw"),
    sell_vault_in: spl_token::TokenAccount @mut @serializer("raw"),
    sell_vault_out: spl_token::TokenAccount @mut @serializer("raw"),
    pool_buy_authority: account @signer,
    pool_sell_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_profit: u64
) {
    require(!config.is_paused);
    require(pool_buy.config == config.ctx.key);
    require(pool_sell.config == config.ctx.key);
    require(pool_buy.is_active);
    require(pool_sell.is_active);
    require(amount_in > 0);

    // Staleness check: snapshots must be recent (within 20 slots)
    let now: u64 = get_clock().slot;
    require(now - pool_buy.last_update <= 20);
    require(now - pool_sell.last_update <= 20);

    // Step 1: Buy on cheap pool -- swap token_in for token_mid
    let buy_output: u64 = calculate_swap_output(
        amount_in,
        pool_buy.reserve_a,
        pool_buy.reserve_b,
        pool_buy.fee_numerator,
        pool_buy.fee_denominator
    );
    require(buy_output > 0);

    // Step 2: Sell on expensive pool -- swap token_mid for token_out
    let sell_output: u64 = calculate_swap_output(
        buy_output,
        pool_sell.reserve_a,
        pool_sell.reserve_b,
        pool_sell.fee_numerator,
        pool_sell.fee_denominator
    );
    require(sell_output > 0);

    // Profit check
    require(sell_output > amount_in);
    let profit: u64 = sell_output - amount_in;
    require(profit >= min_profit);
    require(profit >= config.min_profit_threshold);

    // Execute leg 1: buy
    spl_token::SPLToken::transfer(executor_token_in, buy_vault_in, executor, amount_in);
    spl_token::SPLToken::transfer(buy_vault_out, executor_token_mid, pool_buy_authority, buy_output);

    // Update buy pool reserves
    pool_buy.reserve_a = pool_buy.reserve_a + amount_in;
    pool_buy.reserve_b = pool_buy.reserve_b - buy_output;

    // Execute leg 2: sell
    spl_token::SPLToken::transfer(executor_token_mid, sell_vault_in, executor, buy_output);
    spl_token::SPLToken::transfer(sell_vault_out, executor_token_out, pool_sell_authority, sell_output);

    // Update sell pool reserves
    pool_sell.reserve_a = pool_sell.reserve_a + buy_output;
    pool_sell.reserve_b = pool_sell.reserve_b - sell_output;

    // Distribute profit
    let protocol_share: u64 = (profit * config.profit_split_protocol_bps) / 10000;
    let staker_share: u64 = (profit * config.profit_split_stakers_bps) / 10000;

    // Update protocol stats
    config.total_arbs_executed = config.total_arbs_executed + 1;
    config.total_profit_captured = config.total_profit_captured + profit;
    config.total_staker_rewards = config.total_staker_rewards + staker_share;

    // Update snapshot prices
    pool_buy.price_a_to_b = calculate_price(pool_buy.reserve_a, pool_buy.reserve_b);
    pool_buy.price_b_to_a = calculate_price(pool_buy.reserve_b, pool_buy.reserve_a);
    pool_sell.price_a_to_b = calculate_price(pool_sell.reserve_a, pool_sell.reserve_b);
    pool_sell.price_b_to_a = calculate_price(pool_sell.reserve_b, pool_sell.reserve_a);
}

// ---------------------------------------------------------------------------
// 5. Execute Triangular Arb -- 3-hop: A -> B -> C -> A
// ---------------------------------------------------------------------------

pub execute_triangular_arb(
    config: ProtocolConfig @mut,
    pool_ab: PoolSnapshot @mut,
    pool_bc: PoolSnapshot @mut,
    pool_ca: PoolSnapshot @mut,
    executor: account @signer,
    executor_token_a: spl_token::TokenAccount @mut @serializer("raw"),
    executor_token_b: spl_token::TokenAccount @mut @serializer("raw"),
    executor_token_c: spl_token::TokenAccount @mut @serializer("raw"),
    vault_ab_in: spl_token::TokenAccount @mut @serializer("raw"),
    vault_ab_out: spl_token::TokenAccount @mut @serializer("raw"),
    vault_bc_in: spl_token::TokenAccount @mut @serializer("raw"),
    vault_bc_out: spl_token::TokenAccount @mut @serializer("raw"),
    vault_ca_in: spl_token::TokenAccount @mut @serializer("raw"),
    vault_ca_out: spl_token::TokenAccount @mut @serializer("raw"),
    pool_ab_authority: account @signer,
    pool_bc_authority: account @signer,
    pool_ca_authority: account @signer,
    token_program: account,
    amount_a_in: u64,
    min_profit: u64
) {
    require(!config.is_paused);
    require(pool_ab.config == config.ctx.key);
    require(pool_bc.config == config.ctx.key);
    require(pool_ca.config == config.ctx.key);
    require(pool_ab.is_active);
    require(pool_bc.is_active);
    require(pool_ca.is_active);
    require(amount_a_in > 0);

    // Staleness
    let now: u64 = get_clock().slot;
    require(now - pool_ab.last_update <= 20);
    require(now - pool_bc.last_update <= 20);
    require(now - pool_ca.last_update <= 20);

    // Hop 1: A -> B
    let b_amount: u64 = calculate_swap_output(
        amount_a_in,
        pool_ab.reserve_a,
        pool_ab.reserve_b,
        pool_ab.fee_numerator,
        pool_ab.fee_denominator
    );
    require(b_amount > 0);

    // Hop 2: B -> C
    let c_amount: u64 = calculate_swap_output(
        b_amount,
        pool_bc.reserve_a,
        pool_bc.reserve_b,
        pool_bc.fee_numerator,
        pool_bc.fee_denominator
    );
    require(c_amount > 0);

    // Hop 3: C -> A
    let a_out: u64 = calculate_swap_output(
        c_amount,
        pool_ca.reserve_a,
        pool_ca.reserve_b,
        pool_ca.fee_numerator,
        pool_ca.fee_denominator
    );
    require(a_out > 0);

    // Profit check: must end with more A than we started
    require(a_out > amount_a_in);
    let profit: u64 = a_out - amount_a_in;
    require(profit >= min_profit);
    require(profit >= config.min_profit_threshold);

    // Execute hop 1: A -> B
    spl_token::SPLToken::transfer(executor_token_a, vault_ab_in, executor, amount_a_in);
    spl_token::SPLToken::transfer(vault_ab_out, executor_token_b, pool_ab_authority, b_amount);
    pool_ab.reserve_a = pool_ab.reserve_a + amount_a_in;
    pool_ab.reserve_b = pool_ab.reserve_b - b_amount;

    // Execute hop 2: B -> C
    spl_token::SPLToken::transfer(executor_token_b, vault_bc_in, executor, b_amount);
    spl_token::SPLToken::transfer(vault_bc_out, executor_token_c, pool_bc_authority, c_amount);
    pool_bc.reserve_a = pool_bc.reserve_a + b_amount;
    pool_bc.reserve_b = pool_bc.reserve_b - c_amount;

    // Execute hop 3: C -> A
    spl_token::SPLToken::transfer(executor_token_c, vault_ca_in, executor, c_amount);
    spl_token::SPLToken::transfer(vault_ca_out, executor_token_a, pool_ca_authority, a_out);
    pool_ca.reserve_a = pool_ca.reserve_a + c_amount;
    pool_ca.reserve_b = pool_ca.reserve_b - a_out;

    // Distribute profit
    let protocol_share: u64 = (profit * config.profit_split_protocol_bps) / 10000;
    let staker_share: u64 = (profit * config.profit_split_stakers_bps) / 10000;

    config.total_arbs_executed = config.total_arbs_executed + 1;
    config.total_profit_captured = config.total_profit_captured + profit;
    config.total_staker_rewards = config.total_staker_rewards + staker_share;

    // Update all snapshot prices
    pool_ab.price_a_to_b = calculate_price(pool_ab.reserve_a, pool_ab.reserve_b);
    pool_ab.price_b_to_a = calculate_price(pool_ab.reserve_b, pool_ab.reserve_a);
    pool_bc.price_a_to_b = calculate_price(pool_bc.reserve_a, pool_bc.reserve_b);
    pool_bc.price_b_to_a = calculate_price(pool_bc.reserve_b, pool_bc.reserve_a);
    pool_ca.price_a_to_b = calculate_price(pool_ca.reserve_a, pool_ca.reserve_b);
    pool_ca.price_b_to_a = calculate_price(pool_ca.reserve_b, pool_ca.reserve_a);
}

// ---------------------------------------------------------------------------
// 6. Execute Flash Arb -- Flash loan: borrow, arb, repay + fee, keep profit
// ---------------------------------------------------------------------------

pub execute_flash_arb(
    config: ProtocolConfig @mut,
    flash_loan: FlashLoanState @mut @init(payer=executor, space=256),
    pool_source: PoolSnapshot @mut,
    pool_target: PoolSnapshot @mut,
    executor: account @signer,
    executor_token_a: spl_token::TokenAccount @mut @serializer("raw"),
    executor_token_b: spl_token::TokenAccount @mut @serializer("raw"),
    source_vault_out: spl_token::TokenAccount @mut @serializer("raw"),
    source_vault_in: spl_token::TokenAccount @mut @serializer("raw"),
    target_vault_in: spl_token::TokenAccount @mut @serializer("raw"),
    target_vault_out: spl_token::TokenAccount @mut @serializer("raw"),
    source_authority: account @signer,
    target_authority: account @signer,
    token_program: account,
    borrow_amount: u64,
    flash_fee_bps: u64,
    min_profit: u64
) {
    require(!config.is_paused);
    require(pool_source.config == config.ctx.key);
    require(pool_target.config == config.ctx.key);
    require(pool_source.is_active);
    require(pool_target.is_active);
    require(borrow_amount > 0);
    require(borrow_amount <= config.max_flash_loan);
    require(borrow_amount <= pool_source.reserve_a);
    require(flash_fee_bps > 0);

    let now: u64 = get_clock().slot;
    require(now - pool_source.last_update <= 20);
    require(now - pool_target.last_update <= 20);

    // Flash loan fee
    let flash_fee: u64 = (borrow_amount * flash_fee_bps) / 10000;
    require(flash_fee > 0);

    // Record flash loan state
    flash_loan.config = config.ctx.key;
    flash_loan.borrower = executor.ctx.key;
    flash_loan.source_pool = pool_source.pool_address;
    flash_loan.borrow_amount = borrow_amount;
    flash_loan.fee_amount = flash_fee;
    flash_loan.repaid = false;
    flash_loan.created_at = now;

    // Step 1: Borrow from source pool
    spl_token::SPLToken::transfer(source_vault_out, executor_token_a, source_authority, borrow_amount);
    pool_source.reserve_a = pool_source.reserve_a - borrow_amount;

    // Step 2: Swap borrowed tokens on target pool for profit
    let swap_output: u64 = calculate_swap_output(
        borrow_amount,
        pool_target.reserve_a,
        pool_target.reserve_b,
        pool_target.fee_numerator,
        pool_target.fee_denominator
    );
    require(swap_output > 0);

    spl_token::SPLToken::transfer(executor_token_a, target_vault_in, executor, borrow_amount);
    spl_token::SPLToken::transfer(target_vault_out, executor_token_b, target_authority, swap_output);
    pool_target.reserve_a = pool_target.reserve_a + borrow_amount;
    pool_target.reserve_b = pool_target.reserve_b - swap_output;

    // Step 3: Swap back on source pool (reverse direction for repayment)
    let repay_output: u64 = calculate_swap_output(
        swap_output,
        pool_source.reserve_b,
        pool_source.reserve_a,
        pool_source.fee_numerator,
        pool_source.fee_denominator
    );
    require(repay_output > 0);

    // Must be able to repay borrow + fee
    let total_repay: u64 = borrow_amount + flash_fee;
    require(repay_output >= total_repay);
    let profit: u64 = repay_output - total_repay;
    require(profit >= min_profit);
    require(profit >= config.min_profit_threshold);

    // Step 4: Repay flash loan + fee to source pool
    spl_token::SPLToken::transfer(executor_token_b, source_vault_in, executor, swap_output);
    pool_source.reserve_b = pool_source.reserve_b + swap_output;

    // The source pool gets back its liquidity plus the fee
    pool_source.reserve_a = pool_source.reserve_a + total_repay;

    flash_loan.repaid = true;

    // Distribute profit
    let staker_share: u64 = (profit * config.profit_split_stakers_bps) / 10000;

    config.total_arbs_executed = config.total_arbs_executed + 1;
    config.total_profit_captured = config.total_profit_captured + profit;
    config.total_staker_rewards = config.total_staker_rewards + staker_share;

    // Update prices
    pool_source.price_a_to_b = calculate_price(pool_source.reserve_a, pool_source.reserve_b);
    pool_source.price_b_to_a = calculate_price(pool_source.reserve_b, pool_source.reserve_a);
    pool_target.price_a_to_b = calculate_price(pool_target.reserve_a, pool_target.reserve_b);
    pool_target.price_b_to_a = calculate_price(pool_target.reserve_b, pool_target.reserve_a);
}

// ---------------------------------------------------------------------------
// 7. Submit Protected Swap -- User submits a swap with MEV protection
// ---------------------------------------------------------------------------

pub submit_protected_swap(
    config: ProtocolConfig,
    swap: ProtectedSwap @mut @init(payer=user, space=384),
    user: account @signer,
    input_mint: pubkey,
    output_mint: pubkey,
    amount_in: u64,
    min_amount_out: u64,
    max_slippage_bps: u64
) {
    require(!config.is_paused);
    require(amount_in > 0);
    require(min_amount_out > 0);
    require(max_slippage_bps <= 1000);

    swap.config = config.ctx.key;
    swap.user = user.ctx.key;
    swap.input_mint = input_mint;
    swap.output_mint = output_mint;
    swap.amount_in = amount_in;
    swap.min_amount_out = min_amount_out;
    swap.max_slippage_bps = max_slippage_bps;
    swap.mev_rebate = 0;
    swap.submitted_at = get_clock().slot;
    swap.executed = false;
    swap.batch_id = 0;
}

// ---------------------------------------------------------------------------
// 8. Execute Protected Batch -- Keeper executes a batch of protected swaps
// ---------------------------------------------------------------------------

pub execute_protected_batch(
    config: ProtocolConfig @mut,
    swap_1: ProtectedSwap @mut,
    pool: PoolSnapshot @mut,
    keeper: account @signer,
    user_token_in: spl_token::TokenAccount @mut @serializer("raw"),
    user_token_out: spl_token::TokenAccount @mut @serializer("raw"),
    pool_vault_in: spl_token::TokenAccount @mut @serializer("raw"),
    pool_vault_out: spl_token::TokenAccount @mut @serializer("raw"),
    pool_authority: account @signer,
    token_program: account,
    batch_id: u64
) {
    require(!config.is_paused);
    require(swap_1.config == config.ctx.key);
    require(pool.config == config.ctx.key);
    require(!swap_1.executed);
    require(pool.is_active);

    let now: u64 = get_clock().slot;
    require(now - pool.last_update <= 20);

    // Calculate swap output
    let output: u64 = calculate_swap_output(
        swap_1.amount_in,
        pool.reserve_a,
        pool.reserve_b,
        pool.fee_numerator,
        pool.fee_denominator
    );
    require(output > 0);
    require(output >= swap_1.min_amount_out);

    // Slippage check
    let slippage: u64 = ((swap_1.amount_in - output) * 10000) / swap_1.amount_in;
    require(slippage <= swap_1.max_slippage_bps);

    // Protection fee deducted from output
    let protection_fee: u64 = (output * config.protection_fee_bps) / 10000;
    let user_receives: u64 = output - protection_fee;
    require(user_receives >= swap_1.min_amount_out);

    // Execute the swap
    spl_token::SPLToken::transfer(user_token_in, pool_vault_in, pool_authority, swap_1.amount_in);
    spl_token::SPLToken::transfer(pool_vault_out, user_token_out, pool_authority, user_receives);

    // Update pool reserves
    pool.reserve_a = pool.reserve_a + swap_1.amount_in;
    pool.reserve_b = pool.reserve_b - output;

    // Mark swap as executed
    swap_1.executed = true;
    swap_1.batch_id = batch_id;

    // Update pool prices
    pool.price_a_to_b = calculate_price(pool.reserve_a, pool.reserve_b);
    pool.price_b_to_a = calculate_price(pool.reserve_b, pool.reserve_a);
}

// ---------------------------------------------------------------------------
// 9. Set Protection Fee -- Fee for MEV protection service
// ---------------------------------------------------------------------------

pub set_protection_fee(
    config: ProtocolConfig @mut,
    admin: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == admin.ctx.key);
    require(new_fee_bps <= 500);
    config.protection_fee_bps = new_fee_bps;
}

// ---------------------------------------------------------------------------
// 10. Claim MEV Rebate -- If MEV was captured, user gets a rebate
// ---------------------------------------------------------------------------

pub claim_mev_rebate(
    config: ProtocolConfig,
    swap: ProtectedSwap @mut,
    user: account @signer,
    rebate_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account
) {
    require(swap.config == config.ctx.key);
    require(swap.user == user.ctx.key);
    require(swap.executed);
    require(swap.mev_rebate > 0);

    let rebate: u64 = swap.mev_rebate;
    swap.mev_rebate = 0;

    spl_token::SPLToken::transfer(rebate_vault, user_token, vault_authority, rebate);
}

// ---------------------------------------------------------------------------
// 11. Snapshot Prices -- Record current prices across registered pools
// ---------------------------------------------------------------------------

pub snapshot_prices(
    config: ProtocolConfig,
    snapshot: PoolSnapshot @mut,
    updater: account @signer,
    current_reserve_a: u64,
    current_reserve_b: u64
) {
    require(!config.is_paused);
    require(snapshot.config == config.ctx.key);
    require(snapshot.is_active);
    require(current_reserve_a > 0);
    require(current_reserve_b > 0);

    snapshot.reserve_a = current_reserve_a;
    snapshot.reserve_b = current_reserve_b;
    snapshot.price_a_to_b = calculate_price(current_reserve_a, current_reserve_b);
    snapshot.price_b_to_a = calculate_price(current_reserve_b, current_reserve_a);
    snapshot.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// 12. Detect Opportunity -- Check if an arb opportunity exists (read-only helper)
// ---------------------------------------------------------------------------

pub detect_opportunity(
    config: ProtocolConfig,
    pool_a: PoolSnapshot,
    pool_b: PoolSnapshot,
    test_amount: u64
) -> u64 {
    require(pool_a.config == config.ctx.key);
    require(pool_b.config == config.ctx.key);
    require(pool_a.is_active);
    require(pool_b.is_active);
    require(test_amount > 0);

    // Simulate buy on pool_a, sell on pool_b
    let buy_output: u64 = calculate_swap_output(
        test_amount,
        pool_a.reserve_a,
        pool_a.reserve_b,
        pool_a.fee_numerator,
        pool_a.fee_denominator
    );

    if (buy_output == 0) {
        return 0;
    }

    let sell_output: u64 = calculate_swap_output(
        buy_output,
        pool_b.reserve_a,
        pool_b.reserve_b,
        pool_b.fee_numerator,
        pool_b.fee_denominator
    );

    if (sell_output <= test_amount) {
        return 0;
    }

    return sell_output - test_amount;
}

// ---------------------------------------------------------------------------
// 13. Get Best Route -- Find the most profitable arb route
// ---------------------------------------------------------------------------

pub get_best_route(
    config: ProtocolConfig,
    pool_a: PoolSnapshot,
    pool_b: PoolSnapshot,
    test_amount: u64
) -> u64 {
    require(pool_a.config == config.ctx.key);
    require(pool_b.config == config.ctx.key);
    require(test_amount > 0);

    // Route 1: buy on A, sell on B
    let buy_a: u64 = calculate_swap_output(
        test_amount,
        pool_a.reserve_a,
        pool_a.reserve_b,
        pool_a.fee_numerator,
        pool_a.fee_denominator
    );
    let mut profit_ab: u64 = 0;
    if (buy_a > 0) {
        let sell_b: u64 = calculate_swap_output(
            buy_a,
            pool_b.reserve_a,
            pool_b.reserve_b,
            pool_b.fee_numerator,
            pool_b.fee_denominator
        );
        if (sell_b > test_amount) {
            profit_ab = sell_b - test_amount;
        }
    }

    // Route 2: buy on B, sell on A
    let buy_b: u64 = calculate_swap_output(
        test_amount,
        pool_b.reserve_a,
        pool_b.reserve_b,
        pool_b.fee_numerator,
        pool_b.fee_denominator
    );
    let mut profit_ba: u64 = 0;
    if (buy_b > 0) {
        let sell_a: u64 = calculate_swap_output(
            buy_b,
            pool_a.reserve_a,
            pool_a.reserve_b,
            pool_a.fee_numerator,
            pool_a.fee_denominator
        );
        if (sell_a > test_amount) {
            profit_ba = sell_a - test_amount;
        }
    }

    // Return the better profit (0 = route AB is best or tied, 1+ encoded)
    if (profit_ab >= profit_ba) {
        return profit_ab;
    }
    return profit_ba;
}

// ---------------------------------------------------------------------------
// 14. Distribute Profits -- Split arb profits: protocol, executor, stakers
// ---------------------------------------------------------------------------

pub distribute_profits(
    config: ProtocolConfig @mut,
    executor: account @signer,
    profit_vault: spl_token::TokenAccount @mut @serializer("raw"),
    protocol_fee_account: spl_token::TokenAccount @mut @serializer("raw"),
    executor_account: spl_token::TokenAccount @mut @serializer("raw"),
    staker_pool_account: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account,
    total_profit: u64
) {
    require(!config.is_paused);
    require(total_profit > 0);

    let protocol_share: u64 = (total_profit * config.profit_split_protocol_bps) / 10000;
    let executor_share: u64 = (total_profit * config.profit_split_executor_bps) / 10000;
    let staker_share: u64 = total_profit - protocol_share - executor_share;

    if (protocol_share > 0) {
        spl_token::SPLToken::transfer(profit_vault, protocol_fee_account, vault_authority, protocol_share);
    }
    if (executor_share > 0) {
        spl_token::SPLToken::transfer(profit_vault, executor_account, vault_authority, executor_share);
    }
    if (staker_share > 0) {
        spl_token::SPLToken::transfer(profit_vault, staker_pool_account, vault_authority, staker_share);
    }

    config.total_staker_rewards = config.total_staker_rewards + staker_share;
}

// ---------------------------------------------------------------------------
// 15. Stake For Priority -- Stake tokens for priority access to arb opportunities
// ---------------------------------------------------------------------------

pub stake_for_priority(
    config: ProtocolConfig @mut,
    staker: StakerRecord @mut @init(payer=user, space=256),
    user: account @signer,
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    stake_vault: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(amount > 0);

    staker.config = config.ctx.key;
    staker.authority = user.ctx.key;
    staker.staked_amount = amount;
    staker.reward_debt = 0;
    staker.accumulated_rewards = 0;
    staker.stake_timestamp = get_clock().slot;

    // Priority score = staked amount (can be enhanced with time-weighting)
    staker.priority_score = amount;

    spl_token::SPLToken::transfer(user_token, stake_vault, user, amount);

    config.total_staked = config.total_staked + amount;
}

// ---------------------------------------------------------------------------
// 16. Unstake -- Unstake tokens
// ---------------------------------------------------------------------------

pub unstake(
    config: ProtocolConfig @mut,
    staker: StakerRecord @mut,
    user: account @signer,
    stake_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(staker.config == config.ctx.key);
    require(staker.authority == user.ctx.key);
    require(amount > 0);
    require(amount <= staker.staked_amount);

    staker.staked_amount = staker.staked_amount - amount;
    staker.priority_score = staker.staked_amount;

    spl_token::SPLToken::transfer(stake_vault, user_token, vault_authority, amount);

    config.total_staked = config.total_staked - amount;
}

// ---------------------------------------------------------------------------
// 17. Claim Staker Rewards -- Claim accumulated arb profit share
// ---------------------------------------------------------------------------

pub claim_staker_rewards(
    config: ProtocolConfig @mut,
    staker: StakerRecord @mut,
    user: account @signer,
    reward_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_token: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account
) {
    require(staker.config == config.ctx.key);
    require(staker.authority == user.ctx.key);
    require(staker.staked_amount > 0);

    // Calculate proportional share of staker rewards
    // reward = (staker.staked_amount * total_staker_rewards) / total_staked - reward_debt
    require(config.total_staked > 0);
    let gross_reward: u64 = (staker.staked_amount * config.total_staker_rewards) / config.total_staked;
    require(gross_reward > staker.reward_debt);
    let claimable: u64 = gross_reward - staker.reward_debt;
    require(claimable > 0);

    staker.reward_debt = gross_reward;
    staker.accumulated_rewards = staker.accumulated_rewards + claimable;

    spl_token::SPLToken::transfer(reward_vault, user_token, vault_authority, claimable);
}

// ---------------------------------------------------------------------------
// 18. Set Max Flash Loan -- Cap flash loan size
// ---------------------------------------------------------------------------

pub set_max_flash_loan(
    config: ProtocolConfig @mut,
    admin: account @signer,
    new_max: u64
) {
    require(config.authority == admin.ctx.key);
    require(new_max > 0);
    config.max_flash_loan = new_max;
}

// ---------------------------------------------------------------------------
// 19. Set Profit Split -- Configure profit distribution ratios
// ---------------------------------------------------------------------------

pub set_profit_split(
    config: ProtocolConfig @mut,
    admin: account @signer,
    protocol_bps: u64,
    executor_bps: u64,
    stakers_bps: u64
) {
    require(config.authority == admin.ctx.key);
    // Must sum to 10000 (100%)
    require(protocol_bps + executor_bps + stakers_bps == 10000);
    require(protocol_bps <= 3000);
    require(executor_bps >= 1000);

    config.profit_split_protocol_bps = protocol_bps;
    config.profit_split_executor_bps = executor_bps;
    config.profit_split_stakers_bps = stakers_bps;
}

// ---------------------------------------------------------------------------
// 20. Set Authority -- Transfer admin
// ---------------------------------------------------------------------------

pub set_authority(
    config: ProtocolConfig @mut,
    admin: account @signer,
    new_authority: pubkey
) {
    require(config.authority == admin.ctx.key);
    config.authority = new_authority;
}

// ---------------------------------------------------------------------------
// 21. Pause / Unpause -- Emergency controls
// ---------------------------------------------------------------------------

pub pause(
    config: ProtocolConfig @mut,
    admin: account @signer
) {
    require(config.authority == admin.ctx.key);
    config.is_paused = true;
}

pub unpause(
    config: ProtocolConfig @mut,
    admin: account @signer
) {
    require(config.authority == admin.ctx.key);
    config.is_paused = false;
}

// ---------------------------------------------------------------------------
// 22. Add Allowed DEX -- Whitelist a DEX source
// ---------------------------------------------------------------------------

pub add_allowed_dex(
    config: ProtocolConfig @mut,
    admin: account @signer,
    dex_address: pubkey
) {
    require(config.authority == admin.ctx.key);
    require(config.allowed_dex_count < 8);
    require(!is_dex_allowed(config, dex_address));

    let index: u8 = config.allowed_dex_count;
    set_dex_slot(config, index, dex_address);
    config.allowed_dex_count = config.allowed_dex_count + 1;
}

// ---------------------------------------------------------------------------
// 23. Remove Allowed DEX -- Blacklist a DEX source
// ---------------------------------------------------------------------------

pub remove_allowed_dex(
    config: ProtocolConfig @mut,
    admin: account @signer,
    dex_address: pubkey
) {
    require(config.authority == admin.ctx.key);
    require(config.allowed_dex_count > 0);

    // Find and remove by swapping with last element
    let mut found: bool = false;
    let mut found_index: u8 = 0;
    let count: u8 = config.allowed_dex_count;

    if (count >= 1) {
        if (config.allowed_dex_1 == dex_address) { found = true; found_index = 0; }
    }
    if (!found) {
        if (count >= 2) {
            if (config.allowed_dex_2 == dex_address) { found = true; found_index = 1; }
        }
    }
    if (!found) {
        if (count >= 3) {
            if (config.allowed_dex_3 == dex_address) { found = true; found_index = 2; }
        }
    }
    if (!found) {
        if (count >= 4) {
            if (config.allowed_dex_4 == dex_address) { found = true; found_index = 3; }
        }
    }
    if (!found) {
        if (count >= 5) {
            if (config.allowed_dex_5 == dex_address) { found = true; found_index = 4; }
        }
    }
    if (!found) {
        if (count >= 6) {
            if (config.allowed_dex_6 == dex_address) { found = true; found_index = 5; }
        }
    }
    if (!found) {
        if (count >= 7) {
            if (config.allowed_dex_7 == dex_address) { found = true; found_index = 6; }
        }
    }
    if (!found) {
        if (count >= 8) {
            if (config.allowed_dex_8 == dex_address) { found = true; found_index = 7; }
        }
    }
    require(found);

    // Swap with last element and decrement count
    let last_index: u8 = count - 1;
    if (found_index != last_index) {
        let last_dex: pubkey = get_dex_slot(config, last_index);
        set_dex_slot(config, found_index, last_dex);
    }
    config.allowed_dex_count = config.allowed_dex_count - 1;
}

// ---------------------------------------------------------------------------
// 24. Set MEV Rebate -- Admin assigns a rebate to a protected swap
// ---------------------------------------------------------------------------

pub set_mev_rebate(
    config: ProtocolConfig,
    swap: ProtectedSwap @mut,
    admin: account @signer,
    rebate_amount: u64
) {
    require(config.authority == admin.ctx.key);
    require(swap.config == config.ctx.key);
    require(swap.executed);
    require(rebate_amount > 0);

    swap.mev_rebate = swap.mev_rebate + rebate_amount;
}

// ---------------------------------------------------------------------------
// 25. Deactivate Pool -- Disable a pool from arbitrage
// ---------------------------------------------------------------------------

pub deactivate_pool(
    config: ProtocolConfig,
    snapshot: PoolSnapshot @mut,
    admin: account @signer
) {
    require(config.authority == admin.ctx.key);
    require(snapshot.config == config.ctx.key);
    snapshot.is_active = false;
}

// ---------------------------------------------------------------------------
// 26. Reactivate Pool -- Re-enable a disabled pool
// ---------------------------------------------------------------------------

pub reactivate_pool(
    config: ProtocolConfig,
    snapshot: PoolSnapshot @mut,
    admin: account @signer
) {
    require(config.authority == admin.ctx.key);
    require(snapshot.config == config.ctx.key);
    snapshot.is_active = true;
}

// ---------------------------------------------------------------------------
// Read-Only Getters
// ---------------------------------------------------------------------------

pub get_pool_price_a_to_b(snapshot: PoolSnapshot) -> u64 {
    return snapshot.price_a_to_b;
}

pub get_pool_price_b_to_a(snapshot: PoolSnapshot) -> u64 {
    return snapshot.price_b_to_a;
}

pub get_pool_reserves_a(snapshot: PoolSnapshot) -> u64 {
    return snapshot.reserve_a;
}

pub get_pool_reserves_b(snapshot: PoolSnapshot) -> u64 {
    return snapshot.reserve_b;
}

pub get_total_arbs(config: ProtocolConfig) -> u64 {
    return config.total_arbs_executed;
}

pub get_total_profit(config: ProtocolConfig) -> u64 {
    return config.total_profit_captured;
}

pub get_total_staked(config: ProtocolConfig) -> u64 {
    return config.total_staked;
}

pub get_staker_amount(staker: StakerRecord) -> u64 {
    return staker.staked_amount;
}

pub get_staker_priority(staker: StakerRecord) -> u64 {
    return staker.priority_score;
}

pub get_staker_rewards(staker: StakerRecord) -> u64 {
    return staker.accumulated_rewards;
}

pub get_swap_status(swap: ProtectedSwap) -> bool {
    return swap.executed;
}

pub get_swap_rebate(swap: ProtectedSwap) -> u64 {
    return swap.mev_rebate;
}

pub get_flash_loan_status(flash_loan: FlashLoanState) -> bool {
    return flash_loan.repaid;
}

pub get_protection_fee(config: ProtocolConfig) -> u64 {
    return config.protection_fee_bps;
}

pub get_max_flash_loan(config: ProtocolConfig) -> u64 {
    return config.max_flash_loan;
}

pub get_profit_split_protocol(config: ProtocolConfig) -> u64 {
    return config.profit_split_protocol_bps;
}

pub get_profit_split_executor(config: ProtocolConfig) -> u64 {
    return config.profit_split_executor_bps;
}

pub get_profit_split_stakers(config: ProtocolConfig) -> u64 {
    return config.profit_split_stakers_bps;
}

pub is_paused(config: ProtocolConfig) -> bool {
    return config.is_paused;
}
