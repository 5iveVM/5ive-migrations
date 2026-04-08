// 5IVE Marinade Finance -- Liquid Staking Protocol
//
// Marinade is Solana's #1 liquid staking protocol. Users deposit SOL, receive
// mSOL (liquid staking token), and their SOL is delegated across validators.
// mSOL appreciates over time as staking rewards accrue to the pool.
//
// Key mechanics:
//   - mSOL exchange rate: msol_amount = (sol * msol_supply) / total_sol_staked
//   - Instant unstake via liquidity pool (higher fee, immediate SOL)
//   - Delayed unstake via tickets (lower fee, 1+ epoch wait)
//   - Validator set with score-weighted delegation
//   - Separate liquidity pool with LP tokens for instant unstake providers

use std::interfaces::spl_token;

interface StakeProgram @program("Stake11111111111111111111111111111111111111") @serializer("raw") {
    delegate_stake @discriminator_bytes([2, 0, 0, 0]) (
        stake_account: account @mut,
        vote_account: account,
        clock_sysvar: account,
        stake_history_sysvar: account,
        stake_config_sysvar: account,
        authority: account @authority
    );

    split @discriminator_bytes([3, 0, 0, 0]) (
        source_stake_account: account @mut,
        destination_stake_account: account @mut,
        authority: account @authority,
        lamports: u64
    );

    withdraw @discriminator_bytes([4, 0, 0, 0]) (
        stake_account: account @mut,
        destination_account: account @mut,
        authority: account @authority,
        clock_sysvar: account,
        stake_history_sysvar: account,
        lamports: u64
    );

    deactivate_stake @discriminator_bytes([5, 0, 0, 0]) (
        stake_account: account @mut,
        clock_sysvar: account,
        authority: account @authority
    );

    merge @discriminator_bytes([7, 0, 0, 0]) (
        destination_stake_account: account @mut,
        source_stake_account: account @mut,
        clock_sysvar: account,
        stake_history_sysvar: account,
        authority: account @authority
    );
}

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account StakePool {
    authority: pubkey;
    msol_mint: pubkey;
    total_sol_staked: u64;
    msol_supply: u64;
    deposit_fee_bps: u64;
    withdraw_fee_bps: u64;
    instant_unstake_fee_bps: u64;
    treasury: pubkey;
    treasury_fees_sol: u64;
    lp_mint: pubkey;
    lp_sol_reserves: u64;
    lp_msol_reserves: u64;
    lp_supply: u64;
    num_validators: u32;
    max_validators: u32;
    min_stake_lamports: u64;
    last_epoch: u64;
    is_paused: bool;
    reserve_pda: pubkey;
}

account ValidatorRecord {
    pool: pubkey;
    vote_account: pubkey;
    stake_account: pubkey;
    active_stake: u64;
    score: u32;
    last_epoch: u64;
    is_active: bool;
}

account UnstakeTicket {
    pool: pubkey;
    owner: pubkey;
    msol_amount: u64;
    sol_amount: u64;
    created_epoch: u64;
    is_claimed: bool;
}

// ---------------------------------------------------------------------------
// Internal helpers (not on-chain callable)
// ---------------------------------------------------------------------------

fn calculate_fee(amount: u64, fee_bps: u64) -> u64 {
    return (amount * fee_bps) / 10000;
}

fn sol_to_msol(sol_amount: u64, total_sol: u64, msol_supply: u64) -> u64 {
    if (msol_supply == 0 || total_sol == 0) {
        return sol_amount;
    }
    return (sol_amount * msol_supply) / total_sol;
}

fn msol_to_sol(msol_amount: u64, total_sol: u64, msol_supply: u64) -> u64 {
    if (msol_supply == 0) {
        return 0;
    }
    return (msol_amount * total_sol) / msol_supply;
}

fn calculate_lp_tokens(sol_amount: u64, lp_reserves: u64, lp_supply: u64) -> u64 {
    if (lp_supply == 0 || lp_reserves == 0) {
        return sol_amount;
    }
    return (sol_amount * lp_supply) / lp_reserves;
}

// ---------------------------------------------------------------------------
// 1. Initialize -- Create the stake pool
// ---------------------------------------------------------------------------

pub initialize(
    pool: StakePool @mut @init(payer=admin, space=1024) @signer,
    admin: account @mut @signer,
    msol_mint: pubkey,
    lp_mint: pubkey,
    treasury: pubkey,
    reserve_pda: pubkey,
    deposit_fee_bps: u64,
    withdraw_fee_bps: u64,
    instant_unstake_fee_bps: u64,
    max_validators: u32,
    min_stake_lamports: u64
) {
    require(deposit_fee_bps <= 1000);
    require(withdraw_fee_bps <= 1000);
    require(instant_unstake_fee_bps <= 1000);
    require(max_validators > 0);
    require(min_stake_lamports > 0);

    pool.authority = admin.ctx.key;
    pool.msol_mint = msol_mint;
    pool.total_sol_staked = 0;
    pool.msol_supply = 0;
    pool.deposit_fee_bps = deposit_fee_bps;
    pool.withdraw_fee_bps = withdraw_fee_bps;
    pool.instant_unstake_fee_bps = instant_unstake_fee_bps;
    pool.treasury = treasury;
    pool.treasury_fees_sol = 0;
    pool.lp_mint = lp_mint;
    pool.lp_sol_reserves = 0;
    pool.lp_msol_reserves = 0;
    pool.lp_supply = 0;
    pool.num_validators = 0;
    pool.max_validators = max_validators;
    pool.min_stake_lamports = min_stake_lamports;
    pool.last_epoch = get_clock().epoch;
    pool.is_paused = false;
    pool.reserve_pda = reserve_pda;
}

// ---------------------------------------------------------------------------
// 2. Deposit -- User deposits SOL, receives mSOL
// ---------------------------------------------------------------------------

pub deposit(
    pool: StakePool @mut @signer,
    msol_mint_account: account @mut,
    user_sol_account: account @mut,
    pool_sol_vault: account @mut,
    user_msol_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    sol_amount: u64
) {
    require(!pool.is_paused);
    require(sol_amount > 0);
    require(msol_mint_account.ctx.key == pool.msol_mint);

    let fee: u64 = calculate_fee(sol_amount, pool.deposit_fee_bps);
    let sol_after_fee: u64 = sol_amount - fee;

    let msol_to_mint: u64 = sol_to_msol(sol_after_fee, pool.total_sol_staked, pool.msol_supply);
    require(msol_to_mint > 0);

    spl_token::SPLToken::transfer(user_sol_account, pool_sol_vault, user_authority, sol_amount);
    spl_token::SPLToken::mint_to(msol_mint_account, user_msol_account, pool, msol_to_mint);

    pool.total_sol_staked = pool.total_sol_staked + sol_after_fee;
    pool.msol_supply = pool.msol_supply + msol_to_mint;
    pool.treasury_fees_sol = pool.treasury_fees_sol + fee;
}

// ---------------------------------------------------------------------------
// 3. Liquid Unstake -- Instant: burn mSOL, get SOL from liquidity pool
// ---------------------------------------------------------------------------

pub liquid_unstake(
    pool: StakePool @mut @signer,
    msol_mint_account: account @mut,
    user_msol_account: account @mut,
    lp_sol_vault: account @mut,
    user_sol_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    msol_amount: u64
) {
    require(!pool.is_paused);
    require(msol_amount > 0);
    require(msol_mint_account.ctx.key == pool.msol_mint);

    let sol_value: u64 = msol_to_sol(msol_amount, pool.total_sol_staked, pool.msol_supply);
    require(sol_value > 0);

    let fee: u64 = calculate_fee(sol_value, pool.instant_unstake_fee_bps);
    let sol_out: u64 = sol_value - fee;
    require(sol_out > 0);
    require(sol_out <= pool.lp_sol_reserves);

    spl_token::SPLToken::burn(user_msol_account, msol_mint_account, user_authority, msol_amount);
    spl_token::SPLToken::transfer(lp_sol_vault, user_sol_account, pool, sol_out);

    pool.total_sol_staked = pool.total_sol_staked - sol_value;
    pool.msol_supply = pool.msol_supply - msol_amount;
    pool.lp_sol_reserves = pool.lp_sol_reserves - sol_out;
    pool.treasury_fees_sol = pool.treasury_fees_sol + fee;
}

// ---------------------------------------------------------------------------
// 4. Order Unstake -- Delayed: create ticket, SOL unlocks after epoch boundary
// ---------------------------------------------------------------------------

pub order_unstake(
    pool: StakePool @mut @signer,
    ticket: UnstakeTicket @mut @init(payer=user_authority, space=256),
    msol_mint_account: account @mut,
    user_msol_account: account @mut,
    user_authority: account @mut @signer,
    token_program: account,
    msol_amount: u64
) {
    require(!pool.is_paused);
    require(msol_amount > 0);
    require(msol_mint_account.ctx.key == pool.msol_mint);

    let sol_value: u64 = msol_to_sol(msol_amount, pool.total_sol_staked, pool.msol_supply);
    require(sol_value > 0);

    let fee: u64 = calculate_fee(sol_value, pool.withdraw_fee_bps);
    let sol_after_fee: u64 = sol_value - fee;
    require(sol_after_fee > 0);

    spl_token::SPLToken::burn(user_msol_account, msol_mint_account, user_authority, msol_amount);

    ticket.pool = pool.ctx.key;
    ticket.owner = user_authority.ctx.key;
    ticket.msol_amount = msol_amount;
    ticket.sol_amount = sol_after_fee;
    ticket.created_epoch = get_clock().epoch;
    ticket.is_claimed = false;

    pool.total_sol_staked = pool.total_sol_staked - sol_value;
    pool.msol_supply = pool.msol_supply - msol_amount;
    pool.treasury_fees_sol = pool.treasury_fees_sol + fee;
}

// ---------------------------------------------------------------------------
// 5. Claim Unstake -- Claim SOL from completed delayed unstake ticket
// ---------------------------------------------------------------------------

pub claim_unstake(
    pool: StakePool @mut @signer,
    ticket: UnstakeTicket @mut,
    pool_sol_vault: account @mut,
    user_sol_account: account @mut,
    user_authority: account @signer,
    token_program: account
) {
    require(!pool.is_paused);
    require(ticket.pool == pool.ctx.key);
    require(ticket.owner == user_authority.ctx.key);
    require(!ticket.is_claimed);

    let current_epoch: u64 = get_clock().epoch;
    require(current_epoch > ticket.created_epoch);

    let sol_amount: u64 = ticket.sol_amount;
    require(sol_amount > 0);

    spl_token::SPLToken::transfer(pool_sol_vault, user_sol_account, pool, sol_amount);

    ticket.is_claimed = true;
}

// ---------------------------------------------------------------------------
// 6. Add Validator -- Authority adds a validator to the pool
// ---------------------------------------------------------------------------

pub add_validator(
    pool: StakePool @mut,
    validator: ValidatorRecord @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    vote_account: pubkey,
    stake_account: pubkey,
    initial_score: u32
) {
    require(pool.authority == authority.ctx.key);
    require(pool.num_validators as u64 < pool.max_validators as u64);
    require(initial_score > 0);

    validator.pool = pool.ctx.key;
    validator.vote_account = vote_account;
    validator.stake_account = stake_account;
    validator.active_stake = 0;
    validator.score = initial_score;
    validator.last_epoch = get_clock().epoch;
    validator.is_active = true;

    pool.num_validators = pool.num_validators + 1;
}

// ---------------------------------------------------------------------------
// 7. Remove Validator -- Deactivate a validator (authority only)
// ---------------------------------------------------------------------------

pub remove_validator(
    pool: StakePool @mut,
    validator: ValidatorRecord @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);

    validator.is_active = false;
    pool.num_validators = pool.num_validators - 1;
}

// ---------------------------------------------------------------------------
// 8. Stake to Validator -- Delegate SOL from pool reserve to a validator
// ---------------------------------------------------------------------------

pub stake_to_validator(
    pool: StakePool @mut @signer,
    validator: ValidatorRecord @mut,
    authority: account @signer,
    stake_account: account @mut,
    vote_account: account,
    pool_sol_vault: account @mut,
    clock_sysvar: account,
    stake_history_sysvar: account,
    stake_config_sysvar: account,
    token_program: account,
    sol_amount: u64
) {
    require(!pool.is_paused);
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(validator.vote_account == vote_account.ctx.key);
    require(validator.stake_account == stake_account.ctx.key);
    require(sol_amount >= pool.min_stake_lamports);

    StakeProgram::delegate_stake(
        stake_account,
        vote_account,
        clock_sysvar,
        stake_history_sysvar,
        stake_config_sysvar,
        pool
    );

    validator.active_stake = validator.active_stake + sol_amount;
    validator.last_epoch = get_clock().epoch;
}

// ---------------------------------------------------------------------------
// 9. Unstake from Validator -- Deactivate stake from a validator back to pool
// ---------------------------------------------------------------------------

pub unstake_from_validator(
    pool: StakePool @mut @signer,
    validator: ValidatorRecord @mut,
    authority: account @signer,
    stake_account: account @mut,
    clock_sysvar: account,
    sol_amount: u64
) {
    require(!pool.is_paused);
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.stake_account == stake_account.ctx.key);
    require(sol_amount > 0);
    require(sol_amount <= validator.active_stake);

    StakeProgram::deactivate_stake(
        stake_account,
        clock_sysvar,
        pool
    );

    validator.active_stake = validator.active_stake - sol_amount;
    validator.last_epoch = get_clock().epoch;
}

// ---------------------------------------------------------------------------
// 10. Add Liquidity -- Add SOL to the liquidity pool, receive LP tokens
// ---------------------------------------------------------------------------

pub add_liquidity(
    pool: StakePool @mut @signer,
    lp_mint_account: account @mut,
    user_sol_account: account @mut,
    lp_sol_vault: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    sol_amount: u64
) {
    require(!pool.is_paused);
    require(sol_amount > 0);
    require(lp_mint_account.ctx.key == pool.lp_mint);

    let lp_tokens: u64 = calculate_lp_tokens(sol_amount, pool.lp_sol_reserves, pool.lp_supply);
    require(lp_tokens > 0);

    spl_token::SPLToken::transfer(user_sol_account, lp_sol_vault, user_authority, sol_amount);
    spl_token::SPLToken::mint_to(lp_mint_account, user_lp_account, pool, lp_tokens);

    pool.lp_sol_reserves = pool.lp_sol_reserves + sol_amount;
    pool.lp_supply = pool.lp_supply + lp_tokens;
}

// ---------------------------------------------------------------------------
// 11. Remove Liquidity -- Burn LP tokens, withdraw SOL from liquidity pool
// ---------------------------------------------------------------------------

pub remove_liquidity(
    pool: StakePool @mut @signer,
    lp_mint_account: account @mut,
    user_lp_account: account @mut,
    lp_sol_vault: account @mut,
    user_sol_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(lp_mint_account.ctx.key == pool.lp_mint);

    let sol_out: u64 = (lp_amount * pool.lp_sol_reserves) / pool.lp_supply;
    require(sol_out > 0);
    require(sol_out <= pool.lp_sol_reserves);

    spl_token::SPLToken::burn(user_lp_account, lp_mint_account, user_authority, lp_amount);
    spl_token::SPLToken::transfer(lp_sol_vault, user_sol_account, pool, sol_out);

    pool.lp_sol_reserves = pool.lp_sol_reserves - sol_out;
    pool.lp_supply = pool.lp_supply - lp_amount;
}

// ---------------------------------------------------------------------------
// 12. Update Fees -- Change fee rates (authority only)
// ---------------------------------------------------------------------------

pub update_fees(
    pool: StakePool @mut,
    authority: account @signer,
    new_deposit_fee_bps: u64,
    new_withdraw_fee_bps: u64,
    new_instant_unstake_fee_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_deposit_fee_bps <= 1000);
    require(new_withdraw_fee_bps <= 1000);
    require(new_instant_unstake_fee_bps <= 1000);

    pool.deposit_fee_bps = new_deposit_fee_bps;
    pool.withdraw_fee_bps = new_withdraw_fee_bps;
    pool.instant_unstake_fee_bps = new_instant_unstake_fee_bps;
}

// ---------------------------------------------------------------------------
// 13. Set Authority -- Transfer admin to a new pubkey
// ---------------------------------------------------------------------------

pub set_authority(
    pool: StakePool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

// ---------------------------------------------------------------------------
// 14. Pause -- Emergency halt all pool operations
// ---------------------------------------------------------------------------

pub pause(
    pool: StakePool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(!pool.is_paused);
    pool.is_paused = true;
}

// ---------------------------------------------------------------------------
// 15. Unpause -- Resume pool operations
// ---------------------------------------------------------------------------

pub unpause(
    pool: StakePool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    require(pool.is_paused);
    pool.is_paused = false;
}

// ---------------------------------------------------------------------------
// 16. Update Validator Score -- Adjust a validator's delegation weighting
// ---------------------------------------------------------------------------

pub update_validator_score(
    pool: StakePool,
    validator: ValidatorRecord @mut,
    authority: account @signer,
    new_score: u32
) {
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(new_score > 0);

    validator.score = new_score;
}

// ---------------------------------------------------------------------------
// 17. Update Epoch -- Checkpoint staking rewards into the pool
//     Called once per epoch. Increases total_sol_staked to reflect rewards,
//     which naturally appreciates the mSOL exchange rate.
// ---------------------------------------------------------------------------

pub update_epoch(
    pool: StakePool @mut,
    authority: account @signer,
    epoch_rewards: u64
) {
    require(pool.authority == authority.ctx.key);

    let current_epoch: u64 = get_clock().epoch;
    require(current_epoch > pool.last_epoch);

    pool.total_sol_staked = pool.total_sol_staked + epoch_rewards;
    pool.last_epoch = current_epoch;
}

// ---------------------------------------------------------------------------
// 18. Collect Treasury Fees -- Withdraw accumulated fees to treasury
// ---------------------------------------------------------------------------

pub collect_treasury_fees(
    pool: StakePool @mut @signer,
    authority: account @signer,
    pool_sol_vault: account @mut,
    treasury_account: account @mut,
    token_program: account
) {
    require(pool.authority == authority.ctx.key);
    require(pool.treasury_fees_sol > 0);

    let fees: u64 = pool.treasury_fees_sol;

    spl_token::SPLToken::transfer(pool_sol_vault, treasury_account, pool, fees);

    pool.treasury_fees_sol = 0;
}

// ---------------------------------------------------------------------------
// 19. Merge Validator Stakes -- Merge two stake accounts for a validator
//     Used to consolidate stake after rebalancing operations.
// ---------------------------------------------------------------------------

pub merge_validator_stakes(
    pool: StakePool @signer,
    validator: ValidatorRecord @mut,
    authority: account @signer,
    destination_stake: account @mut,
    source_stake: account @mut,
    clock_sysvar: account,
    stake_history_sysvar: account
) {
    require(!pool.is_paused);
    require(pool.authority == authority.ctx.key);
    require(validator.pool == pool.ctx.key);
    require(validator.is_active);
    require(validator.stake_account == destination_stake.ctx.key);

    StakeProgram::merge(
        destination_stake,
        source_stake,
        clock_sysvar,
        stake_history_sysvar,
        pool
    );

    validator.last_epoch = get_clock().epoch;
}

// ---------------------------------------------------------------------------
// 20. Withdraw Stake to Reserve -- Pull deactivated stake back to pool reserve
// ---------------------------------------------------------------------------

pub withdraw_stake_to_reserve(
    pool: StakePool @mut @signer,
    authority: account @signer,
    stake_account: account @mut,
    reserve_account: account @mut,
    clock_sysvar: account,
    stake_history_sysvar: account,
    lamports: u64
) {
    require(!pool.is_paused);
    require(pool.authority == authority.ctx.key);
    require(reserve_account.ctx.key == pool.reserve_pda);
    require(lamports > 0);

    StakeProgram::withdraw(
        stake_account,
        reserve_account,
        pool,
        clock_sysvar,
        stake_history_sysvar,
        lamports
    );
}

// ---------------------------------------------------------------------------
// Read-only helpers (exposed for off-chain clients)
// ---------------------------------------------------------------------------

pub get_msol_exchange_rate(pool: StakePool) -> u64 {
    if (pool.msol_supply == 0) {
        return 1000000000;
    }
    return (pool.total_sol_staked * 1000000000) / pool.msol_supply;
}

pub get_total_sol_staked(pool: StakePool) -> u64 {
    return pool.total_sol_staked;
}

pub get_msol_supply(pool: StakePool) -> u64 {
    return pool.msol_supply;
}

pub get_lp_sol_reserves(pool: StakePool) -> u64 {
    return pool.lp_sol_reserves;
}

pub get_lp_supply(pool: StakePool) -> u64 {
    return pool.lp_supply;
}

pub get_validator_active_stake(validator: ValidatorRecord) -> u64 {
    return validator.active_stake;
}

pub get_ticket_sol_amount(ticket: UnstakeTicket) -> u64 {
    return ticket.sol_amount;
}

pub is_ticket_claimable(ticket: UnstakeTicket) -> bool {
    if (ticket.is_claimed) {
        return false;
    }
    let current_epoch: u64 = get_clock().epoch;
    if (current_epoch > ticket.created_epoch) {
        return true;
    }
    return false;
}

pub quote_deposit(pool: StakePool, sol_amount: u64) -> u64 {
    let fee: u64 = calculate_fee(sol_amount, pool.deposit_fee_bps);
    let sol_after_fee: u64 = sol_amount - fee;
    return sol_to_msol(sol_after_fee, pool.total_sol_staked, pool.msol_supply);
}

pub quote_liquid_unstake(pool: StakePool, msol_amount: u64) -> u64 {
    let sol_value: u64 = msol_to_sol(msol_amount, pool.total_sol_staked, pool.msol_supply);
    let fee: u64 = calculate_fee(sol_value, pool.instant_unstake_fee_bps);
    return sol_value - fee;
}

pub quote_order_unstake(pool: StakePool, msol_amount: u64) -> u64 {
    let sol_value: u64 = msol_to_sol(msol_amount, pool.total_sol_staked, pool.msol_supply);
    let fee: u64 = calculate_fee(sol_value, pool.withdraw_fee_bps);
    return sol_value - fee;
}
