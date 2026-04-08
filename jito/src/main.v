// 5IVE Jito -- MEV-Aware Liquid Staking Protocol
//
// Jito is Solana's MEV-aware liquid staking protocol. Users stake SOL, receive
// jitoSOL at an exchange rate that appreciates as staking rewards AND MEV tips
// accrue to the pool. This is the key innovation: validators running Jito's
// block engine earn MEV tips that flow back to jitoSOL holders.
//
// Key mechanics:
//   - Exchange rate: jitosol_amount = (sol_amount * jitosol_supply) / total_sol
//   - MEV tip distribution: tips collected by validators flow into the pool,
//     increasing the exchange rate for all jitoSOL holders
//   - Delayed unstake: burn jitoSOL, receive a WithdrawTicket, claim after epoch
//   - Instant withdraw: from a liquidity pool at a higher fee
//   - Validator management: add/remove/score validators, stake delegation
//   - Epoch boundary: update_exchange_rate recalculates based on staking rewards + tips
//
// Precision:
//   - Exchange rate: RATE_PRECISION = 1_000_000_000 (1e9)
//   - Fees in basis points: FEE_DENOMINATOR = 10000
//   - Tip share in basis points per validator

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account StakePool {
    authority: pubkey;               // Pool admin
    jitosol_mint: pubkey;            // jitoSOL mint address
    total_sol: u64;                  // Total SOL managed by the pool
    jitosol_supply: u64;             // Total jitoSOL minted
    deposit_fee_bps: u64;            // Fee on SOL deposits
    withdraw_fee_bps: u64;           // Fee on delayed withdrawals
    instant_withdraw_fee_bps: u64;   // Higher fee for instant withdrawals
    tip_fee_bps: u64;               // Protocol cut of MEV tips
    tip_vault: pubkey;               // Vault holding accumulated tips
    tip_distribution_rate: u64;      // % of tips distributed per epoch (scaled 1e4)
    num_validators: u32;             // Active validator count
    max_validators: u32;             // Maximum validators allowed
    last_epoch: u64;                 // Last epoch where exchange rate was updated
    treasury: pubkey;                // Treasury for protocol fees
    treasury_fees_collected: u64;    // Accumulated treasury fees
    sol_vault: pubkey;               // Main SOL/wSOL vault
    liquidity_pool_sol: u64;         // SOL in instant-withdraw liquidity pool
    liquidity_pool_target: u64;      // Target liquidity pool size
    is_paused: bool;
}

account ValidatorRecord {
    pool: pubkey;                    // Parent stake pool
    vote_account: pubkey;            // Validator vote account
    stake_account: pubkey;           // Delegated stake account
    active_stake: u64;              // SOL currently staked to this validator
    tip_share_bps: u64;             // Validator's share of tips (in bps)
    score: u64;                      // Performance score (higher = more delegation)
    is_active: bool;                 // Whether validator is active in the set
}

account WithdrawTicket {
    pool: pubkey;
    owner: pubkey;                   // Ticket holder
    jitosol_amount: u64;             // jitoSOL burned
    sol_amount: u64;                 // SOL owed (calculated at burn time)
    created_epoch: u64;              // Epoch when ticket was created
    is_claimed: bool;                // Whether SOL has been claimed
}

account TipDistribution {
    pool: pubkey;
    epoch: u64;                      // Epoch of this distribution
    total_tips: u64;                 // Total tips collected this epoch
    distributed_tips: u64;           // Tips already distributed to pool
    num_validators_paid: u32;        // Validators that have claimed their share
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
// RATE_PRECISION = 1_000_000_000
// FEE_DENOMINATOR = 10000
// MIN_DEPOSIT = 1000 (lamports)

// ---------------------------------------------------------------------------
// Pool Initialization
// ---------------------------------------------------------------------------

pub initialize(
    pool: StakePool @mut @init(payer=admin, space=1024) @signer,
    admin: account @mut @signer,
    jitosol_mint: pubkey,
    tip_vault: pubkey,
    treasury: pubkey,
    sol_vault: pubkey,
    deposit_fee_bps: u64,
    withdraw_fee_bps: u64,
    instant_withdraw_fee_bps: u64,
    tip_fee_bps: u64,
    tip_distribution_rate: u64,
    max_validators: u32,
    liquidity_pool_target: u64
) {
    require(deposit_fee_bps <= 1000);
    require(withdraw_fee_bps <= 1000);
    require(instant_withdraw_fee_bps <= 2000);   // Instant can be up to 20%
    require(tip_fee_bps <= 5000);                 // Protocol takes max 50% of tips
    require(tip_distribution_rate <= 10000);
    require(max_validators > 0);

    pool.authority = admin.ctx.key;
    pool.jitosol_mint = jitosol_mint;
    pool.total_sol = 0;
    pool.jitosol_supply = 0;
    pool.deposit_fee_bps = deposit_fee_bps;
    pool.withdraw_fee_bps = withdraw_fee_bps;
    pool.instant_withdraw_fee_bps = instant_withdraw_fee_bps;
    pool.tip_fee_bps = tip_fee_bps;
    pool.tip_vault = tip_vault;
    pool.tip_distribution_rate = tip_distribution_rate;
    pool.num_validators = 0;
    pool.max_validators = max_validators;
    pool.last_epoch = get_clock().epoch;
    pool.treasury = treasury;
    pool.treasury_fees_collected = 0;
    pool.sol_vault = sol_vault;
    pool.liquidity_pool_sol = 0;
    pool.liquidity_pool_target = liquidity_pool_target;
    pool.is_paused = false;
}

// ---------------------------------------------------------------------------
// Staking: Deposit & Withdraw
// ---------------------------------------------------------------------------

// deposit_sol: stake SOL, receive jitoSOL at current exchange rate
pub deposit_sol(
    pool: StakePool @mut @signer,
    user_sol_account: account @mut,
    sol_vault: account @mut,
    jitosol_mint: account @mut,
    user_jitosol_account: account @mut,
    user: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount >= 1000);  // MIN_DEPOSIT
    require(sol_vault.ctx.key == pool.sol_vault);
    require(jitosol_mint.ctx.key == pool.jitosol_mint);

    // Calculate deposit fee
    let fee: u64 = (amount * pool.deposit_fee_bps) / 10000;
    let net_deposit: u64 = amount - fee;

    // Calculate jitoSOL to mint
    // If pool is empty, 1:1 ratio; otherwise use exchange rate
    let mut jitosol_to_mint: u64 = 0;
    if (pool.jitosol_supply == 0) {
        jitosol_to_mint = net_deposit;
    } else {
        jitosol_to_mint = (net_deposit * pool.jitosol_supply) / pool.total_sol;
    }
    require(jitosol_to_mint > 0);

    // Transfer SOL into vault
    spl_token::SPLToken::transfer(user_sol_account, sol_vault, user, amount);

    // Mint jitoSOL to user
    spl_token::SPLToken::mint_to(jitosol_mint, user_jitosol_account, pool, jitosol_to_mint);

    pool.total_sol = pool.total_sol + net_deposit;
    pool.jitosol_supply = pool.jitosol_supply + jitosol_to_mint;
    pool.treasury_fees_collected = pool.treasury_fees_collected + fee;
}

// withdraw_sol: burn jitoSOL, create a WithdrawTicket for delayed claim
pub withdraw_sol(
    pool: StakePool @mut,
    ticket: WithdrawTicket @mut @init(payer=user, space=256),
    user_jitosol_account: account @mut,
    jitosol_mint: account @mut,
    user: account @mut @signer,
    token_program: account,
    jitosol_amount: u64
) {
    require(!pool.is_paused);
    require(jitosol_amount > 0);
    require(jitosol_mint.ctx.key == pool.jitosol_mint);
    require(pool.jitosol_supply >= jitosol_amount);

    // Calculate SOL owed at current exchange rate
    let sol_amount: u64 = (jitosol_amount * pool.total_sol) / pool.jitosol_supply;
    require(sol_amount > 0);

    // Apply withdrawal fee
    let fee: u64 = (sol_amount * pool.withdraw_fee_bps) / 10000;
    let net_sol: u64 = sol_amount - fee;

    // Burn jitoSOL
    spl_token::SPLToken::burn(user_jitosol_account, jitosol_mint, user, jitosol_amount);

    // Create withdraw ticket (claimable after epoch change)
    let clock: Clock = get_clock();
    ticket.pool = pool.ctx.key;
    ticket.owner = user.ctx.key;
    ticket.jitosol_amount = jitosol_amount;
    ticket.sol_amount = net_sol;
    ticket.created_epoch = clock.epoch;
    ticket.is_claimed = false;

    pool.jitosol_supply = pool.jitosol_supply - jitosol_amount;
    pool.total_sol = pool.total_sol - sol_amount;
    pool.treasury_fees_collected = pool.treasury_fees_collected + fee;
}

// instant_withdraw: withdraw SOL immediately from liquidity pool (higher fee)
pub instant_withdraw(
    pool: StakePool @mut @signer,
    user_jitosol_account: account @mut,
    jitosol_mint: account @mut,
    sol_vault: account @mut,
    user_sol_account: account @mut,
    user: account @signer,
    token_program: account,
    jitosol_amount: u64
) {
    require(!pool.is_paused);
    require(jitosol_amount > 0);
    require(jitosol_mint.ctx.key == pool.jitosol_mint);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(pool.jitosol_supply >= jitosol_amount);

    // Calculate SOL at current rate
    let sol_amount: u64 = (jitosol_amount * pool.total_sol) / pool.jitosol_supply;
    require(sol_amount > 0);

    // Instant withdraw fee is higher than delayed
    let fee: u64 = (sol_amount * pool.instant_withdraw_fee_bps) / 10000;
    let net_sol: u64 = sol_amount - fee;

    // Must have sufficient liquidity pool balance
    require(pool.liquidity_pool_sol >= net_sol);

    // Burn jitoSOL
    spl_token::SPLToken::burn(user_jitosol_account, jitosol_mint, user, jitosol_amount);

    // Transfer SOL from vault
    spl_token::SPLToken::transfer(sol_vault, user_sol_account, pool, net_sol);

    pool.jitosol_supply = pool.jitosol_supply - jitosol_amount;
    pool.total_sol = pool.total_sol - sol_amount;
    pool.liquidity_pool_sol = pool.liquidity_pool_sol - net_sol;
    pool.treasury_fees_collected = pool.treasury_fees_collected + fee;
}

// ---------------------------------------------------------------------------
// Validator Management
// ---------------------------------------------------------------------------

pub add_validator(
    pool: StakePool @mut,
    validator: ValidatorRecord @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    vote_account: pubkey,
    stake_account: pubkey,
    tip_share_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(pool.num_validators < pool.max_validators);
    require(tip_share_bps <= 10000);

    validator.pool = pool.ctx.key;
    validator.vote_account = vote_account;
    validator.stake_account = stake_account;
    validator.active_stake = 0;
    validator.tip_share_bps = tip_share_bps;
    validator.score = 100;              // Default score
    validator.is_active = true;

    pool.num_validators = pool.num_validators + 1;
}

pub remove_validator(
    pool: StakePool @mut,
    validator: ValidatorRecord @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(validator.active_stake == 0);  // Must unstake first

    validator.is_active = false;
    pool.num_validators = pool.num_validators - 1;
}

pub update_validator_score(
    pool: StakePool @mut,
    validator: ValidatorRecord @mut,
    authority: account @signer,
    new_score: u64
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    validator.score = new_score;
}

// stake_to_validator: delegate SOL from vault to a validator's stake account
pub stake_to_validator(
    pool: StakePool @mut @signer,
    validator: ValidatorRecord @mut,
    sol_vault: account @mut,
    stake_target: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(amount > 0);

    // Transfer SOL to stake account (in production, this is a stake delegation CPI)
    spl_token::SPLToken::transfer(sol_vault, stake_target, pool, amount);

    validator.active_stake = validator.active_stake + amount;
}

// unstake_from_validator: begin undelegation from a validator
pub unstake_from_validator(
    pool: StakePool @mut @signer,
    validator: ValidatorRecord @mut,
    stake_source: account @mut,
    sol_vault: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(amount > 0);
    require(amount <= validator.active_stake);

    // Return SOL from stake account to vault (simplified; real unstake is epoch-delayed)
    spl_token::SPLToken::transfer(stake_source, sol_vault, pool, amount);

    validator.active_stake = validator.active_stake - amount;
}

// ---------------------------------------------------------------------------
// MEV Tip Distribution (Key Innovation)
// ---------------------------------------------------------------------------

// distribute_tips: distribute accumulated MEV tips to the stake pool
// Tips flow into total_sol, increasing the jitoSOL exchange rate for all holders
pub distribute_tips(
    pool: StakePool @mut @signer,
    tip_dist: TipDistribution @mut @init(payer=caller, space=256),
    tip_vault: account @mut,
    sol_vault: account @mut,
    caller: account @mut @signer,
    token_program: account,
    tips_amount: u64
) {
    require(!pool.is_paused);
    require(tip_vault.ctx.key == pool.tip_vault);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(tips_amount > 0);

    let clock: Clock = get_clock();

    // Protocol takes its cut
    let protocol_cut: u64 = (tips_amount * pool.tip_fee_bps) / 10000;
    let distributable: u64 = tips_amount - protocol_cut;

    // Apply distribution rate (may not distribute 100% per epoch)
    let to_distribute: u64 = (distributable * pool.tip_distribution_rate) / 10000;

    // Transfer tips from tip vault to main SOL vault
    spl_token::SPLToken::transfer(tip_vault, sol_vault, pool, to_distribute);

    // Increase total_sol -- this raises the exchange rate for all jitoSOL holders
    pool.total_sol = pool.total_sol + to_distribute;
    pool.treasury_fees_collected = pool.treasury_fees_collected + protocol_cut;

    // Record distribution
    tip_dist.pool = pool.ctx.key;
    tip_dist.epoch = clock.epoch;
    tip_dist.total_tips = tips_amount;
    tip_dist.distributed_tips = to_distribute;
    tip_dist.num_validators_paid = 0;
}

// claim_tips: individual validator claims their share of tips
pub claim_tips(
    pool: StakePool @mut,
    tip_dist: TipDistribution @mut,
    validator: ValidatorRecord @mut,
    tip_vault: account @mut,
    validator_tip_account: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(tip_dist.pool == pool.ctx.key);
    require(tip_vault.ctx.key == pool.tip_vault);

    // Validator's share based on their tip_share_bps of remaining tips
    let remaining_tips: u64 = tip_dist.total_tips - tip_dist.distributed_tips;
    let validator_share: u64 = (remaining_tips * validator.tip_share_bps) / 10000;
    require(validator_share > 0);

    spl_token::SPLToken::transfer(tip_vault, validator_tip_account, pool, validator_share);

    tip_dist.distributed_tips = tip_dist.distributed_tips + validator_share;
    tip_dist.num_validators_paid = tip_dist.num_validators_paid + 1;
}

// ---------------------------------------------------------------------------
// Epoch Management
// ---------------------------------------------------------------------------

// update_exchange_rate: called at epoch boundary to account for staking rewards
pub update_exchange_rate(
    pool: StakePool @mut,
    authority: account @signer,
    staking_rewards: u64
) {
    require(pool.authority == authority.ctx.key);
    let clock: Clock = get_clock();
    require(clock.epoch > pool.last_epoch);

    // Staking rewards increase total_sol, raising the exchange rate
    pool.total_sol = pool.total_sol + staking_rewards;
    pool.last_epoch = clock.epoch;
}

// update_epoch: general epoch housekeeping
pub update_epoch(
    pool: StakePool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    let clock: Clock = get_clock();
    require(clock.epoch > pool.last_epoch);
    pool.last_epoch = clock.epoch;
}

// ---------------------------------------------------------------------------
// Liquidity Pool for Instant Withdrawals
// ---------------------------------------------------------------------------

// add_tip_liquidity: add SOL to the instant-withdraw liquidity pool
pub add_tip_liquidity(
    pool: StakePool @mut @signer,
    user_sol_account: account @mut,
    sol_vault: account @mut,
    user: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(sol_vault.ctx.key == pool.sol_vault);

    spl_token::SPLToken::transfer(user_sol_account, sol_vault, user, amount);

    pool.liquidity_pool_sol = pool.liquidity_pool_sol + amount;
}

// remove_tip_liquidity: withdraw SOL from the liquidity pool
pub remove_tip_liquidity(
    pool: StakePool @mut @signer,
    sol_vault: account @mut,
    user_sol_account: account @mut,
    user: account @signer,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(amount <= pool.liquidity_pool_sol);
    require(sol_vault.ctx.key == pool.sol_vault);

    spl_token::SPLToken::transfer(sol_vault, user_sol_account, pool, amount);

    pool.liquidity_pool_sol = pool.liquidity_pool_sol - amount;
}

// ---------------------------------------------------------------------------
// Admin Operations
// ---------------------------------------------------------------------------

pub set_fees(
    pool: StakePool @mut,
    authority: account @signer,
    new_deposit_fee_bps: u64,
    new_withdraw_fee_bps: u64,
    new_instant_withdraw_fee_bps: u64,
    new_tip_fee_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_deposit_fee_bps <= 1000);
    require(new_withdraw_fee_bps <= 1000);
    require(new_instant_withdraw_fee_bps <= 2000);
    require(new_tip_fee_bps <= 5000);

    pool.deposit_fee_bps = new_deposit_fee_bps;
    pool.withdraw_fee_bps = new_withdraw_fee_bps;
    pool.instant_withdraw_fee_bps = new_instant_withdraw_fee_bps;
    pool.tip_fee_bps = new_tip_fee_bps;
}

pub set_authority(
    pool: StakePool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

pub pause(
    pool: StakePool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = true;
}

pub unpause(
    pool: StakePool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = false;
}

// collect_treasury_fees: sweep accumulated fees to treasury
pub collect_treasury_fees(
    pool: StakePool @mut @signer,
    sol_vault: account @mut,
    treasury_account: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(sol_vault.ctx.key == pool.sol_vault);
    require(pool.treasury_fees_collected > 0);

    let fees: u64 = pool.treasury_fees_collected;
    spl_token::SPLToken::transfer(sol_vault, treasury_account, pool, fees);
    pool.treasury_fees_collected = 0;
}
