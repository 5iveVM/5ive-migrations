// 5IVE Jupiter DEX Aggregator -- Route Execution, Limit Orders, DCA
//
// Design (Jupiter v6 / Solana's #1 DEX Aggregator):
//   - Route execution: single-hop, multi-hop (2/3), and split-route swaps
//   - Each hop executes constant-product AMM logic internally (models best-route)
//   - Slippage protection on every swap via minimum_out enforcement
//   - Limit order book: keeper-driven fill when price conditions are met
//   - DCA (Dollar-Cost Averaging): scheduled periodic buys via keeper bots
//   - Platform fees in basis points with referral fee splitting
//   - Volume tracking for analytics
//   - Emergency pause/unpause by admin
//
// Fee Model:
//   platform_fee = (amount_out * platform_fee_bps) / 10000
//   referral_fee = (platform_fee * referral_fee_share) / 100
//   net_platform_fee = platform_fee - referral_fee
//
// On real Jupiter the off-chain SDK computes optimal routes across AMMs
// and the on-chain program executes them via CPI. In 5ive we model swap
// execution as internal constant-product logic with vault-based token
// transfers, preserving the route state tracking, slippage protection,
// multi-hop accounting, split routing, limit orders, and DCA scheduling.

use std::interfaces::spl_token;

// ===========================================================================
// Accounts
// ===========================================================================

account JupiterConfig {
    authority: pubkey;
    platform_fee_bps: u64;
    referral_fee_share: u64;
    fee_collector: pubkey;
    total_volume: u128;
    total_routes_executed: u64;
    is_paused: bool;
}

account RouteState {
    config: pubkey;
    user: pubkey;
    input_mint: pubkey;
    output_mint: pubkey;
    amount_in: u64;
    minimum_out: u64;
    actual_out: u64;
    num_hops: u8;
    platform_fee_amount: u64;
    referral_fee_amount: u64;
    timestamp: u64;
}

account LimitOrder {
    config: pubkey;
    owner: pubkey;
    input_mint: pubkey;
    output_mint: pubkey;
    input_amount: u64;
    minimum_output: u64;
    filled_input: u64;
    filled_output: u64;
    expiry_timestamp: u64;
    is_active: bool;
    order_id: u64;
}

account DcaSchedule {
    config: pubkey;
    owner: pubkey;
    input_mint: pubkey;
    output_mint: pubkey;
    amount_per_cycle: u64;
    cycle_frequency: u64;
    total_cycles: u64;
    cycles_executed: u64;
    total_input_spent: u64;
    total_output_received: u64;
    next_execution: u64;
    is_active: bool;
    min_output_per_cycle: u64;
}

// Pool account used to model AMM liquidity that Jupiter routes through.
// Each hop in a route references a pool for pricing.
account Pool {
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    reserve_a: u64;
    reserve_b: u64;
    fee_bps: u64;
    is_active: bool;
}

// ===========================================================================
// Internal Math Helpers
// ===========================================================================

// Constant-product swap output: amount_out = (reserve_out * net_in) / (reserve_in + net_in)
fn compute_swap_output(reserve_in: u64, reserve_out: u64, amount_in: u64, fee_bps: u64) -> u64 {
    let fee: u64 = (amount_in * fee_bps) / 10000;
    let net_in: u64 = amount_in - fee;
    let numerator: u64 = reserve_out * net_in;
    let denominator: u64 = reserve_in + net_in;
    let amount_out: u64 = numerator / denominator;
    return amount_out;
}

// Calculate platform fee from output amount
fn calc_platform_fee(amount_out: u64, fee_bps: u64) -> u64 {
    return (amount_out * fee_bps) / 10000;
}

// Calculate referral fee from platform fee
fn calc_referral_fee(platform_fee: u64, referral_share: u64) -> u64 {
    return (platform_fee * referral_share) / 100;
}

// Execute a single swap hop through a pool. Returns amount_out after pool fees.
// Mutates pool reserves to reflect the swap.
fn execute_hop(
    pool: Pool @mut,
    input_mint: pubkey,
    amount_in: u64
) -> u64 {
    require(pool.is_active);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);
    require(amount_in > 0);

    let mut amount_out: u64 = 0;

    if (input_mint == pool.token_a_mint) {
        // Swap A -> B
        amount_out = compute_swap_output(pool.reserve_a, pool.reserve_b, amount_in, pool.fee_bps);
        require(amount_out > 0);
        require(amount_out < pool.reserve_b);
        pool.reserve_a = pool.reserve_a + amount_in;
        pool.reserve_b = pool.reserve_b - amount_out;
    } else {
        // Swap B -> A
        require(input_mint == pool.token_b_mint);
        amount_out = compute_swap_output(pool.reserve_b, pool.reserve_a, amount_in, pool.fee_bps);
        require(amount_out > 0);
        require(amount_out < pool.reserve_a);
        pool.reserve_b = pool.reserve_b + amount_in;
        pool.reserve_a = pool.reserve_a - amount_out;
    }

    return amount_out;
}

// ===========================================================================
// 1. Initialize -- Set up Jupiter program config
// ===========================================================================

pub initialize(
    config: JupiterConfig @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    fee_collector: pubkey,
    platform_fee_bps: u64,
    referral_fee_share: u64
) {
    require(platform_fee_bps <= 1000);
    require(referral_fee_share <= 100);

    config.authority = admin.ctx.key;
    config.platform_fee_bps = platform_fee_bps;
    config.referral_fee_share = referral_fee_share;
    config.fee_collector = fee_collector;
    config.total_volume = 0;
    config.total_routes_executed = 0;
    config.is_paused = false;
}

// ===========================================================================
// 2. Route Swap -- Single-hop swap through one AMM pool
// ===========================================================================

pub route_swap(
    config: JupiterConfig @mut,
    route: RouteState @mut @init(payer=user, space=512) @signer,
    pool: Pool @mut,
    user: account @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_source_vault: account @mut,
    pool_destination_vault: account @mut,
    fee_destination: account @mut,
    referral_destination: account @mut,
    token_program: account,
    input_mint: pubkey,
    output_mint: pubkey,
    amount_in: u64,
    minimum_out: u64
) {
    require(!config.is_paused);
    require(amount_in > 0);
    require(minimum_out > 0);

    // Execute the single hop
    let raw_out: u64 = execute_hop(pool, input_mint, amount_in);

    // Calculate and deduct platform fee
    let platform_fee: u64 = calc_platform_fee(raw_out, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_platform_fee: u64 = platform_fee - referral_fee;
    let actual_out: u64 = raw_out - platform_fee;

    // Slippage protection
    require(actual_out >= minimum_out);

    // Transfer tokens: user sends input
    spl_token::SPLToken::transfer(user_source, pool_source_vault, user, amount_in);
    // Pool sends output to user
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, config, actual_out);
    // Platform fee to fee collector
    if (net_platform_fee > 0) {
        spl_token::SPLToken::transfer(pool_destination_vault, fee_destination, config, net_platform_fee);
    }
    // Referral fee
    if (referral_fee > 0) {
        spl_token::SPLToken::transfer(pool_destination_vault, referral_destination, config, referral_fee);
    }

    // Record route state
    route.config = config.ctx.key;
    route.user = user.ctx.key;
    route.input_mint = input_mint;
    route.output_mint = output_mint;
    route.amount_in = amount_in;
    route.minimum_out = minimum_out;
    route.actual_out = actual_out;
    route.num_hops = 1;
    route.platform_fee_amount = platform_fee;
    route.referral_fee_amount = referral_fee;
    route.timestamp = get_clock().unix_timestamp as u64;

    // Update global stats
    config.total_volume = config.total_volume + amount_in as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 3. Route Swap Two Hop -- A -> B -> C through 2 AMM pools
// ===========================================================================

pub route_swap_two_hop(
    config: JupiterConfig @mut,
    route: RouteState @mut @init(payer=user, space=512) @signer,
    pool_1: Pool @mut,
    pool_2: Pool @mut,
    user: account @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_1_source_vault: account @mut,
    pool_1_dest_vault: account @mut,
    pool_2_source_vault: account @mut,
    pool_2_dest_vault: account @mut,
    fee_destination: account @mut,
    referral_destination: account @mut,
    token_program: account,
    input_mint: pubkey,
    intermediate_mint: pubkey,
    output_mint: pubkey,
    amount_in: u64,
    minimum_out: u64
) {
    require(!config.is_paused);
    require(amount_in > 0);
    require(minimum_out > 0);

    // Hop 1: input_mint -> intermediate_mint
    let intermediate_amount: u64 = execute_hop(pool_1, input_mint, amount_in);
    require(intermediate_amount > 0);

    // Hop 2: intermediate_mint -> output_mint
    let raw_out: u64 = execute_hop(pool_2, intermediate_mint, intermediate_amount);
    require(raw_out > 0);

    // Calculate and deduct platform fee on final output
    let platform_fee: u64 = calc_platform_fee(raw_out, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_platform_fee: u64 = platform_fee - referral_fee;
    let actual_out: u64 = raw_out - platform_fee;

    // Slippage protection on final output
    require(actual_out >= minimum_out);

    // Token transfers
    // User sends input to first pool
    spl_token::SPLToken::transfer(user_source, pool_1_source_vault, user, amount_in);
    // Intermediate: pool_1 output vault -> pool_2 input vault
    spl_token::SPLToken::transfer(pool_1_dest_vault, pool_2_source_vault, config, intermediate_amount);
    // Final output to user
    spl_token::SPLToken::transfer(pool_2_dest_vault, user_destination, config, actual_out);
    // Fees
    if (net_platform_fee > 0) {
        spl_token::SPLToken::transfer(pool_2_dest_vault, fee_destination, config, net_platform_fee);
    }
    if (referral_fee > 0) {
        spl_token::SPLToken::transfer(pool_2_dest_vault, referral_destination, config, referral_fee);
    }

    // Record route state
    route.config = config.ctx.key;
    route.user = user.ctx.key;
    route.input_mint = input_mint;
    route.output_mint = output_mint;
    route.amount_in = amount_in;
    route.minimum_out = minimum_out;
    route.actual_out = actual_out;
    route.num_hops = 2;
    route.platform_fee_amount = platform_fee;
    route.referral_fee_amount = referral_fee;
    route.timestamp = get_clock().unix_timestamp as u64;

    // Update global stats
    config.total_volume = config.total_volume + amount_in as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 4. Route Swap Three Hop -- A -> B -> C -> D through 3 AMM pools
// ===========================================================================

pub route_swap_three_hop(
    config: JupiterConfig @mut,
    route: RouteState @mut @init(payer=user, space=512) @signer,
    pool_1: Pool @mut,
    pool_2: Pool @mut,
    pool_3: Pool @mut,
    user: account @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_1_source_vault: account @mut,
    pool_1_dest_vault: account @mut,
    pool_2_source_vault: account @mut,
    pool_2_dest_vault: account @mut,
    pool_3_source_vault: account @mut,
    pool_3_dest_vault: account @mut,
    fee_destination: account @mut,
    referral_destination: account @mut,
    token_program: account,
    input_mint: pubkey,
    intermediate_mint_1: pubkey,
    intermediate_mint_2: pubkey,
    output_mint: pubkey,
    amount_in: u64,
    minimum_out: u64
) {
    require(!config.is_paused);
    require(amount_in > 0);
    require(minimum_out > 0);

    // Hop 1: input_mint -> intermediate_mint_1
    let intermediate_1: u64 = execute_hop(pool_1, input_mint, amount_in);
    require(intermediate_1 > 0);

    // Hop 2: intermediate_mint_1 -> intermediate_mint_2
    let intermediate_2: u64 = execute_hop(pool_2, intermediate_mint_1, intermediate_1);
    require(intermediate_2 > 0);

    // Hop 3: intermediate_mint_2 -> output_mint
    let raw_out: u64 = execute_hop(pool_3, intermediate_mint_2, intermediate_2);
    require(raw_out > 0);

    // Platform fee on final output
    let platform_fee: u64 = calc_platform_fee(raw_out, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_platform_fee: u64 = platform_fee - referral_fee;
    let actual_out: u64 = raw_out - platform_fee;

    // Slippage protection
    require(actual_out >= minimum_out);

    // Token transfers through all three hops
    spl_token::SPLToken::transfer(user_source, pool_1_source_vault, user, amount_in);
    spl_token::SPLToken::transfer(pool_1_dest_vault, pool_2_source_vault, config, intermediate_1);
    spl_token::SPLToken::transfer(pool_2_dest_vault, pool_3_source_vault, config, intermediate_2);
    spl_token::SPLToken::transfer(pool_3_dest_vault, user_destination, config, actual_out);
    if (net_platform_fee > 0) {
        spl_token::SPLToken::transfer(pool_3_dest_vault, fee_destination, config, net_platform_fee);
    }
    if (referral_fee > 0) {
        spl_token::SPLToken::transfer(pool_3_dest_vault, referral_destination, config, referral_fee);
    }

    // Record route state
    route.config = config.ctx.key;
    route.user = user.ctx.key;
    route.input_mint = input_mint;
    route.output_mint = output_mint;
    route.amount_in = amount_in;
    route.minimum_out = minimum_out;
    route.actual_out = actual_out;
    route.num_hops = 3;
    route.platform_fee_amount = platform_fee;
    route.referral_fee_amount = referral_fee;
    route.timestamp = get_clock().unix_timestamp as u64;

    config.total_volume = config.total_volume + amount_in as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 5. Split Route Swap -- Split input across 2 pools for same pair
// ===========================================================================
// Optimizes large trades by splitting volume across two liquidity sources.
// The off-chain SDK determines the optimal split percentage; the on-chain
// program executes both legs and sums the outputs.

pub split_route_swap(
    config: JupiterConfig @mut,
    route: RouteState @mut @init(payer=user, space=512) @signer,
    pool_a: Pool @mut,
    pool_b: Pool @mut,
    user: account @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_a_source_vault: account @mut,
    pool_a_dest_vault: account @mut,
    pool_b_source_vault: account @mut,
    pool_b_dest_vault: account @mut,
    fee_destination: account @mut,
    referral_destination: account @mut,
    token_program: account,
    input_mint: pubkey,
    output_mint: pubkey,
    total_amount_in: u64,
    split_bps: u64,
    minimum_out: u64
) {
    require(!config.is_paused);
    require(total_amount_in > 0);
    require(minimum_out > 0);
    require(split_bps > 0);
    require(split_bps < 10000);

    // Split the input: leg A gets split_bps/10000, leg B gets the rest
    let amount_leg_a: u64 = (total_amount_in * split_bps) / 10000;
    let amount_leg_b: u64 = total_amount_in - amount_leg_a;
    require(amount_leg_a > 0);
    require(amount_leg_b > 0);

    // Execute both legs independently
    let out_leg_a: u64 = execute_hop(pool_a, input_mint, amount_leg_a);
    require(out_leg_a > 0);

    let out_leg_b: u64 = execute_hop(pool_b, input_mint, amount_leg_b);
    require(out_leg_b > 0);

    // Sum outputs
    let raw_out: u64 = out_leg_a + out_leg_b;

    // Platform fee on combined output
    let platform_fee: u64 = calc_platform_fee(raw_out, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_platform_fee: u64 = platform_fee - referral_fee;
    let actual_out: u64 = raw_out - platform_fee;

    // Slippage protection on combined output
    require(actual_out >= minimum_out);

    // Token transfers: user input split across both pools
    spl_token::SPLToken::transfer(user_source, pool_a_source_vault, user, amount_leg_a);
    spl_token::SPLToken::transfer(user_source, pool_b_source_vault, user, amount_leg_b);
    // Combined output from both pools to user
    spl_token::SPLToken::transfer(pool_a_dest_vault, user_destination, config, out_leg_a);
    spl_token::SPLToken::transfer(pool_b_dest_vault, user_destination, config, out_leg_b);
    // Deduct fees from user_destination (already received full output above,
    // so we transfer fee portion out to fee accounts)
    if (net_platform_fee > 0) {
        spl_token::SPLToken::transfer(user_destination, fee_destination, user, net_platform_fee);
    }
    if (referral_fee > 0) {
        spl_token::SPLToken::transfer(user_destination, referral_destination, user, referral_fee);
    }

    // Record route state
    route.config = config.ctx.key;
    route.user = user.ctx.key;
    route.input_mint = input_mint;
    route.output_mint = output_mint;
    route.amount_in = total_amount_in;
    route.minimum_out = minimum_out;
    route.actual_out = actual_out;
    route.num_hops = 1;
    route.platform_fee_amount = platform_fee;
    route.referral_fee_amount = referral_fee;
    route.timestamp = get_clock().unix_timestamp as u64;

    config.total_volume = config.total_volume + total_amount_in as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 6. Create Limit Order
// ===========================================================================
// Place a limit order to buy/sell at a target price. The order sits on-chain
// until a keeper fills it or it expires.

pub create_limit_order(
    config: JupiterConfig,
    order: LimitOrder @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    user_input_account: account @mut,
    escrow_account: account @mut,
    token_program: account,
    input_mint: pubkey,
    output_mint: pubkey,
    input_amount: u64,
    minimum_output: u64,
    expiry_timestamp: u64,
    order_id: u64
) {
    require(!config.is_paused);
    require(input_amount > 0);
    require(minimum_output > 0);
    require(expiry_timestamp > get_clock().unix_timestamp as u64);

    // Transfer input tokens to escrow
    spl_token::SPLToken::transfer(user_input_account, escrow_account, owner, input_amount);

    // Initialize order state
    order.config = config.ctx.key;
    order.owner = owner.ctx.key;
    order.input_mint = input_mint;
    order.output_mint = output_mint;
    order.input_amount = input_amount;
    order.minimum_output = minimum_output;
    order.filled_input = 0;
    order.filled_output = 0;
    order.expiry_timestamp = expiry_timestamp;
    order.is_active = true;
    order.order_id = order_id;
}

// ===========================================================================
// 7. Cancel Limit Order
// ===========================================================================

pub cancel_limit_order(
    order: LimitOrder @mut,
    owner: account @signer,
    escrow_account: account @mut,
    user_input_account: account @mut,
    config: JupiterConfig @signer,
    token_program: account
) {
    require(order.owner == owner.ctx.key);
    require(order.is_active);

    // Refund unfilled input tokens from escrow
    let unfilled: u64 = order.input_amount - order.filled_input;
    if (unfilled > 0) {
        spl_token::SPLToken::transfer(escrow_account, user_input_account, config, unfilled);
    }

    order.is_active = false;
}

// ===========================================================================
// 8. Fill Limit Order
// ===========================================================================
// Keeper fills a limit order when market price meets the target.
// Anyone can call this -- the keeper earns the referral fee share as incentive.
// Price check uses cross-multiplication to avoid division:
//   output_amount * order.input_amount >= order.minimum_output * input_amount

pub fill_limit_order(
    config: JupiterConfig @mut,
    order: LimitOrder @mut,
    pool: Pool @mut,
    keeper: account @mut @signer,
    escrow_account: account @mut,
    keeper_source: account @mut,
    owner_destination: account @mut,
    fee_destination: account @mut,
    token_program: account,
    fill_amount: u64
) {
    require(!config.is_paused);
    require(order.is_active);
    require(fill_amount > 0);

    // Check order not expired
    let now: u64 = get_clock().unix_timestamp as u64;
    require(now < order.expiry_timestamp);

    // Cannot fill more than remaining
    let remaining_input: u64 = order.input_amount - order.filled_input;
    require(fill_amount <= remaining_input);

    // Execute swap to determine output for this fill amount
    let raw_output: u64 = execute_hop(pool, order.input_mint, fill_amount);
    require(raw_output > 0);

    // Price check via cross-multiplication (avoids division rounding):
    // raw_output / fill_amount >= order.minimum_output / order.input_amount
    // Equivalent: raw_output * order.input_amount >= order.minimum_output * fill_amount
    let lhs: u128 = raw_output as u128 * order.input_amount as u128;
    let rhs: u128 = order.minimum_output as u128 * fill_amount as u128;
    require(lhs >= rhs);

    // Calculate platform fee on output
    let platform_fee: u64 = calc_platform_fee(raw_output, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_to_owner: u64 = raw_output - platform_fee;

    // Transfer: escrow input -> pool (already accounted in execute_hop reserves)
    spl_token::SPLToken::transfer(escrow_account, keeper_source, config, fill_amount);
    // Keeper provides the output tokens to the order owner
    spl_token::SPLToken::transfer(keeper_source, owner_destination, keeper, net_to_owner);
    // Fees
    if (platform_fee - referral_fee > 0) {
        spl_token::SPLToken::transfer(keeper_source, fee_destination, keeper, platform_fee - referral_fee);
    }
    // Keeper keeps referral_fee as their incentive (already in keeper_source)

    // Update order state
    order.filled_input = order.filled_input + fill_amount;
    order.filled_output = order.filled_output + net_to_owner;

    // Deactivate if fully filled
    if (order.filled_input == order.input_amount) {
        order.is_active = false;
    }

    // Update global stats
    config.total_volume = config.total_volume + fill_amount as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 9. Expire Limit Orders
// ===========================================================================
// Clean up expired orders and refund remaining tokens to owner.

pub expire_limit_order(
    order: LimitOrder @mut,
    config: JupiterConfig @signer,
    escrow_account: account @mut,
    owner_refund_account: account @mut,
    caller: account @signer,
    token_program: account
) {
    require(order.is_active);

    // Must be past expiry
    let now: u64 = get_clock().unix_timestamp as u64;
    require(now >= order.expiry_timestamp);

    // Refund unfilled tokens
    let unfilled: u64 = order.input_amount - order.filled_input;
    if (unfilled > 0) {
        spl_token::SPLToken::transfer(escrow_account, owner_refund_account, config, unfilled);
    }

    order.is_active = false;
}

// ===========================================================================
// 10. Create DCA Schedule
// ===========================================================================
// Dollar-Cost Averaging: automatically buy output_mint every cycle_frequency
// seconds, spending amount_per_cycle of input_mint each time.

pub create_dca(
    config: JupiterConfig,
    schedule: DcaSchedule @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    user_input_account: account @mut,
    escrow_account: account @mut,
    token_program: account,
    input_mint: pubkey,
    output_mint: pubkey,
    amount_per_cycle: u64,
    cycle_frequency: u64,
    total_cycles: u64,
    min_output_per_cycle: u64
) {
    require(!config.is_paused);
    require(amount_per_cycle > 0);
    require(cycle_frequency > 0);
    require(total_cycles > 0);
    require(min_output_per_cycle > 0);

    // Total input needed = amount_per_cycle * total_cycles
    let total_input: u64 = amount_per_cycle * total_cycles;
    require(total_input > 0);

    // Escrow the full input amount upfront
    spl_token::SPLToken::transfer(user_input_account, escrow_account, owner, total_input);

    let now: u64 = get_clock().unix_timestamp as u64;

    schedule.config = config.ctx.key;
    schedule.owner = owner.ctx.key;
    schedule.input_mint = input_mint;
    schedule.output_mint = output_mint;
    schedule.amount_per_cycle = amount_per_cycle;
    schedule.cycle_frequency = cycle_frequency;
    schedule.total_cycles = total_cycles;
    schedule.cycles_executed = 0;
    schedule.total_input_spent = 0;
    schedule.total_output_received = 0;
    schedule.next_execution = now + cycle_frequency;
    schedule.is_active = true;
    schedule.min_output_per_cycle = min_output_per_cycle;
}

// ===========================================================================
// 11. Execute DCA -- Keeper triggers next DCA buy
// ===========================================================================

pub execute_dca(
    config: JupiterConfig @mut,
    schedule: DcaSchedule @mut,
    pool: Pool @mut,
    keeper: account @mut @signer,
    escrow_account: account @mut,
    pool_source_vault: account @mut,
    pool_dest_vault: account @mut,
    owner_destination: account @mut,
    fee_destination: account @mut,
    token_program: account
) {
    require(!config.is_paused);
    require(schedule.is_active);
    require(schedule.cycles_executed < schedule.total_cycles);

    // Check timing
    let now: u64 = get_clock().unix_timestamp as u64;
    require(now >= schedule.next_execution);

    // Execute swap for this cycle
    let amount_in: u64 = schedule.amount_per_cycle;
    let raw_out: u64 = execute_hop(pool, schedule.input_mint, amount_in);
    require(raw_out > 0);

    // Platform fee on output
    let platform_fee: u64 = calc_platform_fee(raw_out, config.platform_fee_bps);
    let referral_fee: u64 = calc_referral_fee(platform_fee, config.referral_fee_share);
    let net_platform_fee: u64 = platform_fee - referral_fee;
    let actual_out: u64 = raw_out - platform_fee;

    // Slippage protection per cycle
    require(actual_out >= schedule.min_output_per_cycle);

    // Token transfers
    spl_token::SPLToken::transfer(escrow_account, pool_source_vault, config, amount_in);
    spl_token::SPLToken::transfer(pool_dest_vault, owner_destination, config, actual_out);
    if (net_platform_fee > 0) {
        spl_token::SPLToken::transfer(pool_dest_vault, fee_destination, config, net_platform_fee);
    }
    // Keeper gets referral_fee as execution incentive
    if (referral_fee > 0) {
        spl_token::SPLToken::transfer(pool_dest_vault, keeper, config, referral_fee);
    }

    // Update schedule state
    schedule.cycles_executed = schedule.cycles_executed + 1;
    schedule.total_input_spent = schedule.total_input_spent + amount_in;
    schedule.total_output_received = schedule.total_output_received + actual_out;
    schedule.next_execution = now + schedule.cycle_frequency;

    // Deactivate if all cycles complete
    if (schedule.cycles_executed == schedule.total_cycles) {
        schedule.is_active = false;
    }

    // Update global stats
    config.total_volume = config.total_volume + amount_in as u128;
    config.total_routes_executed = config.total_routes_executed + 1;
}

// ===========================================================================
// 12. Cancel DCA
// ===========================================================================

pub cancel_dca(
    schedule: DcaSchedule @mut,
    config: JupiterConfig @signer,
    owner: account @signer,
    escrow_account: account @mut,
    owner_refund_account: account @mut,
    token_program: account
) {
    require(schedule.owner == owner.ctx.key);
    require(schedule.is_active);

    // Refund remaining escrowed input tokens
    let remaining_cycles: u64 = schedule.total_cycles - schedule.cycles_executed;
    let refund_amount: u64 = remaining_cycles * schedule.amount_per_cycle;

    if (refund_amount > 0) {
        spl_token::SPLToken::transfer(escrow_account, owner_refund_account, config, refund_amount);
    }

    schedule.is_active = false;
}

// ===========================================================================
// 13. Close DCA -- Close completed DCA account
// ===========================================================================

pub close_dca(
    schedule: DcaSchedule @mut,
    owner: account @signer,
    escrow_account: account @mut,
    owner_refund_account: account @mut,
    config: JupiterConfig @signer,
    token_program: account
) {
    require(schedule.owner == owner.ctx.key);
    require(!schedule.is_active);
    require(schedule.cycles_executed == schedule.total_cycles);

    // Any dust remaining in escrow gets returned
    // (Normally zero if all cycles executed, but handles rounding)
    let total_escrowed: u64 = schedule.amount_per_cycle * schedule.total_cycles;
    let mut dust: u64 = 0;
    if (total_escrowed > schedule.total_input_spent) {
        dust = total_escrowed - schedule.total_input_spent;
    }
    if (dust > 0) {
        spl_token::SPLToken::transfer(escrow_account, owner_refund_account, config, dust);
    }

    // Zero out the schedule (account can be reclaimed by runtime)
    schedule.cycles_executed = 0;
    schedule.total_cycles = 0;
    schedule.amount_per_cycle = 0;
}

// ===========================================================================
// 14. Set Platform Fee
// ===========================================================================

pub set_platform_fee(
    config: JupiterConfig @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_fee_bps <= 1000);
    config.platform_fee_bps = new_fee_bps;
}

// ===========================================================================
// 15. Set Referral Fee
// ===========================================================================

pub set_referral_fee(
    config: JupiterConfig @mut,
    authority: account @signer,
    new_referral_share: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_referral_share <= 100);
    config.referral_fee_share = new_referral_share;
}

// ===========================================================================
// 16. Collect Platform Fees
// ===========================================================================

pub collect_platform_fees(
    config: JupiterConfig @signer,
    authority: account @signer,
    fee_vault: account @mut,
    recipient: account @mut,
    token_program: account,
    amount: u64
) {
    require(config.authority == authority.ctx.key);
    require(config.fee_collector == recipient.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(fee_vault, recipient, config, amount);
}

// ===========================================================================
// 17. Set Authority -- Transfer admin
// ===========================================================================

pub set_authority(
    config: JupiterConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

// ===========================================================================
// 18. Pause -- Emergency halt all operations
// ===========================================================================

pub pause(
    config: JupiterConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    require(!config.is_paused);
    config.is_paused = true;
}

// ===========================================================================
// 19. Unpause -- Resume operations
// ===========================================================================

pub unpause(
    config: JupiterConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    require(config.is_paused);
    config.is_paused = false;
}

// ===========================================================================
// Read-Only Helpers
// ===========================================================================

pub get_total_volume(config: JupiterConfig) -> u128 {
    return config.total_volume;
}

pub get_total_routes(config: JupiterConfig) -> u64 {
    return config.total_routes_executed;
}

pub get_platform_fee_bps(config: JupiterConfig) -> u64 {
    return config.platform_fee_bps;
}

pub get_order_status(order: LimitOrder) -> bool {
    return order.is_active;
}

pub get_order_filled(order: LimitOrder) -> u64 {
    return order.filled_input;
}

pub get_order_remaining(order: LimitOrder) -> u64 {
    return order.input_amount - order.filled_input;
}

pub get_dca_cycles_remaining(schedule: DcaSchedule) -> u64 {
    if (!schedule.is_active) {
        return 0;
    }
    return schedule.total_cycles - schedule.cycles_executed;
}

pub get_dca_next_execution(schedule: DcaSchedule) -> u64 {
    return schedule.next_execution;
}

pub get_dca_total_output(schedule: DcaSchedule) -> u64 {
    return schedule.total_output_received;
}

// Quote a single-hop swap without executing (read-only)
pub quote_swap(
    pool: Pool,
    input_mint: pubkey,
    amount_in: u64,
    platform_fee_bps: u64
) -> u64 {
    require(pool.is_active);
    require(pool.reserve_a > 0);
    require(pool.reserve_b > 0);
    require(amount_in > 0);

    let mut raw_out: u64 = 0;

    if (input_mint == pool.token_a_mint) {
        raw_out = compute_swap_output(pool.reserve_a, pool.reserve_b, amount_in, pool.fee_bps);
    } else {
        raw_out = compute_swap_output(pool.reserve_b, pool.reserve_a, amount_in, pool.fee_bps);
    }

    let platform_fee: u64 = calc_platform_fee(raw_out, platform_fee_bps);
    let net_out: u64 = raw_out - platform_fee;
    return net_out;
}

// Check if a limit order price condition is currently met
pub check_limit_price(
    order: LimitOrder,
    pool: Pool,
    fill_amount: u64
) -> bool {
    if (!order.is_active) {
        return false;
    }
    if (!pool.is_active) {
        return false;
    }
    if (fill_amount == 0) {
        return false;
    }

    let remaining: u64 = order.input_amount - order.filled_input;
    if (fill_amount > remaining) {
        return false;
    }

    let mut raw_output: u64 = 0;
    if (order.input_mint == pool.token_a_mint) {
        raw_output = compute_swap_output(pool.reserve_a, pool.reserve_b, fill_amount, pool.fee_bps);
    } else {
        raw_output = compute_swap_output(pool.reserve_b, pool.reserve_a, fill_amount, pool.fee_bps);
    }

    // Cross-multiplication price check
    let lhs: u128 = raw_output as u128 * order.input_amount as u128;
    let rhs: u128 = order.minimum_output as u128 * fill_amount as u128;
    return lhs >= rhs;
}
