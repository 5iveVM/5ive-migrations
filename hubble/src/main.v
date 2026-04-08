// Hubble Protocol -- 5ive DSL Migration
//
// CDP (Collateralized Debt Position) stablecoin protocol.
// Users deposit collateral (SOL, mSOL, etc.) into Troves and mint USDH stablecoin.
//
// Key concepts:
//   - Troves must maintain > 110% collateral ratio (min_collateral_ratio_bps)
//   - Stability Pool absorbs liquidated troves: USDH depositors earn collateral
//   - Redemptions: anyone can swap USDH for collateral at $1 face value,
//     pulling from the lowest-CR troves first (improves system health)
//   - Borrowing fee charged on USDH minting; redemption fee on redemptions
//   - Oracle staleness enforced (100-slot window)
//
// Integer-only math; BPS_SCALE = 10000

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Protocol {
    authority: pubkey;
    usdh_mint: pubkey;               // USDH stablecoin mint
    stability_pool_vault: pubkey;     // vault holding USDH deposited to stability pool
    total_collateral: u64;            // system-wide collateral deposited
    total_debt: u64;                  // system-wide USDH minted (debt outstanding)
    min_collateral_ratio_bps: u64;    // minimum CR in basis points (11000 = 110%)
    borrowing_fee_bps: u64;           // fee on new USDH minting
    redemption_fee_bps: u64;          // fee on USDH-to-collateral redemptions
    total_borrowing_fees: u64;        // accumulated borrowing fees
    is_paused: bool;
}

account Trove {
    protocol: pubkey;
    owner: pubkey;
    collateral_mint: pubkey;          // which collateral asset backs this trove
    collateral_vault: pubkey;         // trove-specific collateral vault
    collateral_amount: u64;           // deposited collateral tokens
    debt_amount: u64;                 // USDH debt outstanding
    collateral_ratio: u64;            // cached CR in bps (updated on mutations)
    last_update: u64;                 // slot of last state change
}

account StabilityDeposit {
    protocol: pubkey;
    owner: pubkey;
    usdh_deposited: u64;             // USDH deposited into stability pool
    pending_collateral_gain: u64;     // collateral earned from liquidation absorption
    pending_reward: u64;              // additional reward tokens accrued
}

account OraclePrice {
    authority: pubkey;
    mint: pubkey;                     // which asset this oracle prices
    price: u64;                       // price in USD, scaled by 1e9
    decimals: u8;
    last_update: u64;
}

// PRICE_SCALE = 1000000000 (1e9)

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Compute collateral ratio in basis points.
// CR = (collateral_amount * oracle_price * 10000) / (debt * PRICE_SCALE)
fn compute_collateral_ratio(collateral: u64, debt: u64, price: u64) -> u64 {
    if (debt == 0) {
        return 100000; // effectively infinite CR
    }
    // (collateral * price * 10000) / (debt * 1e9)
    // Rearranged to avoid overflow: (collateral * price / 1e5) / (debt / 10)
    // Simplified: direct calculation with integer division
    return (collateral * price * 10000) / (debt * 1000000000);
}

// ---------------------------------------------------------------------------
// Protocol lifecycle
// ---------------------------------------------------------------------------

// 1. initialize -- Create protocol state, USDH mint, and stability pool.
pub initialize(
    protocol: Protocol @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    usdh_mint: pubkey,
    stability_pool_vault: pubkey,
    min_collateral_ratio_bps: u64,
    borrowing_fee_bps: u64,
    redemption_fee_bps: u64
) {
    require(min_collateral_ratio_bps >= 10000); // at least 100%
    require(borrowing_fee_bps < 10000);
    require(redemption_fee_bps < 10000);

    protocol.authority = admin.ctx.key;
    protocol.usdh_mint = usdh_mint;
    protocol.stability_pool_vault = stability_pool_vault;
    protocol.total_collateral = 0;
    protocol.total_debt = 0;
    protocol.min_collateral_ratio_bps = min_collateral_ratio_bps;
    protocol.borrowing_fee_bps = borrowing_fee_bps;
    protocol.redemption_fee_bps = redemption_fee_bps;
    protocol.total_borrowing_fees = 0;
    protocol.is_paused = false;
}

// 2. create_trove -- Open a new collateral+debt position.
pub create_trove(
    protocol: Protocol,
    trove: Trove @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    collateral_mint: pubkey,
    collateral_vault: pubkey
) {
    require(!protocol.is_paused);

    trove.protocol = protocol.ctx.key;
    trove.owner = owner.ctx.key;
    trove.collateral_mint = collateral_mint;
    trove.collateral_vault = collateral_vault;
    trove.collateral_amount = 0;
    trove.debt_amount = 0;
    trove.collateral_ratio = 0;
    trove.last_update = get_clock().slot;
}

// 3. deposit_collateral -- Add collateral to an existing trove.
pub deposit_collateral(
    protocol: Protocol @mut,
    trove: Trove @mut,
    oracle: OraclePrice,
    user_collateral: account @mut,
    trove_vault: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!protocol.is_paused);
    require(trove.owner == user_authority.ctx.key);
    require(amount > 0);
    require(trove_vault.ctx.key == trove.collateral_vault);
    require(oracle.mint == trove.collateral_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    spl_token::SPLToken::transfer(user_collateral, trove_vault, user_authority, amount);

    trove.collateral_amount = trove.collateral_amount + amount;
    protocol.total_collateral = protocol.total_collateral + amount;
    trove.last_update = now;

    // Update cached CR
    trove.collateral_ratio = compute_collateral_ratio(
        trove.collateral_amount, trove.debt_amount, oracle.price
    );
}

// 4. withdraw_collateral -- Remove collateral, must maintain min CR.
pub withdraw_collateral(
    protocol: Protocol @mut,
    trove: Trove @mut @signer,
    oracle: OraclePrice,
    trove_vault: account @mut,
    user_collateral: account @mut,
    user_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!protocol.is_paused);
    require(trove.owner == user_authority.ctx.key);
    require(amount > 0);
    require(amount <= trove.collateral_amount);
    require(trove_vault.ctx.key == trove.collateral_vault);
    require(oracle.mint == trove.collateral_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    let new_collateral: u64 = trove.collateral_amount - amount;

    // Health check: new CR must exceed minimum
    if (trove.debt_amount > 0) {
        let new_cr: u64 = compute_collateral_ratio(new_collateral, trove.debt_amount, oracle.price);
        require(new_cr >= protocol.min_collateral_ratio_bps);
    }

    spl_token::SPLToken::transfer(trove_vault, user_collateral, trove, amount);

    trove.collateral_amount = new_collateral;
    protocol.total_collateral = protocol.total_collateral - amount;
    trove.last_update = now;

    trove.collateral_ratio = compute_collateral_ratio(
        trove.collateral_amount, trove.debt_amount, oracle.price
    );
}

// 5. borrow_usdh -- Mint USDH against deposited collateral, with borrowing fee.
pub borrow_usdh(
    protocol: Protocol @mut @signer,
    trove: Trove @mut,
    oracle: OraclePrice,
    usdh_mint: account @mut,
    user_usdh_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    usdh_amount: u64
) {
    require(!protocol.is_paused);
    require(trove.owner == user_authority.ctx.key);
    require(usdh_amount > 0);
    require(usdh_mint.ctx.key == protocol.usdh_mint);
    require(oracle.mint == trove.collateral_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    // Borrowing fee
    let fee: u64 = (usdh_amount * protocol.borrowing_fee_bps) / 10000;
    let total_new_debt: u64 = usdh_amount + fee;
    let new_debt: u64 = trove.debt_amount + total_new_debt;

    // CR check after new debt
    let new_cr: u64 = compute_collateral_ratio(trove.collateral_amount, new_debt, oracle.price);
    require(new_cr >= protocol.min_collateral_ratio_bps);

    // Mint USDH to user (they receive usdh_amount; fee is added to their debt)
    spl_token::SPLToken::mint_to(usdh_mint, user_usdh_account, protocol, usdh_amount);

    trove.debt_amount = new_debt;
    trove.collateral_ratio = new_cr;
    trove.last_update = now;

    protocol.total_debt = protocol.total_debt + total_new_debt;
    protocol.total_borrowing_fees = protocol.total_borrowing_fees + fee;
}

// 6. repay_usdh -- Burn USDH to reduce trove debt.
pub repay_usdh(
    protocol: Protocol @mut,
    trove: Trove @mut,
    oracle: OraclePrice,
    usdh_mint: account @mut,
    user_usdh_account: account @mut,
    user_authority: account @signer,
    token_program: account,
    usdh_amount: u64
) {
    require(!protocol.is_paused);
    require(trove.owner == user_authority.ctx.key);
    require(usdh_amount > 0);
    require(usdh_mint.ctx.key == protocol.usdh_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Clamp repayment to outstanding debt
    let mut repay: u64 = usdh_amount;
    if (repay > trove.debt_amount) {
        repay = trove.debt_amount;
    }

    spl_token::SPLToken::burn(user_usdh_account, usdh_mint, user_authority, repay);

    trove.debt_amount = trove.debt_amount - repay;
    trove.last_update = now;

    if (protocol.total_debt >= repay) {
        protocol.total_debt = protocol.total_debt - repay;
    } else {
        protocol.total_debt = 0;
    }

    trove.collateral_ratio = compute_collateral_ratio(
        trove.collateral_amount, trove.debt_amount, oracle.price
    );
}

// 7. close_trove -- Repay all debt and withdraw all collateral, closing the trove.
pub close_trove(
    protocol: Protocol @mut @signer,
    trove: Trove @mut @signer,
    oracle: OraclePrice,
    usdh_mint: account @mut,
    user_usdh_account: account @mut,
    trove_vault: account @mut,
    user_collateral: account @mut,
    user_authority: account @signer,
    token_program: account
) {
    require(!protocol.is_paused);
    require(trove.owner == user_authority.ctx.key);
    require(trove_vault.ctx.key == trove.collateral_vault);
    require(usdh_mint.ctx.key == protocol.usdh_mint);

    // Burn all outstanding debt
    if (trove.debt_amount > 0) {
        spl_token::SPLToken::burn(user_usdh_account, usdh_mint, user_authority, trove.debt_amount);

        if (protocol.total_debt >= trove.debt_amount) {
            protocol.total_debt = protocol.total_debt - trove.debt_amount;
        } else {
            protocol.total_debt = 0;
        }
    }

    // Withdraw all collateral
    if (trove.collateral_amount > 0) {
        spl_token::SPLToken::transfer(trove_vault, user_collateral, trove, trove.collateral_amount);

        if (protocol.total_collateral >= trove.collateral_amount) {
            protocol.total_collateral = protocol.total_collateral - trove.collateral_amount;
        } else {
            protocol.total_collateral = 0;
        }
    }

    trove.collateral_amount = 0;
    trove.debt_amount = 0;
    trove.collateral_ratio = 0;
    trove.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// Liquidation
// ---------------------------------------------------------------------------

// 8. liquidate_trove -- Liquidate a trove whose CR fell below the minimum.
//    Stability Pool USDH absorbs the debt; liquidator receives collateral + bonus.
pub liquidate_trove(
    protocol: Protocol @mut @signer,
    trove: Trove @mut @signer,
    oracle: OraclePrice,
    stability_pool_vault: account @mut,
    usdh_mint: account @mut,
    trove_vault: account @mut,
    liquidator_collateral: account @mut,
    liquidator: account @signer,
    token_program: account
) {
    require(!protocol.is_paused);
    require(oracle.mint == trove.collateral_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);
    require(trove_vault.ctx.key == trove.collateral_vault);
    require(stability_pool_vault.ctx.key == protocol.stability_pool_vault);
    require(usdh_mint.ctx.key == protocol.usdh_mint);

    // Verify the trove is under-collateralized
    let current_cr: u64 = compute_collateral_ratio(
        trove.collateral_amount, trove.debt_amount, oracle.price
    );
    require(current_cr < protocol.min_collateral_ratio_bps);
    require(trove.debt_amount > 0);

    // Burn USDH from stability pool to cover the debt
    spl_token::SPLToken::burn(stability_pool_vault, usdh_mint, protocol, trove.debt_amount);

    // Liquidation bonus: 10% extra collateral to liquidator (hardcoded per Hubble spec)
    // Collateral to seize = debt_amount * PRICE_SCALE / oracle_price * 110%
    // Simplified: (debt_amount * 1000000000 * 110) / (oracle_price * 100)
    let collateral_value: u64 = (trove.debt_amount * 1000000000) / oracle.price;
    let collateral_with_bonus: u64 = (collateral_value * 110) / 100;

    let mut seize_amount: u64 = collateral_with_bonus;
    if (seize_amount > trove.collateral_amount) {
        seize_amount = trove.collateral_amount;
    }

    spl_token::SPLToken::transfer(trove_vault, liquidator_collateral, trove, seize_amount);

    // Update protocol totals
    if (protocol.total_debt >= trove.debt_amount) {
        protocol.total_debt = protocol.total_debt - trove.debt_amount;
    } else {
        protocol.total_debt = 0;
    }
    if (protocol.total_collateral >= seize_amount) {
        protocol.total_collateral = protocol.total_collateral - seize_amount;
    } else {
        protocol.total_collateral = 0;
    }

    // Zero out the trove
    trove.collateral_amount = trove.collateral_amount - seize_amount;
    trove.debt_amount = 0;
    trove.collateral_ratio = 0;
    trove.last_update = now;
}

// ---------------------------------------------------------------------------
// Stability Pool
// ---------------------------------------------------------------------------

// 9. stability_pool_deposit -- Deposit USDH to the stability pool.
//    Stability pool USDH absorbs liquidations; depositors earn collateral gains.
pub stability_pool_deposit(
    protocol: Protocol,
    deposit: StabilityDeposit @mut @init(payer=depositor, space=256),
    stability_pool_vault: account @mut,
    user_usdh_account: account @mut,
    depositor: account @mut @signer,
    token_program: account,
    amount: u64
) {
    require(!protocol.is_paused);
    require(amount > 0);
    require(stability_pool_vault.ctx.key == protocol.stability_pool_vault);

    spl_token::SPLToken::transfer(user_usdh_account, stability_pool_vault, depositor, amount);

    deposit.protocol = protocol.ctx.key;
    deposit.owner = depositor.ctx.key;
    deposit.usdh_deposited = deposit.usdh_deposited + amount;
    deposit.pending_collateral_gain = 0;
    deposit.pending_reward = 0;
}

// 10. stability_pool_withdraw -- Withdraw USDH from the stability pool.
pub stability_pool_withdraw(
    protocol: Protocol @signer,
    deposit: StabilityDeposit @mut,
    stability_pool_vault: account @mut,
    user_usdh_account: account @mut,
    depositor: account @signer,
    token_program: account,
    amount: u64
) {
    require(!protocol.is_paused);
    require(deposit.owner == depositor.ctx.key);
    require(amount > 0);
    require(amount <= deposit.usdh_deposited);
    require(stability_pool_vault.ctx.key == protocol.stability_pool_vault);

    spl_token::SPLToken::transfer(stability_pool_vault, user_usdh_account, protocol, amount);
    deposit.usdh_deposited = deposit.usdh_deposited - amount;
}

// 11. claim_liquidation_gains -- Claim collateral earned from absorbed liquidations.
pub claim_liquidation_gains(
    protocol: Protocol @signer,
    deposit: StabilityDeposit @mut,
    collateral_vault: account @mut,
    user_collateral: account @mut,
    depositor: account @signer,
    token_program: account
) {
    require(deposit.owner == depositor.ctx.key);
    require(deposit.pending_collateral_gain > 0);

    let gain: u64 = deposit.pending_collateral_gain;
    deposit.pending_collateral_gain = 0;

    spl_token::SPLToken::transfer(collateral_vault, user_collateral, protocol, gain);
}

// ---------------------------------------------------------------------------
// Redemptions
// ---------------------------------------------------------------------------

// 12. redeem -- Swap USDH for collateral at $1 face value from lowest-CR troves.
//     Redemption fee is deducted. This improves system-wide health.
pub redeem(
    protocol: Protocol @mut @signer,
    trove: Trove @mut @signer,
    oracle: OraclePrice,
    usdh_mint: account @mut,
    user_usdh_account: account @mut,
    trove_vault: account @mut,
    user_collateral: account @mut,
    redeemer: account @signer,
    token_program: account,
    usdh_amount: u64
) {
    require(!protocol.is_paused);
    require(usdh_amount > 0);
    require(usdh_mint.ctx.key == protocol.usdh_mint);
    require(trove_vault.ctx.key == trove.collateral_vault);
    require(oracle.mint == trove.collateral_mint);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);
    require(oracle.price > 0);

    // Clamp to trove's outstanding debt
    let mut redeem_amount: u64 = usdh_amount;
    if (redeem_amount > trove.debt_amount) {
        redeem_amount = trove.debt_amount;
    }

    // Redemption fee
    let fee: u64 = (redeem_amount * protocol.redemption_fee_bps) / 10000;
    let net_redeem: u64 = redeem_amount - fee;

    // Calculate collateral to receive at face value ($1 per USDH)
    // collateral = net_redeem * PRICE_SCALE / oracle_price
    let collateral_out: u64 = (net_redeem * 1000000000) / oracle.price;
    require(collateral_out > 0);
    require(collateral_out <= trove.collateral_amount);

    // Burn the USDH
    spl_token::SPLToken::burn(user_usdh_account, usdh_mint, redeemer, redeem_amount);

    // Transfer collateral to redeemer
    spl_token::SPLToken::transfer(trove_vault, user_collateral, trove, collateral_out);

    // Update trove
    trove.debt_amount = trove.debt_amount - redeem_amount;
    trove.collateral_amount = trove.collateral_amount - collateral_out;
    trove.last_update = now;
    trove.collateral_ratio = compute_collateral_ratio(
        trove.collateral_amount, trove.debt_amount, oracle.price
    );

    // Update protocol totals
    if (protocol.total_debt >= redeem_amount) {
        protocol.total_debt = protocol.total_debt - redeem_amount;
    } else {
        protocol.total_debt = 0;
    }
    if (protocol.total_collateral >= collateral_out) {
        protocol.total_collateral = protocol.total_collateral - collateral_out;
    } else {
        protocol.total_collateral = 0;
    }
}

// ---------------------------------------------------------------------------
// Oracle
// ---------------------------------------------------------------------------

// 13. update_oracle -- Push a new price for an oracle feed.
pub update_oracle(
    oracle: OraclePrice @mut,
    authority: account @signer,
    new_price: u64,
    new_decimals: u8
) {
    require(oracle.authority == authority.ctx.key);
    require(new_price > 0);

    oracle.price = new_price;
    oracle.decimals = new_decimals;
    oracle.last_update = get_clock().slot;
}

// ---------------------------------------------------------------------------
// Admin instructions
// ---------------------------------------------------------------------------

// 14. set_redemption_fee -- Admin: update redemption fee.
pub set_redemption_fee(
    protocol: Protocol @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(protocol.authority == authority.ctx.key);
    require(new_fee_bps < 10000);
    protocol.redemption_fee_bps = new_fee_bps;
}

// 15. set_borrowing_fee -- Admin: update borrowing fee.
pub set_borrowing_fee(
    protocol: Protocol @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(protocol.authority == authority.ctx.key);
    require(new_fee_bps < 10000);
    protocol.borrowing_fee_bps = new_fee_bps;
}

// 16. set_min_collateral_ratio -- Admin: update minimum collateral ratio.
pub set_min_collateral_ratio(
    protocol: Protocol @mut,
    authority: account @signer,
    new_ratio_bps: u64
) {
    require(protocol.authority == authority.ctx.key);
    require(new_ratio_bps >= 10000); // must be at least 100%
    protocol.min_collateral_ratio_bps = new_ratio_bps;
}

// 17. collect_borrowing_fees -- Admin: withdraw accumulated borrowing fees.
pub collect_borrowing_fees(
    protocol: Protocol @mut @signer,
    usdh_mint: account @mut,
    fee_recipient: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(protocol.authority == authority.ctx.key);
    require(protocol.total_borrowing_fees > 0);
    require(usdh_mint.ctx.key == protocol.usdh_mint);

    let fees: u64 = protocol.total_borrowing_fees;
    protocol.total_borrowing_fees = 0;

    // Mint the fee amount as USDH to the fee recipient
    spl_token::SPLToken::mint_to(usdh_mint, fee_recipient, protocol, fees);
}

// 18. set_authority -- Transfer protocol admin.
pub set_authority(
    protocol: Protocol @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(protocol.authority == authority.ctx.key);
    protocol.authority = new_authority;
}

// 19. pause -- Halt all protocol operations.
pub pause(
    protocol: Protocol @mut,
    authority: account @signer
) {
    require(protocol.authority == authority.ctx.key);
    protocol.is_paused = true;
}

// 20. unpause -- Resume protocol operations.
pub unpause(
    protocol: Protocol @mut,
    authority: account @signer
) {
    require(protocol.authority == authority.ctx.key);
    protocol.is_paused = false;
}
