// 5IVE Civic Gateway / Identity Protocol Migration
//
// Civic's on-chain identity verification protocol. Gatekeeper Networks define
// verification standards; authorized Gatekeepers issue Gateway Tokens that
// prove a wallet has passed verification without storing PII on-chain.
//
// Architecture:
//   - GatekeeperNetwork: defines standards (KYC, age, uniqueness), fees, expiry
//   - Gatekeeper: authorized verifier within a network, stakes as bond
//   - GatewayToken: on-chain proof of verification, PDA from (network, owner)
//   - Features bitfield: bit 0=KYC, bit 1=age_18+, bit 2=uniqueness, bit 3=country
//   - Token states: 0=active, 1=revoked, 2=frozen, 3=expired

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account GatekeeperNetwork {
    authority: pubkey;
    name: string<32>;
    num_gatekeepers: u16;
    default_expiry_seconds: u64;
    max_expiry_seconds: u64;
    token_fee_lamports: u64;
    network_fee_lamports: u64;
    network_fee_collector: pubkey;
    metadata_uri_hash: pubkey;
    total_tokens_issued: u64;
    total_tokens_revoked: u64;
    is_active: bool;
    is_paused: bool;
    features_mask: u64;
}

account Gatekeeper {
    network: pubkey;
    authority: pubkey;
    tokens_issued: u64;
    tokens_revoked: u64;
    fees_collected: u64;
    is_active: bool;
    staked_amount: u64;
}

account GatewayToken {
    network: pubkey;
    gatekeeper: pubkey;
    owner: pubkey;
    issued_at: u64;
    expires_at: u64;
    state: u8;
    features: u64;
    parent_token: pubkey;
}

account VerificationResult {
    is_valid: bool;
    token_state: u8;
    expires_at: u64;
    network: pubkey;
}

// ---------------------------------------------------------------------------
// Constants (encoded as helpers)
// ---------------------------------------------------------------------------

fn state_active() -> u8 { return 0; }
fn state_revoked() -> u8 { return 1; }
fn state_frozen() -> u8 { return 2; }
fn state_expired() -> u8 { return 3; }

// ---------------------------------------------------------------------------
// Network Management
// ---------------------------------------------------------------------------

pub create_network(
    network: GatekeeperNetwork @mut @init(payer=authority_signer, space=512),
    authority_signer: account @mut @signer,
    name: string<32>,
    default_expiry_seconds: u64,
    max_expiry_seconds: u64,
    token_fee_lamports: u64,
    network_fee_lamports: u64,
    network_fee_collector: pubkey,
    features_mask: u64
) {
    require(default_expiry_seconds > 0);
    require(max_expiry_seconds >= default_expiry_seconds);

    network.authority = authority_signer.ctx.key;
    network.name = name;
    network.num_gatekeepers = 0;
    network.default_expiry_seconds = default_expiry_seconds;
    network.max_expiry_seconds = max_expiry_seconds;
    network.token_fee_lamports = token_fee_lamports;
    network.network_fee_lamports = network_fee_lamports;
    network.network_fee_collector = network_fee_collector;
    network.metadata_uri_hash = authority_signer.ctx.key;
    network.total_tokens_issued = 0;
    network.total_tokens_revoked = 0;
    network.is_active = true;
    network.is_paused = false;
    network.features_mask = features_mask;
}

pub update_network(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer,
    new_default_expiry_seconds: u64,
    new_max_expiry_seconds: u64,
    new_token_fee_lamports: u64,
    new_network_fee_lamports: u64,
    new_metadata_uri_hash: pubkey,
    new_features_mask: u64
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(new_default_expiry_seconds > 0);
    require(new_max_expiry_seconds >= new_default_expiry_seconds);

    network.default_expiry_seconds = new_default_expiry_seconds;
    network.max_expiry_seconds = new_max_expiry_seconds;
    network.token_fee_lamports = new_token_fee_lamports;
    network.network_fee_lamports = new_network_fee_lamports;
    network.metadata_uri_hash = new_metadata_uri_hash;
    network.features_mask = new_features_mask;
}

pub close_network(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);

    network.is_active = false;
    network.is_paused = true;
}

pub set_network_authority(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer,
    new_authority: pubkey
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);

    network.authority = new_authority;
}

pub pause_network(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(!network.is_paused);

    network.is_paused = true;
}

pub unpause_network(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(network.is_paused);

    network.is_paused = false;
}

pub set_expiry_config(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer,
    new_default_expiry_seconds: u64,
    new_max_expiry_seconds: u64
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(new_default_expiry_seconds > 0);
    require(new_max_expiry_seconds >= new_default_expiry_seconds);

    network.default_expiry_seconds = new_default_expiry_seconds;
    network.max_expiry_seconds = new_max_expiry_seconds;
}

// ---------------------------------------------------------------------------
// Gatekeeper Management
// ---------------------------------------------------------------------------

pub add_gatekeeper(
    network: GatekeeperNetwork @mut,
    gatekeeper: Gatekeeper @mut @init(payer=authority_signer, space=256),
    authority_signer: account @mut @signer,
    gatekeeper_authority: pubkey
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(!network.is_paused);

    gatekeeper.network = network.ctx.key;
    gatekeeper.authority = gatekeeper_authority;
    gatekeeper.tokens_issued = 0;
    gatekeeper.tokens_revoked = 0;
    gatekeeper.fees_collected = 0;
    gatekeeper.is_active = true;
    gatekeeper.staked_amount = 0;

    network.num_gatekeepers = network.num_gatekeepers + 1;
}

pub remove_gatekeeper(
    network: GatekeeperNetwork @mut,
    gatekeeper: Gatekeeper @mut,
    authority_signer: account @signer
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);
    require(gatekeeper.network == network.ctx.key);
    require(gatekeeper.is_active);

    gatekeeper.is_active = false;

    require(network.num_gatekeepers > 0);
    network.num_gatekeepers = network.num_gatekeepers - 1;
}

pub stake_gatekeeper(
    network: GatekeeperNetwork,
    gatekeeper: Gatekeeper @mut,
    gatekeeper_signer: account @signer,
    stake_source: account @mut,
    stake_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(network.is_active);
    require(!network.is_paused);
    require(gatekeeper.network == network.ctx.key);
    require(gatekeeper.authority == gatekeeper_signer.ctx.key);
    require(gatekeeper.is_active);
    require(amount > 0);

    spl_token::SPLToken::transfer(stake_source, stake_vault, gatekeeper_signer, amount);

    gatekeeper.staked_amount = gatekeeper.staked_amount + amount;
}

pub unstake_gatekeeper(
    network: GatekeeperNetwork,
    gatekeeper: Gatekeeper @mut,
    gatekeeper_signer: account @signer,
    stake_vault: account @mut,
    stake_destination: account @mut,
    vault_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(network.is_active);
    require(gatekeeper.network == network.ctx.key);
    require(gatekeeper.authority == gatekeeper_signer.ctx.key);
    require(amount > 0);
    require(amount <= gatekeeper.staked_amount);

    spl_token::SPLToken::transfer(stake_vault, stake_destination, vault_authority, amount);

    gatekeeper.staked_amount = gatekeeper.staked_amount - amount;
}

// ---------------------------------------------------------------------------
// Gateway Token Operations
// ---------------------------------------------------------------------------

pub issue_token(
    network: GatekeeperNetwork @mut,
    gatekeeper: Gatekeeper @mut,
    token: GatewayToken @mut @init(payer=gatekeeper_signer, space=256),
    gatekeeper_signer: account @mut @signer,
    owner_wallet: account,
    fee_payer: account @mut @signer,
    fee_destination: account @mut,
    network_fee_destination: account @mut,
    token_program: account,
    expiry_seconds: u64,
    features: u64
) {
    require(network.is_active);
    require(!network.is_paused);
    require(gatekeeper.network == network.ctx.key);
    require(gatekeeper.authority == gatekeeper_signer.ctx.key);
    require(gatekeeper.is_active);

    // Validate expiry
    let mut actual_expiry: u64 = expiry_seconds;
    if (expiry_seconds == 0) {
        actual_expiry = network.default_expiry_seconds;
    }
    require(actual_expiry <= network.max_expiry_seconds);
    require(actual_expiry > 0);

    // Validate features against network mask
    require((features & network.features_mask) == features);

    // Derive expected PDA
    let expected_pda: pubkey = derive_pda("gateway_token", network.ctx.key, owner_wallet.ctx.key);
    require(token.ctx.key == expected_pda);

    let now: u64 = get_clock().unix_timestamp as u64;

    token.network = network.ctx.key;
    token.gatekeeper = gatekeeper_signer.ctx.key;
    token.owner = owner_wallet.ctx.key;
    token.issued_at = now;
    token.expires_at = now + actual_expiry;
    token.state = state_active();
    token.features = features;
    token.parent_token = token.ctx.key;

    // Collect gatekeeper fee from fee_payer
    if (network.token_fee_lamports > 0) {
        spl_token::SPLToken::transfer(fee_payer, fee_destination, fee_payer, network.token_fee_lamports);
    }

    // Collect network fee
    if (network.network_fee_lamports > 0) {
        spl_token::SPLToken::transfer(fee_payer, network_fee_destination, fee_payer, network.network_fee_lamports);
    }

    gatekeeper.tokens_issued = gatekeeper.tokens_issued + 1;
    gatekeeper.fees_collected = gatekeeper.fees_collected + network.token_fee_lamports;
    network.total_tokens_issued = network.total_tokens_issued + 1;
}

pub refresh_token(
    network: GatekeeperNetwork,
    gatekeeper: Gatekeeper,
    token: GatewayToken @mut,
    gatekeeper_signer: account @signer,
    expiry_seconds: u64
) {
    require(network.is_active);
    require(!network.is_paused);
    require(gatekeeper.network == network.ctx.key);
    require(gatekeeper.authority == gatekeeper_signer.ctx.key);
    require(gatekeeper.is_active);
    require(token.network == network.ctx.key);

    // Only active or expired tokens can be refreshed
    require(token.state == state_active() || token.state == state_expired());

    let mut actual_expiry: u64 = expiry_seconds;
    if (expiry_seconds == 0) {
        actual_expiry = network.default_expiry_seconds;
    }
    require(actual_expiry <= network.max_expiry_seconds);
    require(actual_expiry > 0);

    let now: u64 = get_clock().unix_timestamp as u64;

    // Set new expiry from current time
    token.expires_at = now + actual_expiry;
    token.state = state_active();

    // Update gatekeeper reference if refreshed by a different gatekeeper
    token.gatekeeper = gatekeeper_signer.ctx.key;
}

pub revoke_token(
    network: GatekeeperNetwork @mut,
    gatekeeper: Gatekeeper @mut,
    token: GatewayToken @mut,
    authority_signer: account @signer
) {
    require(network.is_active);
    require(token.network == network.ctx.key);

    // Either the gatekeeper or network authority can revoke
    let is_gatekeeper: bool = gatekeeper.authority == authority_signer.ctx.key;
    let is_network_authority: bool = network.authority == authority_signer.ctx.key;
    require(is_gatekeeper || is_network_authority);

    if (is_gatekeeper) {
        require(gatekeeper.network == network.ctx.key);
        require(gatekeeper.is_active);
    }

    // Cannot revoke an already-revoked token
    require(token.state != state_revoked());

    token.state = state_revoked();

    gatekeeper.tokens_revoked = gatekeeper.tokens_revoked + 1;
    network.total_tokens_revoked = network.total_tokens_revoked + 1;
}

pub freeze_token(
    network: GatekeeperNetwork,
    gatekeeper: Gatekeeper,
    token: GatewayToken @mut,
    authority_signer: account @signer
) {
    require(network.is_active);
    require(token.network == network.ctx.key);

    // Either gatekeeper or network authority can freeze
    let is_gatekeeper: bool = gatekeeper.authority == authority_signer.ctx.key;
    let is_network_authority: bool = network.authority == authority_signer.ctx.key;
    require(is_gatekeeper || is_network_authority);

    if (is_gatekeeper) {
        require(gatekeeper.network == network.ctx.key);
        require(gatekeeper.is_active);
    }

    // Can only freeze active tokens
    require(token.state == state_active());

    token.state = state_frozen();
}

pub unfreeze_token(
    network: GatekeeperNetwork,
    gatekeeper: Gatekeeper,
    token: GatewayToken @mut,
    authority_signer: account @signer
) {
    require(network.is_active);
    require(token.network == network.ctx.key);

    // Either gatekeeper or network authority can unfreeze
    let is_gatekeeper: bool = gatekeeper.authority == authority_signer.ctx.key;
    let is_network_authority: bool = network.authority == authority_signer.ctx.key;
    require(is_gatekeeper || is_network_authority);

    if (is_gatekeeper) {
        require(gatekeeper.network == network.ctx.key);
        require(gatekeeper.is_active);
    }

    // Can only unfreeze frozen tokens
    require(token.state == state_frozen());

    token.state = state_active();
}

pub burn_token(
    network: GatekeeperNetwork @mut,
    token: GatewayToken @mut,
    owner_signer: account @signer
) {
    require(token.network == network.ctx.key);
    require(token.owner == owner_signer.ctx.key);

    // Owner can burn their own token regardless of state (except already revoked)
    require(token.state != state_revoked());

    token.state = state_revoked();
    network.total_tokens_revoked = network.total_tokens_revoked + 1;
}

// ---------------------------------------------------------------------------
// Verification (Consumer-facing)
// ---------------------------------------------------------------------------

fn check_token_validity(token: GatewayToken, network: GatekeeperNetwork) -> bool {
    if (!network.is_active) {
        return false;
    }
    if (network.is_paused) {
        return false;
    }
    if (token.state != state_active()) {
        return false;
    }
    let now: u64 = get_clock().unix_timestamp as u64;
    if (now >= token.expires_at) {
        return false;
    }
    return true;
}

pub verify_token(
    network: GatekeeperNetwork,
    token: GatewayToken,
    result: VerificationResult @mut @init(payer=requester, space=128),
    requester: account @mut @signer,
    owner_wallet: account
) {
    require(token.network == network.ctx.key);
    require(token.owner == owner_wallet.ctx.key);

    // Verify PDA derivation
    let expected_pda: pubkey = derive_pda("gateway_token", network.ctx.key, owner_wallet.ctx.key);
    require(token.ctx.key == expected_pda);

    let now: u64 = get_clock().unix_timestamp as u64;

    let mut effective_state: u8 = token.state;
    if (token.state == state_active() && now >= token.expires_at) {
        effective_state = state_expired();
    }

    let valid: bool = check_token_validity(token, network);

    result.is_valid = valid;
    result.token_state = effective_state;
    result.expires_at = token.expires_at;
    result.network = network.ctx.key;
}

pub verify_token_with_features(
    network: GatekeeperNetwork,
    token: GatewayToken,
    result: VerificationResult @mut @init(payer=requester, space=128),
    requester: account @mut @signer,
    owner_wallet: account,
    required_features: u64
) {
    require(token.network == network.ctx.key);
    require(token.owner == owner_wallet.ctx.key);

    // Verify PDA derivation
    let expected_pda: pubkey = derive_pda("gateway_token", network.ctx.key, owner_wallet.ctx.key);
    require(token.ctx.key == expected_pda);

    let now: u64 = get_clock().unix_timestamp as u64;

    let mut effective_state: u8 = token.state;
    if (token.state == state_active() && now >= token.expires_at) {
        effective_state = state_expired();
    }

    let valid: bool = check_token_validity(token, network);

    // Bitwise feature check: token must have all required features
    let has_features: bool = (token.features & required_features) == required_features;

    result.is_valid = valid && has_features;
    result.token_state = effective_state;
    result.expires_at = token.expires_at;
    result.network = network.ctx.key;
}

// ---------------------------------------------------------------------------
// Fee Management
// ---------------------------------------------------------------------------

pub set_token_fee(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer,
    new_token_fee_lamports: u64
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);

    network.token_fee_lamports = new_token_fee_lamports;
}

pub set_network_fee(
    network: GatekeeperNetwork @mut,
    authority_signer: account @signer,
    new_network_fee_lamports: u64,
    new_fee_collector: pubkey
) {
    require(network.authority == authority_signer.ctx.key);
    require(network.is_active);

    network.network_fee_lamports = new_network_fee_lamports;
    network.network_fee_collector = new_fee_collector;
}

pub collect_fees(
    gatekeeper: Gatekeeper @mut,
    gatekeeper_signer: account @signer,
    fee_vault: account @mut,
    fee_destination: account @mut,
    vault_authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(gatekeeper.authority == gatekeeper_signer.ctx.key);
    require(gatekeeper.is_active);
    require(amount > 0);
    require(amount <= gatekeeper.fees_collected);

    spl_token::SPLToken::transfer(fee_vault, fee_destination, vault_authority, amount);

    gatekeeper.fees_collected = gatekeeper.fees_collected - amount;
}

// ---------------------------------------------------------------------------
// Read-only Getters
// ---------------------------------------------------------------------------

pub get_network_active(network: GatekeeperNetwork) -> bool {
    return network.is_active;
}

pub get_network_paused(network: GatekeeperNetwork) -> bool {
    return network.is_paused;
}

pub get_network_gatekeeper_count(network: GatekeeperNetwork) -> u16 {
    return network.num_gatekeepers;
}

pub get_network_total_issued(network: GatekeeperNetwork) -> u64 {
    return network.total_tokens_issued;
}

pub get_network_total_revoked(network: GatekeeperNetwork) -> u64 {
    return network.total_tokens_revoked;
}

pub get_network_features_mask(network: GatekeeperNetwork) -> u64 {
    return network.features_mask;
}

pub get_token_state(token: GatewayToken) -> u8 {
    return token.state;
}

pub get_token_owner(token: GatewayToken) -> pubkey {
    return token.owner;
}

pub get_token_expiry(token: GatewayToken) -> u64 {
    return token.expires_at;
}

pub get_token_features(token: GatewayToken) -> u64 {
    return token.features;
}

pub is_token_valid(
    network: GatekeeperNetwork,
    token: GatewayToken
) -> bool {
    return check_token_validity(token, network);
}

pub get_gatekeeper_tokens_issued(gatekeeper: Gatekeeper) -> u64 {
    return gatekeeper.tokens_issued;
}

pub get_gatekeeper_stake(gatekeeper: Gatekeeper) -> u64 {
    return gatekeeper.staked_amount;
}
