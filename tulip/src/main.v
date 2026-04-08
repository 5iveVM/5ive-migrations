// 5IVE Tulip Protocol -- Yield Aggregator Migration
//
// Tulip is a yield aggregator on Solana that auto-compounds vault strategies
// across lending protocols, AMM LP positions, and leveraged farming.
//
// Design:
//   - Vaults hold underlying tokens; depositors receive proportional shares
//   - Three strategy types: lending (0), amm_lp (1), leveraged (2)
//   - Permissionless compound() crank harvests rewards and redeposits
//   - LendingOptimizer rotates funds across up to 3 lending platforms
//   - LeveragedVault borrows against collateral to amplify yield
//   - Performance fee (on yield) + management fee (on TVL) collected by authority
//   - Emergency withdraw bypasses strategy to return underlying directly
//   - Integer-only math; all fees in basis points (1 bps = 0.01%)

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Vault {
    underlying_mint: pubkey;
    vault_shares_mint: pubkey;
    underlying_vault: pubkey;
    strategy_type: u8;          // 0 = lending, 1 = amm_lp, 2 = leveraged
    total_deposited: u64;
    total_shares: u64;
    performance_fee_bps: u64;   // fee on yield at compound time
    management_fee_bps: u64;    // annualized fee on TVL
    last_compound: u64;         // slot of last compound
    max_deposit: u64;           // per-vault deposit cap
    authority: pubkey;
    is_paused: bool;
}

account LendingOptimizer {
    vault: pubkey;
    current_lender: u8;        // 0, 1, or 2
    rate_1: u64;               // APY of lender 1 (scaled)
    rate_2: u64;
    rate_3: u64;
    amount_1: u64;             // deposited in lender 1
    amount_2: u64;
    amount_3: u64;
}

account LeveragedVault {
    vault: pubkey;
    borrow_reserve: pubkey;    // reserve to borrow from
    borrowed_amount: u64;
    leverage_ratio: u64;       // e.g. 300 = 3x (scaled by 100)
    health_factor: u64;        // scaled by 100; must stay > 100
}

// ---------------------------------------------------------------------------
// Vault lifecycle
// ---------------------------------------------------------------------------

// 1. create_vault -- initialize a new yield vault
pub create_vault(
    vault: Vault @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    underlying_mint: pubkey,
    vault_shares_mint: pubkey,
    underlying_vault: pubkey,
    strategy_type: u8,
    performance_fee_bps: u64,
    management_fee_bps: u64,
    max_deposit: u64
) {
    // strategy_type: 0=lending, 1=amm_lp, 2=leveraged
    require(strategy_type <= 2);
    // Performance fee capped at 20% (2000 bps)
    require(performance_fee_bps <= 2000);
    // Management fee capped at 5% (500 bps)
    require(management_fee_bps <= 500);
    require(max_deposit > 0);

    vault.underlying_mint = underlying_mint;
    vault.vault_shares_mint = vault_shares_mint;
    vault.underlying_vault = underlying_vault;
    vault.strategy_type = strategy_type;
    vault.total_deposited = 0;
    vault.total_shares = 0;
    vault.performance_fee_bps = performance_fee_bps;
    vault.management_fee_bps = management_fee_bps;
    vault.last_compound = get_clock().slot;
    vault.max_deposit = max_deposit;
    vault.authority = creator.ctx.key;
    vault.is_paused = false;
}

// 2. deposit -- deposit underlying tokens, receive vault shares
pub deposit(
    vault: Vault @mut @signer,
    user_underlying: account @mut,
    vault_underlying: account @mut,
    shares_mint: account @mut,
    user_shares: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!vault.is_paused);
    require(amount > 0);
    require(vault_underlying.ctx.key == vault.underlying_vault);
    require(shares_mint.ctx.key == vault.vault_shares_mint);
    require(vault.total_deposited + amount <= vault.max_deposit);

    // Calculate shares: if first deposit, 1:1; otherwise proportional
    let mut shares_to_mint: u64 = 0;
    if (vault.total_shares == 0) {
        shares_to_mint = amount;
    } else {
        shares_to_mint = (amount * vault.total_shares) / vault.total_deposited;
    }
    require(shares_to_mint > 0);

    spl_token::SPLToken::transfer(user_underlying, vault_underlying, user_authority, amount);
    spl_token::SPLToken::mint_to(shares_mint, user_shares, vault, shares_to_mint);

    vault.total_deposited = vault.total_deposited + amount;
    vault.total_shares = vault.total_shares + shares_to_mint;
}

// 3. withdraw -- burn shares, receive underlying + accumulated yield
pub withdraw(
    vault: Vault @mut @signer,
    user_shares: account @mut,
    shares_mint: account @mut,
    vault_underlying: account @mut,
    user_underlying: account @mut,
    user_authority: account @signer,
    token_program: account,
    shares_amount: u64
) {
    require(!vault.is_paused);
    require(shares_amount > 0);
    require(shares_amount <= vault.total_shares);
    require(vault_underlying.ctx.key == vault.underlying_vault);
    require(shares_mint.ctx.key == vault.vault_shares_mint);

    // Pro-rata underlying: shares / total_shares * total_deposited
    let underlying_amount: u64 = (shares_amount * vault.total_deposited) / vault.total_shares;
    require(underlying_amount > 0);

    spl_token::SPLToken::burn(user_shares, shares_mint, user_authority, shares_amount);
    spl_token::SPLToken::transfer(vault_underlying, user_underlying, vault, underlying_amount);

    vault.total_deposited = vault.total_deposited - underlying_amount;
    vault.total_shares = vault.total_shares - shares_amount;
}

// 4. compound -- permissionless crank: harvest rewards, swap, redeposit
pub compound(
    vault: Vault @mut @signer,
    vault_underlying: account @mut,
    reward_source: account @mut,
    cranker: account @signer,
    token_program: account,
    reward_amount: u64
) {
    require(!vault.is_paused);
    require(reward_amount > 0);
    require(vault_underlying.ctx.key == vault.underlying_vault);

    let current_slot: u64 = get_clock().slot;

    // Performance fee: taken from yield before redeposit
    let perf_fee: u64 = (reward_amount * vault.performance_fee_bps) / 10000;
    let net_reward: u64 = reward_amount - perf_fee;

    // Transfer rewards into vault (already swapped to underlying by caller)
    spl_token::SPLToken::transfer(reward_source, vault_underlying, cranker, net_reward);

    // Yield net of fee increases total_deposited, share price rises
    vault.total_deposited = vault.total_deposited + net_reward;
    vault.last_compound = current_slot;
}

// ---------------------------------------------------------------------------
// Lending Optimizer
// ---------------------------------------------------------------------------

// 5. create_lending_optimizer -- vault that auto-rotates between lenders
pub create_lending_optimizer(
    optimizer: LendingOptimizer @mut @init(payer=authority, space=256) @signer,
    vault: Vault,
    authority: account @mut @signer
) {
    require(vault.authority == authority.ctx.key);
    require(vault.strategy_type == 0);  // must be a lending vault

    optimizer.vault = vault.ctx.key;
    optimizer.current_lender = 0;
    optimizer.rate_1 = 0;
    optimizer.rate_2 = 0;
    optimizer.rate_3 = 0;
    optimizer.amount_1 = 0;
    optimizer.amount_2 = 0;
    optimizer.amount_3 = 0;
}

// 6. rebalance_lending -- move funds to whichever lender has best rate
pub rebalance_lending(
    optimizer: LendingOptimizer @mut,
    vault: Vault @mut,
    cranker: account @signer,
    new_rate_1: u64,
    new_rate_2: u64,
    new_rate_3: u64
) {
    require(!vault.is_paused);
    require(optimizer.vault == vault.ctx.key);

    // Update observed rates
    optimizer.rate_1 = new_rate_1;
    optimizer.rate_2 = new_rate_2;
    optimizer.rate_3 = new_rate_3;

    // Determine best lender
    let total: u64 = optimizer.amount_1 + optimizer.amount_2 + optimizer.amount_3;

    let mut best_lender: u8 = 0;
    let mut best_rate: u64 = new_rate_1;
    if (new_rate_2 > best_rate) {
        best_lender = 1;
        best_rate = new_rate_2;
    }
    if (new_rate_3 > best_rate) {
        best_lender = 2;
    }

    // Move all funds to best lender (simplified -- real impl would CPI withdraw/deposit)
    optimizer.amount_1 = 0;
    optimizer.amount_2 = 0;
    optimizer.amount_3 = 0;
    if (best_lender == 0) {
        optimizer.amount_1 = total;
    }
    if (best_lender == 1) {
        optimizer.amount_2 = total;
    }
    if (best_lender == 2) {
        optimizer.amount_3 = total;
    }
    optimizer.current_lender = best_lender;
}

// ---------------------------------------------------------------------------
// Leveraged Vault
// ---------------------------------------------------------------------------

// 7. create_leveraged_vault -- borrow + farm for amplified yield
pub create_leveraged_vault(
    lev_vault: LeveragedVault @mut @init(payer=authority, space=256) @signer,
    vault: Vault,
    authority: account @mut @signer,
    borrow_reserve: pubkey,
    leverage_ratio: u64
) {
    require(vault.authority == authority.ctx.key);
    require(vault.strategy_type == 2);  // must be a leveraged vault
    // Leverage between 1x (100) and 5x (500)
    require(leverage_ratio >= 100);
    require(leverage_ratio <= 500);

    lev_vault.vault = vault.ctx.key;
    lev_vault.borrow_reserve = borrow_reserve;
    lev_vault.borrowed_amount = 0;
    lev_vault.leverage_ratio = leverage_ratio;
    lev_vault.health_factor = 200;  // start healthy at 2.0x
}

// 8. deleverage -- reduce leverage if health factor drops
pub deleverage(
    lev_vault: LeveragedVault @mut,
    vault: Vault @mut @signer,
    vault_underlying: account @mut,
    repay_destination: account @mut,
    authority: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(!vault.is_paused);
    require(lev_vault.vault == vault.ctx.key);
    require(vault_underlying.ctx.key == vault.underlying_vault);
    require(repay_amount > 0);
    require(repay_amount <= lev_vault.borrowed_amount);

    // Repay borrowed funds from vault underlying
    spl_token::SPLToken::transfer(vault_underlying, repay_destination, vault, repay_amount);

    lev_vault.borrowed_amount = lev_vault.borrowed_amount - repay_amount;
    vault.total_deposited = vault.total_deposited - repay_amount;

    // Recalculate health factor: higher is safer
    if (lev_vault.borrowed_amount > 0) {
        lev_vault.health_factor = (vault.total_deposited * 100) / lev_vault.borrowed_amount;
    } else {
        lev_vault.health_factor = 10000;  // max health when no borrows
    }
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// 9. set_strategy -- change vault strategy type (only when empty)
pub set_strategy(
    vault: Vault @mut,
    authority: account @signer,
    new_strategy: u8
) {
    require(vault.authority == authority.ctx.key);
    require(new_strategy <= 2);
    // Can only change strategy when vault is empty to prevent fund confusion
    require(vault.total_deposited == 0);
    vault.strategy_type = new_strategy;
}

// 10. set_performance_fee -- update performance fee (bps)
pub set_performance_fee(
    vault: Vault @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(vault.authority == authority.ctx.key);
    require(new_fee_bps <= 2000);  // max 20%
    vault.performance_fee_bps = new_fee_bps;
}

// 11. set_management_fee -- update management fee (bps)
pub set_management_fee(
    vault: Vault @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(vault.authority == authority.ctx.key);
    require(new_fee_bps <= 500);  // max 5%
    vault.management_fee_bps = new_fee_bps;
}

// 12. collect_fees -- authority withdraws accrued management fees
pub collect_fees(
    vault: Vault @mut @signer,
    vault_underlying: account @mut,
    fee_recipient: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(vault.authority == authority.ctx.key);
    require(vault_underlying.ctx.key == vault.underlying_vault);

    let current_slot: u64 = get_clock().slot;
    let slots_elapsed: u64 = current_slot - vault.last_compound;

    // Annualized management fee: (TVL * bps * slots_elapsed) / (slots_per_year * 10000)
    // ~63072000 slots/year at 400ms slots
    let slots_per_year: u64 = 63072000;
    let fee: u64 = (vault.total_deposited * vault.management_fee_bps * slots_elapsed) / (slots_per_year * 10000);
    require(fee > 0);
    require(fee <= vault.total_deposited);

    spl_token::SPLToken::transfer(vault_underlying, fee_recipient, vault, fee);
    vault.total_deposited = vault.total_deposited - fee;
}

// 13. emergency_withdraw -- bypass strategy, return underlying directly
pub emergency_withdraw(
    vault: Vault @mut @signer,
    user_shares: account @mut,
    shares_mint: account @mut,
    vault_underlying: account @mut,
    user_underlying: account @mut,
    user_authority: account @signer,
    token_program: account,
    shares_amount: u64
) {
    // Emergency withdraw works even when paused
    require(shares_amount > 0);
    require(shares_amount <= vault.total_shares);
    require(vault_underlying.ctx.key == vault.underlying_vault);
    require(shares_mint.ctx.key == vault.vault_shares_mint);

    // Pro-rata calculation (same as withdraw but no pause check)
    let underlying_amount: u64 = (shares_amount * vault.total_deposited) / vault.total_shares;
    require(underlying_amount > 0);

    spl_token::SPLToken::burn(user_shares, shares_mint, user_authority, shares_amount);
    spl_token::SPLToken::transfer(vault_underlying, user_underlying, vault, underlying_amount);

    vault.total_deposited = vault.total_deposited - underlying_amount;
    vault.total_shares = vault.total_shares - shares_amount;
}

// 14. set_authority -- transfer vault ownership
pub set_authority(
    vault: Vault @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(vault.authority == authority.ctx.key);
    vault.authority = new_authority;
}

// 15. pause -- halt deposits, withdrawals, and compounding
pub pause(
    vault: Vault @mut,
    authority: account @signer
) {
    require(vault.authority == authority.ctx.key);
    require(!vault.is_paused);
    vault.is_paused = true;
}

// 16. unpause -- resume normal vault operations
pub unpause(
    vault: Vault @mut,
    authority: account @signer
) {
    require(vault.authority == authority.ctx.key);
    require(vault.is_paused);
    vault.is_paused = false;
}

// 17. set_max_deposit -- update the vault deposit cap
pub set_max_deposit(
    vault: Vault @mut,
    authority: account @signer,
    new_max: u64
) {
    require(vault.authority == authority.ctx.key);
    require(new_max > 0);
    vault.max_deposit = new_max;
}

// 18. update_vault_metrics -- refresh vault accounting after external state changes
pub update_vault_metrics(
    vault: Vault @mut,
    authority: account @signer,
    new_total_deposited: u64
) {
    require(vault.authority == authority.ctx.key);
    // Authority can update the effective deposited amount to reflect
    // external strategy state (e.g. after lending accrual, LP rebalance)
    require(new_total_deposited > 0);
    vault.total_deposited = new_total_deposited;
    vault.last_compound = get_clock().slot;
}
