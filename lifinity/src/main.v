// Lifinity Protocol -- 5ive DSL Migration
//
// Proactive Market Maker (PMM): uses oracle prices to SET the swap price
// instead of discovering it from reserve ratios like a traditional AMM.
//
// Key innovation:
//   - Price is determined BY THE ORACLE, not by constant product formula
//   - Spread widens dynamically during volatility (min_spread_bps..max_spread_bps)
//   - Virtual reserves are computed FROM oracle price, not from actual token balances
//   - Concentration multiplier amplifies effective liquidity depth
//   - Result: drastically reduced impermanent loss for LPs
//
// Math:
//   effective_price = oracle_price * (1 +/- spread_bps / 10000)
//   virtual_reserve_b = virtual_reserve_a * oracle_price
//   concentrated_reserve = virtual_reserve * concentration
//
// Integer-only arithmetic; BPS_SCALE = 10000

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Pool {
    token_a_mint: pubkey;
    token_b_mint: pubkey;
    token_a_vault: pubkey;
    token_b_vault: pubkey;
    oracle: pubkey;                 // price oracle for the pair
    lp_mint: pubkey;
    virtual_reserve_a: u64;         // computed from real reserves + concentration
    virtual_reserve_b: u64;         // = virtual_reserve_a * oracle_price / PRICE_SCALE
    real_reserve_a: u64;            // actual token A in vault
    real_reserve_b: u64;            // actual token B in vault
    concentration: u64;             // liquidity concentration multiplier (1x = 100)
    min_spread_bps: u64;            // minimum spread in basis points
    max_spread_bps: u64;            // maximum spread (used during volatility)
    current_spread_bps: u64;        // active spread
    oracle_price: u64;              // cached oracle price (scaled by PRICE_SCALE)
    last_oracle_update: u64;        // slot of last oracle refresh
    fee_rate_bps: u64;              // swap fee in basis points
    total_fees_a: u64;              // accumulated fees in token A
    total_fees_b: u64;              // accumulated fees in token B
    lp_supply: u64;                 // total LP tokens outstanding
    authority: pubkey;
    is_paused: bool;
}

account PriceOracle {
    authority: pubkey;
    price: u64;                     // price scaled by 1e9 (PRICE_SCALE)
    confidence: u64;                // confidence band width
    last_update: u64;               // slot of last update
}

account NftPool {
    collection_mint: pubkey;        // NFT collection identifier
    token_vault: pubkey;            // SOL/token vault for NFT trading
    oracle: pubkey;                 // floor price oracle
    floor_price: u64;               // cached floor price
    spread_bps: u64;                // spread for NFT swaps
    fee_rate_bps: u64;
    total_fees: u64;
    authority: pubkey;
    is_paused: bool;
}

account RewardDistributor {
    pool: pubkey;
    reward_mint: pubkey;
    reward_vault: pubkey;
    total_distributed: u64;
    rewards_per_share: u64;         // accumulated rewards per LP share (scaled)
    last_update_slot: u64;
    authority: pubkey;
}

// PRICE_SCALE = 1000000000 (1e9)

// ---------------------------------------------------------------------------
// Pool lifecycle
// ---------------------------------------------------------------------------

// 1. create_pool -- Initialize a Lifinity-style PMM pool for a token pair.
//    Oracle determines price; spread and concentration are configurable.
pub create_pool(
    pool: Pool @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    token_a_mint: pubkey,
    token_b_mint: pubkey,
    token_a_vault: pubkey,
    token_b_vault: pubkey,
    oracle: pubkey,
    lp_mint: pubkey,
    min_spread_bps: u64,
    max_spread_bps: u64,
    concentration: u64,
    fee_rate_bps: u64
) {
    require(min_spread_bps <= max_spread_bps);
    require(max_spread_bps < 10000);   // spread cannot exceed 100%
    require(concentration > 0);
    require(fee_rate_bps < 10000);

    pool.token_a_mint = token_a_mint;
    pool.token_b_mint = token_b_mint;
    pool.token_a_vault = token_a_vault;
    pool.token_b_vault = token_b_vault;
    pool.oracle = oracle;
    pool.lp_mint = lp_mint;
    pool.virtual_reserve_a = 0;
    pool.virtual_reserve_b = 0;
    pool.real_reserve_a = 0;
    pool.real_reserve_b = 0;
    pool.concentration = concentration;
    pool.min_spread_bps = min_spread_bps;
    pool.max_spread_bps = max_spread_bps;
    pool.current_spread_bps = min_spread_bps;
    pool.oracle_price = 0;
    pool.last_oracle_update = 0;
    pool.fee_rate_bps = fee_rate_bps;
    pool.total_fees_a = 0;
    pool.total_fees_b = 0;
    pool.lp_supply = 0;
    pool.authority = creator.ctx.key;
    pool.is_paused = false;
}

// 2. deposit -- Add liquidity to the pool. LP tokens minted proportionally.
//    First depositor sets the baseline ratio.
pub deposit(
    pool: Pool @mut @signer,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    lp_mint: account @mut,
    user_lp_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64,
    min_lp_tokens: u64
) {
    require(!pool.is_paused);
    require(amount_a > 0 || amount_b > 0);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    let mut lp_to_mint: u64 = 0;

    if (pool.lp_supply == 0) {
        // First deposit: LP tokens = sum of deposits
        lp_to_mint = amount_a + amount_b;
    } else {
        // Proportional minting based on total real reserves
        let total_reserves: u64 = pool.real_reserve_a + pool.real_reserve_b;
        require(total_reserves > 0);
        let deposit_value: u64 = amount_a + amount_b;
        lp_to_mint = (deposit_value * pool.lp_supply) / total_reserves;
    }

    require(lp_to_mint > 0);
    require(lp_to_mint >= min_lp_tokens);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, pool_vault_a, user_authority, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, pool_vault_b, user_authority, amount_b);
    }
    spl_token::SPLToken::mint_to(lp_mint, user_lp_account, pool, lp_to_mint);

    pool.real_reserve_a = pool.real_reserve_a + amount_a;
    pool.real_reserve_b = pool.real_reserve_b + amount_b;
    pool.lp_supply = pool.lp_supply + lp_to_mint;

    // Recompute virtual reserves from oracle price and concentration
    // virtual_reserve_a = real_reserve_a * concentration / 100
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    if (pool.oracle_price > 0) {
        pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
    }
}

// 3. withdraw -- Remove liquidity by burning LP tokens. Proportional redemption.
pub withdraw(
    pool: Pool @mut @signer,
    user_lp_account: account @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    lp_mint: account @mut,
    user_authority: account @signer,
    token_program: account,
    lp_amount: u64,
    min_amount_a: u64,
    min_amount_b: u64
) {
    require(!pool.is_paused);
    require(lp_amount > 0);
    require(lp_amount <= pool.lp_supply);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);
    require(lp_mint.ctx.key == pool.lp_mint);

    let amount_a: u64 = (lp_amount * pool.real_reserve_a) / pool.lp_supply;
    let amount_b: u64 = (lp_amount * pool.real_reserve_b) / pool.lp_supply;
    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    spl_token::SPLToken::burn(user_lp_account, lp_mint, user_authority, lp_amount);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, amount_b);
    }

    pool.real_reserve_a = pool.real_reserve_a - amount_a;
    pool.real_reserve_b = pool.real_reserve_b - amount_b;
    pool.lp_supply = pool.lp_supply - lp_amount;

    // Recompute virtual reserves
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    if (pool.oracle_price > 0) {
        pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
    }
}

// ---------------------------------------------------------------------------
// Oracle-driven swap
// ---------------------------------------------------------------------------

// Internal: compute spread based on oracle confidence.
// Higher confidence band = more volatility = wider spread.
fn compute_dynamic_spread(
    min_spread: u64,
    max_spread: u64,
    confidence: u64,
    price: u64
) -> u64 {
    if (price == 0) {
        return max_spread;
    }
    // confidence_ratio = confidence * 10000 / price (in bps)
    let confidence_bps: u64 = (confidence * 10000) / price;

    // Linear interpolation: spread = min + confidence_bps, clamped to max
    let spread: u64 = min_spread + confidence_bps;
    if (spread > max_spread) {
        return max_spread;
    }
    return spread;
}

// 4. swap -- Execute a swap using oracle-determined price with dynamic spread.
//    The price is NOT from reserves; it is the oracle price adjusted by spread.
//    is_a_to_b: true = sell A for B, false = sell B for A
pub swap(
    pool: Pool @mut @signer,
    oracle: PriceOracle,
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
    require(!pool.is_paused);
    require(amount_in > 0);
    require(oracle.ctx.key == pool.oracle);

    // Oracle freshness check
    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    // Dynamic spread from oracle confidence
    let spread: u64 = compute_dynamic_spread(
        pool.min_spread_bps,
        pool.max_spread_bps,
        oracle.confidence,
        oracle.price
    );
    pool.current_spread_bps = spread;

    // Swap fee
    let fee: u64 = (amount_in * pool.fee_rate_bps) / 10000;
    let amount_after_fee: u64 = amount_in - fee;

    let mut amount_out: u64 = 0;

    if (is_a_to_b) {
        // Selling A for B: user gets B at oracle_price minus spread (worse for seller)
        // effective_price = oracle_price * (10000 - spread) / 10000
        // amount_out = amount_after_fee * effective_price / PRICE_SCALE
        require(pool_source_vault.ctx.key == pool.token_a_vault);
        require(pool_destination_vault.ctx.key == pool.token_b_vault);

        let effective_price: u64 = (oracle.price * (10000 - spread)) / 10000;
        amount_out = (amount_after_fee * effective_price) / 1000000000;

        require(amount_out > 0);
        require(amount_out <= pool.real_reserve_b);

        pool.real_reserve_a = pool.real_reserve_a + amount_in - fee;
        pool.real_reserve_b = pool.real_reserve_b - amount_out;
        pool.total_fees_a = pool.total_fees_a + fee;
    } else {
        // Selling B for A: user gets A at 1/oracle_price minus spread
        // amount_out = amount_after_fee * PRICE_SCALE / (oracle_price * (10000 + spread) / 10000)
        require(pool_source_vault.ctx.key == pool.token_b_vault);
        require(pool_destination_vault.ctx.key == pool.token_a_vault);

        let effective_price: u64 = (oracle.price * (10000 + spread)) / 10000;
        require(effective_price > 0);
        amount_out = (amount_after_fee * 1000000000) / effective_price;

        require(amount_out > 0);
        require(amount_out <= pool.real_reserve_a);

        pool.real_reserve_b = pool.real_reserve_b + amount_in - fee;
        pool.real_reserve_a = pool.real_reserve_a - amount_out;
        pool.total_fees_b = pool.total_fees_b + fee;
    }

    require(amount_out >= min_amount_out);

    spl_token::SPLToken::transfer(user_source, pool_source_vault, user_authority, amount_in);
    spl_token::SPLToken::transfer(pool_destination_vault, user_destination, pool, amount_out);

    // Update cached oracle price
    pool.oracle_price = oracle.price;
    pool.last_oracle_update = now;

    // Recompute virtual reserves from updated real reserves
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
}

// 5. update_oracle_price -- Refresh the pool's cached oracle price.
//    Permissionless; anyone can trigger a price refresh.
pub update_oracle_price(
    pool: Pool @mut,
    oracle: PriceOracle
) {
    require(oracle.ctx.key == pool.oracle);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    pool.oracle_price = oracle.price;
    pool.last_oracle_update = now;

    // Recompute virtual reserves with new price
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
}

// 6. set_spread -- Admin: configure min and max spread bounds.
pub set_spread(
    pool: Pool @mut,
    authority: account @signer,
    new_min_spread_bps: u64,
    new_max_spread_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_min_spread_bps <= new_max_spread_bps);
    require(new_max_spread_bps < 10000);

    pool.min_spread_bps = new_min_spread_bps;
    pool.max_spread_bps = new_max_spread_bps;

    // Clamp current spread to new bounds
    if (pool.current_spread_bps < new_min_spread_bps) {
        pool.current_spread_bps = new_min_spread_bps;
    }
    if (pool.current_spread_bps > new_max_spread_bps) {
        pool.current_spread_bps = new_max_spread_bps;
    }
}

// 7. set_concentration -- Admin: update liquidity concentration factor.
//    Higher concentration = deeper effective liquidity = less slippage.
pub set_concentration(
    pool: Pool @mut,
    authority: account @signer,
    new_concentration: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_concentration > 0);

    pool.concentration = new_concentration;

    // Recompute virtual reserves
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    if (pool.oracle_price > 0) {
        pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
    }
}

// 8. rebalance -- Adjust virtual reserves to match the latest oracle price.
//    Permissionless crank; recalculates virtual reserves from real reserves.
pub rebalance(
    pool: Pool @mut,
    oracle: PriceOracle
) {
    require(!pool.is_paused);
    require(oracle.ctx.key == pool.oracle);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    pool.oracle_price = oracle.price;
    pool.last_oracle_update = now;
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
}

// 9. collect_fees -- Admin: withdraw accumulated swap fees.
pub collect_fees(
    pool: Pool @mut @signer,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account,
    amount_a: u64,
    amount_b: u64
) {
    require(pool.authority == authority.ctx.key);
    require(pool_vault_a.ctx.key == pool.token_a_vault);
    require(pool_vault_b.ctx.key == pool.token_b_vault);
    require(amount_a <= pool.total_fees_a);
    require(amount_b <= pool.total_fees_b);

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, recipient_a, pool, amount_a);
        pool.total_fees_a = pool.total_fees_a - amount_a;
        pool.real_reserve_a = pool.real_reserve_a - amount_a;
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, recipient_b, pool, amount_b);
        pool.total_fees_b = pool.total_fees_b - amount_b;
        pool.real_reserve_b = pool.real_reserve_b - amount_b;
    }
}

// 10. set_fee_rate -- Admin: update swap fee rate.
pub set_fee_rate(
    pool: Pool @mut,
    authority: account @signer,
    new_fee_rate_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_fee_rate_bps < 10000);
    pool.fee_rate_bps = new_fee_rate_bps;
}

// ---------------------------------------------------------------------------
// NFT trading (Lifinity NFT pools)
// ---------------------------------------------------------------------------

// 11. create_nft_pool -- Initialize an oracle-priced pool for NFT trading.
pub create_nft_pool(
    nft_pool: NftPool @mut @init(payer=creator, space=512) @signer,
    creator: account @mut @signer,
    collection_mint: pubkey,
    token_vault: pubkey,
    oracle: pubkey,
    spread_bps: u64,
    fee_rate_bps: u64
) {
    require(spread_bps < 10000);
    require(fee_rate_bps < 10000);

    nft_pool.collection_mint = collection_mint;
    nft_pool.token_vault = token_vault;
    nft_pool.oracle = oracle;
    nft_pool.floor_price = 0;
    nft_pool.spread_bps = spread_bps;
    nft_pool.fee_rate_bps = fee_rate_bps;
    nft_pool.total_fees = 0;
    nft_pool.authority = creator.ctx.key;
    nft_pool.is_paused = false;
}

// 12. nft_swap -- Buy/sell an NFT against the oracle floor price with spread.
//    is_buy: true = buy NFT (pay tokens), false = sell NFT (receive tokens)
pub nft_swap(
    nft_pool: NftPool @mut @signer,
    oracle: PriceOracle,
    user_token_account: account @mut,
    pool_token_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    is_buy: bool
) {
    require(!nft_pool.is_paused);
    require(oracle.ctx.key == nft_pool.oracle);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);
    require(pool_token_vault.ctx.key == nft_pool.token_vault);

    nft_pool.floor_price = oracle.price;

    if (is_buy) {
        // Buyer pays floor_price + spread + fee
        let price_with_spread: u64 = (oracle.price * (10000 + nft_pool.spread_bps)) / 10000;
        let fee: u64 = (price_with_spread * nft_pool.fee_rate_bps) / 10000;
        let total_cost: u64 = price_with_spread + fee;

        spl_token::SPLToken::transfer(user_token_account, pool_token_vault, user_authority, total_cost);
        nft_pool.total_fees = nft_pool.total_fees + fee;
    } else {
        // Seller receives floor_price - spread - fee
        let price_with_spread: u64 = (oracle.price * (10000 - nft_pool.spread_bps)) / 10000;
        let fee: u64 = (price_with_spread * nft_pool.fee_rate_bps) / 10000;
        let payout: u64 = price_with_spread - fee;
        require(payout > 0);

        spl_token::SPLToken::transfer(pool_token_vault, user_token_account, nft_pool, payout);
        nft_pool.total_fees = nft_pool.total_fees + fee;
    }
}

// ---------------------------------------------------------------------------
// Admin and rewards
// ---------------------------------------------------------------------------

// 13. set_authority -- Transfer pool admin to a new key.
pub set_authority(
    pool: Pool @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(pool.authority == authority.ctx.key);
    pool.authority = new_authority;
}

// 14. pause -- Halt all pool operations.
pub pause(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = true;
}

// 15. unpause -- Resume pool operations.
pub unpause(
    pool: Pool @mut,
    authority: account @signer
) {
    require(pool.authority == authority.ctx.key);
    pool.is_paused = false;
}

// 16. update_pool_config -- Admin: batch-update pool configuration.
pub update_pool_config(
    pool: Pool @mut,
    authority: account @signer,
    new_min_spread_bps: u64,
    new_max_spread_bps: u64,
    new_concentration: u64,
    new_fee_rate_bps: u64
) {
    require(pool.authority == authority.ctx.key);
    require(new_min_spread_bps <= new_max_spread_bps);
    require(new_max_spread_bps < 10000);
    require(new_concentration > 0);
    require(new_fee_rate_bps < 10000);

    pool.min_spread_bps = new_min_spread_bps;
    pool.max_spread_bps = new_max_spread_bps;
    pool.concentration = new_concentration;
    pool.fee_rate_bps = new_fee_rate_bps;

    // Recompute virtual reserves
    pool.virtual_reserve_a = (pool.real_reserve_a * pool.concentration) / 100;
    if (pool.oracle_price > 0) {
        pool.virtual_reserve_b = (pool.virtual_reserve_a * pool.oracle_price) / 1000000000;
    }
}

// 17. claim_rewards -- LP claims accumulated rewards from the distributor.
pub claim_rewards(
    distributor: RewardDistributor @mut @signer,
    pool: Pool,
    reward_vault: account @mut,
    user_reward_account: account @mut,
    user_lp_account: account,
    user_authority: account @signer,
    token_program: account,
    user_lp_balance: u64
) {
    require(distributor.pool == pool.ctx.key);
    require(reward_vault.ctx.key == distributor.reward_vault);
    require(user_lp_balance > 0);
    require(distributor.rewards_per_share > 0);

    // rewards = user_lp_balance * rewards_per_share / 1e9 (scale factor)
    let pending_reward: u64 = (user_lp_balance * distributor.rewards_per_share) / 1000000000;
    require(pending_reward > 0);

    spl_token::SPLToken::transfer(reward_vault, user_reward_account, distributor, pending_reward);
    distributor.total_distributed = distributor.total_distributed + pending_reward;
}

// 18. distribute_rewards -- Authority: deposit rewards and update per-share accumulator.
pub distribute_rewards(
    distributor: RewardDistributor @mut,
    pool: Pool,
    reward_source: account @mut,
    reward_vault: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(distributor.authority == authority.ctx.key);
    require(distributor.pool == pool.ctx.key);
    require(reward_vault.ctx.key == distributor.reward_vault);
    require(amount > 0);
    require(pool.lp_supply > 0);

    spl_token::SPLToken::transfer(reward_source, reward_vault, authority, amount);

    // Increase rewards per share: amount * 1e9 / total_lp_supply
    let increase: u64 = (amount * 1000000000) / pool.lp_supply;
    distributor.rewards_per_share = distributor.rewards_per_share + increase;
    distributor.last_update_slot = get_clock().slot;
}
