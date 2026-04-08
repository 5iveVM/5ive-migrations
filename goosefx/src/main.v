// 5IVE GooseFX Migration
//
// DEX with Single-Sided Liquidity (SSL) AMM + perpetuals + GOFX staking.
//
// Key innovation: SSL = single-sided liquidity. LPs deposit only ONE token
// (not a pair). Protocol uses oracle to determine fair price. Less impermanent
// loss than traditional AMM since pricing is oracle-driven.
//
// Instructions (20):
//   create_ssl_pool, deposit_ssl, withdraw_ssl, ssl_swap,
//   create_perp_market, open_perp_position, close_perp_position,
//   place_perp_order, cancel_perp_order, settle_funding, liquidate_perp,
//   deposit_margin, withdraw_margin, create_staking_pool, stake_gofx,
//   unstake_gofx, claim_staking_rewards, set_ssl_params, set_authority,
//   pause/unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account SSLPool {
    authority: pubkey;
    token_mint: pubkey;
    vault: pubkey;
    oracle: pubkey;
    oracle_price: u64;
    total_deposited: u64;
    total_shares: u64;
    virtual_price: u64;
    fee_bps: u64;
    protocol_fees: u64;
    is_paused: bool;
}

account SSLPosition {
    pool: pubkey;
    owner: pubkey;
    deposited: u64;
    shares: u64;
}

account PerpMarket {
    authority: pubkey;
    oracle: pubkey;
    oracle_price: u64;
    funding_rate: i64;
    open_interest_long: u64;
    open_interest_short: u64;
    cumulative_funding: i64;
    last_funding_slot: u64;
    funding_interval: u64;
    maintenance_margin_bps: u64;
    taker_fee_bps: u64;
    insurance_vault: pubkey;
    insurance_balance: u64;
    is_paused: bool;
}

account PerpPosition {
    market: pubkey;
    owner: pubkey;
    size: i64;
    entry_price: u64;
    margin: u64;
    last_funding_index: i64;
    realized_pnl: i64;
}

account StakingPool {
    authority: pubkey;
    gofx_mint: pubkey;
    stake_vault: pubkey;
    reward_vault: pubkey;
    reward_mint: pubkey;
    total_staked: u64;
    reward_per_share: u64;
    last_update_slot: u64;
    reward_rate_per_slot: u64;
}

account StakeRecord {
    pool: pubkey;
    owner: pubkey;
    staked_amount: u64;
    reward_debt: u64;
    pending_reward: u64;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_shares(amount: u64, total_shares: u64, total_deposited: u64) -> u64 {
    if (total_shares == 0) {
        return amount;
    }
    return (amount * total_shares) / total_deposited;
}

fn calculate_withdrawal(shares: u64, total_shares: u64, total_deposited: u64) -> u64 {
    if (total_shares == 0) {
        return 0;
    }
    return (shares * total_deposited) / total_shares;
}

fn abs_i64(val: i64) -> u64 {
    if (val < 0) {
        return (0 - val) as u64;
    }
    return val as u64;
}

// ---------------------------------------------------------------------------
// Instructions -- SSL Pool lifecycle
// ---------------------------------------------------------------------------

pub create_ssl_pool(
    pool: SSLPool @mut @init(payer=creator, space=512),
    creator: account @signer,
    token_mint: pubkey,
    vault: pubkey,
    oracle: pubkey,
    fee_bps: u64
) {
    require(fee_bps > 0);
    require(fee_bps <= 1000);

    pool.authority = creator.ctx.key;
    pool.token_mint = token_mint;
    pool.vault = vault;
    pool.oracle = oracle;
    pool.oracle_price = 0;
    pool.total_deposited = 0;
    pool.total_shares = 0;
    pool.virtual_price = 1000000;
    pool.fee_bps = fee_bps;
    pool.protocol_fees = 0;
    pool.is_paused = false;
}

pub deposit_ssl(
    pool: SSLPool @mut,
    position: SSLPosition @mut @init(payer=owner, space=256),
    owner: account @signer,
    user_token: account @mut,
    pool_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!pool.is_paused);
    require(amount > 0);
    require(pool_vault.ctx.key == pool.vault);

    let shares: u64 = calculate_shares(amount, pool.total_shares, pool.total_deposited);
    require(shares > 0);

    spl_token::SPLToken::transfer(user_token, pool_vault, owner, amount);

    pool.total_deposited = pool.total_deposited + amount;
    pool.total_shares = pool.total_shares + shares;

    position.pool = pool.ctx.key;
    position.owner = owner.ctx.key;
    position.deposited = position.deposited + amount;
    position.shares = position.shares + shares;
}

pub withdraw_ssl(
    pool: SSLPool @mut @signer,
    position: SSLPosition @mut,
    owner: account @signer,
    pool_vault: account @mut,
    user_token: account @mut,
    token_program: account,
    shares_to_burn: u64
) {
    require(!pool.is_paused);
    require(shares_to_burn > 0);
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(shares_to_burn <= position.shares);
    require(pool_vault.ctx.key == pool.vault);

    let amount: u64 = calculate_withdrawal(shares_to_burn, pool.total_shares, pool.total_deposited);
    require(amount > 0);
    require(amount <= pool.total_deposited);

    spl_token::SPLToken::transfer(pool_vault, user_token, pool, amount);

    pool.total_deposited = pool.total_deposited - amount;
    pool.total_shares = pool.total_shares - shares_to_burn;
    position.shares = position.shares - shares_to_burn;
    if (position.deposited >= amount) {
        position.deposited = position.deposited - amount;
    } else {
        position.deposited = 0;
    }
}

pub ssl_swap(
    pool_in: SSLPool @mut @signer,
    pool_out: SSLPool @mut @signer,
    user_source: account @mut,
    user_destination: account @mut,
    vault_in: account @mut,
    vault_out: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_in: u64,
    min_amount_out: u64
) {
    require(!pool_in.is_paused);
    require(!pool_out.is_paused);
    require(amount_in > 0);
    require(vault_in.ctx.key == pool_in.vault);
    require(vault_out.ctx.key == pool_out.vault);
    require(pool_in.oracle_price > 0);
    require(pool_out.oracle_price > 0);

    // Fee on input
    let fee: u64 = (amount_in * pool_in.fee_bps) / 10000;
    let amount_after_fee: u64 = amount_in - fee;

    // Oracle-based pricing: amount_out = amount_in * price_in / price_out
    let amount_out: u64 = (amount_after_fee * pool_in.oracle_price) / pool_out.oracle_price;
    require(amount_out > 0);
    require(amount_out >= min_amount_out);
    require(amount_out <= pool_out.total_deposited);

    // Transfer in
    spl_token::SPLToken::transfer(user_source, vault_in, user_authority, amount_in);

    // Transfer out
    spl_token::SPLToken::transfer(vault_out, user_destination, pool_out, amount_out);

    // Update pool balances
    pool_in.total_deposited = pool_in.total_deposited + amount_after_fee;
    pool_in.protocol_fees = pool_in.protocol_fees + fee;
    pool_out.total_deposited = pool_out.total_deposited - amount_out;
}

pub set_ssl_params(
    pool: SSLPool @mut,
    authority: account @signer,
    fee_bps: u64,
    oracle_price: u64
) {
    require(pool.authority == authority.ctx.key);
    require(fee_bps <= 1000);
    require(oracle_price > 0);
    pool.fee_bps = fee_bps;
    pool.oracle_price = oracle_price;
}

// ---------------------------------------------------------------------------
// Instructions -- Perpetuals
// ---------------------------------------------------------------------------

pub create_perp_market(
    market: PerpMarket @mut @init(payer=creator, space=768),
    creator: account @signer,
    oracle: pubkey,
    insurance_vault: pubkey,
    funding_interval: u64,
    maintenance_margin_bps: u64,
    taker_fee_bps: u64
) {
    require(funding_interval > 0);
    require(maintenance_margin_bps > 0);
    require(taker_fee_bps > 0);

    market.authority = creator.ctx.key;
    market.oracle = oracle;
    market.oracle_price = 0;
    market.funding_rate = 0;
    market.open_interest_long = 0;
    market.open_interest_short = 0;
    market.cumulative_funding = 0;
    market.last_funding_slot = get_clock().slot;
    market.funding_interval = funding_interval;
    market.maintenance_margin_bps = maintenance_margin_bps;
    market.taker_fee_bps = taker_fee_bps;
    market.insurance_vault = insurance_vault;
    market.insurance_balance = 0;
    market.is_paused = false;
}

pub deposit_margin(
    market: PerpMarket,
    position: PerpPosition @mut,
    user_token: account @mut,
    margin_vault: account @mut,
    owner: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(position.market == market.ctx.key);
    require(position.owner == owner.ctx.key);

    spl_token::SPLToken::transfer(user_token, margin_vault, owner, amount);
    position.margin = position.margin + amount;
}

pub withdraw_margin(
    market: PerpMarket @signer,
    position: PerpPosition @mut,
    margin_vault: account @mut,
    user_token: account @mut,
    owner: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(position.market == market.ctx.key);
    require(position.owner == owner.ctx.key);
    require(amount <= position.margin);

    // Check margin requirement after withdrawal
    let remaining_margin: u64 = position.margin - amount;
    let position_value: u64 = abs_i64(position.size) * position.entry_price;
    let required_margin: u64 = (position_value * market.maintenance_margin_bps) / 10000;
    require(remaining_margin >= required_margin);

    spl_token::SPLToken::transfer(margin_vault, user_token, market, amount);
    position.margin = remaining_margin;
}

pub open_perp_position(
    market: PerpMarket @mut,
    position: PerpPosition @mut @init(payer=owner, space=512),
    owner: account @signer,
    user_token: account @mut,
    margin_vault: account @mut,
    token_program: account,
    margin_amount: u64,
    size: i64,
    oracle_price: u64
) {
    require(!market.is_paused);
    require(margin_amount > 0);
    require(size != 0);
    require(oracle_price > 0);

    // Initial margin check
    let position_value: u64 = abs_i64(size) * oracle_price;
    let required_margin: u64 = (position_value * market.maintenance_margin_bps) / 10000;
    require(margin_amount >= required_margin);

    // Fee
    let fee: u64 = (position_value * market.taker_fee_bps) / 10000;
    require(margin_amount > fee);

    spl_token::SPLToken::transfer(user_token, margin_vault, owner, margin_amount);

    position.market = market.ctx.key;
    position.owner = owner.ctx.key;
    position.size = size;
    position.entry_price = oracle_price;
    position.margin = margin_amount - fee;
    position.last_funding_index = market.cumulative_funding;
    position.realized_pnl = 0;

    // Update open interest
    if (size > 0) {
        market.open_interest_long = market.open_interest_long + abs_i64(size);
    } else {
        market.open_interest_short = market.open_interest_short + abs_i64(size);
    }
    market.oracle_price = oracle_price;
}

pub close_perp_position(
    market: PerpMarket @mut @signer,
    position: PerpPosition @mut,
    margin_vault: account @mut,
    user_token: account @mut,
    owner: account @signer,
    token_program: account,
    oracle_price: u64
) {
    require(!market.is_paused);
    require(position.market == market.ctx.key);
    require(position.owner == owner.ctx.key);
    require(position.size != 0);
    require(oracle_price > 0);

    // Calculate PnL
    let mut pnl: i64 = 0;
    let size_abs: u64 = abs_i64(position.size);
    if (position.size > 0) {
        // Long: profit if price went up
        if (oracle_price > position.entry_price) {
            pnl = (size_abs * (oracle_price - position.entry_price)) as i64;
        } else {
            pnl = 0 - (size_abs * (position.entry_price - oracle_price)) as i64;
        }
    } else {
        // Short: profit if price went down
        if (oracle_price < position.entry_price) {
            pnl = (size_abs * (position.entry_price - oracle_price)) as i64;
        } else {
            pnl = 0 - (size_abs * (oracle_price - position.entry_price)) as i64;
        }
    }

    // Apply funding delta
    let funding_delta: i64 = market.cumulative_funding - position.last_funding_index;
    let funding_payment: i64 = position.size * funding_delta;

    // Fee
    let close_value: u64 = size_abs * oracle_price;
    let fee: u64 = (close_value * market.taker_fee_bps) / 10000;

    // Total payout = margin + pnl - funding - fee
    let mut payout: u64 = position.margin;
    if (pnl > 0) {
        payout = payout + pnl as u64;
    } else {
        let loss: u64 = abs_i64(pnl);
        if (payout > loss) {
            payout = payout - loss;
        } else {
            payout = 0;
        }
    }
    if (funding_payment > 0) {
        let fp: u64 = funding_payment as u64;
        if (payout > fp) {
            payout = payout - fp;
        } else {
            payout = 0;
        }
    } else {
        payout = payout + abs_i64(funding_payment);
    }
    if (payout > fee) {
        payout = payout - fee;
    } else {
        payout = 0;
    }

    if (payout > 0) {
        spl_token::SPLToken::transfer(margin_vault, user_token, market, payout);
    }

    // Update open interest
    if (position.size > 0) {
        if (market.open_interest_long >= size_abs) {
            market.open_interest_long = market.open_interest_long - size_abs;
        } else {
            market.open_interest_long = 0;
        }
    } else {
        if (market.open_interest_short >= size_abs) {
            market.open_interest_short = market.open_interest_short - size_abs;
        } else {
            market.open_interest_short = 0;
        }
    }

    position.size = 0;
    position.margin = 0;
    position.realized_pnl = position.realized_pnl + pnl;
}

pub place_perp_order(
    market: PerpMarket @mut,
    position: PerpPosition @mut,
    owner: account @signer,
    additional_size: i64,
    oracle_price: u64
) {
    require(!market.is_paused);
    require(position.market == market.ctx.key);
    require(position.owner == owner.ctx.key);
    require(additional_size != 0);
    require(oracle_price > 0);

    // Weighted average entry price
    let old_abs: u64 = abs_i64(position.size);
    let new_abs: u64 = abs_i64(additional_size);
    let total_abs: u64 = old_abs + new_abs;
    if (total_abs > 0) {
        position.entry_price = (old_abs * position.entry_price + new_abs * oracle_price) / total_abs;
    }
    position.size = position.size + additional_size;

    // Margin check
    let position_value: u64 = abs_i64(position.size) * position.entry_price;
    let required: u64 = (position_value * market.maintenance_margin_bps) / 10000;
    require(position.margin >= required);

    // Update OI
    if (additional_size > 0) {
        market.open_interest_long = market.open_interest_long + new_abs;
    } else {
        market.open_interest_short = market.open_interest_short + new_abs;
    }
    market.oracle_price = oracle_price;
}

pub cancel_perp_order(
    market: PerpMarket @mut,
    position: PerpPosition @mut,
    owner: account @signer,
    reduce_size: i64
) {
    require(position.market == market.ctx.key);
    require(position.owner == owner.ctx.key);
    require(reduce_size != 0);

    // Reduce position size towards zero
    let old_abs: u64 = abs_i64(position.size);
    let reduce_abs: u64 = abs_i64(reduce_size);
    require(reduce_abs <= old_abs);

    if (position.size > 0) {
        position.size = position.size - reduce_abs as i64;
        if (market.open_interest_long >= reduce_abs) {
            market.open_interest_long = market.open_interest_long - reduce_abs;
        }
    } else {
        position.size = position.size + reduce_abs as i64;
        if (market.open_interest_short >= reduce_abs) {
            market.open_interest_short = market.open_interest_short - reduce_abs;
        }
    }
}

pub settle_funding(
    market: PerpMarket @mut,
    authority: account @signer,
    oracle_price: u64
) {
    require(market.authority == authority.ctx.key);
    require(oracle_price > 0);

    let now: u64 = get_clock().slot;
    require(now >= market.last_funding_slot + market.funding_interval);

    // Funding rate = (mark - index) / index * scale
    // Simplified: if longs > shorts, longs pay; otherwise shorts pay
    let mut new_funding: i64 = 0;
    if (market.open_interest_long > market.open_interest_short) {
        let imbalance: u64 = market.open_interest_long - market.open_interest_short;
        new_funding = (imbalance * 100) as i64 / (market.open_interest_long as i64 + 1);
    } else {
        if (market.open_interest_short > market.open_interest_long) {
            let imbalance: u64 = market.open_interest_short - market.open_interest_long;
            new_funding = 0 - ((imbalance * 100) as i64 / (market.open_interest_short as i64 + 1));
        }
    }

    market.funding_rate = new_funding;
    market.cumulative_funding = market.cumulative_funding + new_funding;
    market.last_funding_slot = now;
    market.oracle_price = oracle_price;
}

pub liquidate_perp(
    market: PerpMarket @mut @signer,
    position: PerpPosition @mut,
    margin_vault: account @mut,
    liquidator_token: account @mut,
    liquidator: account @signer,
    token_program: account,
    oracle_price: u64
) {
    require(!market.is_paused);
    require(position.market == market.ctx.key);
    require(oracle_price > 0);

    // Calculate unrealized PnL
    let size_abs: u64 = abs_i64(position.size);
    let mut loss: u64 = 0;
    if (position.size > 0) {
        if (oracle_price < position.entry_price) {
            loss = size_abs * (position.entry_price - oracle_price);
        }
    } else {
        if (oracle_price > position.entry_price) {
            loss = size_abs * (oracle_price - position.entry_price);
        }
    }

    // Check if position is below maintenance margin
    let position_value: u64 = size_abs * oracle_price;
    let required_margin: u64 = (position_value * market.maintenance_margin_bps) / 10000;
    let mut effective_margin: u64 = position.margin;
    if (effective_margin > loss) {
        effective_margin = effective_margin - loss;
    } else {
        effective_margin = 0;
    }
    require(effective_margin < required_margin);

    // Liquidator receives half of remaining margin as reward
    let reward: u64 = effective_margin / 2;
    if (reward > 0) {
        spl_token::SPLToken::transfer(margin_vault, liquidator_token, market, reward);
    }

    // Remaining margin goes to insurance fund
    let insurance_portion: u64 = effective_margin - reward;
    market.insurance_balance = market.insurance_balance + insurance_portion;

    // Clear position
    if (position.size > 0) {
        if (market.open_interest_long >= size_abs) {
            market.open_interest_long = market.open_interest_long - size_abs;
        } else {
            market.open_interest_long = 0;
        }
    } else {
        if (market.open_interest_short >= size_abs) {
            market.open_interest_short = market.open_interest_short - size_abs;
        } else {
            market.open_interest_short = 0;
        }
    }
    position.size = 0;
    position.margin = 0;
}

// ---------------------------------------------------------------------------
// Instructions -- GOFX Staking
// ---------------------------------------------------------------------------

pub create_staking_pool(
    pool: StakingPool @mut @init(payer=creator, space=512),
    creator: account @signer,
    gofx_mint: pubkey,
    stake_vault: pubkey,
    reward_vault: pubkey,
    reward_mint: pubkey,
    reward_rate_per_slot: u64
) {
    pool.authority = creator.ctx.key;
    pool.gofx_mint = gofx_mint;
    pool.stake_vault = stake_vault;
    pool.reward_vault = reward_vault;
    pool.reward_mint = reward_mint;
    pool.total_staked = 0;
    pool.reward_per_share = 0;
    pool.last_update_slot = get_clock().slot;
    pool.reward_rate_per_slot = reward_rate_per_slot;
}

pub stake_gofx(
    pool: StakingPool @mut,
    record: StakeRecord @mut @init(payer=owner, space=256),
    owner: account @signer,
    user_gofx: account @mut,
    stake_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(amount > 0);
    require(stake_vault.ctx.key == pool.stake_vault);

    // Update reward accumulator before changing stakes
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - pool.last_update_slot;
    if (elapsed > 0) {
        if (pool.total_staked > 0) {
            let new_rewards: u64 = elapsed * pool.reward_rate_per_slot;
            pool.reward_per_share = pool.reward_per_share + (new_rewards * 1000000000) / pool.total_staked;
        }
        pool.last_update_slot = now;
    }

    // Accrue pending rewards for existing stake
    if (record.staked_amount > 0) {
        let pending: u64 = (record.staked_amount * pool.reward_per_share) / 1000000000 - record.reward_debt;
        record.pending_reward = record.pending_reward + pending;
    }

    spl_token::SPLToken::transfer(user_gofx, stake_vault, owner, amount);

    record.pool = pool.ctx.key;
    record.owner = owner.ctx.key;
    record.staked_amount = record.staked_amount + amount;
    record.reward_debt = (record.staked_amount * pool.reward_per_share) / 1000000000;
    pool.total_staked = pool.total_staked + amount;
}

pub unstake_gofx(
    pool: StakingPool @mut @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    stake_vault: account @mut,
    user_gofx: account @mut,
    token_program: account,
    amount: u64
) {
    require(amount > 0);
    require(record.pool == pool.ctx.key);
    require(record.owner == owner.ctx.key);
    require(amount <= record.staked_amount);
    require(stake_vault.ctx.key == pool.stake_vault);

    // Update reward accumulator
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - pool.last_update_slot;
    if (elapsed > 0) {
        if (pool.total_staked > 0) {
            let new_rewards: u64 = elapsed * pool.reward_rate_per_slot;
            pool.reward_per_share = pool.reward_per_share + (new_rewards * 1000000000) / pool.total_staked;
        }
        pool.last_update_slot = now;
    }

    // Accrue pending rewards
    let pending: u64 = (record.staked_amount * pool.reward_per_share) / 1000000000 - record.reward_debt;
    record.pending_reward = record.pending_reward + pending;

    spl_token::SPLToken::transfer(stake_vault, user_gofx, pool, amount);

    record.staked_amount = record.staked_amount - amount;
    record.reward_debt = (record.staked_amount * pool.reward_per_share) / 1000000000;
    pool.total_staked = pool.total_staked - amount;
}

pub claim_staking_rewards(
    pool: StakingPool @mut @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    reward_vault: account @mut,
    user_reward: account @mut,
    token_program: account
) {
    require(record.pool == pool.ctx.key);
    require(record.owner == owner.ctx.key);
    require(reward_vault.ctx.key == pool.reward_vault);

    // Update accumulator
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - pool.last_update_slot;
    if (elapsed > 0) {
        if (pool.total_staked > 0) {
            let new_rewards: u64 = elapsed * pool.reward_rate_per_slot;
            pool.reward_per_share = pool.reward_per_share + (new_rewards * 1000000000) / pool.total_staked;
        }
        pool.last_update_slot = now;
    }

    let pending: u64 = (record.staked_amount * pool.reward_per_share) / 1000000000 - record.reward_debt;
    let total_reward: u64 = record.pending_reward + pending;
    require(total_reward > 0);

    spl_token::SPLToken::transfer(reward_vault, user_reward, pool, total_reward);

    record.pending_reward = 0;
    record.reward_debt = (record.staked_amount * pool.reward_per_share) / 1000000000;
}

// ---------------------------------------------------------------------------
// Instructions -- Admin
// ---------------------------------------------------------------------------

pub set_authority(
    pool: SSLPool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

pub pause_unpause(
    pool: SSLPool @mut,
    authority: account @signer,
    paused: bool
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = paused;
}
