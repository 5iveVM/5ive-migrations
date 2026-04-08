// 5IVE Friktion Migration
//
// Structured products -- DeFi Options Vaults (DOVs).
// Auto-sells covered calls / cash-secured puts in weekly/biweekly epochs.
// Users deposit underlying tokens, vault sells options, premium = yield.
//
// Strategy types: 0 = covered_call, 1 = cash_secured_put,
//                 2 = basis_yield, 3 = protection
//
// Key concept: Epochs -- each vault runs in cycles. Users deposit during an epoch,
// vault sells options at start of next epoch, options settle at expiry.
//
// Instructions (18):
//   create_volt, deposit_to_volt, withdraw_from_volt, start_epoch, sell_options,
//   settle_epoch, claim_pending, create_entropy_round, rebalance_entropy,
//   set_volt_params, set_auction_params, set_performance_fee, collect_fees,
//   emergency_withdraw, set_authority, pause, unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Volt {
    authority: pubkey;
    underlying_mint: pubkey;
    quote_mint: pubkey;
    volt_token_mint: pubkey;
    vault: pubkey;
    premium_vault: pubkey;

    strategy_type: u8;
    epoch_length: u64;
    current_epoch: u64;

    // Current options state
    strike_price: u64;
    premium_collected: u64;

    // Vault totals
    total_deposited: u64;
    total_shares: u64;

    // Fee config
    performance_fee_bps: u64;
    management_fee_bps: u64;
    accumulated_fees: u64;

    // Auction params
    min_premium_bps: u64;
    max_strike_offset_bps: u64;

    is_paused: bool;
}

account Epoch {
    volt: pubkey;
    epoch_number: u64;
    start_time: u64;
    end_time: u64;
    strike_price: u64;
    options_minted: u64;
    options_sold: u64;
    premium: u64;
    settled: bool;
    pnl: i64;
}

account UserDeposit {
    volt: pubkey;
    owner: pubkey;
    shares: u64;
    pending_deposit: u64;
    pending_withdrawal: u64;
    last_epoch: u64;
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

fn calculate_underlying(shares: u64, total_shares: u64, total_deposited: u64) -> u64 {
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
// Instructions -- Volt lifecycle
// ---------------------------------------------------------------------------

pub create_volt(
    volt: Volt @mut @init(payer=creator, space=1024),
    creator: account @signer,
    underlying_mint: pubkey,
    quote_mint: pubkey,
    volt_token_mint: pubkey,
    vault: pubkey,
    premium_vault: pubkey,
    strategy_type: u8,
    epoch_length: u64,
    performance_fee_bps: u64,
    management_fee_bps: u64
) {
    require(strategy_type <= 3);
    require(epoch_length > 0);
    require(performance_fee_bps <= 5000);
    require(management_fee_bps <= 500);

    volt.authority = creator.ctx.key;
    volt.underlying_mint = underlying_mint;
    volt.quote_mint = quote_mint;
    volt.volt_token_mint = volt_token_mint;
    volt.vault = vault;
    volt.premium_vault = premium_vault;
    volt.strategy_type = strategy_type;
    volt.epoch_length = epoch_length;
    volt.current_epoch = 0;
    volt.strike_price = 0;
    volt.premium_collected = 0;
    volt.total_deposited = 0;
    volt.total_shares = 0;
    volt.performance_fee_bps = performance_fee_bps;
    volt.management_fee_bps = management_fee_bps;
    volt.accumulated_fees = 0;
    volt.min_premium_bps = 100;
    volt.max_strike_offset_bps = 2000;
    volt.is_paused = false;
}

// ---------------------------------------------------------------------------
// Instructions -- User deposit / withdraw
// ---------------------------------------------------------------------------

pub deposit_to_volt(
    volt: Volt @mut,
    user_deposit: UserDeposit @mut @init(payer=owner, space=384),
    owner: account @signer,
    user_underlying: account @mut,
    volt_vault: account @mut,
    volt_token_mint: account @mut,
    user_volt_tokens: account @mut,
    token_program: account,
    amount: u64
) {
    require(!volt.is_paused);
    require(amount > 0);
    require(volt_vault.ctx.key == volt.vault);

    // Calculate volt token shares
    let shares: u64 = calculate_shares(amount, volt.total_shares, volt.total_deposited);
    require(shares > 0);

    // Transfer underlying into vault
    spl_token::SPLToken::transfer(user_underlying, volt_vault, owner, amount);

    // Mint volt tokens to user
    spl_token::SPLToken::mint_to(volt_token_mint, user_volt_tokens, owner, shares);

    volt.total_deposited = volt.total_deposited + amount;
    volt.total_shares = volt.total_shares + shares;

    user_deposit.volt = volt.ctx.key;
    user_deposit.owner = owner.ctx.key;
    user_deposit.shares = user_deposit.shares + shares;
    user_deposit.pending_deposit = user_deposit.pending_deposit + amount;
    user_deposit.last_epoch = volt.current_epoch;
}

pub withdraw_from_volt(
    volt: Volt @mut @signer,
    user_deposit: UserDeposit @mut,
    owner: account @signer,
    user_volt_tokens: account @mut,
    volt_token_mint: account @mut,
    volt_vault: account @mut,
    user_underlying: account @mut,
    token_program: account,
    shares_to_burn: u64
) {
    require(!volt.is_paused);
    require(shares_to_burn > 0);
    require(user_deposit.volt == volt.ctx.key);
    require(user_deposit.owner == owner.ctx.key);
    require(shares_to_burn <= user_deposit.shares);
    require(volt_vault.ctx.key == volt.vault);

    // Calculate underlying amount for shares
    let underlying_amount: u64 = calculate_underlying(shares_to_burn, volt.total_shares, volt.total_deposited);
    require(underlying_amount > 0);
    require(underlying_amount <= volt.total_deposited);

    // Burn volt tokens
    spl_token::SPLToken::burn(user_volt_tokens, volt_token_mint, owner, shares_to_burn);

    // Transfer underlying back to user
    spl_token::SPLToken::transfer(volt_vault, user_underlying, volt, underlying_amount);

    volt.total_deposited = volt.total_deposited - underlying_amount;
    volt.total_shares = volt.total_shares - shares_to_burn;
    user_deposit.shares = user_deposit.shares - shares_to_burn;
    if (user_deposit.pending_deposit >= underlying_amount) {
        user_deposit.pending_deposit = user_deposit.pending_deposit - underlying_amount;
    } else {
        user_deposit.pending_deposit = 0;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Epoch lifecycle
// ---------------------------------------------------------------------------

pub start_epoch(
    volt: Volt @mut,
    epoch: Epoch @mut @init(payer=authority, space=512),
    authority: account @signer,
    strike_price: u64,
    oracle_price: u64
) {
    require(!volt.is_paused);
    require(volt.authority == authority.ctx.key);
    require(strike_price > 0);
    require(oracle_price > 0);

    // Validate strike price within allowed offset
    let max_offset: u64 = (oracle_price * volt.max_strike_offset_bps) / 10000;
    if (strike_price > oracle_price) {
        require(strike_price - oracle_price <= max_offset);
    } else {
        require(oracle_price - strike_price <= max_offset);
    }

    let now: u64 = get_clock().slot;

    volt.current_epoch = volt.current_epoch + 1;
    volt.strike_price = strike_price;
    volt.premium_collected = 0;

    epoch.volt = volt.ctx.key;
    epoch.epoch_number = volt.current_epoch;
    epoch.start_time = now;
    epoch.end_time = now + volt.epoch_length;
    epoch.strike_price = strike_price;
    epoch.options_minted = volt.total_deposited;
    epoch.options_sold = 0;
    epoch.premium = 0;
    epoch.settled = false;
    epoch.pnl = 0;
}

pub sell_options(
    volt: Volt @mut,
    epoch: Epoch @mut,
    authority: account @signer,
    premium_source: account @mut,
    volt_premium_vault: account @mut,
    buyer: account @signer,
    token_program: account,
    options_amount: u64,
    premium_amount: u64
) {
    require(!volt.is_paused);
    require(volt.authority == authority.ctx.key);
    require(epoch.volt == volt.ctx.key);
    require(epoch.epoch_number == volt.current_epoch);
    require(!epoch.settled);
    require(options_amount > 0);
    require(premium_amount > 0);
    require(volt_premium_vault.ctx.key == volt.premium_vault);

    // Ensure enough options to sell
    let remaining: u64 = epoch.options_minted - epoch.options_sold;
    require(options_amount <= remaining);

    // Check minimum premium
    let min_premium: u64 = (options_amount * volt.min_premium_bps) / 10000;
    require(premium_amount >= min_premium);

    // Collect premium from buyer
    spl_token::SPLToken::transfer(premium_source, volt_premium_vault, buyer, premium_amount);

    epoch.options_sold = epoch.options_sold + options_amount;
    epoch.premium = epoch.premium + premium_amount;
    volt.premium_collected = volt.premium_collected + premium_amount;
}

pub settle_epoch(
    volt: Volt @mut @signer,
    epoch: Epoch @mut,
    authority: account @signer,
    volt_vault: account @mut,
    volt_premium_vault: account @mut,
    token_program: account,
    settlement_price: u64
) {
    require(volt.authority == authority.ctx.key);
    require(epoch.volt == volt.ctx.key);
    require(epoch.epoch_number == volt.current_epoch);
    require(!epoch.settled);
    require(volt_vault.ctx.key == volt.vault);
    require(volt_premium_vault.ctx.key == volt.premium_vault);

    // Check epoch has expired
    let now: u64 = get_clock().slot;
    require(now >= epoch.end_time);

    let mut pnl: i64 = epoch.premium as i64;

    if (volt.strategy_type == 0) {
        // Covered call: if settlement > strike, options are exercised
        // Loss = (settlement - strike) * options_sold (capped at deposited)
        if (settlement_price > epoch.strike_price) {
            let loss_per_unit: u64 = settlement_price - epoch.strike_price;
            let total_loss: u64 = (loss_per_unit * epoch.options_sold) / settlement_price;
            pnl = pnl - total_loss as i64;
        }
    } else {
        if (volt.strategy_type == 1) {
            // Cash-secured put: if settlement < strike, options are exercised
            if (settlement_price < epoch.strike_price) {
                let loss_per_unit: u64 = epoch.strike_price - settlement_price;
                let total_loss: u64 = (loss_per_unit * epoch.options_sold) / epoch.strike_price;
                pnl = pnl - total_loss as i64;
            }
        }
    }

    epoch.pnl = pnl;
    epoch.settled = true;

    // Apply performance fee on positive PnL
    if (pnl > 0) {
        let profit: u64 = pnl as u64;
        let perf_fee: u64 = (profit * volt.performance_fee_bps) / 10000;
        volt.accumulated_fees = volt.accumulated_fees + perf_fee;

        // Net premium goes back to vault depositors
        let net_profit: u64 = profit - perf_fee;

        // Transfer premium from premium vault to main vault
        spl_token::SPLToken::transfer(volt_premium_vault, volt_vault, volt, net_profit);
        volt.total_deposited = volt.total_deposited + net_profit;
    } else {
        // Negative PnL: reduce total deposited
        let loss: u64 = abs_i64(pnl);
        if (volt.total_deposited > loss) {
            volt.total_deposited = volt.total_deposited - loss;
        } else {
            volt.total_deposited = 0;
        }
    }
}

pub claim_pending(
    volt: Volt,
    user_deposit: UserDeposit @mut,
    owner: account @signer
) {
    require(user_deposit.volt == volt.ctx.key);
    require(user_deposit.owner == owner.ctx.key);

    // Pending deposits are confirmed after epoch boundary
    require(volt.current_epoch > user_deposit.last_epoch);

    user_deposit.pending_deposit = 0;
    user_deposit.pending_withdrawal = 0;
    user_deposit.last_epoch = volt.current_epoch;
}

// ---------------------------------------------------------------------------
// Instructions -- Entropy (basis yield strategy)
// ---------------------------------------------------------------------------

pub create_entropy_round(
    volt: Volt @mut,
    authority: account @signer,
    deposit_amount: u64
) {
    require(volt.authority == authority.ctx.key);
    require(volt.strategy_type == 2);
    require(deposit_amount > 0);
    require(deposit_amount <= volt.total_deposited);

    // Basis yield: deposit to external protocol for yield
    // In production this would CPI into Mango/other perp protocol
    // Here we track the allocation
    volt.premium_collected = deposit_amount;
}

pub rebalance_entropy(
    volt: Volt @mut,
    authority: account @signer,
    new_amount: u64,
    realized_yield: u64
) {
    require(volt.authority == authority.ctx.key);
    require(volt.strategy_type == 2);

    // Apply yield from basis trade
    if (realized_yield > 0) {
        let perf_fee: u64 = (realized_yield * volt.performance_fee_bps) / 10000;
        volt.accumulated_fees = volt.accumulated_fees + perf_fee;
        volt.total_deposited = volt.total_deposited + realized_yield - perf_fee;
    }

    volt.premium_collected = new_amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Admin configuration
// ---------------------------------------------------------------------------

pub set_volt_params(
    volt: Volt @mut,
    authority: account @signer,
    min_premium_bps: u64,
    max_strike_offset_bps: u64
) {
    require(volt.authority == authority.ctx.key);
    require(max_strike_offset_bps <= 10000);
    volt.min_premium_bps = min_premium_bps;
    volt.max_strike_offset_bps = max_strike_offset_bps;
}

pub set_auction_params(
    volt: Volt @mut,
    authority: account @signer,
    min_premium_bps: u64
) {
    require(volt.authority == authority.ctx.key);
    volt.min_premium_bps = min_premium_bps;
}

pub set_performance_fee(
    volt: Volt @mut,
    authority: account @signer,
    new_performance_fee_bps: u64
) {
    require(volt.authority == authority.ctx.key);
    require(new_performance_fee_bps <= 5000);
    volt.performance_fee_bps = new_performance_fee_bps;
}

pub collect_fees(
    volt: Volt @mut @signer,
    authority: account @signer,
    volt_vault: account @mut,
    fee_recipient: account @mut,
    token_program: account
) {
    require(volt.authority == authority.ctx.key);
    require(volt.accumulated_fees > 0);
    require(volt_vault.ctx.key == volt.vault);

    let fees: u64 = volt.accumulated_fees;
    volt.accumulated_fees = 0;

    spl_token::SPLToken::transfer(volt_vault, fee_recipient, volt, fees);
}

pub emergency_withdraw(
    volt: Volt @mut @signer,
    authority: account @signer,
    volt_vault: account @mut,
    recipient: account @mut,
    token_program: account,
    amount: u64
) {
    require(volt.authority == authority.ctx.key);
    require(amount > 0);
    require(volt_vault.ctx.key == volt.vault);

    spl_token::SPLToken::transfer(volt_vault, recipient, volt, amount);

    if (volt.total_deposited >= amount) {
        volt.total_deposited = volt.total_deposited - amount;
    } else {
        volt.total_deposited = 0;
    }
}

pub set_authority(
    volt: Volt @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(volt.authority == authority.ctx.key);
    volt.authority = new_authority;
}

pub pause(
    volt: Volt @mut,
    authority: account @signer
) {
    require(volt.authority == authority.ctx.key);
    volt.is_paused = true;
}

pub unpause(
    volt: Volt @mut,
    authority: account @signer
) {
    require(volt.authority == authority.ctx.key);
    volt.is_paused = false;
}
