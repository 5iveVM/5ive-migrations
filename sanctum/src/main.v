// 5IVE Sanctum -- LST Aggregator & Infinity Pool
//
// Sanctum is the unified liquidity layer for all liquid staking tokens (LSTs)
// on Solana. It enables instant swaps between any LST (mSOL, jitoSOL, stSOL,
// bSOL, etc.) at fair oracle-derived exchange rates, backed by the Infinity Pool.
//
// Key innovation -- Infinity Pool:
//   A deep SOL liquidity pool that acts as the universal intermediary for all
//   LST conversions. Instead of needing pair-specific pools (mSOL/jitoSOL,
//   jitoSOL/stSOL, etc.), every swap routes through SOL:
//     LST_A -> SOL (at LST_A exchange rate) -> LST_B (at LST_B exchange rate)
//   This means N LSTs need only 1 pool instead of N*(N-1)/2 pairs.
//
// Key mechanics:
//   - LST registration: each LST has an oracle-derived exchange rate to SOL
//   - Swap: convert between any two registered LSTs via the Infinity Pool
//   - Liquidity providers deposit SOL into the Infinity Pool, receive LP tokens
//   - Per-LST fee overrides allow pricing illiquid LSTs differently
//
// Precision:
//   - Exchange rates: RATE_PRECISION = 1_000_000_000 (1e9)
//   - Fees in basis points: FEE_DENOMINATOR = 10000
//   - All math integer-only; rates stored as u64 scaled by 1e9

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account RouterConfig {
    authority: pubkey;               // Admin authority
    infinity_pool_vault: pubkey;     // SOL vault backing instant conversions
    total_liquidity: u64;            // Total SOL across all registered LSTs
    swap_fee_bps: u64;              // Default swap fee in basis points
    num_registered_lsts: u32;        // Number of registered LST types
    max_registered_lsts: u32;        // Maximum LSTs allowed
    is_paused: bool;
    max_slippage_bps: u64;          // Global max slippage tolerance
    collected_fees: u64;             // Accumulated protocol fees (in SOL-equivalent)
}

account LstEntry {
    config: pubkey;                  // Parent RouterConfig
    lst_mint: pubkey;                // SPL mint of the LST
    oracle: pubkey;                  // Price oracle for this LST
    exchange_rate: u64;              // LST/SOL rate (scaled 1e9, e.g. 1.05 SOL per LST = 1_050_000_000)
    last_rate_update: u64;           // Slot of last rate update
    fee_override_bps: u64;          // Per-LST fee override (0 = use default)
    total_volume: u64;               // Lifetime swap volume through this LST
    is_active: bool;                 // Whether this LST is enabled for swaps
    lst_vault: pubkey;               // Vault holding this LST
}

account InfinityPool {
    config: pubkey;                  // Parent RouterConfig
    sol_vault: pubkey;               // Deep SOL liquidity vault
    lp_mint: pubkey;                 // LP token mint for pool depositors
    total_sol: u64;                  // Total SOL in the pool
    lp_supply: u64;                  // Total LP tokens outstanding
    fee_collector: pubkey;           // Address that collects fees
}

account LpPosition {
    pool: pubkey;                    // Parent InfinityPool
    owner: pubkey;                   // LP token holder
    lp_shares: u64;                  // LP shares held
    deposited_at: u64;               // Slot of deposit
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
// RATE_PRECISION = 1_000_000_000
// FEE_DENOMINATOR = 10000
// STALENESS_WINDOW = 100 (slots)

// ---------------------------------------------------------------------------
// Router Initialization
// ---------------------------------------------------------------------------

pub initialize(
    config: RouterConfig @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    infinity_pool_vault: pubkey,
    swap_fee_bps: u64,
    max_registered_lsts: u32,
    max_slippage_bps: u64
) {
    require(swap_fee_bps <= 500);         // Max 5%
    require(max_registered_lsts > 0);
    require(max_slippage_bps <= 1000);    // Max 10% slippage

    config.authority = admin.ctx.key;
    config.infinity_pool_vault = infinity_pool_vault;
    config.total_liquidity = 0;
    config.swap_fee_bps = swap_fee_bps;
    config.num_registered_lsts = 0;
    config.max_registered_lsts = max_registered_lsts;
    config.is_paused = false;
    config.max_slippage_bps = max_slippage_bps;
    config.collected_fees = 0;
}

// ---------------------------------------------------------------------------
// Infinity Pool
// ---------------------------------------------------------------------------

pub create_infinity_pool(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @init(payer=admin, space=512),
    admin: account @mut @signer,
    sol_vault: pubkey,
    lp_mint: pubkey,
    fee_collector: pubkey
) {
    require(config.authority == admin.ctx.key);

    pool.config = config.ctx.key;
    pool.sol_vault = sol_vault;
    pool.lp_mint = lp_mint;
    pool.total_sol = 0;
    pool.lp_supply = 0;
    pool.fee_collector = fee_collector;
}

// add_liquidity: deposit SOL into the Infinity Pool, receive LP tokens
pub add_liquidity(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    position: LpPosition @mut @init(payer=depositor, space=256),
    user_sol_account: account @mut,
    sol_vault: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    depositor: account @mut @signer,
    token_program: account,
    amount: u64
) {
    require(!config.is_paused);
    require(pool.config == config.ctx.key);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(lp_mint.ctx.key == pool.lp_mint);
    require(amount > 0);

    // Calculate LP tokens to mint
    let mut lp_to_mint: u64 = 0;
    if (pool.lp_supply == 0) {
        // First deposit: 1:1
        lp_to_mint = amount;
    } else {
        // Proportional: lp_to_mint = (amount * lp_supply) / total_sol
        lp_to_mint = (amount * pool.lp_supply) / pool.total_sol;
    }
    require(lp_to_mint > 0);

    // Transfer SOL into vault
    spl_token::SPLToken::transfer(user_sol_account, sol_vault, depositor, amount);

    // Mint LP tokens
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    pool.total_sol = pool.total_sol + amount;
    pool.lp_supply = pool.lp_supply + lp_to_mint;
    config.total_liquidity = config.total_liquidity + amount;

    // Record position
    let clock: Clock = get_clock();
    position.pool = pool.ctx.key;
    position.owner = depositor.ctx.key;
    position.lp_shares = lp_to_mint;
    position.deposited_at = clock.slot;
}

// remove_liquidity: burn LP tokens, withdraw SOL from the Infinity Pool
pub remove_liquidity(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    position: LpPosition @mut,
    user_lp_account: account @mut,
    lp_mint: account @mut,
    sol_vault: account @mut,
    user_sol_account: account @mut,
    depositor: account @signer,
    token_program: account,
    lp_amount: u64
) {
    require(pool.config == config.ctx.key);
    require(position.pool == pool.ctx.key);
    require(position.owner == depositor.ctx.key);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(lp_mint.ctx.key == pool.lp_mint);
    require(lp_amount > 0);
    require(lp_amount <= position.lp_shares);
    require(lp_amount <= pool.lp_supply);

    // Calculate SOL to return
    let sol_to_return: u64 = (lp_amount * pool.total_sol) / pool.lp_supply;
    require(sol_to_return > 0);

    // Burn LP tokens
    spl_token::SPLToken::burn(user_lp_account, lp_mint, depositor, lp_amount);

    // Transfer SOL back
    spl_token::SPLToken::transfer(sol_vault, user_sol_account, pool, sol_to_return);

    pool.total_sol = pool.total_sol - sol_to_return;
    pool.lp_supply = pool.lp_supply - lp_amount;
    config.total_liquidity = config.total_liquidity - sol_to_return;
    position.lp_shares = position.lp_shares - lp_amount;
}

// ---------------------------------------------------------------------------
// LST Registration & Rate Management
// ---------------------------------------------------------------------------

// register_lst: register a new liquid staking token with the router
pub register_lst(
    config: RouterConfig @mut,
    entry: LstEntry @mut @init(payer=admin, space=512),
    admin: account @mut @signer,
    lst_mint: pubkey,
    oracle: pubkey,
    lst_vault: pubkey,
    initial_rate: u64
) {
    require(config.authority == admin.ctx.key);
    require(config.num_registered_lsts < config.max_registered_lsts);
    require(initial_rate > 0);

    let clock: Clock = get_clock();

    entry.config = config.ctx.key;
    entry.lst_mint = lst_mint;
    entry.oracle = oracle;
    entry.exchange_rate = initial_rate;
    entry.last_rate_update = clock.slot;
    entry.fee_override_bps = 0;           // Use default fee
    entry.total_volume = 0;
    entry.is_active = true;
    entry.lst_vault = lst_vault;

    config.num_registered_lsts = config.num_registered_lsts + 1;
}

// update_lst_rate: refresh the exchange rate for a registered LST
pub update_lst_rate(
    config: RouterConfig @mut,
    entry: LstEntry @mut,
    authority: account @signer,
    new_rate: u64
) {
    require(config.authority == authority.ctx.key);
    require(entry.config == config.ctx.key);
    require(entry.is_active);
    require(new_rate > 0);

    let clock: Clock = get_clock();

    entry.exchange_rate = new_rate;
    entry.last_rate_update = clock.slot;
}

// ---------------------------------------------------------------------------
// Helper: get effective fee for an LST
// ---------------------------------------------------------------------------

fn get_effective_fee(config_fee: u64, override_fee: u64) -> u64 {
    if (override_fee > 0) {
        return override_fee;
    }
    return config_fee;
}

// Helper: check rate staleness
fn check_rate_fresh(last_update: u64, current_slot: u64) -> bool {
    if (current_slot - last_update <= 100) {
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Swaps (Core Functionality)
// ---------------------------------------------------------------------------

// swap_lst: swap between any two LSTs via the Infinity Pool
// Route: LST_A -> SOL (at LST_A rate) -> LST_B (at LST_B rate)
pub swap_lst(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    entry_a: LstEntry @mut,
    entry_b: LstEntry @mut,
    user_lst_a_account: account @mut,
    user_lst_b_account: account @mut,
    lst_a_vault: account @mut,
    lst_b_vault: account @mut,
    sol_vault: account @mut,
    user: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64
) {
    require(!config.is_paused);
    require(entry_a.config == config.ctx.key);
    require(entry_b.config == config.ctx.key);
    require(entry_a.is_active);
    require(entry_b.is_active);
    require(lst_a_vault.ctx.key == entry_a.lst_vault);
    require(lst_b_vault.ctx.key == entry_b.lst_vault);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(pool.config == config.ctx.key);
    require(amount_in > 0);

    let clock: Clock = get_clock();
    require(check_rate_fresh(entry_a.last_rate_update, clock.slot));
    require(check_rate_fresh(entry_b.last_rate_update, clock.slot));

    // Step 1: Convert LST_A to SOL value
    // sol_value = (amount_in * exchange_rate_a) / RATE_PRECISION
    let sol_value: u64 = (amount_in * entry_a.exchange_rate) / 1000000000;
    require(sol_value > 0);

    // Step 2: Apply swap fee
    let fee_a: u64 = get_effective_fee(config.swap_fee_bps, entry_a.fee_override_bps);
    let fee_b: u64 = get_effective_fee(config.swap_fee_bps, entry_b.fee_override_bps);
    let total_fee_bps: u64 = fee_a + fee_b;
    let fee_amount: u64 = (sol_value * total_fee_bps) / 10000;
    let net_sol_value: u64 = sol_value - fee_amount;

    // Step 3: Convert SOL value to LST_B amount
    // amount_out = (net_sol_value * RATE_PRECISION) / exchange_rate_b
    let amount_out: u64 = (net_sol_value * 1000000000) / entry_b.exchange_rate;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);

    // Slippage check against max
    let expected_no_fee: u64 = (sol_value * 1000000000) / entry_b.exchange_rate;
    if (expected_no_fee > 0) {
        let slippage_bps: u64 = ((expected_no_fee - amount_out) * 10000) / expected_no_fee;
        require(slippage_bps <= config.max_slippage_bps);
    }

    // Execute token transfers
    // User sends LST_A to vault A
    spl_token::SPLToken::transfer(user_lst_a_account, lst_a_vault, user, amount_in);

    // User receives LST_B from vault B
    spl_token::SPLToken::transfer(lst_b_vault, user_lst_b_account, pool, amount_out);

    // Track fees and volume
    config.collected_fees = config.collected_fees + fee_amount;
    entry_a.total_volume = entry_a.total_volume + amount_in;
    entry_b.total_volume = entry_b.total_volume + amount_out;
}

// swap_lst_to_sol: convert any LST to SOL (unstake via Infinity Pool)
pub swap_lst_to_sol(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    entry: LstEntry @mut,
    user_lst_account: account @mut,
    lst_vault: account @mut,
    sol_vault: account @mut,
    user_sol_account: account @mut,
    user: account @signer,
    token_program: account,
    amount_in: u64,
    min_sol_out: u64
) {
    require(!config.is_paused);
    require(entry.config == config.ctx.key);
    require(entry.is_active);
    require(lst_vault.ctx.key == entry.lst_vault);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(pool.config == config.ctx.key);
    require(amount_in > 0);

    let clock: Clock = get_clock();
    require(check_rate_fresh(entry.last_rate_update, clock.slot));

    // Convert LST to SOL value
    let sol_value: u64 = (amount_in * entry.exchange_rate) / 1000000000;
    require(sol_value > 0);

    // Apply fee
    let fee_bps: u64 = get_effective_fee(config.swap_fee_bps, entry.fee_override_bps);
    let fee: u64 = (sol_value * fee_bps) / 10000;
    let net_sol: u64 = sol_value - fee;
    require(net_sol >= min_sol_out);

    // Must have sufficient SOL in Infinity Pool
    require(pool.total_sol >= net_sol);

    // User sends LST to vault
    spl_token::SPLToken::transfer(user_lst_account, lst_vault, user, amount_in);

    // User receives SOL from pool
    spl_token::SPLToken::transfer(sol_vault, user_sol_account, pool, net_sol);

    pool.total_sol = pool.total_sol - net_sol;
    config.collected_fees = config.collected_fees + fee;
    entry.total_volume = entry.total_volume + amount_in;
}

// swap_sol_to_lst: convert SOL to any registered LST (stake via Infinity Pool)
pub swap_sol_to_lst(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    entry: LstEntry @mut,
    user_sol_account: account @mut,
    sol_vault: account @mut,
    lst_vault: account @mut,
    user_lst_account: account @mut,
    user: account @signer,
    token_program: account,
    sol_amount: u64,
    min_lst_out: u64
) {
    require(!config.is_paused);
    require(entry.config == config.ctx.key);
    require(entry.is_active);
    require(lst_vault.ctx.key == entry.lst_vault);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(pool.config == config.ctx.key);
    require(sol_amount > 0);

    let clock: Clock = get_clock();
    require(check_rate_fresh(entry.last_rate_update, clock.slot));

    // Apply fee on SOL input
    let fee_bps: u64 = get_effective_fee(config.swap_fee_bps, entry.fee_override_bps);
    let fee: u64 = (sol_amount * fee_bps) / 10000;
    let net_sol: u64 = sol_amount - fee;

    // Convert SOL to LST amount
    // lst_out = (net_sol * RATE_PRECISION) / exchange_rate
    let lst_out: u64 = (net_sol * 1000000000) / entry.exchange_rate;
    require(lst_out > 0);
    require(lst_out >= min_lst_out);

    // User sends SOL to pool
    spl_token::SPLToken::transfer(user_sol_account, sol_vault, user, sol_amount);

    // User receives LST from vault
    spl_token::SPLToken::transfer(lst_vault, user_lst_account, pool, lst_out);

    pool.total_sol = pool.total_sol + net_sol;
    config.collected_fees = config.collected_fees + fee;
    entry.total_volume = entry.total_volume + lst_out;
}

// ---------------------------------------------------------------------------
// Admin: Fee & LST Management
// ---------------------------------------------------------------------------

pub set_swap_fee(
    config: RouterConfig @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_fee_bps <= 500);
    config.swap_fee_bps = new_fee_bps;
}

pub set_lst_fee(
    config: RouterConfig @mut,
    entry: LstEntry @mut,
    authority: account @signer,
    new_fee_override_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(entry.config == config.ctx.key);
    require(new_fee_override_bps <= 1000);  // Per-LST max 10%
    entry.fee_override_bps = new_fee_override_bps;
}

pub disable_lst(
    config: RouterConfig @mut,
    entry: LstEntry @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    require(entry.config == config.ctx.key);
    require(entry.is_active);
    entry.is_active = false;
}

pub enable_lst(
    config: RouterConfig @mut,
    entry: LstEntry @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    require(entry.config == config.ctx.key);
    require(!entry.is_active);
    entry.is_active = true;
}

pub set_authority(
    config: RouterConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

pub pause(
    config: RouterConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    config.is_paused = true;
}

pub unpause(
    config: RouterConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    config.is_paused = false;
}

pub set_max_slippage(
    config: RouterConfig @mut,
    authority: account @signer,
    new_max_slippage_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_max_slippage_bps <= 2000);  // Max 20%
    config.max_slippage_bps = new_max_slippage_bps;
}

// collect_fees: sweep accumulated protocol fees
pub collect_fees(
    config: RouterConfig @mut,
    pool: InfinityPool @mut @signer,
    sol_vault: account @mut,
    fee_recipient: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(config.authority == authority.ctx.key);
    require(pool.config == config.ctx.key);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(config.collected_fees > 0);

    let fees: u64 = config.collected_fees;
    spl_token::SPLToken::transfer(sol_vault, fee_recipient, pool, fees);
    config.collected_fees = 0;
}
