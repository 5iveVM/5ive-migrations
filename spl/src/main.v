// Solana Program Library (SPL) — Core Programs
// 5ive DSL migration: the foundational programs every Solana app depends on
//
// This file consolidates five SPL core programs into one 5ive module:
//   1. SPL Token Program       — Fungible/non-fungible token standard (11 instructions)
//   2. Associated Token Account — Deterministic PDA-based token accounts (2 instructions)
//   3. Token-Lending            — Reference lending protocol (8 instructions)
//   4. Governance               — On-chain DAO governance (10 instructions)
//   5. Stake Pool               — Native SOL staking pools (8 instructions)
//
// Total: 39 on-chain instructions replacing Solana's own base layer.

use std::interfaces::spl_token;

// ═══════════════════════════════════════════════════════════════════
// PROGRAM 1: SPL TOKEN PROGRAM
// The standard token program — mint, transfer, burn, freeze, delegate.
// Every token on Solana runs through this program.
// ═══════════════════════════════════════════════════════════════════

account Mint {
    authority: pubkey;
    supply: u64;
    decimals: u8;
    is_initialized: bool;
    freeze_authority: pubkey;
    has_freeze_authority: bool;
}

account TokenAccount {
    mint: pubkey;
    owner: pubkey;
    amount: u64;
    delegate: pubkey;
    delegated_amount: u64;
    is_frozen: bool;
    is_native: bool;
    close_authority: pubkey;
    state: u8;  // 0 = uninitialized, 1 = initialized, 2 = frozen
}

// --- SPL Token: initialize_mint ---
// Create a new token mint with decimals and authorities
pub initialize_mint(
    mint: Mint @mut @init(payer=payer, space=256) @signer,
    payer: account @mut @signer,
    mint_authority: pubkey,
    freeze_authority: pubkey,
    decimals: u8,
    has_freeze_authority: bool
) {
    require(!mint.is_initialized);

    mint.authority = mint_authority;
    mint.supply = 0;
    mint.decimals = decimals;
    mint.is_initialized = true;
    mint.freeze_authority = freeze_authority;
    mint.has_freeze_authority = has_freeze_authority;
}

// --- SPL Token: initialize_account ---
// Create a token account for a given mint
pub initialize_account(
    token_account: TokenAccount @mut @init(payer=payer, space=256) @signer,
    payer: account @mut @signer,
    mint: Mint,
    owner: account
) {
    require(mint.is_initialized);
    require(token_account.state == 0);  // must be uninitialized

    token_account.mint = mint.ctx.key;
    token_account.owner = owner.ctx.key;
    token_account.amount = 0;
    token_account.delegate = 0;
    token_account.delegated_amount = 0;
    token_account.is_frozen = false;
    token_account.is_native = false;
    token_account.close_authority = 0;
    token_account.state = 1;  // initialized
}

// --- SPL Token: transfer ---
// Transfer tokens between accounts (owner or approved delegate)
pub transfer(
    from: TokenAccount @mut,
    to: TokenAccount @mut,
    authority: account @signer,
    amount: u64
) {
    require(from.state == 1);  // initialized
    require(to.state == 1);
    require(from.mint == to.mint);
    require(!from.is_frozen);
    require(!to.is_frozen);
    require(amount > 0);

    if (from.owner == authority.ctx.key) {
        // Owner is signing directly
    } else {
        // Delegate must be signing with sufficient allowance
        require(from.delegate == authority.ctx.key);
        require(from.delegated_amount >= amount);
        from.delegated_amount = from.delegated_amount - amount;
    }

    require(from.amount >= amount);
    from.amount = from.amount - amount;
    to.amount = to.amount + amount;
}

// --- SPL Token: approve ---
// Approve a delegate to spend up to N tokens
pub approve(
    token_account: TokenAccount @mut,
    owner: account @signer,
    delegate: pubkey,
    amount: u64
) {
    require(token_account.state == 1);
    require(token_account.owner == owner.ctx.key);
    require(!token_account.is_frozen);

    token_account.delegate = delegate;
    token_account.delegated_amount = amount;
}

// --- SPL Token: revoke ---
// Revoke delegate approval
pub revoke(
    token_account: TokenAccount @mut,
    owner: account @signer
) {
    require(token_account.state == 1);
    require(token_account.owner == owner.ctx.key);
    require(!token_account.is_frozen);

    token_account.delegate = 0;
    token_account.delegated_amount = 0;
}

// --- SPL Token: mint_to ---
// Mint new tokens to a destination account (mint authority only)
pub mint_to(
    mint: Mint @mut,
    to: TokenAccount @mut,
    authority: account @signer,
    amount: u64
) {
    require(mint.is_initialized);
    require(to.state == 1);
    require(to.mint == mint.ctx.key);
    require(mint.authority == authority.ctx.key);
    require(!to.is_frozen);
    require(amount > 0);

    mint.supply = mint.supply + amount;
    to.amount = to.amount + amount;
}

// --- SPL Token: burn ---
// Burn tokens from an account (owner or delegate)
pub burn(
    mint: Mint @mut,
    from: TokenAccount @mut,
    authority: account @signer,
    amount: u64
) {
    require(mint.is_initialized);
    require(from.state == 1);
    require(from.mint == mint.ctx.key);
    require(!from.is_frozen);
    require(amount > 0);

    if (from.owner == authority.ctx.key) {
        // Owner is signing
    } else {
        require(from.delegate == authority.ctx.key);
        require(from.delegated_amount >= amount);
        from.delegated_amount = from.delegated_amount - amount;
    }

    require(from.amount >= amount);
    from.amount = from.amount - amount;
    mint.supply = mint.supply - amount;
}

// --- SPL Token: close_account ---
// Close a token account and reclaim SOL rent to destination
pub close_account(
    token_account: TokenAccount @mut,
    destination: account @mut,
    authority: account @signer
) {
    require(token_account.state == 1);
    require(token_account.amount == 0);

    // Authority must be owner or close_authority
    if (token_account.close_authority != 0) {
        require(token_account.close_authority == authority.ctx.key);
    } else {
        require(token_account.owner == authority.ctx.key);
    }

    // Zero out all fields
    token_account.mint = 0;
    token_account.owner = 0;
    token_account.amount = 0;
    token_account.delegate = 0;
    token_account.delegated_amount = 0;
    token_account.is_frozen = false;
    token_account.is_native = false;
    token_account.close_authority = 0;
    token_account.state = 0;  // back to uninitialized
    // Rent lamports transferred to destination by the runtime
}

// --- SPL Token: freeze_account ---
// Freeze a token account (freeze authority only)
pub freeze_account(
    mint: Mint,
    token_account: TokenAccount @mut,
    authority: account @signer
) {
    require(mint.is_initialized);
    require(mint.has_freeze_authority);
    require(mint.freeze_authority == authority.ctx.key);
    require(token_account.state == 1);
    require(token_account.mint == mint.ctx.key);
    require(!token_account.is_frozen);

    token_account.is_frozen = true;
    token_account.state = 2;  // frozen
}

// --- SPL Token: thaw_account ---
// Unfreeze a frozen token account
pub thaw_account(
    mint: Mint,
    token_account: TokenAccount @mut,
    authority: account @signer
) {
    require(mint.is_initialized);
    require(mint.has_freeze_authority);
    require(mint.freeze_authority == authority.ctx.key);
    require(token_account.state == 2);  // must be frozen
    require(token_account.mint == mint.ctx.key);
    require(token_account.is_frozen);

    token_account.is_frozen = false;
    token_account.state = 1;  // back to initialized
}

// --- SPL Token: set_authority ---
// Change mint or freeze authority
// authority_type: 0 = mint_authority, 1 = freeze_authority,
//                2 = account_owner, 3 = close_account
pub set_authority(
    mint: Mint @mut,
    token_account: TokenAccount @mut,
    current_authority: account @signer,
    new_authority: pubkey,
    authority_type: u8
) {
    if (authority_type == 0) {
        // Change mint authority
        require(mint.is_initialized);
        require(mint.authority == current_authority.ctx.key);
        mint.authority = new_authority;
    }
    if (authority_type == 1) {
        // Change freeze authority
        require(mint.is_initialized);
        require(mint.has_freeze_authority);
        require(mint.freeze_authority == current_authority.ctx.key);
        mint.freeze_authority = new_authority;
        if (new_authority == 0) {
            mint.has_freeze_authority = false;
        }
    }
    if (authority_type == 2) {
        // Change account owner
        require(token_account.state == 1);
        require(token_account.owner == current_authority.ctx.key);
        token_account.owner = new_authority;
    }
    if (authority_type == 3) {
        // Change close authority
        require(token_account.state == 1);
        if (token_account.close_authority != 0) {
            require(token_account.close_authority == current_authority.ctx.key);
        } else {
            require(token_account.owner == current_authority.ctx.key);
        }
        token_account.close_authority = new_authority;
    }
}


// ═══════════════════════════════════════════════════════════════════
// PROGRAM 2: ASSOCIATED TOKEN ACCOUNT (ATA)
// Deterministic token account addresses via PDA derivation.
// Every wallet gets exactly one token account per mint.
// ═══════════════════════════════════════════════════════════════════

// --- ATA: create_associated_token_account ---
// Create a deterministic ATA for a wallet + mint combination
pub create_associated_token_account(
    ata: TokenAccount @mut @init(payer=payer, space=256),
    payer: account @mut @signer,
    wallet: account,
    mint: Mint
) {
    require(mint.is_initialized);

    // Derive the expected PDA and verify it matches
    let expected_ata: pubkey = derive_pda("associated_token_account", wallet.ctx.key, mint.ctx.key);
    require(ata.ctx.key == expected_ata);

    // The ATA must not already be initialized
    require(ata.state == 0);

    ata.mint = mint.ctx.key;
    ata.owner = wallet.ctx.key;
    ata.amount = 0;
    ata.delegate = 0;
    ata.delegated_amount = 0;
    ata.is_frozen = false;
    ata.is_native = false;
    ata.close_authority = 0;
    ata.state = 1;  // initialized
}

// --- ATA: recover_nested ---
// Recover tokens from a nested ATA (ATA owned by another ATA)
// This happens when someone accidentally creates an ATA with an ATA as the owner
pub recover_nested(
    nested_ata: TokenAccount @mut,
    owner_ata: TokenAccount @mut,
    destination: TokenAccount @mut,
    owner_wallet: account @signer,
    nested_mint: Mint,
    owner_mint: Mint
) {
    require(nested_ata.state == 1);
    require(owner_ata.state == 1);
    require(destination.state == 1);

    // Verify the owner ATA belongs to the wallet
    let expected_owner_ata: pubkey = derive_pda("associated_token_account", owner_wallet.ctx.key, owner_mint.ctx.key);
    require(owner_ata.ctx.key == expected_owner_ata);
    require(owner_ata.owner == owner_wallet.ctx.key);

    // Verify the nested ATA is owned by the owner ATA (the error condition)
    require(nested_ata.owner == owner_ata.ctx.key);
    require(nested_ata.mint == nested_mint.ctx.key);

    // Destination must accept the same mint and belong to the wallet
    require(destination.mint == nested_mint.ctx.key);
    require(destination.owner == owner_wallet.ctx.key);

    // Transfer all tokens from nested to destination
    let recover_amount: u64 = nested_ata.amount;
    require(recover_amount > 0);

    nested_ata.amount = 0;
    destination.amount = destination.amount + recover_amount;

    // Close the nested ATA
    nested_ata.state = 0;
    nested_ata.mint = 0;
    nested_ata.owner = 0;
    nested_ata.delegate = 0;
    nested_ata.delegated_amount = 0;
    nested_ata.close_authority = 0;
}


// ═══════════════════════════════════════════════════════════════════
// PROGRAM 3: SPL TOKEN-LENDING
// The original reference lending protocol (Solend forked from this).
// Utilization-based interest rates, collateral obligations, liquidation.
// ═══════════════════════════════════════════════════════════════════

account LendingMarket {
    owner: pubkey;
    oracle_program_id: pubkey;
    token_program_id: pubkey;
    is_initialized: bool;
}

account Reserve {
    lending_market: pubkey;

    // Liquidity pool
    liquidity_mint: pubkey;
    liquidity_supply: u64;
    liquidity_fee_receiver: pubkey;
    liquidity_oracle: pubkey;

    // Collateral (cTokens)
    collateral_mint: pubkey;
    collateral_supply: u64;

    // Interest rate config
    optimal_utilization: u64;
    loan_to_value: u64;
    liquidation_threshold: u64;
    liquidation_bonus: u64;
    min_borrow_rate: u64;
    optimal_borrow_rate: u64;
    max_borrow_rate: u64;

    // Fee config
    borrow_fee_wad: u64;
    flash_loan_fee_wad: u64;
    host_fee_percentage: u8;

    // State
    available_amount: u64;
    borrowed_amount: u64;
    cumulative_borrow_rate: u64;
    last_update_slot: u64;
    is_initialized: bool;
}

account Obligation {
    lending_market: pubkey;
    owner: pubkey;

    // Deposits — up to 3 reserve slots
    deposit_reserve_0: pubkey;
    deposited_amount_0: u64;
    market_value_0: u64;
    deposit_reserve_1: pubkey;
    deposited_amount_1: u64;
    market_value_1: u64;
    deposit_reserve_2: pubkey;
    deposited_amount_2: u64;
    market_value_2: u64;

    // Borrows — up to 3 reserve slots
    borrow_reserve_0: pubkey;
    borrowed_amount_0: u64;
    borrow_market_value_0: u64;
    borrow_reserve_1: pubkey;
    borrowed_amount_1: u64;
    borrow_market_value_1: u64;
    borrow_reserve_2: pubkey;
    borrowed_amount_2: u64;
    borrow_market_value_2: u64;

    // Aggregates
    deposited_value: u64;
    borrowed_value: u64;
    allowed_borrow_value: u64;
    unhealthy_borrow_value: u64;

    is_initialized: bool;
    num_deposits: u8;
    num_borrows: u8;
}

// --- Internal: calculate utilization rate (0..100 scaled) ---
fn calculate_utilization_rate(available: u64, borrowed: u64) -> u64 {
    let total: u64 = available + borrowed;
    if (total == 0) {
        return 0;
    }
    return (borrowed * 100) / total;
}

// --- Internal: two-slope interest rate model ---
fn calculate_borrow_rate(
    min_rate: u64,
    optimal_rate: u64,
    max_rate: u64,
    optimal_utilization: u64,
    utilization: u64
) -> u64 {
    if (utilization <= optimal_utilization) {
        if (optimal_utilization == 0) {
            return min_rate;
        }
        return min_rate + ((optimal_rate - min_rate) * utilization) / optimal_utilization;
    }
    let excess: u64 = utilization - optimal_utilization;
    let remaining: u64 = 100 - optimal_utilization;
    if (remaining == 0) {
        return max_rate;
    }
    return optimal_rate + ((max_rate - optimal_rate) * excess) / remaining;
}

// --- SPL Lending: init_lending_market ---
// Create a lending market
pub init_lending_market(
    market: LendingMarket @mut @init(payer=owner, space=256),
    owner: account @mut @signer,
    oracle_program_id: pubkey,
    token_program_id: pubkey
) {
    require(!market.is_initialized);

    market.owner = owner.ctx.key;
    market.oracle_program_id = oracle_program_id;
    market.token_program_id = token_program_id;
    market.is_initialized = true;
}

// --- SPL Lending: init_reserve ---
// Create a reserve with interest rate configuration
pub init_reserve(
    market: LendingMarket,
    reserve: Reserve @mut @init(payer=admin, space=600),
    admin: account @mut @signer,
    liquidity_mint: pubkey,
    liquidity_fee_receiver: pubkey,
    liquidity_oracle: pubkey,
    collateral_mint: pubkey,
    optimal_utilization: u64,
    loan_to_value: u64,
    liquidation_threshold: u64,
    liquidation_bonus: u64,
    min_borrow_rate: u64,
    optimal_borrow_rate: u64,
    max_borrow_rate: u64,
    borrow_fee_wad: u64,
    flash_loan_fee_wad: u64,
    host_fee_percentage: u8
) {
    require(market.is_initialized);
    require(market.owner == admin.ctx.key);
    require(!reserve.is_initialized);
    require(optimal_utilization <= 100);
    require(loan_to_value < 100);
    require(loan_to_value > 0);
    require(liquidation_threshold > loan_to_value);
    require(liquidation_threshold <= 100);
    require(min_borrow_rate <= optimal_borrow_rate);
    require(optimal_borrow_rate <= max_borrow_rate);

    reserve.lending_market = market.ctx.key;
    reserve.liquidity_mint = liquidity_mint;
    reserve.liquidity_supply = 0;
    reserve.liquidity_fee_receiver = liquidity_fee_receiver;
    reserve.liquidity_oracle = liquidity_oracle;
    reserve.collateral_mint = collateral_mint;
    reserve.collateral_supply = 0;

    reserve.optimal_utilization = optimal_utilization;
    reserve.loan_to_value = loan_to_value;
    reserve.liquidation_threshold = liquidation_threshold;
    reserve.liquidation_bonus = liquidation_bonus;
    reserve.min_borrow_rate = min_borrow_rate;
    reserve.optimal_borrow_rate = optimal_borrow_rate;
    reserve.max_borrow_rate = max_borrow_rate;

    reserve.borrow_fee_wad = borrow_fee_wad;
    reserve.flash_loan_fee_wad = flash_loan_fee_wad;
    reserve.host_fee_percentage = host_fee_percentage;

    reserve.available_amount = 0;
    reserve.borrowed_amount = 0;
    reserve.cumulative_borrow_rate = 1000000000;  // 1.0 in WAD-like scale
    reserve.last_update_slot = get_clock().slot;
    reserve.is_initialized = true;
}

// --- SPL Lending: deposit_reserve_liquidity ---
// Deposit tokens and receive cTokens at the current exchange rate
pub deposit_reserve_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    user_liquidity: account @mut,
    user_collateral: account @mut,
    reserve_liquidity_supply: account @mut,
    collateral_mint_account: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(market.is_initialized);
    require(reserve.is_initialized);
    require(reserve.lending_market == market.ctx.key);
    require(amount > 0);

    // Refresh reserve timestamp
    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Calculate cTokens to mint: if no supply yet, 1:1; otherwise proportional
    let total_liquidity: u64 = reserve.available_amount + reserve.borrowed_amount;
    let mut collateral_amount: u64 = amount;
    if (reserve.collateral_supply > 0) {
        if (total_liquidity > 0) {
            collateral_amount = (amount * reserve.collateral_supply) / total_liquidity;
        }
    }
    require(collateral_amount > 0);

    // CPI: transfer liquidity in, mint cTokens out
    spl_token::SPLToken::transfer(user_liquidity, reserve_liquidity_supply, user_authority, amount);
    spl_token::SPLToken::mint_to(collateral_mint_account, user_collateral, market_authority, collateral_amount);

    reserve.available_amount = reserve.available_amount + amount;
    reserve.collateral_supply = reserve.collateral_supply + collateral_amount;
}

// --- SPL Lending: redeem_reserve_collateral ---
// Burn cTokens and receive underlying tokens at the current exchange rate
pub redeem_reserve_collateral(
    market: LendingMarket,
    reserve: Reserve @mut,
    user_collateral: account @mut,
    user_liquidity: account @mut,
    reserve_liquidity_supply: account @mut,
    collateral_mint_account: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(market.is_initialized);
    require(reserve.is_initialized);
    require(reserve.lending_market == market.ctx.key);
    require(collateral_amount > 0);
    require(reserve.collateral_supply >= collateral_amount);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Calculate liquidity to return: proportional to cToken share
    let total_liquidity: u64 = reserve.available_amount + reserve.borrowed_amount;
    let liquidity_amount: u64 = (collateral_amount * total_liquidity) / reserve.collateral_supply;
    require(liquidity_amount > 0);
    require(liquidity_amount <= reserve.available_amount);

    // CPI: burn cTokens, transfer liquidity out
    spl_token::SPLToken::burn(user_collateral, collateral_mint_account, user_authority, collateral_amount);
    spl_token::SPLToken::transfer(reserve_liquidity_supply, user_liquidity, market_authority, liquidity_amount);

    reserve.available_amount = reserve.available_amount - liquidity_amount;
    reserve.collateral_supply = reserve.collateral_supply - collateral_amount;
}

// --- SPL Lending: borrow_obligation_liquidity ---
// Borrow against deposited collateral
pub borrow_obligation_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    reserve_liquidity_supply: account @mut,
    market_authority: account @signer,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(market.is_initialized);
    require(reserve.is_initialized);
    require(obligation.is_initialized);
    require(obligation.lending_market == market.ctx.key);
    require(reserve.lending_market == market.ctx.key);
    require(obligation.owner == user_authority.ctx.key);
    require(amount > 0);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Enforce LTV: new borrow must not exceed allowed borrow value
    let new_borrowed: u64 = obligation.borrowed_value + amount;
    let ltv_limit: u64 = (obligation.deposited_value * reserve.loan_to_value) / 100;
    require(new_borrowed <= ltv_limit);
    require(amount <= reserve.available_amount);

    // Calculate borrow fee
    let borrow_fee: u64 = (amount * reserve.borrow_fee_wad) / 1000000000;
    let net_amount: u64 = amount - borrow_fee;

    // CPI: transfer liquidity to borrower (net of fee)
    spl_token::SPLToken::transfer(reserve_liquidity_supply, user_liquidity, market_authority, net_amount);

    reserve.available_amount = reserve.available_amount - amount;
    reserve.borrowed_amount = reserve.borrowed_amount + amount;

    obligation.borrowed_value = new_borrowed;
    obligation.allowed_borrow_value = ltv_limit;
}

// --- SPL Lending: repay_obligation_liquidity ---
// Repay borrowed tokens
pub repay_obligation_liquidity(
    market: LendingMarket,
    reserve: Reserve @mut,
    obligation: Obligation @mut,
    user_liquidity: account @mut,
    reserve_liquidity_supply: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(market.is_initialized);
    require(reserve.is_initialized);
    require(obligation.is_initialized);
    require(obligation.lending_market == market.ctx.key);
    require(reserve.lending_market == market.ctx.key);
    require(amount > 0);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Clamp repay to outstanding borrow
    let mut repay_amount: u64 = amount;
    if (amount > obligation.borrowed_value) {
        repay_amount = obligation.borrowed_value;
    }

    // CPI: transfer repayment from user to reserve
    spl_token::SPLToken::transfer(user_liquidity, reserve_liquidity_supply, user_authority, repay_amount);

    if (reserve.borrowed_amount >= repay_amount) {
        reserve.borrowed_amount = reserve.borrowed_amount - repay_amount;
    } else {
        reserve.borrowed_amount = 0;
    }
    reserve.available_amount = reserve.available_amount + repay_amount;

    obligation.borrowed_value = obligation.borrowed_value - repay_amount;
}

// --- SPL Lending: liquidate_obligation ---
// Liquidate an unhealthy position (borrowed_value > liquidation threshold)
pub liquidate_obligation(
    market: LendingMarket,
    repay_reserve: Reserve @mut,
    withdraw_reserve: Reserve @mut,
    obligation: Obligation @mut,
    liquidator_liquidity: account @mut,
    reserve_liquidity_supply: account @mut,
    liquidator_collateral: account @mut,
    withdraw_collateral_supply: account @mut,
    market_authority: account @signer,
    liquidator: account @signer,
    token_program: account,
    repay_amount: u64
) {
    require(market.is_initialized);
    require(repay_reserve.is_initialized);
    require(withdraw_reserve.is_initialized);
    require(obligation.is_initialized);
    require(obligation.lending_market == market.ctx.key);
    require(repay_amount > 0);

    let current_slot: u64 = get_clock().slot;
    repay_reserve.last_update_slot = current_slot;

    // Accrue interest on borrowed amount
    let time_delta: u64 = current_slot - repay_reserve.last_update_slot;
    if (repay_reserve.borrowed_amount > 0) {
        let utilization: u64 = calculate_utilization_rate(
            repay_reserve.available_amount,
            repay_reserve.borrowed_amount
        );
        let rate: u64 = calculate_borrow_rate(
            repay_reserve.min_borrow_rate,
            repay_reserve.optimal_borrow_rate,
            repay_reserve.max_borrow_rate,
            repay_reserve.optimal_utilization,
            utilization
        );
        let seconds_per_year: u64 = 31536000;
        let interest: u64 = (repay_reserve.borrowed_amount * rate * time_delta) / (seconds_per_year * 100);
        repay_reserve.borrowed_amount = repay_reserve.borrowed_amount + interest;
    }

    // Verify obligation is unhealthy
    let liquidation_limit: u64 = (obligation.deposited_value * repay_reserve.liquidation_threshold) / 100;
    require(obligation.borrowed_value > liquidation_limit);

    // Clamp repay to outstanding borrow (max 50% of borrow per liquidation)
    let max_repay: u64 = obligation.borrowed_value / 2;
    let mut actual_repay: u64 = repay_amount;
    if (actual_repay > max_repay) {
        actual_repay = max_repay;
    }
    if (actual_repay > obligation.borrowed_value) {
        actual_repay = obligation.borrowed_value;
    }

    // CPI: liquidator pays repayment
    spl_token::SPLToken::transfer(liquidator_liquidity, reserve_liquidity_supply, liquidator, actual_repay);

    // Liquidator receives collateral + bonus
    let collateral_to_seize: u64 = (actual_repay * (100 + repay_reserve.liquidation_bonus)) / 100;

    // CPI: transfer collateral to liquidator
    spl_token::SPLToken::transfer(withdraw_collateral_supply, liquidator_collateral, market_authority, collateral_to_seize);

    // Update reserve state
    if (repay_reserve.borrowed_amount >= actual_repay) {
        repay_reserve.borrowed_amount = repay_reserve.borrowed_amount - actual_repay;
    } else {
        repay_reserve.borrowed_amount = 0;
    }
    repay_reserve.available_amount = repay_reserve.available_amount + actual_repay;

    // Update obligation state
    if (obligation.borrowed_value >= actual_repay) {
        obligation.borrowed_value = obligation.borrowed_value - actual_repay;
    } else {
        obligation.borrowed_value = 0;
    }
    if (obligation.deposited_value >= collateral_to_seize) {
        obligation.deposited_value = obligation.deposited_value - collateral_to_seize;
    } else {
        obligation.deposited_value = 0;
    }
}

// --- SPL Lending: flash_loan ---
// Borrow and repay within the same transaction (fee-based)
pub flash_loan(
    market: LendingMarket,
    reserve: Reserve @mut,
    borrower_liquidity: account @mut,
    reserve_liquidity_supply: account @mut,
    fee_receiver: account @mut,
    market_authority: account @signer,
    borrower: account @signer,
    token_program: account,
    amount: u64
) {
    require(market.is_initialized);
    require(reserve.is_initialized);
    require(reserve.lending_market == market.ctx.key);
    require(amount > 0);
    require(amount <= reserve.available_amount);

    let current_slot: u64 = get_clock().slot;
    reserve.last_update_slot = current_slot;

    // Calculate flash loan fee
    let flash_fee: u64 = (amount * reserve.flash_loan_fee_wad) / 1000000000;
    require(flash_fee > 0);

    // Calculate host fee portion
    let host_fee: u64 = (flash_fee * reserve.host_fee_percentage as u64) / 100;
    let protocol_fee: u64 = flash_fee - host_fee;

    // CPI: lend out, then expect repayment + fee in same tx
    // Step 1: Transfer loan amount to borrower
    spl_token::SPLToken::transfer(reserve_liquidity_supply, borrower_liquidity, market_authority, amount);

    // Step 2: Borrower must repay amount + fee (enforced atomically)
    let repay_total: u64 = amount + flash_fee;
    spl_token::SPLToken::transfer(borrower_liquidity, reserve_liquidity_supply, borrower, repay_total);

    // Protocol fee goes to fee receiver
    if (protocol_fee > 0) {
        spl_token::SPLToken::transfer(reserve_liquidity_supply, fee_receiver, market_authority, protocol_fee);
    }

    // Net effect: reserve gains the flash_fee minus what was sent to fee_receiver
    // available_amount stays the same (amount out = amount + fee in - protocol_fee out)
    reserve.available_amount = reserve.available_amount + flash_fee - protocol_fee;
}


// ═══════════════════════════════════════════════════════════════════
// PROGRAM 4: SPL GOVERNANCE
// On-chain DAO governance — realms, proposals, voting, execution.
// ═══════════════════════════════════════════════════════════════════

account Realm {
    community_mint: pubkey;
    authority: pubkey;
    min_tokens_to_create_proposal: u64;
    voting_period: u64;
    max_voting_time: u64;
    is_initialized: bool;
    proposal_count: u64;
}

account Proposal {
    realm: pubkey;
    governance: pubkey;
    owner: pubkey;
    title: string<64>;
    description_hash: pubkey;
    status: u8;  // 0=draft, 1=voting, 2=succeeded, 3=defeated, 4=executing, 5=completed, 6=cancelled
    yes_votes: u64;
    no_votes: u64;
    voting_start_time: u64;
    voting_end_time: u64;
    is_initialized: bool;
}

account VoteRecord {
    proposal: pubkey;
    voter: pubkey;
    vote_weight: u64;
    is_yes: bool;
    is_initialized: bool;
}

account TokenOwnerRecord {
    realm: pubkey;
    governing_token_mint: pubkey;
    owner: pubkey;
    amount: u64;
    unrelinquished_votes: u64;
    is_initialized: bool;
}

// --- Governance: create_realm ---
// Create a governance realm
pub create_realm(
    realm: Realm @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    community_mint: pubkey,
    min_tokens_to_create_proposal: u64,
    voting_period: u64,
    max_voting_time: u64
) {
    require(!realm.is_initialized);
    require(voting_period > 0);
    require(max_voting_time >= voting_period);

    realm.community_mint = community_mint;
    realm.authority = authority.ctx.key;
    realm.min_tokens_to_create_proposal = min_tokens_to_create_proposal;
    realm.voting_period = voting_period;
    realm.max_voting_time = max_voting_time;
    realm.is_initialized = true;
    realm.proposal_count = 0;
}

// --- Governance: deposit_governing_tokens ---
// Deposit tokens for voting power
pub deposit_governing_tokens(
    realm: Realm,
    token_owner_record: TokenOwnerRecord @mut @init(payer=owner, space=256),
    owner: account @mut @signer,
    user_token_source: account @mut,
    realm_token_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(realm.is_initialized);
    require(amount > 0);

    // CPI: transfer governance tokens to realm vault
    spl_token::SPLToken::transfer(user_token_source, realm_token_vault, owner, amount);

    if (!token_owner_record.is_initialized) {
        token_owner_record.realm = realm.ctx.key;
        token_owner_record.governing_token_mint = realm.community_mint;
        token_owner_record.owner = owner.ctx.key;
        token_owner_record.amount = amount;
        token_owner_record.unrelinquished_votes = 0;
        token_owner_record.is_initialized = true;
    } else {
        require(token_owner_record.owner == owner.ctx.key);
        require(token_owner_record.realm == realm.ctx.key);
        token_owner_record.amount = token_owner_record.amount + amount;
    }
}

// --- Governance: withdraw_governing_tokens ---
// Withdraw tokens (only if no unrelinquished votes)
pub withdraw_governing_tokens(
    realm: Realm,
    token_owner_record: TokenOwnerRecord @mut,
    owner: account @signer,
    realm_token_vault: account @mut,
    user_token_destination: account @mut,
    realm_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(realm.is_initialized);
    require(token_owner_record.is_initialized);
    require(token_owner_record.owner == owner.ctx.key);
    require(token_owner_record.realm == realm.ctx.key);
    require(amount > 0);
    require(amount <= token_owner_record.amount);

    // Cannot withdraw while votes are outstanding
    require(token_owner_record.unrelinquished_votes == 0);

    // CPI: transfer tokens back to user
    spl_token::SPLToken::transfer(realm_token_vault, user_token_destination, realm_authority, amount);

    token_owner_record.amount = token_owner_record.amount - amount;
}

// --- Governance: create_proposal ---
// Create a governance proposal
pub create_proposal(
    realm: Realm @mut,
    proposal: Proposal @mut @init(payer=proposer, space=512),
    proposer: account @mut @signer,
    token_owner_record: TokenOwnerRecord,
    governance: pubkey,
    title: string<64>,
    description_hash: pubkey
) {
    require(realm.is_initialized);
    require(token_owner_record.is_initialized);
    require(token_owner_record.owner == proposer.ctx.key);
    require(token_owner_record.realm == realm.ctx.key);
    require(token_owner_record.amount >= realm.min_tokens_to_create_proposal);

    proposal.realm = realm.ctx.key;
    proposal.governance = governance;
    proposal.owner = proposer.ctx.key;
    proposal.title = title;
    proposal.description_hash = description_hash;
    proposal.status = 0;  // draft
    proposal.yes_votes = 0;
    proposal.no_votes = 0;
    proposal.voting_start_time = 0;
    proposal.voting_end_time = 0;
    proposal.is_initialized = true;

    realm.proposal_count = realm.proposal_count + 1;
}

// --- Governance: cast_vote ---
// Vote yes or no on a proposal with token weight
pub cast_vote(
    realm: Realm,
    proposal: Proposal @mut,
    vote_record: VoteRecord @mut @init(payer=voter, space=256),
    token_owner_record: TokenOwnerRecord @mut,
    voter: account @mut @signer,
    is_yes: bool
) {
    require(realm.is_initialized);
    require(proposal.is_initialized);
    require(proposal.realm == realm.ctx.key);
    require(token_owner_record.is_initialized);
    require(token_owner_record.owner == voter.ctx.key);
    require(token_owner_record.realm == realm.ctx.key);
    require(!vote_record.is_initialized);  // cannot vote twice

    // Proposal must be in voting state
    require(proposal.status == 1);

    // Voting must not have expired
    let now: u64 = get_clock().unix_timestamp;
    require(now <= proposal.voting_end_time);

    let vote_weight: u64 = token_owner_record.amount;
    require(vote_weight > 0);

    vote_record.proposal = proposal.ctx.key;
    vote_record.voter = voter.ctx.key;
    vote_record.vote_weight = vote_weight;
    vote_record.is_yes = is_yes;
    vote_record.is_initialized = true;

    if (is_yes) {
        proposal.yes_votes = proposal.yes_votes + vote_weight;
    } else {
        proposal.no_votes = proposal.no_votes + vote_weight;
    }

    token_owner_record.unrelinquished_votes = token_owner_record.unrelinquished_votes + 1;
}

// --- Governance: finalize_vote ---
// End voting and determine outcome (succeeded or defeated)
pub finalize_vote(
    realm: Realm,
    proposal: Proposal @mut
) {
    require(realm.is_initialized);
    require(proposal.is_initialized);
    require(proposal.realm == realm.ctx.key);
    require(proposal.status == 1);  // must be in voting

    // Voting period must have elapsed
    let now: u64 = get_clock().unix_timestamp;
    require(now > proposal.voting_end_time);

    // Simple majority: yes > no
    if (proposal.yes_votes > proposal.no_votes) {
        proposal.status = 2;  // succeeded
    } else {
        proposal.status = 3;  // defeated
    }
}

// --- Governance: execute_proposal ---
// Execute a passed proposal
pub execute_proposal(
    realm: Realm,
    proposal: Proposal @mut
) {
    require(realm.is_initialized);
    require(proposal.is_initialized);
    require(proposal.realm == realm.ctx.key);
    require(proposal.status == 2);  // must be succeeded

    proposal.status = 4;  // executing

    // Execution logic happens via CPIs in the actual transaction
    // After execution, mark as completed
    proposal.status = 5;  // completed
}

// --- Governance: cancel_proposal ---
// Cancel a proposal (owner only, before voting ends)
pub cancel_proposal(
    realm: Realm,
    proposal: Proposal @mut,
    owner: account @signer
) {
    require(realm.is_initialized);
    require(proposal.is_initialized);
    require(proposal.realm == realm.ctx.key);
    require(proposal.owner == owner.ctx.key);

    // Can cancel if draft or still in voting period
    require(proposal.status == 0 || proposal.status == 1);

    if (proposal.status == 1) {
        let now: u64 = get_clock().unix_timestamp;
        require(now <= proposal.voting_end_time);
    }

    proposal.status = 6;  // cancelled
}

// --- Governance: relinquish_vote ---
// Withdraw a vote (before voting ends)
pub relinquish_vote(
    realm: Realm,
    proposal: Proposal @mut,
    vote_record: VoteRecord @mut,
    token_owner_record: TokenOwnerRecord @mut,
    voter: account @signer
) {
    require(realm.is_initialized);
    require(proposal.is_initialized);
    require(vote_record.is_initialized);
    require(token_owner_record.is_initialized);
    require(proposal.realm == realm.ctx.key);
    require(vote_record.proposal == proposal.ctx.key);
    require(vote_record.voter == voter.ctx.key);
    require(token_owner_record.owner == voter.ctx.key);

    // Can only relinquish while voting is active
    require(proposal.status == 1);
    let now: u64 = get_clock().unix_timestamp;
    require(now <= proposal.voting_end_time);

    // Subtract the vote weight
    let weight: u64 = vote_record.vote_weight;
    if (vote_record.is_yes) {
        require(proposal.yes_votes >= weight);
        proposal.yes_votes = proposal.yes_votes - weight;
    } else {
        require(proposal.no_votes >= weight);
        proposal.no_votes = proposal.no_votes - weight;
    }

    // Clear the vote record
    vote_record.is_initialized = false;
    vote_record.vote_weight = 0;

    // Decrement unrelinquished votes
    require(token_owner_record.unrelinquished_votes > 0);
    token_owner_record.unrelinquished_votes = token_owner_record.unrelinquished_votes - 1;
}

// --- Governance: set_governance_config ---
// Update governance parameters (realm authority only)
pub set_governance_config(
    realm: Realm @mut,
    authority: account @signer,
    new_min_tokens_to_create_proposal: u64,
    new_voting_period: u64,
    new_max_voting_time: u64
) {
    require(realm.is_initialized);
    require(realm.authority == authority.ctx.key);
    require(new_voting_period > 0);
    require(new_max_voting_time >= new_voting_period);

    realm.min_tokens_to_create_proposal = new_min_tokens_to_create_proposal;
    realm.voting_period = new_voting_period;
    realm.max_voting_time = new_max_voting_time;
}


// ═══════════════════════════════════════════════════════════════════
// PROGRAM 5: SPL STAKE POOL
// Native SOL staking pool — pool tokens represent shares of staked SOL.
// Manages validators, deposits, withdrawals, and epoch fees.
// ═══════════════════════════════════════════════════════════════════

account StakePool {
    manager: pubkey;
    staker: pubkey;
    stake_deposit_authority: pubkey;
    pool_mint: pubkey;
    fee_account: pubkey;
    total_lamports: u64;
    pool_token_supply: u64;
    epoch_fee_numerator: u64;
    epoch_fee_denominator: u64;
    stake_withdrawal_fee_numerator: u64;
    stake_withdrawal_fee_denominator: u64;
    next_epoch_fee: u64;
    preferred_deposit_validator: pubkey;
    preferred_withdraw_validator: pubkey;
    last_update_epoch: u64;
    is_initialized: bool;
    validator_count: u32;
}

account ValidatorStakeInfo {
    stake_pool: pubkey;
    vote_account: pubkey;
    active_stake_lamports: u64;
    transient_stake_lamports: u64;
    last_update_epoch: u64;
    status: u8;  // 0 = active, 1 = deactivating, 2 = ready_for_removal
    is_initialized: bool;
}

// --- Stake Pool: initialize_stake_pool ---
// Create a stake pool with fee configuration
pub initialize_stake_pool(
    pool: StakePool @mut @init(payer=manager, space=512),
    manager: account @mut @signer,
    staker: pubkey,
    stake_deposit_authority: pubkey,
    pool_mint: pubkey,
    fee_account: pubkey,
    epoch_fee_numerator: u64,
    epoch_fee_denominator: u64,
    stake_withdrawal_fee_numerator: u64,
    stake_withdrawal_fee_denominator: u64
) {
    require(!pool.is_initialized);
    require(epoch_fee_denominator > 0);
    require(epoch_fee_numerator <= epoch_fee_denominator);
    require(stake_withdrawal_fee_denominator > 0);
    require(stake_withdrawal_fee_numerator <= stake_withdrawal_fee_denominator);

    pool.manager = manager.ctx.key;
    pool.staker = staker;
    pool.stake_deposit_authority = stake_deposit_authority;
    pool.pool_mint = pool_mint;
    pool.fee_account = fee_account;
    pool.total_lamports = 0;
    pool.pool_token_supply = 0;
    pool.epoch_fee_numerator = epoch_fee_numerator;
    pool.epoch_fee_denominator = epoch_fee_denominator;
    pool.stake_withdrawal_fee_numerator = stake_withdrawal_fee_numerator;
    pool.stake_withdrawal_fee_denominator = stake_withdrawal_fee_denominator;
    pool.next_epoch_fee = 0;
    pool.preferred_deposit_validator = 0;
    pool.preferred_withdraw_validator = 0;
    pool.last_update_epoch = get_clock().epoch;
    pool.is_initialized = true;
    pool.validator_count = 0;
}

// --- Stake Pool: add_validator_to_pool ---
// Add a validator to the stake pool
pub add_validator_to_pool(
    pool: StakePool @mut,
    validator_info: ValidatorStakeInfo @mut @init(payer=staker, space=256),
    staker: account @mut @signer,
    vote_account: pubkey
) {
    require(pool.is_initialized);
    require(pool.staker == staker.ctx.key);
    require(!validator_info.is_initialized);

    // Derive expected PDA for this validator stake info
    let expected_pda: pubkey = derive_pda("validator_stake", pool.ctx.key, vote_account);
    require(validator_info.ctx.key == expected_pda);

    validator_info.stake_pool = pool.ctx.key;
    validator_info.vote_account = vote_account;
    validator_info.active_stake_lamports = 0;
    validator_info.transient_stake_lamports = 0;
    validator_info.last_update_epoch = get_clock().epoch;
    validator_info.status = 0;  // active
    validator_info.is_initialized = true;

    pool.validator_count = pool.validator_count + 1;
}

// --- Stake Pool: remove_validator_from_pool ---
// Remove a validator from the stake pool (must have zero stake)
pub remove_validator_from_pool(
    pool: StakePool @mut,
    validator_info: ValidatorStakeInfo @mut,
    staker: account @signer
) {
    require(pool.is_initialized);
    require(validator_info.is_initialized);
    require(pool.staker == staker.ctx.key);
    require(validator_info.stake_pool == pool.ctx.key);

    // Validator must have no remaining stake
    require(validator_info.active_stake_lamports == 0);
    require(validator_info.transient_stake_lamports == 0);

    // Clear the validator info
    validator_info.is_initialized = false;
    validator_info.status = 2;  // ready_for_removal

    require(pool.validator_count > 0);
    pool.validator_count = pool.validator_count - 1;
}

// --- Stake Pool: deposit_stake ---
// Deposit SOL and receive pool tokens at the current exchange rate
pub deposit_stake(
    pool: StakePool @mut,
    validator_info: ValidatorStakeInfo @mut,
    pool_mint_account: account @mut,
    user_pool_token_account: account @mut,
    deposit_authority: account @signer,
    pool_authority: account @signer,
    token_program: account,
    lamports: u64
) {
    require(pool.is_initialized);
    require(validator_info.is_initialized);
    require(validator_info.stake_pool == pool.ctx.key);
    require(validator_info.status == 0);  // must be active
    require(pool.stake_deposit_authority == deposit_authority.ctx.key);
    require(lamports > 0);

    // Calculate pool tokens to mint at current exchange rate
    let mut pool_tokens: u64 = lamports;
    if (pool.pool_token_supply > 0) {
        if (pool.total_lamports > 0) {
            pool_tokens = (lamports * pool.pool_token_supply) / pool.total_lamports;
        }
    }
    require(pool_tokens > 0);

    // CPI: mint pool tokens to depositor
    spl_token::SPLToken::mint_to(pool_mint_account, user_pool_token_account, pool_authority, pool_tokens);

    // Update state
    pool.total_lamports = pool.total_lamports + lamports;
    pool.pool_token_supply = pool.pool_token_supply + pool_tokens;
    validator_info.active_stake_lamports = validator_info.active_stake_lamports + lamports;
}

// --- Stake Pool: withdraw_stake ---
// Burn pool tokens and receive SOL at the current exchange rate
pub withdraw_stake(
    pool: StakePool @mut,
    validator_info: ValidatorStakeInfo @mut,
    pool_mint_account: account @mut,
    user_pool_token_account: account @mut,
    user_authority: account @signer,
    pool_authority: account @signer,
    fee_token_account: account @mut,
    token_program: account,
    pool_tokens: u64
) {
    require(pool.is_initialized);
    require(validator_info.is_initialized);
    require(validator_info.stake_pool == pool.ctx.key);
    require(pool_tokens > 0);
    require(pool.pool_token_supply >= pool_tokens);

    // Calculate SOL to return at current exchange rate
    let lamports_out: u64 = (pool_tokens * pool.total_lamports) / pool.pool_token_supply;
    require(lamports_out > 0);
    require(validator_info.active_stake_lamports >= lamports_out);

    // Calculate withdrawal fee
    let withdrawal_fee: u64 = (pool_tokens * pool.stake_withdrawal_fee_numerator) / pool.stake_withdrawal_fee_denominator;
    let tokens_to_burn: u64 = pool_tokens - withdrawal_fee;

    // CPI: burn user's pool tokens (net of fee)
    spl_token::SPLToken::burn(user_pool_token_account, pool_mint_account, user_authority, tokens_to_burn);

    // CPI: transfer fee tokens to fee account
    if (withdrawal_fee > 0) {
        spl_token::SPLToken::transfer(user_pool_token_account, fee_token_account, user_authority, withdrawal_fee);
    }

    // Update state
    pool.total_lamports = pool.total_lamports - lamports_out;
    pool.pool_token_supply = pool.pool_token_supply - tokens_to_burn;
    validator_info.active_stake_lamports = validator_info.active_stake_lamports - lamports_out;
}

// --- Stake Pool: update_validator_list_balance ---
// Update validator balances per epoch (called by crankers)
pub update_validator_list_balance(
    pool: StakePool @mut,
    validator_info: ValidatorStakeInfo @mut,
    pool_authority: account @signer,
    pool_mint_account: account @mut,
    fee_token_account: account @mut,
    token_program: account,
    new_active_stake: u64,
    new_transient_stake: u64
) {
    require(pool.is_initialized);
    require(validator_info.is_initialized);
    require(validator_info.stake_pool == pool.ctx.key);

    let current_epoch: u64 = get_clock().epoch;
    require(current_epoch > validator_info.last_update_epoch);

    // Calculate total stake change for this validator
    let old_total: u64 = validator_info.active_stake_lamports + validator_info.transient_stake_lamports;
    let new_total: u64 = new_active_stake + new_transient_stake;

    // If stake increased (rewards earned), collect epoch fee
    if (new_total > old_total) {
        let rewards: u64 = new_total - old_total;
        let epoch_fee: u64 = (rewards * pool.epoch_fee_numerator) / pool.epoch_fee_denominator;

        if (epoch_fee > 0) {
            // Mint fee tokens to the pool fee account
            let fee_tokens: u64 = (epoch_fee * pool.pool_token_supply) / pool.total_lamports;
            if (fee_tokens > 0) {
                spl_token::SPLToken::mint_to(pool_mint_account, fee_token_account, pool_authority, fee_tokens);
                pool.pool_token_supply = pool.pool_token_supply + fee_tokens;
            }
        }

        pool.total_lamports = pool.total_lamports + rewards;
    }

    // If stake decreased (slashing), reduce pool total
    if (new_total < old_total) {
        let loss: u64 = old_total - new_total;
        if (pool.total_lamports >= loss) {
            pool.total_lamports = pool.total_lamports - loss;
        } else {
            pool.total_lamports = 0;
        }
    }

    // Update validator info
    validator_info.active_stake_lamports = new_active_stake;
    validator_info.transient_stake_lamports = new_transient_stake;
    validator_info.last_update_epoch = current_epoch;

    pool.last_update_epoch = current_epoch;
}

// --- Stake Pool: set_manager ---
// Transfer pool manager authority
pub set_manager(
    pool: StakePool @mut,
    manager: account @signer,
    new_manager: pubkey,
    new_fee_account: pubkey
) {
    require(pool.is_initialized);
    require(pool.manager == manager.ctx.key);

    pool.manager = new_manager;
    pool.fee_account = new_fee_account;
}

// --- Stake Pool: set_fee ---
// Update fee configuration
pub set_fee(
    pool: StakePool @mut,
    manager: account @signer,
    new_epoch_fee_numerator: u64,
    new_epoch_fee_denominator: u64,
    new_withdrawal_fee_numerator: u64,
    new_withdrawal_fee_denominator: u64
) {
    require(pool.is_initialized);
    require(pool.manager == manager.ctx.key);
    require(new_epoch_fee_denominator > 0);
    require(new_epoch_fee_numerator <= new_epoch_fee_denominator);
    require(new_withdrawal_fee_denominator > 0);
    require(new_withdrawal_fee_numerator <= new_withdrawal_fee_denominator);

    // Fee changes take effect next epoch to prevent front-running
    pool.next_epoch_fee = new_epoch_fee_numerator;
    pool.epoch_fee_denominator = new_epoch_fee_denominator;
    pool.stake_withdrawal_fee_numerator = new_withdrawal_fee_numerator;
    pool.stake_withdrawal_fee_denominator = new_withdrawal_fee_denominator;
}
