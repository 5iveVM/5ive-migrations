// Larix Lending + Fractional Protocol - 5IVE Migration
//
// Lending protocol with mining incentives (LARIX token rewards) and
// NFT fractionalization support, including fractional collateral.
//
// Lending (Solend-inspired with mining):
//   - Isolated reserves per token; LP gets cTokens representing share
//   - Utilization-based interest rate curve (kink model)
//   - Collateral obligation tracks deposited_value and borrowed_value
//   - Liquidation with configurable bonus
//   - LARIX mining rewards for depositors and borrowers
//
// Fractionalization:
//   - Lock an NFT into a vault, mint fractional tokens
//   - Buyout/auction mechanism for whole-NFT acquisition
//   - Fraction holders claim proportional auction proceeds
//   - Fractional tokens usable as lending collateral

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Market {
    admin: pubkey;
    quote_currency: pubkey;
    is_paused: bool;
    oracle: pubkey;
    protocol_fees_collected: u64;
}

account Reserve {
    market: pubkey;
    liquidity_mint: pubkey;
    liquidity_supply: pubkey;
    collateral_mint: pubkey;
    collateral_supply: u64;
    liquidity_available: u64;
    borrowed_amount: u64;
    cumulative_borrow_rate: u64;
    last_update_slot: u64;
    protocol_fees: u64;

    // Interest rate config
    optimal_utilization_rate: u8;
    loan_to_value_ratio: u8;
    liquidation_threshold: u8;
    liquidation_bonus: u8;
    max_borrow_rate: u8;
    min_borrow_rate: u8;
    reserve_factor: u8;
    supply_cap: u64;

    // Mining rewards
    mining_rate: u64;
    total_mining_reward: u64;
    last_mining_update: u64;
    acc_reward_per_share: u64;
}

account UserAccount {
    market: pubkey;
    authority: pubkey;
    deposited_value: u64;
    borrowed_value: u64;
    allowed_borrow_value: u64;
    reward_debt: u64;
    pending_reward: u64;
}

account PriceOracle {
    authority: pubkey;
    price: u64;
    decimals: u8;
    last_update: u64;
}

account FractionVault {
    authority: pubkey;
    nft_mint: pubkey;
    nft_account: pubkey;
    fraction_mint: pubkey;
    total_fractions: u64;
    is_locked: bool;
    auction_state: u8;     // 0 = none, 1 = active, 2 = settled
    highest_bid: u64;
    highest_bidder: pubkey;
    auction_end: u64;
    reserve_price: u64;
}

account Bid {
    vault: pubkey;
    bidder: pubkey;
    amount: u64;
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn calculate_utilization(liquidity: u64, borrows: u64) -> u64 {
    let total: u64 = liquidity + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * 100) / total;
}

fn calculate_borrow_rate(
    min_rate: u64,
    max_rate: u64,
    optimal: u64,
    utilization: u64
) -> u64 {
    if (utilization <= optimal) {
        if (optimal == 0) {
            return min_rate;
        }
        return min_rate + (utilization * (max_rate - min_rate)) / optimal;
    }

    let extra: u64 = utilization - optimal;
    let extra_range: u64 = 100 - optimal;
    if (extra_range == 0) {
        return max_rate;
    }
    return max_rate + (extra * max_rate) / extra_range;
}

// ---------------------------------------------------------------------------
// Lending: Market and Reserve management
// ---------------------------------------------------------------------------

/// Initialize a new lending market.
pub init_market(
    market: Market @mut @init(payer=admin, space=600),
    quote_currency: account,
    admin: account @mut @signer
) {
    market.admin = admin.ctx.key;
    market.quote_currency = quote_currency.ctx.key;
    market.is_paused = false;
    market.oracle = admin.ctx.key; // placeholder, set via set_oracle
    market.protocol_fees_collected = 0;
}

/// Initialize a reserve within a market for a specific token.
pub init_reserve(
    market: Market,
    reserve: Reserve @mut @init(payer=admin, space=800),
    liquidity_mint: spl_token::Mint @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    admin: account @mut @signer,
    config_optimal_utilization: u8,
    config_loan_to_value: u8,
    config_reserve_factor: u8,
    config_supply_cap: u64,
    initial_mining_rate: u64
) {
    require(market.admin == admin.ctx.key);
    require(config_reserve_factor <= 50);
    require(config_loan_to_value < 100);
    require(config_loan_to_value > 0);

    reserve.market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint.ctx.key;
    reserve.liquidity_supply = liquidity_supply.ctx.key;
    reserve.collateral_mint = collateral_mint.ctx.key;

    reserve.collateral_supply = 0;
    reserve.liquidity_available = 0;
    reserve.borrowed_amount = 0;
    reserve.cumulative_borrow_rate = 1000000000;
    reserve.last_update_slot = get_clock().slot;
    reserve.protocol_fees = 0;

    reserve.optimal_utilization_rate = config_optimal_utilization;
    reserve.loan_to_value_ratio = config_loan_to_value;
    reserve.liquidation_threshold = 80;
    reserve.liquidation_bonus = 5;
    reserve.max_borrow_rate = 20;
    reserve.min_borrow_rate = 2;
    reserve.reserve_factor = config_reserve_factor;
    reserve.supply_cap = config_supply_cap;

    // Mining config
    reserve.mining_rate = initial_mining_rate;
    reserve.total_mining_reward = 0;
    reserve.last_mining_update = get_clock().slot;
    reserve.acc_reward_per_share = 0;
}

/// Refresh a reserve: update timestamp, accrue interest, update mining rewards.
pub refresh_reserve(reserve: Reserve @mut) {
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - reserve.last_update_slot;

    if (elapsed > 0) {
        // Accrue interest
        if (reserve.borrowed_amount > 0) {
            let utilization: u64 = calculate_utilization(
                reserve.liquidity_available,
                reserve.borrowed_amount
            );
            let borrow_rate: u64 = calculate_borrow_rate(
                reserve.min_borrow_rate as u64,
                reserve.max_borrow_rate as u64,
                reserve.optimal_utilization_rate as u64,
                utilization
            );

            let seconds_per_year: u64 = 31536000;
            let gross_interest: u64 = (reserve.borrowed_amount * borrow_rate * elapsed) / (seconds_per_year * 100);
            let protocol_cut: u64 = (gross_interest * reserve.reserve_factor as u64) / 100;
            let lp_interest: u64 = gross_interest - protocol_cut;

            reserve.borrowed_amount = reserve.borrowed_amount + gross_interest;
            reserve.protocol_fees = reserve.protocol_fees + protocol_cut;
            reserve.liquidity_available = reserve.liquidity_available + lp_interest;

            let rate_increase: u64 = (reserve.cumulative_borrow_rate * borrow_rate * elapsed) / (seconds_per_year * 100);
            reserve.cumulative_borrow_rate = reserve.cumulative_borrow_rate + rate_increase;
        }

        // Accrue mining rewards
        if (reserve.collateral_supply > 0) {
            let mining_elapsed: u64 = now - reserve.last_mining_update;
            let new_rewards: u64 = mining_elapsed * reserve.mining_rate;
            reserve.total_mining_reward = reserve.total_mining_reward + new_rewards;
            reserve.acc_reward_per_share = reserve.acc_reward_per_share + (new_rewards * 1000000000) / reserve.collateral_supply;
        }
        reserve.last_mining_update = now;
    }

    reserve.last_update_slot = now;
}

// ---------------------------------------------------------------------------
// Lending: Deposit / Withdraw / Borrow / Repay
// ---------------------------------------------------------------------------

/// Deposit liquidity into a reserve, receive cTokens.
pub deposit(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);
    require(reserve.market == market.ctx.key);
    require(user.market == market.ctx.key);
    require(user.authority == user_authority.ctx.key);
    require(reserve.liquidity_supply == liquidity_supply.ctx.key);
    require(reserve.collateral_mint == collateral_mint.ctx.key);
    require(reserve.liquidity_available + amount <= reserve.supply_cap);

    // Update user mining rewards before changing balances
    if (user.deposited_value > 0) {
        let pending: u64 = (user.deposited_value * reserve.acc_reward_per_share) / 1000000000 - user.reward_debt;
        user.pending_reward = user.pending_reward + pending;
    }

    spl_token::SPLToken::transfer(user_liquidity, liquidity_supply, user_authority, amount);
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, amount);

    reserve.liquidity_available = reserve.liquidity_available + amount;
    reserve.collateral_supply = reserve.collateral_supply + amount;
    user.deposited_value = user.deposited_value + amount;
    user.reward_debt = (user.deposited_value * reserve.acc_reward_per_share) / 1000000000;
}

/// Withdraw liquidity by burning cTokens.
pub withdraw(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!market.is_paused);
    require(collateral_amount > 0);
    require(user.authority == user_authority.ctx.key);

    let total_liquidity: u64 = reserve.liquidity_available + reserve.borrowed_amount;
    let liquidity_amount: u64 = (collateral_amount * total_liquidity) / reserve.collateral_supply;
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.liquidity_available);

    // Health check: remaining deposit must cover borrows
    let mut remaining: u64 = 0;
    if (user.deposited_value > liquidity_amount) {
        remaining = user.deposited_value - liquidity_amount;
    }
    let max_borrow_after: u64 = (remaining * reserve.liquidation_threshold as u64) / 100;
    require(user.borrowed_value <= max_borrow_after);

    // Update mining rewards
    let pending: u64 = (user.deposited_value * reserve.acc_reward_per_share) / 1000000000 - user.reward_debt;
    user.pending_reward = user.pending_reward + pending;

    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, collateral_amount);
    spl_token::SPLToken::transfer(liquidity_supply, user_liquidity, market_authority, liquidity_amount);

    reserve.liquidity_available = reserve.liquidity_available - liquidity_amount;
    reserve.collateral_supply = reserve.collateral_supply - collateral_amount;
    user.deposited_value = user.deposited_value - liquidity_amount;
    user.reward_debt = (user.deposited_value * reserve.acc_reward_per_share) / 1000000000;
}

/// Borrow liquidity against collateral obligation.
pub borrow(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(user.authority == user_authority.ctx.key);
    require(amount > 0);
    require(amount <= reserve.liquidity_available);

    let new_borrowed: u64 = user.borrowed_value + amount;
    let ltv_limit: u64 = (user.deposited_value * reserve.loan_to_value_ratio as u64) / 100;
    let liq_limit: u64 = (user.deposited_value * reserve.liquidation_threshold as u64) / 100;

    require(new_borrowed <= ltv_limit);
    require(new_borrowed <= liq_limit);

    reserve.liquidity_available = reserve.liquidity_available - amount;
    reserve.borrowed_amount = reserve.borrowed_amount + amount;
    user.borrowed_value = new_borrowed;
    user.allowed_borrow_value = ltv_limit;

    spl_token::SPLToken::transfer(liquidity_supply, user_liquidity, market_authority, amount);
}

/// Repay borrowed liquidity.
pub repay(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!market.is_paused);
    require(amount > 0);

    let mut repay_amount: u64 = amount;
    if (amount > user.borrowed_value) {
        repay_amount = user.borrowed_value;
    }

    spl_token::SPLToken::transfer(user_liquidity, liquidity_supply, user_authority, repay_amount);

    if (reserve.borrowed_amount >= repay_amount) {
        reserve.borrowed_amount = reserve.borrowed_amount - repay_amount;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.liquidity_available = reserve.liquidity_available + repay_amount;
    user.borrowed_value = user.borrowed_value - repay_amount;
}

/// Liquidate an undercollateralized obligation.
pub liquidate(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    liquidator_liquidity: spl_token::TokenAccount @mut @serializer("raw"),
    liquidity_supply: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(repay_amount > 0);

    let now: u64 = get_clock().slot;
    require(now - oracle_state.last_update <= 100);
    require(oracle_state.price > 0);

    let liq_limit: u64 = (user.deposited_value * reserve.liquidation_threshold as u64) / 100;
    require(user.borrowed_value > liq_limit);

    let mut actual_repay: u64 = repay_amount;
    if (repay_amount > user.borrowed_value) {
        actual_repay = user.borrowed_value;
    }

    spl_token::SPLToken::transfer(liquidator_liquidity, liquidity_supply, liquidator, actual_repay);

    let collateral_to_seize: u64 = (actual_repay * (100 + reserve.liquidation_bonus as u64)) / 100;
    spl_token::SPLToken::transfer(user_collateral, liquidator_liquidity, market_authority, collateral_to_seize);

    if (reserve.borrowed_amount >= actual_repay) {
        reserve.borrowed_amount = reserve.borrowed_amount - actual_repay;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.liquidity_available = reserve.liquidity_available + actual_repay;

    if (user.borrowed_value >= actual_repay) {
        user.borrowed_value = user.borrowed_value - actual_repay;
    } else {
        user.borrowed_value = 0;
    }
}

// ---------------------------------------------------------------------------
// Mining rewards
// ---------------------------------------------------------------------------

/// Claim accumulated LARIX mining rewards.
pub claim_mining_reward(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    reward_vault: account @mut,
    user_reward_account: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account
) {
    require(!market.is_paused);
    require(user.authority == user_authority.ctx.key);

    // Calculate pending rewards
    let current_reward: u64 = (user.deposited_value * reserve.acc_reward_per_share) / 1000000000;
    let mut claimable: u64 = 0;
    if (current_reward > user.reward_debt) {
        claimable = current_reward - user.reward_debt;
    }
    claimable = claimable + user.pending_reward;

    require(claimable > 0);

    spl_token::SPLToken::transfer(reward_vault, user_reward_account, market_authority, claimable);

    user.reward_debt = current_reward;
    user.pending_reward = 0;
}

/// Admin sets mining reward emission rate per reserve.
pub set_mining_rate(
    market: Market,
    reserve: Reserve @mut,
    admin: account @signer,
    new_mining_rate: u64
) {
    require(market.admin == admin.ctx.key);
    require(reserve.market == market.ctx.key);

    // Accrue pending rewards before changing rate
    let now: u64 = get_clock().slot;
    if (reserve.collateral_supply > 0) {
        let elapsed: u64 = now - reserve.last_mining_update;
        let new_rewards: u64 = elapsed * reserve.mining_rate;
        reserve.total_mining_reward = reserve.total_mining_reward + new_rewards;
        reserve.acc_reward_per_share = reserve.acc_reward_per_share + (new_rewards * 1000000000) / reserve.collateral_supply;
    }
    reserve.last_mining_update = now;

    reserve.mining_rate = new_mining_rate;
}

// ---------------------------------------------------------------------------
// NFT Fractionalization
// ---------------------------------------------------------------------------

/// Lock an NFT into a vault and mint fractional tokens.
pub create_fraction_vault(
    vault: FractionVault @mut @init(payer=owner, space=600),
    owner: account @mut @signer,
    nft_source: spl_token::TokenAccount @mut @serializer("raw"),
    nft_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    nft_mint: spl_token::Mint @serializer("raw"),
    fraction_mint: spl_token::Mint @mut @serializer("raw"),
    owner_fraction_account: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    total_fractions: u64
) {
    require(total_fractions > 0);

    // Transfer NFT into vault
    spl_token::SPLToken::transfer(nft_source, nft_vault_account, owner, 1);

    // Mint fractional tokens to owner
    spl_token::SPLToken::mint_to(fraction_mint, owner_fraction_account, owner, total_fractions);

    vault.authority = owner.ctx.key;
    vault.nft_mint = nft_mint.ctx.key;
    vault.nft_account = nft_vault_account.ctx.key;
    vault.fraction_mint = fraction_mint.ctx.key;
    vault.total_fractions = total_fractions;
    vault.is_locked = true;
    vault.auction_state = 0;
    vault.highest_bid = 0;
    vault.highest_bidder = owner.ctx.key;
    vault.auction_end = 0;
    vault.reserve_price = 0;
}

/// Burn all fractions to redeem (unlock) the underlying NFT.
/// Caller must hold the entire fractional supply.
pub redeem_fractions(
    vault: FractionVault @mut,
    redeemer: account @signer,
    fraction_source: spl_token::TokenAccount @mut @serializer("raw"),
    fraction_mint: spl_token::Mint @mut @serializer("raw"),
    nft_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    nft_destination: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account
) {
    require(vault.is_locked);
    require(vault.auction_state == 0);
    require(vault.fraction_mint == fraction_mint.ctx.key);
    require(vault.nft_account == nft_vault_account.ctx.key);

    // Burn all fractions
    spl_token::SPLToken::burn(fraction_source, fraction_mint, redeemer, vault.total_fractions);

    // Transfer NFT out
    spl_token::SPLToken::transfer(nft_vault_account, nft_destination, vault_authority, 1);

    vault.is_locked = false;
}

/// Initiate a buyout auction for a fractioned NFT.
/// Any fraction holder can trigger this.
pub start_auction(
    vault: FractionVault @mut,
    initiator: account @signer,
    reserve_price: u64,
    duration: u64
) {
    require(vault.is_locked);
    require(vault.auction_state == 0);
    require(reserve_price > 0);
    require(duration > 0);

    let now: u64 = get_clock().slot;
    vault.auction_state = 1;
    vault.reserve_price = reserve_price;
    vault.auction_end = now + duration;
    vault.highest_bid = 0;
}

/// Place a bid on an active auction for a fractioned NFT.
pub place_bid(
    vault: FractionVault @mut,
    bid: Bid @mut @init(payer=bidder, space=300),
    bidder: account @mut @signer,
    bid_vault: spl_token::TokenAccount @mut @serializer("raw"),
    bidder_token: spl_token::TokenAccount @mut @serializer("raw"),
    token_program: account,
    amount: u64
) {
    require(vault.is_locked);
    require(vault.auction_state == 1);

    let now: u64 = get_clock().slot;
    require(now < vault.auction_end);
    require(amount > vault.highest_bid);
    require(amount >= vault.reserve_price);

    // Transfer bid amount into escrow vault
    spl_token::SPLToken::transfer(bidder_token, bid_vault, bidder, amount);

    vault.highest_bid = amount;
    vault.highest_bidder = bidder.ctx.key;

    bid.vault = vault.ctx.key;
    bid.bidder = bidder.ctx.key;
    bid.amount = amount;
    bid.is_active = true;
}

/// Buyout: directly buy the whole NFT at or above reserve price (shortcut for single-bid).
pub buyout_vault(
    vault: FractionVault @mut,
    buyer: account @mut @signer,
    buyer_token: spl_token::TokenAccount @mut @serializer("raw"),
    proceeds_vault: spl_token::TokenAccount @mut @serializer("raw"),
    nft_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    nft_destination: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(vault.is_locked);
    // Buyout allowed when no auction is running, or as winning settlement
    require(vault.auction_state == 0 || vault.auction_state == 1);
    require(amount >= vault.reserve_price || vault.reserve_price == 0);
    require(amount > 0);

    // Transfer payment into proceeds vault for fraction holders
    spl_token::SPLToken::transfer(buyer_token, proceeds_vault, buyer, amount);

    // Transfer NFT to buyer
    spl_token::SPLToken::transfer(nft_vault_account, nft_destination, vault_authority, 1);

    vault.highest_bid = amount;
    vault.highest_bidder = buyer.ctx.key;
    vault.auction_state = 2; // settled
    vault.is_locked = false;
}

/// Settle an auction after it ends. Winner gets NFT, proceeds go to escrow.
pub settle_auction(
    vault: FractionVault @mut,
    nft_vault_account: spl_token::TokenAccount @mut @serializer("raw"),
    nft_destination: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account
) {
    require(vault.auction_state == 1);
    require(vault.highest_bid > 0);

    let now: u64 = get_clock().slot;
    require(now >= vault.auction_end);

    // Transfer NFT to highest bidder
    spl_token::SPLToken::transfer(nft_vault_account, nft_destination, vault_authority, 1);

    vault.auction_state = 2; // settled
    vault.is_locked = false;
}

/// Fraction holder claims their proportional share of auction proceeds.
pub claim_auction_proceeds(
    vault: FractionVault,
    claimant: account @signer,
    fraction_source: spl_token::TokenAccount @mut @serializer("raw"),
    fraction_mint: spl_token::Mint @mut @serializer("raw"),
    proceeds_vault: spl_token::TokenAccount @mut @serializer("raw"),
    claimant_token: spl_token::TokenAccount @mut @serializer("raw"),
    vault_authority: account @signer,
    token_program: account,
    fraction_amount: u64
) {
    require(vault.auction_state == 2);
    require(fraction_amount > 0);
    require(vault.total_fractions > 0);

    // Calculate proportional payout
    let payout: u64 = (fraction_amount * vault.highest_bid) / vault.total_fractions;
    require(payout > 0);

    // Burn the fractions
    spl_token::SPLToken::burn(fraction_source, fraction_mint, claimant, fraction_amount);

    // Transfer proportional proceeds
    spl_token::SPLToken::transfer(proceeds_vault, claimant_token, vault_authority, payout);
}

// ---------------------------------------------------------------------------
// Fractional Collateral (lending integration)
// ---------------------------------------------------------------------------

/// Deposit fractional tokens as collateral in the lending market.
pub deposit_fractions_as_collateral(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_fractions: spl_token::TokenAccount @mut @serializer("raw"),
    fraction_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(amount > 0);
    require(user.authority == user_authority.ctx.key);
    require(reserve.market == market.ctx.key);

    let now: u64 = get_clock().slot;
    require(now - oracle_state.last_update <= 100);

    // Value the fractions via oracle price
    let value: u64 = (amount * oracle_state.price) / (10 as u64);

    // Transfer fractions into lending vault
    spl_token::SPLToken::transfer(user_fractions, fraction_vault, user_authority, amount);

    // Mint cTokens representing the collateral
    spl_token::SPLToken::mint_to(collateral_mint, user_collateral, market_authority, amount);

    reserve.collateral_supply = reserve.collateral_supply + amount;
    user.deposited_value = user.deposited_value + value;
    user.allowed_borrow_value = (user.deposited_value * reserve.loan_to_value_ratio as u64) / 100;
}

/// Withdraw fractional collateral from the lending market.
pub withdraw_fraction_collateral(
    market: Market,
    reserve: Reserve @mut,
    user: UserAccount @mut,
    user_fractions: spl_token::TokenAccount @mut @serializer("raw"),
    fraction_vault: spl_token::TokenAccount @mut @serializer("raw"),
    user_collateral: spl_token::TokenAccount @mut @serializer("raw"),
    collateral_mint: spl_token::Mint @mut @serializer("raw"),
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64,
    oracle_state: PriceOracle
) {
    require(!market.is_paused);
    require(amount > 0);
    require(user.authority == user_authority.ctx.key);

    let now: u64 = get_clock().slot;
    require(now - oracle_state.last_update <= 100);

    let value: u64 = (amount * oracle_state.price) / (10 as u64);

    // Health check: remaining must cover borrows
    let mut remaining_value: u64 = 0;
    if (user.deposited_value > value) {
        remaining_value = user.deposited_value - value;
    }
    let max_borrow_after: u64 = (remaining_value * reserve.liquidation_threshold as u64) / 100;
    require(user.borrowed_value <= max_borrow_after);

    // Burn cTokens
    spl_token::SPLToken::burn(user_collateral, collateral_mint, user_authority, amount);

    // Return fractions
    spl_token::SPLToken::transfer(fraction_vault, user_fractions, market_authority, amount);

    reserve.collateral_supply = reserve.collateral_supply - amount;
    user.deposited_value = user.deposited_value - value;
    user.allowed_borrow_value = (user.deposited_value * reserve.loan_to_value_ratio as u64) / 100;
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

/// Set the oracle address for the market.
pub set_oracle(
    market: Market @mut,
    admin: account @signer,
    new_oracle: pubkey
) {
    require(market.admin == admin.ctx.key);
    market.oracle = new_oracle;
}

/// Update the oracle price feed.
pub update_oracle(
    oracle: PriceOracle @mut,
    authority: account @signer,
    price: u64,
    decimals: u8
) {
    require(oracle.authority == authority.ctx.key);
    require(price > 0);
    oracle.price = price;
    oracle.decimals = decimals;
    oracle.last_update = get_clock().slot;
}

/// Transfer market admin authority.
pub set_authority(
    market: Market @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(market.admin == admin.ctx.key);
    market.admin = new_admin;
}

/// Pause or unpause the lending market.
pub set_paused(
    market: Market @mut,
    admin: account @signer,
    paused: bool
) {
    require(market.admin == admin.ctx.key);
    market.is_paused = paused;
}

// ---------------------------------------------------------------------------
// Read helpers
// ---------------------------------------------------------------------------

pub get_utilization(liquidity: u64, borrows: u64) -> u64 {
    return calculate_utilization(liquidity, borrows);
}

pub get_borrow_rate(min_rate: u64, max_rate: u64, optimal: u64, utilization: u64) -> u64 {
    return calculate_borrow_rate(min_rate, max_rate, optimal, utilization);
}

pub get_vault_auction_state(vault: FractionVault) -> u8 {
    return vault.auction_state;
}

pub get_mining_reward(reserve: Reserve) -> u64 {
    return reserve.total_mining_reward;
}
