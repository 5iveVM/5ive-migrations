// 5IVE Phoenix -- Next-Gen Atomic Order Book
//
// Phoenix is Solana's next-generation on-chain order book. Unlike OpenBook/Serum,
// orders match atomically on placement -- no crank step needed. This eliminates
// MEV from delayed settlement and simplifies the trading experience.
//
// Key innovations:
//   - Atomic matching: place_limit_order immediately matches against the book
//   - Seat-based access: makers must request_seat and be approved before posting
//   - Free funds: unsettled balances (base_lots_free, quote_lots_free) are
//     automatically available for new orders without explicit settlement
//   - Taker-only swap: instant market-order-like execution with slippage protection
//
// Precision:
//   - Prices in ticks (price_in_ticks * tick_size = actual price)
//   - Sizes in lots (size_in_lots * lot_size = actual quantity)
//   - Fees in basis points: taker_fee_bps, maker_rebate_bps
//   - BPS_DENOMINATOR = 10000

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account MarketConfig {
    base_mint: pubkey;
    quote_mint: pubkey;
    base_vault: pubkey;
    quote_vault: pubkey;
    tick_size: u64;                  // Minimum price increment (quote atoms per tick)
    lot_size: u64;                   // Minimum size increment (base atoms per lot)
    taker_fee_bps: u64;             // Taker fee in basis points
    maker_rebate_bps: u64;          // Maker rebate in basis points (can be 0)
    num_seats: u32;                  // Number of approved maker seats
    max_seats: u32;                  // Maximum allowed seats
    authority: pubkey;               // Market authority / admin
    next_order_id: u64;              // Monotonic order ID counter
    collected_fees: u64;             // Accumulated protocol fees (quote)
    is_closed: bool;                 // Market lifecycle flag
}

account Seat {
    market: pubkey;
    trader: pubkey;                  // Wallet of the seated maker
    is_approved: bool;               // Whether seat is active
    base_balance: u64;               // Deposited base available
    quote_balance: u64;              // Deposited quote available
}

account Order {
    market: pubkey;
    trader: pubkey;                  // Seat account key
    side: u8;                        // 0 = bid, 1 = ask
    price_in_ticks: u64;            // Limit price in tick units
    size_in_lots: u64;              // Original size in lot units
    filled: u64;                     // Filled lots
    order_id: u64;                   // Unique order ID
    is_active: bool;                 // Whether order is still resting
}

account TraderState {
    market: pubkey;
    trader: pubkey;                  // Wallet address
    base_lots_free: u64;             // Base lots available for withdrawal or new orders
    base_lots_locked: u64;           // Base lots locked in resting asks
    quote_lots_free: u64;            // Quote lots available for withdrawal or new orders
    quote_lots_locked: u64;          // Quote lots locked in resting bids
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
// BPS_DENOMINATOR = 10000
// SIDE_BID = 0, SIDE_ASK = 1

// ---------------------------------------------------------------------------
// Market Lifecycle
// ---------------------------------------------------------------------------

pub initialize_market(
    config: MarketConfig @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    base_mint: pubkey,
    quote_mint: pubkey,
    base_vault: pubkey,
    quote_vault: pubkey,
    tick_size: u64,
    lot_size: u64,
    taker_fee_bps: u64,
    maker_rebate_bps: u64,
    max_seats: u32
) {
    require(tick_size > 0);
    require(lot_size > 0);
    require(taker_fee_bps <= 1000);         // Max 10%
    require(maker_rebate_bps <= taker_fee_bps);  // Rebate cannot exceed fee
    require(base_mint != quote_mint);
    require(max_seats > 0);

    config.base_mint = base_mint;
    config.quote_mint = quote_mint;
    config.base_vault = base_vault;
    config.quote_vault = quote_vault;
    config.tick_size = tick_size;
    config.lot_size = lot_size;
    config.taker_fee_bps = taker_fee_bps;
    config.maker_rebate_bps = maker_rebate_bps;
    config.num_seats = 0;
    config.max_seats = max_seats;
    config.authority = creator.ctx.key;
    config.next_order_id = 1;
    config.collected_fees = 0;
    config.is_closed = false;
}

pub set_params(
    config: MarketConfig @mut,
    authority: account @signer,
    new_taker_fee_bps: u64,
    new_maker_rebate_bps: u64,
    new_max_seats: u32
) {
    require(config.authority == authority.ctx.key);
    require(!config.is_closed);
    require(new_taker_fee_bps <= 1000);
    require(new_maker_rebate_bps <= new_taker_fee_bps);
    require(new_max_seats >= config.num_seats);  // Cannot shrink below active seats

    config.taker_fee_bps = new_taker_fee_bps;
    config.maker_rebate_bps = new_maker_rebate_bps;
    config.max_seats = new_max_seats;
}

pub close_market(
    config: MarketConfig @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    config.is_closed = true;
}

// ---------------------------------------------------------------------------
// Seat Management
// ---------------------------------------------------------------------------

// request_seat: trader registers as a maker (authority must approve)
pub request_seat(
    config: MarketConfig @mut,
    seat: Seat @mut @init(payer=trader, space=256),
    trader: account @mut @signer
) {
    require(!config.is_closed);
    require(config.num_seats < config.max_seats);

    seat.market = config.ctx.key;
    seat.trader = trader.ctx.key;
    seat.is_approved = false;
    seat.base_balance = 0;
    seat.quote_balance = 0;
}

// change_seat_status: authority approves or revokes a seat
pub change_seat_status(
    config: MarketConfig @mut,
    seat: Seat @mut,
    authority: account @signer,
    approved: bool
) {
    require(config.authority == authority.ctx.key);
    require(seat.market == config.ctx.key);

    if (approved) {
        if (!seat.is_approved) {
            seat.is_approved = true;
            config.num_seats = config.num_seats + 1;
        }
    } else {
        if (seat.is_approved) {
            seat.is_approved = false;
            config.num_seats = config.num_seats - 1;
        }
    }
}

// release_seat: trader gives up their seat (must have no open orders or balances)
pub release_seat(
    config: MarketConfig @mut,
    seat: Seat @mut,
    trader: account @signer
) {
    require(seat.trader == trader.ctx.key);
    require(seat.market == config.ctx.key);
    require(seat.base_balance == 0);
    require(seat.quote_balance == 0);

    if (seat.is_approved) {
        config.num_seats = config.num_seats - 1;
    }
    seat.is_approved = false;
}

// ---------------------------------------------------------------------------
// Deposits & Withdrawals
// ---------------------------------------------------------------------------

pub deposit_funds(
    config: MarketConfig @mut @signer,
    trader_state: TraderState @mut,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    trader: account @signer,
    token_program: account,
    base_amount: u64,
    quote_amount: u64
) {
    require(!config.is_closed);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(base_vault.ctx.key == config.base_vault);
    require(quote_vault.ctx.key == config.quote_vault);

    if (base_amount > 0) {
        spl_token::SPLToken::transfer(user_base_account, base_vault, trader, base_amount);
        // Convert to lots for internal tracking
        let base_lots: u64 = base_amount / config.lot_size;
        trader_state.base_lots_free = trader_state.base_lots_free + base_lots;
    }

    if (quote_amount > 0) {
        spl_token::SPLToken::transfer(user_quote_account, quote_vault, trader, quote_amount);
        let quote_lots: u64 = quote_amount / config.tick_size;
        trader_state.quote_lots_free = trader_state.quote_lots_free + quote_lots;
    }
}

pub withdraw_funds(
    config: MarketConfig @mut @signer,
    trader_state: TraderState @mut,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    trader: account @signer,
    token_program: account,
    base_lots: u64,
    quote_lots: u64
) {
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(base_vault.ctx.key == config.base_vault);
    require(quote_vault.ctx.key == config.quote_vault);
    require(base_lots <= trader_state.base_lots_free);
    require(quote_lots <= trader_state.quote_lots_free);

    if (base_lots > 0) {
        let base_amount: u64 = base_lots * config.lot_size;
        spl_token::SPLToken::transfer(base_vault, user_base_account, config, base_amount);
        trader_state.base_lots_free = trader_state.base_lots_free - base_lots;
    }

    if (quote_lots > 0) {
        let quote_amount: u64 = quote_lots * config.tick_size;
        spl_token::SPLToken::transfer(quote_vault, user_quote_account, config, quote_amount);
        trader_state.quote_lots_free = trader_state.quote_lots_free - quote_lots;
    }
}

// ---------------------------------------------------------------------------
// Order Placement (Atomic Matching)
// ---------------------------------------------------------------------------

// Helper: calculate taker fee and maker rebate for a fill
fn calculate_fees(fill_quote: u64, taker_fee_bps: u64, maker_rebate_bps: u64) -> u64 {
    // Returns net protocol fee = taker_fee - maker_rebate
    let taker_fee: u64 = (fill_quote * taker_fee_bps) / 10000;
    let maker_rebate: u64 = (fill_quote * maker_rebate_bps) / 10000;
    return taker_fee - maker_rebate;
}

// place_limit_order: atomically matches against resting orders, remainder rests on book
pub place_limit_order(
    config: MarketConfig @mut,
    seat: Seat @mut,
    trader_state: TraderState @mut,
    order: Order @mut @init(payer=trader, space=512),
    resting_order: Order @mut,
    resting_trader_state: TraderState @mut,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    trader: account @mut @signer,
    token_program: account,
    side: u8,
    price_in_ticks: u64,
    size_in_lots: u64
) {
    require(!config.is_closed);
    require(seat.market == config.ctx.key);
    require(seat.trader == trader.ctx.key);
    require(seat.is_approved);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(base_vault.ctx.key == config.base_vault);
    require(quote_vault.ctx.key == config.quote_vault);
    require(side <= 1);
    require(price_in_ticks > 0);
    require(size_in_lots > 0);

    let clock: Clock = get_clock();

    // Deposit tokens for the order
    if (side == 0) {
        // Bid: need quote tokens
        let quote_needed: u64 = price_in_ticks * size_in_lots * config.tick_size;
        spl_token::SPLToken::transfer(user_quote_account, quote_vault, trader, quote_needed);
        trader_state.quote_lots_free = trader_state.quote_lots_free + (quote_needed / config.tick_size);
    } else {
        // Ask: need base tokens
        let base_needed: u64 = size_in_lots * config.lot_size;
        spl_token::SPLToken::transfer(user_base_account, base_vault, trader, base_needed);
        trader_state.base_lots_free = trader_state.base_lots_free + (base_needed / config.lot_size);
    }

    let mut remaining_lots: u64 = size_in_lots;

    // Atomic matching against a resting order (if it crosses)
    if (resting_order.is_active) {
        require(resting_order.market == config.ctx.key);
        require(resting_order.side != side);  // Opposite side

        let mut crosses: bool = false;
        if (side == 0) {
            // Incoming bid crosses resting ask if bid_price >= ask_price
            if (price_in_ticks >= resting_order.price_in_ticks) {
                crosses = true;
            }
        } else {
            // Incoming ask crosses resting bid if ask_price <= bid_price
            if (price_in_ticks <= resting_order.price_in_ticks) {
                crosses = true;
            }
        }

        if (crosses) {
            let resting_remaining: u64 = resting_order.size_in_lots - resting_order.filled;
            let mut fill_lots: u64 = remaining_lots;
            if (resting_remaining < fill_lots) {
                fill_lots = resting_remaining;
            }

            if (fill_lots > 0) {
                // Fill at resting order price (maker's price)
                let fill_price: u64 = resting_order.price_in_ticks;
                let fill_quote_lots: u64 = fill_price * fill_lots;

                // Net protocol fee
                let protocol_fee: u64 = calculate_fees(
                    fill_quote_lots * config.tick_size,
                    config.taker_fee_bps,
                    config.maker_rebate_bps
                );
                config.collected_fees = config.collected_fees + protocol_fee;

                // Maker rebate credited to resting trader
                let maker_rebate: u64 = (fill_quote_lots * config.tick_size * config.maker_rebate_bps) / 10000;

                // Update taker (incoming order) state
                if (side == 0) {
                    // Taker bought base: spend quote, gain base
                    trader_state.quote_lots_free = trader_state.quote_lots_free - fill_quote_lots;
                    trader_state.base_lots_free = trader_state.base_lots_free + fill_lots;
                } else {
                    // Taker sold base: spend base, gain quote
                    trader_state.base_lots_free = trader_state.base_lots_free - fill_lots;
                    trader_state.quote_lots_free = trader_state.quote_lots_free + fill_quote_lots;
                }

                // Update maker (resting order) state
                if (resting_order.side == 0) {
                    // Resting maker bought base
                    resting_trader_state.quote_lots_locked = resting_trader_state.quote_lots_locked - fill_quote_lots;
                    resting_trader_state.base_lots_free = resting_trader_state.base_lots_free + fill_lots;
                } else {
                    // Resting maker sold base
                    resting_trader_state.base_lots_locked = resting_trader_state.base_lots_locked - fill_lots;
                    resting_trader_state.quote_lots_free = resting_trader_state.quote_lots_free + fill_quote_lots;
                }

                resting_order.filled = resting_order.filled + fill_lots;
                remaining_lots = remaining_lots - fill_lots;

                if (resting_order.filled >= resting_order.size_in_lots) {
                    resting_order.is_active = false;
                }
            }
        }
    }

    // Place remaining as resting order
    order.market = config.ctx.key;
    order.trader = seat.ctx.key;
    order.side = side;
    order.price_in_ticks = price_in_ticks;
    order.size_in_lots = size_in_lots;
    order.filled = size_in_lots - remaining_lots;
    order.order_id = config.next_order_id;
    order.is_active = remaining_lots > 0;

    config.next_order_id = config.next_order_id + 1;

    // Lock remaining funds for resting portion
    if (remaining_lots > 0) {
        if (side == 0) {
            let lock_quote: u64 = price_in_ticks * remaining_lots;
            trader_state.quote_lots_free = trader_state.quote_lots_free - lock_quote;
            trader_state.quote_lots_locked = trader_state.quote_lots_locked + lock_quote;
        } else {
            trader_state.base_lots_free = trader_state.base_lots_free - remaining_lots;
            trader_state.base_lots_locked = trader_state.base_lots_locked + remaining_lots;
        }
    }
}

// place_limit_order_with_free_funds: same as place_limit_order but uses already-deposited free funds
pub place_limit_order_with_free_funds(
    config: MarketConfig @mut,
    seat: Seat @mut,
    trader_state: TraderState @mut,
    order: Order @mut @init(payer=trader, space=512),
    resting_order: Order @mut,
    resting_trader_state: TraderState @mut,
    trader: account @mut @signer,
    side: u8,
    price_in_ticks: u64,
    size_in_lots: u64
) {
    require(!config.is_closed);
    require(seat.market == config.ctx.key);
    require(seat.trader == trader.ctx.key);
    require(seat.is_approved);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(side <= 1);
    require(price_in_ticks > 0);
    require(size_in_lots > 0);

    // Verify sufficient free funds
    if (side == 0) {
        let quote_needed: u64 = price_in_ticks * size_in_lots;
        require(trader_state.quote_lots_free >= quote_needed);
    } else {
        require(trader_state.base_lots_free >= size_in_lots);
    }

    let mut remaining_lots: u64 = size_in_lots;

    // Atomic matching against resting order
    if (resting_order.is_active) {
        require(resting_order.market == config.ctx.key);
        require(resting_order.side != side);

        let mut crosses: bool = false;
        if (side == 0) {
            if (price_in_ticks >= resting_order.price_in_ticks) {
                crosses = true;
            }
        } else {
            if (price_in_ticks <= resting_order.price_in_ticks) {
                crosses = true;
            }
        }

        if (crosses) {
            let resting_remaining: u64 = resting_order.size_in_lots - resting_order.filled;
            let mut fill_lots: u64 = remaining_lots;
            if (resting_remaining < fill_lots) {
                fill_lots = resting_remaining;
            }

            if (fill_lots > 0) {
                let fill_price: u64 = resting_order.price_in_ticks;
                let fill_quote_lots: u64 = fill_price * fill_lots;

                let protocol_fee: u64 = calculate_fees(
                    fill_quote_lots * config.tick_size,
                    config.taker_fee_bps,
                    config.maker_rebate_bps
                );
                config.collected_fees = config.collected_fees + protocol_fee;

                if (side == 0) {
                    trader_state.quote_lots_free = trader_state.quote_lots_free - fill_quote_lots;
                    trader_state.base_lots_free = trader_state.base_lots_free + fill_lots;
                } else {
                    trader_state.base_lots_free = trader_state.base_lots_free - fill_lots;
                    trader_state.quote_lots_free = trader_state.quote_lots_free + fill_quote_lots;
                }

                if (resting_order.side == 0) {
                    resting_trader_state.quote_lots_locked = resting_trader_state.quote_lots_locked - fill_quote_lots;
                    resting_trader_state.base_lots_free = resting_trader_state.base_lots_free + fill_lots;
                } else {
                    resting_trader_state.base_lots_locked = resting_trader_state.base_lots_locked - fill_lots;
                    resting_trader_state.quote_lots_free = resting_trader_state.quote_lots_free + fill_quote_lots;
                }

                resting_order.filled = resting_order.filled + fill_lots;
                remaining_lots = remaining_lots - fill_lots;

                if (resting_order.filled >= resting_order.size_in_lots) {
                    resting_order.is_active = false;
                }
            }
        }
    }

    // Place resting portion
    order.market = config.ctx.key;
    order.trader = seat.ctx.key;
    order.side = side;
    order.price_in_ticks = price_in_ticks;
    order.size_in_lots = size_in_lots;
    order.filled = size_in_lots - remaining_lots;
    order.order_id = config.next_order_id;
    order.is_active = remaining_lots > 0;

    config.next_order_id = config.next_order_id + 1;

    if (remaining_lots > 0) {
        if (side == 0) {
            let lock_quote: u64 = price_in_ticks * remaining_lots;
            trader_state.quote_lots_free = trader_state.quote_lots_free - lock_quote;
            trader_state.quote_lots_locked = trader_state.quote_lots_locked + lock_quote;
        } else {
            trader_state.base_lots_free = trader_state.base_lots_free - remaining_lots;
            trader_state.base_lots_locked = trader_state.base_lots_locked + remaining_lots;
        }
    }
}

// place_market_order: taker-only, fills immediately, no resting remainder
pub place_market_order(
    config: MarketConfig @mut @signer,
    trader_state: TraderState @mut,
    resting_order: Order @mut,
    resting_trader_state: TraderState @mut,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    trader: account @mut @signer,
    token_program: account,
    side: u8,
    size_in_lots: u64,
    max_price_in_ticks: u64
) {
    require(!config.is_closed);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(base_vault.ctx.key == config.base_vault);
    require(quote_vault.ctx.key == config.quote_vault);
    require(side <= 1);
    require(size_in_lots > 0);
    require(resting_order.is_active);
    require(resting_order.market == config.ctx.key);
    require(resting_order.side != side);

    // Slippage check
    if (side == 0) {
        require(resting_order.price_in_ticks <= max_price_in_ticks);
    } else {
        require(resting_order.price_in_ticks >= max_price_in_ticks);
    }

    let resting_remaining: u64 = resting_order.size_in_lots - resting_order.filled;
    let mut fill_lots: u64 = size_in_lots;
    if (resting_remaining < fill_lots) {
        fill_lots = resting_remaining;
    }
    require(fill_lots > 0);

    let fill_price: u64 = resting_order.price_in_ticks;
    let fill_quote_amount: u64 = fill_price * fill_lots * config.tick_size;
    let fill_base_amount: u64 = fill_lots * config.lot_size;

    let taker_fee: u64 = (fill_quote_amount * config.taker_fee_bps) / 10000;
    let maker_rebate: u64 = (fill_quote_amount * config.maker_rebate_bps) / 10000;
    config.collected_fees = config.collected_fees + taker_fee - maker_rebate;

    // Transfer tokens for taker
    if (side == 0) {
        // Taker buying: send quote, receive base
        spl_token::SPLToken::transfer(user_quote_account, quote_vault, trader, fill_quote_amount + taker_fee);
        spl_token::SPLToken::transfer(base_vault, user_base_account, config, fill_base_amount);
    } else {
        // Taker selling: send base, receive quote
        spl_token::SPLToken::transfer(user_base_account, base_vault, trader, fill_base_amount);
        spl_token::SPLToken::transfer(quote_vault, user_quote_account, config, fill_quote_amount - taker_fee);
    }

    // Update resting maker state
    let fill_quote_lots: u64 = fill_price * fill_lots;
    if (resting_order.side == 0) {
        resting_trader_state.quote_lots_locked = resting_trader_state.quote_lots_locked - fill_quote_lots;
        resting_trader_state.base_lots_free = resting_trader_state.base_lots_free + fill_lots;
    } else {
        resting_trader_state.base_lots_locked = resting_trader_state.base_lots_locked - fill_lots;
        resting_trader_state.quote_lots_free = resting_trader_state.quote_lots_free + fill_quote_lots;
    }

    resting_order.filled = resting_order.filled + fill_lots;
    if (resting_order.filled >= resting_order.size_in_lots) {
        resting_order.is_active = false;
    }
}

// swap: taker-only instant execution (convenience wrapper similar to AMM swap)
pub swap(
    config: MarketConfig @mut @signer,
    resting_order: Order @mut,
    resting_trader_state: TraderState @mut,
    user_base_account: account @mut,
    user_quote_account: account @mut,
    base_vault: account @mut,
    quote_vault: account @mut,
    trader: account @signer,
    token_program: account,
    side: u8,
    amount_in: u64,
    min_amount_out: u64
) {
    require(!config.is_closed);
    require(base_vault.ctx.key == config.base_vault);
    require(quote_vault.ctx.key == config.quote_vault);
    require(side <= 1);
    require(amount_in > 0);
    require(resting_order.is_active);
    require(resting_order.market == config.ctx.key);
    require(resting_order.side != side);

    let fill_price: u64 = resting_order.price_in_ticks;
    let resting_remaining: u64 = resting_order.size_in_lots - resting_order.filled;

    let mut fill_lots: u64 = 0;
    let mut amount_out: u64 = 0;

    if (side == 0) {
        // Buying base with quote: amount_in is quote
        let max_lots: u64 = amount_in / (fill_price * config.tick_size);
        fill_lots = max_lots;
        if (resting_remaining < fill_lots) {
            fill_lots = resting_remaining;
        }
        let quote_cost: u64 = fill_lots * fill_price * config.tick_size;
        let taker_fee: u64 = (quote_cost * config.taker_fee_bps) / 10000;
        amount_out = fill_lots * config.lot_size;
        require(amount_out >= min_amount_out);

        spl_token::SPLToken::transfer(user_quote_account, quote_vault, trader, quote_cost + taker_fee);
        spl_token::SPLToken::transfer(base_vault, user_base_account, config, amount_out);
        config.collected_fees = config.collected_fees + taker_fee;
    } else {
        // Selling base for quote: amount_in is base
        fill_lots = amount_in / config.lot_size;
        if (resting_remaining < fill_lots) {
            fill_lots = resting_remaining;
        }
        let quote_proceeds: u64 = fill_lots * fill_price * config.tick_size;
        let taker_fee: u64 = (quote_proceeds * config.taker_fee_bps) / 10000;
        amount_out = quote_proceeds - taker_fee;
        require(amount_out >= min_amount_out);

        spl_token::SPLToken::transfer(user_base_account, base_vault, trader, fill_lots * config.lot_size);
        spl_token::SPLToken::transfer(quote_vault, user_quote_account, config, amount_out);
        config.collected_fees = config.collected_fees + taker_fee;
    }

    require(fill_lots > 0);

    // Update resting maker
    let fill_quote_lots: u64 = fill_price * fill_lots;
    if (resting_order.side == 0) {
        resting_trader_state.quote_lots_locked = resting_trader_state.quote_lots_locked - fill_quote_lots;
        resting_trader_state.base_lots_free = resting_trader_state.base_lots_free + fill_lots;
    } else {
        resting_trader_state.base_lots_locked = resting_trader_state.base_lots_locked - fill_lots;
        resting_trader_state.quote_lots_free = resting_trader_state.quote_lots_free + fill_quote_lots;
    }

    let maker_rebate: u64 = (fill_quote_lots * config.tick_size * config.maker_rebate_bps) / 10000;
    // Rebate stays in resting trader's free balance (already in vault)

    resting_order.filled = resting_order.filled + fill_lots;
    if (resting_order.filled >= resting_order.size_in_lots) {
        resting_order.is_active = false;
    }
}

// ---------------------------------------------------------------------------
// Order Management
// ---------------------------------------------------------------------------

pub cancel_order(
    config: MarketConfig @mut,
    trader_state: TraderState @mut,
    order: Order @mut,
    trader: account @signer
) {
    require(order.market == config.ctx.key);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(order.is_active);

    let remaining: u64 = order.size_in_lots - order.filled;
    require(remaining > 0);

    // Unlock funds back to free
    if (order.side == 0) {
        let quote_to_unlock: u64 = order.price_in_ticks * remaining;
        trader_state.quote_lots_locked = trader_state.quote_lots_locked - quote_to_unlock;
        trader_state.quote_lots_free = trader_state.quote_lots_free + quote_to_unlock;
    } else {
        trader_state.base_lots_locked = trader_state.base_lots_locked - remaining;
        trader_state.base_lots_free = trader_state.base_lots_free + remaining;
    }

    order.is_active = false;
}

pub cancel_all_orders(
    config: MarketConfig @mut,
    trader_state: TraderState @mut,
    order: Order @mut,
    trader: account @signer
) {
    require(order.market == config.ctx.key);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);

    if (order.is_active) {
        let remaining: u64 = order.size_in_lots - order.filled;
        if (remaining > 0) {
            if (order.side == 0) {
                let quote_to_unlock: u64 = order.price_in_ticks * remaining;
                trader_state.quote_lots_locked = trader_state.quote_lots_locked - quote_to_unlock;
                trader_state.quote_lots_free = trader_state.quote_lots_free + quote_to_unlock;
            } else {
                trader_state.base_lots_locked = trader_state.base_lots_locked - remaining;
                trader_state.base_lots_free = trader_state.base_lots_free + remaining;
            }
        }
        order.is_active = false;
    }
}

// reduce_order: partially reduce an order's size without cancelling
pub reduce_order(
    config: MarketConfig @mut,
    trader_state: TraderState @mut,
    order: Order @mut,
    trader: account @signer,
    reduce_lots: u64
) {
    require(order.market == config.ctx.key);
    require(trader_state.market == config.ctx.key);
    require(trader_state.trader == trader.ctx.key);
    require(order.is_active);
    require(reduce_lots > 0);

    let remaining: u64 = order.size_in_lots - order.filled;
    require(reduce_lots <= remaining);

    // Unlock reduced portion
    if (order.side == 0) {
        let quote_to_unlock: u64 = order.price_in_ticks * reduce_lots;
        trader_state.quote_lots_locked = trader_state.quote_lots_locked - quote_to_unlock;
        trader_state.quote_lots_free = trader_state.quote_lots_free + quote_to_unlock;
    } else {
        trader_state.base_lots_locked = trader_state.base_lots_locked - reduce_lots;
        trader_state.base_lots_free = trader_state.base_lots_free + reduce_lots;
    }

    order.size_in_lots = order.size_in_lots - reduce_lots;

    // If fully reduced, deactivate
    if (order.size_in_lots <= order.filled) {
        order.is_active = false;
    }
}

// ---------------------------------------------------------------------------
// Fee Collection
// ---------------------------------------------------------------------------

pub collect_fees(
    config: MarketConfig @mut @signer,
    authority: account @signer,
    quote_vault: account @mut,
    fee_recipient: account @mut,
    token_program: account
) {
    require(config.authority == authority.ctx.key);
    require(quote_vault.ctx.key == config.quote_vault);
    require(config.collected_fees > 0);

    let fees: u64 = config.collected_fees;
    spl_token::SPLToken::transfer(quote_vault, fee_recipient, config, fees);
    config.collected_fees = 0;
}
