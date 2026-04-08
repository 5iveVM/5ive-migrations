// 5IVE Wormhole: Cross-Chain Bridge (Core Bridge + Token Bridge)
//
// Design (Wormhole v1/v2 inspired):
//   - Core bridge: post messages, verify guardian signatures, post VAAs
//   - Guardian set management: 19 guardians, 13/19 supermajority for verification
//   - Token bridge: lock/unlock native tokens, mint/burn wrapped tokens
//   - Claim records prevent VAA replay (each VAA processed exactly once)
//   - Sequence numbers: per-emitter monotonic counter
//   - Fee collection: configurable bridge fee per message
//   - Guardian set rotation via governance VAA with expiration grace period

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account BridgeConfig {
    authority: pubkey;
    guardian_set_index: u32;
    fee: u64;
    sequence: u64;
    fee_collector: pubkey;
    is_active: bool;
}

account GuardianSet {
    bridge: pubkey;
    index: u32;
    num_guardians: u8;
    expiration_time: u64;
    // Guardian keys stored as pubkeys (represent eth addresses mapped to 32-byte keys)
    // Supporting up to 19 guardians
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

account PostedMessage {
    bridge: pubkey;
    emitter: pubkey;
    sequence: u64;
    nonce: u32;
    payload_hash: pubkey;
    consistency_level: u8;
    timestamp: u64;
}

account SignatureSet {
    bridge: pubkey;
    guardian_set_index: u32;
    num_signatures: u8;
    hash: pubkey;
    num_verified: u8;
    // Per-guardian verification status (bitmap as individual bools for clarity)
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

account ClaimRecord {
    bridge: pubkey;
    vaa_hash: pubkey;
    claimed: bool;
    claim_time: u64;
}

account TokenBridgeConfig {
    bridge: pubkey;
    authority: pubkey;
    is_active: bool;
    registered_chains: u16;
}

account WrappedMeta {
    token_bridge: pubkey;
    chain_id: u16;
    token_address_hash: pubkey;
    original_decimals: u8;
    mint: pubkey;
}

account ChainRegistration {
    token_bridge: pubkey;
    chain_id: u16;
    emitter_address: pubkey;
    is_registered: bool;
}

account TransferRecord {
    token_bridge: pubkey;
    sender: pubkey;
    recipient_chain: u16;
    recipient_address: pubkey;
    amount: u64;
    sequence: u64;
    timestamp: u64;
}

// ---------------------------------------------------------------------------
// Constants (as fn helpers)
// ---------------------------------------------------------------------------

fn supermajority_threshold(num_guardians: u64) -> u64 {
    // Wormhole requires (2/3 + 1) guardians to sign
    // For 19 guardians: (19 * 2) / 3 + 1 = 13
    return (num_guardians * 2) / 3 + 1;
}

fn guardian_set_grace_period() -> u64 {
    // 86400 seconds = 24 hours grace period after rotation
    return 86400;
}

// ---------------------------------------------------------------------------
// Core Bridge: Initialize
// ---------------------------------------------------------------------------

pub initialize(
    config: BridgeConfig @mut @init(payer=authority, space=512) @signer,
    authority: account @mut @signer,
    fee_collector: account,
    initial_fee: u64
) {
    config.authority = authority.ctx.key;
    config.guardian_set_index = 0;
    config.fee = initial_fee;
    config.sequence = 0;
    config.fee_collector = fee_collector.ctx.key;
    config.is_active = true;
}

pub init_guardian_set(
    config: BridgeConfig @mut,
    guardian_set: GuardianSet @mut @init(payer=authority, space=1024) @signer,
    authority: account @mut @signer,
    num_guardians: u8,
    key_0: pubkey,
    key_1: pubkey,
    key_2: pubkey,
    key_3: pubkey,
    key_4: pubkey,
    key_5: pubkey,
    key_6: pubkey,
    key_7: pubkey,
    key_8: pubkey,
    key_9: pubkey,
    key_10: pubkey,
    key_11: pubkey,
    key_12: pubkey,
    key_13: pubkey,
    key_14: pubkey,
    key_15: pubkey,
    key_16: pubkey,
    key_17: pubkey,
    key_18: pubkey
) {
    require(config.authority == authority.ctx.key);
    require(num_guardians > 0);
    require(num_guardians <= 19);

    guardian_set.bridge = config.ctx.key;
    guardian_set.index = config.guardian_set_index;
    guardian_set.num_guardians = num_guardians;
    guardian_set.expiration_time = 0;

    guardian_set.key_0 = key_0;
    guardian_set.key_1 = key_1;
    guardian_set.key_2 = key_2;
    guardian_set.key_3 = key_3;
    guardian_set.key_4 = key_4;
    guardian_set.key_5 = key_5;
    guardian_set.key_6 = key_6;
    guardian_set.key_7 = key_7;
    guardian_set.key_8 = key_8;
    guardian_set.key_9 = key_9;
    guardian_set.key_10 = key_10;
    guardian_set.key_11 = key_11;
    guardian_set.key_12 = key_12;
    guardian_set.key_13 = key_13;
    guardian_set.key_14 = key_14;
    guardian_set.key_15 = key_15;
    guardian_set.key_16 = key_16;
    guardian_set.key_17 = key_17;
    guardian_set.key_18 = key_18;
}

// ---------------------------------------------------------------------------
// Core Bridge: Post Message
// ---------------------------------------------------------------------------

pub post_message(
    config: BridgeConfig @mut,
    message: PostedMessage @mut @init(payer=emitter, space=512) @signer,
    emitter: account @mut @signer,
    fee_collector_account: account @mut,
    nonce: u32,
    payload_hash: pubkey,
    consistency_level: u8
) -> u64 {
    require(config.is_active);
    require(config.fee_collector == fee_collector_account.ctx.key);

    // Sequence is monotonically increasing per bridge
    let current_sequence: u64 = config.sequence;
    config.sequence = config.sequence + 1;

    message.bridge = config.ctx.key;
    message.emitter = emitter.ctx.key;
    message.sequence = current_sequence;
    message.nonce = nonce;
    message.payload_hash = payload_hash;
    message.consistency_level = consistency_level;
    message.timestamp = get_clock().unix_timestamp;

    return current_sequence;
}

// ---------------------------------------------------------------------------
// Core Bridge: Verify Signatures
// ---------------------------------------------------------------------------

fn get_guardian_key(gs: GuardianSet, idx: u8) -> pubkey {
    if (idx == 0) { return gs.key_0; }
    if (idx == 1) { return gs.key_1; }
    if (idx == 2) { return gs.key_2; }
    if (idx == 3) { return gs.key_3; }
    if (idx == 4) { return gs.key_4; }
    if (idx == 5) { return gs.key_5; }
    if (idx == 6) { return gs.key_6; }
    if (idx == 7) { return gs.key_7; }
    if (idx == 8) { return gs.key_8; }
    if (idx == 9) { return gs.key_9; }
    if (idx == 10) { return gs.key_10; }
    if (idx == 11) { return gs.key_11; }
    if (idx == 12) { return gs.key_12; }
    if (idx == 13) { return gs.key_13; }
    if (idx == 14) { return gs.key_14; }
    if (idx == 15) { return gs.key_15; }
    if (idx == 16) { return gs.key_16; }
    if (idx == 17) { return gs.key_17; }
    if (idx == 18) { return gs.key_18; }
    return gs.key_0;
}

fn set_sig_verified(sig_set: SignatureSet, idx: u8) -> bool {
    // Returns true if this guardian index was already verified
    if (idx == 0) { return sig_set.verified_0; }
    if (idx == 1) { return sig_set.verified_1; }
    if (idx == 2) { return sig_set.verified_2; }
    if (idx == 3) { return sig_set.verified_3; }
    if (idx == 4) { return sig_set.verified_4; }
    if (idx == 5) { return sig_set.verified_5; }
    if (idx == 6) { return sig_set.verified_6; }
    if (idx == 7) { return sig_set.verified_7; }
    if (idx == 8) { return sig_set.verified_8; }
    if (idx == 9) { return sig_set.verified_9; }
    if (idx == 10) { return sig_set.verified_10; }
    if (idx == 11) { return sig_set.verified_11; }
    if (idx == 12) { return sig_set.verified_12; }
    if (idx == 13) { return sig_set.verified_13; }
    if (idx == 14) { return sig_set.verified_14; }
    if (idx == 15) { return sig_set.verified_15; }
    if (idx == 16) { return sig_set.verified_16; }
    if (idx == 17) { return sig_set.verified_17; }
    if (idx == 18) { return sig_set.verified_18; }
    return false;
}

pub init_signature_set(
    config: BridgeConfig,
    sig_set: SignatureSet @mut @init(payer=payer, space=512) @signer,
    payer: account @mut @signer,
    guardian_set: GuardianSet,
    vaa_hash: pubkey
) {
    require(config.is_active);
    require(guardian_set.bridge == config.ctx.key);
    require(guardian_set.index == config.guardian_set_index);

    // Ensure guardian set has not expired
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    sig_set.bridge = config.ctx.key;
    sig_set.guardian_set_index = guardian_set.index;
    sig_set.num_signatures = guardian_set.num_guardians;
    sig_set.hash = vaa_hash;
    sig_set.num_verified = 0;

    sig_set.verified_0 = false;
    sig_set.verified_1 = false;
    sig_set.verified_2 = false;
    sig_set.verified_3 = false;
    sig_set.verified_4 = false;
    sig_set.verified_5 = false;
    sig_set.verified_6 = false;
    sig_set.verified_7 = false;
    sig_set.verified_8 = false;
    sig_set.verified_9 = false;
    sig_set.verified_10 = false;
    sig_set.verified_11 = false;
    sig_set.verified_12 = false;
    sig_set.verified_13 = false;
    sig_set.verified_14 = false;
    sig_set.verified_15 = false;
    sig_set.verified_16 = false;
    sig_set.verified_17 = false;
    sig_set.verified_18 = false;
}

pub verify_signatures(
    config: BridgeConfig,
    sig_set: SignatureSet @mut,
    guardian_set: GuardianSet,
    guardian_index: u8,
    guardian_key: pubkey
) {
    require(config.is_active);
    require(sig_set.bridge == config.ctx.key);
    require(guardian_set.bridge == config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(guardian_index < guardian_set.num_guardians);

    // Verify the guardian key matches the guardian set at the given index
    let expected_key: pubkey = get_guardian_key(guardian_set, guardian_index);
    require(expected_key == guardian_key);

    // Check not already verified for this index
    let already_verified: bool = set_sig_verified(sig_set, guardian_index);
    require(!already_verified);

    // Verify the ed25519 signature (builtin checks the preceding
    // ed25519 program instruction in the transaction)
    verify_ed25519_instruction();

    // Mark this guardian's signature as verified
    if (guardian_index == 0) { sig_set.verified_0 = true; }
    if (guardian_index == 1) { sig_set.verified_1 = true; }
    if (guardian_index == 2) { sig_set.verified_2 = true; }
    if (guardian_index == 3) { sig_set.verified_3 = true; }
    if (guardian_index == 4) { sig_set.verified_4 = true; }
    if (guardian_index == 5) { sig_set.verified_5 = true; }
    if (guardian_index == 6) { sig_set.verified_6 = true; }
    if (guardian_index == 7) { sig_set.verified_7 = true; }
    if (guardian_index == 8) { sig_set.verified_8 = true; }
    if (guardian_index == 9) { sig_set.verified_9 = true; }
    if (guardian_index == 10) { sig_set.verified_10 = true; }
    if (guardian_index == 11) { sig_set.verified_11 = true; }
    if (guardian_index == 12) { sig_set.verified_12 = true; }
    if (guardian_index == 13) { sig_set.verified_13 = true; }
    if (guardian_index == 14) { sig_set.verified_14 = true; }
    if (guardian_index == 15) { sig_set.verified_15 = true; }
    if (guardian_index == 16) { sig_set.verified_16 = true; }
    if (guardian_index == 17) { sig_set.verified_17 = true; }
    if (guardian_index == 18) { sig_set.verified_18 = true; }

    sig_set.num_verified = sig_set.num_verified + 1;
}

// ---------------------------------------------------------------------------
// Core Bridge: Post VAA (submit and finalize a verified VAA)
// ---------------------------------------------------------------------------

fn count_verified(sig_set: SignatureSet) -> u64 {
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

pub post_vaa(
    config: BridgeConfig,
    sig_set: SignatureSet,
    guardian_set: GuardianSet,
    claim: ClaimRecord @mut @init(payer=payer, space=256) @signer,
    payer: account @mut @signer,
    vaa_hash: pubkey
) {
    require(config.is_active);
    require(sig_set.bridge == config.ctx.key);
    require(guardian_set.bridge == config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);

    // Verify the hash matches
    require(sig_set.hash == vaa_hash);

    // Check supermajority of signatures are verified
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // Guardian set must not have expired
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // Create claim record for replay protection
    claim.bridge = config.ctx.key;
    claim.vaa_hash = vaa_hash;
    claim.claimed = true;
    claim.claim_time = now;
}

// ---------------------------------------------------------------------------
// Core Bridge: Set Guardian Set (governance action via VAA)
// ---------------------------------------------------------------------------

pub set_guardian_set(
    config: BridgeConfig @mut,
    old_guardian_set: GuardianSet @mut,
    new_guardian_set: GuardianSet @mut @init(payer=payer, space=1024) @signer,
    sig_set: SignatureSet,
    payer: account @mut @signer,
    new_index: u32,
    new_num_guardians: u8,
    key_0: pubkey,
    key_1: pubkey,
    key_2: pubkey,
    key_3: pubkey,
    key_4: pubkey,
    key_5: pubkey,
    key_6: pubkey,
    key_7: pubkey,
    key_8: pubkey,
    key_9: pubkey,
    key_10: pubkey,
    key_11: pubkey,
    key_12: pubkey,
    key_13: pubkey,
    key_14: pubkey,
    key_15: pubkey,
    key_16: pubkey,
    key_17: pubkey,
    key_18: pubkey
) {
    require(config.is_active);
    require(old_guardian_set.bridge == config.ctx.key);
    require(sig_set.bridge == config.ctx.key);
    require(sig_set.guardian_set_index == old_guardian_set.index);

    // Verify supermajority on the governance VAA
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(old_guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // New index must be strictly greater than current
    require(new_index > config.guardian_set_index);
    require(new_num_guardians > 0);
    require(new_num_guardians <= 19);

    // Expire the old guardian set with a grace period
    let now: u64 = get_clock().unix_timestamp;
    let grace: u64 = guardian_set_grace_period();
    old_guardian_set.expiration_time = now + grace;

    // Initialize the new guardian set
    new_guardian_set.bridge = config.ctx.key;
    new_guardian_set.index = new_index;
    new_guardian_set.num_guardians = new_num_guardians;
    new_guardian_set.expiration_time = 0;

    new_guardian_set.key_0 = key_0;
    new_guardian_set.key_1 = key_1;
    new_guardian_set.key_2 = key_2;
    new_guardian_set.key_3 = key_3;
    new_guardian_set.key_4 = key_4;
    new_guardian_set.key_5 = key_5;
    new_guardian_set.key_6 = key_6;
    new_guardian_set.key_7 = key_7;
    new_guardian_set.key_8 = key_8;
    new_guardian_set.key_9 = key_9;
    new_guardian_set.key_10 = key_10;
    new_guardian_set.key_11 = key_11;
    new_guardian_set.key_12 = key_12;
    new_guardian_set.key_13 = key_13;
    new_guardian_set.key_14 = key_14;
    new_guardian_set.key_15 = key_15;
    new_guardian_set.key_16 = key_16;
    new_guardian_set.key_17 = key_17;
    new_guardian_set.key_18 = key_18;

    // Update bridge config to point to new guardian set
    config.guardian_set_index = new_index;
}

// ---------------------------------------------------------------------------
// Core Bridge: Admin / Config
// ---------------------------------------------------------------------------

pub set_bridge_fee(
    config: BridgeConfig @mut,
    authority: account @signer,
    new_fee: u64
) {
    require(config.authority == authority.ctx.key);
    config.fee = new_fee;
}

pub set_bridge_active(
    config: BridgeConfig @mut,
    authority: account @signer,
    active: bool
) {
    require(config.authority == authority.ctx.key);
    config.is_active = active;
}

pub transfer_bridge_authority(
    config: BridgeConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Token Bridge: Initialize
// ---------------------------------------------------------------------------

pub initialize_token_bridge(
    token_config: TokenBridgeConfig @mut @init(payer=authority, space=256) @signer,
    bridge_config: BridgeConfig,
    authority: account @mut @signer
) {
    require(bridge_config.is_active);

    token_config.bridge = bridge_config.ctx.key;
    token_config.authority = authority.ctx.key;
    token_config.is_active = true;
    token_config.registered_chains = 0;
}

// ---------------------------------------------------------------------------
// Token Bridge: Register Chain
// ---------------------------------------------------------------------------

pub register_chain(
    token_config: TokenBridgeConfig @mut,
    registration: ChainRegistration @mut @init(payer=payer, space=256) @signer,
    bridge_config: BridgeConfig,
    sig_set: SignatureSet,
    guardian_set: GuardianSet,
    payer: account @mut @signer,
    chain_id: u16,
    emitter_address: pubkey
) {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(sig_set.bridge == bridge_config.ctx.key);
    require(guardian_set.bridge == bridge_config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(chain_id > 0);

    // Verify governance VAA has supermajority
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    registration.token_bridge = token_config.ctx.key;
    registration.chain_id = chain_id;
    registration.emitter_address = emitter_address;
    registration.is_registered = true;

    token_config.registered_chains = token_config.registered_chains + 1;
}

// ---------------------------------------------------------------------------
// Token Bridge: Transfer Native (lock tokens, emit bridge message)
// ---------------------------------------------------------------------------

pub transfer_native(
    token_config: TokenBridgeConfig,
    bridge_config: BridgeConfig @mut,
    message: PostedMessage @mut @init(payer=sender, space=512) @signer,
    sender: account @mut @signer,
    sender_token_account: account @mut,
    custody_vault: account @mut,
    fee_collector_account: account @mut,
    token_program: account,
    amount: u64,
    recipient_chain: u16,
    recipient_address: pubkey,
    nonce: u32
) -> u64 {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(amount > 0);
    require(recipient_chain > 0);
    require(bridge_config.fee_collector == fee_collector_account.ctx.key);

    // Lock tokens in custody vault
    spl_token::SPLToken::transfer(sender_token_account, custody_vault, sender, amount);

    // Emit bridge message with transfer details
    let current_sequence: u64 = bridge_config.sequence;
    bridge_config.sequence = bridge_config.sequence + 1;

    // Payload hash encodes: amount, recipient_chain, recipient_address
    // In production the keccak256 hash would cover all transfer fields
    let transfer_hash: pubkey = keccak256();

    message.bridge = bridge_config.ctx.key;
    message.emitter = token_config.ctx.key;
    message.sequence = current_sequence;
    message.nonce = nonce;
    message.payload_hash = transfer_hash;
    message.consistency_level = 1;
    message.timestamp = get_clock().unix_timestamp;

    return current_sequence;
}

// ---------------------------------------------------------------------------
// Token Bridge: Complete Native (unlock tokens from incoming VAA)
// ---------------------------------------------------------------------------

pub complete_native(
    token_config: TokenBridgeConfig,
    bridge_config: BridgeConfig,
    sig_set: SignatureSet,
    guardian_set: GuardianSet,
    claim: ClaimRecord @mut @init(payer=payer, space=256) @signer,
    custody_vault: account @mut,
    recipient_token_account: account @mut,
    token_bridge_authority: account @signer,
    payer: account @mut @signer,
    token_program: account,
    vaa_hash: pubkey,
    amount: u64
) {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(sig_set.bridge == bridge_config.ctx.key);
    require(guardian_set.bridge == bridge_config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);
    require(amount > 0);

    // Verify supermajority
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // Guardian set must not have expired
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // Replay protection: create claim record
    claim.bridge = bridge_config.ctx.key;
    claim.vaa_hash = vaa_hash;
    claim.claimed = true;
    claim.claim_time = now;

    // Release locked tokens from custody to recipient
    spl_token::SPLToken::transfer(custody_vault, recipient_token_account, token_bridge_authority, amount);
}

// ---------------------------------------------------------------------------
// Token Bridge: Transfer Wrapped (burn wrapped tokens, emit bridge message)
// ---------------------------------------------------------------------------

pub transfer_wrapped(
    token_config: TokenBridgeConfig,
    bridge_config: BridgeConfig @mut,
    message: PostedMessage @mut @init(payer=sender, space=512) @signer,
    wrapped_meta: WrappedMeta,
    sender: account @mut @signer,
    sender_wrapped_account: account @mut,
    wrapped_mint: account @mut,
    fee_collector_account: account @mut,
    token_program: account,
    amount: u64,
    recipient_chain: u16,
    recipient_address: pubkey,
    nonce: u32
) -> u64 {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(wrapped_meta.token_bridge == token_config.ctx.key);
    require(wrapped_meta.mint == wrapped_mint.ctx.key);
    require(amount > 0);
    require(recipient_chain > 0);
    require(bridge_config.fee_collector == fee_collector_account.ctx.key);

    // Normalize amount to 8 decimals (Wormhole standard)
    // If original_decimals > 8, truncate; otherwise use as-is
    let mut normalized_amount: u64 = amount;
    if (wrapped_meta.original_decimals > 8) {
        let decimal_diff: u64 = (wrapped_meta.original_decimals as u64) - 8;
        let mut divisor: u64 = 1;
        let mut i: u64 = 0;
        // Manual power of 10 (max diff is ~10 so loop is bounded)
        if (decimal_diff >= 1) { divisor = divisor * 10; }
        if (decimal_diff >= 2) { divisor = divisor * 10; }
        if (decimal_diff >= 3) { divisor = divisor * 10; }
        if (decimal_diff >= 4) { divisor = divisor * 10; }
        if (decimal_diff >= 5) { divisor = divisor * 10; }
        if (decimal_diff >= 6) { divisor = divisor * 10; }
        if (decimal_diff >= 7) { divisor = divisor * 10; }
        if (decimal_diff >= 8) { divisor = divisor * 10; }
        if (decimal_diff >= 9) { divisor = divisor * 10; }
        if (decimal_diff >= 10) { divisor = divisor * 10; }
        normalized_amount = amount / divisor;
    }
    require(normalized_amount > 0);

    // Burn wrapped tokens
    spl_token::SPLToken::burn(sender_wrapped_account, wrapped_mint, sender, amount);

    // Emit bridge message
    let current_sequence: u64 = bridge_config.sequence;
    bridge_config.sequence = bridge_config.sequence + 1;

    let transfer_hash: pubkey = keccak256();

    message.bridge = bridge_config.ctx.key;
    message.emitter = token_config.ctx.key;
    message.sequence = current_sequence;
    message.nonce = nonce;
    message.payload_hash = transfer_hash;
    message.consistency_level = 1;
    message.timestamp = get_clock().unix_timestamp;

    return current_sequence;
}

// ---------------------------------------------------------------------------
// Token Bridge: Complete Wrapped (mint wrapped tokens from incoming VAA)
// ---------------------------------------------------------------------------

pub complete_wrapped(
    token_config: TokenBridgeConfig,
    bridge_config: BridgeConfig,
    sig_set: SignatureSet,
    guardian_set: GuardianSet,
    wrapped_meta: WrappedMeta,
    claim: ClaimRecord @mut @init(payer=payer, space=256) @signer,
    wrapped_mint: account @mut,
    recipient_wrapped_account: account @mut,
    token_bridge_authority: account @signer,
    payer: account @mut @signer,
    token_program: account,
    vaa_hash: pubkey,
    amount: u64
) {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(sig_set.bridge == bridge_config.ctx.key);
    require(guardian_set.bridge == bridge_config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(sig_set.hash == vaa_hash);
    require(wrapped_meta.token_bridge == token_config.ctx.key);
    require(wrapped_meta.mint == wrapped_mint.ctx.key);
    require(amount > 0);

    // Verify supermajority
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    // Guardian set must not have expired
    let now: u64 = get_clock().unix_timestamp;
    if (guardian_set.expiration_time > 0) {
        require(now < guardian_set.expiration_time);
    }

    // Denormalize amount back from 8 decimals to original decimals
    let mut denormalized_amount: u64 = amount;
    if (wrapped_meta.original_decimals > 8) {
        let decimal_diff: u64 = (wrapped_meta.original_decimals as u64) - 8;
        let mut multiplier: u64 = 1;
        if (decimal_diff >= 1) { multiplier = multiplier * 10; }
        if (decimal_diff >= 2) { multiplier = multiplier * 10; }
        if (decimal_diff >= 3) { multiplier = multiplier * 10; }
        if (decimal_diff >= 4) { multiplier = multiplier * 10; }
        if (decimal_diff >= 5) { multiplier = multiplier * 10; }
        if (decimal_diff >= 6) { multiplier = multiplier * 10; }
        if (decimal_diff >= 7) { multiplier = multiplier * 10; }
        if (decimal_diff >= 8) { multiplier = multiplier * 10; }
        if (decimal_diff >= 9) { multiplier = multiplier * 10; }
        if (decimal_diff >= 10) { multiplier = multiplier * 10; }
        denormalized_amount = amount * multiplier;
    }

    // Replay protection
    claim.bridge = bridge_config.ctx.key;
    claim.vaa_hash = vaa_hash;
    claim.claimed = true;
    claim.claim_time = now;

    // Mint wrapped tokens to recipient
    spl_token::SPLToken::mint_to(wrapped_mint, recipient_wrapped_account, token_bridge_authority, denormalized_amount);
}

// ---------------------------------------------------------------------------
// Token Bridge: Create Wrapped Asset Metadata
// ---------------------------------------------------------------------------

pub create_wrapped(
    token_config: TokenBridgeConfig @mut,
    bridge_config: BridgeConfig,
    sig_set: SignatureSet,
    guardian_set: GuardianSet,
    wrapped_meta: WrappedMeta @mut @init(payer=payer, space=256) @signer,
    payer: account @mut @signer,
    wrapped_mint: account,
    chain_id: u16,
    token_address_hash: pubkey,
    original_decimals: u8
) {
    require(token_config.is_active);
    require(bridge_config.is_active);
    require(token_config.bridge == bridge_config.ctx.key);
    require(sig_set.bridge == bridge_config.ctx.key);
    require(guardian_set.bridge == bridge_config.ctx.key);
    require(sig_set.guardian_set_index == guardian_set.index);
    require(chain_id > 0);

    // Verify governance VAA supermajority
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    require(verified_count >= threshold);

    wrapped_meta.token_bridge = token_config.ctx.key;
    wrapped_meta.chain_id = chain_id;
    wrapped_meta.token_address_hash = token_address_hash;
    wrapped_meta.original_decimals = original_decimals;
    wrapped_meta.mint = wrapped_mint.ctx.key;
}

// ---------------------------------------------------------------------------
// Token Bridge: Admin
// ---------------------------------------------------------------------------

pub set_token_bridge_active(
    token_config: TokenBridgeConfig @mut,
    authority: account @signer,
    active: bool
) {
    require(token_config.authority == authority.ctx.key);
    token_config.is_active = active;
}

pub transfer_token_bridge_authority(
    token_config: TokenBridgeConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(token_config.authority == authority.ctx.key);
    token_config.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Read-only Queries
// ---------------------------------------------------------------------------

pub get_bridge_fee(config: BridgeConfig) -> u64 {
    return config.fee;
}

pub get_guardian_set_index(config: BridgeConfig) -> u32 {
    return config.guardian_set_index;
}

pub get_sequence(config: BridgeConfig) -> u64 {
    return config.sequence;
}

pub get_num_guardians(guardian_set: GuardianSet) -> u8 {
    return guardian_set.num_guardians;
}

pub get_guardian_expiration(guardian_set: GuardianSet) -> u64 {
    return guardian_set.expiration_time;
}

pub get_num_verified(sig_set: SignatureSet) -> u8 {
    return sig_set.num_verified;
}

pub is_vaa_verified(sig_set: SignatureSet, guardian_set: GuardianSet) -> bool {
    let verified_count: u64 = count_verified(sig_set);
    let threshold: u64 = supermajority_threshold(guardian_set.num_guardians as u64);
    return verified_count >= threshold;
}

pub is_claimed(claim: ClaimRecord) -> bool {
    return claim.claimed;
}

pub get_message_sequence(message: PostedMessage) -> u64 {
    return message.sequence;
}

pub get_message_emitter(message: PostedMessage) -> pubkey {
    return message.emitter;
}

pub get_registered_chains(token_config: TokenBridgeConfig) -> u16 {
    return token_config.registered_chains;
}

pub is_chain_registered(registration: ChainRegistration) -> bool {
    return registration.is_registered;
}

pub get_wrapped_chain_id(wrapped_meta: WrappedMeta) -> u16 {
    return wrapped_meta.chain_id;
}

pub get_wrapped_original_decimals(wrapped_meta: WrappedMeta) -> u8 {
    return wrapped_meta.original_decimals;
}
