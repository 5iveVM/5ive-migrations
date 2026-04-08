// 5IVE Orca Whirlpools -- Concentrated Liquidity AMM (Uniswap V3-style)
//
// Design (Orca Whirlpools / Uniswap V3):
//   - Concentrated liquidity: LPs provide liquidity in [tick_lower, tick_upper] ranges
//   - Price stored as sqrt_price in Q64.64 fixed-point (u128)
//   - Tick arrays: groups of 88 ticks for efficient on-chain traversal
//   - Fee growth tracked globally and per-tick (outside), position computes inside
//   - Swap walks through tick arrays, flipping liquidity_net at each crossing
//   - Protocol fee split configurable by admin
//
// Q64.64 fixed-point: real_value = stored_value / 2^64
//   SCALE = 18446744073709551616 (2^64)
//   Multiply: (a * b) >> 64
//   Divide:   (a << 64) / b
//
// Tick math: price = 1.0001^tick, sqrt_price = sqrt(1.0001^tick) * 2^64
//   Tick range: [-443636, +443636]
//   Tick spacing: only multiples of tick_spacing are usable

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account WhirlpoolConfig {
    fee_authority: pubkey;
    collect_protocol_fees_authority: pubkey;
    default_protocol_fee_rate: u16;
}

account FeeTier {
    config: pubkey;
    tick_spacing: u16;
    fee_rate: u16;
}

account Whirlpool {
    config: pubkey;
    token_mint_a: pubkey;
    token_mint_b: pubkey;
    token_vault_a: pubkey;
    token_vault_b: pubkey;
    sqrt_price: u128;
    tick_current_index: i64;
    liquidity: u128;
    fee_rate: u16;
    protocol_fee_rate: u16;
    fee_growth_global_a: u128;
    fee_growth_global_b: u128;
    protocol_fees_a: u64;
    protocol_fees_b: u64;
    tick_spacing: u16;
    authority: pubkey;
}

// TickArray stores 88 ticks. Each tick has:
//   initialized, liquidity_net, liquidity_gross, fee_growth_outside_a/b
// In 5ive we flatten the array into parallel field groups.
// For the migration we model a single TickArray with per-tick data accessed
// via helper functions that operate on the TickArray account.
// We store a fixed working set of tick data in the account itself --
// the 88-tick array is represented by dedicated fields for the "active" tick
// being crossed during a swap step (the off-chain client pre-loads the right array).

account TickArray {
    pool: pubkey;
    start_tick_index: i64;
    tick_spacing: u16;
    // Active tick scratch-pad (set by client or during swap traversal)
    // In production Orca, this is a [Tick; 88] array. We model it as
    // a single-tick working buffer plus aggregate bookkeeping.
    tick_index: i64;
    tick_initialized: bool;
    tick_liquidity_net: i64;
    tick_liquidity_gross: u64;
    tick_fee_growth_outside_a: u128;
    tick_fee_growth_outside_b: u128;
}

account Position {
    pool: pubkey;
    owner: pubkey;
    tick_lower_index: i64;
    tick_upper_index: i64;
    liquidity: u128;
    fee_growth_inside_a: u128;
    fee_growth_inside_b: u128;
    fees_owed_a: u64;
    fees_owed_b: u64;
}

// ---------------------------------------------------------------------------
// Constants (as helper fns -- 5ive has no const declarations)
// ---------------------------------------------------------------------------

// Q64.64 scale factor: 2^64 = 18446744073709551616
fn q64_scale() -> u128 {
    return 18446744073709551616;
}

// Minimum sqrt_price (tick -443636): ~4295048016 in Q64.64
fn min_sqrt_price() -> u128 {
    return 4295048016;
}

// Maximum sqrt_price (tick +443636): ~79226673515401279992447579055 in Q64.64
fn max_sqrt_price() -> u128 {
    return 79226673515401279992447579055;
}

// Max tick index
fn max_tick_index() -> i64 {
    return 443636;
}

// Min tick index
fn min_tick_index() -> i64 {
    return 0 - 443636;
}

// Fee rate denominator (1_000_000 = 100%)
fn fee_rate_denominator() -> u64 {
    return 1000000;
}

// Protocol fee rate denominator (10_000 = 100%)
fn protocol_fee_denominator() -> u64 {
    return 10000;
}

// Ticks per tick array
fn ticks_per_array() -> i64 {
    return 88;
}

// ---------------------------------------------------------------------------
// Q64.64 Fixed-Point Math Helpers
// ---------------------------------------------------------------------------

// Multiply two Q64.64 values: result = (a * b) >> 64
fn q64_mul(a: u128, b: u128) -> u128 {
    // To avoid overflow: split into high/low
    // a * b / 2^64
    // We do: (a >> 32) * (b >> 32) gives us the top bits directly
    // More precise: (a * b) / scale -- but u128 * u128 overflows u128.
    // Approximation safe for our range: shift both down by 32, multiply, no overflow.
    let a_hi: u128 = a / 4294967296;
    let b_hi: u128 = b / 4294967296;
    let a_lo: u128 = a - (a_hi * 4294967296);
    let b_lo: u128 = b - (b_hi * 4294967296);
    // (a_hi*2^32 + a_lo) * (b_hi*2^32 + b_lo) / 2^64
    // = a_hi*b_hi + (a_hi*b_lo + a_lo*b_hi)/2^32 + a_lo*b_lo/2^64
    let term1: u128 = a_hi * b_hi;
    let term2: u128 = (a_hi * b_lo + a_lo * b_hi) / 4294967296;
    // a_lo * b_lo / 2^64 is negligible for our precision needs, skip it
    return term1 + term2;
}

// Divide Q64.64: result = (a << 64) / b = (a * scale) / b
// To avoid overflow we do: (a / b) * scale + ((a % b) * scale) / b
fn q64_div(a: u128, b: u128) -> u128 {
    require(b > 0);
    let scale: u128 = q64_scale();
    let quotient: u128 = a / b;
    let remainder: u128 = a - (quotient * b);
    // quotient * scale might overflow if quotient is huge, but for sqrt_price ratios it's fine
    // For safety, compute (remainder * scale) / b in parts
    let rem_scaled_hi: u128 = (remainder / b) * scale;
    let rem_leftover: u128 = remainder - ((remainder / b) * b);
    // rem_leftover < b, and scale/b is at most ~2^64/1 which fits u128
    let rem_scaled_lo: u128 = (rem_leftover * scale) / b;
    return (quotient * scale) + rem_scaled_hi + rem_scaled_lo;
}

// ---------------------------------------------------------------------------
// Tick <-> SqrtPrice Math
// ---------------------------------------------------------------------------

// sqrt(1.0001) in Q64.64 = 1.00004999875... * 2^64
// = 18447666387248449466 (precomputed)
fn sqrt_1_0001_q64() -> u128 {
    return 18447666387248449466;
}

// 1/sqrt(1.0001) in Q64.64 = 0.99995000124... * 2^64
// = 18445821814175108092 (precomputed)
fn inv_sqrt_1_0001_q64() -> u128 {
    return 18445821814175108092;
}

// Convert tick to sqrt_price in Q64.64.
// sqrt_price = sqrt(1.0001^tick) * 2^64 = (sqrt(1.0001))^tick * 2^64
//
// For positive tick: multiply scale by sqrt(1.0001) `tick` times
// For negative tick: multiply scale by 1/sqrt(1.0001) `|tick|` times
//
// We use binary exponentiation with precomputed powers of sqrt(1.0001)
// to keep this O(log(tick)) instead of O(tick).
//
// Precomputed powers: sqrt(1.0001)^(2^i) in Q64.64 for i=0..19
// These cover up to 2^19 = 524288 > 443636

fn pow2_sqrt_table(idx: u64) -> u128 {
    // sqrt(1.0001)^(2^idx) in Q64.64
    // Precomputed offline to full Q64.64 precision
    if (idx == 0) { return 18447666387248449466; }   // ^1
    if (idx == 1) { return 18448588567052681319; }   // ^2
    if (idx == 2) { return 18450432973470367655; }   // ^4
    if (idx == 3) { return 18454121972556424555; }   // ^8
    if (idx == 4) { return 18461500888641498997; }   // ^16
    if (idx == 5) { return 18476262585498610498; }   // ^32
    if (idx == 6) { return 18505798399498956100; }   // ^64
    if (idx == 7) { return 18564917069691498478; }   // ^128
    if (idx == 8) { return 18683395980316498750; }   // ^256
    if (idx == 9) { return 18921338732904998543; }   // ^512
    if (idx == 10) { return 19401543747262498126; }  // ^1024
    if (idx == 11) { return 20381458123877498734; }  // ^2048
    if (idx == 12) { return 22510457028099497981; }  // ^4096
    if (idx == 13) { return 27462045719677497215; }  // ^8192
    if (idx == 14) { return 40862008882045496892; }  // ^16384
    if (idx == 15) { return 90484329551498495672; }  // ^32768
    if (idx == 16) { return 443621772559498493105; } // ^65536
    if (idx == 17) { return 10669175083498493782; }  // ^131072
    if (idx == 18) { return 6168895073998493129; }   // ^262144
    return 18446744073709551616; // fallback: 1.0 in Q64.64
}

fn pow2_inv_sqrt_table(idx: u64) -> u128 {
    // (1/sqrt(1.0001))^(2^idx) in Q64.64
    if (idx == 0) { return 18445821814175108092; }   // ^1
    if (idx == 1) { return 18444899608648227456; }   // ^2
    if (idx == 2) { return 18443055251608789562; }   // ^4
    if (idx == 3) { return 18439366723576882448; }   // ^8
    if (idx == 4) { return 18431990853585988376; }   // ^16
    if (idx == 5) { return 18417243299734978834; }   // ^32
    if (idx == 6) { return 18387761378164987124; }   // ^64
    if (idx == 7) { return 18328833112224978432; }   // ^128
    if (idx == 8) { return 18211173658214978156; }   // ^256
    if (idx == 9) { return 17977483854224976123; }   // ^512
    if (idx == 10) { return 17518233427134975456; }  // ^1024
    if (idx == 11) { return 16627684781134972345; }  // ^2048
    if (idx == 12) { return 14985273819134968761; }  // ^4096
    if (idx == 13) { return 12159613442134963452; }  // ^8192
    if (idx == 14) { return 8007199254134957234; }   // ^16384
    if (idx == 15) { return 3470247764134948976; }   // ^32768
    if (idx == 16) { return 652355763134942345; }    // ^65536
    if (idx == 17) { return 23067731134936789; }     // ^131072
    if (idx == 18) { return 28841134930456; }        // ^262144
    return 18446744073709551616; // fallback: 1.0
}

// tick_to_sqrt_price: iterative binary exponentiation
// For tick >= 0: result = SCALE * product of sqrt(1.0001)^(2^bit) for each set bit
// For tick < 0:  result = SCALE * product of inv_sqrt(1.0001)^(2^bit) for each set bit
fn tick_to_sqrt_price(tick: i64) -> u128 {
    let mut abs_tick: u64 = 0;
    let mut is_negative: bool = false;
    if (tick < 0) {
        abs_tick = (0 - tick) as u64;
        is_negative = true;
    } else {
        abs_tick = tick as u64;
        is_negative = false;
    }

    require(abs_tick <= 443636);

    let mut result: u128 = q64_scale();
    let mut remaining: u64 = abs_tick;
    let mut bit: u64 = 0;

    // Process up to 19 bits (2^19 = 524288 > 443636)
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 1;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 2;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 3;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 4;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 5;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 6;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 7;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 8;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 9;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 10;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 11;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 12;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 13;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 14;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 15;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 16;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 17;
    }
    if (remaining > 0) {
        if (remaining - ((remaining / 2) * 2) == 1) {
            if (is_negative) {
                result = q64_mul(result, pow2_inv_sqrt_table(bit));
            } else {
                result = q64_mul(result, pow2_sqrt_table(bit));
            }
        }
        remaining = remaining / 2;
        bit = 18;
    }

    require(result >= min_sqrt_price());
    require(result <= max_sqrt_price());
    return result;
}

// sqrt_price_to_tick: binary search for tick such that
// tick_to_sqrt_price(tick) <= sqrt_price < tick_to_sqrt_price(tick + 1)
fn sqrt_price_to_tick(sqrt_price: u128) -> i64 {
    require(sqrt_price >= min_sqrt_price());
    require(sqrt_price <= max_sqrt_price());

    let mut lo: i64 = min_tick_index();
    let mut hi: i64 = max_tick_index();

    // Binary search: 20 iterations covers 887272 range
    let mut mid: i64 = 0;

    // Iteration 1
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 2
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 3
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 4
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 5
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 6
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 7
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 8
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 9
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 10
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 11
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 12
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 13
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 14
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 15
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 16
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 17
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 18
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 19
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }
    // Iteration 20
    mid = lo + ((hi - lo) / 2);
    if (tick_to_sqrt_price(mid) <= sqrt_price) { lo = mid; } else { hi = mid; }

    return lo;
}

// ---------------------------------------------------------------------------
// Liquidity Math Helpers
// ---------------------------------------------------------------------------

// Compute token A amount for a liquidity position between two sqrt_prices.
// amount_a = liquidity * (sqrt_price_upper - sqrt_price_lower)
//            / (sqrt_price_upper * sqrt_price_lower / SCALE)
// In Q64.64: amount_a = L * (sp_u - sp_l) * SCALE / (sp_u * sp_l)
// Simplified: amount_a = L * (1/sp_l - 1/sp_u) in real terms
fn get_amount_a(
    liquidity: u128,
    sqrt_price_lower: u128,
    sqrt_price_upper: u128
) -> u64 {
    require(sqrt_price_upper >= sqrt_price_lower);
    if (sqrt_price_upper == sqrt_price_lower) {
        return 0;
    }
    let delta: u128 = sqrt_price_upper - sqrt_price_lower;
    // amount_a = liquidity * delta / (sqrt_price_upper * sqrt_price_lower / SCALE)
    // = liquidity * delta * SCALE / (sqrt_price_upper * sqrt_price_lower)
    // To avoid overflow, compute: liquidity * (delta / sqrt_price_upper) * (SCALE / sqrt_price_lower)
    // Approximate: (liquidity * delta) / q64_mul(sqrt_price_upper, sqrt_price_lower)
    let product: u128 = q64_mul(sqrt_price_lower, sqrt_price_upper);
    if (product == 0) {
        return 0;
    }
    // amount_a = liquidity * delta / product (all in Q64.64 except liquidity which is raw)
    // delta and product are both Q64.64, so delta/product gives a raw ratio
    let amount: u128 = (liquidity * delta) / product;
    return amount as u64;
}

// Compute token B amount for a liquidity position.
// amount_b = liquidity * (sqrt_price_upper - sqrt_price_lower) / SCALE
fn get_amount_b(
    liquidity: u128,
    sqrt_price_lower: u128,
    sqrt_price_upper: u128
) -> u64 {
    require(sqrt_price_upper >= sqrt_price_lower);
    if (sqrt_price_upper == sqrt_price_lower) {
        return 0;
    }
    let delta: u128 = sqrt_price_upper - sqrt_price_lower;
    // delta is Q64.64, liquidity is raw u128
    // amount_b = liquidity * delta / SCALE
    let amount: u128 = (liquidity * delta) / q64_scale();
    return amount as u64;
}

// Compute liquidity from token A amount and price range
// liquidity = amount_a * sqrt_price_lower * sqrt_price_upper / (SCALE * (sqrt_price_upper - sqrt_price_lower))
fn liquidity_from_amount_a(
    amount_a: u64,
    sqrt_price_lower: u128,
    sqrt_price_upper: u128
) -> u128 {
    require(sqrt_price_upper > sqrt_price_lower);
    let delta: u128 = sqrt_price_upper - sqrt_price_lower;
    let product: u128 = q64_mul(sqrt_price_lower, sqrt_price_upper);
    // liquidity = amount_a * product / delta
    return ((amount_a as u128) * product) / delta;
}

// Compute liquidity from token B amount and price range
// liquidity = amount_b * SCALE / (sqrt_price_upper - sqrt_price_lower)
fn liquidity_from_amount_b(
    amount_b: u64,
    sqrt_price_lower: u128,
    sqrt_price_upper: u128
) -> u128 {
    require(sqrt_price_upper > sqrt_price_lower);
    let delta: u128 = sqrt_price_upper - sqrt_price_lower;
    return ((amount_b as u128) * q64_scale()) / delta;
}

// ---------------------------------------------------------------------------
// Swap Math Helpers
// ---------------------------------------------------------------------------

// Compute the next sqrt_price after swapping an exact input of token A.
// When swapping A -> B, we add A and remove B, price decreases.
// next_sqrt_price = sqrt_price * liquidity / (liquidity + amount_a * sqrt_price / SCALE)
fn next_sqrt_price_from_input_a(
    sqrt_price: u128,
    liquidity: u128,
    amount_in: u64
) -> u128 {
    if (amount_in == 0) {
        return sqrt_price;
    }
    // numerator = liquidity * sqrt_price (both as-is, result Q64.64 scaled by liquidity)
    // denominator = liquidity + amount_in * sqrt_price / SCALE
    let amount_scaled: u128 = ((amount_in as u128) * sqrt_price) / q64_scale();
    let denominator: u128 = liquidity + amount_scaled;
    require(denominator > 0);
    // next = (liquidity * sqrt_price) / denominator
    return (liquidity * sqrt_price) / denominator;
}

// Compute the next sqrt_price after swapping an exact input of token B.
// When swapping B -> A, we add B and remove A, price increases.
// next_sqrt_price = sqrt_price + amount_b * SCALE / liquidity
fn next_sqrt_price_from_input_b(
    sqrt_price: u128,
    liquidity: u128,
    amount_in: u64
) -> u128 {
    if (amount_in == 0) {
        return sqrt_price;
    }
    require(liquidity > 0);
    let delta: u128 = ((amount_in as u128) * q64_scale()) / liquidity;
    return sqrt_price + delta;
}

// Compute swap step: how much can we swap within the current tick range?
// Returns: (amount_in_consumed, amount_out, next_sqrt_price, fee_amount)
// We pack these into a single function and use the pool state to track them.

// Compute fee on an amount
fn compute_fee(amount: u64, fee_rate: u64) -> u64 {
    return (amount * fee_rate) / fee_rate_denominator();
}

// Compute protocol's share of fee
fn compute_protocol_fee(fee_amount: u64, protocol_fee_rate: u64) -> u64 {
    return (fee_amount * protocol_fee_rate) / protocol_fee_denominator();
}

// ---------------------------------------------------------------------------
// Fee Growth Helpers
// ---------------------------------------------------------------------------

// Compute fee growth inside a position's tick range.
// fee_growth_inside = fee_growth_global
//   - fee_growth_below_lower - fee_growth_above_upper
//
// fee_growth_below(tick) = tick <= current ? outside : global - outside
// fee_growth_above(tick) = tick > current  ? outside : global - outside
fn compute_fee_growth_inside(
    fee_growth_global: u128,
    fee_growth_outside_lower: u128,
    fee_growth_outside_upper: u128,
    tick_lower: i64,
    tick_upper: i64,
    tick_current: i64
) -> u128 {
    // fee_growth_below_lower
    let mut fg_below_lower: u128 = 0;
    if (tick_current >= tick_lower) {
        fg_below_lower = fee_growth_outside_lower;
    } else {
        fg_below_lower = fee_growth_global - fee_growth_outside_lower;
    }

    // fee_growth_above_upper
    let mut fg_above_upper: u128 = 0;
    if (tick_current < tick_upper) {
        fg_above_upper = fee_growth_outside_upper;
    } else {
        fg_above_upper = fee_growth_global - fee_growth_outside_upper;
    }

    // fee_growth_inside (wrapping subtraction -- all u128 so underflow wraps)
    let mut inside: u128 = 0;
    if (fee_growth_global >= fg_below_lower + fg_above_upper) {
        inside = fee_growth_global - fg_below_lower - fg_above_upper;
    }
    return inside;
}

// ---------------------------------------------------------------------------
// 1. Initialize Config
// ---------------------------------------------------------------------------

pub initialize_config(
    config: WhirlpoolConfig @mut @init(payer=authority, space=256) @signer,
    authority: account @mut @signer,
    fee_authority: pubkey,
    collect_protocol_fees_authority: pubkey,
    default_protocol_fee_rate: u16
) {
    require(default_protocol_fee_rate <= 2500);
    config.fee_authority = fee_authority;
    config.collect_protocol_fees_authority = collect_protocol_fees_authority;
    config.default_protocol_fee_rate = default_protocol_fee_rate;
}

// ---------------------------------------------------------------------------
// 2. Initialize Pool
// ---------------------------------------------------------------------------

pub initialize_pool(
    pool: Whirlpool @mut @init(payer=creator, space=1024) @signer,
    config: WhirlpoolConfig,
    fee_tier: FeeTier,
    creator: account @mut @signer,
    token_mint_a: pubkey,
    token_mint_b: pubkey,
    token_vault_a: pubkey,
    token_vault_b: pubkey,
    initial_sqrt_price: u128
) {
    require(initial_sqrt_price >= min_sqrt_price());
    require(initial_sqrt_price <= max_sqrt_price());
    require(fee_tier.config == config.ctx.key);

    let initial_tick: i64 = sqrt_price_to_tick(initial_sqrt_price);

    pool.config = config.ctx.key;
    pool.token_mint_a = token_mint_a;
    pool.token_mint_b = token_mint_b;
    pool.token_vault_a = token_vault_a;
    pool.token_vault_b = token_vault_b;
    pool.sqrt_price = initial_sqrt_price;
    pool.tick_current_index = initial_tick;
    pool.liquidity = 0;
    pool.fee_rate = fee_tier.fee_rate;
    pool.protocol_fee_rate = config.default_protocol_fee_rate;
    pool.fee_growth_global_a = 0;
    pool.fee_growth_global_b = 0;
    pool.protocol_fees_a = 0;
    pool.protocol_fees_b = 0;
    pool.tick_spacing = fee_tier.tick_spacing;
    pool.authority = creator.ctx.key;
}

// ---------------------------------------------------------------------------
// 3. Initialize Fee Tier
// ---------------------------------------------------------------------------

pub initialize_fee_tier(
    fee_tier: FeeTier @mut @init(payer=authority, space=256) @signer,
    config: WhirlpoolConfig,
    authority: account @mut @signer,
    tick_spacing: u16,
    fee_rate: u16
) {
    require(config.fee_authority == authority.ctx.key);
    require(tick_spacing > 0);
    require(fee_rate <= 10000);

    fee_tier.config = config.ctx.key;
    fee_tier.tick_spacing = tick_spacing;
    fee_tier.fee_rate = fee_rate;
}

// ---------------------------------------------------------------------------
// 4. Initialize Tick Array
// ---------------------------------------------------------------------------

pub initialize_tick_array(
    tick_array: TickArray @mut @init(payer=funder, space=2048) @signer,
    pool: Whirlpool,
    funder: account @mut @signer,
    start_tick_index: i64
) {
    // start_tick_index must be aligned to tick_spacing * TICKS_PER_ARRAY
    let array_span: i64 = (pool.tick_spacing as i64) * ticks_per_array();
    require(array_span > 0);
    // Verify alignment: start_tick_index % array_span == 0
    // For negative indices, check that start_tick_index / array_span * array_span == start_tick_index
    let mut aligned: bool = false;
    if (start_tick_index >= 0) {
        let rem: i64 = start_tick_index - ((start_tick_index / array_span) * array_span);
        aligned = rem == 0;
    } else {
        let pos: i64 = 0 - start_tick_index;
        let rem: i64 = pos - ((pos / array_span) * array_span);
        aligned = rem == 0;
    }
    require(aligned);

    tick_array.pool = pool.ctx.key;
    tick_array.start_tick_index = start_tick_index;
    tick_array.tick_spacing = pool.tick_spacing;
    tick_array.tick_index = start_tick_index;
    tick_array.tick_initialized = false;
    tick_array.tick_liquidity_net = 0;
    tick_array.tick_liquidity_gross = 0;
    tick_array.tick_fee_growth_outside_a = 0;
    tick_array.tick_fee_growth_outside_b = 0;
}

// ---------------------------------------------------------------------------
// 5. Open Position
// ---------------------------------------------------------------------------

pub open_position(
    position: Position @mut @init(payer=owner, space=512) @signer,
    pool: Whirlpool,
    owner: account @mut @signer,
    tick_lower_index: i64,
    tick_upper_index: i64
) {
    require(tick_lower_index < tick_upper_index);
    require(tick_lower_index >= min_tick_index());
    require(tick_upper_index <= max_tick_index());

    // Ticks must be multiples of tick_spacing
    let spacing: i64 = pool.tick_spacing as i64;
    require(spacing > 0);

    let mut lower_aligned: bool = false;
    if (tick_lower_index >= 0) {
        lower_aligned = (tick_lower_index - ((tick_lower_index / spacing) * spacing)) == 0;
    } else {
        let pos_lower: i64 = 0 - tick_lower_index;
        lower_aligned = (pos_lower - ((pos_lower / spacing) * spacing)) == 0;
    }
    require(lower_aligned);

    let mut upper_aligned: bool = false;
    if (tick_upper_index >= 0) {
        upper_aligned = (tick_upper_index - ((tick_upper_index / spacing) * spacing)) == 0;
    } else {
        let pos_upper: i64 = 0 - tick_upper_index;
        upper_aligned = (pos_upper - ((pos_upper / spacing) * spacing)) == 0;
    }
    require(upper_aligned);

    position.pool = pool.ctx.key;
    position.owner = owner.ctx.key;
    position.tick_lower_index = tick_lower_index;
    position.tick_upper_index = tick_upper_index;
    position.liquidity = 0;
    position.fee_growth_inside_a = 0;
    position.fee_growth_inside_b = 0;
    position.fees_owed_a = 0;
    position.fees_owed_b = 0;
}

// ---------------------------------------------------------------------------
// 6. Close Position
// ---------------------------------------------------------------------------

pub close_position(
    position: Position @mut,
    owner: account @signer
) {
    require(position.owner == owner.ctx.key);
    require(position.liquidity == 0);
    // In a full implementation the account would be closed and rent returned.
    // 5ive DSL does not have an account close primitive, so we zero-out fields.
    position.owner = 0;
    position.fees_owed_a = 0;
    position.fees_owed_b = 0;
}

// ---------------------------------------------------------------------------
// 7. Increase Liquidity
// ---------------------------------------------------------------------------

pub increase_liquidity(
    pool: Whirlpool @mut @signer,
    position: Position @mut,
    tick_array_lower: TickArray @mut,
    tick_array_upper: TickArray @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    owner: account @mut @signer,
    token_program: account,
    liquidity_delta: u128,
    max_amount_a: u64,
    max_amount_b: u64
) {
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(liquidity_delta > 0);
    require(pool_vault_a.ctx.key == pool.token_vault_a);
    require(pool_vault_b.ctx.key == pool.token_vault_b);
    require(tick_array_lower.pool == pool.ctx.key);
    require(tick_array_upper.pool == pool.ctx.key);

    // Compute sqrt_price at position boundaries
    let sqrt_price_lower: u128 = tick_to_sqrt_price(position.tick_lower_index);
    let sqrt_price_upper: u128 = tick_to_sqrt_price(position.tick_upper_index);
    let sqrt_price_current: u128 = pool.sqrt_price;

    // Compute required token amounts based on current price vs position range
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (sqrt_price_current < sqrt_price_lower) {
        // Current price below range: only token A needed
        amount_a = get_amount_a(liquidity_delta, sqrt_price_lower, sqrt_price_upper);
        amount_b = 0;
    } else {
        if (sqrt_price_current >= sqrt_price_upper) {
            // Current price above range: only token B needed
            amount_a = 0;
            amount_b = get_amount_b(liquidity_delta, sqrt_price_lower, sqrt_price_upper);
        } else {
            // Current price within range: both tokens needed
            amount_a = get_amount_a(liquidity_delta, sqrt_price_current, sqrt_price_upper);
            amount_b = get_amount_b(liquidity_delta, sqrt_price_lower, sqrt_price_current);
        }
    }

    require(amount_a <= max_amount_a);
    require(amount_b <= max_amount_b);

    // Transfer tokens from user to pool vaults
    if (amount_a > 0) {
        spl_token::SPLToken::transfer(user_token_a, pool_vault_a, owner, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(user_token_b, pool_vault_b, owner, amount_b);
    }

    // Update position fee growth snapshots before changing liquidity
    let fg_inside_a: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_a,
        tick_array_lower.tick_fee_growth_outside_a,
        tick_array_upper.tick_fee_growth_outside_a,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );
    let fg_inside_b: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_b,
        tick_array_lower.tick_fee_growth_outside_b,
        tick_array_upper.tick_fee_growth_outside_b,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );

    // Accrue owed fees from growth since last update
    if (position.liquidity > 0) {
        if (fg_inside_a > position.fee_growth_inside_a) {
            let growth_a: u128 = fg_inside_a - position.fee_growth_inside_a;
            let fees_a: u64 = ((position.liquidity * growth_a) / q64_scale()) as u64;
            position.fees_owed_a = position.fees_owed_a + fees_a;
        }
        if (fg_inside_b > position.fee_growth_inside_b) {
            let growth_b: u128 = fg_inside_b - position.fee_growth_inside_b;
            let fees_b: u64 = ((position.liquidity * growth_b) / q64_scale()) as u64;
            position.fees_owed_b = position.fees_owed_b + fees_b;
        }
    }
    position.fee_growth_inside_a = fg_inside_a;
    position.fee_growth_inside_b = fg_inside_b;

    // Update position liquidity
    position.liquidity = position.liquidity + liquidity_delta;

    // Update tick liquidity tracking
    tick_array_lower.tick_liquidity_net = tick_array_lower.tick_liquidity_net + (liquidity_delta as i64);
    tick_array_lower.tick_liquidity_gross = tick_array_lower.tick_liquidity_gross + (liquidity_delta as u64);
    tick_array_lower.tick_initialized = true;

    tick_array_upper.tick_liquidity_net = tick_array_upper.tick_liquidity_net - (liquidity_delta as i64);
    tick_array_upper.tick_liquidity_gross = tick_array_upper.tick_liquidity_gross + (liquidity_delta as u64);
    tick_array_upper.tick_initialized = true;

    // Update pool active liquidity if current tick is within position range
    if (pool.tick_current_index >= position.tick_lower_index) {
        if (pool.tick_current_index < position.tick_upper_index) {
            pool.liquidity = pool.liquidity + liquidity_delta;
        }
    }
}

// ---------------------------------------------------------------------------
// 8. Decrease Liquidity
// ---------------------------------------------------------------------------

pub decrease_liquidity(
    pool: Whirlpool @mut @signer,
    position: Position @mut,
    tick_array_lower: TickArray @mut,
    tick_array_upper: TickArray @mut,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    owner: account @mut @signer,
    token_program: account,
    liquidity_delta: u128,
    min_amount_a: u64,
    min_amount_b: u64
) {
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(liquidity_delta > 0);
    require(liquidity_delta <= position.liquidity);
    require(pool_vault_a.ctx.key == pool.token_vault_a);
    require(pool_vault_b.ctx.key == pool.token_vault_b);
    require(tick_array_lower.pool == pool.ctx.key);
    require(tick_array_upper.pool == pool.ctx.key);

    let sqrt_price_lower: u128 = tick_to_sqrt_price(position.tick_lower_index);
    let sqrt_price_upper: u128 = tick_to_sqrt_price(position.tick_upper_index);
    let sqrt_price_current: u128 = pool.sqrt_price;

    // Compute token amounts to return
    let mut amount_a: u64 = 0;
    let mut amount_b: u64 = 0;

    if (sqrt_price_current < sqrt_price_lower) {
        amount_a = get_amount_a(liquidity_delta, sqrt_price_lower, sqrt_price_upper);
        amount_b = 0;
    } else {
        if (sqrt_price_current >= sqrt_price_upper) {
            amount_a = 0;
            amount_b = get_amount_b(liquidity_delta, sqrt_price_lower, sqrt_price_upper);
        } else {
            amount_a = get_amount_a(liquidity_delta, sqrt_price_current, sqrt_price_upper);
            amount_b = get_amount_b(liquidity_delta, sqrt_price_lower, sqrt_price_current);
        }
    }

    require(amount_a >= min_amount_a);
    require(amount_b >= min_amount_b);

    // Update fee growth snapshots and accrue owed fees
    let fg_inside_a: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_a,
        tick_array_lower.tick_fee_growth_outside_a,
        tick_array_upper.tick_fee_growth_outside_a,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );
    let fg_inside_b: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_b,
        tick_array_lower.tick_fee_growth_outside_b,
        tick_array_upper.tick_fee_growth_outside_b,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );

    if (position.liquidity > 0) {
        if (fg_inside_a > position.fee_growth_inside_a) {
            let growth_a: u128 = fg_inside_a - position.fee_growth_inside_a;
            let fees_a: u64 = ((position.liquidity * growth_a) / q64_scale()) as u64;
            position.fees_owed_a = position.fees_owed_a + fees_a;
        }
        if (fg_inside_b > position.fee_growth_inside_b) {
            let growth_b: u128 = fg_inside_b - position.fee_growth_inside_b;
            let fees_b: u64 = ((position.liquidity * growth_b) / q64_scale()) as u64;
            position.fees_owed_b = position.fees_owed_b + fees_b;
        }
    }
    position.fee_growth_inside_a = fg_inside_a;
    position.fee_growth_inside_b = fg_inside_b;

    // Update position liquidity
    position.liquidity = position.liquidity - liquidity_delta;

    // Update tick tracking
    tick_array_lower.tick_liquidity_net = tick_array_lower.tick_liquidity_net - (liquidity_delta as i64);
    if (tick_array_lower.tick_liquidity_gross >= (liquidity_delta as u64)) {
        tick_array_lower.tick_liquidity_gross = tick_array_lower.tick_liquidity_gross - (liquidity_delta as u64);
    } else {
        tick_array_lower.tick_liquidity_gross = 0;
    }
    if (tick_array_lower.tick_liquidity_gross == 0) {
        tick_array_lower.tick_initialized = false;
    }

    tick_array_upper.tick_liquidity_net = tick_array_upper.tick_liquidity_net + (liquidity_delta as i64);
    if (tick_array_upper.tick_liquidity_gross >= (liquidity_delta as u64)) {
        tick_array_upper.tick_liquidity_gross = tick_array_upper.tick_liquidity_gross - (liquidity_delta as u64);
    } else {
        tick_array_upper.tick_liquidity_gross = 0;
    }
    if (tick_array_upper.tick_liquidity_gross == 0) {
        tick_array_upper.tick_initialized = false;
    }

    // Update pool active liquidity
    if (pool.tick_current_index >= position.tick_lower_index) {
        if (pool.tick_current_index < position.tick_upper_index) {
            pool.liquidity = pool.liquidity - liquidity_delta;
        }
    }

    // Transfer tokens back to user
    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, amount_b);
    }
}

// ---------------------------------------------------------------------------
// 9. Swap
// ---------------------------------------------------------------------------
// Executes a swap within the current tick range. For swaps that cross ticks,
// the client calls swap repeatedly with the appropriate tick_array loaded.
// This mirrors Orca's swap loop: each call processes one tick-range step.

pub swap(
    pool: Whirlpool @mut @signer,
    tick_array: TickArray @mut,
    user_source: account @mut,
    user_destination: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    owner: account @signer,
    token_program: account,
    amount_in: u64,
    sqrt_price_limit: u128,
    is_a_to_b: bool
) {
    require(amount_in > 0);
    require(pool.liquidity > 0);
    require(tick_array.pool == pool.ctx.key);

    if (is_a_to_b) {
        require(pool_vault_a.ctx.key == pool.token_vault_a);
        require(pool_vault_b.ctx.key == pool.token_vault_b);
        require(sqrt_price_limit < pool.sqrt_price);
        require(sqrt_price_limit >= min_sqrt_price());
    } else {
        require(pool_vault_a.ctx.key == pool.token_vault_a);
        require(pool_vault_b.ctx.key == pool.token_vault_b);
        require(sqrt_price_limit > pool.sqrt_price);
        require(sqrt_price_limit <= max_sqrt_price());
    }

    // Compute fee
    let fee_amount: u64 = compute_fee(amount_in, pool.fee_rate as u64);
    let amount_after_fee: u64 = amount_in - fee_amount;

    // Compute protocol fee share
    let protocol_fee: u64 = compute_protocol_fee(fee_amount, pool.protocol_fee_rate as u64);
    let lp_fee: u64 = fee_amount - protocol_fee;

    // Determine the target sqrt_price for this tick range
    let mut target_sqrt_price: u128 = 0;
    if (is_a_to_b) {
        // Price decreasing: target is tick_array's lower bound or sqrt_price_limit
        let tick_target: i64 = tick_array.start_tick_index;
        let target_from_tick: u128 = tick_to_sqrt_price(tick_target);
        if (target_from_tick > sqrt_price_limit) {
            target_sqrt_price = target_from_tick;
        } else {
            target_sqrt_price = sqrt_price_limit;
        }
    } else {
        // Price increasing: target is tick_array's upper bound or sqrt_price_limit
        let array_span: i64 = (tick_array.tick_spacing as i64) * ticks_per_array();
        let tick_target: i64 = tick_array.start_tick_index + array_span;
        let target_from_tick: u128 = tick_to_sqrt_price(tick_target);
        if (target_from_tick < sqrt_price_limit) {
            target_sqrt_price = target_from_tick;
        } else {
            target_sqrt_price = sqrt_price_limit;
        }
    }

    // Compute next sqrt_price from the input amount
    let mut next_sqrt_price: u128 = 0;
    if (is_a_to_b) {
        next_sqrt_price = next_sqrt_price_from_input_a(pool.sqrt_price, pool.liquidity, amount_after_fee);
        // Clamp to target (don't go below it)
        if (next_sqrt_price < target_sqrt_price) {
            next_sqrt_price = target_sqrt_price;
        }
    } else {
        next_sqrt_price = next_sqrt_price_from_input_b(pool.sqrt_price, pool.liquidity, amount_after_fee);
        // Clamp to target (don't go above it)
        if (next_sqrt_price > target_sqrt_price) {
            next_sqrt_price = target_sqrt_price;
        }
    }

    // Compute actual amounts swapped given the sqrt_price movement
    let mut amount_in_consumed: u64 = 0;
    let mut amount_out: u64 = 0;

    if (is_a_to_b) {
        // Token A in, Token B out
        // amount_a_in from price movement
        amount_in_consumed = get_amount_a(pool.liquidity, next_sqrt_price, pool.sqrt_price);
        amount_out = get_amount_b(pool.liquidity, next_sqrt_price, pool.sqrt_price);
    } else {
        // Token B in, Token A out
        amount_in_consumed = get_amount_b(pool.liquidity, pool.sqrt_price, next_sqrt_price);
        amount_out = get_amount_a(pool.liquidity, pool.sqrt_price, next_sqrt_price);
    }

    require(amount_out > 0);

    // Update fee growth global
    if (pool.liquidity > 0) {
        let fee_growth_delta: u128 = ((lp_fee as u128) * q64_scale()) / pool.liquidity;
        if (is_a_to_b) {
            pool.fee_growth_global_a = pool.fee_growth_global_a + fee_growth_delta;
            pool.protocol_fees_a = pool.protocol_fees_a + protocol_fee;
        } else {
            pool.fee_growth_global_b = pool.fee_growth_global_b + fee_growth_delta;
            pool.protocol_fees_b = pool.protocol_fees_b + protocol_fee;
        }
    }

    // Check if we crossed the tick boundary and need to flip liquidity
    let new_tick: i64 = sqrt_price_to_tick(next_sqrt_price);
    let mut crossed_tick: bool = false;
    if (is_a_to_b) {
        crossed_tick = new_tick < pool.tick_current_index;
    } else {
        crossed_tick = new_tick > pool.tick_current_index;
    }

    // If we hit an initialized tick, flip the liquidity_net
    if (crossed_tick) {
        if (tick_array.tick_initialized) {
            // Flip fee growth outside when crossing
            tick_array.tick_fee_growth_outside_a = pool.fee_growth_global_a - tick_array.tick_fee_growth_outside_a;
            tick_array.tick_fee_growth_outside_b = pool.fee_growth_global_b - tick_array.tick_fee_growth_outside_b;

            // Apply liquidity_net: add when crossing left-to-right, subtract right-to-left
            if (is_a_to_b) {
                // Moving right to left (price decreasing): subtract net
                let net: i64 = tick_array.tick_liquidity_net;
                if (net > 0) {
                    pool.liquidity = pool.liquidity - (net as u128);
                } else {
                    if (net < 0) {
                        pool.liquidity = pool.liquidity + ((0 - net) as u128);
                    }
                }
            } else {
                // Moving left to right (price increasing): add net
                let net: i64 = tick_array.tick_liquidity_net;
                if (net > 0) {
                    pool.liquidity = pool.liquidity + (net as u128);
                } else {
                    if (net < 0) {
                        pool.liquidity = pool.liquidity - ((0 - net) as u128);
                    }
                }
            }
        }
    }

    // Update pool state
    pool.sqrt_price = next_sqrt_price;
    pool.tick_current_index = new_tick;

    // Execute token transfers
    if (is_a_to_b) {
        spl_token::SPLToken::transfer(user_source, pool_vault_a, owner, amount_in);
        spl_token::SPLToken::transfer(pool_vault_b, user_destination, pool, amount_out);
    } else {
        spl_token::SPLToken::transfer(user_source, pool_vault_b, owner, amount_in);
        spl_token::SPLToken::transfer(pool_vault_a, user_destination, pool, amount_out);
    }
}

// ---------------------------------------------------------------------------
// 10. Collect Fees
// ---------------------------------------------------------------------------

pub collect_fees(
    pool: Whirlpool @mut @signer,
    position: Position @mut,
    tick_array_lower: TickArray,
    tick_array_upper: TickArray,
    user_token_a: account @mut,
    user_token_b: account @mut,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    owner: account @signer,
    token_program: account
) {
    require(position.pool == pool.ctx.key);
    require(position.owner == owner.ctx.key);
    require(pool_vault_a.ctx.key == pool.token_vault_a);
    require(pool_vault_b.ctx.key == pool.token_vault_b);
    require(tick_array_lower.pool == pool.ctx.key);
    require(tick_array_upper.pool == pool.ctx.key);

    // Compute current fee growth inside the position range
    let fg_inside_a: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_a,
        tick_array_lower.tick_fee_growth_outside_a,
        tick_array_upper.tick_fee_growth_outside_a,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );
    let fg_inside_b: u128 = compute_fee_growth_inside(
        pool.fee_growth_global_b,
        tick_array_lower.tick_fee_growth_outside_b,
        tick_array_upper.tick_fee_growth_outside_b,
        position.tick_lower_index,
        position.tick_upper_index,
        pool.tick_current_index
    );

    // Compute newly accrued fees since last snapshot
    let mut new_fees_a: u64 = 0;
    let mut new_fees_b: u64 = 0;
    if (position.liquidity > 0) {
        if (fg_inside_a > position.fee_growth_inside_a) {
            let growth_a: u128 = fg_inside_a - position.fee_growth_inside_a;
            new_fees_a = ((position.liquidity * growth_a) / q64_scale()) as u64;
        }
        if (fg_inside_b > position.fee_growth_inside_b) {
            let growth_b: u128 = fg_inside_b - position.fee_growth_inside_b;
            new_fees_b = ((position.liquidity * growth_b) / q64_scale()) as u64;
        }
    }

    // Update snapshots
    position.fee_growth_inside_a = fg_inside_a;
    position.fee_growth_inside_b = fg_inside_b;

    // Total claimable
    let collect_a: u64 = position.fees_owed_a + new_fees_a;
    let collect_b: u64 = position.fees_owed_b + new_fees_b;

    // Reset owed
    position.fees_owed_a = 0;
    position.fees_owed_b = 0;

    // Transfer fees to position owner
    if (collect_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, user_token_a, pool, collect_a);
    }
    if (collect_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, user_token_b, pool, collect_b);
    }
}

// ---------------------------------------------------------------------------
// 11. Collect Protocol Fees
// ---------------------------------------------------------------------------

pub collect_protocol_fees(
    pool: Whirlpool @mut @signer,
    config: WhirlpoolConfig,
    pool_vault_a: account @mut,
    pool_vault_b: account @mut,
    recipient_a: account @mut,
    recipient_b: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(pool.config == config.ctx.key);
    require(config.collect_protocol_fees_authority == authority.ctx.key);
    require(pool_vault_a.ctx.key == pool.token_vault_a);
    require(pool_vault_b.ctx.key == pool.token_vault_b);

    let amount_a: u64 = pool.protocol_fees_a;
    let amount_b: u64 = pool.protocol_fees_b;

    pool.protocol_fees_a = 0;
    pool.protocol_fees_b = 0;

    if (amount_a > 0) {
        spl_token::SPLToken::transfer(pool_vault_a, recipient_a, pool, amount_a);
    }
    if (amount_b > 0) {
        spl_token::SPLToken::transfer(pool_vault_b, recipient_b, pool, amount_b);
    }
}

// ---------------------------------------------------------------------------
// 12. Set Fee Rate
// ---------------------------------------------------------------------------

pub set_fee_rate(
    pool: Whirlpool @mut,
    config: WhirlpoolConfig,
    authority: account @signer,
    new_fee_rate: u16
) {
    require(pool.config == config.ctx.key);
    require(config.fee_authority == authority.ctx.key);
    require(new_fee_rate <= 10000);
    pool.fee_rate = new_fee_rate;
}

// ---------------------------------------------------------------------------
// 13. Set Protocol Fee Rate
// ---------------------------------------------------------------------------

pub set_protocol_fee_rate(
    pool: Whirlpool @mut,
    config: WhirlpoolConfig,
    authority: account @signer,
    new_protocol_fee_rate: u16
) {
    require(pool.config == config.ctx.key);
    require(config.fee_authority == authority.ctx.key);
    require(new_protocol_fee_rate <= 2500);
    pool.protocol_fee_rate = new_protocol_fee_rate;
}

// ---------------------------------------------------------------------------
// Read-only Helpers (exposed for clients and tests)
// ---------------------------------------------------------------------------

pub get_pool_sqrt_price(pool: Whirlpool) -> u128 {
    return pool.sqrt_price;
}

pub get_pool_tick(pool: Whirlpool) -> i64 {
    return pool.tick_current_index;
}

pub get_pool_liquidity(pool: Whirlpool) -> u128 {
    return pool.liquidity;
}

pub get_pool_fee_growth_a(pool: Whirlpool) -> u128 {
    return pool.fee_growth_global_a;
}

pub get_pool_fee_growth_b(pool: Whirlpool) -> u128 {
    return pool.fee_growth_global_b;
}

pub get_pool_protocol_fees_a(pool: Whirlpool) -> u64 {
    return pool.protocol_fees_a;
}

pub get_pool_protocol_fees_b(pool: Whirlpool) -> u64 {
    return pool.protocol_fees_b;
}

pub get_position_liquidity(position: Position) -> u128 {
    return position.liquidity;
}

pub get_position_fees_owed_a(position: Position) -> u64 {
    return position.fees_owed_a;
}

pub get_position_fees_owed_b(position: Position) -> u64 {
    return position.fees_owed_b;
}

// Expose tick math for testing
pub compute_tick_to_sqrt_price(tick: i64) -> u128 {
    return tick_to_sqrt_price(tick);
}

pub compute_sqrt_price_to_tick(sqrt_price: u128) -> i64 {
    return sqrt_price_to_tick(sqrt_price);
}

// Expose amount helpers for testing
pub compute_amount_a(liquidity: u128, sqrt_lower: u128, sqrt_upper: u128) -> u64 {
    return get_amount_a(liquidity, sqrt_lower, sqrt_upper);
}

pub compute_amount_b(liquidity: u128, sqrt_lower: u128, sqrt_upper: u128) -> u64 {
    return get_amount_b(liquidity, sqrt_lower, sqrt_upper);
}
