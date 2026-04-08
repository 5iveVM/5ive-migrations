// 5IVE Bonfida Migration -- DEX (CLOB) + Solana Name Service (SNS)
//
// Part 1: Bonfida DEX (Serum/OpenBook-style Central Limit Order Book)
//   - On-chain order book with price-time priority matching
//   - Limit, IOC (Immediate-or-Cancel), and Post-Only order types
//   - OpenOrders accounts lock funds until fill or cancel
//   - Crank-driven matching: match_orders produces events, consume_events settles
//   - Settlement transfers filled tokens to user wallets
//   - Configurable maker/taker fee basis points per market
//   - Emergency pause/unpause per market
//
// Part 2: Solana Name Service (SNS)
//   - .sol domain registration with hashed name representation (pubkey-sized)
//   - Time-based expiration and renewal with configurable fees
//   - Subdomain support (e.g., mail.alice.sol) inheriting parent expiry
//   - Reverse records for address-to-name lookups
//   - Admin controls for fees and authority transfer
//
// Fee Model (DEX):
//   maker_fee = (size * price * maker_fee_bps) / (10000 * 1000000)
//   taker_fee = (size * price * taker_fee_bps) / (10000 * 1000000)
//   QUOTE_PRECISION = 1000000 (6 decimal places)
//
// Domain Hashing:
//   Domain names stored as pubkey-sized hashes (keccak256) since 5ive
//   uses fixed-size fields. Parent-child relationships via hash references.

use std::interfaces::spl_token;

// ===========================================================================
// PART 1: BONFIDA DEX -- Accounts
// ===========================================================================

account Market {
    base_mint: pubkey;
    quote_mint: pubkey;
    base_vault: pubkey;
    quote_vault: pubkey;
    bids_account: pubkey;
    asks_account: pubkey;
    event_queue: pubkey;
    min_order_size: u64;
    tick_size: u64;
    maker_fee_bps: u64;
    taker_fee_bps: u64;
    total_volume: u128;
    authority: pubkey;
    is_active: bool;
}

account Order {
    market: pubkey;
    owner: pubkey;
    side: u8;
    price: u64;
    size: u64;
    filled_size: u64;
    order_id: u64;
    client_order_id: u64;
    timestamp: u64;
    is_active: bool;
    order_type: u8;
}

account OpenOrders {
    market: pubkey;
    owner: pubkey;
    base_free: u64;
    base_locked: u64;
    quote_free: u64;
    quote_locked: u64;
    num_orders: u8;
}

account SettlementRecord {
    market: pubkey;
    maker: pubkey;
    taker: pubkey;
    price: u64;
    size: u64;
    maker_fee: u64;
    taker_fee: u64;
    timestamp: u64;
}

// ===========================================================================
// PART 2: SOLANA NAME SERVICE -- Accounts
// ===========================================================================

account NameServiceConfig {
    admin: pubkey;
    registration_fee: u64;
    renewal_fee: u64;
    treasury: pubkey;
    min_name_length: u8;
    max_name_length: u8;
}

account NameRegistry {
    owner: pubkey;
    class_authority: pubkey;
    parent: pubkey;
    data_hash: pubkey;
    expiry_timestamp: u64;
    is_active: bool;
}

account DomainRecord {
    name_hash: pubkey;
    owner: pubkey;
    resolver: pubkey;
    parent_hash: pubkey;
    created_at: u64;
    expires_at: u64;
    is_transferable: bool;
}

account ReverseRecord {
    address: pubkey;
    name_hash: pubkey;
    is_active: bool;
}

account SubdomainRecord {
    parent_hash: pubkey;
    subdomain_hash: pubkey;
    owner: pubkey;
    resolver: pubkey;
    expires_at: u64;
}

// ===========================================================================
// DEX Internal Helpers
// ===========================================================================

// QUOTE_PRECISION = 1000000 (6 decimal places for quote currency)

// Calculate maker fee: (size * price * maker_fee_bps) / (10000 * 1000000)
fn calc_maker_fee(size: u64, price: u64, fee_bps: u64) -> u64 {
    let notional: u64 = size * price;
    let fee: u64 = (notional * fee_bps) / 10000000000;
    return fee;
}

// Calculate taker fee: (size * price * taker_fee_bps) / (10000 * 1000000)
fn calc_taker_fee(size: u64, price: u64, fee_bps: u64) -> u64 {
    let notional: u64 = size * price;
    let fee: u64 = (notional * fee_bps) / 10000000000;
    return fee;
}

// Calculate quote amount for an order: (size * price) / QUOTE_PRECISION
fn calc_quote_amount(size: u64, price: u64) -> u64 {
    return (size * price) / 1000000;
}

// ===========================================================================
// 1. create_market -- Initialize a new trading market with fee config
// ===========================================================================

pub create_market(
    market: Market @mut @init(payer=creator, space=512) @signer,
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
    require(base_mint != quote_mint);
    require(min_order_size > 0);
    require(tick_size > 0);
    require(maker_fee_bps <= 500);
    require(taker_fee_bps <= 500);

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
    market.total_volume = 0;
    market.authority = creator.ctx.key;
    market.is_active = true;
}

// ===========================================================================
// 2. init_open_orders -- Create user's open orders account for a market
// ===========================================================================

pub init_open_orders(
    market: Market,
    open_orders: OpenOrders @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer
) {
    require(market.is_active);

    open_orders.market = market.ctx.key;
    open_orders.owner = owner.ctx.key;
    open_orders.base_free = 0;
    open_orders.base_locked = 0;
    open_orders.quote_free = 0;
    open_orders.quote_locked = 0;
    open_orders.num_orders = 0;
}

// ===========================================================================
// 3. place_order -- Place a limit/IOC/post-only order (locks funds)
// ===========================================================================

pub place_order(
    market: Market @mut,
    order: Order @mut @init(payer=owner, space=512) @signer,
    open_orders: OpenOrders @mut,
    owner: account @mut @signer,
    user_base_token: account @mut,
    user_quote_token: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    token_program: account,
    side: u8,
    price: u64,
    size: u64,
    client_order_id: u64,
    order_id: u64,
    order_type: u8
) {
    require(market.is_active);
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    // Validate order parameters
    require(side <= 1);
    require(order_type <= 2);
    require(price > 0);
    require(size >= market.min_order_size);
    require(price % market.tick_size == 0);

    let now: u64 = get_clock().unix_timestamp;

    // Initialize order record
    order.market = market.ctx.key;
    order.owner = owner.ctx.key;
    order.side = side;
    order.price = price;
    order.size = size;
    order.filled_size = 0;
    order.order_id = order_id;
    order.client_order_id = client_order_id;
    order.timestamp = now;
    order.is_active = true;
    order.order_type = order_type;

    // Lock funds in open orders based on side
    let quote_needed: u64 = calc_quote_amount(size, price);

    if (side == 0) {
        // Bid: lock quote tokens (buyer deposits quote to buy base)
        require(quote_needed > 0);
        spl_token::SPLToken::transfer(user_quote_token, quote_vault, owner, quote_needed);
        open_orders.quote_locked = open_orders.quote_locked + quote_needed;
    } else {
        // Ask: lock base tokens (seller deposits base to sell for quote)
        spl_token::SPLToken::transfer(user_base_token, base_vault, owner, size);
        open_orders.base_locked = open_orders.base_locked + size;
    }

    open_orders.num_orders = open_orders.num_orders + 1;
}

// ===========================================================================
// 4. cancel_order -- Cancel an order, unlock funds
// ===========================================================================

pub cancel_order(
    market: Market,
    order: Order @mut,
    open_orders: OpenOrders @mut,
    owner: account @signer
) {
    require(order.market == market.ctx.key);
    require(order.owner == owner.ctx.key);
    require(order.is_active);

    let remaining_size: u64 = order.size - order.filled_size;
    require(remaining_size > 0);

    // Unlock remaining funds
    if (order.side == 0) {
        // Bid: unlock quote
        let quote_to_unlock: u64 = calc_quote_amount(remaining_size, order.price);
        if (open_orders.quote_locked >= quote_to_unlock) {
            open_orders.quote_locked = open_orders.quote_locked - quote_to_unlock;
        } else {
            open_orders.quote_locked = 0;
        }
        open_orders.quote_free = open_orders.quote_free + quote_to_unlock;
    } else {
        // Ask: unlock base
        if (open_orders.base_locked >= remaining_size) {
            open_orders.base_locked = open_orders.base_locked - remaining_size;
        } else {
            open_orders.base_locked = 0;
        }
        open_orders.base_free = open_orders.base_free + remaining_size;
    }

    order.is_active = false;

    if (open_orders.num_orders > 0) {
        open_orders.num_orders = open_orders.num_orders - 1;
    }
}

// ===========================================================================
// 5. cancel_all_orders -- Cancel all user orders in a market
//    (Modeled as canceling two representative orders; real impl iterates)
// ===========================================================================

pub cancel_all_orders(
    market: Market,
    order_a: Order @mut,
    order_b: Order @mut,
    open_orders: OpenOrders @mut,
    owner: account @signer
) {
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);

    // Cancel order_a if active and belongs to owner
    if (order_a.is_active) {
        require(order_a.market == market.ctx.key);
        require(order_a.owner == owner.ctx.key);
        let remaining_a: u64 = order_a.size - order_a.filled_size;
        if (order_a.side == 0) {
            let quote_unlock_a: u64 = calc_quote_amount(remaining_a, order_a.price);
            if (open_orders.quote_locked >= quote_unlock_a) {
                open_orders.quote_locked = open_orders.quote_locked - quote_unlock_a;
            } else {
                open_orders.quote_locked = 0;
            }
            open_orders.quote_free = open_orders.quote_free + quote_unlock_a;
        } else {
            if (open_orders.base_locked >= remaining_a) {
                open_orders.base_locked = open_orders.base_locked - remaining_a;
            } else {
                open_orders.base_locked = 0;
            }
            open_orders.base_free = open_orders.base_free + remaining_a;
        }
        order_a.is_active = false;
        if (open_orders.num_orders > 0) {
            open_orders.num_orders = open_orders.num_orders - 1;
        }
    }

    // Cancel order_b if active and belongs to owner
    if (order_b.is_active) {
        require(order_b.market == market.ctx.key);
        require(order_b.owner == owner.ctx.key);
        let remaining_b: u64 = order_b.size - order_b.filled_size;
        if (order_b.side == 0) {
            let quote_unlock_b: u64 = calc_quote_amount(remaining_b, order_b.price);
            if (open_orders.quote_locked >= quote_unlock_b) {
                open_orders.quote_locked = open_orders.quote_locked - quote_unlock_b;
            } else {
                open_orders.quote_locked = 0;
            }
            open_orders.quote_free = open_orders.quote_free + quote_unlock_b;
        } else {
            if (open_orders.base_locked >= remaining_b) {
                open_orders.base_locked = open_orders.base_locked - remaining_b;
            } else {
                open_orders.base_locked = 0;
            }
            open_orders.base_free = open_orders.base_free + remaining_b;
        }
        order_b.is_active = false;
        if (open_orders.num_orders > 0) {
            open_orders.num_orders = open_orders.num_orders - 1;
        }
    }
}

// ===========================================================================
// 6. match_orders -- Crank: match crossing bids and asks
// ===========================================================================

pub match_orders(
    market: Market @mut @signer,
    bid_order: Order @mut,
    ask_order: Order @mut,
    bid_open_orders: OpenOrders @mut,
    ask_open_orders: OpenOrders @mut,
    settlement: SettlementRecord @mut @init(payer=crank, space=512) @signer,
    crank: account @mut @signer
) {
    require(market.is_active);
    require(bid_order.market == market.ctx.key);
    require(ask_order.market == market.ctx.key);
    require(bid_order.is_active);
    require(ask_order.is_active);
    require(bid_order.side == 0);
    require(ask_order.side == 1);

    // Price-time priority: bid must be >= ask for a match
    require(bid_order.price >= ask_order.price);

    // Post-only check: reject post-only orders that would immediately match
    // order_type 2 = post-only; these should have been rejected at place_order
    // if they would cross. Here we enforce: if either is post-only, skip.
    require(bid_order.order_type != 2);
    require(ask_order.order_type != 2);

    // Determine fill size (minimum of remaining sizes)
    let bid_remaining: u64 = bid_order.size - bid_order.filled_size;
    let ask_remaining: u64 = ask_order.size - ask_order.filled_size;
    let mut fill_size: u64 = bid_remaining;
    if (ask_remaining < fill_size) {
        fill_size = ask_remaining;
    }
    require(fill_size > 0);

    // Match at the maker's price (bid price for the resting order)
    let match_price: u64 = bid_order.price;
    let quote_amount: u64 = calc_quote_amount(fill_size, match_price);
    require(quote_amount > 0);

    // Calculate fees
    let maker_fee: u64 = calc_maker_fee(fill_size, match_price, market.maker_fee_bps);
    let taker_fee: u64 = calc_taker_fee(fill_size, match_price, market.taker_fee_bps);

    // Update order fill progress
    bid_order.filled_size = bid_order.filled_size + fill_size;
    ask_order.filled_size = ask_order.filled_size + fill_size;

    // Deactivate fully filled orders
    if (bid_order.filled_size >= bid_order.size) {
        bid_order.is_active = false;
        if (bid_open_orders.num_orders > 0) {
            bid_open_orders.num_orders = bid_open_orders.num_orders - 1;
        }
    }
    if (ask_order.filled_size >= ask_order.size) {
        ask_order.is_active = false;
        if (ask_open_orders.num_orders > 0) {
            ask_open_orders.num_orders = ask_open_orders.num_orders - 1;
        }
    }

    // IOC handling: cancel remaining unfilled portion
    // order_type 1 = IOC
    if (bid_order.order_type == 1) {
        if (bid_order.filled_size < bid_order.size) {
            let ioc_remaining: u64 = bid_order.size - bid_order.filled_size;
            let ioc_quote_unlock: u64 = calc_quote_amount(ioc_remaining, bid_order.price);
            if (bid_open_orders.quote_locked >= ioc_quote_unlock) {
                bid_open_orders.quote_locked = bid_open_orders.quote_locked - ioc_quote_unlock;
            } else {
                bid_open_orders.quote_locked = 0;
            }
            bid_open_orders.quote_free = bid_open_orders.quote_free + ioc_quote_unlock;
            bid_order.is_active = false;
            if (bid_open_orders.num_orders > 0) {
                bid_open_orders.num_orders = bid_open_orders.num_orders - 1;
            }
        }
    }
    if (ask_order.order_type == 1) {
        if (ask_order.filled_size < ask_order.size) {
            let ioc_base_remaining: u64 = ask_order.size - ask_order.filled_size;
            if (ask_open_orders.base_locked >= ioc_base_remaining) {
                ask_open_orders.base_locked = ask_open_orders.base_locked - ioc_base_remaining;
            } else {
                ask_open_orders.base_locked = 0;
            }
            ask_open_orders.base_free = ask_open_orders.base_free + ioc_base_remaining;
            ask_order.is_active = false;
            if (ask_open_orders.num_orders > 0) {
                ask_open_orders.num_orders = ask_open_orders.num_orders - 1;
            }
        }
    }

    // Credit filled amounts to open orders as free balances
    // Buyer (bid) receives base tokens
    bid_open_orders.base_free = bid_open_orders.base_free + fill_size;
    // Deduct locked quote from buyer (net of fees paid)
    let bid_quote_consumed: u64 = quote_amount + taker_fee;
    if (bid_open_orders.quote_locked >= bid_quote_consumed) {
        bid_open_orders.quote_locked = bid_open_orders.quote_locked - bid_quote_consumed;
    } else {
        bid_open_orders.quote_locked = 0;
    }

    // Seller (ask) receives quote tokens minus maker fee
    let seller_quote_credit: u64 = quote_amount - maker_fee;
    ask_open_orders.quote_free = ask_open_orders.quote_free + seller_quote_credit;
    // Deduct locked base from seller
    if (ask_open_orders.base_locked >= fill_size) {
        ask_open_orders.base_locked = ask_open_orders.base_locked - fill_size;
    } else {
        ask_open_orders.base_locked = 0;
    }

    // Record settlement event
    let now: u64 = get_clock().unix_timestamp;
    settlement.market = market.ctx.key;
    settlement.maker = ask_order.owner;
    settlement.taker = bid_order.owner;
    settlement.price = match_price;
    settlement.size = fill_size;
    settlement.maker_fee = maker_fee;
    settlement.taker_fee = taker_fee;
    settlement.timestamp = now;

    // Update market volume
    let fill_volume: u128 = quote_amount as u128;
    market.total_volume = market.total_volume + fill_volume;
}

// ===========================================================================
// 7. settle_funds -- Settle matched trades to user wallets
// ===========================================================================

pub settle_funds(
    market: Market @mut @signer,
    open_orders: OpenOrders @mut,
    owner: account @signer,
    user_base_token: account @mut,
    user_quote_token: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    token_program: account
) {
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);
    require(base_vault.ctx.key == market.base_vault);
    require(quote_vault.ctx.key == market.quote_vault);

    // Transfer free base to user
    let base_amount: u64 = open_orders.base_free;
    if (base_amount > 0) {
        spl_token::SPLToken::transfer(base_vault, user_base_token, market, base_amount);
        open_orders.base_free = 0;
    }

    // Transfer free quote to user
    let quote_amount: u64 = open_orders.quote_free;
    if (quote_amount > 0) {
        spl_token::SPLToken::transfer(quote_vault, user_quote_token, market, quote_amount);
        open_orders.quote_free = 0;
    }
}

// ===========================================================================
// 8. consume_events -- Process settlement events from event queue
// ===========================================================================

pub consume_events(
    market: Market,
    settlement: SettlementRecord @mut,
    maker_open_orders: OpenOrders @mut,
    taker_open_orders: OpenOrders @mut,
    crank: account @signer
) {
    require(settlement.market == market.ctx.key);
    require(settlement.size > 0);

    // Events are consumed by updating open orders with fill results
    // The maker receives quote (minus fee), taker receives base
    // This is already handled during match_orders; consume_events
    // serves as the finalization/acknowledgment step

    // Verify the settlement references valid open orders
    require(maker_open_orders.market == market.ctx.key);
    require(taker_open_orders.market == market.ctx.key);

    // Mark settlement as consumed by zeroing size
    settlement.size = 0;
}

// ===========================================================================
// 9. close_open_orders -- Close open orders account (must be empty)
// ===========================================================================

pub close_open_orders(
    market: Market,
    open_orders: OpenOrders @mut,
    owner: account @signer
) {
    require(open_orders.market == market.ctx.key);
    require(open_orders.owner == owner.ctx.key);
    require(open_orders.num_orders == 0);
    require(open_orders.base_free == 0);
    require(open_orders.base_locked == 0);
    require(open_orders.quote_free == 0);
    require(open_orders.quote_locked == 0);

    // Zero out the account to mark it as closed
    open_orders.base_free = 0;
    open_orders.base_locked = 0;
    open_orders.quote_free = 0;
    open_orders.quote_locked = 0;
    open_orders.num_orders = 0;
}

// ===========================================================================
// 10. set_market_fees -- Update maker/taker fee rates
// ===========================================================================

pub set_market_fees(
    market: Market @mut,
    authority: account @signer,
    new_maker_fee_bps: u64,
    new_taker_fee_bps: u64
) {
    require(market.authority == authority.ctx.key);
    require(new_maker_fee_bps <= 500);
    require(new_taker_fee_bps <= 500);

    market.maker_fee_bps = new_maker_fee_bps;
    market.taker_fee_bps = new_taker_fee_bps;
}

// ===========================================================================
// 11. pause_market / unpause_market -- Emergency controls
// ===========================================================================

pub pause_market(
    market: Market @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(market.is_active);
    market.is_active = false;
}

pub unpause_market(
    market: Market @mut,
    authority: account @signer
) {
    require(market.authority == authority.ctx.key);
    require(!market.is_active);
    market.is_active = true;
}

// ===========================================================================
// PART 2: SOLANA NAME SERVICE -- Instructions
// ===========================================================================

// ===========================================================================
// 12. init_name_service -- Initialize name service config
// ===========================================================================

pub init_name_service(
    config: NameServiceConfig @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    treasury: pubkey,
    registration_fee: u64,
    renewal_fee: u64,
    min_name_length: u8,
    max_name_length: u8
) {
    require(registration_fee > 0);
    require(renewal_fee > 0);
    require(min_name_length > 0);
    require(max_name_length >= min_name_length);
    require(max_name_length <= 64);

    config.admin = admin.ctx.key;
    config.registration_fee = registration_fee;
    config.renewal_fee = renewal_fee;
    config.treasury = treasury;
    config.min_name_length = min_name_length;
    config.max_name_length = max_name_length;
}

// ===========================================================================
// 13. register_name -- Register a new .sol domain name
// ===========================================================================

pub register_name(
    config: NameServiceConfig,
    domain: DomainRecord @mut @init(payer=registrant, space=512) @signer,
    registry: NameRegistry @mut @init(payer=registrant, space=512),
    registrant: account @mut @signer,
    registrant_token: account @mut,
    treasury_token: account @mut,
    token_program: account,
    name_hash: pubkey,
    resolver: pubkey,
    duration: u64,
    name_length: u8
) {
    // Validate name length within config bounds
    require(name_length >= config.min_name_length);
    require(name_length <= config.max_name_length);
    require(duration > 0);

    let now: u64 = get_clock().unix_timestamp;
    let expiry: u64 = now + duration;

    // Pay registration fee to treasury
    spl_token::SPLToken::transfer(registrant_token, treasury_token, registrant, config.registration_fee);

    // Initialize domain record
    domain.name_hash = name_hash;
    domain.owner = registrant.ctx.key;
    domain.resolver = resolver;
    domain.parent_hash = derive_pda("root_domain", config.ctx.key);
    domain.created_at = now;
    domain.expires_at = expiry;
    domain.is_transferable = true;

    // Initialize name registry
    registry.owner = registrant.ctx.key;
    registry.class_authority = config.admin;
    registry.parent = config.ctx.key;
    registry.data_hash = name_hash;
    registry.expiry_timestamp = expiry;
    registry.is_active = true;
}

// ===========================================================================
// 14. renew_name -- Extend domain expiration
// ===========================================================================

pub renew_name(
    config: NameServiceConfig,
    domain: DomainRecord @mut,
    registry: NameRegistry @mut,
    owner: account @mut @signer,
    owner_token: account @mut,
    treasury_token: account @mut,
    token_program: account,
    duration: u64
) {
    require(domain.owner == owner.ctx.key);
    require(registry.is_active);
    require(duration > 0);

    let now: u64 = get_clock().unix_timestamp;

    // Can renew before or after expiry
    // If expired, new expiry starts from now; if not, extends from current expiry
    let mut new_expiry: u64 = domain.expires_at + duration;
    if (domain.expires_at < now) {
        new_expiry = now + duration;
    }

    // Pay renewal fee
    spl_token::SPLToken::transfer(owner_token, treasury_token, owner, config.renewal_fee);

    domain.expires_at = new_expiry;
    registry.expiry_timestamp = new_expiry;
}

// ===========================================================================
// 15. transfer_name -- Transfer domain ownership
// ===========================================================================

pub transfer_name(
    domain: DomainRecord @mut,
    registry: NameRegistry @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(domain.owner == owner.ctx.key);
    require(domain.is_transferable);
    require(registry.is_active);

    let now: u64 = get_clock().unix_timestamp;
    require(domain.expires_at > now);

    domain.owner = new_owner;
    registry.owner = new_owner;
}

// ===========================================================================
// 16. update_resolver -- Change the address a name resolves to
// ===========================================================================

pub update_resolver(
    domain: DomainRecord @mut,
    owner: account @signer,
    new_resolver: pubkey
) {
    require(domain.owner == owner.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    require(domain.expires_at > now);

    domain.resolver = new_resolver;
}

// ===========================================================================
// 17. delete_name -- Delete an expired or owned domain
// ===========================================================================

pub delete_name(
    domain: DomainRecord @mut,
    registry: NameRegistry @mut,
    authority: account @signer
) {
    let now: u64 = get_clock().unix_timestamp;

    // Owner can delete anytime; anyone can delete expired domains
    let is_owner: bool = domain.owner == authority.ctx.key;
    let is_expired: bool = domain.expires_at <= now;
    require(is_owner || is_expired);

    registry.is_active = false;
    registry.expiry_timestamp = 0;

    // Zero out the domain record
    domain.expires_at = 0;
    domain.is_transferable = false;
}

// ===========================================================================
// 18. create_subdomain -- Create a subdomain under an owned domain
// ===========================================================================

pub create_subdomain(
    config: NameServiceConfig,
    parent_domain: DomainRecord,
    subdomain: SubdomainRecord @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    subdomain_hash: pubkey,
    resolver: pubkey
) {
    require(parent_domain.owner == owner.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    require(parent_domain.expires_at > now);

    // Subdomain inherits parent's expiration
    subdomain.parent_hash = parent_domain.name_hash;
    subdomain.subdomain_hash = subdomain_hash;
    subdomain.owner = owner.ctx.key;
    subdomain.resolver = resolver;
    subdomain.expires_at = parent_domain.expires_at;
}

// ===========================================================================
// 19. transfer_subdomain -- Transfer subdomain ownership
// ===========================================================================

pub transfer_subdomain(
    parent_domain: DomainRecord,
    subdomain: SubdomainRecord @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(subdomain.owner == owner.ctx.key);
    require(subdomain.parent_hash == parent_domain.name_hash);

    let now: u64 = get_clock().unix_timestamp;
    require(subdomain.expires_at > now);

    subdomain.owner = new_owner;
}

// ===========================================================================
// 20. delete_subdomain -- Delete a subdomain
// ===========================================================================

pub delete_subdomain(
    parent_domain: DomainRecord,
    subdomain: SubdomainRecord @mut,
    authority: account @signer
) {
    require(subdomain.parent_hash == parent_domain.name_hash);

    let now: u64 = get_clock().unix_timestamp;

    // Subdomain owner or parent domain owner can delete
    let is_subdomain_owner: bool = subdomain.owner == authority.ctx.key;
    let is_parent_owner: bool = parent_domain.owner == authority.ctx.key;
    let is_expired: bool = subdomain.expires_at <= now;
    require(is_subdomain_owner || is_parent_owner || is_expired);

    subdomain.expires_at = 0;
    subdomain.owner = derive_pda("deleted", subdomain.subdomain_hash);
}

// ===========================================================================
// 21. create_reverse_record -- Map an address back to a domain name
// ===========================================================================

pub create_reverse_record(
    domain: DomainRecord,
    reverse: ReverseRecord @mut @init(payer=owner, space=512) @signer,
    owner: account @mut @signer,
    address: pubkey
) {
    require(domain.owner == owner.ctx.key);

    let now: u64 = get_clock().unix_timestamp;
    require(domain.expires_at > now);

    // The address being mapped must be the domain's resolver target
    require(address == domain.resolver);

    reverse.address = address;
    reverse.name_hash = domain.name_hash;
    reverse.is_active = true;
}

// ===========================================================================
// 22. delete_reverse_record -- Remove reverse mapping
// ===========================================================================

pub delete_reverse_record(
    reverse: ReverseRecord @mut,
    owner: account @signer
) {
    require(reverse.is_active);
    // Only the address holder can remove reverse mapping
    require(reverse.address == owner.ctx.key);

    reverse.is_active = false;
}

// ===========================================================================
// 23. set_registration_fee -- Admin: update registration fee
// ===========================================================================

pub set_registration_fee(
    config: NameServiceConfig @mut,
    admin: account @signer,
    new_fee: u64
) {
    require(config.admin == admin.ctx.key);
    require(new_fee > 0);

    config.registration_fee = new_fee;
}

// ===========================================================================
// 24. set_renewal_fee -- Admin: update renewal fee
// ===========================================================================

pub set_renewal_fee(
    config: NameServiceConfig @mut,
    admin: account @signer,
    new_fee: u64
) {
    require(config.admin == admin.ctx.key);
    require(new_fee > 0);

    config.renewal_fee = new_fee;
}

// ===========================================================================
// 25. set_name_service_authority -- Admin: transfer authority
// ===========================================================================

pub set_name_service_authority(
    config: NameServiceConfig @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(config.admin == admin.ctx.key);

    config.admin = new_admin;
}

// ===========================================================================
// Read-Only Queries -- DEX
// ===========================================================================

pub get_market_volume(market: Market) -> u128 {
    return market.total_volume;
}

pub get_order_status(order: Order) -> bool {
    return order.is_active;
}

pub get_order_filled_size(order: Order) -> u64 {
    return order.filled_size;
}

pub get_order_remaining_size(order: Order) -> u64 {
    let remaining: u64 = order.size - order.filled_size;
    return remaining;
}

pub get_open_orders_base_free(open_orders: OpenOrders) -> u64 {
    return open_orders.base_free;
}

pub get_open_orders_quote_free(open_orders: OpenOrders) -> u64 {
    return open_orders.quote_free;
}

pub get_open_orders_base_locked(open_orders: OpenOrders) -> u64 {
    return open_orders.base_locked;
}

pub get_open_orders_quote_locked(open_orders: OpenOrders) -> u64 {
    return open_orders.quote_locked;
}

pub get_maker_fee_bps(market: Market) -> u64 {
    return market.maker_fee_bps;
}

pub get_taker_fee_bps(market: Market) -> u64 {
    return market.taker_fee_bps;
}

// ===========================================================================
// Read-Only Queries -- Name Service
// ===========================================================================

pub get_domain_owner(domain: DomainRecord) -> pubkey {
    return domain.owner;
}

pub get_domain_resolver(domain: DomainRecord) -> pubkey {
    return domain.resolver;
}

pub get_domain_expiry(domain: DomainRecord) -> u64 {
    return domain.expires_at;
}

pub get_subdomain_resolver(subdomain: SubdomainRecord) -> pubkey {
    return subdomain.resolver;
}

pub get_subdomain_expiry(subdomain: SubdomainRecord) -> u64 {
    return subdomain.expires_at;
}

pub get_reverse_name(reverse: ReverseRecord) -> pubkey {
    return reverse.name_hash;
}

pub get_registration_fee(config: NameServiceConfig) -> u64 {
    return config.registration_fee;
}

pub get_renewal_fee(config: NameServiceConfig) -> u64 {
    return config.renewal_fee;
}

pub is_domain_expired(domain: DomainRecord) -> bool {
    let now: u64 = get_clock().unix_timestamp;
    let expired: bool = domain.expires_at <= now;
    return expired;
}

pub is_reverse_active(reverse: ReverseRecord) -> bool {
    return reverse.is_active;
}
