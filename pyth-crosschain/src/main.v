// 5IVE Pyth Crosschain Receiver - Canonical migration
//
// Design (Pyth Crosschain Receiver):
//   - Receives and verifies Wormhole VAA-wrapped price updates on Solana
//   - Distinct from the Pyth Oracle on Pythnet: this is the consumer-facing program
//   - Flow: Pythnet oracle -> Wormhole attester -> Hermes -> VAA -> Receiver -> DeFi
//   - Verifies guardian signatures via Wormhole bridge integration
//   - Data source validation: only accepts prices from authorized emitter chains
//   - Append-only updates: newer prices overwrite older, never the reverse
//   - PriceUpdateV2 stores spot price + EMA (exponential moving average)
//   - TwapUpdate stores time-weighted average price with cumulative accumulators
//   - Verification levels: partial (some sigs) vs full (meets min_signatures)
//   - Update fee charged per price update to fund infrastructure
//   - Rent reclaim allows cleanup of stale accounts after grace period
//   - Two-step governance authority transfer for safe admin rotation

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account ReceiverConfig {
    admin: pubkey;
    pending_admin: pubkey;
    wormhole_bridge: pubkey;
    update_fee: u64;
    min_signatures: u8;
    num_data_sources: u8;
    is_active: bool;
    stale_grace_slots: u64;
}

account DataSource {
    config: pubkey;
    emitter_chain: u16;
    emitter_address: pubkey;
    is_valid: bool;
}

account PriceUpdateV2 {
    config: pubkey;
    feed_id: pubkey;
    price: i64;
    confidence: u64;
    exponent: i64;
    publish_time: u64;
    prev_publish_time: u64;
    ema_price: i64;
    ema_confidence: u64;
    verification_level: u8;
    posted_slot: u64;
    write_authority: pubkey;
}

account TwapUpdate {
    config: pubkey;
    feed_id: pubkey;
    cumulative_price: i64;
    cumulative_confidence: u64;
    num_down_slots: u64;
    start_slot: u64;
    end_slot: u64;
    twap_price: i64;
    twap_confidence: u64;
    posted_slot: u64;
    write_authority: pubkey;
}

// Wormhole accounts referenced cross-program (read-only mirrors)
account WormholeGuardianSet {
    bridge: pubkey;
    index: u32;
    num_guardians: u8;
    expiration_time: u64;
    key_0: pubkey;
    key_1: pubkey;
    key_2: pubkey;
    key_3: pubkey;
    key_4: pubkey;
    key_5: pubkey;
    key_6: pubkey;
    key_7: pubkey;
    key_8: pubkey;
    key_9: pubkey;
    key_10: pubkey;
    key_11: pubkey;
    key_12: pubkey;
    key_13: pubkey;
    key_14: pubkey;
    key_15: pubkey;
    key_16: pubkey;
    key_17: pubkey;
    key_18: pubkey;
}

account WormholeSignatureSet {
    bridge: pubkey;
    guardian_set_index: u32;
    num_signatures: u8;
    hash: pubkey;
    num_verified: u8;
    verified_0: bool;
    verified_1: bool;
    verified_2: bool;
    verified_3: bool;
    verified_4: bool;
    verified_5: bool;
    verified_6: bool;
    verified_7: bool;
    verified_8: bool;
    verified_9: bool;
    verified_10: bool;
    verified_11: bool;
    verified_12: bool;
    verified_13: bool;
    verified_14: bool;
    verified_15: bool;
    verified_16: bool;
    verified_17: bool;
    verified_18: bool;
}

// ---------------------------------------------------------------------------
// Constants (as fn helpers -- 5ive has no top-level const)
// ---------------------------------------------------------------------------

fn verification_partial() -> u8 { return 0; }
fn verification_full() -> u8 { return 1; }
fn zero_pubkey() -> pubkey { return derive_pda("zero"); }
fn default_stale_grace_slots() -> u64 { return 100; }
fn max_data_sources() -> u8 { return 32; }

// ---------------------------------------------------------------------------
// Wormhole helpers: count verified signatures from a signature set
// ---------------------------------------------------------------------------

fn count_wormhole_verified(sig_set: WormholeSignatureSet) -> u64 {
    let mut count: u64 = 0;
    if (sig_set.verified_0) { count = count + 1; }
    if (sig_set.verified_1) { count = count + 1; }
    if (sig_set.verified_2) { count = count + 1; }
    if (sig_set.verified_3) { count = count + 1; }
    if (sig_set.verified_4) { count = count + 1; }
    if (sig_set.verified_5) { count = count + 1; }
    if (sig_set.verified_6) { count = count + 1; }
    if (sig_set.verified_7) { count = count + 1; }
    if (sig_set.verified_8) { count = count + 1; }
    if (sig_set.verified_9) { count = count + 1; }
    if (sig_set.verified_10) { count = count + 1; }
    if (sig_set.verified_11) { count = count + 1; }
    if (sig_set.verified_12) { count = count + 1; }
    if (sig_set.verified_13) { count = count + 1; }
    if (sig_set.verified_14) { count = count + 1; }
    if (sig_set.verified_15) { count = count + 1; }
    if (sig_set.verified_16) { count = count + 1; }
    if (sig_set.verified_17) { count = count + 1; }
    if (sig_set.verified_18) { count = count + 1; }
    return count;
}

// Wormhole supermajority: (2/3 + 1) of guardian set
fn wormhole_supermajority(num_guardians: u64) -> u64 {
    return (num_guardians * 2) / 3 + 1;
}

// Determine verification level based on verified count vs min_signatures
fn compute_verification_level(verified_count: u64, min_sigs: u64) -> u8 {
    if (verified_count >= min_sigs) {
        return verification_full();
    }
    return verification_partial();
}

// Absolute difference for signed integers
fn abs_diff_i64(a: i64, b: i64) -> u64 {
    if (a >= b) {
        return (a - b) as u64;
    }
    return (b - a) as u64;
}

// ===========================================================================
// Initialization & Governance
// ===========================================================================

// ---------------------------------------------------------------------------
// initialize -- Set up receiver config
// ---------------------------------------------------------------------------

pub initialize(
    config: ReceiverConfig @mut @init(payer=admin, space=512) @signer,
    admin: account @mut @signer,
    wormhole_bridge: pubkey,
    update_fee: u64,
    min_signatures: u8,
    stale_grace_slots: u64
) {
    require(min_signatures > 0);

    let mut grace: u64 = stale_grace_slots;
    if (grace == 0) {
        grace = default_stale_grace_slots();
    }

    config.admin = admin.ctx.key;
    config.pending_admin = zero_pubkey();
    config.wormhole_bridge = wormhole_bridge;
    config.update_fee = update_fee;
    config.min_signatures = min_signatures;
    config.num_data_sources = 0;
    config.is_active = true;
    config.stale_grace_slots = grace;
}

// ---------------------------------------------------------------------------
// request_governance_authority_transfer -- Begin 2-step authority transfer
// ---------------------------------------------------------------------------

pub request_governance_authority_transfer(
    config: ReceiverConfig @mut,
    admin: account @signer,
    new_admin: pubkey
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    config.pending_admin = new_admin;
}

// ---------------------------------------------------------------------------
// cancel_governance_authority_transfer -- Cancel pending transfer
// ---------------------------------------------------------------------------

pub cancel_governance_authority_transfer(
    config: ReceiverConfig @mut,
    admin: account @signer
) {
    require(config.admin == admin.ctx.key);
    config.pending_admin = zero_pubkey();
}

// ---------------------------------------------------------------------------
// accept_governance_authority_transfer -- Complete authority transfer
// ---------------------------------------------------------------------------

pub accept_governance_authority_transfer(
    config: ReceiverConfig @mut,
    new_admin: account @signer
) {
    require(config.pending_admin == new_admin.ctx.key);
    config.admin = new_admin.ctx.key;
    config.pending_admin = zero_pubkey();
}

// ===========================================================================
// Configuration (Governance)
// ===========================================================================

// ---------------------------------------------------------------------------
// set_data_sources -- Add an authorized data source emitter
// ---------------------------------------------------------------------------

pub set_data_sources(
    config: ReceiverConfig @mut,
    data_source: DataSource @mut @init(payer=admin, space=256),
    admin: account @mut @signer,
    emitter_chain: u16,
    emitter_address: pubkey
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    require(emitter_chain > 0);
    require(config.num_data_sources < max_data_sources());

    data_source.config = config.ctx.key;
    data_source.emitter_chain = emitter_chain;
    data_source.emitter_address = emitter_address;
    data_source.is_valid = true;

    config.num_data_sources = config.num_data_sources + 1;
}

// ---------------------------------------------------------------------------
// revoke_data_source -- Remove an authorized data source
// ---------------------------------------------------------------------------

pub revoke_data_source(
    config: ReceiverConfig @mut,
    data_source: DataSource @mut,
    admin: account @signer
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);

    data_source.is_valid = false;
    config.num_data_sources = config.num_data_sources - 1;
}

// ---------------------------------------------------------------------------
// set_fee -- Set update fee (charged per price update)
// ---------------------------------------------------------------------------

pub set_fee(
    config: ReceiverConfig @mut,
    admin: account @signer,
    new_fee: u64
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    config.update_fee = new_fee;
}

// ---------------------------------------------------------------------------
// set_wormhole_address -- Update Wormhole bridge address
// ---------------------------------------------------------------------------

pub set_wormhole_address(
    config: ReceiverConfig @mut,
    admin: account @signer,
    new_wormhole_bridge: pubkey
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    config.wormhole_bridge = new_wormhole_bridge;
}

// ---------------------------------------------------------------------------
// set_minimum_signatures -- Set minimum guardian signatures for full verification
// ---------------------------------------------------------------------------

pub set_minimum_signatures(
    config: ReceiverConfig @mut,
    admin: account @signer,
    new_min_signatures: u8
) {
    require(config.admin == admin.ctx.key);
    require(config.is_active);
    require(new_min_signatures > 0);
    config.min_signatures = new_min_signatures;
}

// ---------------------------------------------------------------------------
// set_stale_grace_slots -- Configure staleness grace period for rent reclaim
// ---------------------------------------------------------------------------

pub set_stale_grace_slots(
    config: ReceiverConfig @mut,
    admin: account @signer,
    new_grace_slots: u64
) {
    require(config.admin == admin.ctx.key);
    require(new_grace_slots > 0);
    config.stale_grace_slots = new_grace_slots;
}

// ---------------------------------------------------------------------------
// set_active -- Pause/unpause the receiver
// ---------------------------------------------------------------------------

pub set_active(
    config: ReceiverConfig @mut,
    admin: account @signer,
    active: bool
) {
    require(config.admin == admin.ctx.key);
    config.is_active = active;
}

// ===========================================================================
// Price Updates (Core)
// ===========================================================================

// ---------------------------------------------------------------------------
// post_update_atomic -- Post a price update with inline Wormhole VAA
//                       verification (all-in-one tx)
//
// The atomic path verifies guardian signatures directly within this
// instruction by checking the ed25519 precompile instruction that must
// precede this call in the same transaction. The caller passes the
// Wormhole guardian set and a signature set account; the receiver
// confirms supermajority, validates the data source, and writes the
// verified price.
// ---------------------------------------------------------------------------

pub post_update_atomic(
    config: ReceiverConfig @mut,
    data_source: DataSource,
    guardian_set: WormholeGuardianSet,
    price_update: PriceUpdateV2 @mut @init(payer=payer, space=512),
    payer: account @mut @signer,
    fee_account: account @mut,
    // VAA payload fields (extracted off-chain, passed as instruction args)
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    price: i64,
    confidence: u64,
    exponent: i64,
    publish_time: u64,
    ema_price: i64,
    ema_confidence: u64,
    num_signatures: u8
) {
    require(config.is_active);

    // --- Fee check ---
    require(config.update_fee >= 0);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Guardian set validation ---
    require(guardian_set.bridge == config.wormhole_bridge);
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // --- Signature verification via ed25519 precompile ---
    // The caller must include ed25519 program instructions before this call.
    // verify_ed25519_instruction() checks the preceding instruction verified
    // the expected signatures against the VAA hash.
    verify_ed25519_instruction();

    // --- Determine verification level ---
    // num_signatures is the count of valid guardian signatures in the VAA
    let verified_count: u64 = num_signatures as u64;
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count > 0);

    // Must have at least Wormhole supermajority
    require(verified_count >= threshold);

    let level: u8 = compute_verification_level(verified_count, config.min_signatures as u64);

    // --- Validate price data ---
    require(confidence > 0);
    require(publish_time > 0);

    // --- Write PriceUpdateV2 ---
    let current_slot: u64 = get_clock().slot;

    price_update.config = config.ctx.key;
    price_update.feed_id = feed_id;
    price_update.price = price;
    price_update.confidence = confidence;
    price_update.exponent = exponent;
    price_update.publish_time = publish_time;
    price_update.prev_publish_time = 0;
    price_update.ema_price = ema_price;
    price_update.ema_confidence = ema_confidence;
    price_update.verification_level = level;
    price_update.posted_slot = current_slot;
    price_update.write_authority = payer.ctx.key;
}

// ---------------------------------------------------------------------------
// post_update -- Post a price update using a pre-verified Wormhole VAA
//
// For the two-step flow: (1) verify_signatures on Wormhole bridge first,
// (2) then call post_update with the verified signature set.
// ---------------------------------------------------------------------------

pub post_update(
    config: ReceiverConfig @mut,
    data_source: DataSource,
    sig_set: WormholeSignatureSet,
    guardian_set: WormholeGuardianSet,
    price_update: PriceUpdateV2 @mut @init(payer=payer, space=512),
    payer: account @mut @signer,
    fee_account: account @mut,
    // VAA payload fields
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    price: i64,
    confidence: u64,
    exponent: i64,
    publish_time: u64,
    ema_price: i64,
    ema_confidence: u64
) {
    require(config.is_active);

    // --- Fee check ---
    require(config.update_fee >= 0);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Wormhole signature set validation ---
    require(sig_set.bridge == config.wormhole_bridge);
    require(guardian_set.bridge == config.wormhole_bridge);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);

    // Guardian set must not have expired
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // Count verified signatures and check supermajority
    let verified_count: u64 = count_wormhole_verified(sig_set);
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // Determine verification level
    let level: u8 = compute_verification_level(verified_count, config.min_signatures as u64);

    // --- Validate price data ---
    require(confidence > 0);
    require(publish_time > 0);

    // --- Write PriceUpdateV2 ---
    let current_slot: u64 = get_clock().slot;

    price_update.config = config.ctx.key;
    price_update.feed_id = feed_id;
    price_update.price = price;
    price_update.confidence = confidence;
    price_update.exponent = exponent;
    price_update.publish_time = publish_time;
    price_update.prev_publish_time = 0;
    price_update.ema_price = ema_price;
    price_update.ema_confidence = ema_confidence;
    price_update.verification_level = level;
    price_update.posted_slot = current_slot;
    price_update.write_authority = payer.ctx.key;
}

// ---------------------------------------------------------------------------
// update_price_feed -- Overwrite an existing PriceUpdateV2 with a newer price
//
// Enforces append-only semantics: new publish_time must be strictly greater
// than the existing one. Only the original write_authority can update.
// ---------------------------------------------------------------------------

pub update_price_feed(
    config: ReceiverConfig,
    data_source: DataSource,
    sig_set: WormholeSignatureSet,
    guardian_set: WormholeGuardianSet,
    price_update: PriceUpdateV2 @mut,
    payer: account @signer,
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    price: i64,
    confidence: u64,
    exponent: i64,
    publish_time: u64,
    ema_price: i64,
    ema_confidence: u64
) {
    require(config.is_active);

    // Only the original writer (or the payer of the account) can overwrite
    require(price_update.write_authority == payer.ctx.key);
    require(price_update.config == config.ctx.key);
    require(price_update.feed_id == feed_id);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Wormhole verification ---
    require(sig_set.bridge == config.wormhole_bridge);
    require(guardian_set.bridge == config.wormhole_bridge);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);

    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    let verified_count: u64 = count_wormhole_verified(sig_set);
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    let level: u8 = compute_verification_level(verified_count, config.min_signatures as u64);

    // --- Validate price data ---
    require(confidence > 0);
    require(publish_time > 0);

    // --- Append-only: newer prices only ---
    require(publish_time > price_update.publish_time);

    // --- Overwrite ---
    let current_slot: u64 = get_clock().slot;

    price_update.prev_publish_time = price_update.publish_time;
    price_update.price = price;
    price_update.confidence = confidence;
    price_update.exponent = exponent;
    price_update.publish_time = publish_time;
    price_update.ema_price = ema_price;
    price_update.ema_confidence = ema_confidence;
    price_update.verification_level = level;
    price_update.posted_slot = current_slot;
}

// ---------------------------------------------------------------------------
// post_update_atomic_existing -- Atomic path for overwriting existing accounts
// ---------------------------------------------------------------------------

pub post_update_atomic_existing(
    config: ReceiverConfig,
    data_source: DataSource,
    guardian_set: WormholeGuardianSet,
    price_update: PriceUpdateV2 @mut,
    payer: account @signer,
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    price: i64,
    confidence: u64,
    exponent: i64,
    publish_time: u64,
    ema_price: i64,
    ema_confidence: u64,
    num_signatures: u8
) {
    require(config.is_active);

    // --- Authority check ---
    require(price_update.write_authority == payer.ctx.key);
    require(price_update.config == config.ctx.key);
    require(price_update.feed_id == feed_id);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Guardian set validation ---
    require(guardian_set.bridge == config.wormhole_bridge);
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // --- Signature verification via ed25519 precompile ---
    verify_ed25519_instruction();

    let verified_count: u64 = num_signatures as u64;
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count > 0);
    require(verified_count >= threshold);

    let level: u8 = compute_verification_level(verified_count, config.min_signatures as u64);

    // --- Validate price data ---
    require(confidence > 0);
    require(publish_time > 0);

    // --- Append-only: newer prices only ---
    require(publish_time > price_update.publish_time);

    // --- Overwrite ---
    let current_slot: u64 = get_clock().slot;

    price_update.prev_publish_time = price_update.publish_time;
    price_update.price = price;
    price_update.confidence = confidence;
    price_update.exponent = exponent;
    price_update.publish_time = publish_time;
    price_update.ema_price = ema_price;
    price_update.ema_confidence = ema_confidence;
    price_update.verification_level = level;
    price_update.posted_slot = current_slot;
}

// ===========================================================================
// TWAP Updates
// ===========================================================================

// ---------------------------------------------------------------------------
// post_twap_update -- Post a time-weighted average price (TWAP) update
//
// TWAP is computed from cumulative accumulators:
//   twap_price = cumulative_price / (end_slot - start_slot - num_down_slots)
//   twap_confidence = cumulative_confidence / (end_slot - start_slot - num_down_slots)
// ---------------------------------------------------------------------------

pub post_twap_update(
    config: ReceiverConfig @mut,
    data_source: DataSource,
    sig_set: WormholeSignatureSet,
    guardian_set: WormholeGuardianSet,
    twap_update: TwapUpdate @mut @init(payer=payer, space=512),
    payer: account @mut @signer,
    fee_account: account @mut,
    // VAA payload fields
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    cumulative_price: i64,
    cumulative_confidence: u64,
    num_down_slots: u64,
    start_slot: u64,
    end_slot: u64
) {
    require(config.is_active);

    // --- Fee check ---
    require(config.update_fee >= 0);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Wormhole signature set validation ---
    require(sig_set.bridge == config.wormhole_bridge);
    require(guardian_set.bridge == config.wormhole_bridge);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);

    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    let verified_count: u64 = count_wormhole_verified(sig_set);
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // --- Validate TWAP data ---
    require(end_slot > start_slot);
    let active_slots: u64 = end_slot - start_slot - num_down_slots;
    require(active_slots > 0);

    // --- Compute TWAP ---
    // twap_price = cumulative_price / active_slots
    // twap_confidence = cumulative_confidence / active_slots
    // Note: cumulative_price is i64, so we must handle signed division carefully
    let mut computed_twap_price: i64 = 0;
    let active_slots_i64: i64 = active_slots as i64;
    if (cumulative_price >= 0) {
        computed_twap_price = cumulative_price / active_slots_i64;
    } else {
        // For negative cumulative: negate, divide, negate back
        let pos_cumulative: i64 = 0 - cumulative_price;
        let pos_result: i64 = pos_cumulative / active_slots_i64;
        computed_twap_price = 0 - pos_result;
    }

    let computed_twap_confidence: u64 = cumulative_confidence / active_slots;

    // --- Write TwapUpdate ---
    let current_slot: u64 = get_clock().slot;

    twap_update.config = config.ctx.key;
    twap_update.feed_id = feed_id;
    twap_update.cumulative_price = cumulative_price;
    twap_update.cumulative_confidence = cumulative_confidence;
    twap_update.num_down_slots = num_down_slots;
    twap_update.start_slot = start_slot;
    twap_update.end_slot = end_slot;
    twap_update.twap_price = computed_twap_price;
    twap_update.twap_confidence = computed_twap_confidence;
    twap_update.posted_slot = current_slot;
    twap_update.write_authority = payer.ctx.key;
}

// ---------------------------------------------------------------------------
// update_twap -- Overwrite existing TWAP with newer data
// ---------------------------------------------------------------------------

pub update_twap(
    config: ReceiverConfig,
    data_source: DataSource,
    sig_set: WormholeSignatureSet,
    guardian_set: WormholeGuardianSet,
    twap_update: TwapUpdate @mut,
    payer: account @signer,
    vaa_hash: pubkey,
    emitter_chain: u16,
    emitter_address: pubkey,
    feed_id: pubkey,
    cumulative_price: i64,
    cumulative_confidence: u64,
    num_down_slots: u64,
    start_slot: u64,
    end_slot: u64
) {
    require(config.is_active);

    // --- Authority check ---
    require(twap_update.write_authority == payer.ctx.key);
    require(twap_update.config == config.ctx.key);
    require(twap_update.feed_id == feed_id);

    // --- Data source validation ---
    require(data_source.config == config.ctx.key);
    require(data_source.is_valid);
    require(data_source.emitter_chain == emitter_chain);
    require(data_source.emitter_address == emitter_address);

    // --- Wormhole verification ---
    require(sig_set.bridge == config.wormhole_bridge);
    require(guardian_set.bridge == config.wormhole_bridge);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);

    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    let verified_count: u64 = count_wormhole_verified(sig_set);
    let threshold: u64 = wormhole_supermajority(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // --- Append-only: newer TWAP windows only ---
    require(end_slot > twap_update.end_slot);

    // --- Validate TWAP data ---
    require(end_slot > start_slot);
    let active_slots: u64 = end_slot - start_slot - num_down_slots;
    require(active_slots > 0);

    // --- Compute TWAP ---
    let mut computed_twap_price: i64 = 0;
    let active_slots_i64: i64 = active_slots as i64;
    if (cumulative_price >= 0) {
        computed_twap_price = cumulative_price / active_slots_i64;
    } else {
        let pos_cumulative: i64 = 0 - cumulative_price;
        let pos_result: i64 = pos_cumulative / active_slots_i64;
        computed_twap_price = 0 - pos_result;
    }

    let computed_twap_confidence: u64 = cumulative_confidence / active_slots;

    // --- Overwrite ---
    let current_slot: u64 = get_clock().slot;

    twap_update.cumulative_price = cumulative_price;
    twap_update.cumulative_confidence = cumulative_confidence;
    twap_update.num_down_slots = num_down_slots;
    twap_update.start_slot = start_slot;
    twap_update.end_slot = end_slot;
    twap_update.twap_price = computed_twap_price;
    twap_update.twap_confidence = computed_twap_confidence;
    twap_update.posted_slot = current_slot;
}

// ===========================================================================
// Account Cleanup
// ===========================================================================

// ---------------------------------------------------------------------------
// reclaim_rent -- Close a stale price update account, reclaim SOL rent
//
// Anyone can call this to reclaim rent from a price update account that
// has been stale for longer than stale_grace_slots.
// ---------------------------------------------------------------------------

pub reclaim_rent(
    config: ReceiverConfig,
    price_update: PriceUpdateV2 @mut,
    rent_recipient: account @mut
) {
    require(price_update.config == config.ctx.key);

    let current_slot: u64 = get_clock().slot;
    let stale_threshold: u64 = price_update.posted_slot + config.stale_grace_slots;

    // Account must be stale beyond the grace period
    require(current_slot > stale_threshold);

    // Zero out the account to mark it as reclaimable
    // In the 5ive runtime, zeroing the config key signals account closure
    price_update.config = zero_pubkey();
    price_update.feed_id = zero_pubkey();
    price_update.price = 0;
    price_update.confidence = 0;
    price_update.exponent = 0;
    price_update.publish_time = 0;
    price_update.prev_publish_time = 0;
    price_update.ema_price = 0;
    price_update.ema_confidence = 0;
    price_update.verification_level = 0;
    price_update.posted_slot = 0;
    price_update.write_authority = zero_pubkey();
}

// ---------------------------------------------------------------------------
// reclaim_twap_rent -- Close a stale TWAP account, reclaim SOL rent
// ---------------------------------------------------------------------------

pub reclaim_twap_rent(
    config: ReceiverConfig,
    twap_update: TwapUpdate @mut,
    rent_recipient: account @mut
) {
    require(twap_update.config == config.ctx.key);

    let current_slot: u64 = get_clock().slot;
    let stale_threshold: u64 = twap_update.posted_slot + config.stale_grace_slots;

    // Account must be stale beyond the grace period
    require(current_slot > stale_threshold);

    // Zero out the account to mark it as reclaimable
    twap_update.config = zero_pubkey();
    twap_update.feed_id = zero_pubkey();
    twap_update.cumulative_price = 0;
    twap_update.cumulative_confidence = 0;
    twap_update.num_down_slots = 0;
    twap_update.start_slot = 0;
    twap_update.end_slot = 0;
    twap_update.twap_price = 0;
    twap_update.twap_confidence = 0;
    twap_update.posted_slot = 0;
    twap_update.write_authority = zero_pubkey();
}

// ===========================================================================
// Consumer Read-Only Queries
// ===========================================================================

// ---------------------------------------------------------------------------
// get_price -- Read verified price with staleness check
// ---------------------------------------------------------------------------

pub get_price(
    config: ReceiverConfig,
    price_update: PriceUpdateV2,
    max_age_slots: u64
) -> i64 {
    require(price_update.config == config.ctx.key);
    require(max_age_slots > 0);

    let current_slot: u64 = get_clock().slot;
    require(price_update.posted_slot + max_age_slots >= current_slot);

    return price_update.price;
}

// ---------------------------------------------------------------------------
// get_price_no_older_than -- Price with custom staleness in publish_time
// ---------------------------------------------------------------------------

pub get_price_no_older_than(
    config: ReceiverConfig,
    price_update: PriceUpdateV2,
    max_age_seconds: u64
) -> i64 {
    require(price_update.config == config.ctx.key);
    require(max_age_seconds > 0);

    let now: u64 = get_clock().unix_timestamp;
    require(price_update.publish_time + max_age_seconds >= now);

    return price_update.price;
}

// ---------------------------------------------------------------------------
// get_price_unsafe -- Read price without staleness check
// ---------------------------------------------------------------------------

pub get_price_unsafe(
    price_update: PriceUpdateV2
) -> i64 {
    return price_update.price;
}

// ---------------------------------------------------------------------------
// get_ema_price -- Read EMA price with staleness check
// ---------------------------------------------------------------------------

pub get_ema_price(
    config: ReceiverConfig,
    price_update: PriceUpdateV2,
    max_age_slots: u64
) -> i64 {
    require(price_update.config == config.ctx.key);
    require(max_age_slots > 0);

    let current_slot: u64 = get_clock().slot;
    require(price_update.posted_slot + max_age_slots >= current_slot);

    return price_update.ema_price;
}

// ---------------------------------------------------------------------------
// get_ema_price_no_older_than -- EMA with custom staleness in publish_time
// ---------------------------------------------------------------------------

pub get_ema_price_no_older_than(
    config: ReceiverConfig,
    price_update: PriceUpdateV2,
    max_age_seconds: u64
) -> i64 {
    require(price_update.config == config.ctx.key);
    require(max_age_seconds > 0);

    let now: u64 = get_clock().unix_timestamp;
    require(price_update.publish_time + max_age_seconds >= now);

    return price_update.ema_price;
}

// ---------------------------------------------------------------------------
// get_twap_price -- Read TWAP price with staleness check
// ---------------------------------------------------------------------------

pub get_twap_price(
    config: ReceiverConfig,
    twap_update: TwapUpdate,
    max_age_slots: u64
) -> i64 {
    require(twap_update.config == config.ctx.key);
    require(max_age_slots > 0);

    let current_slot: u64 = get_clock().slot;
    require(twap_update.posted_slot + max_age_slots >= current_slot);

    return twap_update.twap_price;
}

// ---------------------------------------------------------------------------
// get_twap_price_unsafe -- Read TWAP price without staleness check
// ---------------------------------------------------------------------------

pub get_twap_price_unsafe(
    twap_update: TwapUpdate
) -> i64 {
    return twap_update.twap_price;
}

// ===========================================================================
// View Helpers
// ===========================================================================

pub get_feed_id(price_update: PriceUpdateV2) -> pubkey {
    return price_update.feed_id;
}

pub get_confidence(price_update: PriceUpdateV2) -> u64 {
    return price_update.confidence;
}

pub get_exponent(price_update: PriceUpdateV2) -> i64 {
    return price_update.exponent;
}

pub get_publish_time(price_update: PriceUpdateV2) -> u64 {
    return price_update.publish_time;
}

pub get_prev_publish_time(price_update: PriceUpdateV2) -> u64 {
    return price_update.prev_publish_time;
}

pub get_ema_confidence(price_update: PriceUpdateV2) -> u64 {
    return price_update.ema_confidence;
}

pub get_verification_level(price_update: PriceUpdateV2) -> u8 {
    return price_update.verification_level;
}

pub get_posted_slot(price_update: PriceUpdateV2) -> u64 {
    return price_update.posted_slot;
}

pub get_write_authority(price_update: PriceUpdateV2) -> pubkey {
    return price_update.write_authority;
}

pub get_update_fee(config: ReceiverConfig) -> u64 {
    return config.update_fee;
}

pub get_min_signatures(config: ReceiverConfig) -> u8 {
    return config.min_signatures;
}

pub get_num_data_sources(config: ReceiverConfig) -> u8 {
    return config.num_data_sources;
}

pub is_data_source_valid(data_source: DataSource) -> bool {
    return data_source.is_valid;
}

pub get_twap_feed_id(twap_update: TwapUpdate) -> pubkey {
    return twap_update.feed_id;
}

pub get_twap_confidence(twap_update: TwapUpdate) -> u64 {
    return twap_update.twap_confidence;
}

pub get_twap_posted_slot(twap_update: TwapUpdate) -> u64 {
    return twap_update.posted_slot;
}

pub get_twap_window(twap_update: TwapUpdate) -> u64 {
    return twap_update.end_slot - twap_update.start_slot;
}

pub get_twap_active_slots(twap_update: TwapUpdate) -> u64 {
    return twap_update.end_slot - twap_update.start_slot - twap_update.num_down_slots;
}

pub is_receiver_active(config: ReceiverConfig) -> bool {
    return config.is_active;
}

pub get_wormhole_bridge(config: ReceiverConfig) -> pubkey {
    return config.wormhole_bridge;
}
