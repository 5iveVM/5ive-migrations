// UXD Protocol -- 5ive DSL Migration
//
// Delta-neutral stablecoin: mint UXD by depositing SOL, protocol opens a
// short perpetual position to hedge price exposure. Result: UXD stays at $1
// regardless of SOL price movement.
//
// Key innovation:
//   - 1 SOL deposited -> protocol opens 1 SOL short perp -> price movement
//     on the collateral is exactly offset by PnL on the short -> UXD = $1
//   - Funding payments from short perps = yield for the protocol
//   - Idle USDC is parked in Mercurial vaults for additional yield
//   - Insurance fund covers negative funding episodes
//
// Integer-only math; BPS_SCALE = 10000, PRICE_SCALE = 1000000000 (1e9)

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Controller {
    authority: pubkey;
    uxd_mint: pubkey;                    // UXD stablecoin mint
    insurance_vault: pubkey;             // insurance fund vault
    total_collateral_deposited: u64;     // total SOL (or other) collateral held
    total_uxd_minted: u64;              // total UXD in circulation
    redeemable_supply_cap: u64;          // max UXD that can be minted globally
    minting_fee_bps: u64;               // fee on UXD minting
    redeeming_fee_bps: u64;             // fee on UXD redemption
    insurance_balance: u64;              // SOL/USDC in insurance fund
    mercurial_vault: pubkey;             // connected Mercurial vault for idle yield
    mercurial_deposited: u64;            // amount parked in Mercurial
    is_paused: bool;
}

account HedgePosition {
    controller: pubkey;
    collateral_mint: pubkey;             // which asset is hedged (e.g., SOL)
    perp_market: pubkey;                 // which perp market the short is on
    collateral_amount: u64;              // deposited collateral backing this position
    short_size: u64;                     // size of the short perp position
    entry_price: u64;                    // price at which short was opened (scaled)
    unrealized_pnl: i64;                // current PnL on the short (can be negative)
    funding_accrued: i64;                // cumulative funding payments (positive = earned)
}

account OraclePrice {
    authority: pubkey;
    mint: pubkey;
    price: u64;                          // price scaled by PRICE_SCALE
    last_update: u64;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Compute the dollar value of collateral.
// value = collateral_amount * oracle_price / PRICE_SCALE
fn compute_collateral_value(amount: u64, price: u64) -> u64 {
    return (amount * price) / 1000000000;
}

// ---------------------------------------------------------------------------
// Core instructions
// ---------------------------------------------------------------------------

// 1. initialize -- Create the UXD controller, set mint and insurance fund.
pub initialize(
    controller: Controller @mut @init(payer=admin, space=768) @signer,
    admin: account @mut @signer,
    uxd_mint: pubkey,
    insurance_vault: pubkey,
    redeemable_supply_cap: u64,
    minting_fee_bps: u64,
    redeeming_fee_bps: u64
) {
    require(redeemable_supply_cap > 0);
    require(minting_fee_bps < 10000);
    require(redeeming_fee_bps < 10000);

    controller.authority = admin.ctx.key;
    controller.uxd_mint = uxd_mint;
    controller.insurance_vault = insurance_vault;
    controller.total_collateral_deposited = 0;
    controller.total_uxd_minted = 0;
    controller.redeemable_supply_cap = redeemable_supply_cap;
    controller.minting_fee_bps = minting_fee_bps;
    controller.redeeming_fee_bps = redeeming_fee_bps;
    controller.insurance_balance = 0;
    controller.mercurial_vault = insurance_vault; // default; updated via register
    controller.mercurial_deposited = 0;
    controller.is_paused = false;
}

// 2. mint_uxd -- Deposit collateral, protocol opens short perp, mint UXD 1:1.
//    The short hedge ensures price neutrality: if SOL goes up, short loses
//    the same amount, and vice versa. UXD value stays at $1.
pub mint_uxd(
    controller: Controller @mut @signer,
    hedge: HedgePosition @mut @init(payer=user, space=512),
    oracle: OraclePrice,
    uxd_mint: account @mut,
    user_collateral: account @mut,
    controller_collateral_vault: account @mut,
    user_uxd_account: account @mut,
    user: account @mut @signer,
    token_program: account,
    collateral_amount: u64
) {
    require(!controller.is_paused);
    require(collateral_amount > 0);
    require(uxd_mint.ctx.key == controller.uxd_mint);
    require(oracle.price > 0);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Calculate UXD to mint = collateral dollar value
    let collateral_value: u64 = compute_collateral_value(collateral_amount, oracle.price);
    require(collateral_value > 0);

    // Minting fee
    let fee: u64 = (collateral_value * controller.minting_fee_bps) / 10000;
    let uxd_to_mint: u64 = collateral_value - fee;
    require(uxd_to_mint > 0);

    // Supply cap check
    require(controller.total_uxd_minted + uxd_to_mint <= controller.redeemable_supply_cap);

    // Transfer collateral from user to controller
    spl_token::SPLToken::transfer(user_collateral, controller_collateral_vault, user, collateral_amount);

    // Mint UXD to user
    spl_token::SPLToken::mint_to(uxd_mint, user_uxd_account, controller, uxd_to_mint);

    // Record hedge position (short perp opened at oracle price)
    hedge.controller = controller.ctx.key;
    hedge.collateral_mint = oracle.mint;
    hedge.perp_market = oracle.mint; // simplified; real impl references actual perp market
    hedge.collateral_amount = collateral_amount;
    hedge.short_size = collateral_amount;
    hedge.entry_price = oracle.price;
    hedge.unrealized_pnl = 0;
    hedge.funding_accrued = 0;

    // Update controller totals
    controller.total_collateral_deposited = controller.total_collateral_deposited + collateral_amount;
    controller.total_uxd_minted = controller.total_uxd_minted + uxd_to_mint;
    controller.insurance_balance = controller.insurance_balance + fee;
}

// 3. redeem_uxd -- Burn UXD, protocol closes short, return collateral.
pub redeem_uxd(
    controller: Controller @mut @signer,
    hedge: HedgePosition @mut,
    oracle: OraclePrice,
    uxd_mint: account @mut,
    user_uxd_account: account @mut,
    controller_collateral_vault: account @mut,
    user_collateral: account @mut,
    user: account @signer,
    token_program: account,
    uxd_amount: u64
) {
    require(!controller.is_paused);
    require(uxd_amount > 0);
    require(uxd_mint.ctx.key == controller.uxd_mint);
    require(oracle.price > 0);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Clamp to controller's outstanding UXD
    let mut redeem_amount: u64 = uxd_amount;
    if (redeem_amount > controller.total_uxd_minted) {
        redeem_amount = controller.total_uxd_minted;
    }

    // Redemption fee
    let fee: u64 = (redeem_amount * controller.redeeming_fee_bps) / 10000;
    let net_value: u64 = redeem_amount - fee;

    // Calculate collateral to return: net_value * PRICE_SCALE / oracle_price
    let collateral_out: u64 = (net_value * 1000000000) / oracle.price;
    require(collateral_out > 0);
    require(collateral_out <= controller.total_collateral_deposited);
    require(collateral_out <= hedge.collateral_amount);

    // Burn UXD
    spl_token::SPLToken::burn(user_uxd_account, uxd_mint, user, redeem_amount);

    // Return collateral
    spl_token::SPLToken::transfer(controller_collateral_vault, user_collateral, controller, collateral_out);

    // Update hedge position (reduce short proportionally)
    hedge.collateral_amount = hedge.collateral_amount - collateral_out;
    hedge.short_size = hedge.short_size - collateral_out;

    // Update controller
    controller.total_uxd_minted = controller.total_uxd_minted - redeem_amount;
    if (controller.total_collateral_deposited >= collateral_out) {
        controller.total_collateral_deposited = controller.total_collateral_deposited - collateral_out;
    } else {
        controller.total_collateral_deposited = 0;
    }
    controller.insurance_balance = controller.insurance_balance + fee;
}

// 4. rebalance -- Adjust the hedge if funding costs have eroded insurance.
//    Recalculates PnL on short position and adjusts hedge size if needed.
pub rebalance(
    controller: Controller @mut,
    hedge: HedgePosition @mut,
    oracle: OraclePrice,
    authority: account @signer
) {
    require(!controller.is_paused);
    require(controller.authority == authority.ctx.key);
    require(oracle.price > 0);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Calculate unrealized PnL on the short:
    // If price went UP since entry, short loses -> negative PnL
    // If price went DOWN, short gains -> positive PnL
    // pnl = (entry_price - current_price) * short_size / PRICE_SCALE
    let mut pnl: i64 = 0;
    if (oracle.price < hedge.entry_price) {
        // Price dropped: short is profitable
        let diff: u64 = hedge.entry_price - oracle.price;
        pnl = ((diff * hedge.short_size) / 1000000000) as i64;
    } else {
        // Price rose: short is losing
        let diff: u64 = oracle.price - hedge.entry_price;
        pnl = 0 - ((diff * hedge.short_size) / 1000000000) as i64;
    }

    hedge.unrealized_pnl = pnl;

    // Update entry price to current (mark to market)
    hedge.entry_price = oracle.price;
}

// ---------------------------------------------------------------------------
// Mercurial integration (idle yield)
// ---------------------------------------------------------------------------

// 5. register_mercurial_vault -- Connect a Mercurial vault for idle USDC yield.
pub register_mercurial_vault(
    controller: Controller @mut,
    authority: account @signer,
    mercurial_vault: pubkey
) {
    require(controller.authority == authority.ctx.key);
    controller.mercurial_vault = mercurial_vault;
    controller.mercurial_deposited = 0;
}

// 6. deposit_to_mercurial -- Park idle stablecoins in Mercurial for yield.
pub deposit_to_mercurial(
    controller: Controller @mut @signer,
    controller_stable_vault: account @mut,
    mercurial_vault: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!controller.is_paused);
    require(controller.authority == authority.ctx.key);
    require(amount > 0);
    require(mercurial_vault.ctx.key == controller.mercurial_vault);

    spl_token::SPLToken::transfer(controller_stable_vault, mercurial_vault, controller, amount);
    controller.mercurial_deposited = controller.mercurial_deposited + amount;
}

// 7. withdraw_from_mercurial -- Pull stablecoins back from Mercurial.
pub withdraw_from_mercurial(
    controller: Controller @mut,
    mercurial_vault: account @mut,
    controller_stable_vault: account @mut,
    mercurial_authority: account @signer,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(!controller.is_paused);
    require(controller.authority == authority.ctx.key);
    require(amount > 0);
    require(amount <= controller.mercurial_deposited);
    require(mercurial_vault.ctx.key == controller.mercurial_vault);

    spl_token::SPLToken::transfer(mercurial_vault, controller_stable_vault, mercurial_authority, amount);
    controller.mercurial_deposited = controller.mercurial_deposited - amount;
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// 8. set_redeemable_global_supply_cap -- Admin: update max UXD supply.
pub set_redeemable_global_supply_cap(
    controller: Controller @mut,
    authority: account @signer,
    new_cap: u64
) {
    require(controller.authority == authority.ctx.key);
    require(new_cap > 0);
    controller.redeemable_supply_cap = new_cap;
}

// 9. set_minting_fee -- Admin: update minting fee.
pub set_minting_fee(
    controller: Controller @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(controller.authority == authority.ctx.key);
    require(new_fee_bps < 10000);
    controller.minting_fee_bps = new_fee_bps;
}

// 10. set_redeeming_fee -- Admin: update redemption fee.
pub set_redeeming_fee(
    controller: Controller @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(controller.authority == authority.ctx.key);
    require(new_fee_bps < 10000);
    controller.redeeming_fee_bps = new_fee_bps;
}

// ---------------------------------------------------------------------------
// Interest and insurance
// ---------------------------------------------------------------------------

// 11. collect_interest -- Collect yield from perp funding + Mercurial.
//     Positive funding from short perps and Mercurial vault yield are
//     consolidated into the insurance fund.
pub collect_interest(
    controller: Controller @mut,
    hedge: HedgePosition @mut,
    authority: account @signer,
    funding_amount: u64,
    mercurial_yield: u64
) {
    require(controller.authority == authority.ctx.key);

    // Add funding revenue
    if (funding_amount > 0) {
        controller.insurance_balance = controller.insurance_balance + funding_amount;
        hedge.funding_accrued = hedge.funding_accrued + funding_amount as i64;
    }

    // Add Mercurial yield
    if (mercurial_yield > 0) {
        controller.insurance_balance = controller.insurance_balance + mercurial_yield;
        if (controller.mercurial_deposited >= mercurial_yield) {
            // Yield realized; reduce tracked deposit (yield is now in insurance)
        }
    }
}

// 12. fund_insurance -- Deposit additional funds to the insurance vault.
pub fund_insurance(
    controller: Controller @mut,
    insurance_vault: account @mut,
    funder_account: account @mut,
    funder: account @signer,
    token_program: account,
    amount: u64
) {
    require(amount > 0);
    require(insurance_vault.ctx.key == controller.insurance_vault);

    spl_token::SPLToken::transfer(funder_account, insurance_vault, funder, amount);
    controller.insurance_balance = controller.insurance_balance + amount;
}

// 13. withdraw_insurance -- Admin: withdraw from the insurance fund.
pub withdraw_insurance(
    controller: Controller @mut @signer,
    insurance_vault: account @mut,
    recipient: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(controller.authority == authority.ctx.key);
    require(amount > 0);
    require(amount <= controller.insurance_balance);
    require(insurance_vault.ctx.key == controller.insurance_vault);

    spl_token::SPLToken::transfer(insurance_vault, recipient, controller, amount);
    controller.insurance_balance = controller.insurance_balance - amount;
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

// 14. set_authority -- Transfer controller admin.
pub set_authority(
    controller: Controller @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(controller.authority == authority.ctx.key);
    controller.authority = new_authority;
}

// 15. pause -- Halt all minting and redeeming.
pub pause(
    controller: Controller @mut,
    authority: account @signer
) {
    require(controller.authority == authority.ctx.key);
    controller.is_paused = true;
}

// 16. unpause -- Resume operations.
pub unpause(
    controller: Controller @mut,
    authority: account @signer
) {
    require(controller.authority == authority.ctx.key);
    controller.is_paused = false;
}

// 17. update_controller -- Admin: batch-update controller configuration.
pub update_controller(
    controller: Controller @mut,
    authority: account @signer,
    new_supply_cap: u64,
    new_minting_fee_bps: u64,
    new_redeeming_fee_bps: u64
) {
    require(controller.authority == authority.ctx.key);
    require(new_supply_cap > 0);
    require(new_minting_fee_bps < 10000);
    require(new_redeeming_fee_bps < 10000);

    controller.redeemable_supply_cap = new_supply_cap;
    controller.minting_fee_bps = new_minting_fee_bps;
    controller.redeeming_fee_bps = new_redeeming_fee_bps;
}

// 18. emergency_close_positions -- Admin: force-close all hedge positions.
//     Used when perp market is degraded or funding costs are catastrophic.
//     Returns collateral to insurance fund; UXD supply remains but is no
//     longer delta-neutral until re-hedged.
pub emergency_close_positions(
    controller: Controller @mut @signer,
    hedge: HedgePosition @mut,
    oracle: OraclePrice,
    controller_collateral_vault: account @mut,
    insurance_vault: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(controller.authority == authority.ctx.key);
    require(insurance_vault.ctx.key == controller.insurance_vault);
    require(oracle.price > 0);

    let now: u64 = get_clock().slot;
    require(now - oracle.last_update <= 100);

    // Calculate final PnL on the short
    let mut final_pnl: i64 = 0;
    if (oracle.price < hedge.entry_price) {
        let diff: u64 = hedge.entry_price - oracle.price;
        final_pnl = ((diff * hedge.short_size) / 1000000000) as i64;
    } else {
        let diff: u64 = oracle.price - hedge.entry_price;
        final_pnl = 0 - ((diff * hedge.short_size) / 1000000000) as i64;
    }

    // Move remaining collateral to insurance vault
    if (hedge.collateral_amount > 0) {
        spl_token::SPLToken::transfer(
            controller_collateral_vault, insurance_vault, controller, hedge.collateral_amount
        );

        controller.insurance_balance = controller.insurance_balance + hedge.collateral_amount;
        if (controller.total_collateral_deposited >= hedge.collateral_amount) {
            controller.total_collateral_deposited = controller.total_collateral_deposited - hedge.collateral_amount;
        } else {
            controller.total_collateral_deposited = 0;
        }
    }

    // Zero out the hedge
    hedge.collateral_amount = 0;
    hedge.short_size = 0;
    hedge.unrealized_pnl = final_pnl;
    hedge.funding_accrued = hedge.funding_accrued + final_pnl;
}
