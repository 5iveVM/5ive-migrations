# 5ive-streamflow: Streamflow Protocol Migration

A complete 5ive DSL migration of Streamflow -- token streaming, vesting, and payroll on Solana.

## What This Implements

Streamflow enables continuous token distribution through time-locked streams. Tokens are escrowed in vaults and vest linearly with optional cliff periods. Used for employee vesting, investor lockups, payroll, and DAO token distribution.

### Key Innovation -- Linear Vesting with Cliff

Streamflow implements a precise vesting formula:
- Before cliff: nothing vested (vested = 0)
- At cliff: cliff_amount vests instantly
- After cliff to end: remaining tokens vest linearly
- Formula: `vested = cliff_amount + (total - cliff) * (current_time - cliff_time) / (end_time - cliff_time)`
- Withdrawable = vested - already_withdrawn

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Stream** | Token stream: sender, recipient, amounts, schedule, status | 512 |
| **ProtocolConfig** | Global config: fee rate, total counters | 512 |

### Instructions (18 total)

**Stream Creation:**
1. `create_stream` -- Create a token stream with linear vesting, cliff, and period
2. `create_vesting_contract` -- Non-cancelable, non-transferable vesting schedule
3. `create_payroll` -- Recurring fixed-period payment stream
4. `create_multisig_stream` -- Stream requiring N approvals to cancel

**Stream Operations:**
5. `cancel_stream` -- Cancel: return unvested to sender, send vested to recipient
6. `transfer_stream` -- Recipient transfers stream to new address
7. `withdraw_from_stream` -- Recipient claims vested tokens
8. `topup_stream` -- Add more tokens to an existing stream
9. `pause_stream` -- Halt vesting accrual
10. `resume_stream` -- Resume paused stream
11. `update_stream_recipient` -- Sender changes recipient (if transferable)

**Multisig Cancellation:**
12. `approve_cancel` -- Approve multisig cancellation (final approver unlocks)
13. `execute_cancel` -- Execute cancellation after multisig approval

**Admin:**
14. `set_protocol_fee` -- Update fee in basis points
15. `collect_fees` -- Collect accumulated protocol fees
16. `set_authority` -- Transfer protocol admin

**Cleanup:**
17. `close_completed_stream` -- Close fully withdrawn or cancelled stream

## Key Design Decisions

### Vesting Math (Integer-Only)

All vesting calculations use integer arithmetic:
```
if current_time < cliff_time:
    vested = 0
elif current_time >= end_time:
    vested = total_amount
else:
    remaining = total_amount - cliff_amount
    elapsed = current_time - cliff_time
    duration = end_time - cliff_time
    vested = cliff_amount + (remaining * elapsed) / duration
```

Division truncates (floor), so the last token is only withdrawable at or after end_time.

### Stream Types

| Type | Cancelable | Transferable | Cliff | Period |
|------|-----------|-------------|-------|--------|
| Standard Stream | Configurable | Configurable | Optional | Optional |
| Vesting Contract | No | No | Required | Continuous |
| Payroll | Yes | No | None | Required |
| Multisig Stream | Requires N approvals | No | Optional | Continuous |

### Fee Model

- Protocol fee charged in basis points on stream creation (max 10%)
- Fee deducted from total_amount before escrow
- Recipient receives stream over the net amount
- Fees transferred to protocol fee_vault on creation

### Period-Aligned Withdrawals

When `period > 0`, withdrawals enforce minimum time between claims:
- `elapsed_since_last_withdraw >= period` must hold
- Prevents micro-withdrawals on payroll streams
- Period = 0 means continuous (withdraw anytime)

### Cancellation Safety

- Only sender can cancel (if cancelable_by_sender is true)
- On cancel: vested-but-unwithdrawn goes to recipient, unvested returns to sender
- Multisig streams require approve_cancel before execute_cancel
- Non-cancelable streams (vesting contracts) cannot be cancelled at all

## Building

```bash
npm run build
```

## Testing

```bash
npm test
```

## Project Structure

```
streamflow/
  src/
    main.v           -- Complete Streamflow migration
```

## Source Protocol

- [Streamflow](https://github.com/streamflow-finance/js-sdk) -- Rust/Anchor
- This migration faithfully represents linear vesting, cliff mechanics, payroll, and multisig cancellation
