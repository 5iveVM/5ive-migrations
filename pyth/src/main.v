// 5IVE Pyth Network Oracle - Canonical migration
//
// Design (Pyth Network-inspired):
//   - Products represent tradeable assets with metadata
//   - Price feeds aggregate multiple publisher quotes into authoritative prices
//   - Publishers are authorized entities that submit price + confidence
//   - Aggregation uses weighted median with confidence-based weighting
//   - Staleness detection: prices older than staleness_slots are marked stale
//   - Status tracking: unknown (0), trading (1), halted (2)
//   - All prices are i64 (signed, supports negative for derivatives)
//   - Exponent stored as i64 (e.g., -8 means price * 10^-8)
//   - Confidence is u64 (always positive uncertainty range)

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account OracleConfig {
    authority: pubkey;
    staleness_slots: u64;
    num_products: u64;
}

account Product {
    config: pubkey;
    symbol_high: u64;
    symbol_low: u64;
    asset_type: u8;
    price_account: pubkey;
    num_publishers: u64;
    is_active: bool;
}

account PriceFeed {
    product: pubkey;
    config: pubkey;
    price: i64;
    confidence: u64;
    exponent: i64;
    status: u8;
    last_slot: u64;
    num_publishers: u64;
    min_publishers: u64;
}

account PublisherPrice {
    feed: pubkey;
    publisher: pubkey;
    price: i64;
    confidence: u64;
    last_slot: u64;
    status: u8;
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Constants (as fn helpers — 5ive has no top-level const)
// ---------------------------------------------------------------------------

fn status_unknown() -> u8 { return 0; }
fn status_trading() -> u8 { return 1; }
fn status_halted() -> u8 { return 2; }
fn max_publishers() -> u64 { return 64; }
fn default_staleness() -> u64 { return 25; }

// ---------------------------------------------------------------------------
// Admin: init_mapping — bootstrap the oracle
// ---------------------------------------------------------------------------

pub init_mapping(
    config: OracleConfig @mut @init(payer=authority, space=256),
    authority: account @mut @signer,
    staleness_slots: u64
) {
    let mut staleness: u64 = staleness_slots;
    if (staleness == 0) {
        staleness = default_staleness();
    }
    config.authority = authority.ctx.key;
    config.staleness_slots = staleness;
    config.num_products = 0;
}

// ---------------------------------------------------------------------------
// Admin: add_product — register a new asset (e.g., SOL/USD)
// ---------------------------------------------------------------------------

pub add_product(
    config: OracleConfig @mut,
    product: Product @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    symbol_high: u64,
    symbol_low: u64,
    asset_type: u8
) {
    require(config.authority == authority.ctx.key);
    require(asset_type <= 10);

    product.config = config.ctx.key;
    product.symbol_high = symbol_high;
    product.symbol_low = symbol_low;
    product.asset_type = asset_type;
    product.num_publishers = 0;
    product.is_active = true;

    config.num_products = config.num_products + 1;
}

// ---------------------------------------------------------------------------
// Admin: add_price — create a price feed for a product
// ---------------------------------------------------------------------------

pub add_price(
    config: OracleConfig,
    product: Product @mut,
    feed: PriceFeed @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    exponent: i64
) {
    require(config.authority == authority.ctx.key);
    require(product.config == config.ctx.key);
    require(product.is_active);

    feed.product = product.ctx.key;
    feed.config = config.ctx.key;
    feed.price = 0;
    feed.confidence = 0;
    feed.exponent = exponent;
    feed.status = status_unknown();
    feed.last_slot = 0;
    feed.num_publishers = 0;
    feed.min_publishers = 1;

    product.price_account = feed.ctx.key;
}

// ---------------------------------------------------------------------------
// Admin: add_publisher — authorize a publisher for a price feed
// ---------------------------------------------------------------------------

pub add_publisher(
    config: OracleConfig,
    product: Product @mut,
    feed: PriceFeed @mut,
    publisher_price: PublisherPrice @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    publisher: pubkey
) {
    require(config.authority == authority.ctx.key);
    require(product.config == config.ctx.key);
    require(feed.product == product.ctx.key);
    require(feed.num_publishers < max_publishers());

    publisher_price.feed = feed.ctx.key;
    publisher_price.publisher = publisher;
    publisher_price.price = 0;
    publisher_price.confidence = 0;
    publisher_price.last_slot = 0;
    publisher_price.status = status_unknown();
    publisher_price.is_active = true;

    feed.num_publishers = feed.num_publishers + 1;
    product.num_publishers = product.num_publishers + 1;
}

// ---------------------------------------------------------------------------
// Admin: del_publisher — remove a publisher from a price feed
// ---------------------------------------------------------------------------

pub del_publisher(
    config: OracleConfig,
    product: Product @mut,
    feed: PriceFeed @mut,
    publisher_price: PublisherPrice @mut,
    authority: account @signer
) {
    require(config.authority == authority.ctx.key);
    require(product.config == config.ctx.key);
    require(feed.product == product.ctx.key);
    require(publisher_price.feed == feed.ctx.key);
    require(publisher_price.is_active);

    publisher_price.is_active = false;
    publisher_price.price = 0;
    publisher_price.confidence = 0;
    publisher_price.status = status_unknown();

    feed.num_publishers = feed.num_publishers - 1;
    product.num_publishers = product.num_publishers - 1;
}

// ---------------------------------------------------------------------------
// Admin: set_min_publishers — set minimum publishers for valid aggregation
// ---------------------------------------------------------------------------

pub set_min_publishers(
    config: OracleConfig,
    feed: PriceFeed @mut,
    authority: account @signer,
    min_publishers: u64
) {
    require(config.authority == authority.ctx.key);
    require(feed.config == config.ctx.key);
    require(min_publishers > 0);
    require(min_publishers <= max_publishers());

    feed.min_publishers = min_publishers;
}

// ---------------------------------------------------------------------------
// Admin: update_staleness — change the staleness window
// ---------------------------------------------------------------------------

pub update_staleness(
    config: OracleConfig @mut,
    authority: account @signer,
    new_staleness_slots: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_staleness_slots > 0);
    config.staleness_slots = new_staleness_slots;
}

// ---------------------------------------------------------------------------
// Admin: transfer_authority — transfer oracle admin to new key
// ---------------------------------------------------------------------------

pub transfer_authority(
    config: OracleConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Admin: set_product_active — pause/unpause a product
// ---------------------------------------------------------------------------

pub set_product_active(
    config: OracleConfig,
    product: Product @mut,
    authority: account @signer,
    is_active: bool
) {
    require(config.authority == authority.ctx.key);
    require(product.config == config.ctx.key);
    product.is_active = is_active;
}

// ---------------------------------------------------------------------------
// Core: update_price — publisher submits a new price + confidence
// ---------------------------------------------------------------------------

pub update_price(
    config: OracleConfig,
    feed: PriceFeed,
    publisher_price: PublisherPrice @mut,
    publisher: account @signer,
    price: i64,
    confidence: u64,
    status: u8
) {
    require(publisher_price.feed == feed.ctx.key);
    require(feed.config == config.ctx.key);
    require(publisher_price.publisher == publisher.ctx.key);
    require(publisher_price.is_active);
    require(status <= 2);
    require(confidence > 0);

    let current_slot: u64 = get_clock().slot;

    publisher_price.price = price;
    publisher_price.confidence = confidence;
    publisher_price.last_slot = current_slot;
    publisher_price.status = status;
}

// ---------------------------------------------------------------------------
// Core: aggregate_price — compute aggregate from all publisher quotes
//
// Approach: weighted median using confidence as inverse weight.
// 1. Caller passes up to 32 publisher price accounts
// 2. Collect fresh, trading-status quotes
// 3. Sort by price (bubble sort — bounded by max_publishers)
// 4. Walk sorted prices; median where cumulative weight crosses 50%
// 5. Aggregate confidence = weighted MAD (median absolute deviation)
//
// Because 5ive doesn't have dynamic arrays or generics, we accept
// individual publisher accounts and use fixed-size local arrays
// encoded as indexed fields. For the migration we accept up to 16
// publishers per aggregation call (can be called multiple times for
// feeds with more publishers, or extended when 5ive adds arrays).
// ---------------------------------------------------------------------------

pub aggregate_price(
    config: OracleConfig,
    feed: PriceFeed @mut,
    pp0: PublisherPrice,
    pp1: PublisherPrice,
    pp2: PublisherPrice,
    pp3: PublisherPrice,
    pp4: PublisherPrice,
    pp5: PublisherPrice,
    pp6: PublisherPrice,
    pp7: PublisherPrice
) {
    let current_slot: u64 = get_clock().slot;
    let staleness: u64 = config.staleness_slots;

    // Collect fresh, active, trading publishers into parallel arrays.
    // prices[i] and weights[i] stored as individual variables.
    let mut count: u64 = 0;

    // Price slots (i64)
    let mut p0: i64 = 0;
    let mut p1: i64 = 0;
    let mut p2: i64 = 0;
    let mut p3: i64 = 0;
    let mut p4: i64 = 0;
    let mut p5: i64 = 0;
    let mut p6: i64 = 0;
    let mut p7: i64 = 0;

    // Weight slots (u64) — inverse of confidence (higher confidence = lower spread = more weight)
    // We use a fixed precision scale: weight = WEIGHT_SCALE / confidence
    let mut w0: u64 = 0;
    let mut w1: u64 = 0;
    let mut w2: u64 = 0;
    let mut w3: u64 = 0;
    let mut w4: u64 = 0;
    let mut w5: u64 = 0;
    let mut w6: u64 = 0;
    let mut w7: u64 = 0;

    // Weight scale: 1_000_000_000 for precision
    let weight_scale: u64 = 1000000000;

    // --- Collect publisher 0 ---
    if (pp0.is_active) {
        if (pp0.feed == feed.ctx.key) {
            if (pp0.status == status_trading()) {
                if (pp0.last_slot + staleness >= current_slot) {
                    if (pp0.confidence > 0) {
                        p0 = pp0.price;
                        w0 = weight_scale / pp0.confidence;
                        if (w0 == 0) { w0 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 1 ---
    if (pp1.is_active) {
        if (pp1.feed == feed.ctx.key) {
            if (pp1.status == status_trading()) {
                if (pp1.last_slot + staleness >= current_slot) {
                    if (pp1.confidence > 0) {
                        p1 = pp1.price;
                        w1 = weight_scale / pp1.confidence;
                        if (w1 == 0) { w1 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 2 ---
    if (pp2.is_active) {
        if (pp2.feed == feed.ctx.key) {
            if (pp2.status == status_trading()) {
                if (pp2.last_slot + staleness >= current_slot) {
                    if (pp2.confidence > 0) {
                        p2 = pp2.price;
                        w2 = weight_scale / pp2.confidence;
                        if (w2 == 0) { w2 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 3 ---
    if (pp3.is_active) {
        if (pp3.feed == feed.ctx.key) {
            if (pp3.status == status_trading()) {
                if (pp3.last_slot + staleness >= current_slot) {
                    if (pp3.confidence > 0) {
                        p3 = pp3.price;
                        w3 = weight_scale / pp3.confidence;
                        if (w3 == 0) { w3 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 4 ---
    if (pp4.is_active) {
        if (pp4.feed == feed.ctx.key) {
            if (pp4.status == status_trading()) {
                if (pp4.last_slot + staleness >= current_slot) {
                    if (pp4.confidence > 0) {
                        p4 = pp4.price;
                        w4 = weight_scale / pp4.confidence;
                        if (w4 == 0) { w4 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 5 ---
    if (pp5.is_active) {
        if (pp5.feed == feed.ctx.key) {
            if (pp5.status == status_trading()) {
                if (pp5.last_slot + staleness >= current_slot) {
                    if (pp5.confidence > 0) {
                        p5 = pp5.price;
                        w5 = weight_scale / pp5.confidence;
                        if (w5 == 0) { w5 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 6 ---
    if (pp6.is_active) {
        if (pp6.feed == feed.ctx.key) {
            if (pp6.status == status_trading()) {
                if (pp6.last_slot + staleness >= current_slot) {
                    if (pp6.confidence > 0) {
                        p6 = pp6.price;
                        w6 = weight_scale / pp6.confidence;
                        if (w6 == 0) { w6 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Collect publisher 7 ---
    if (pp7.is_active) {
        if (pp7.feed == feed.ctx.key) {
            if (pp7.status == status_trading()) {
                if (pp7.last_slot + staleness >= current_slot) {
                    if (pp7.confidence > 0) {
                        p7 = pp7.price;
                        w7 = weight_scale / pp7.confidence;
                        if (w7 == 0) { w7 = 1; }
                        count = count + 1;
                    }
                }
            }
        }
    }

    // --- Check minimum publisher threshold ---
    require(count >= feed.min_publishers);

    // --- Bubble sort by price (ascending) ---
    // We sort all 8 slots; unused slots have price=0 and weight=0 and
    // will not affect the weighted median since their weight is 0.
    let mut passes: u64 = 0;
    while (passes < 8) {
        // Compare adjacent pairs and swap if out of order
        if (p0 > p1) {
            let tmp_p: i64 = p0; p0 = p1; p1 = tmp_p;
            let tmp_w: u64 = w0; w0 = w1; w1 = tmp_w;
        }
        if (p1 > p2) {
            let tmp_p: i64 = p1; p1 = p2; p2 = tmp_p;
            let tmp_w: u64 = w1; w1 = w2; w2 = tmp_w;
        }
        if (p2 > p3) {
            let tmp_p: i64 = p2; p2 = p3; p3 = tmp_p;
            let tmp_w: u64 = w2; w2 = w3; w3 = tmp_w;
        }
        if (p3 > p4) {
            let tmp_p: i64 = p3; p3 = p4; p4 = tmp_p;
            let tmp_w: u64 = w3; w3 = w4; w4 = tmp_w;
        }
        if (p4 > p5) {
            let tmp_p: i64 = p4; p4 = p5; p5 = tmp_p;
            let tmp_w: u64 = w4; w4 = w5; w5 = tmp_w;
        }
        if (p5 > p6) {
            let tmp_p: i64 = p5; p5 = p6; p6 = tmp_p;
            let tmp_w: u64 = w5; w5 = w6; w6 = tmp_w;
        }
        if (p6 > p7) {
            let tmp_p: i64 = p6; p6 = p7; p7 = tmp_p;
            let tmp_w: u64 = w6; w6 = w7; w7 = tmp_w;
        }
        passes = passes + 1;
    }

    // --- Weighted median ---
    // Walk sorted prices, accumulate weight. Median is price where
    // cumulative weight first reaches or exceeds half of total weight.
    let total_weight: u64 = w0 + w1 + w2 + w3 + w4 + w5 + w6 + w7;
    let half_weight: u64 = total_weight / 2;

    let mut cumulative: u64 = 0;
    let mut median_price: i64 = 0;

    // Slot 0
    cumulative = cumulative + w0;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w0 > 0) {
                median_price = p0;
            }
        }
    }

    // Slot 1
    cumulative = cumulative + w1;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w1 > 0) {
                median_price = p1;
            }
        }
    }

    // Slot 2
    cumulative = cumulative + w2;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w2 > 0) {
                median_price = p2;
            }
        }
    }

    // Slot 3
    cumulative = cumulative + w3;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w3 > 0) {
                median_price = p3;
            }
        }
    }

    // Slot 4
    cumulative = cumulative + w4;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w4 > 0) {
                median_price = p4;
            }
        }
    }

    // Slot 5
    cumulative = cumulative + w5;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w5 > 0) {
                median_price = p5;
            }
        }
    }

    // Slot 6
    cumulative = cumulative + w6;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w6 > 0) {
                median_price = p6;
            }
        }
    }

    // Slot 7
    cumulative = cumulative + w7;
    if (median_price == 0) {
        if (cumulative > half_weight) {
            if (w7 > 0) {
                median_price = p7;
            }
        }
    }

    // Fallback: if median_price is still 0 (all prices were zero or
    // exactly zero — unlikely but possible), use the first nonzero.
    if (median_price == 0) {
        if (w0 > 0) { median_price = p0; }
    }

    // --- Aggregate confidence: weighted MAD ---
    // MAD = sum(weight_i * |price_i - median|) / total_weight
    let mut mad_sum: u64 = 0;

    let d0: u64 = abs_diff_i64(p0, median_price);
    mad_sum = mad_sum + (w0 * d0);

    let d1: u64 = abs_diff_i64(p1, median_price);
    mad_sum = mad_sum + (w1 * d1);

    let d2: u64 = abs_diff_i64(p2, median_price);
    mad_sum = mad_sum + (w2 * d2);

    let d3: u64 = abs_diff_i64(p3, median_price);
    mad_sum = mad_sum + (w3 * d3);

    let d4: u64 = abs_diff_i64(p4, median_price);
    mad_sum = mad_sum + (w4 * d4);

    let d5: u64 = abs_diff_i64(p5, median_price);
    mad_sum = mad_sum + (w5 * d5);

    let d6: u64 = abs_diff_i64(p6, median_price);
    mad_sum = mad_sum + (w6 * d6);

    let d7: u64 = abs_diff_i64(p7, median_price);
    mad_sum = mad_sum + (w7 * d7);

    let mut agg_confidence: u64 = 0;
    if (total_weight > 0) {
        agg_confidence = mad_sum / total_weight;
    }

    // Minimum confidence floor of 1 when we have valid data
    if (agg_confidence == 0) {
        if (count > 0) {
            agg_confidence = 1;
        }
    }

    // --- Write aggregated result ---
    feed.price = median_price;
    feed.confidence = agg_confidence;
    feed.last_slot = current_slot;
    feed.status = status_trading();
}

// ---------------------------------------------------------------------------
// Consumer: get_price — read the current aggregated price with staleness check
// ---------------------------------------------------------------------------

pub get_price(
    config: OracleConfig,
    feed: PriceFeed
) -> i64 {
    require(feed.config == config.ctx.key);

    let current_slot: u64 = get_clock().slot;

    // Check staleness
    if (feed.last_slot + config.staleness_slots < current_slot) {
        // Price is stale — revert
        require(false);
    }

    // Check status is trading
    require(feed.status == status_trading());

    return feed.price;
}

// ---------------------------------------------------------------------------
// Consumer: get_price_with_confidence — returns price (confidence via feed)
// ---------------------------------------------------------------------------

pub get_price_with_confidence(
    config: OracleConfig,
    feed: PriceFeed
) -> i64 {
    require(feed.config == config.ctx.key);

    let current_slot: u64 = get_clock().slot;

    if (feed.last_slot + config.staleness_slots < current_slot) {
        require(false);
    }

    require(feed.status == status_trading());

    // Caller reads feed.confidence from the account after this call
    return feed.price;
}

// ---------------------------------------------------------------------------
// Consumer: get_price_no_older_than — price with custom staleness
// ---------------------------------------------------------------------------

pub get_price_no_older_than(
    config: OracleConfig,
    feed: PriceFeed,
    max_age_slots: u64
) -> i64 {
    require(feed.config == config.ctx.key);
    require(max_age_slots > 0);

    let current_slot: u64 = get_clock().slot;

    if (feed.last_slot + max_age_slots < current_slot) {
        require(false);
    }

    require(feed.status == status_trading());

    return feed.price;
}

// ---------------------------------------------------------------------------
// Consumer: get_price_unsafe — read price without staleness check
// (for protocols that handle staleness themselves)
// ---------------------------------------------------------------------------

pub get_price_unsafe(
    feed: PriceFeed
) -> i64 {
    return feed.price;
}

// ---------------------------------------------------------------------------
// View: get_feed_status — returns status code of the feed
// ---------------------------------------------------------------------------

pub get_feed_status(feed: PriceFeed) -> u8 {
    return feed.status;
}

// ---------------------------------------------------------------------------
// View: get_feed_confidence — returns confidence of the aggregated price
// ---------------------------------------------------------------------------

pub get_feed_confidence(feed: PriceFeed) -> u64 {
    return feed.confidence;
}

// ---------------------------------------------------------------------------
// View: get_feed_exponent — returns the exponent of the price feed
// ---------------------------------------------------------------------------

pub get_feed_exponent(feed: PriceFeed) -> i64 {
    return feed.exponent;
}

// ---------------------------------------------------------------------------
// View: get_feed_last_slot — returns the slot of last aggregation
// ---------------------------------------------------------------------------

pub get_feed_last_slot(feed: PriceFeed) -> u64 {
    return feed.last_slot;
}

// ---------------------------------------------------------------------------
// View: get_num_publishers — returns the number of active publishers
// ---------------------------------------------------------------------------

pub get_num_publishers(feed: PriceFeed) -> u64 {
    return feed.num_publishers;
}

// ---------------------------------------------------------------------------
// View: is_price_stale — check if the price is stale
// ---------------------------------------------------------------------------

pub is_price_stale(
    config: OracleConfig,
    feed: PriceFeed
) -> u64 {
    let current_slot: u64 = get_clock().slot;
    if (feed.last_slot + config.staleness_slots < current_slot) {
        return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Absolute difference between two signed integers, returned as u64.
fn abs_diff_i64(a: i64, b: i64) -> u64 {
    if (a >= b) {
        return (a - b) as u64;
    }
    return (b - a) as u64;
}
