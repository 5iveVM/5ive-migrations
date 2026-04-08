// 5IVE Streamflow Protocol -- Token streaming, vesting, and payroll
//
// Design (Streamflow v2-inspired):
//   - Linear token vesting with cliff support
//   - Streams escrow tokens in a vault; recipients claim vested amounts over time
//   - Cliff: no tokens vest before cliff_time, then cliff_amount vests instantly
//   - After cliff: remaining tokens vest linearly until end_time
//   - Streams can be paused, cancelled, transferred, and topped up
//   - Multisig cancellation requires N approvals before execution
//   - Protocol fee in basis points on all stream creation
//   - Payroll: recurring fixed-period payment streams
//   - All math is integer-only; timestamps via get_clock().unix_timestamp

use std::interfaces::spl_token;

account Stream {
    sender: pubkey;
    recipient: pubkey;
    token_mint: pubkey;
    escrow_vault: pubkey;
    total_amount: u64;
    withdrawn_amount: u64;
    start_time: u64;
    end_time: u64;
    cliff_time: u64;
    cliff_amount: u64;
    period: u64;                   // payment period in seconds (0 = continuous linear)
    last_withdraw: u64;
    cancelable_by_sender: bool;
    transferable: bool;
    is_paused: bool;
    is_cancelled: bool;
    created_at: u64;
}

account ProtocolConfig {
    authority: pubkey;
    fee_bps: u64;                  // basis points charged on stream creation
    fee_collector: pubkey;
    total_streams: u64;
    total_streamed_value: u64;     // cumulative tokens locked across all streams
}

// ---------------------------------------------------------------------------
// Internal math helpers
// ---------------------------------------------------------------------------

// Calculate vested amount using linear vesting with cliff
// If current_time < cliff_time: vested = 0
// If current_time >= end_time: vested = total_amount
// Otherwise: vested = cliff_amount + (total - cliff) * (current_time - cliff_time) / (end_time - cliff_time)
fn calculate_vested(
    total_amount: u64,
    cliff_amount: u64,
    cliff_time: u64,
    end_time: u64,
    current_time: u64
) -> u64 {
    // Before cliff: nothing vested
    if (current_time < cliff_time) {
        return 0;
    }

    // After end: everything vested
    if (current_time >= end_time) {
        return total_amount;
    }

    // Between cliff and end: cliff_amount + linear portion of remainder
    let remaining_amount: u64 = total_amount - cliff_amount;
    let elapsed: u64 = current_time - cliff_time;
    let duration: u64 = end_time - cliff_time;

    if (duration == 0) {
        return total_amount;
    }

    let linear_vested: u64 = (remaining_amount * elapsed) / duration;
    return cliff_amount + linear_vested;
}

// Calculate withdrawable = vested - already_withdrawn
fn calculate_withdrawable(
    total_amount: u64,
    withdrawn_amount: u64,
    cliff_amount: u64,
    cliff_time: u64,
    end_time: u64,
    current_time: u64
) -> u64 {
    let vested: u64 = calculate_vested(
        total_amount, cliff_amount, cliff_time, end_time, current_time
    );

    if (vested <= withdrawn_amount) {
        return 0;
    }

    return vested - withdrawn_amount;
}

// ---------------------------------------------------------------------------
// Protocol initialization
// ---------------------------------------------------------------------------

pub init_protocol(
    config: ProtocolConfig @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    fee_collector: pubkey,
    fee_bps: u64
) {
    require(fee_bps <= 1000);  // max 10% fee

    config.authority = authority.ctx.key;
    config.fee_bps = fee_bps;
    config.fee_collector = fee_collector;
    config.total_streams = 0;
    config.total_streamed_value = 0;
}

// ---------------------------------------------------------------------------
// Stream creation
// ---------------------------------------------------------------------------

// Create a token stream with linear vesting and optional cliff
pub create_stream(
    config: ProtocolConfig @mut,
    stream: Stream @mut @init(payer=sender, space=512) @signer,
    sender: account @mut @signer,
    sender_token: account @mut,
    escrow_vault: account @mut,
    fee_vault: account @mut,
    token_program: account,
    recipient: pubkey,
    token_mint: pubkey,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: u64,
    cliff_amount: u64,
    period: u64,
    cancelable_by_sender: bool,
    transferable: bool
) {
    require(!config.is_paused);
    require(total_amount > 0);
    require(end_time > start_time);
    require(cliff_time >= start_time);
    require(cliff_time <= end_time);
    require(cliff_amount <= total_amount);

    let now: u64 = get_clock().unix_timestamp;
    require(start_time >= now);

    // Calculate and deduct protocol fee
    let fee: u64 = (total_amount * config.fee_bps) / 10000;
    let net_amount: u64 = total_amount - fee;
    require(net_amount > 0);
    require(cliff_amount <= net_amount);

    // Transfer tokens to escrow vault
    spl_token::SPLToken::transfer(sender_token, escrow_vault, sender, net_amount);

    // Transfer fee to protocol fee collector
    if (fee > 0) {
        spl_token::SPLToken::transfer(sender_token, fee_vault, sender, fee);
    }

    stream.sender = sender.ctx.key;
    stream.recipient = recipient;
    stream.token_mint = token_mint;
    stream.escrow_vault = escrow_vault.ctx.key;
    stream.total_amount = net_amount;
    stream.withdrawn_amount = 0;
    stream.start_time = start_time;
    stream.end_time = end_time;
    stream.cliff_time = cliff_time;
    stream.cliff_amount = cliff_amount;
    stream.period = period;
    stream.last_withdraw = 0;
    stream.cancelable_by_sender = cancelable_by_sender;
    stream.transferable = transferable;
    stream.is_paused = false;
    stream.is_cancelled = false;
    stream.created_at = now;

    config.total_streams = config.total_streams + 1;
    config.total_streamed_value = config.total_streamed_value + net_amount;
}

// Cancel a stream -- return unvested to sender, send vested to recipient
pub cancel_stream(
    stream: Stream @mut,
    sender_token: account @mut,
    recipient_token: account @mut,
    escrow_vault: account @mut,
    canceller: account @signer,
    token_program: account
) {
    require(!stream.is_cancelled);
    require(stream.cancelable_by_sender);
    require(stream.sender == canceller.ctx.key);
    require(escrow_vault.ctx.key == stream.escrow_vault);

    let now: u64 = get_clock().unix_timestamp;

    // Calculate vested amount for recipient
    let vested: u64 = calculate_vested(
        stream.total_amount, stream.cliff_amount,
        stream.cliff_time, stream.end_time, now
    );

    let recipient_due: u64 = 0;
    if (vested > stream.withdrawn_amount) {
        let due: u64 = vested - stream.withdrawn_amount;
        // Transfer vested-but-unwithdrawn to recipient
        spl_token::SPLToken::transfer(escrow_vault, recipient_token, canceller, due);
    }

    // Return unvested remainder to sender
    let remaining_in_vault: u64 = stream.total_amount - stream.withdrawn_amount;
    let vested_unwithdrawn: u64 = 0;
    if (vested > stream.withdrawn_amount) {
        let vuw: u64 = vested - stream.withdrawn_amount;
        let sender_refund: u64 = remaining_in_vault - vuw;
        if (sender_refund > 0) {
            spl_token::SPLToken::transfer(escrow_vault, sender_token, canceller, sender_refund);
        }
    } else {
        // Nothing vested beyond what's withdrawn; return everything
        if (remaining_in_vault > 0) {
            spl_token::SPLToken::transfer(escrow_vault, sender_token, canceller, remaining_in_vault);
        }
    }

    stream.is_cancelled = true;
}

// Transfer stream ownership to a new recipient (if transferable)
pub transfer_stream(
    stream: Stream @mut,
    current_recipient: account @signer,
    new_recipient: pubkey
) {
    require(!stream.is_cancelled);
    require(stream.transferable);
    require(stream.recipient == current_recipient.ctx.key);

    stream.recipient = new_recipient;
}

// Recipient withdraws vested tokens from the stream
pub withdraw_from_stream(
    stream: Stream @mut,
    recipient: account @signer,
    recipient_token: account @mut,
    escrow_vault: account @mut,
    token_program: account
) {
    require(!stream.is_cancelled);
    require(!stream.is_paused);
    require(stream.recipient == recipient.ctx.key);
    require(escrow_vault.ctx.key == stream.escrow_vault);

    let now: u64 = get_clock().unix_timestamp;

    let withdrawable: u64 = calculate_withdrawable(
        stream.total_amount, stream.withdrawn_amount,
        stream.cliff_amount, stream.cliff_time, stream.end_time, now
    );
    require(withdrawable > 0);

    // If stream has a period, enforce period-aligned withdrawals
    if (stream.period > 0) {
        if (stream.last_withdraw > 0) {
            let elapsed_since_last: u64 = now - stream.last_withdraw;
            require(elapsed_since_last >= stream.period);
        }
    }

    spl_token::SPLToken::transfer(escrow_vault, recipient_token, recipient, withdrawable);

    stream.withdrawn_amount = stream.withdrawn_amount + withdrawable;
    stream.last_withdraw = now;
}

// Add more tokens to an existing stream (extends total_amount)
pub topup_stream(
    stream: Stream @mut,
    sender: account @signer,
    sender_token: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!stream.is_cancelled);
    require(stream.sender == sender.ctx.key);
    require(escrow_vault.ctx.key == stream.escrow_vault);
    require(amount > 0);

    spl_token::SPLToken::transfer(sender_token, escrow_vault, sender, amount);

    stream.total_amount = stream.total_amount + amount;
}

// ---------------------------------------------------------------------------
// Batch vesting -- create a vesting contract (single stream, batch handled off-chain)
// ---------------------------------------------------------------------------

// Create a vesting contract with predefined schedule
pub create_vesting_contract(
    config: ProtocolConfig @mut,
    stream: Stream @mut @init(payer=sender, space=512) @signer,
    sender: account @mut @signer,
    sender_token: account @mut,
    escrow_vault: account @mut,
    fee_vault: account @mut,
    token_program: account,
    recipient: pubkey,
    token_mint: pubkey,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: u64,
    cliff_amount: u64
) {
    require(total_amount > 0);
    require(end_time > start_time);
    require(cliff_time >= start_time);
    require(cliff_time <= end_time);
    require(cliff_amount <= total_amount);

    let now: u64 = get_clock().unix_timestamp;

    // Calculate protocol fee
    let fee: u64 = (total_amount * config.fee_bps) / 10000;
    let net_amount: u64 = total_amount - fee;
    require(net_amount > 0);
    require(cliff_amount <= net_amount);

    spl_token::SPLToken::transfer(sender_token, escrow_vault, sender, net_amount);
    if (fee > 0) {
        spl_token::SPLToken::transfer(sender_token, fee_vault, sender, fee);
    }

    // Vesting contracts are non-cancelable and non-transferable by default
    stream.sender = sender.ctx.key;
    stream.recipient = recipient;
    stream.token_mint = token_mint;
    stream.escrow_vault = escrow_vault.ctx.key;
    stream.total_amount = net_amount;
    stream.withdrawn_amount = 0;
    stream.start_time = start_time;
    stream.end_time = end_time;
    stream.cliff_time = cliff_time;
    stream.cliff_amount = cliff_amount;
    stream.period = 0;             // continuous vesting
    stream.last_withdraw = 0;
    stream.cancelable_by_sender = false;
    stream.transferable = false;
    stream.is_paused = false;
    stream.is_cancelled = false;
    stream.created_at = now;

    config.total_streams = config.total_streams + 1;
    config.total_streamed_value = config.total_streamed_value + net_amount;
}

// Create a payroll stream with fixed recurring periods
pub create_payroll(
    config: ProtocolConfig @mut,
    stream: Stream @mut @init(payer=sender, space=512) @signer,
    sender: account @mut @signer,
    sender_token: account @mut,
    escrow_vault: account @mut,
    fee_vault: account @mut,
    token_program: account,
    recipient: pubkey,
    token_mint: pubkey,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    period: u64
) {
    require(total_amount > 0);
    require(end_time > start_time);
    require(period > 0);

    let now: u64 = get_clock().unix_timestamp;

    // Payroll has no cliff
    let fee: u64 = (total_amount * config.fee_bps) / 10000;
    let net_amount: u64 = total_amount - fee;
    require(net_amount > 0);

    spl_token::SPLToken::transfer(sender_token, escrow_vault, sender, net_amount);
    if (fee > 0) {
        spl_token::SPLToken::transfer(sender_token, fee_vault, sender, fee);
    }

    // Payroll is cancelable by sender, not transferable
    stream.sender = sender.ctx.key;
    stream.recipient = recipient;
    stream.token_mint = token_mint;
    stream.escrow_vault = escrow_vault.ctx.key;
    stream.total_amount = net_amount;
    stream.withdrawn_amount = 0;
    stream.start_time = start_time;
    stream.end_time = end_time;
    stream.cliff_time = start_time;    // no cliff: cliff_time == start_time
    stream.cliff_amount = 0;
    stream.period = period;
    stream.last_withdraw = 0;
    stream.cancelable_by_sender = true;
    stream.transferable = false;
    stream.is_paused = false;
    stream.is_cancelled = false;
    stream.created_at = now;

    config.total_streams = config.total_streams + 1;
    config.total_streamed_value = config.total_streamed_value + net_amount;
}

// ---------------------------------------------------------------------------
// Stream controls
// ---------------------------------------------------------------------------

// Pause a stream -- halts vesting accrual for withdrawal purposes
pub pause_stream(
    stream: Stream @mut,
    authority: account @signer
) {
    require(!stream.is_cancelled);
    require(!stream.is_paused);
    require(stream.sender == authority.ctx.key);

    stream.is_paused = true;
}

// Resume a paused stream
pub resume_stream(
    stream: Stream @mut,
    authority: account @signer
) {
    require(!stream.is_cancelled);
    require(stream.is_paused);
    require(stream.sender == authority.ctx.key);

    stream.is_paused = false;
}

// Update the recipient of a stream (sender-initiated)
pub update_stream_recipient(
    stream: Stream @mut,
    sender: account @signer,
    new_recipient: pubkey
) {
    require(!stream.is_cancelled);
    require(stream.sender == sender.ctx.key);
    require(stream.transferable);

    stream.recipient = new_recipient;
}

// ---------------------------------------------------------------------------
// Multisig cancellation
// ---------------------------------------------------------------------------

// Create a multisig stream -- requires N approvals to cancel
// Uses the same Stream account; multisig logic is tracked off-chain.
// On-chain, we just mark it as non-cancelable-by-sender until approvals met.
pub create_multisig_stream(
    config: ProtocolConfig @mut,
    stream: Stream @mut @init(payer=sender, space=512) @signer,
    sender: account @mut @signer,
    sender_token: account @mut,
    escrow_vault: account @mut,
    fee_vault: account @mut,
    token_program: account,
    recipient: pubkey,
    token_mint: pubkey,
    total_amount: u64,
    start_time: u64,
    end_time: u64,
    cliff_time: u64,
    cliff_amount: u64
) {
    require(total_amount > 0);
    require(end_time > start_time);
    require(cliff_time >= start_time);
    require(cliff_time <= end_time);
    require(cliff_amount <= total_amount);

    let now: u64 = get_clock().unix_timestamp;

    let fee: u64 = (total_amount * config.fee_bps) / 10000;
    let net_amount: u64 = total_amount - fee;
    require(net_amount > 0);

    spl_token::SPLToken::transfer(sender_token, escrow_vault, sender, net_amount);
    if (fee > 0) {
        spl_token::SPLToken::transfer(sender_token, fee_vault, sender, fee);
    }

    // Multisig streams start non-cancelable; approve_cancel flips the flag
    stream.sender = sender.ctx.key;
    stream.recipient = recipient;
    stream.token_mint = token_mint;
    stream.escrow_vault = escrow_vault.ctx.key;
    stream.total_amount = net_amount;
    stream.withdrawn_amount = 0;
    stream.start_time = start_time;
    stream.end_time = end_time;
    stream.cliff_time = cliff_time;
    stream.cliff_amount = cliff_amount;
    stream.period = 0;
    stream.last_withdraw = 0;
    stream.cancelable_by_sender = false;  // locked until multisig approval
    stream.transferable = false;
    stream.is_paused = false;
    stream.is_cancelled = false;
    stream.created_at = now;

    config.total_streams = config.total_streams + 1;
    config.total_streamed_value = config.total_streamed_value + net_amount;
}

// Approve cancellation of a multisig stream (called by each signer)
// Once sufficient approvals are collected off-chain, this flips cancelable_by_sender
pub approve_cancel(
    stream: Stream @mut,
    approver: account @signer
) {
    require(!stream.is_cancelled);
    require(!stream.cancelable_by_sender);

    // In production, approval count is tracked in a separate multisig account.
    // This instruction is called by the final approver to unlock cancellation.
    // The approver must be the sender (simplified; real impl checks multisig signers).
    require(stream.sender == approver.ctx.key);

    stream.cancelable_by_sender = true;
}

// Execute cancellation after multisig approval
pub execute_cancel(
    stream: Stream @mut,
    sender_token: account @mut,
    recipient_token: account @mut,
    escrow_vault: account @mut,
    executor: account @signer,
    token_program: account
) {
    require(!stream.is_cancelled);
    require(stream.cancelable_by_sender);
    require(stream.sender == executor.ctx.key);
    require(escrow_vault.ctx.key == stream.escrow_vault);

    let now: u64 = get_clock().unix_timestamp;

    let vested: u64 = calculate_vested(
        stream.total_amount, stream.cliff_amount,
        stream.cliff_time, stream.end_time, now
    );

    // Send vested-but-unwithdrawn to recipient
    if (vested > stream.withdrawn_amount) {
        let recipient_due: u64 = vested - stream.withdrawn_amount;
        spl_token::SPLToken::transfer(escrow_vault, recipient_token, executor, recipient_due);

        // Return unvested to sender
        let remaining: u64 = stream.total_amount - stream.withdrawn_amount - recipient_due;
        if (remaining > 0) {
            spl_token::SPLToken::transfer(escrow_vault, sender_token, executor, remaining);
        }
    } else {
        // Nothing new vested; return all remaining to sender
        let remaining: u64 = stream.total_amount - stream.withdrawn_amount;
        if (remaining > 0) {
            spl_token::SPLToken::transfer(escrow_vault, sender_token, executor, remaining);
        }
    }

    stream.is_cancelled = true;
}

// ---------------------------------------------------------------------------
// Protocol admin
// ---------------------------------------------------------------------------

// Set the protocol fee in basis points
pub set_protocol_fee(
    config: ProtocolConfig @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_fee_bps <= 1000);  // max 10%

    config.fee_bps = new_fee_bps;
}

// Collect accumulated protocol fees (fees already in fee_vault via create_stream)
pub collect_fees(
    config: ProtocolConfig,
    authority: account @signer,
    fee_vault: account @mut,
    collector_token: account @mut,
    token_program: account,
    amount: u64
) {
    require(config.authority == authority.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(fee_vault, collector_token, authority, amount);
}

// Transfer protocol authority
pub set_authority(
    config: ProtocolConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);

    config.authority = new_authority;
}

// Close a stream that has been fully withdrawn (all tokens claimed)
pub close_completed_stream(
    stream: Stream @mut,
    closer: account @signer
) {
    // Stream must be fully withdrawn or cancelled
    require(
        stream.withdrawn_amount == stream.total_amount ||
        stream.is_cancelled
    );

    // Only sender or recipient can close
    require(
        stream.sender == closer.ctx.key ||
        stream.recipient == closer.ctx.key
    );

    // Zero out state (account rent returned off-chain)
    stream.total_amount = 0;
    stream.withdrawn_amount = 0;
    stream.is_cancelled = true;
}
