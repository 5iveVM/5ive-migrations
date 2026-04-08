// Mercl Smart Wallet Protocol - 5IVE Migration
//
// Multi-signature smart wallet with session keys, spending limits,
// time-locked transactions, and social recovery.
//
// Features:
//   - Configurable m-of-n guardian multisig (up to 5 guardians)
//   - Propose / approve / execute transaction flow
//   - Session keys with per-key spending limits and expiry
//   - Daily spending limits per wallet
//   - Time-lock for high-value transactions
//   - Social recovery with guardian quorum + timelock
//   - Pause / unpause for emergency wallet freeze
//   - Upgrade path for wallet configuration changes

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account SmartWallet {
    owner: pubkey;
    guardian_1: pubkey;
    guardian_2: pubkey;
    guardian_3: pubkey;
    guardian_4: pubkey;
    guardian_5: pubkey;
    threshold: u8;
    num_guardians: u8;
    daily_limit: u64;
    daily_spent: u64;
    limit_reset_time: u64;
    time_lock_duration: u64;
    time_lock_threshold: u64;
    recovery_pending: bool;
    is_paused: bool;
    nonce: u64;
}

account Transaction {
    wallet: pubkey;
    proposer: pubkey;
    recipient: pubkey;
    amount: u64;
    data_hash: pubkey;
    approvals: u8;
    rejections: u8;
    status: u8;          // 0 = pending, 1 = approved, 2 = executed, 3 = rejected, 4 = cancelled
    created_at: u64;
    execute_after: u64;
}

account SessionKey {
    wallet: pubkey;
    key: pubkey;
    spending_limit: u64;
    spent: u64;
    expires_at: u64;
    is_active: bool;
}

account RecoveryRequest {
    wallet: pubkey;
    new_owner: pubkey;
    initiator: pubkey;
    confirmations: u8;
    initiated_at: u64;
    is_executed: bool;
}

// ---------------------------------------------------------------------------
// Wallet lifecycle
// ---------------------------------------------------------------------------

/// Create a new smart wallet with an owner and initial set of guardians.
/// The threshold defines how many guardian approvals are needed for operations.
pub create_wallet(
    wallet: SmartWallet @mut @init(payer=owner, space=800),
    owner: account @mut @signer,
    guardian_1: pubkey,
    guardian_2: pubkey,
    guardian_3: pubkey,
    guardian_4: pubkey,
    guardian_5: pubkey,
    num_guardians: u8,
    threshold: u8,
    daily_limit: u64,
    time_lock_duration: u64,
    time_lock_threshold: u64
) {
    require(num_guardians >= 1);
    require(num_guardians <= 5);
    require(threshold >= 1);
    require(threshold <= num_guardians);
    require(daily_limit > 0);

    wallet.owner = owner.ctx.key;
    wallet.guardian_1 = guardian_1;
    wallet.guardian_2 = guardian_2;
    wallet.guardian_3 = guardian_3;
    wallet.guardian_4 = guardian_4;
    wallet.guardian_5 = guardian_5;
    wallet.num_guardians = num_guardians;
    wallet.threshold = threshold;
    wallet.daily_limit = daily_limit;
    wallet.daily_spent = 0;
    wallet.limit_reset_time = get_clock().slot;
    wallet.time_lock_duration = time_lock_duration;
    wallet.time_lock_threshold = time_lock_threshold;
    wallet.recovery_pending = false;
    wallet.is_paused = false;
    wallet.nonce = 0;
}

/// Add a new guardian to the wallet. Owner only. Max 5 guardians.
pub add_guardian(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_guardian: pubkey
) {
    require(wallet.owner == owner.ctx.key);
    require(!wallet.is_paused);
    require(wallet.num_guardians < 5);

    let idx: u8 = wallet.num_guardians + 1;
    if (idx == 2) {
        wallet.guardian_2 = new_guardian;
    }
    if (idx == 3) {
        wallet.guardian_3 = new_guardian;
    }
    if (idx == 4) {
        wallet.guardian_4 = new_guardian;
    }
    if (idx == 5) {
        wallet.guardian_5 = new_guardian;
    }

    wallet.num_guardians = wallet.num_guardians + 1;
}

/// Remove a guardian by index (1-5). Owner only. Threshold must remain satisfiable.
pub remove_guardian(
    wallet: SmartWallet @mut,
    owner: account @signer,
    guardian_index: u8
) {
    require(wallet.owner == owner.ctx.key);
    require(!wallet.is_paused);
    require(guardian_index >= 1);
    require(guardian_index <= wallet.num_guardians);
    require(wallet.num_guardians - 1 >= wallet.threshold);

    // Zero out the removed slot (shift is not needed; we track count)
    let zero: pubkey = owner.ctx.key; // placeholder sentinel
    if (guardian_index == 1) {
        wallet.guardian_1 = wallet.guardian_5;
    }
    if (guardian_index == 2) {
        wallet.guardian_2 = wallet.guardian_5;
    }
    if (guardian_index == 3) {
        wallet.guardian_3 = wallet.guardian_5;
    }
    if (guardian_index == 4) {
        wallet.guardian_4 = wallet.guardian_5;
    }
    // guardian_5 slot is now unused after compaction

    wallet.num_guardians = wallet.num_guardians - 1;
}

/// Change the multisig threshold. Owner only.
pub set_threshold(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_threshold: u8
) {
    require(wallet.owner == owner.ctx.key);
    require(new_threshold >= 1);
    require(new_threshold <= wallet.num_guardians);
    wallet.threshold = new_threshold;
}

// ---------------------------------------------------------------------------
// Transaction flow
// ---------------------------------------------------------------------------

// Helper: check if a pubkey matches any active guardian slot
fn is_guardian(wallet: SmartWallet, key: pubkey, num: u8) -> bool {
    if (num >= 1) {
        if (wallet.guardian_1 == key) { return true; }
    }
    if (num >= 2) {
        if (wallet.guardian_2 == key) { return true; }
    }
    if (num >= 3) {
        if (wallet.guardian_3 == key) { return true; }
    }
    if (num >= 4) {
        if (wallet.guardian_4 == key) { return true; }
    }
    if (num >= 5) {
        if (wallet.guardian_5 == key) { return true; }
    }
    return false;
}

/// Propose a new transaction from the wallet. Owner or guardian.
pub propose_transaction(
    wallet: SmartWallet @mut,
    tx: Transaction @mut @init(payer=proposer, space=500),
    proposer: account @mut @signer,
    recipient: pubkey,
    amount: u64,
    data_hash: pubkey
) {
    require(!wallet.is_paused);
    let is_owner: bool = wallet.owner == proposer.ctx.key;
    let is_guard: bool = is_guardian(wallet, proposer.ctx.key, wallet.num_guardians);
    require(is_owner || is_guard);
    require(amount > 0);

    let now: u64 = get_clock().slot;

    tx.wallet = wallet.ctx.key;
    tx.proposer = proposer.ctx.key;
    tx.recipient = recipient;
    tx.amount = amount;
    tx.data_hash = data_hash;
    tx.approvals = 0;
    tx.rejections = 0;
    tx.status = 0;
    tx.created_at = now;

    // Apply time-lock if amount exceeds threshold
    if (amount >= wallet.time_lock_threshold) {
        tx.execute_after = now + wallet.time_lock_duration;
    } else {
        tx.execute_after = now;
    }

    wallet.nonce = wallet.nonce + 1;
}

/// Guardian approves a pending transaction.
pub approve_transaction(
    wallet: SmartWallet,
    tx: Transaction @mut,
    guardian: account @signer
) {
    require(!wallet.is_paused);
    require(tx.wallet == wallet.ctx.key);
    require(tx.status == 0);
    require(is_guardian(wallet, guardian.ctx.key, wallet.num_guardians));

    tx.approvals = tx.approvals + 1;

    // Auto-advance status when threshold is met
    if (tx.approvals >= wallet.threshold) {
        tx.status = 1; // approved, ready for execution
    }
}

/// Execute an approved transaction after time-lock has elapsed.
pub execute_transaction(
    wallet: SmartWallet @mut @signer,
    tx: Transaction @mut,
    wallet_source: account @mut,
    recipient_account: account @mut,
    executor: account @signer,
    token_program: account
) {
    require(!wallet.is_paused);
    require(tx.wallet == wallet.ctx.key);
    require(tx.status == 1);

    let now: u64 = get_clock().slot;
    require(now >= tx.execute_after);

    // Reset daily limit window if needed (simplified: per-epoch reset)
    if (now > wallet.limit_reset_time + 216000) {
        wallet.daily_spent = 0;
        wallet.limit_reset_time = now;
    }

    // Enforce daily spending limit
    require(wallet.daily_spent + tx.amount <= wallet.daily_limit);

    spl_token::SPLToken::transfer(wallet_source, recipient_account, wallet, tx.amount);

    wallet.daily_spent = wallet.daily_spent + tx.amount;
    tx.status = 2; // executed
}

/// Guardian rejects a pending transaction.
pub reject_transaction(
    wallet: SmartWallet,
    tx: Transaction @mut,
    guardian: account @signer
) {
    require(!wallet.is_paused);
    require(tx.wallet == wallet.ctx.key);
    require(tx.status == 0);
    require(is_guardian(wallet, guardian.ctx.key, wallet.num_guardians));

    tx.rejections = tx.rejections + 1;

    // If enough rejections to make threshold impossible, mark rejected
    let remaining: u8 = wallet.num_guardians - tx.approvals - tx.rejections;
    if (tx.approvals + remaining < wallet.threshold) {
        tx.status = 3; // rejected
    }
}

// ---------------------------------------------------------------------------
// Session keys
// ---------------------------------------------------------------------------

/// Create a temporary session key with spending limit and expiry.
pub create_session_key(
    wallet: SmartWallet,
    session: SessionKey @mut @init(payer=owner, space=400),
    owner: account @mut @signer,
    key: pubkey,
    spending_limit: u64,
    expires_at: u64
) {
    require(wallet.owner == owner.ctx.key);
    require(!wallet.is_paused);
    require(spending_limit > 0);

    let now: u64 = get_clock().slot;
    require(expires_at > now);

    session.wallet = wallet.ctx.key;
    session.key = key;
    session.spending_limit = spending_limit;
    session.spent = 0;
    session.expires_at = expires_at;
    session.is_active = true;
}

/// Revoke an active session key. Owner only.
pub revoke_session_key(
    wallet: SmartWallet,
    session: SessionKey @mut,
    owner: account @signer
) {
    require(wallet.owner == owner.ctx.key);
    require(session.wallet == wallet.ctx.key);
    require(session.is_active);

    session.is_active = false;
}

/// Execute a transaction using a session key (no multisig required).
/// Enforced by the session key's spending limit and expiry.
pub execute_with_session_key(
    wallet: SmartWallet @mut @signer,
    session: SessionKey @mut,
    wallet_source: account @mut,
    recipient_account: account @mut,
    session_signer: account @signer,
    token_program: account,
    amount: u64
) {
    require(!wallet.is_paused);
    require(session.wallet == wallet.ctx.key);
    require(session.is_active);
    require(session.key == session_signer.ctx.key);

    let now: u64 = get_clock().slot;
    require(now < session.expires_at);
    require(amount > 0);
    require(session.spent + amount <= session.spending_limit);

    // Also respect wallet daily limit
    if (now > wallet.limit_reset_time + 216000) {
        wallet.daily_spent = 0;
        wallet.limit_reset_time = now;
    }
    require(wallet.daily_spent + amount <= wallet.daily_limit);

    spl_token::SPLToken::transfer(wallet_source, recipient_account, wallet, amount);

    session.spent = session.spent + amount;
    wallet.daily_spent = wallet.daily_spent + amount;
}

// ---------------------------------------------------------------------------
// Spending limits and time-lock
// ---------------------------------------------------------------------------

/// Set or update the daily spending limit for the wallet. Owner only.
pub set_spending_limit(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_daily_limit: u64
) {
    require(wallet.owner == owner.ctx.key);
    require(new_daily_limit > 0);
    wallet.daily_limit = new_daily_limit;
}

/// Set or update the time-lock duration and threshold. Owner only.
/// Transactions exceeding time_lock_threshold will be delayed by duration slots.
pub set_time_lock(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_duration: u64,
    new_threshold: u64
) {
    require(wallet.owner == owner.ctx.key);
    require(new_threshold > 0);
    wallet.time_lock_duration = new_duration;
    wallet.time_lock_threshold = new_threshold;
}

// ---------------------------------------------------------------------------
// Social recovery
// ---------------------------------------------------------------------------

/// A guardian initiates wallet recovery, proposing a new owner.
pub initiate_recovery(
    wallet: SmartWallet @mut,
    recovery: RecoveryRequest @mut @init(payer=guardian, space=400),
    guardian: account @mut @signer,
    new_owner: pubkey
) {
    require(!wallet.recovery_pending);
    require(is_guardian(wallet, guardian.ctx.key, wallet.num_guardians));

    let now: u64 = get_clock().slot;

    recovery.wallet = wallet.ctx.key;
    recovery.new_owner = new_owner;
    recovery.initiator = guardian.ctx.key;
    recovery.confirmations = 1;
    recovery.initiated_at = now;
    recovery.is_executed = false;

    wallet.recovery_pending = true;
}

/// Additional guardians confirm the recovery request.
pub confirm_recovery(
    wallet: SmartWallet,
    recovery: RecoveryRequest @mut,
    guardian: account @signer
) {
    require(wallet.recovery_pending);
    require(recovery.wallet == wallet.ctx.key);
    require(!recovery.is_executed);
    require(is_guardian(wallet, guardian.ctx.key, wallet.num_guardians));
    require(recovery.initiator != guardian.ctx.key);

    recovery.confirmations = recovery.confirmations + 1;
}

/// Execute recovery after threshold confirmations and time-lock period.
pub execute_recovery(
    wallet: SmartWallet @mut,
    recovery: RecoveryRequest @mut,
    executor: account @signer
) {
    require(wallet.recovery_pending);
    require(recovery.wallet == wallet.ctx.key);
    require(!recovery.is_executed);
    require(recovery.confirmations >= wallet.threshold);

    let now: u64 = get_clock().slot;
    require(now >= recovery.initiated_at + wallet.time_lock_duration);

    wallet.owner = recovery.new_owner;
    wallet.recovery_pending = false;
    recovery.is_executed = true;
}

/// Owner cancels a pending recovery (proves they still have access).
pub cancel_recovery(
    wallet: SmartWallet @mut,
    recovery: RecoveryRequest @mut,
    owner: account @signer
) {
    require(wallet.owner == owner.ctx.key);
    require(wallet.recovery_pending);
    require(recovery.wallet == wallet.ctx.key);
    require(!recovery.is_executed);

    wallet.recovery_pending = false;
    recovery.is_executed = true; // mark as resolved
}

// ---------------------------------------------------------------------------
// Ownership and admin
// ---------------------------------------------------------------------------

/// Direct ownership transfer (no recovery flow). Owner only.
pub transfer_ownership(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(wallet.owner == owner.ctx.key);
    require(!wallet.is_paused);
    wallet.owner = new_owner;
}

/// Pause or unpause the wallet. Owner only. Paused wallets reject all operations.
pub set_paused(
    wallet: SmartWallet @mut,
    owner: account @signer,
    paused: bool
) {
    require(wallet.owner == owner.ctx.key);
    wallet.is_paused = paused;
}

/// Upgrade wallet configuration (thresholds, limits, guardians) in one call.
pub upgrade_wallet(
    wallet: SmartWallet @mut,
    owner: account @signer,
    new_threshold: u8,
    new_daily_limit: u64,
    new_time_lock_duration: u64,
    new_time_lock_threshold: u64
) {
    require(wallet.owner == owner.ctx.key);
    require(!wallet.is_paused);
    require(new_threshold >= 1);
    require(new_threshold <= wallet.num_guardians);
    require(new_daily_limit > 0);
    require(new_time_lock_threshold > 0);

    wallet.threshold = new_threshold;
    wallet.daily_limit = new_daily_limit;
    wallet.time_lock_duration = new_time_lock_duration;
    wallet.time_lock_threshold = new_time_lock_threshold;
}

// ---------------------------------------------------------------------------
// Read helpers
// ---------------------------------------------------------------------------

pub get_wallet_owner(wallet: SmartWallet) -> pubkey {
    return wallet.owner;
}

pub get_threshold(wallet: SmartWallet) -> u8 {
    return wallet.threshold;
}

pub get_daily_spent(wallet: SmartWallet) -> u64 {
    return wallet.daily_spent;
}

pub get_tx_status(tx: Transaction) -> u8 {
    return tx.status;
}

pub get_session_remaining(session: SessionKey) -> u64 {
    return session.spending_limit - session.spent;
}
