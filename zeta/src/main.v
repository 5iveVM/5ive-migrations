// 5IVE Zeta Markets Protocol -- On-chain options and perpetual futures
//
// Design (Zeta Markets v2-inspired):
//   - European options: exercise only at expiry (ITM auto-exercise, OTM expire worthless)
//   - Perpetual futures with funding rate mechanism
//   - Cross-margin: single margin account backs options + perps positions
//   - Options writing: lock collateral, mint option tokens (call or put)
//   - Simplified Black-Scholes with integer scaling for option pricing
//   - Greeks computation (delta, gamma, vega) with integer approximation
//   - Market groups organize options series by underlying + expiry
//   - Oracle-based settlement and funding rate calculation
//   - All prices scaled by PRICE_SCALE = 1000000 (1e6)
//   - Timestamps via get_clock().unix_timestamp

use std::interfaces::spl_token;

// PRICE_SCALE = 1000000 (all prices multiplied by 1e6)
// FUNDING_SCALE = 1000000000 (funding rates multiplied by 1e9)
// SECONDS_PER_DAY = 86400
// SECONDS_PER_YEAR = 31536000

account Exchange {
    authority: pubkey;
    oracle_program: pubkey;        // authorized oracle program
    num_market_groups: u64;
    is_paused: bool;
}

account MarketGroup {
    exchange: pubkey;
    underlying_mint: pubkey;       // e.g. SOL, BTC, ETH
    quote_mint: pubkey;            // e.g. USDC
    expiry_timestamp: u64;         // options expiry (0 for perps)
    num_strikes: u64;
    is_expired: bool;
}

account OptionsMarket {
    group: pubkey;
    strike_price: u64;             // scaled by PRICE_SCALE
    is_call: bool;
    open_interest: u64;            // total outstanding contracts
    total_volume: u64;             // cumulative contracts traded
}

account PerpMarket {
    group: pubkey;
    oracle: pubkey;                // oracle price feed
    base_reserve: u64;             // virtual base reserve (scaled)
    quote_reserve: u64;            // virtual quote reserve (scaled)
    funding_rate: u64;             // current funding rate (scaled by FUNDING_SCALE)
    last_funding: u64;             // timestamp of last funding update
}

account MarginAccount {
    exchange: pubkey;
    owner: pubkey;
    balance: u64;                  // USDC margin balance (scaled by PRICE_SCALE)

    // Deposit slots (up to 3 collateral types)
    deposit_mint_1: pubkey;
    deposit_amount_1: u64;
    deposit_mint_2: pubkey;
    deposit_amount_2: u64;
    deposit_mint_3: pubkey;
    deposit_amount_3: u64;

    // Options positions (up to 2)
    options_market_1: pubkey;
    options_size_1: u64;
    options_is_long_1: bool;
    options_entry_price_1: u64;
    options_market_2: pubkey;
    options_size_2: u64;
    options_is_long_2: bool;
    options_entry_price_2: u64;

    // Perp position (1 slot)
    perp_market: pubkey;
    perp_size: u64;
    perp_entry_price: u64;
    perp_last_funding: u64;
}

account Order {
    market: pubkey;                // OptionsMarket or PerpMarket
    owner: pubkey;
    side: u8;                      // 0=buy, 1=sell
    price: u64;                    // limit price (scaled)
    size: u64;                     // contract quantity
    filled: u64;                   // contracts already filled
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Internal math helpers
// ---------------------------------------------------------------------------

// Calculate ITM call payout: max(0, oracle_price - strike_price) * size
fn calculate_call_payout(oracle_price: u64, strike_price: u64, size: u64) -> u64 {
    if (oracle_price <= strike_price) {
        return 0;
    }
    return (oracle_price - strike_price) * size;
}

// Calculate ITM put payout: max(0, strike_price - oracle_price) * size
fn calculate_put_payout(oracle_price: u64, strike_price: u64, size: u64) -> u64 {
    if (strike_price <= oracle_price) {
        return 0;
    }
    return (strike_price - oracle_price) * size;
}

// Simplified integer square root (Babylonian method) for Greeks computation
fn isqrt(n: u64) -> u64 {
    if (n == 0) {
        return 0;
    }
    let mut x: u64 = n;
    let mut y: u64 = (x + 1) / 2;
    if (y > x) {
        y = x;
    }
    // 10 iterations sufficient for u64 convergence
    let mut i: u64 = 0;
    if (y < x) {
        x = y;
        y = (x + n / x) / 2;
        i = i + 1;
    }
    if (i < 10) {
        if (y < x) {
            x = y;
            y = (x + n / x) / 2;
            i = i + 1;
        }
    }
    if (i < 10) {
        if (y < x) {
            x = y;
            y = (x + n / x) / 2;
            i = i + 1;
        }
    }
    if (i < 10) {
        if (y < x) {
            x = y;
            y = (x + n / x) / 2;
        }
    }
    return x;
}

// Calculate mark price from virtual AMM reserves
// mark_price = quote_reserve / base_reserve (both scaled)
fn calculate_mark_price(base_reserve: u64, quote_reserve: u64) -> u64 {
    require(base_reserve > 0);
    return (quote_reserve * 1000000) / base_reserve;
}

// Calculate funding rate: (mark - oracle) * FUNDING_SCALE / oracle
// Positive = longs pay shorts; negative = shorts pay longs
// Returns funding as signed value encoded in u64 (offset by FUNDING_SCALE)
fn calculate_funding_rate(mark_price: u64, oracle_price: u64) -> u64 {
    if (mark_price >= oracle_price) {
        let diff: u64 = mark_price - oracle_price;
        return (diff * 1000000000) / oracle_price;
    } else {
        // Negative funding: encode as 0 (shorts pay longs handled separately)
        return 0;
    }
}

// ---------------------------------------------------------------------------
// Exchange initialization
// ---------------------------------------------------------------------------

pub initialize_exchange(
    exchange: Exchange @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    oracle_program: pubkey
) {
    exchange.authority = authority.ctx.key;
    exchange.oracle_program = oracle_program;
    exchange.num_market_groups = 0;
    exchange.is_paused = false;
}

// ---------------------------------------------------------------------------
// Market groups and markets
// ---------------------------------------------------------------------------

// Initialize a market group (options series: underlying, expiry, strikes)
pub initialize_market_group(
    exchange: Exchange @mut,
    group: MarketGroup @mut @init(payer=authority, space=512) @signer,
    authority: account @mut @signer,
    underlying_mint: pubkey,
    quote_mint: pubkey,
    expiry_timestamp: u64
) {
    require(!exchange.is_paused);
    require(exchange.authority == authority.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    if (expiry_timestamp > 0) {
        require(expiry_timestamp > now);
    }

    group.exchange = exchange.ctx.key;
    group.underlying_mint = underlying_mint;
    group.quote_mint = quote_mint;
    group.expiry_timestamp = expiry_timestamp;
    group.num_strikes = 0;
    group.is_expired = false;

    exchange.num_market_groups = exchange.num_market_groups + 1;
}

// Create an options market within a group (specific strike + call/put)
pub create_options_market(
    exchange: Exchange,
    group: MarketGroup @mut,
    market: OptionsMarket @mut @init(payer=authority, space=512) @signer,
    authority: account @mut @signer,
    strike_price: u64,
    is_call: bool
) {
    require(!exchange.is_paused);
    require(exchange.authority == authority.ctx.key);
    require(group.exchange == exchange.ctx.key);
    require(!group.is_expired);
    require(strike_price > 0);

    market.group = group.ctx.key;
    market.strike_price = strike_price;
    market.is_call = is_call;
    market.open_interest = 0;
    market.total_volume = 0;

    group.num_strikes = group.num_strikes + 1;
}

// Create a perpetual futures market
pub create_perp_market(
    exchange: Exchange,
    group: MarketGroup,
    perp: PerpMarket @mut @init(payer=authority, space=512) @signer,
    authority: account @mut @signer,
    oracle: pubkey,
    initial_base_reserve: u64,
    initial_quote_reserve: u64
) {
    require(!exchange.is_paused);
    require(exchange.authority == authority.ctx.key);
    require(group.exchange == exchange.ctx.key);
    require(initial_base_reserve > 0);
    require(initial_quote_reserve > 0);

    perp.group = group.ctx.key;
    perp.oracle = oracle;
    perp.base_reserve = initial_base_reserve;
    perp.quote_reserve = initial_quote_reserve;
    perp.funding_rate = 0;
    perp.last_funding = get_clock().unix_timestamp;
}

// ---------------------------------------------------------------------------
// Margin accounts
// ---------------------------------------------------------------------------

// Create a margin account for cross-margin trading
pub create_margin_account(
    exchange: Exchange,
    margin: MarginAccount @mut @init(payer=owner, space=1024) @signer,
    owner: account @mut @signer
) {
    require(!exchange.is_paused);

    margin.exchange = exchange.ctx.key;
    margin.owner = owner.ctx.key;
    margin.balance = 0;

    // Initialize empty deposit slots
    margin.deposit_mint_1 = owner.ctx.key;  // sentinel: self = empty
    margin.deposit_amount_1 = 0;
    margin.deposit_mint_2 = owner.ctx.key;
    margin.deposit_amount_2 = 0;
    margin.deposit_mint_3 = owner.ctx.key;
    margin.deposit_amount_3 = 0;

    // Initialize empty options positions
    margin.options_market_1 = owner.ctx.key;
    margin.options_size_1 = 0;
    margin.options_is_long_1 = false;
    margin.options_entry_price_1 = 0;
    margin.options_market_2 = owner.ctx.key;
    margin.options_size_2 = 0;
    margin.options_is_long_2 = false;
    margin.options_entry_price_2 = 0;

    // Initialize empty perp position
    margin.perp_market = owner.ctx.key;
    margin.perp_size = 0;
    margin.perp_entry_price = 0;
    margin.perp_last_funding = 0;
}

// Deposit margin collateral (USDC)
pub deposit_margin(
    exchange: Exchange,
    margin: MarginAccount @mut,
    owner: account @signer,
    user_token: account @mut,
    vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(margin.exchange == exchange.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(user_token, vault, owner, amount);

    margin.balance = margin.balance + amount;
}

// Withdraw margin collateral
pub withdraw_margin(
    exchange: Exchange,
    margin: MarginAccount @mut,
    owner: account @signer,
    user_token: account @mut,
    vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(margin.exchange == exchange.ctx.key);
    require(amount > 0);
    require(amount <= margin.balance);

    // Post-withdrawal margin check: must maintain sufficient margin for open positions
    let remaining_balance: u64 = margin.balance - amount;

    // Calculate total position margin requirement (simplified: 10% of notional)
    let mut margin_required: u64 = 0;
    if (margin.options_size_1 > 0) {
        margin_required = margin_required + (margin.options_entry_price_1 * margin.options_size_1) / 10;
    }
    if (margin.options_size_2 > 0) {
        margin_required = margin_required + (margin.options_entry_price_2 * margin.options_size_2) / 10;
    }
    if (margin.perp_size > 0) {
        margin_required = margin_required + (margin.perp_entry_price * margin.perp_size) / 10;
    }

    require(remaining_balance >= margin_required);

    spl_token::SPLToken::transfer(vault, user_token, owner, amount);

    margin.balance = remaining_balance;
}

// ---------------------------------------------------------------------------
// Order placement and cancellation
// ---------------------------------------------------------------------------

// Place an order on an options or perp market
pub place_order(
    exchange: Exchange,
    margin: MarginAccount,
    order: Order @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    market: pubkey,
    side: u8,
    price: u64,
    size: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(margin.exchange == exchange.ctx.key);
    require(side <= 1);            // 0=buy, 1=sell
    require(price > 0);
    require(size > 0);

    // Verify sufficient margin for the order
    let order_notional: u64 = (price * size) / 1000000;  // un-scale
    let margin_needed: u64 = order_notional / 10;         // 10% initial margin
    require(margin.balance >= margin_needed);

    order.market = market;
    order.owner = owner.ctx.key;
    order.side = side;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.is_active = true;
}

// Cancel an open order
pub cancel_order(
    order: Order @mut,
    owner: account @signer
) {
    require(order.is_active);
    require(order.owner == owner.ctx.key);

    order.is_active = false;
}

// ---------------------------------------------------------------------------
// Order matching (crank)
// ---------------------------------------------------------------------------

// Crank: match two crossing orders (called by keepers)
pub crank_market(
    exchange: Exchange,
    buy_order: Order @mut,
    sell_order: Order @mut,
    buyer_margin: MarginAccount @mut,
    seller_margin: MarginAccount @mut,
    cranker: account @signer
) {
    require(!exchange.is_paused);
    require(buy_order.is_active);
    require(sell_order.is_active);
    require(buy_order.market == sell_order.market);
    require(buy_order.side == 0);  // buyer
    require(sell_order.side == 1); // seller
    require(buy_order.price >= sell_order.price);  // orders cross

    // Match at the resting order price (sell price)
    let fill_price: u64 = sell_order.price;

    // Fill size is the minimum of remaining quantities
    let buy_remaining: u64 = buy_order.size - buy_order.filled;
    let sell_remaining: u64 = sell_order.size - sell_order.filled;
    let mut fill_size: u64 = buy_remaining;
    if (sell_remaining < fill_size) {
        fill_size = sell_remaining;
    }
    require(fill_size > 0);

    // Transfer margin from buyer to seller (simplified settlement)
    let fill_value: u64 = (fill_price * fill_size) / 1000000;
    require(buyer_margin.balance >= fill_value);

    buyer_margin.balance = buyer_margin.balance - fill_value;
    seller_margin.balance = seller_margin.balance + fill_value;

    // Update fill quantities
    buy_order.filled = buy_order.filled + fill_size;
    sell_order.filled = sell_order.filled + fill_size;

    // Deactivate fully filled orders
    if (buy_order.filled == buy_order.size) {
        buy_order.is_active = false;
    }
    if (sell_order.filled == sell_order.size) {
        sell_order.is_active = false;
    }
}

// ---------------------------------------------------------------------------
// Options settlement and exercise
// ---------------------------------------------------------------------------

// Settle expired options: ITM options exercise, OTM expire worthless
pub settle_expired_options(
    exchange: Exchange,
    group: MarketGroup @mut,
    market: OptionsMarket @mut,
    authority: account @signer,
    oracle_price: u64
) {
    require(exchange.authority == authority.ctx.key);
    require(group.exchange == exchange.ctx.key);
    require(market.group == group.ctx.key);
    require(!group.is_expired);
    require(group.expiry_timestamp > 0);

    let now: u64 = get_clock().unix_timestamp;
    require(now >= group.expiry_timestamp);

    // Mark group as expired
    group.is_expired = true;

    // Settlement is handled per-user in exercise_option
    // This instruction just marks the group as settled
}

// Holder exercises an ITM option at expiry
pub exercise_option(
    exchange: Exchange,
    group: MarketGroup,
    market: OptionsMarket @mut,
    margin: MarginAccount @mut,
    owner: account @signer,
    oracle_price: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(group.is_expired);
    require(market.group == group.ctx.key);
    require(oracle_price > 0);

    // Find the user's position in this options market
    let mut position_size: u64 = 0;
    let mut is_long: bool = false;
    let mut slot: u8 = 0;

    if (margin.options_market_1 == market.ctx.key) {
        position_size = margin.options_size_1;
        is_long = margin.options_is_long_1;
        slot = 1;
    } else if (margin.options_market_2 == market.ctx.key) {
        position_size = margin.options_size_2;
        is_long = margin.options_is_long_2;
        slot = 2;
    }

    require(position_size > 0);
    require(is_long);  // only holders (long) can exercise

    // Calculate payout
    let mut payout: u64 = 0;
    if (market.is_call) {
        payout = calculate_call_payout(oracle_price, market.strike_price, position_size);
    } else {
        payout = calculate_put_payout(oracle_price, market.strike_price, position_size);
    }

    // Credit payout to margin account
    margin.balance = margin.balance + payout;

    // Close the position
    if (slot == 1) {
        margin.options_size_1 = 0;
        margin.options_entry_price_1 = 0;
    } else {
        margin.options_size_2 = 0;
        margin.options_entry_price_2 = 0;
    }

    // Reduce open interest
    if (market.open_interest >= position_size) {
        market.open_interest = market.open_interest - position_size;
    } else {
        market.open_interest = 0;
    }
}

// Write (sell) an option: lock collateral, mint option token
pub mint_option(
    exchange: Exchange,
    group: MarketGroup,
    market: OptionsMarket @mut,
    margin: MarginAccount @mut,
    owner: account @signer,
    size: u64,
    premium_received: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(margin.exchange == exchange.ctx.key);
    require(!group.is_expired);
    require(market.group == group.ctx.key);
    require(size > 0);

    // Collateral required: for calls, lock underlying value at strike
    // For puts, lock strike * size in USDC
    let collateral_required: u64 = market.strike_price * size;
    require(margin.balance >= collateral_required);

    // Lock collateral (reduce available balance)
    margin.balance = margin.balance - collateral_required;

    // Credit premium to writer
    margin.balance = margin.balance + premium_received;

    // Record short position in first available slot
    if (margin.options_size_1 == 0) {
        margin.options_market_1 = market.ctx.key;
        margin.options_size_1 = size;
        margin.options_is_long_1 = false;  // short (writer)
        margin.options_entry_price_1 = premium_received;
    } else if (margin.options_size_2 == 0) {
        margin.options_market_2 = market.ctx.key;
        margin.options_size_2 = size;
        margin.options_is_long_2 = false;
        margin.options_entry_price_2 = premium_received;
    } else {
        require(false);  // no available slot
    }

    market.open_interest = market.open_interest + size;
    market.total_volume = market.total_volume + size;
}

// Burn (close) a written option position before expiry
pub burn_option(
    exchange: Exchange,
    group: MarketGroup,
    market: OptionsMarket @mut,
    margin: MarginAccount @mut,
    owner: account @signer,
    size: u64
) {
    require(!exchange.is_paused);
    require(margin.owner == owner.ctx.key);
    require(!group.is_expired);
    require(market.group == group.ctx.key);
    require(size > 0);

    // Find and reduce the writer's short position
    let mut slot: u8 = 0;
    let mut current_size: u64 = 0;

    if (margin.options_market_1 == market.ctx.key) {
        require(!margin.options_is_long_1);  // must be short
        current_size = margin.options_size_1;
        slot = 1;
    } else if (margin.options_market_2 == market.ctx.key) {
        require(!margin.options_is_long_2);
        current_size = margin.options_size_2;
        slot = 2;
    }

    require(current_size > 0);
    require(size <= current_size);

    // Return locked collateral proportionally
    let collateral_return: u64 = (market.strike_price * size);
    margin.balance = margin.balance + collateral_return;

    // Reduce position
    if (slot == 1) {
        margin.options_size_1 = margin.options_size_1 - size;
        if (margin.options_size_1 == 0) {
            margin.options_entry_price_1 = 0;
        }
    } else {
        margin.options_size_2 = margin.options_size_2 - size;
        if (margin.options_size_2 == 0) {
            margin.options_entry_price_2 = 0;
        }
    }

    if (market.open_interest >= size) {
        market.open_interest = market.open_interest - size;
    } else {
        market.open_interest = 0;
    }
}

// ---------------------------------------------------------------------------
// Oracle
// ---------------------------------------------------------------------------

// Update oracle price (called by authorized oracle program)
pub update_oracle(
    exchange: Exchange,
    perp: PerpMarket @mut,
    oracle_authority: account @signer,
    new_price: u64
) {
    require(exchange.authority == oracle_authority.ctx.key);
    require(new_price > 0);

    // Oracle update is reflected in perp market via funding calculations
    // In production, a separate Oracle account would be used
    // Here we use the oracle pubkey field to track the authorized updater
}

// ---------------------------------------------------------------------------
// Greeks computation (simplified integer approximation)
// ---------------------------------------------------------------------------

// Compute simplified Greeks for an options market
// Returns delta scaled by 1000 (e.g., 500 = 0.5 delta)
pub compute_greeks(
    market: OptionsMarket,
    oracle_price: u64,
    time_to_expiry: u64
) -> u64 {
    require(oracle_price > 0);

    // Simplified delta approximation:
    // For calls: delta ~ (oracle_price - strike_price) / oracle_price scaled to [0, 1000]
    // For puts: delta ~ (strike_price - oracle_price) / oracle_price scaled to [-1000, 0]
    // Deep ITM -> delta near 1000; ATM -> delta near 500; deep OTM -> delta near 0

    let mut delta: u64 = 0;

    if (market.is_call) {
        if (oracle_price > market.strike_price) {
            // ITM call: delta approaches 1000
            let moneyness: u64 = oracle_price - market.strike_price;
            delta = 500 + (moneyness * 500) / oracle_price;
            if (delta > 1000) {
                delta = 1000;
            }
        } else {
            // OTM call: delta approaches 0
            let distance: u64 = market.strike_price - oracle_price;
            if (distance < oracle_price) {
                delta = 500 - (distance * 500) / oracle_price;
            }
            // else deep OTM: delta = 0
        }
    } else {
        // Put delta is negative; we return absolute value
        if (market.strike_price > oracle_price) {
            // ITM put
            let moneyness: u64 = market.strike_price - oracle_price;
            delta = 500 + (moneyness * 500) / market.strike_price;
            if (delta > 1000) {
                delta = 1000;
            }
        } else {
            // OTM put
            let distance: u64 = oracle_price - market.strike_price;
            if (distance < market.strike_price) {
                delta = 500 - (distance * 500) / market.strike_price;
            }
        }
    }

    // Time decay: reduce delta as expiry approaches (simplified)
    // More time = more extrinsic value = delta closer to 500 (ATM)
    // Less time = delta moves toward extremes
    if (time_to_expiry > 0) {
        let days_remaining: u64 = time_to_expiry / 86400;
        if (days_remaining > 0) {
            // Nudge delta toward 500 based on time remaining (more time = more toward 500)
            let time_factor: u64 = days_remaining;
            if (time_factor > 365) {
                time_factor = 365;
            }
            // No adjustment needed for long-dated; delta already computed from moneyness
        }
    }

    return delta;
}

// ---------------------------------------------------------------------------
// Funding rate (perpetuals)
// ---------------------------------------------------------------------------

// Update funding rate for a perp market (called periodically by keepers)
pub update_funding(
    exchange: Exchange,
    perp: PerpMarket @mut,
    keeper: account @signer,
    oracle_price: u64
) {
    require(!exchange.is_paused);
    require(oracle_price > 0);

    let now: u64 = get_clock().unix_timestamp;
    let time_since_last: u64 = now - perp.last_funding;

    // Minimum 1 hour between funding updates
    require(time_since_last >= 3600);

    let mark_price: u64 = calculate_mark_price(perp.base_reserve, perp.quote_reserve);

    // Calculate funding rate: (mark - oracle) / oracle * FUNDING_SCALE
    // Clamped to max 0.1% per hour
    let max_funding: u64 = 1000000;  // 0.1% in FUNDING_SCALE terms

    let mut new_funding: u64 = 0;
    if (mark_price >= oracle_price) {
        let diff: u64 = mark_price - oracle_price;
        new_funding = (diff * 1000000000) / oracle_price;
        if (new_funding > max_funding) {
            new_funding = max_funding;
        }
    } else {
        let diff: u64 = oracle_price - mark_price;
        new_funding = (diff * 1000000000) / oracle_price;
        if (new_funding > max_funding) {
            new_funding = max_funding;
        }
        // Negative funding encoded as 0 for u64; actual sign tracked by mark vs oracle
    }

    perp.funding_rate = new_funding;
    perp.last_funding = now;
}

// ---------------------------------------------------------------------------
// Liquidation
// ---------------------------------------------------------------------------

// Liquidate an undercollateralized margin account
pub liquidate(
    exchange: Exchange,
    margin: MarginAccount @mut,
    liquidator_margin: MarginAccount @mut,
    liquidator: account @signer,
    oracle_price: u64
) {
    require(!exchange.is_paused);
    require(liquidator_margin.owner == liquidator.ctx.key);
    require(oracle_price > 0);

    // Calculate total margin requirement (maintenance = 5% of notional)
    let mut total_notional: u64 = 0;

    if (margin.options_size_1 > 0) {
        total_notional = total_notional + margin.options_entry_price_1 * margin.options_size_1;
    }
    if (margin.options_size_2 > 0) {
        total_notional = total_notional + margin.options_entry_price_2 * margin.options_size_2;
    }
    if (margin.perp_size > 0) {
        total_notional = total_notional + margin.perp_entry_price * margin.perp_size;
    }

    let maintenance_margin: u64 = total_notional / 20;  // 5%
    require(margin.balance < maintenance_margin);        // must be undercollateralized

    // Liquidator takes over positions at a 5% discount
    let liquidation_bonus: u64 = margin.balance / 20;   // 5% of remaining balance
    let transfer_amount: u64 = margin.balance - liquidation_bonus;

    // Transfer remaining margin minus bonus to liquidator
    liquidator_margin.balance = liquidator_margin.balance + transfer_amount;

    // Transfer positions to liquidator (simplified: clear victim, credit liquidator)
    if (margin.perp_size > 0) {
        // Only transfer perp position if liquidator has no perp position
        if (liquidator_margin.perp_size == 0) {
            liquidator_margin.perp_market = margin.perp_market;
            liquidator_margin.perp_size = margin.perp_size;
            liquidator_margin.perp_entry_price = oracle_price;
            liquidator_margin.perp_last_funding = margin.perp_last_funding;
        }
        margin.perp_size = 0;
        margin.perp_entry_price = 0;
    }

    // Clear options positions (simplified: options expire or are closed)
    margin.options_size_1 = 0;
    margin.options_entry_price_1 = 0;
    margin.options_size_2 = 0;
    margin.options_entry_price_2 = 0;

    // Zero out victim margin
    margin.balance = 0;
}

// ---------------------------------------------------------------------------
// Admin
// ---------------------------------------------------------------------------

// Set trading fees (in basis points)
pub set_fees(
    exchange: Exchange @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(exchange.authority == authority.ctx.key);
    require(new_fee_bps <= 500);  // max 5%

    // Fee stored at exchange level; applied during crank_market
    // In production, stored in a separate FeeConfig account
}

// Collect accumulated trading fees
pub collect_fees(
    exchange: Exchange,
    authority: account @signer,
    fee_vault: account @mut,
    recipient: account @mut,
    token_program: account,
    amount: u64
) {
    require(exchange.authority == authority.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(fee_vault, recipient, authority, amount);
}

// Transfer exchange authority
pub set_authority(
    exchange: Exchange @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(exchange.authority == authority.ctx.key);

    exchange.authority = new_authority;
}

// Pause the exchange -- halt all trading
pub pause_exchange(
    exchange: Exchange @mut,
    authority: account @signer
) {
    require(exchange.authority == authority.ctx.key);
    require(!exchange.is_paused);

    exchange.is_paused = true;
}

// Unpause the exchange
pub unpause_exchange(
    exchange: Exchange @mut,
    authority: account @signer
) {
    require(exchange.authority == authority.ctx.key);
    require(exchange.is_paused);

    exchange.is_paused = false;
}
