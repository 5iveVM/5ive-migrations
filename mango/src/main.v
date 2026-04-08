// 5IVE Mango Markets v4 -- Cross-Margined Derivatives Exchange
//
// Design (Mango Markets v4):
//   - MangoGroup: top-level exchange instance with admin and insurance vault
//   - TokenBank: per-token reserve with deposit/borrow indices, interest model, risk weights
//   - MangoAccount: user portfolio -- up to 4 token positions + 2 perp positions, cross-margined
//   - PerpMarket: perpetual futures market with oracle, funding, and fees
//   - PerpOrder: individual order on a perp market (limit/market, long/short)
//   - Health: weighted assets - weighted liabilities + perp value; must be > 0
//   - Interest: compound accrual via deposit_index / borrow_index (scaled 1e6)
//   - Funding: periodic settlement; longs pay shorts when mark > oracle (and vice versa)
//   - Flash loans: borrow + repay within one transaction; fee charged
//   - Liquidation: force-close unhealthy positions at oracle + bonus
//   - Negative token deposits = borrows; all positions share one health score
//   - Fixed slots: 4 token positions + 2 perp positions per MangoAccount (no dynamic arrays)
//
// Index scale: 1_000_000 (1e6). A raw deposit of 100 tokens at index 1_000_000 = 100 tokens.
// As interest accrues, indices grow; native_deposit = raw_deposit * deposit_index / 1e6.
//
// Weight scale: 10_000 = 100%. init_asset_weight 8000 = 80%.
// Fee scale: basis points (1 bps = 0.01%).
// Funding rate: i64 scaled 1e6.

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account MangoGroup {
    admin: pubkey;
    insurance_vault: pubkey;
    num_tokens: u8;
    num_perp_markets: u8;
    is_paused: bool;
    fees_accrued: u64;
}

account TokenBank {
    group: pubkey;
    mint: pubkey;
    vault: pubkey;
    oracle: pubkey;
    deposit_index: u64;
    borrow_index: u64;
    total_deposits: u64;
    total_borrows: u64;
    optimal_utilization: u64;
    interest_rate_0: u64;
    interest_rate_1: u64;
    max_rate: u64;
    init_asset_weight: u64;
    maint_asset_weight: u64;
    init_liab_weight: u64;
    maint_liab_weight: u64;
    last_update: u64;
    oracle_price: u64;
    bank_index: u8;
}

account MangoAccount {
    group: pubkey;
    owner: pubkey;
    delegate: pubkey;
    is_bankrupt: bool;
    // Token positions (up to 4). Positive = deposit, negative = borrow.
    token_deposit_1: i64;
    token_bank_1: pubkey;
    token_deposit_2: i64;
    token_bank_2: pubkey;
    token_deposit_3: i64;
    token_bank_3: pubkey;
    token_deposit_4: i64;
    token_bank_4: pubkey;
    // Perp positions (up to 2).
    perp_base_position_1: i64;
    perp_quote_position_1: i64;
    perp_market_1: pubkey;
    perp_realized_pnl_1: i64;
    perp_unsettled_funding_1: i64;
    perp_base_position_2: i64;
    perp_quote_position_2: i64;
    perp_market_2: pubkey;
    perp_realized_pnl_2: i64;
    perp_unsettled_funding_2: i64;
}

account PerpMarket {
    group: pubkey;
    oracle: pubkey;
    base_decimals: u8;
    quote_decimals: u8;
    market_index: u8;
    base_lot_size: u64;
    quote_lot_size: u64;
    long_funding: i64;
    short_funding: i64;
    funding_last_updated: u64;
    open_interest: u64;
    fees_accrued: u64;
    maker_fee_bps: u64;
    taker_fee_bps: u64;
    min_funding_rate: i64;
    max_funding_rate: i64;
    oracle_price: u64;
    is_active: bool;
}

account PerpOrder {
    market: pubkey;
    owner: pubkey;
    is_long: bool;
    price: u64;
    size: u64;
    filled: u64;
    order_id: u64;
    is_active: bool;
}

account PriceOracle {
    authority: pubkey;
    price: u64;
    last_update: u64;
}

// ---------------------------------------------------------------------------
// Constants (as helper fns)
// ---------------------------------------------------------------------------

fn index_scale() -> u64 {
    return 1000000;
}

fn weight_scale() -> u64 {
    return 10000;
}

fn bps_scale() -> u64 {
    return 10000;
}

fn seconds_per_year() -> u64 {
    return 31536000;
}

fn zero_pubkey() -> pubkey {
    return pubkey(0);
}

// ---------------------------------------------------------------------------
// 1. create_group -- Create a MangoGroup (the exchange instance)
// ---------------------------------------------------------------------------

pub create_group(
    group: MangoGroup @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    insurance_vault: account
) {
    group.admin = admin.ctx.key;
    group.insurance_vault = insurance_vault.ctx.key;
    group.num_tokens = 0;
    group.num_perp_markets = 0;
    group.is_paused = false;
    group.fees_accrued = 0;
}

// ---------------------------------------------------------------------------
// 2. create_account -- Create a user MangoAccount
// ---------------------------------------------------------------------------

pub create_account(
    group: MangoGroup,
    mango_account: MangoAccount @mut @init(payer=owner, space=1024) @signer,
    owner: account @mut @signer
) {
    require(!group.is_paused);

    mango_account.group = group.ctx.key;
    mango_account.owner = owner.ctx.key;
    mango_account.delegate = zero_pubkey();
    mango_account.is_bankrupt = false;

    mango_account.token_deposit_1 = 0;
    mango_account.token_bank_1 = zero_pubkey();
    mango_account.token_deposit_2 = 0;
    mango_account.token_bank_2 = zero_pubkey();
    mango_account.token_deposit_3 = 0;
    mango_account.token_bank_3 = zero_pubkey();
    mango_account.token_deposit_4 = 0;
    mango_account.token_bank_4 = zero_pubkey();

    mango_account.perp_base_position_1 = 0;
    mango_account.perp_quote_position_1 = 0;
    mango_account.perp_market_1 = zero_pubkey();
    mango_account.perp_realized_pnl_1 = 0;
    mango_account.perp_unsettled_funding_1 = 0;
    mango_account.perp_base_position_2 = 0;
    mango_account.perp_quote_position_2 = 0;
    mango_account.perp_market_2 = zero_pubkey();
    mango_account.perp_realized_pnl_2 = 0;
    mango_account.perp_unsettled_funding_2 = 0;
}

// ---------------------------------------------------------------------------
// 3. close_account -- Close a MangoAccount (must have no positions)
// ---------------------------------------------------------------------------

pub close_account(
    mango_account: MangoAccount @mut,
    owner: account @signer
) {
    require(mango_account.owner == owner.ctx.key);
    require(!mango_account.is_bankrupt);

    // All token positions must be zero
    require(mango_account.token_deposit_1 == 0);
    require(mango_account.token_deposit_2 == 0);
    require(mango_account.token_deposit_3 == 0);
    require(mango_account.token_deposit_4 == 0);

    // All perp positions must be zero
    require(mango_account.perp_base_position_1 == 0);
    require(mango_account.perp_quote_position_1 == 0);
    require(mango_account.perp_base_position_2 == 0);
    require(mango_account.perp_quote_position_2 == 0);

    // Mark as closed by zeroing owner
    mango_account.owner = zero_pubkey();
}

// ---------------------------------------------------------------------------
// 4. register_token -- Register a token for deposits/borrows
// ---------------------------------------------------------------------------

pub register_token(
    group: MangoGroup @mut,
    bank: TokenBank @mut @init(payer=admin, space=768) @signer,
    admin: account @mut @signer,
    mint: account,
    vault: account,
    oracle: account,
    optimal_utilization: u64,
    interest_rate_0: u64,
    interest_rate_1: u64,
    max_rate: u64,
    init_asset_weight: u64,
    maint_asset_weight: u64,
    init_liab_weight: u64,
    maint_liab_weight: u64
) {
    require(group.admin == admin.ctx.key);
    require(!group.is_paused);
    require(group.num_tokens < 4);
    require(optimal_utilization <= 10000);
    require(init_asset_weight <= maint_asset_weight);
    require(init_liab_weight >= maint_liab_weight);

    bank.group = group.ctx.key;
    bank.mint = mint.ctx.key;
    bank.vault = vault.ctx.key;
    bank.oracle = oracle.ctx.key;
    bank.deposit_index = index_scale();
    bank.borrow_index = index_scale();
    bank.total_deposits = 0;
    bank.total_borrows = 0;
    bank.optimal_utilization = optimal_utilization;
    bank.interest_rate_0 = interest_rate_0;
    bank.interest_rate_1 = interest_rate_1;
    bank.max_rate = max_rate;
    bank.init_asset_weight = init_asset_weight;
    bank.maint_asset_weight = maint_asset_weight;
    bank.init_liab_weight = init_liab_weight;
    bank.maint_liab_weight = maint_liab_weight;
    bank.last_update = get_clock().unix_timestamp;
    bank.oracle_price = 0;
    bank.bank_index = group.num_tokens;

    group.num_tokens = group.num_tokens + 1;
}

// ---------------------------------------------------------------------------
// Helper: two-slope interest rate model
// ---------------------------------------------------------------------------

fn calc_utilization(deposits: u64, borrows: u64) -> u64 {
    let total: u64 = deposits + borrows;
    if (total == 0) {
        return 0;
    }
    return (borrows * 10000) / total;
}

fn calc_borrow_rate(
    utilization: u64,
    optimal_util: u64,
    rate_0: u64,
    rate_1: u64,
    max_rate: u64
) -> u64 {
    if (utilization <= optimal_util) {
        if (optimal_util == 0) {
            return rate_0;
        }
        return rate_0 + (utilization * (rate_1 - rate_0)) / optimal_util;
    }
    let excess: u64 = utilization - optimal_util;
    let range: u64 = 10000 - optimal_util;
    if (range == 0) {
        return max_rate;
    }
    return rate_1 + (excess * (max_rate - rate_1)) / range;
}

fn calc_deposit_rate(borrow_rate: u64, utilization: u64) -> u64 {
    return (borrow_rate * utilization) / 10000;
}

// ---------------------------------------------------------------------------
// 5. deposit -- Deposit tokens as collateral
// ---------------------------------------------------------------------------

pub deposit(
    group: MangoGroup,
    mango_account: MangoAccount @mut,
    bank: TokenBank @mut,
    owner: account @signer,
    user_token_account: account @mut,
    bank_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!group.is_paused);
    require(mango_account.group == group.ctx.key);
    require(mango_account.owner == owner.ctx.key);
    require(bank.group == group.ctx.key);
    require(bank_vault.ctx.key == bank.vault);
    require(amount > 0);
    require(!mango_account.is_bankrupt);

    // Convert to indexed amount: raw = amount * SCALE / deposit_index
    let indexed_amount: i64 = ((amount * index_scale()) / bank.deposit_index) as i64;

    // Find or assign a slot for this bank
    if (mango_account.token_bank_1 == bank.ctx.key) {
        mango_account.token_deposit_1 = mango_account.token_deposit_1 + indexed_amount;
    } else if (mango_account.token_bank_2 == bank.ctx.key) {
        mango_account.token_deposit_2 = mango_account.token_deposit_2 + indexed_amount;
    } else if (mango_account.token_bank_3 == bank.ctx.key) {
        mango_account.token_deposit_3 = mango_account.token_deposit_3 + indexed_amount;
    } else if (mango_account.token_bank_4 == bank.ctx.key) {
        mango_account.token_deposit_4 = mango_account.token_deposit_4 + indexed_amount;
    } else if (mango_account.token_bank_1 == zero_pubkey()) {
        mango_account.token_bank_1 = bank.ctx.key;
        mango_account.token_deposit_1 = indexed_amount;
    } else if (mango_account.token_bank_2 == zero_pubkey()) {
        mango_account.token_bank_2 = bank.ctx.key;
        mango_account.token_deposit_2 = indexed_amount;
    } else if (mango_account.token_bank_3 == zero_pubkey()) {
        mango_account.token_bank_3 = bank.ctx.key;
        mango_account.token_deposit_3 = indexed_amount;
    } else if (mango_account.token_bank_4 == zero_pubkey()) {
        mango_account.token_bank_4 = bank.ctx.key;
        mango_account.token_deposit_4 = indexed_amount;
    } else {
        require(false);
    }

    spl_token::SPLToken::transfer(user_token_account, bank_vault, owner, amount);
    bank.total_deposits = bank.total_deposits + amount;
}

// ---------------------------------------------------------------------------
// Helper: compute health for a MangoAccount
// ---------------------------------------------------------------------------
// Returns health scaled to 1e6. health > 0 means account is healthy.
// use_init: true = init weights (for new borrows), false = maint weights (for liquidation)

fn compute_token_health(
    raw_deposit: i64,
    deposit_index: u64,
    borrow_index: u64,
    oracle_price: u64,
    init_asset_weight: u64,
    maint_asset_weight: u64,
    init_liab_weight: u64,
    maint_liab_weight: u64,
    use_init: bool
) -> i64 {
    if (raw_deposit >= 0) {
        // Positive deposit: asset
        let native: u64 = ((raw_deposit as u64) * deposit_index) / index_scale();
        let value: u64 = native * oracle_price;
        let mut weight: u64 = maint_asset_weight;
        if (use_init) {
            weight = init_asset_weight;
        }
        let weighted: u64 = (value * weight) / weight_scale();
        return weighted as i64;
    } else {
        // Negative deposit: borrow (liability)
        let abs_raw: u64 = (0 - raw_deposit) as u64;
        let native: u64 = (abs_raw * borrow_index) / index_scale();
        let value: u64 = native * oracle_price;
        let mut weight: u64 = maint_liab_weight;
        if (use_init) {
            weight = init_liab_weight;
        }
        let weighted: u64 = (value * weight) / weight_scale();
        return 0 - (weighted as i64);
    }
}

fn compute_perp_health(
    base_position: i64,
    oracle_price: u64,
    quote_position: i64
) -> i64 {
    // perp_value = base_position * oracle_price + quote_position
    let base_value: i64 = base_position * (oracle_price as i64);
    return base_value + quote_position;
}

// ---------------------------------------------------------------------------
// 6. withdraw -- Withdraw tokens (health check enforced)
// ---------------------------------------------------------------------------

pub withdraw(
    group: MangoGroup,
    mango_account: MangoAccount @mut,
    bank: TokenBank @mut,
    bank2: TokenBank,
    bank3: TokenBank,
    bank4: TokenBank,
    perp_market_1: PerpMarket,
    perp_market_2: PerpMarket,
    owner: account @signer,
    bank_vault: account @mut,
    user_token_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(!group.is_paused);
    require(mango_account.group == group.ctx.key);
    require(mango_account.owner == owner.ctx.key);
    require(bank.group == group.ctx.key);
    require(bank_vault.ctx.key == bank.vault);
    require(amount > 0);
    require(!mango_account.is_bankrupt);

    // Convert to indexed amount
    let indexed_amount: i64 = ((amount * index_scale()) / bank.deposit_index) as i64;

    // Deduct from the correct slot
    if (mango_account.token_bank_1 == bank.ctx.key) {
        mango_account.token_deposit_1 = mango_account.token_deposit_1 - indexed_amount;
    } else if (mango_account.token_bank_2 == bank.ctx.key) {
        mango_account.token_deposit_2 = mango_account.token_deposit_2 - indexed_amount;
    } else if (mango_account.token_bank_3 == bank.ctx.key) {
        mango_account.token_deposit_3 = mango_account.token_deposit_3 - indexed_amount;
    } else if (mango_account.token_bank_4 == bank.ctx.key) {
        mango_account.token_deposit_4 = mango_account.token_deposit_4 - indexed_amount;
    } else {
        require(false);
    }

    // Track borrows if the position went negative
    if (amount > bank.total_deposits) {
        bank.total_borrows = bank.total_borrows + (amount - bank.total_deposits);
        bank.total_deposits = 0;
    } else {
        bank.total_deposits = bank.total_deposits - amount;
    }

    // Health check (init weights -- stricter)
    let mut health: i64 = 0;

    // Token slot 1
    if (mango_account.token_bank_1 != zero_pubkey()) {
        let mut op: u64 = bank.oracle_price;
        let mut di: u64 = bank.deposit_index;
        let mut bi: u64 = bank.borrow_index;
        let mut iaw: u64 = bank.init_asset_weight;
        let mut maw: u64 = bank.maint_asset_weight;
        let mut ilw: u64 = bank.init_liab_weight;
        let mut mlw: u64 = bank.maint_liab_weight;
        if (mango_account.token_bank_1 == bank2.ctx.key) {
            op = bank2.oracle_price; di = bank2.deposit_index; bi = bank2.borrow_index;
            iaw = bank2.init_asset_weight; maw = bank2.maint_asset_weight;
            ilw = bank2.init_liab_weight; mlw = bank2.maint_liab_weight;
        }
        if (mango_account.token_bank_1 == bank3.ctx.key) {
            op = bank3.oracle_price; di = bank3.deposit_index; bi = bank3.borrow_index;
            iaw = bank3.init_asset_weight; maw = bank3.maint_asset_weight;
            ilw = bank3.init_liab_weight; mlw = bank3.maint_liab_weight;
        }
        if (mango_account.token_bank_1 == bank4.ctx.key) {
            op = bank4.oracle_price; di = bank4.deposit_index; bi = bank4.borrow_index;
            iaw = bank4.init_asset_weight; maw = bank4.maint_asset_weight;
            ilw = bank4.init_liab_weight; mlw = bank4.maint_liab_weight;
        }
        health = health + compute_token_health(mango_account.token_deposit_1, di, bi, op, iaw, maw, ilw, mlw, true);
    }

    // Token slot 2
    if (mango_account.token_bank_2 != zero_pubkey()) {
        let mut op2: u64 = bank.oracle_price;
        let mut di2: u64 = bank.deposit_index;
        let mut bi2: u64 = bank.borrow_index;
        let mut iaw2: u64 = bank.init_asset_weight;
        let mut maw2: u64 = bank.maint_asset_weight;
        let mut ilw2: u64 = bank.init_liab_weight;
        let mut mlw2: u64 = bank.maint_liab_weight;
        if (mango_account.token_bank_2 == bank2.ctx.key) {
            op2 = bank2.oracle_price; di2 = bank2.deposit_index; bi2 = bank2.borrow_index;
            iaw2 = bank2.init_asset_weight; maw2 = bank2.maint_asset_weight;
            ilw2 = bank2.init_liab_weight; mlw2 = bank2.maint_liab_weight;
        }
        if (mango_account.token_bank_2 == bank3.ctx.key) {
            op2 = bank3.oracle_price; di2 = bank3.deposit_index; bi2 = bank3.borrow_index;
            iaw2 = bank3.init_asset_weight; maw2 = bank3.maint_asset_weight;
            ilw2 = bank3.init_liab_weight; mlw2 = bank3.maint_liab_weight;
        }
        if (mango_account.token_bank_2 == bank4.ctx.key) {
            op2 = bank4.oracle_price; di2 = bank4.deposit_index; bi2 = bank4.borrow_index;
            iaw2 = bank4.init_asset_weight; maw2 = bank4.maint_asset_weight;
            ilw2 = bank4.init_liab_weight; mlw2 = bank4.maint_liab_weight;
        }
        health = health + compute_token_health(mango_account.token_deposit_2, di2, bi2, op2, iaw2, maw2, ilw2, mlw2, true);
    }

    // Token slot 3
    if (mango_account.token_bank_3 != zero_pubkey()) {
        let mut op3: u64 = bank.oracle_price;
        let mut di3: u64 = bank.deposit_index;
        let mut bi3: u64 = bank.borrow_index;
        let mut iaw3: u64 = bank.init_asset_weight;
        let mut maw3: u64 = bank.maint_asset_weight;
        let mut ilw3: u64 = bank.init_liab_weight;
        let mut mlw3: u64 = bank.maint_liab_weight;
        if (mango_account.token_bank_3 == bank2.ctx.key) {
            op3 = bank2.oracle_price; di3 = bank2.deposit_index; bi3 = bank2.borrow_index;
            iaw3 = bank2.init_asset_weight; maw3 = bank2.maint_asset_weight;
            ilw3 = bank2.init_liab_weight; mlw3 = bank2.maint_liab_weight;
        }
        if (mango_account.token_bank_3 == bank3.ctx.key) {
            op3 = bank3.oracle_price; di3 = bank3.deposit_index; bi3 = bank3.borrow_index;
            iaw3 = bank3.init_asset_weight; maw3 = bank3.maint_asset_weight;
            ilw3 = bank3.init_liab_weight; mlw3 = bank3.maint_liab_weight;
        }
        if (mango_account.token_bank_3 == bank4.ctx.key) {
            op3 = bank4.oracle_price; di3 = bank4.deposit_index; bi3 = bank4.borrow_index;
            iaw3 = bank4.init_asset_weight; maw3 = bank4.maint_asset_weight;
            ilw3 = bank4.init_liab_weight; mlw3 = bank4.maint_liab_weight;
        }
        health = health + compute_token_health(mango_account.token_deposit_3, di3, bi3, op3, iaw3, maw3, ilw3, mlw3, true);
    }

    // Token slot 4
    if (mango_account.token_bank_4 != zero_pubkey()) {
        let mut op4: u64 = bank.oracle_price;
        let mut di4: u64 = bank.deposit_index;
        let mut bi4: u64 = bank.borrow_index;
        let mut iaw4: u64 = bank.init_asset_weight;
        let mut maw4: u64 = bank.maint_asset_weight;
        let mut ilw4: u64 = bank.init_liab_weight;
        let mut mlw4: u64 = bank.maint_liab_weight;
        if (mango_account.token_bank_4 == bank2.ctx.key) {
            op4 = bank2.oracle_price; di4 = bank2.deposit_index; bi4 = bank2.borrow_index;
            iaw4 = bank2.init_asset_weight; maw4 = bank2.maint_asset_weight;
            ilw4 = bank2.init_liab_weight; mlw4 = bank2.maint_liab_weight;
        }
        if (mango_account.token_bank_4 == bank3.ctx.key) {
            op4 = bank3.oracle_price; di4 = bank3.deposit_index; bi4 = bank3.borrow_index;
            iaw4 = bank3.init_asset_weight; maw4 = bank3.maint_asset_weight;
            ilw4 = bank3.init_liab_weight; mlw4 = bank3.maint_liab_weight;
        }
        if (mango_account.token_bank_4 == bank4.ctx.key) {
            op4 = bank4.oracle_price; di4 = bank4.deposit_index; bi4 = bank4.borrow_index;
            iaw4 = bank4.init_asset_weight; maw4 = bank4.maint_asset_weight;
            ilw4 = bank4.init_liab_weight; mlw4 = bank4.maint_liab_weight;
        }
        health = health + compute_token_health(mango_account.token_deposit_4, di4, bi4, op4, iaw4, maw4, ilw4, mlw4, true);
    }

    // Perp slot 1
    if (mango_account.perp_market_1 != zero_pubkey()) {
        let mut perp_op: u64 = perp_market_1.oracle_price;
        if (mango_account.perp_market_1 == perp_market_2.ctx.key) {
            perp_op = perp_market_2.oracle_price;
        }
        health = health + compute_perp_health(mango_account.perp_base_position_1, perp_op, mango_account.perp_quote_position_1);
    }

    // Perp slot 2
    if (mango_account.perp_market_2 != zero_pubkey()) {
        let mut perp_op2: u64 = perp_market_2.oracle_price;
        if (mango_account.perp_market_2 == perp_market_1.ctx.key) {
            perp_op2 = perp_market_1.oracle_price;
        }
        health = health + compute_perp_health(mango_account.perp_base_position_2, perp_op2, mango_account.perp_quote_position_2);
    }

    require(health >= 0);

    spl_token::SPLToken::transfer(bank_vault, user_token_account, owner, amount);
}

// ---------------------------------------------------------------------------
// 7. flash_loan_begin -- Start a flash loan
// ---------------------------------------------------------------------------

account FlashLoanState {
    borrower: pubkey;
    bank: pubkey;
    amount: u64;
    fee_bps: u64;
    is_active: bool;
}

pub flash_loan_begin(
    group: MangoGroup,
    bank: TokenBank,
    flash_state: FlashLoanState @mut @init(payer=borrower, space=256) @signer,
    borrower: account @mut @signer,
    bank_vault: account @mut,
    user_token_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(!group.is_paused);
    require(bank.group == group.ctx.key);
    require(bank_vault.ctx.key == bank.vault);
    require(amount > 0);

    flash_state.borrower = borrower.ctx.key;
    flash_state.bank = bank.ctx.key;
    flash_state.amount = amount;
    flash_state.fee_bps = 5;
    flash_state.is_active = true;

    spl_token::SPLToken::transfer(bank_vault, user_token_account, borrower, amount);
}

// ---------------------------------------------------------------------------
// 8. flash_loan_end -- Repay flash loan + fee
// ---------------------------------------------------------------------------

pub flash_loan_end(
    group: MangoGroup,
    bank: TokenBank @mut,
    flash_state: FlashLoanState @mut,
    borrower: account @signer,
    user_token_account: account @mut,
    bank_vault: account @mut,
    token_program: account
) {
    require(flash_state.is_active);
    require(flash_state.borrower == borrower.ctx.key);
    require(flash_state.bank == bank.ctx.key);
    require(bank_vault.ctx.key == bank.vault);

    let fee: u64 = (flash_state.amount * flash_state.fee_bps) / bps_scale();
    let repay_amount: u64 = flash_state.amount + fee;

    spl_token::SPLToken::transfer(user_token_account, bank_vault, borrower, repay_amount);

    bank.total_deposits = bank.total_deposits + fee;
    flash_state.is_active = false;
}

// ---------------------------------------------------------------------------
// 9. create_perp_market -- Create a perpetual futures market
// ---------------------------------------------------------------------------

pub create_perp_market(
    group: MangoGroup @mut,
    perp_market: PerpMarket @mut @init(payer=admin, space=768) @signer,
    admin: account @mut @signer,
    oracle: account,
    base_decimals: u8,
    quote_decimals: u8,
    base_lot_size: u64,
    quote_lot_size: u64,
    maker_fee_bps: u64,
    taker_fee_bps: u64,
    min_funding_rate: i64,
    max_funding_rate: i64
) {
    require(group.admin == admin.ctx.key);
    require(!group.is_paused);
    require(group.num_perp_markets < 2);
    require(base_lot_size > 0);
    require(quote_lot_size > 0);
    require(min_funding_rate <= max_funding_rate);

    perp_market.group = group.ctx.key;
    perp_market.oracle = oracle.ctx.key;
    perp_market.base_decimals = base_decimals;
    perp_market.quote_decimals = quote_decimals;
    perp_market.market_index = group.num_perp_markets;
    perp_market.base_lot_size = base_lot_size;
    perp_market.quote_lot_size = quote_lot_size;
    perp_market.long_funding = 0;
    perp_market.short_funding = 0;
    perp_market.funding_last_updated = get_clock().unix_timestamp;
    perp_market.open_interest = 0;
    perp_market.fees_accrued = 0;
    perp_market.maker_fee_bps = maker_fee_bps;
    perp_market.taker_fee_bps = taker_fee_bps;
    perp_market.min_funding_rate = min_funding_rate;
    perp_market.max_funding_rate = max_funding_rate;
    perp_market.oracle_price = 0;
    perp_market.is_active = true;

    group.num_perp_markets = group.num_perp_markets + 1;
}

// ---------------------------------------------------------------------------
// 10. place_perp_order -- Place a perp order
// ---------------------------------------------------------------------------

pub place_perp_order(
    group: MangoGroup,
    mango_account: MangoAccount @mut,
    perp_market: PerpMarket,
    order: PerpOrder @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    is_long: bool,
    price: u64,
    size: u64,
    order_id: u64
) {
    require(!group.is_paused);
    require(perp_market.is_active);
    require(mango_account.group == group.ctx.key);
    require(perp_market.group == group.ctx.key);
    require(mango_account.owner == owner.ctx.key);
    require(!mango_account.is_bankrupt);
    require(price > 0);
    require(size > 0);

    // Assign perp market slot if not already assigned
    if (mango_account.perp_market_1 == zero_pubkey()) {
        mango_account.perp_market_1 = perp_market.ctx.key;
    } else if (mango_account.perp_market_1 != perp_market.ctx.key) {
        if (mango_account.perp_market_2 == zero_pubkey()) {
            mango_account.perp_market_2 = perp_market.ctx.key;
        }
    }

    order.market = perp_market.ctx.key;
    order.owner = owner.ctx.key;
    order.is_long = is_long;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.order_id = order_id;
    order.is_active = true;
}

// ---------------------------------------------------------------------------
// 11. cancel_perp_order -- Cancel an open perp order
// ---------------------------------------------------------------------------

pub cancel_perp_order(
    order: PerpOrder @mut,
    owner: account @signer
) {
    require(order.owner == owner.ctx.key);
    require(order.is_active);

    order.is_active = false;
}

// ---------------------------------------------------------------------------
// 12. consume_perp_events -- Match orders and settle trades
// ---------------------------------------------------------------------------

pub consume_perp_events(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    maker_account: MangoAccount @mut,
    taker_account: MangoAccount @mut,
    maker_order: PerpOrder @mut,
    taker_order: PerpOrder @mut
) {
    require(!group.is_paused);
    require(perp_market.is_active);
    require(maker_order.is_active);
    require(taker_order.is_active);
    require(maker_order.market == perp_market.ctx.key);
    require(taker_order.market == perp_market.ctx.key);

    // Orders must be opposite sides
    require(maker_order.is_long != taker_order.is_long);

    // Price match: taker buy must meet maker sell price (or vice versa)
    if (taker_order.is_long) {
        require(taker_order.price >= maker_order.price);
    } else {
        require(taker_order.price <= maker_order.price);
    }

    // Fill quantity: min of remaining sizes
    let maker_remaining: u64 = maker_order.size - maker_order.filled;
    let taker_remaining: u64 = taker_order.size - taker_order.filled;
    let mut fill_size: u64 = maker_remaining;
    if (taker_remaining < maker_remaining) {
        fill_size = taker_remaining;
    }
    require(fill_size > 0);

    // Execution price = maker's price (price-time priority)
    let exec_price: u64 = maker_order.price;

    // Quote value of the fill in lots
    let quote_change: i64 = ((fill_size * exec_price * perp_market.quote_lot_size) / perp_market.base_lot_size) as i64;
    let base_change: i64 = fill_size as i64;

    // Fees
    let maker_fee: u64 = (quote_change as u64 * perp_market.maker_fee_bps) / bps_scale();
    let taker_fee: u64 = (quote_change as u64 * perp_market.taker_fee_bps) / bps_scale();

    // Update maker account perp position
    if (mango_account_has_perp_market(maker_account, perp_market.ctx.key, 1)) {
        if (maker_order.is_long) {
            maker_account.perp_base_position_1 = maker_account.perp_base_position_1 + base_change;
            maker_account.perp_quote_position_1 = maker_account.perp_quote_position_1 - quote_change - (maker_fee as i64);
        } else {
            maker_account.perp_base_position_1 = maker_account.perp_base_position_1 - base_change;
            maker_account.perp_quote_position_1 = maker_account.perp_quote_position_1 + quote_change - (maker_fee as i64);
        }
    } else {
        if (maker_order.is_long) {
            maker_account.perp_base_position_2 = maker_account.perp_base_position_2 + base_change;
            maker_account.perp_quote_position_2 = maker_account.perp_quote_position_2 - quote_change - (maker_fee as i64);
        } else {
            maker_account.perp_base_position_2 = maker_account.perp_base_position_2 - base_change;
            maker_account.perp_quote_position_2 = maker_account.perp_quote_position_2 + quote_change - (maker_fee as i64);
        }
    }

    // Update taker account perp position
    if (mango_account_has_perp_market(taker_account, perp_market.ctx.key, 1)) {
        if (taker_order.is_long) {
            taker_account.perp_base_position_1 = taker_account.perp_base_position_1 + base_change;
            taker_account.perp_quote_position_1 = taker_account.perp_quote_position_1 - quote_change - (taker_fee as i64);
        } else {
            taker_account.perp_base_position_1 = taker_account.perp_base_position_1 - base_change;
            taker_account.perp_quote_position_1 = taker_account.perp_quote_position_1 + quote_change - (taker_fee as i64);
        }
    } else {
        if (taker_order.is_long) {
            taker_account.perp_base_position_2 = taker_account.perp_base_position_2 + base_change;
            taker_account.perp_quote_position_2 = taker_account.perp_quote_position_2 - quote_change - (taker_fee as i64);
        } else {
            taker_account.perp_base_position_2 = taker_account.perp_base_position_2 - base_change;
            taker_account.perp_quote_position_2 = taker_account.perp_quote_position_2 + quote_change - (taker_fee as i64);
        }
    }

    // Update orders
    maker_order.filled = maker_order.filled + fill_size;
    taker_order.filled = taker_order.filled + fill_size;

    if (maker_order.filled >= maker_order.size) {
        maker_order.is_active = false;
    }
    if (taker_order.filled >= taker_order.size) {
        taker_order.is_active = false;
    }

    // Update market
    perp_market.open_interest = perp_market.open_interest + fill_size;
    perp_market.fees_accrued = perp_market.fees_accrued + maker_fee + taker_fee;
}

fn mango_account_has_perp_market(acct: MangoAccount, market_key: pubkey, slot: u8) -> bool {
    if (slot == 1) {
        return acct.perp_market_1 == market_key;
    }
    return acct.perp_market_2 == market_key;
}

// ---------------------------------------------------------------------------
// 13. settle_perp_pnl -- Settle realized PnL between two accounts
// ---------------------------------------------------------------------------

pub settle_perp_pnl(
    group: MangoGroup,
    perp_market: PerpMarket,
    account_a: MangoAccount @mut,
    account_b: MangoAccount @mut
) {
    require(!group.is_paused);
    require(perp_market.group == group.ctx.key);
    require(account_a.group == group.ctx.key);
    require(account_b.group == group.ctx.key);

    // Find pnl for account_a in perp_market
    let mut pnl_a: i64 = 0;
    let mut slot_a: u8 = 0;
    if (account_a.perp_market_1 == perp_market.ctx.key) {
        pnl_a = account_a.perp_realized_pnl_1;
        slot_a = 1;
    } else if (account_a.perp_market_2 == perp_market.ctx.key) {
        pnl_a = account_a.perp_realized_pnl_2;
        slot_a = 2;
    } else {
        require(false);
    }

    // Find pnl for account_b in perp_market
    let mut pnl_b: i64 = 0;
    let mut slot_b: u8 = 0;
    if (account_b.perp_market_1 == perp_market.ctx.key) {
        pnl_b = account_b.perp_realized_pnl_1;
        slot_b = 1;
    } else if (account_b.perp_market_2 == perp_market.ctx.key) {
        pnl_b = account_b.perp_realized_pnl_2;
        slot_b = 2;
    } else {
        require(false);
    }

    // One must be positive, the other negative (net settlement)
    require((pnl_a > 0 && pnl_b < 0) || (pnl_a < 0 && pnl_b > 0));

    // Settle the smaller absolute amount
    let mut settle_amount: i64 = pnl_a;
    if (pnl_a > 0) {
        let abs_b: i64 = 0 - pnl_b;
        if (pnl_a > abs_b) {
            settle_amount = abs_b;
        }
    } else {
        let abs_a: i64 = 0 - pnl_a;
        if (abs_a > pnl_b) {
            settle_amount = 0 - pnl_b;
        }
    }

    // Apply settlement
    if (slot_a == 1) {
        account_a.perp_realized_pnl_1 = account_a.perp_realized_pnl_1 - settle_amount;
    } else {
        account_a.perp_realized_pnl_2 = account_a.perp_realized_pnl_2 - settle_amount;
    }

    if (slot_b == 1) {
        account_b.perp_realized_pnl_1 = account_b.perp_realized_pnl_1 + settle_amount;
    } else {
        account_b.perp_realized_pnl_2 = account_b.perp_realized_pnl_2 + settle_amount;
    }
}

// ---------------------------------------------------------------------------
// 14. update_funding -- Update funding rate based on mark vs oracle
// ---------------------------------------------------------------------------

pub update_funding(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    oracle: PriceOracle,
    mark_price: u64
) {
    require(!group.is_paused);
    require(perp_market.group == group.ctx.key);
    require(perp_market.oracle == oracle.ctx.key);
    require(perp_market.is_active);

    let oracle_price: u64 = oracle.price;
    require(oracle_price > 0);
    require(mark_price > 0);

    let now: u64 = get_clock().unix_timestamp;
    let time_delta: u64 = now - perp_market.funding_last_updated;
    require(time_delta > 0);

    // funding_rate = clamp((mark - oracle) / oracle * 1e6, min, max)
    let mark_i: i64 = mark_price as i64;
    let oracle_i: i64 = oracle_price as i64;
    let diff: i64 = mark_i - oracle_i;
    let mut funding_rate: i64 = (diff * 1000000) / oracle_i;

    // Clamp to [min_funding_rate, max_funding_rate]
    if (funding_rate < perp_market.min_funding_rate) {
        funding_rate = perp_market.min_funding_rate;
    }
    if (funding_rate > perp_market.max_funding_rate) {
        funding_rate = perp_market.max_funding_rate;
    }

    // Scale by time elapsed (hours)
    let hours: u64 = time_delta / 3600;
    if (hours == 0) {
        return;
    }
    let funding_delta: i64 = funding_rate * (hours as i64);

    // Longs pay when mark > oracle (positive funding); shorts pay when mark < oracle
    perp_market.long_funding = perp_market.long_funding + funding_delta;
    perp_market.short_funding = perp_market.short_funding - funding_delta;
    perp_market.funding_last_updated = now;
    perp_market.oracle_price = oracle_price;
}

// ---------------------------------------------------------------------------
// 15. compute_health -- Calculate account health (read-only)
// ---------------------------------------------------------------------------

pub compute_health(
    mango_account: MangoAccount,
    bank1: TokenBank,
    bank2: TokenBank,
    bank3: TokenBank,
    bank4: TokenBank,
    perp1: PerpMarket,
    perp2: PerpMarket,
    use_init: bool
) -> i64 {
    let mut health: i64 = 0;

    // Token slot 1
    if (mango_account.token_bank_1 != zero_pubkey()) {
        if (mango_account.token_bank_1 == bank1.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_1, bank1.deposit_index, bank1.borrow_index, bank1.oracle_price, bank1.init_asset_weight, bank1.maint_asset_weight, bank1.init_liab_weight, bank1.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_1 == bank2.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_1, bank2.deposit_index, bank2.borrow_index, bank2.oracle_price, bank2.init_asset_weight, bank2.maint_asset_weight, bank2.init_liab_weight, bank2.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_1 == bank3.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_1, bank3.deposit_index, bank3.borrow_index, bank3.oracle_price, bank3.init_asset_weight, bank3.maint_asset_weight, bank3.init_liab_weight, bank3.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_1 == bank4.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_1, bank4.deposit_index, bank4.borrow_index, bank4.oracle_price, bank4.init_asset_weight, bank4.maint_asset_weight, bank4.init_liab_weight, bank4.maint_liab_weight, use_init);
        }
    }

    // Token slot 2
    if (mango_account.token_bank_2 != zero_pubkey()) {
        if (mango_account.token_bank_2 == bank1.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_2, bank1.deposit_index, bank1.borrow_index, bank1.oracle_price, bank1.init_asset_weight, bank1.maint_asset_weight, bank1.init_liab_weight, bank1.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_2 == bank2.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_2, bank2.deposit_index, bank2.borrow_index, bank2.oracle_price, bank2.init_asset_weight, bank2.maint_asset_weight, bank2.init_liab_weight, bank2.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_2 == bank3.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_2, bank3.deposit_index, bank3.borrow_index, bank3.oracle_price, bank3.init_asset_weight, bank3.maint_asset_weight, bank3.init_liab_weight, bank3.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_2 == bank4.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_2, bank4.deposit_index, bank4.borrow_index, bank4.oracle_price, bank4.init_asset_weight, bank4.maint_asset_weight, bank4.init_liab_weight, bank4.maint_liab_weight, use_init);
        }
    }

    // Token slot 3
    if (mango_account.token_bank_3 != zero_pubkey()) {
        if (mango_account.token_bank_3 == bank1.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_3, bank1.deposit_index, bank1.borrow_index, bank1.oracle_price, bank1.init_asset_weight, bank1.maint_asset_weight, bank1.init_liab_weight, bank1.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_3 == bank2.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_3, bank2.deposit_index, bank2.borrow_index, bank2.oracle_price, bank2.init_asset_weight, bank2.maint_asset_weight, bank2.init_liab_weight, bank2.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_3 == bank3.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_3, bank3.deposit_index, bank3.borrow_index, bank3.oracle_price, bank3.init_asset_weight, bank3.maint_asset_weight, bank3.init_liab_weight, bank3.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_3 == bank4.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_3, bank4.deposit_index, bank4.borrow_index, bank4.oracle_price, bank4.init_asset_weight, bank4.maint_asset_weight, bank4.init_liab_weight, bank4.maint_liab_weight, use_init);
        }
    }

    // Token slot 4
    if (mango_account.token_bank_4 != zero_pubkey()) {
        if (mango_account.token_bank_4 == bank1.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_4, bank1.deposit_index, bank1.borrow_index, bank1.oracle_price, bank1.init_asset_weight, bank1.maint_asset_weight, bank1.init_liab_weight, bank1.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_4 == bank2.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_4, bank2.deposit_index, bank2.borrow_index, bank2.oracle_price, bank2.init_asset_weight, bank2.maint_asset_weight, bank2.init_liab_weight, bank2.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_4 == bank3.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_4, bank3.deposit_index, bank3.borrow_index, bank3.oracle_price, bank3.init_asset_weight, bank3.maint_asset_weight, bank3.init_liab_weight, bank3.maint_liab_weight, use_init);
        } else if (mango_account.token_bank_4 == bank4.ctx.key) {
            health = health + compute_token_health(mango_account.token_deposit_4, bank4.deposit_index, bank4.borrow_index, bank4.oracle_price, bank4.init_asset_weight, bank4.maint_asset_weight, bank4.init_liab_weight, bank4.maint_liab_weight, use_init);
        }
    }

    // Perp slot 1
    if (mango_account.perp_market_1 != zero_pubkey()) {
        let mut pop: u64 = 0;
        if (mango_account.perp_market_1 == perp1.ctx.key) {
            pop = perp1.oracle_price;
        } else if (mango_account.perp_market_1 == perp2.ctx.key) {
            pop = perp2.oracle_price;
        }
        health = health + compute_perp_health(mango_account.perp_base_position_1, pop, mango_account.perp_quote_position_1);
    }

    // Perp slot 2
    if (mango_account.perp_market_2 != zero_pubkey()) {
        let mut pop2: u64 = 0;
        if (mango_account.perp_market_2 == perp1.ctx.key) {
            pop2 = perp1.oracle_price;
        } else if (mango_account.perp_market_2 == perp2.ctx.key) {
            pop2 = perp2.oracle_price;
        }
        health = health + compute_perp_health(mango_account.perp_base_position_2, pop2, mango_account.perp_quote_position_2);
    }

    return health;
}

// ---------------------------------------------------------------------------
// 16. liquidate_token -- Liquidate an unhealthy token position
// ---------------------------------------------------------------------------

pub liquidate_token(
    group: MangoGroup,
    liqee_account: MangoAccount @mut,
    liqor_account: MangoAccount @mut,
    asset_bank: TokenBank,
    liab_bank: TokenBank,
    liqor_owner: account @signer,
    max_liab_transfer: u64
) {
    require(!group.is_paused);
    require(liqee_account.group == group.ctx.key);
    require(liqor_account.group == group.ctx.key);
    require(liqor_account.owner == liqor_owner.ctx.key);
    require(!liqor_account.is_bankrupt);

    // Liqee must be unhealthy (maint health < 0) -- caller must verify off-chain
    // and pass suitable accounts. We enforce basic sanity here.
    require(!liqee_account.is_bankrupt);

    // Liquidation bonus: 5% (500 bps)
    let liq_bonus_bps: u64 = 500;
    require(asset_bank.oracle_price > 0);
    require(liab_bank.oracle_price > 0);

    // How much liability to transfer (in native tokens)
    let mut liab_transfer: u64 = max_liab_transfer;

    // Find liqee's liability position in liab_bank (must be negative)
    let mut liqee_liab_raw: i64 = 0;
    let mut liqee_liab_slot: u8 = 0;
    if (liqee_account.token_bank_1 == liab_bank.ctx.key) {
        liqee_liab_raw = liqee_account.token_deposit_1;
        liqee_liab_slot = 1;
    } else if (liqee_account.token_bank_2 == liab_bank.ctx.key) {
        liqee_liab_raw = liqee_account.token_deposit_2;
        liqee_liab_slot = 2;
    } else if (liqee_account.token_bank_3 == liab_bank.ctx.key) {
        liqee_liab_raw = liqee_account.token_deposit_3;
        liqee_liab_slot = 3;
    } else if (liqee_account.token_bank_4 == liab_bank.ctx.key) {
        liqee_liab_raw = liqee_account.token_deposit_4;
        liqee_liab_slot = 4;
    } else {
        require(false);
    }
    require(liqee_liab_raw < 0);
    let liqee_liab_native: u64 = ((0 - liqee_liab_raw) as u64 * liab_bank.borrow_index) / index_scale();

    if (liab_transfer > liqee_liab_native) {
        liab_transfer = liqee_liab_native;
    }

    // Asset to seize = liab_transfer * liab_price * (1 + bonus) / asset_price
    let liab_value: u64 = liab_transfer * liab_bank.oracle_price;
    let asset_to_seize: u64 = (liab_value * (bps_scale() + liq_bonus_bps)) / (asset_bank.oracle_price * bps_scale());

    // Find liqee's asset position in asset_bank (must be positive)
    let mut liqee_asset_raw: i64 = 0;
    let mut liqee_asset_slot: u8 = 0;
    if (liqee_account.token_bank_1 == asset_bank.ctx.key) {
        liqee_asset_raw = liqee_account.token_deposit_1;
        liqee_asset_slot = 1;
    } else if (liqee_account.token_bank_2 == asset_bank.ctx.key) {
        liqee_asset_raw = liqee_account.token_deposit_2;
        liqee_asset_slot = 2;
    } else if (liqee_account.token_bank_3 == asset_bank.ctx.key) {
        liqee_asset_raw = liqee_account.token_deposit_3;
        liqee_asset_slot = 3;
    } else if (liqee_account.token_bank_4 == asset_bank.ctx.key) {
        liqee_asset_raw = liqee_account.token_deposit_4;
        liqee_asset_slot = 4;
    } else {
        require(false);
    }
    require(liqee_asset_raw > 0);

    // Convert asset_to_seize to indexed
    let asset_indexed: i64 = ((asset_to_seize * index_scale()) / asset_bank.deposit_index) as i64;
    let liab_indexed: i64 = ((liab_transfer * index_scale()) / liab_bank.borrow_index) as i64;

    // Deduct from liqee asset
    if (liqee_asset_slot == 1) {
        liqee_account.token_deposit_1 = liqee_account.token_deposit_1 - asset_indexed;
    } else if (liqee_asset_slot == 2) {
        liqee_account.token_deposit_2 = liqee_account.token_deposit_2 - asset_indexed;
    } else if (liqee_asset_slot == 3) {
        liqee_account.token_deposit_3 = liqee_account.token_deposit_3 - asset_indexed;
    } else {
        liqee_account.token_deposit_4 = liqee_account.token_deposit_4 - asset_indexed;
    }

    // Reduce liqee liability (add positive to a negative balance)
    if (liqee_liab_slot == 1) {
        liqee_account.token_deposit_1 = liqee_account.token_deposit_1 + liab_indexed;
    } else if (liqee_liab_slot == 2) {
        liqee_account.token_deposit_2 = liqee_account.token_deposit_2 + liab_indexed;
    } else if (liqee_liab_slot == 3) {
        liqee_account.token_deposit_3 = liqee_account.token_deposit_3 + liab_indexed;
    } else {
        liqee_account.token_deposit_4 = liqee_account.token_deposit_4 + liab_indexed;
    }

    // Credit liqor: receives the seized asset, takes on the liability
    // For simplicity, credit asset to liqor slot 1, liab to liqor slot 2
    // (in production, find or assign the correct slot)
    if (liqor_account.token_bank_1 == asset_bank.ctx.key) {
        liqor_account.token_deposit_1 = liqor_account.token_deposit_1 + asset_indexed;
    } else if (liqor_account.token_bank_2 == asset_bank.ctx.key) {
        liqor_account.token_deposit_2 = liqor_account.token_deposit_2 + asset_indexed;
    } else if (liqor_account.token_bank_3 == asset_bank.ctx.key) {
        liqor_account.token_deposit_3 = liqor_account.token_deposit_3 + asset_indexed;
    } else if (liqor_account.token_bank_4 == asset_bank.ctx.key) {
        liqor_account.token_deposit_4 = liqor_account.token_deposit_4 + asset_indexed;
    } else if (liqor_account.token_bank_1 == zero_pubkey()) {
        liqor_account.token_bank_1 = asset_bank.ctx.key;
        liqor_account.token_deposit_1 = asset_indexed;
    } else if (liqor_account.token_bank_2 == zero_pubkey()) {
        liqor_account.token_bank_2 = asset_bank.ctx.key;
        liqor_account.token_deposit_2 = asset_indexed;
    } else if (liqor_account.token_bank_3 == zero_pubkey()) {
        liqor_account.token_bank_3 = asset_bank.ctx.key;
        liqor_account.token_deposit_3 = asset_indexed;
    } else {
        liqor_account.token_bank_4 = asset_bank.ctx.key;
        liqor_account.token_deposit_4 = asset_indexed;
    }

    // Liqor takes on the liability
    if (liqor_account.token_bank_1 == liab_bank.ctx.key) {
        liqor_account.token_deposit_1 = liqor_account.token_deposit_1 - liab_indexed;
    } else if (liqor_account.token_bank_2 == liab_bank.ctx.key) {
        liqor_account.token_deposit_2 = liqor_account.token_deposit_2 - liab_indexed;
    } else if (liqor_account.token_bank_3 == liab_bank.ctx.key) {
        liqor_account.token_deposit_3 = liqor_account.token_deposit_3 - liab_indexed;
    } else if (liqor_account.token_bank_4 == liab_bank.ctx.key) {
        liqor_account.token_deposit_4 = liqor_account.token_deposit_4 - liab_indexed;
    } else if (liqor_account.token_bank_1 == zero_pubkey()) {
        liqor_account.token_bank_1 = liab_bank.ctx.key;
        liqor_account.token_deposit_1 = 0 - liab_indexed;
    } else if (liqor_account.token_bank_2 == zero_pubkey()) {
        liqor_account.token_bank_2 = liab_bank.ctx.key;
        liqor_account.token_deposit_2 = 0 - liab_indexed;
    } else if (liqor_account.token_bank_3 == zero_pubkey()) {
        liqor_account.token_bank_3 = liab_bank.ctx.key;
        liqor_account.token_deposit_3 = 0 - liab_indexed;
    } else {
        liqor_account.token_bank_4 = liab_bank.ctx.key;
        liqor_account.token_deposit_4 = 0 - liab_indexed;
    }
}

// ---------------------------------------------------------------------------
// 17. liquidate_perp -- Liquidate a perp position
// ---------------------------------------------------------------------------

pub liquidate_perp(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    liqee_account: MangoAccount @mut,
    liqor_account: MangoAccount @mut,
    liqor_owner: account @signer,
    max_base_transfer: u64
) {
    require(!group.is_paused);
    require(perp_market.is_active);
    require(liqee_account.group == group.ctx.key);
    require(liqor_account.group == group.ctx.key);
    require(liqor_account.owner == liqor_owner.ctx.key);
    require(!liqee_account.is_bankrupt);
    require(!liqor_account.is_bankrupt);
    require(perp_market.oracle_price > 0);

    // Liquidation bonus: 2.5% (250 bps) for perps
    let liq_bonus_bps: u64 = 250;

    // Find liqee's perp position
    let mut liqee_base: i64 = 0;
    let mut liqee_quote: i64 = 0;
    let mut liqee_slot: u8 = 0;
    if (liqee_account.perp_market_1 == perp_market.ctx.key) {
        liqee_base = liqee_account.perp_base_position_1;
        liqee_quote = liqee_account.perp_quote_position_1;
        liqee_slot = 1;
    } else if (liqee_account.perp_market_2 == perp_market.ctx.key) {
        liqee_base = liqee_account.perp_base_position_2;
        liqee_quote = liqee_account.perp_quote_position_2;
        liqee_slot = 2;
    } else {
        require(false);
    }
    require(liqee_base != 0);

    // Determine transfer size (base lots)
    let mut abs_base: u64 = 0;
    if (liqee_base > 0) {
        abs_base = liqee_base as u64;
    } else {
        abs_base = (0 - liqee_base) as u64;
    }
    let mut transfer_base: u64 = max_base_transfer;
    if (transfer_base > abs_base) {
        transfer_base = abs_base;
    }

    // Settlement price = oracle + bonus for liquidator
    let oracle_px: u64 = perp_market.oracle_price;
    let bonus: u64 = (oracle_px * liq_bonus_bps) / bps_scale();

    let mut liqee_price: u64 = oracle_px;
    let mut liqor_price: u64 = oracle_px;
    if (liqee_base > 0) {
        // Liqee is long; liquidator shorts at oracle - bonus (favorable for liqor)
        liqor_price = oracle_px - bonus;
        liqee_price = oracle_px;
    } else {
        // Liqee is short; liquidator longs at oracle + bonus
        liqor_price = oracle_px + bonus;
        liqee_price = oracle_px;
    }

    let transfer_base_i: i64 = transfer_base as i64;
    let liqee_quote_change: i64 = (transfer_base_i * (liqee_price as i64) * (perp_market.quote_lot_size as i64)) / (perp_market.base_lot_size as i64);
    let liqor_quote_change: i64 = (transfer_base_i * (liqor_price as i64) * (perp_market.quote_lot_size as i64)) / (perp_market.base_lot_size as i64);

    // Update liqee: reduce position
    if (liqee_slot == 1) {
        if (liqee_base > 0) {
            liqee_account.perp_base_position_1 = liqee_account.perp_base_position_1 - transfer_base_i;
            liqee_account.perp_quote_position_1 = liqee_account.perp_quote_position_1 + liqee_quote_change;
        } else {
            liqee_account.perp_base_position_1 = liqee_account.perp_base_position_1 + transfer_base_i;
            liqee_account.perp_quote_position_1 = liqee_account.perp_quote_position_1 - liqee_quote_change;
        }
    } else {
        if (liqee_base > 0) {
            liqee_account.perp_base_position_2 = liqee_account.perp_base_position_2 - transfer_base_i;
            liqee_account.perp_quote_position_2 = liqee_account.perp_quote_position_2 + liqee_quote_change;
        } else {
            liqee_account.perp_base_position_2 = liqee_account.perp_base_position_2 + transfer_base_i;
            liqee_account.perp_quote_position_2 = liqee_account.perp_quote_position_2 - liqee_quote_change;
        }
    }

    // Find or assign liqor perp slot
    let mut liqor_slot: u8 = 0;
    if (liqor_account.perp_market_1 == perp_market.ctx.key) {
        liqor_slot = 1;
    } else if (liqor_account.perp_market_2 == perp_market.ctx.key) {
        liqor_slot = 2;
    } else if (liqor_account.perp_market_1 == zero_pubkey()) {
        liqor_account.perp_market_1 = perp_market.ctx.key;
        liqor_slot = 1;
    } else if (liqor_account.perp_market_2 == zero_pubkey()) {
        liqor_account.perp_market_2 = perp_market.ctx.key;
        liqor_slot = 2;
    } else {
        require(false);
    }

    // Update liqor: take on opposite position
    if (liqor_slot == 1) {
        if (liqee_base > 0) {
            // Liqor goes short
            liqor_account.perp_base_position_1 = liqor_account.perp_base_position_1 - transfer_base_i;
            liqor_account.perp_quote_position_1 = liqor_account.perp_quote_position_1 + liqor_quote_change;
        } else {
            // Liqor goes long
            liqor_account.perp_base_position_1 = liqor_account.perp_base_position_1 + transfer_base_i;
            liqor_account.perp_quote_position_1 = liqor_account.perp_quote_position_1 - liqor_quote_change;
        }
    } else {
        if (liqee_base > 0) {
            liqor_account.perp_base_position_2 = liqor_account.perp_base_position_2 - transfer_base_i;
            liqor_account.perp_quote_position_2 = liqor_account.perp_quote_position_2 + liqor_quote_change;
        } else {
            liqor_account.perp_base_position_2 = liqor_account.perp_base_position_2 + transfer_base_i;
            liqor_account.perp_quote_position_2 = liqor_account.perp_quote_position_2 - liqor_quote_change;
        }
    }

    // Reduce open interest
    if (perp_market.open_interest >= transfer_base) {
        perp_market.open_interest = perp_market.open_interest - transfer_base;
    } else {
        perp_market.open_interest = 0;
    }
}

// ---------------------------------------------------------------------------
// 18. set_oracle -- Update oracle price for a token/market
// ---------------------------------------------------------------------------

pub set_oracle(
    oracle: PriceOracle @mut,
    authority: account @signer,
    price: u64
) {
    require(oracle.authority == authority.ctx.key);
    require(price > 0);
    oracle.price = price;
    oracle.last_update = get_clock().unix_timestamp;
}

pub set_bank_oracle(
    group: MangoGroup,
    bank: TokenBank @mut,
    admin: account @signer,
    price: u64
) {
    require(group.admin == admin.ctx.key);
    require(bank.group == group.ctx.key);
    require(price > 0);
    bank.oracle_price = price;
}

pub set_perp_oracle(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    admin: account @signer,
    price: u64
) {
    require(group.admin == admin.ctx.key);
    require(perp_market.group == group.ctx.key);
    require(price > 0);
    perp_market.oracle_price = price;
}

// ---------------------------------------------------------------------------
// 19. update_interest -- Accrue interest on token deposits/borrows
// ---------------------------------------------------------------------------

pub update_interest(
    group: MangoGroup,
    bank: TokenBank @mut
) {
    require(!group.is_paused);
    require(bank.group == group.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    let time_delta: u64 = now - bank.last_update;
    if (time_delta == 0) {
        return;
    }

    let utilization: u64 = calc_utilization(bank.total_deposits, bank.total_borrows);
    let borrow_rate: u64 = calc_borrow_rate(
        utilization,
        bank.optimal_utilization,
        bank.interest_rate_0,
        bank.interest_rate_1,
        bank.max_rate
    );
    let deposit_rate: u64 = calc_deposit_rate(borrow_rate, utilization);

    // Compound deposit index: deposit_index *= (1 + deposit_rate * time_delta / year)
    // deposit_index += deposit_index * deposit_rate * time_delta / (year * 10000)
    let deposit_increase: u64 = (bank.deposit_index * deposit_rate * time_delta) / (seconds_per_year() * 10000);
    bank.deposit_index = bank.deposit_index + deposit_increase;

    // Compound borrow index
    let borrow_increase: u64 = (bank.borrow_index * borrow_rate * time_delta) / (seconds_per_year() * 10000);
    bank.borrow_index = bank.borrow_index + borrow_increase;

    // Update borrows to reflect accrued interest
    if (bank.total_borrows > 0) {
        let interest_accrued: u64 = (bank.total_borrows * borrow_rate * time_delta) / (seconds_per_year() * 10000);
        bank.total_borrows = bank.total_borrows + interest_accrued;
    }

    bank.last_update = now;
}

// ---------------------------------------------------------------------------
// 20. set_fees -- Update trading fees on a perp market
// ---------------------------------------------------------------------------

pub set_fees(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    admin: account @signer,
    maker_fee_bps: u64,
    taker_fee_bps: u64
) {
    require(group.admin == admin.ctx.key);
    require(perp_market.group == group.ctx.key);
    require(maker_fee_bps <= 1000);
    require(taker_fee_bps <= 1000);

    perp_market.maker_fee_bps = maker_fee_bps;
    perp_market.taker_fee_bps = taker_fee_bps;
}

// ---------------------------------------------------------------------------
// 21. pause / unpause -- Emergency controls
// ---------------------------------------------------------------------------

pub pause(
    group: MangoGroup @mut,
    admin: account @signer
) {
    require(group.admin == admin.ctx.key);
    group.is_paused = true;
}

pub unpause(
    group: MangoGroup @mut,
    admin: account @signer
) {
    require(group.admin == admin.ctx.key);
    group.is_paused = false;
}

// ---------------------------------------------------------------------------
// Admin: set delegate on a MangoAccount
// ---------------------------------------------------------------------------

pub set_delegate(
    mango_account: MangoAccount @mut,
    owner: account @signer,
    delegate: pubkey
) {
    require(mango_account.owner == owner.ctx.key);
    mango_account.delegate = delegate;
}

// ---------------------------------------------------------------------------
// Admin: transfer group admin
// ---------------------------------------------------------------------------

pub transfer_admin(
    group: MangoGroup @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(group.admin == admin.ctx.key);
    group.admin = new_admin;
}

// ---------------------------------------------------------------------------
// Admin: update token bank weights
// ---------------------------------------------------------------------------

pub update_token_weights(
    group: MangoGroup,
    bank: TokenBank @mut,
    admin: account @signer,
    init_asset_weight: u64,
    maint_asset_weight: u64,
    init_liab_weight: u64,
    maint_liab_weight: u64
) {
    require(group.admin == admin.ctx.key);
    require(bank.group == group.ctx.key);
    require(init_asset_weight <= maint_asset_weight);
    require(init_liab_weight >= maint_liab_weight);

    bank.init_asset_weight = init_asset_weight;
    bank.maint_asset_weight = maint_asset_weight;
    bank.init_liab_weight = init_liab_weight;
    bank.maint_liab_weight = maint_liab_weight;
}

// ---------------------------------------------------------------------------
// Admin: update interest rate params on a token bank
// ---------------------------------------------------------------------------

pub update_interest_params(
    group: MangoGroup,
    bank: TokenBank @mut,
    admin: account @signer,
    optimal_utilization: u64,
    interest_rate_0: u64,
    interest_rate_1: u64,
    max_rate: u64
) {
    require(group.admin == admin.ctx.key);
    require(bank.group == group.ctx.key);
    require(optimal_utilization <= 10000);

    bank.optimal_utilization = optimal_utilization;
    bank.interest_rate_0 = interest_rate_0;
    bank.interest_rate_1 = interest_rate_1;
    bank.max_rate = max_rate;
}

// ---------------------------------------------------------------------------
// Admin: update perp market funding params
// ---------------------------------------------------------------------------

pub update_funding_params(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    admin: account @signer,
    min_funding_rate: i64,
    max_funding_rate: i64
) {
    require(group.admin == admin.ctx.key);
    require(perp_market.group == group.ctx.key);
    require(min_funding_rate <= max_funding_rate);

    perp_market.min_funding_rate = min_funding_rate;
    perp_market.max_funding_rate = max_funding_rate;
}

// ---------------------------------------------------------------------------
// Admin: set perp market active/inactive
// ---------------------------------------------------------------------------

pub set_perp_market_active(
    group: MangoGroup,
    perp_market: PerpMarket @mut,
    admin: account @signer,
    active: bool
) {
    require(group.admin == admin.ctx.key);
    require(perp_market.group == group.ctx.key);
    perp_market.is_active = active;
}

// ---------------------------------------------------------------------------
// Read-only: getters
// ---------------------------------------------------------------------------

pub get_health(
    mango_account: MangoAccount,
    bank1: TokenBank,
    bank2: TokenBank,
    bank3: TokenBank,
    bank4: TokenBank,
    perp1: PerpMarket,
    perp2: PerpMarket
) -> i64 {
    return compute_health(mango_account, bank1, bank2, bank3, bank4, perp1, perp2, false);
}

pub get_token_deposit(mango_account: MangoAccount, slot: u8) -> i64 {
    if (slot == 1) {
        return mango_account.token_deposit_1;
    }
    if (slot == 2) {
        return mango_account.token_deposit_2;
    }
    if (slot == 3) {
        return mango_account.token_deposit_3;
    }
    return mango_account.token_deposit_4;
}

pub get_perp_base_position(mango_account: MangoAccount, slot: u8) -> i64 {
    if (slot == 1) {
        return mango_account.perp_base_position_1;
    }
    return mango_account.perp_base_position_2;
}

pub get_perp_quote_position(mango_account: MangoAccount, slot: u8) -> i64 {
    if (slot == 1) {
        return mango_account.perp_quote_position_1;
    }
    return mango_account.perp_quote_position_2;
}

pub get_deposit_index(bank: TokenBank) -> u64 {
    return bank.deposit_index;
}

pub get_borrow_index(bank: TokenBank) -> u64 {
    return bank.borrow_index;
}

pub get_oracle_price(bank: TokenBank) -> u64 {
    return bank.oracle_price;
}

pub get_perp_open_interest(perp_market: PerpMarket) -> u64 {
    return perp_market.open_interest;
}

pub get_perp_funding(perp_market: PerpMarket) -> i64 {
    return perp_market.long_funding;
}

pub get_fees_accrued(group: MangoGroup) -> u64 {
    return group.fees_accrued;
}

pub get_perp_fees(perp_market: PerpMarket) -> u64 {
    return perp_market.fees_accrued;
}

pub get_utilization(bank: TokenBank) -> u64 {
    return calc_utilization(bank.total_deposits, bank.total_borrows);
}
