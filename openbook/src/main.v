// 5IVE OpenBook (Serum v2) -- Central Limit Order Book
//
// OpenBook is the OG Solana order book. Self-custodial central limit order book
// where every trade matches on-chain. Users maintain OpenOrders accounts that
// track their free and locked base/quote balances. A crank mechanism
// (match_orders + consume_events) processes fills asynchronously.
//
// Key mechanics:
//   - Bids and asks stored in separate on-chain accounts (red-black tree off-chain,
//     simplified here as account-level tracking)
//   - Order types: limit, immediate-or-cancel (IOC), post-only
//   - Settlement: matched funds move to OpenOrders free balances, then settle_funds
//     transfers to user wallets
//   - Crank: permissionless match_orders + consume_events calls
//   - Fees: maker/taker fee model with configurable rates
//   - Market authority controls fee rates, pruning, and market lifecycle
//
// Precision:
//   - Prices in ticks (price = tick * tick_size)
//   - Sizes in lots (size = lots * min_order_size)
//   - Fees in basis points (1 bps = 0.01%)
//   - FEE_DENOMINATOR = 10000

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Market {
    base_mint: pubkey;
    quote_mint: pubkey;
    base_vault: pubkey;
    quote_vault: pubkey;
    bids_account: pubkey;            // PDA/account tracking bid orders
    asks_account: pubkey;            // PDA/account tracking ask orders
    event_queue: pubkey;             // Event queue for crank processing
    min_order_size: u64;             // Minimum order size in base lots
    tick_size: u64;                  // Minimum price increment
    maker_fee_bps: u64;             // Maker fee in basis points
    taker_fee_bps: u64;             // Taker fee in basis points
    collected_fees_base: u64;        // Accumulated base fees
    collected_fees_quote: u64;       // Accumulated quote fees
    authority: pubkey;               // Market authority (admin)
    next_order_id: u64;              // Monotonic order ID counter
    is_disabled: bool;               // Market kill switch
}

account OpenOrders {
    market: pubkey;                  // Parent market
    owner: pubkey;                   // Owner wallet
    base_free: u64;                  // Base tokens available for withdrawal
    base_locked: u64;               // Base tokens locked in open orders
    quote_free: u64;                 // Quote tokens available for withdrawal
    quote_locked: u64;              // Quote tokens locked in open orders
    num_orders: u32;                 // Count of active orders
}

account Order {
    market: pubkey;
    owner: pubkey;                   // OpenOrders account key
    side: u8;                        // 0 = bid, 1 = ask
    price: u64;                      // Price in ticks
    size: u64;                       // Original size in base lots
    filled: u64;                     // Filled amount in base lots
    order_id: u64;                   // Unique order ID (market-assigned)
    client_order_id: u64;           // Client-specified ID for lookup
    order_type: u8;                  // 0 = limit, 1 = IOC, 2 = post_only
    timestamp: u64;                  // Slot placed
    is_active: bool;                 // Whether order is still live
}

account EventNode {
    event_type: u8;                  // 0 = fill, 1 = out (cancel/expire)
    maker: pubkey;                   // Maker OpenOrders account
    taker: pubkey;                   // Taker OpenOrders account
    price: u64;                      // Fill price in ticks
    size: u64;                       // Fill size in base lots
    timestamp: u64;                  // Slot of event
    is_consumed: bool;               // Whether event has been cranked
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
// FEE_DENOMINATOR = 10000
// SIDE_BID = 0, SIDE_ASK = 1
// ORDER_LIMIT = 0, ORDER_IOC = 1, ORDER_POST_ONLY = 2

// ---------------------------------------------------------------------------
// Market Lifecycle
// ---------------------------------------------------------------------------

pub create_market(
    market: Market @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    base_mint: pubkey,
    quote_mint: pubkey,
    base_vault: pubkey,
    quote_vault: pubkey,
    bids_account: pubkey,
    asks_account: pubkey,
    event_queue: pubkey,
    min_order_size: u64,
    tick_size: u64,
    maker_fee_bps: u64,
    taker_fee_bps: u64
) {
    require(min_order_size > 0);
    require(tick_size > 0);
    require(maker_fee_bps <= 1000);       // Max 10%
    require(taker_fee_bps <= 1000);
    require(base_mint != quote_mint);

    market.base_mint = base_mint;
    market.quote_mint = quote_mint;
    market.base_vault = base_vault;
    market.quote_vault = quote_vault;
    market.bids_account = bids_account;
    market.asks_account = asks_account;
    market.event_queue = event_queue;
    market.min_order_size = min_order_size;
    market.tick_size = tick_size;
    market.maker_fee_bps = maker_fee_bps;
    market.taker_fee_bps = taker_fee_bps;
    market.collected_fees_base = 0;
    market.collected_fees_quote = 0;
    market.authority = creator.ctx.key;
    market.next_order_id = 1;
    market.is_disabled = false;
}

pub set_market_authority(
    market: Market @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(market.authority == authority.ctx.key);
    market.authority = new_authority;
}

pub set_fee_rates(
    market: Market @mut,
    authority: account @signer,
    new_maker_fee_bps: u64,
    new_taker_fee_bps: u64
) {
    require(market.authority == authority.ctx.key);
    require(new_maker_fee_bps <= 1000);
    require(new_taker_fee_bps <= 1000);
    market.maker_fee_bps = new_maker_fee_bps;
    market.taker_fee_bps = new_taker_fee_bps;
}

pub disable_market(
    market: Market @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    market.is_disabled = true;
}

pub close_market(
    market: Market @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(market.is_disabled);
    // All open orders must be cancelled and settled before closing
    require(market.collected_fees_base == 0);
    require(market.collected_fees_quote == 0);
    // Mark fully closed -- in production, reclaim rent
    market.next_order_id = 0;
}

// ---------------------------------------------------------------------------
// Open Orders Account Management
// ---------------------------------------------------------------------------

pub init_open_orders(
    open_orders: OpenOrders @mut @init(payer=owner, space=512),
    market: Market,
    owner: account @mut @signer
) {
    require(!market.is_disabled);

    open_orders.market = market.ctx.key;
    open_orders.owner = owner.ctx.key;
    open_orders.base_free = 0;
    open_orders.base_locked = 0;
    open_orders.quote_free = 0;
    open_orders.quote_locked = 0;
    open_orders.num_orders = 0;
}

pub close_open_orders(
    open_orders: OpenOrders @mut,
    owner: account @signer
) {
    require(open_orders.owner == owner.ctx.key);
    require(open_orders.num_orders == 0);
    require(open_orders.base_free == 0);
    require(open_orders.base_locked == 0);
    require(open_orders.quote_free == 0);
    require(open_orders.quote_locked == 0);
    // Account closed -- rent reclaimable in production
}

// ---------------------------------------------------------------------------
// Order Placement
// ---------------------------------------------------------------------------

// place_order: unified entry for limit/IOC/post_only orders
pub place_order(
    market: Market @mut @signer,
    open_orders: OpenOrders @mut,
    order: Order @mut @init(payer=owner, space=512),
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    owner: account @mut @signer,
    token_program: account,
    side: u8,
    price: u64,
    size: u64,
    order_type: u8,
    client_order_id: u64
) {
    require(!market.is_disabled);
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);
    require(side <= 1);                    // 0 = bid, 1 = ask
    require(order_type <= 2);              // 0 = limit, 1 = IOC, 2 = post_only
    require(price > 0);
    require(size >= market.min_order_size);
    require(price % market.tick_size == 0);  // Price must be on tick grid

    let clock: Clock = get_clock();

    // Assign order ID
    order.market = market.ctx.key;
    order.owner = open_orders.ctx.key;
    order.side = side;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.order_id = market.next_order_id;
    order.client_order_id = client_order_id;
    order.order_type = order_type;
    order.timestamp = clock.slot;
    order.is_active = true;

    market.next_order_id = market.next_order_id + 1;

    // Lock funds: bids lock quote, asks lock base
    if (side == 0) {
        // Bid: lock quote = price * size
        let quote_to_lock: u64 = price * size;
        spl_token::SPLToken::transfer(user_quote_account, quote_vault, owner, quote_to_lock);
        open_orders.quote_locked = open_orders.quote_locked + quote_to_lock;
    } else {
        // Ask: lock base = size
        spl_token::SPLToken::transfer(user_base_account, base_vault, owner, size);
        open_orders.base_locked = open_orders.base_locked + size;
    }

    open_orders.num_orders = open_orders.num_orders + 1;
}

// new_order_v3: legacy Serum v3-compatible entry point (delegates to place_order logic)
pub new_order_v3(
    market: Market @mut @signer,
    open_orders: OpenOrders @mut,
    order: Order @mut @init(payer=owner, space=512),
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    owner: account @mut @signer,
    token_program: account,
    side: u8,
    price: u64,
    size: u64,
    order_type: u8,
    client_order_id: u64,
    self_trade_behavior: u8
) {
    require(!market.is_disabled);
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);
    require(side <= 1);
    require(order_type <= 2);
    require(self_trade_behavior <= 2);     // 0 = decrement_take, 1 = cancel_provide, 2 = abort
    require(price > 0);
    require(size >= market.min_order_size);
    require(price % market.tick_size == 0);

    let clock: Clock = get_clock();

    order.market = market.ctx.key;
    order.owner = open_orders.ctx.key;
    order.side = side;
    order.price = price;
    order.size = size;
    order.filled = 0;
    order.order_id = market.next_order_id;
    order.client_order_id = client_order_id;
    order.order_type = order_type;
    order.timestamp = clock.slot;
    order.is_active = true;

    market.next_order_id = market.next_order_id + 1;

    if (side == 0) {
        let quote_to_lock: u64 = price * size;
        spl_token::SPLToken::transfer(user_quote_account, quote_vault, owner, quote_to_lock);
        open_orders.quote_locked = open_orders.quote_locked + quote_to_lock;
    } else {
        spl_token::SPLToken::transfer(user_base_account, base_vault, owner, size);
        open_orders.base_locked = open_orders.base_locked + size;
    }

    open_orders.num_orders = open_orders.num_orders + 1;
}

// ---------------------------------------------------------------------------
// Order Cancellation
// ---------------------------------------------------------------------------

pub cancel_order(
    market: Market @mut,
    open_orders: OpenOrders @mut,
    order: Order @mut,
    owner: account @signer
) {
    require(open_orders.owner == owner.ctx.key);
    require(order.owner == open_orders.ctx.key);
    require(order.market == market.ctx.key);
    require(order.is_active);

    let remaining: u64 = order.size - order.filled;
    require(remaining > 0);

    // Unlock remaining funds
    if (order.side == 0) {
        // Bid: unlock quote
        let quote_to_unlock: u64 = order.price * remaining;
        open_orders.quote_locked = open_orders.quote_locked - quote_to_unlock;
        open_orders.quote_free = open_orders.quote_free + quote_to_unlock;
    } else {
        // Ask: unlock base
        open_orders.base_locked = open_orders.base_locked - remaining;
        open_orders.base_free = open_orders.base_free + remaining;
    }

    order.is_active = false;
    open_orders.num_orders = open_orders.num_orders - 1;
}

pub cancel_order_by_client_id(
    market: Market @mut,
    open_orders: OpenOrders @mut,
    order: Order @mut,
    owner: account @signer,
    client_order_id: u64
) {
    require(open_orders.owner == owner.ctx.key);
    require(order.owner == open_orders.ctx.key);
    require(order.market == market.ctx.key);
    require(order.client_order_id == client_order_id);
    require(order.is_active);

    let remaining: u64 = order.size - order.filled;
    require(remaining > 0);

    if (order.side == 0) {
        let quote_to_unlock: u64 = order.price * remaining;
        open_orders.quote_locked = open_orders.quote_locked - quote_to_unlock;
        open_orders.quote_free = open_orders.quote_free + quote_to_unlock;
    } else {
        open_orders.base_locked = open_orders.base_locked - remaining;
        open_orders.base_free = open_orders.base_free + remaining;
    }

    order.is_active = false;
    open_orders.num_orders = open_orders.num_orders - 1;
}

// cancel_all: batch cancel all active orders for an OpenOrders account
// In practice, each order must be passed individually; this cancels a single
// order but is the entry point a client would call in a loop.
pub cancel_all(
    market: Market @mut,
    open_orders: OpenOrders @mut,
    order: Order @mut,
    owner: account @signer
) {
    require(open_orders.owner == owner.ctx.key);
    require(order.owner == open_orders.ctx.key);
    require(order.market == market.ctx.key);

    if (order.is_active) {
        let remaining: u64 = order.size - order.filled;
        if (remaining > 0) {
            if (order.side == 0) {
                let quote_to_unlock: u64 = order.price * remaining;
                open_orders.quote_locked = open_orders.quote_locked - quote_to_unlock;
                open_orders.quote_free = open_orders.quote_free + quote_to_unlock;
            } else {
                open_orders.base_locked = open_orders.base_locked - remaining;
                open_orders.base_free = open_orders.base_free + remaining;
            }
        }
        order.is_active = false;
        open_orders.num_orders = open_orders.num_orders - 1;
    }
}

// ---------------------------------------------------------------------------
// Crank: Matching & Event Consumption
// ---------------------------------------------------------------------------

// match_orders: permissionless crank that matches a maker order against a taker
// In production Serum, the matching engine walks the book. Here we represent a
// single maker-taker match per invocation (crank calls this in a loop).
pub match_orders(
    market: Market @mut,
    maker_order: Order @mut,
    taker_order: Order @mut,
    maker_open_orders: OpenOrders @mut,
    taker_open_orders: OpenOrders @mut,
    event: EventNode @mut @init(payer=cranker, space=256),
    cranker: account @mut @signer
) {
    require(!market.is_disabled);
    require(maker_order.market == market.ctx.key);
    require(taker_order.market == market.ctx.key);
    require(maker_order.is_active);
    require(taker_order.is_active);
    require(maker_order.owner == maker_open_orders.ctx.key);
    require(taker_order.owner == taker_open_orders.ctx.key);

    // Orders must be on opposite sides
    require(maker_order.side != taker_order.side);

    // Price compatibility: bid >= ask for a match
    if (maker_order.side == 0) {
        // Maker is bidding, taker is asking
        require(maker_order.price >= taker_order.price);
    } else {
        // Maker is asking, taker is bidding
        require(taker_order.price >= maker_order.price);
    }

    // Fill at maker's price (price-time priority)
    let fill_price: u64 = maker_order.price;

    // Fill size is the minimum of remaining quantities
    let maker_remaining: u64 = maker_order.size - maker_order.filled;
    let taker_remaining: u64 = taker_order.size - taker_order.filled;
    let mut fill_size: u64 = maker_remaining;
    if (taker_remaining < fill_size) {
        fill_size = taker_remaining;
    }
    require(fill_size > 0);

    let fill_quote: u64 = fill_price * fill_size;

    // Calculate fees
    let maker_fee: u64 = (fill_quote * market.maker_fee_bps) / 10000;
    let taker_fee: u64 = (fill_quote * market.taker_fee_bps) / 10000;

    // Update maker: receives counterpart, pays fee
    if (maker_order.side == 0) {
        // Maker bought base: unlock quote, gain base
        maker_open_orders.quote_locked = maker_open_orders.quote_locked - fill_quote;
        maker_open_orders.base_free = maker_open_orders.base_free + fill_size;
        // Maker fee deducted from freed quote
        market.collected_fees_quote = market.collected_fees_quote + maker_fee;
    } else {
        // Maker sold base: unlock base, gain quote
        maker_open_orders.base_locked = maker_open_orders.base_locked - fill_size;
        maker_open_orders.quote_free = maker_open_orders.quote_free + fill_quote - maker_fee;
        market.collected_fees_quote = market.collected_fees_quote + maker_fee;
    }

    // Update taker: receives counterpart, pays fee
    if (taker_order.side == 0) {
        // Taker bought base
        taker_open_orders.quote_locked = taker_open_orders.quote_locked - fill_quote;
        taker_open_orders.base_free = taker_open_orders.base_free + fill_size;
        market.collected_fees_quote = market.collected_fees_quote + taker_fee;
    } else {
        // Taker sold base
        taker_open_orders.base_locked = taker_open_orders.base_locked - fill_size;
        taker_open_orders.quote_free = taker_open_orders.quote_free + fill_quote - taker_fee;
        market.collected_fees_quote = market.collected_fees_quote + taker_fee;
    }

    // Update fill amounts
    maker_order.filled = maker_order.filled + fill_size;
    taker_order.filled = taker_order.filled + fill_size;

    // Deactivate fully filled orders
    if (maker_order.filled >= maker_order.size) {
        maker_order.is_active = false;
        maker_open_orders.num_orders = maker_open_orders.num_orders - 1;
    }
    if (taker_order.filled >= taker_order.size) {
        taker_order.is_active = false;
        taker_open_orders.num_orders = taker_open_orders.num_orders - 1;
    }

    // IOC orders: cancel any unfilled remainder
    if (taker_order.order_type == 1) {
        if (taker_order.is_active) {
            let ioc_remaining: u64 = taker_order.size - taker_order.filled;
            if (taker_order.side == 0) {
                let quote_refund: u64 = taker_order.price * ioc_remaining;
                taker_open_orders.quote_locked = taker_open_orders.quote_locked - quote_refund;
                taker_open_orders.quote_free = taker_open_orders.quote_free + quote_refund;
            } else {
                taker_open_orders.base_locked = taker_open_orders.base_locked - ioc_remaining;
                taker_open_orders.base_free = taker_open_orders.base_free + ioc_remaining;
            }
            taker_order.is_active = false;
            taker_open_orders.num_orders = taker_open_orders.num_orders - 1;
        }
    }

    // Write event for consume_events
    let clock: Clock = get_clock();
    event.event_type = 0;          // fill
    event.maker = maker_open_orders.ctx.key;
    event.taker = taker_open_orders.ctx.key;
    event.price = fill_price;
    event.size = fill_size;
    event.timestamp = clock.slot;
    event.is_consumed = false;
}

// consume_events: process fill events, making funds available for settlement
pub consume_events(
    market: Market @mut,
    event: EventNode @mut,
    cranker: account @signer
) {
    require(event.event_type == 0);        // Only fill events
    require(!event.is_consumed);
    // Mark event as consumed -- cranker earns rebate off-chain
    event.is_consumed = true;
}

// ---------------------------------------------------------------------------
// Settlement
// ---------------------------------------------------------------------------

// settle_funds: transfer free balances from OpenOrders back to user wallets
pub settle_funds(
    market: Market @mut @signer,
    open_orders: OpenOrders @mut,
    owner: account @signer,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    token_program: account
) {
    require(open_orders.owner == owner.ctx.key);
    require(open_orders.market == market.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    let base_amount: u64 = open_orders.base_free;
    let quote_amount: u64 = open_orders.quote_free;

    if (base_amount > 0) {
        spl_token::SPLToken::transfer(base_vault, user_base_account, market, base_amount);
        open_orders.base_free = 0;
    }

    if (quote_amount > 0) {
        spl_token::SPLToken::transfer(quote_vault, user_quote_account, market, quote_amount);
        open_orders.quote_free = 0;
    }
}

// ---------------------------------------------------------------------------
// Admin Operations
// ---------------------------------------------------------------------------

// prune_orders: authority can force-cancel stale orders (e.g., when disabling market)
pub prune_orders(
    market: Market @mut,
    open_orders: OpenOrders @mut,
    order: Order @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(order.market == market.ctx.key);
    require(order.owner == open_orders.ctx.key);

    if (order.is_active) {
        let remaining: u64 = order.size - order.filled;
        if (remaining > 0) {
            if (order.side == 0) {
                let quote_to_unlock: u64 = order.price * remaining;
                open_orders.quote_locked = open_orders.quote_locked - quote_to_unlock;
                open_orders.quote_free = open_orders.quote_free + quote_to_unlock;
            } else {
                open_orders.base_locked = open_orders.base_locked - remaining;
                open_orders.base_free = open_orders.base_free + remaining;
            }
        }
        order.is_active = false;
        open_orders.num_orders = open_orders.num_orders - 1;
    }
}

// sweep_fees: transfer accumulated protocol fees to a recipient
pub sweep_fees(
    market: Market @mut @signer,
    authority: account @signer,
    base_vault: account @mut,
    quote_vault: account @mut,
    fee_recipient_base: account @mut,
    fee_recipient_quote: account @mut,
    token_program: account
) {
    require(market.authority == authority.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    if (market.collected_fees_base > 0) {
        spl_token::SPLToken::transfer(base_vault, fee_recipient_base, market, market.collected_fees_base);
        market.collected_fees_base = 0;
    }

    if (market.collected_fees_quote > 0) {
        spl_token::SPLToken::transfer(quote_vault, fee_recipient_quote, market, market.collected_fees_quote);
        market.collected_fees_quote = 0;
    }
}
