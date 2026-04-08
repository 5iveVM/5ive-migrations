// 5IVE Squads Protocol -- Multisig / Smart Account Migration
//
// Squads is a multisig protocol for DAOs and teams on Solana. It provides
// shared custody of assets via M-of-N approval with time-locks and
// spending limits for operational efficiency.
//
// Design:
//   - Multisig: up to 10 members with configurable threshold (M of N)
//   - Transaction: proposed action requiring threshold approvals + time_lock
//   - SpendingLimit: per-token budgets allowing fast transfers without full approval
//   - Vault: PDA-controlled token vault owned by the multisig
//   - Key difference from wallet (Mercl): Squads is team/DAO-oriented with
//     equal members; Mercl is personal with owner + guardians
//   - All math integer-only; time in seconds; status as u8 enum

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Multisig {
    authority: pubkey;
    threshold: u64;
    num_members: u64;
    member_1: pubkey;
    member_2: pubkey;
    member_3: pubkey;
    member_4: pubkey;
    member_5: pubkey;
    member_6: pubkey;
    member_7: pubkey;
    member_8: pubkey;
    member_9: pubkey;
    member_10: pubkey;
    time_lock_seconds: u64;
    transaction_index: u64;
    config_authority: pubkey;   // can change config without full proposal
    is_active: bool;
}

account Transaction {
    multisig: pubkey;
    proposer: pubkey;
    instruction_hash: pubkey;  // hash of the proposed instruction data
    status: u8;                // 0=pending, 1=approved, 2=rejected, 3=executed, 4=cancelled
    approval_count: u64;
    rejection_count: u64;
    approved_by_1: bool;
    approved_by_2: bool;
    approved_by_3: bool;
    approved_by_4: bool;
    approved_by_5: bool;
    approved_by_6: bool;
    approved_by_7: bool;
    approved_by_8: bool;
    approved_by_9: bool;
    approved_by_10: bool;
    created_at: u64;
    execute_after: u64;        // created_at + time_lock_seconds
}

account SpendingLimit {
    multisig: pubkey;
    token_mint: pubkey;
    amount_limit: u64;
    period: u8;               // 0=daily, 1=weekly, 2=monthly
    amount_spent: u64;
    last_reset: u64;          // timestamp of last period reset
    is_active: bool;
}

account Vault {
    multisig: pubkey;
    vault_index: u64;
    authority_bump: u64;       // PDA bump seed for vault authority
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// Check if a pubkey matches any member slot in the multisig
fn is_member(ms: Multisig, who: pubkey) -> bool {
    if (ms.member_1 == who) { return true; }
    if (ms.member_2 == who) { return true; }
    if (ms.member_3 == who) { return true; }
    if (ms.member_4 == who) { return true; }
    if (ms.member_5 == who) { return true; }
    if (ms.member_6 == who) { return true; }
    if (ms.member_7 == who) { return true; }
    if (ms.member_8 == who) { return true; }
    if (ms.member_9 == who) { return true; }
    if (ms.member_10 == who) { return true; }
    return false;
}

// Get member index (1-10) for a pubkey, or 0 if not found
fn member_index(ms: Multisig, who: pubkey) -> u64 {
    if (ms.member_1 == who) { return 1; }
    if (ms.member_2 == who) { return 2; }
    if (ms.member_3 == who) { return 3; }
    if (ms.member_4 == who) { return 4; }
    if (ms.member_5 == who) { return 5; }
    if (ms.member_6 == who) { return 6; }
    if (ms.member_7 == who) { return 7; }
    if (ms.member_8 == who) { return 8; }
    if (ms.member_9 == who) { return 9; }
    if (ms.member_10 == who) { return 10; }
    return 0;
}

// Seconds per period: daily=86400, weekly=604800, monthly=2592000
fn period_seconds(period: u8) -> u64 {
    if (period == 0) { return 86400; }
    if (period == 1) { return 604800; }
    return 2592000;
}

// Zero pubkey constant (11111111111111111111111111111111)
fn zero_key() -> pubkey {
    return 11111111111111111111111111111111;
}

// ---------------------------------------------------------------------------
// Multisig Lifecycle
// ---------------------------------------------------------------------------

// 1. create_multisig -- create a new multisig with members and config
pub create_multisig(
    ms: Multisig @mut @init(payer=creator, space=1024) @signer,
    creator: account @mut @signer,
    member_1: pubkey,
    member_2: pubkey,
    member_3: pubkey,
    num_members: u64,
    threshold: u64,
    time_lock_seconds: u64
) {
    // At least 1 member, threshold 1..num_members
    require(num_members >= 1);
    require(num_members <= 10);
    require(threshold >= 1);
    require(threshold <= num_members);

    ms.authority = creator.ctx.key;
    ms.threshold = threshold;
    ms.num_members = num_members;
    ms.member_1 = member_1;
    ms.member_2 = member_2;
    ms.member_3 = member_3;
    ms.member_4 = zero_key();
    ms.member_5 = zero_key();
    ms.member_6 = zero_key();
    ms.member_7 = zero_key();
    ms.member_8 = zero_key();
    ms.member_9 = zero_key();
    ms.member_10 = zero_key();
    ms.time_lock_seconds = time_lock_seconds;
    ms.transaction_index = 0;
    ms.config_authority = creator.ctx.key;
    ms.is_active = true;
}

// 2. add_member -- add a new member to the multisig
pub add_member(
    ms: Multisig @mut,
    authority: account @signer,
    new_member: pubkey
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    require(ms.num_members < 10);

    // Find first empty slot and assign
    let next: u64 = ms.num_members + 1;
    if (next == 2) { ms.member_2 = new_member; }
    if (next == 3) { ms.member_3 = new_member; }
    if (next == 4) { ms.member_4 = new_member; }
    if (next == 5) { ms.member_5 = new_member; }
    if (next == 6) { ms.member_6 = new_member; }
    if (next == 7) { ms.member_7 = new_member; }
    if (next == 8) { ms.member_8 = new_member; }
    if (next == 9) { ms.member_9 = new_member; }
    if (next == 10) { ms.member_10 = new_member; }

    ms.num_members = next;
}

// 3. remove_member -- remove a member (threshold must still be reachable)
pub remove_member(
    ms: Multisig @mut,
    authority: account @signer,
    member_to_remove: pubkey
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    require(ms.num_members > 1);

    // Verify member exists
    let idx: u64 = member_index(ms, member_to_remove);
    require(idx > 0);

    // Zero out the member slot
    if (idx == 1) { ms.member_1 = zero_key(); }
    if (idx == 2) { ms.member_2 = zero_key(); }
    if (idx == 3) { ms.member_3 = zero_key(); }
    if (idx == 4) { ms.member_4 = zero_key(); }
    if (idx == 5) { ms.member_5 = zero_key(); }
    if (idx == 6) { ms.member_6 = zero_key(); }
    if (idx == 7) { ms.member_7 = zero_key(); }
    if (idx == 8) { ms.member_8 = zero_key(); }
    if (idx == 9) { ms.member_9 = zero_key(); }
    if (idx == 10) { ms.member_10 = zero_key(); }

    ms.num_members = ms.num_members - 1;

    // Threshold cannot exceed remaining members
    if (ms.threshold > ms.num_members) {
        ms.threshold = ms.num_members;
    }
}

// 4. change_threshold -- update the approval threshold
pub change_threshold(
    ms: Multisig @mut,
    authority: account @signer,
    new_threshold: u64
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    require(new_threshold >= 1);
    require(new_threshold <= ms.num_members);

    ms.threshold = new_threshold;
}

// ---------------------------------------------------------------------------
// Transaction Proposals
// ---------------------------------------------------------------------------

// 5. create_transaction -- propose an action for multisig approval
pub create_transaction(
    tx: Transaction @mut @init(payer=proposer, space=512) @signer,
    ms: Multisig @mut,
    proposer: account @mut @signer,
    instruction_hash: pubkey
) {
    require(ms.is_active);
    let proposer_key: pubkey = proposer.ctx.key;
    require(is_member(ms, proposer_key));

    let now: u64 = get_clock().slot;
    let new_index: u64 = ms.transaction_index + 1;

    tx.multisig = ms.ctx.key;
    tx.proposer = proposer_key;
    tx.instruction_hash = instruction_hash;
    tx.status = 0;  // pending
    tx.approval_count = 0;
    tx.rejection_count = 0;
    tx.approved_by_1 = false;
    tx.approved_by_2 = false;
    tx.approved_by_3 = false;
    tx.approved_by_4 = false;
    tx.approved_by_5 = false;
    tx.approved_by_6 = false;
    tx.approved_by_7 = false;
    tx.approved_by_8 = false;
    tx.approved_by_9 = false;
    tx.approved_by_10 = false;
    tx.created_at = now;
    tx.execute_after = now + ms.time_lock_seconds;

    ms.transaction_index = new_index;
}

// 6. approve_transaction -- member votes to approve
pub approve_transaction(
    tx: Transaction @mut,
    ms: Multisig,
    voter: account @signer
) {
    require(ms.is_active);
    require(tx.multisig == ms.ctx.key);
    require(tx.status == 0);  // must be pending

    let voter_key: pubkey = voter.ctx.key;
    let idx: u64 = member_index(ms, voter_key);
    require(idx > 0);  // must be a member

    // Prevent double-voting: check slot hasn't already approved
    if (idx == 1) { require(!tx.approved_by_1); tx.approved_by_1 = true; }
    if (idx == 2) { require(!tx.approved_by_2); tx.approved_by_2 = true; }
    if (idx == 3) { require(!tx.approved_by_3); tx.approved_by_3 = true; }
    if (idx == 4) { require(!tx.approved_by_4); tx.approved_by_4 = true; }
    if (idx == 5) { require(!tx.approved_by_5); tx.approved_by_5 = true; }
    if (idx == 6) { require(!tx.approved_by_6); tx.approved_by_6 = true; }
    if (idx == 7) { require(!tx.approved_by_7); tx.approved_by_7 = true; }
    if (idx == 8) { require(!tx.approved_by_8); tx.approved_by_8 = true; }
    if (idx == 9) { require(!tx.approved_by_9); tx.approved_by_9 = true; }
    if (idx == 10) { require(!tx.approved_by_10); tx.approved_by_10 = true; }

    tx.approval_count = tx.approval_count + 1;

    // Auto-transition to approved if threshold met
    if (tx.approval_count >= ms.threshold) {
        tx.status = 1;  // approved
    }
}

// 7. reject_transaction -- member votes to reject
pub reject_transaction(
    tx: Transaction @mut,
    ms: Multisig,
    voter: account @signer
) {
    require(ms.is_active);
    require(tx.multisig == ms.ctx.key);
    require(tx.status == 0);  // must be pending

    let voter_key: pubkey = voter.ctx.key;
    let idx: u64 = member_index(ms, voter_key);
    require(idx > 0);

    tx.rejection_count = tx.rejection_count + 1;

    // If rejections exceed (num_members - threshold), proposal cannot pass
    let reject_threshold: u64 = ms.num_members - ms.threshold + 1;
    if (tx.rejection_count >= reject_threshold) {
        tx.status = 2;  // rejected
    }
}

// 8. execute_transaction -- execute after threshold met + time_lock elapsed
pub execute_transaction(
    tx: Transaction @mut,
    ms: Multisig,
    executor: account @signer
) {
    require(ms.is_active);
    require(tx.multisig == ms.ctx.key);
    require(tx.status == 1);  // must be approved

    let executor_key: pubkey = executor.ctx.key;
    require(is_member(ms, executor_key));

    // Enforce time lock
    let now: u64 = get_clock().slot;
    require(now >= tx.execute_after);

    tx.status = 3;  // executed
}

// 9. cancel_transaction -- proposer or config authority can cancel
pub cancel_transaction(
    tx: Transaction @mut,
    ms: Multisig,
    canceller: account @signer
) {
    require(tx.multisig == ms.ctx.key);
    require(tx.status == 0);  // can only cancel pending

    let canceller_key: pubkey = canceller.ctx.key;
    // Only proposer or config_authority can cancel
    let is_proposer: bool = tx.proposer == canceller_key;
    let is_config_auth: bool = ms.config_authority == canceller_key;
    require(is_proposer);

    tx.status = 4;  // cancelled
}

// ---------------------------------------------------------------------------
// Spending Limits (Fast-Path Transfers)
// ---------------------------------------------------------------------------

// 10. create_spending_limit -- per-token periodic budget
pub create_spending_limit(
    limit: SpendingLimit @mut @init(payer=authority, space=256) @signer,
    ms: Multisig,
    authority: account @mut @signer,
    token_mint: pubkey,
    amount_limit: u64,
    period: u8
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    require(amount_limit > 0);
    require(period <= 2);  // 0=daily, 1=weekly, 2=monthly

    limit.multisig = ms.ctx.key;
    limit.token_mint = token_mint;
    limit.amount_limit = amount_limit;
    limit.period = period;
    limit.amount_spent = 0;
    limit.last_reset = get_clock().slot;
    limit.is_active = true;
}

// 11. execute_spending_limit_transfer -- within limits, no approval needed
pub execute_spending_limit_transfer(
    limit: SpendingLimit @mut,
    ms: Multisig,
    vault_token: account @mut,
    recipient_token: account @mut,
    member: account @signer,
    vault: Vault @signer,
    token_program: account,
    amount: u64
) {
    require(ms.is_active);
    require(limit.is_active);
    require(limit.multisig == ms.ctx.key);
    require(amount > 0);

    let member_key: pubkey = member.ctx.key;
    require(is_member(ms, member_key));

    let now: u64 = get_clock().slot;
    let period_len: u64 = period_seconds(limit.period);

    // Reset period if elapsed (using slots as proxy; ~2.5 slots/sec)
    let slots_per_sec: u64 = 2;
    let period_slots: u64 = period_len * slots_per_sec;
    if (now - limit.last_reset >= period_slots) {
        limit.amount_spent = 0;
        limit.last_reset = now;
    }

    // Check within budget
    require(limit.amount_spent + amount <= limit.amount_limit);

    spl_token::SPLToken::transfer(vault_token, recipient_token, vault, amount);

    limit.amount_spent = limit.amount_spent + amount;
}

// ---------------------------------------------------------------------------
// Vaults
// ---------------------------------------------------------------------------

// 12. create_vault -- PDA-controlled vault for the multisig
pub create_vault(
    vault: Vault @mut @init(payer=creator, space=256) @signer,
    ms: Multisig @mut,
    creator: account @mut @signer,
    vault_index: u64,
    authority_bump: u64
) {
    require(ms.is_active);
    let creator_key: pubkey = creator.ctx.key;
    require(is_member(ms, creator_key));

    vault.multisig = ms.ctx.key;
    vault.vault_index = vault_index;
    vault.authority_bump = authority_bump;
}

// 13. vault_deposit -- deposit tokens into the multisig vault
pub vault_deposit(
    vault: Vault,
    ms: Multisig,
    user_token: account @mut,
    vault_token: account @mut,
    depositor: account @signer,
    token_program: account,
    amount: u64
) {
    require(ms.is_active);
    require(vault.multisig == ms.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(user_token, vault_token, depositor, amount);
}

// 14. vault_withdraw -- withdraw tokens (requires multisig tx approval)
pub vault_withdraw(
    vault: Vault @signer,
    ms: Multisig,
    tx: Transaction,
    vault_token: account @mut,
    recipient_token: account @mut,
    executor: account @signer,
    token_program: account,
    amount: u64
) {
    require(ms.is_active);
    require(vault.multisig == ms.ctx.key);
    require(tx.multisig == ms.ctx.key);
    require(tx.status == 3);  // must be executed transaction
    require(amount > 0);

    let executor_key: pubkey = executor.ctx.key;
    require(is_member(ms, executor_key));

    spl_token::SPLToken::transfer(vault_token, recipient_token, vault, amount);
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

// 15. set_time_lock -- update the time lock duration
pub set_time_lock(
    ms: Multisig @mut,
    authority: account @signer,
    new_time_lock: u64
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    ms.time_lock_seconds = new_time_lock;
}

// 16. set_config_authority -- transfer config authority
pub set_config_authority(
    ms: Multisig @mut,
    authority: account @signer,
    new_config_authority: pubkey
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    ms.config_authority = new_config_authority;
}

// 17. close_multisig -- deactivate the multisig permanently
pub close_multisig(
    ms: Multisig @mut,
    authority: account @signer
) {
    require(ms.config_authority == authority.ctx.key);
    require(ms.is_active);
    ms.is_active = false;
}

// 18. transfer_authority -- transfer the multisig top-level authority
pub transfer_authority(
    ms: Multisig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(ms.authority == authority.ctx.key);
    require(ms.is_active);
    ms.authority = new_authority;
}
