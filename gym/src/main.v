// Gym Liquidity Bootstrapping & Incentive Protocol - 5IVE Migration
//
// Tools for new tokens to bootstrap liquidity:
//   - Liquidity Bootstrapping Pools (LBPs) with time-weighted shifting weights
//   - Bonding curves (linear, exponential, sigmoid) with graduation to AMM
//   - Reward vaults for LP staking incentives
//   - Liquidity locks to prove long-term commitment
//
// Designed to give fair token distribution and sustainable liquidity.

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account LBP {
    authority: pubkey;
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    lp_mint: pubkey;
    start_weight_a: u64;     // basis points (e.g. 9000 = 90%)
    end_weight_a: u64;       // basis points (e.g. 5000 = 50%)
    start_time: u64;
    end_time: u64;
    current_weight_a: u64;
    reserve_a: u64;
    reserve_b: u64;
    lp_supply: u64;
    fee_numerator: u64;
    fee_denominator: u64;
    is_active: bool;
    is_paused: bool;
}

account BondingCurve {
    authority: pubkey;
    token_mint: pubkey;
    reserve_mint: pubkey;
    reserve_vault: pubkey;
    curve_type: u8;          // 0 = linear, 1 = exponential, 2 = sigmoid
    slope: u64;              // price sensitivity parameter
    base_price: u64;
    supply: u64;
    reserve_balance: u64;
    graduation_threshold: u64;
    is_graduated: bool;
    is_paused: bool;
}

account RewardVault {
    authority: pubkey;
    stake_mint: pubkey;
    reward_mint: pubkey;
    vault: pubkey;
    reward_per_second: u64;
    total_staked: u64;
    acc_reward_per_share: u64;
    last_update: u64;
    is_paused: bool;
}

account StakePosition {
    vault: pubkey;
    owner: pubkey;
    amount: u64;
    reward_debt: u64;
    pending_reward: u64;
}

account LiquidityLock {
    authority: pubkey;
    lp_mint: pubkey;
    owner: pubkey;
    amount: u64;
    unlock_time: u64;
    is_locked: bool;
}

// ---------------------------------------------------------------------------
// Liquidity Bootstrapping Pool (LBP)
// ---------------------------------------------------------------------------

/// Create an LBP with time-weighted shifting weights.
/// Starts at start_weight_a (e.g. 9000 = 90% project token) and shifts
/// to end_weight_a (e.g. 5000 = 50/50) over the duration.
pub create_lbp(
    lbp: LBP @mut @init(payer=creator, space=700),
    creator: account @mut @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    lp_mint: pubkey,
    start_weight_a: u64,
    end_weight_a: u64,
    start_time: u64,
    end_time: u64,
    fee_numerator: u64,
    fee_denominator: u64,
    initial_a: u64,
    initial_b: u64
) {
    require(start_weight_a >= 1000);
    require(start_weight_a <= 9500);
    require(end_weight_a >= 500);
    require(end_weight_a <= start_weight_a);
    require(end_time > start_time);
    require(fee_denominator > 0);
    require(fee_numerator < fee_denominator);
    require(initial_a > 0);
    require(initial_b > 0);

    lbp.authority = creator.ctx.key;
    lbp.token_a_mint = token_a_mint;
    lbp.token_b_mint = token_b_mint;
    lbp.token_a_vault = token_a_vault;
    lbp.token_b_vault = token_b_vault;
    lbp.lp_mint = lp_mint;
    lbp.start_weight_a = start_weight_a;
    lbp.end_weight_a = end_weight_a;
    lbp.start_time = start_time;
    lbp.end_time = end_time;
    lbp.current_weight_a = start_weight_a;
    lbp.reserve_a = initial_a;
    lbp.reserve_b = initial_b;
    lbp.lp_supply = initial_a + initial_b;
    lbp.fee_numerator = fee_numerator;
    lbp.fee_denominator = fee_denominator;
    lbp.is_active = true;
    lbp.is_paused = false;
}

/// Crank: advance LBP weight shift based on elapsed time.
/// Should be called periodically to update pricing.
pub update_lbp_weights(lbp: LBP @mut) {
    require(lbp.is_active);

    let now: u64 = get_clock().slot;

    if (now >= lbp.end_time) {
        lbp.current_weight_a = lbp.end_weight_a;
        return;
    }

    if (now <= lbp.start_time) {
        lbp.current_weight_a = lbp.start_weight_a;
        return;
    }

    let elapsed: u64 = now - lbp.start_time;
    let duration: u64 = lbp.end_time - lbp.start_time;
    let weight_delta: u64 = lbp.start_weight_a - lbp.end_weight_a;

    // Linear interpolation: current = start - (delta * elapsed / duration)
    let shift: u64 = (weight_delta * elapsed) / duration;
    lbp.current_weight_a = lbp.start_weight_a - shift;
}

/// Swap during the LBP. Price discovery via shifting weights.
/// Uses weighted constant product: (R_a / W_a) * (R_b / W_b) = k
pub swap_lbp(
    lbp: LBP @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    pool_source_vault: account @mut,
    pool_destination_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64,
    is_a_to_b: bool
) {
    require(lbp.is_active);
    require(!lbp.is_paused);
    require(amount_in > 0);

    let now: u64 = get_clock().slot;
    require(now >= lbp.start_time);

    let weight_a: u64 = lbp.current_weight_a;
    let weight_b: u64 = 10000 - weight_a;

    let mut source_reserve: u64 = 0;
    let mut dest_reserve: u64 = 0;
    let mut source_weight: u64 = 0;
    let mut dest_weight: u64 = 0;

    if (is_a_to_b) {
        require(pool_source_vault.ctx.key == lbp.token_a_vault);
        require(pool_destination_vault.ctx.key == lbp.token_b_vault);
        source_reserve = lbp.reserve_a;
        dest_reserve = lbp.reserve_b;
        source_weight = weight_a;
        dest_weight = weight_b;
    } else {
        require(pool_source_vault.ctx.key == lbp.token_b_vault);
        require(pool_destination_vault.ctx.key == lbp.token_a_vault);
        source_reserve = lbp.reserve_b;
        dest_reserve = lbp.reserve_a;
        source_weight = weight_b;
        dest_weight = weight_a;
    }

    // Apply fee
    let fee: u64 = (amount_in * lbp.fee_numerator) / lbp.fee_denominator;
    let dx: u64 = amount_in - fee;

    // Weighted AMM formula (simplified for integer math):
    // amount_out = dest_reserve * dx * dest_weight / (source_reserve * source_weight + dx * dest_weight)
    let numerator: u64 = dest_reserve * dx * dest_weight;
    let denominator: u64 = source_reserve * source_weight + dx * dest_weight;
    let amount_out: u64 = numerator / denominator;

    require(amount_out > 0);
    require(amount_out < dest_reserve);
    require(amount_out >= min_amount_out);

    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, lbp, amount_out);

    if (is_a_to_b) {
        lbp.reserve_a = lbp.reserve_a + amount_in;
        lbp.reserve_b = lbp.reserve_b - amount_out;
    } else {
        lbp.reserve_b = lbp.reserve_b + amount_in;
        lbp.reserve_a = lbp.reserve_a - amount_out;
    }
}

/// Close the LBP and withdraw remaining tokens.
pub close_lbp(
    lbp: LBP @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(lbp.authority == authority.ctx.key);
    require(lbp.is_active);

    let now: u64 = get_clock().slot;
    require(now >= lbp.end_time);

    require(pool_token_a_vault.ctx.key == lbp.token_a_vault);
    require(pool_token_b_vault.ctx.key == lbp.token_b_vault);

    // Transfer all remaining reserves to authority
    if (lbp.reserve_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, lbp, lbp.reserve_a);
    }
    if (lbp.reserve_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, lbp, lbp.reserve_b);
    }

    lbp.reserve_a = 0;
    lbp.reserve_b = 0;
    lbp.is_active = false;
}

// ---------------------------------------------------------------------------
// Bonding Curves
// ---------------------------------------------------------------------------

/// Create a bonding curve for a token.
/// curve_type: 0 = linear (price = base + slope * supply)
///             1 = exponential (price = base * (1 + slope)^supply, approx)
///             2 = sigmoid (price = base + slope * supply / (1 + supply))
pub create_bonding_curve(
    curve: BondingCurve @mut @init(payer=creator, space=600),
    creator: account @mut @signer,
    token_mint: pubkey,
    reserve_mint: pubkey,
    reserve_vault: pubkey,
    curve_type: u8,
    slope: u64,
    base_price: u64,
    graduation_threshold: u64
) {
    require(curve_type <= 2);
    require(slope > 0);
    require(base_price > 0);
    require(graduation_threshold > 0);

    curve.authority = creator.ctx.key;
    curve.token_mint = token_mint;
    curve.reserve_mint = reserve_mint;
    curve.reserve_vault = reserve_vault;
    curve.curve_type = curve_type;
    curve.slope = slope;
    curve.base_price = base_price;
    curve.supply = 0;
    curve.reserve_balance = 0;
    curve.graduation_threshold = graduation_threshold;
    curve.is_graduated = false;
    curve.is_paused = false;
}

/// Calculate current price on the bonding curve.
fn get_curve_price(curve_type: u8, base: u64, slope: u64, supply: u64) -> u64 {
    if (curve_type == 0) {
        // Linear: price = base + slope * supply / 1000
        return base + (slope * supply) / 1000;
    }
    if (curve_type == 1) {
        // Exponential approximation: price = base + base * slope * supply / 1000000
        return base + (base * slope * supply) / 1000000;
    }
    // Sigmoid: price = base + slope * supply / (1000 + supply)
    return base + (slope * supply) / (1000 + supply);
}

/// Buy tokens from the bonding curve. Price increases with supply.
pub buy_from_curve(
    curve: BondingCurve @mut @signer,
    buyer: account @signer,
    buyer_reserve: spl_token::TokenAccount @mut @serializer("raw"),
    curve_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    token_mint: spl_token::Mint @mut @serializer("raw"),
    buyer_token: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64,
    max_cost: u64
) {
    require(!curve.is_paused);
    require(!curve.is_graduated);
    require(amount > 0);
    require(curve.token_mint == token_mint.ctx.key);
    require(curve.reserve_vault == curve_reserve_vault.ctx.key);

    // Calculate cost: sum of prices over the range [supply, supply + amount]
    // Simplified: cost = amount * average price
    let price_start: u64 = get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply);
    let price_end: u64 = get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply + amount);
    let cost: u64 = (amount * (price_start + price_end)) / 2;

    require(cost > 0);
    require(cost <= max_cost);

    // Transfer reserve tokens from buyer
    spl_token::SPLToken::transfer(buyer_reserve, curve_reserve_vault, buyer, cost);

    // Mint new tokens to buyer
    spl_token::SPLToken::mint_to(token_mint, buyer_token, curve, amount);

    curve.supply = curve.supply + amount;
    curve.reserve_balance = curve.reserve_balance + cost;
}

/// Sell tokens back to the bonding curve. Price decreases with supply.
pub sell_to_curve(
    curve: BondingCurve @mut @signer,
    seller: account @signer,
    seller_token: spl_token::TokenAccount @mut @serializer("raw"),
    token_mint: spl_token::Mint @mut @serializer("raw"),
    curve_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    seller_reserve: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64,
    min_proceeds: u64
) {
    require(!curve.is_paused);
    require(!curve.is_graduated);
    require(amount > 0);
    require(amount <= curve.supply);
    require(curve.token_mint == token_mint.ctx.key);
    require(curve.reserve_vault == curve_reserve_vault.ctx.key);

    // Calculate proceeds: sum of prices over [supply - amount, supply]
    let price_end: u64 = get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply);
    let price_start: u64 = get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply - amount);
    let proceeds: u64 = (amount * (price_start + price_end)) / 2;

    require(proceeds > 0);
    require(proceeds <= curve.reserve_balance);
    require(proceeds >= min_proceeds);

    // Burn the tokens being sold
    spl_token::SPLToken::burn(seller_token, token_mint, seller, amount);

    // Transfer reserve tokens to seller
    spl_token::SPLToken::transfer(curve_reserve_vault, seller_reserve, curve, proceeds);

    curve.supply = curve.supply - amount;
    curve.reserve_balance = curve.reserve_balance - proceeds;
}

/// Graduate the bonding curve when market cap hits the threshold.
/// After graduation, the reserve is migrated to a proper AMM pool.
pub graduate_curve(
    curve: BondingCurve @mut @signer,
    curve_reserve_vault: spl_token::TokenAccount @mut @serializer("raw"),
    amm_pool_vault: spl_token::TokenAccount @mut @serializer("raw"),
    authority: account @signer,
    token_program: account
) {
    require(!curve.is_graduated);
    require(curve.authority == authority.ctx.key);
    require(curve.reserve_balance >= curve.graduation_threshold);

    // Migrate all reserves to AMM pool
    spl_token::SPLToken::transfer(curve_reserve_vault, amm_pool_vault, curve, curve.reserve_balance);

    curve.reserve_balance = 0;
    curve.is_graduated = true;
}

// ---------------------------------------------------------------------------
// Reward Vaults
// ---------------------------------------------------------------------------

/// Create a reward vault for distributing rewards to LP stakers.
pub create_reward_vault(
    vault: RewardVault @mut @init(payer=creator, space=600),
    creator: account @mut @signer,
    stake_mint: pubkey,
    reward_mint: pubkey,
    reward_vault: pubkey,
    reward_per_second: u64
) {
    require(reward_per_second > 0);

    vault.authority = creator.ctx.key;
    vault.stake_mint = stake_mint;
    vault.reward_mint = reward_mint;
    vault.vault = reward_vault;
    vault.reward_per_second = reward_per_second;
    vault.total_staked = 0;
    vault.acc_reward_per_share = 0;
    vault.last_update = get_clock().slot;
    vault.is_paused = false;
}

/// Fund the reward vault with reward tokens.
pub fund_vault(
    vault: RewardVault,
    funder: account @signer,
    funder_token: spl_token::TokenAccount @mut @serializer("raw"),
    reward_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(amount > 0);
    require(vault.vault == reward_vault_account.ctx.key);

    spl_token::SPLToken::transfer(funder_token, reward_vault_account, funder, amount);
}

/// Internal: update accumulated rewards per share.
fn update_vault_rewards(vault: RewardVault @mut) {
    let now: u64 = get_clock().slot;
    if (vault.total_staked > 0) {
        let elapsed: u64 = now - vault.last_update;
        let new_rewards: u64 = elapsed * vault.reward_per_second;
        vault.acc_reward_per_share = vault.acc_reward_per_share + (new_rewards * 1000000000) / vault.total_staked;
    }
    vault.last_update = now;
}

/// Stake LP tokens to earn rewards.
pub stake_for_rewards(
    vault: RewardVault @mut,
    position: StakePosition @mut @init(payer=staker, space=400),
    staker: account @mut @signer,
    staker_lp: spl_token::TokenAccount @mut @serializer("raw"),
    vault_lp_account: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(!vault.is_paused);
    require(amount > 0);

    // Update rewards before changing balances
    update_vault_rewards(vault);

    spl_token::SPLToken::transfer(staker_lp, vault_lp_account, staker, amount);

    position.vault = vault.ctx.key;
    position.owner = staker.ctx.key;
    position.amount = amount;
    position.reward_debt = (amount * vault.acc_reward_per_share) / 1000000000;
    position.pending_reward = 0;

    vault.total_staked = vault.total_staked + amount;
}

/// Unstake LP tokens.
pub unstake(
    vault: RewardVault @mut @signer,
    position: StakePosition @mut,
    staker: account @signer,
    vault_lp_account: spl_token::TokenAccount @mut @serializer("raw"),
    staker_lp: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(position.owner == staker.ctx.key);
    require(position.vault == vault.ctx.key);
    require(amount > 0);
    require(amount <= position.amount);

    // Update rewards
    update_vault_rewards(vault);

    // Calculate pending rewards before unstaking
    let current_reward: u64 = (position.amount * vault.acc_reward_per_share) / 1000000000;
    let pending: u64 = current_reward - position.reward_debt;
    position.pending_reward = position.pending_reward + pending;

    spl_token::SPLToken::transfer(vault_lp_account, staker_lp, vault, amount);

    position.amount = position.amount - amount;
    vault.total_staked = vault.total_staked - amount;
    position.reward_debt = (position.amount * vault.acc_reward_per_share) / 1000000000;
}

/// Claim accumulated rewards.
pub claim_rewards(
    vault: RewardVault @mut @signer,
    position: StakePosition @mut,
    staker: account @signer,
    reward_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    staker_reward: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account
) {
    require(position.owner == staker.ctx.key);
    require(position.vault == vault.ctx.key);
    require(vault.vault == reward_vault_account.ctx.key);

    // Update rewards
    update_vault_rewards(vault);

    let current_reward: u64 = (position.amount * vault.acc_reward_per_share) / 1000000000;
    let mut claimable: u64 = 0;
    if (current_reward > position.reward_debt) {
        claimable = current_reward - position.reward_debt;
    }
    claimable = claimable + position.pending_reward;

    require(claimable > 0);

    spl_token::SPLToken::transfer(reward_vault_account, staker_reward, vault, claimable);

    position.reward_debt = current_reward;
    position.pending_reward = 0;
}

/// Update reward emission rate. Authority only.
pub set_reward_rate(
    vault: RewardVault @mut,
    authority: account @signer,
    new_rate: u64
) {
    require(vault.authority == authority.ctx.key);
    require(new_rate > 0);

    // Accrue pending rewards before changing rate
    update_vault_rewards(vault);

    vault.reward_per_second = new_rate;
}

/// Auto-reinvest pending rewards by staking them back.
/// Works when the reward token is the same as the stake token.
pub compound_rewards(
    vault: RewardVault @mut @signer,
    position: StakePosition @mut,
    staker: account @signer,
    reward_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    vault_lp_account: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account
) {
    require(!vault.is_paused);
    require(position.owner == staker.ctx.key);
    require(position.vault == vault.ctx.key);
    require(vault.vault == reward_vault_account.ctx.key);

    // Update and calculate claimable
    update_vault_rewards(vault);

    let current_reward: u64 = (position.amount * vault.acc_reward_per_share) / 1000000000;
    let mut claimable: u64 = 0;
    if (current_reward > position.reward_debt) {
        claimable = current_reward - position.reward_debt;
    }
    claimable = claimable + position.pending_reward;
    require(claimable > 0);

    // Transfer from reward vault to LP vault (re-stake)
    spl_token::SPLToken::transfer(reward_vault_account, vault_lp_account, vault, claimable);

    position.amount = position.amount + claimable;
    vault.total_staked = vault.total_staked + claimable;
    position.reward_debt = (position.amount * vault.acc_reward_per_share) / 1000000000;
    position.pending_reward = 0;
}

// ---------------------------------------------------------------------------
// Liquidity Locks
// ---------------------------------------------------------------------------

/// Lock LP tokens for a specified duration to prove long-term commitment.
pub lock_liquidity(
    lock: LiquidityLock @mut @init(payer=locker, space=400),
    locker: account @mut @signer,
    locker_lp: spl_token::TokenAccount @mut @serializer("raw"),
    lock_vault: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    lp_mint: pubkey,
    amount: u64,
    duration: u64
) {
    require(amount > 0);
    require(duration > 0);

    let now: u64 = get_clock().slot;

    spl_token::SPLToken::transfer(locker_lp, lock_vault, locker, amount);

    lock.authority = locker.ctx.key;
    lock.lp_mint = lp_mint;
    lock.owner = locker.ctx.key;
    lock.amount = amount;
    lock.unlock_time = now + duration;
    lock.is_locked = true;
}

/// Unlock LP tokens after the lock duration has expired.
pub unlock_liquidity(
    lock: LiquidityLock @mut,
    owner: account @signer,
    lock_vault: spl_token::TokenAccount @mut @serializer("raw"),
    owner_lp: spl_token::TokenAccount @mut @serializer("raw"),
    lock_authority: account @signer,
    token_program: account
) {
    require(lock.owner == owner.ctx.key);
    require(lock.is_locked);

    let now: u64 = get_clock().slot;
    require(now >= lock.unlock_time);

    spl_token::SPLToken::transfer(lock_vault, owner_lp, lock_authority, lock.amount);

    lock.is_locked = false;
    lock.amount = 0;
}

/// Extend the lock duration. Can only increase, never decrease.
pub extend_lock(
    lock: LiquidityLock @mut,
    owner: account @signer,
    additional_duration: u64
) {
    require(lock.owner == owner.ctx.key);
    require(lock.is_locked);
    require(additional_duration > 0);

    lock.unlock_time = lock.unlock_time + additional_duration;
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

/// Transfer LBP authority.
pub set_lbp_authority(
    lbp: LBP @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(lbp.authority == authority.ctx.key);
    lbp.authority = new_authority;
}

/// Transfer bonding curve authority.
pub set_curve_authority(
    curve: BondingCurve @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(curve.authority == authority.ctx.key);
    curve.authority = new_authority;
}

/// Transfer reward vault authority.
pub set_vault_authority(
    vault: RewardVault @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(vault.authority == authority.ctx.key);
    vault.authority = new_authority;
}

/// Update LBP fees.
pub set_fees(
    lbp: LBP @mut,
    authority: account @signer,
    new_fee_numerator: u64,
    new_fee_denominator: u64
) {
    require(lbp.authority == authority.ctx.key);
    require(new_fee_denominator > 0);
    require(new_fee_numerator < new_fee_denominator);
    lbp.fee_numerator = new_fee_numerator;
    lbp.fee_denominator = new_fee_denominator;
}

/// Pause or unpause an LBP.
pub set_lbp_paused(
    lbp: LBP @mut,
    authority: account @signer,
    paused: bool
) {
    require(lbp.authority == authority.ctx.key);
    lbp.is_paused = paused;
}

/// Pause or unpause a bonding curve.
pub set_curve_paused(
    curve: BondingCurve @mut,
    authority: account @signer,
    paused: bool
) {
    require(curve.authority == authority.ctx.key);
    curve.is_paused = paused;
}

/// Pause or unpause a reward vault.
pub set_vault_paused(
    vault: RewardVault @mut,
    authority: account @signer,
    paused: bool
) {
    require(vault.authority == authority.ctx.key);
    vault.is_paused = paused;
}

/// Collect protocol fees from the LBP. Authority withdraws accumulated fee residue.
pub collect_protocol_fees(
    lbp: LBP @mut @signer,
    pool_token_a_vault: account @mut,
    pool_token_b_vault: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64
) {
    require(lbp.authority == authority.ctx.key);
    require(pool_token_a_vault.ctx.key == lbp.token_a_vault);
    require(pool_token_b_vault.ctx.key == lbp.token_b_vault);
    require(amount_a <= lbp.reserve_a);
    require(amount_b <= lbp.reserve_b);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_token_a_vault, recipient_a, lbp, amount_a);
        lbp.reserve_a = lbp.reserve_a - amount_a;
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_token_b_vault, recipient_b, lbp, amount_b);
        lbp.reserve_b = lbp.reserve_b - amount_b;
    }
}

// ---------------------------------------------------------------------------
// Read helpers
// ---------------------------------------------------------------------------

pub get_lbp_current_weight(lbp: LBP) -> u64 {
    return lbp.current_weight_a;
}

pub get_curve_price_at(curve: BondingCurve) -> u64 {
    return get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply);
}

pub get_curve_market_cap(curve: BondingCurve) -> u64 {
    let price: u64 = get_curve_price(curve.curve_type, curve.base_price, curve.slope, curve.supply);
    return price * curve.supply;
}

pub get_total_staked(vault: RewardVault) -> u64 {
    return vault.total_staked;
}

pub get_lock_remaining(lock: LiquidityLock) -> u64 {
    let now: u64 = get_clock().slot;
    if (now >= lock.unlock_time) {
        return 0;
    }
    return lock.unlock_time - now;
}
