# Mercl Smart Wallet Protocol

A 5ive DSL migration of the Mercl smart wallet protocol -- multi-signature wallet infrastructure with session keys, spending limits, time-locked transactions, and social recovery.

## Overview

Mercl provides programmable wallet security for on-chain assets. Instead of a single private key controlling all funds, Mercl wallets use a guardian-based multisig model where transactions require approval from a configurable quorum of trusted parties.

## Architecture

### Accounts

| Account | Description |
|---------|-------------|
| **SmartWallet** | Core wallet state: owner, up to 5 guardians, threshold, spending limits, time-lock config, pause state |
| **Transaction** | Proposed transaction awaiting approval: recipient, amount, data hash, approval/rejection counts, status, time-lock |
| **SessionKey** | Temporary key with scoped spending limit and expiry for dApp interactions |
| **RecoveryRequest** | Guardian-initiated recovery proposal: new owner, confirmation count, time-lock |

### Transaction Status Codes

- `0` -- Pending (awaiting approvals)
- `1` -- Approved (threshold met, awaiting execution)
- `2` -- Executed
- `3` -- Rejected
- `4` -- Cancelled

## Instructions (20)

### Wallet Lifecycle
1. `create_wallet` -- Create a smart wallet with owner, guardians, threshold, and limits
2. `add_guardian` -- Add a recovery guardian (max 5)
3. `remove_guardian` -- Remove a guardian by index
4. `set_threshold` -- Change the multisig approval threshold

### Transaction Flow
5. `propose_transaction` -- Propose a transaction (recipient, amount, data_hash)
6. `approve_transaction` -- Guardian approves a pending transaction
7. `execute_transaction` -- Execute once threshold met and time-lock elapsed
8. `reject_transaction` -- Guardian rejects a pending transaction

### Session Keys
9. `create_session_key` -- Create a temporary session key with spending limit and expiry
10. `revoke_session_key` -- Revoke an active session key
11. `execute_with_session_key` -- Execute a transfer using a session key (within limits)

### Spending Limits and Time-Lock
12. `set_spending_limit` -- Set daily spending limit for the wallet
13. `set_time_lock` -- Configure time-lock duration and threshold amount

### Social Recovery
14. `initiate_recovery` -- Guardian initiates wallet recovery with proposed new owner
15. `confirm_recovery` -- Additional guardians confirm the recovery
16. `execute_recovery` -- Execute recovery after threshold + time-lock
17. `cancel_recovery` -- Owner cancels a pending recovery

### Ownership and Admin
18. `transfer_ownership` -- Direct ownership transfer
19. `set_paused` -- Pause or unpause the wallet
20. `upgrade_wallet` -- Batch update wallet configuration

## Security Model

- **Multisig**: All transactions require `threshold`-of-`num_guardians` approvals
- **Time-lock**: Transactions above `time_lock_threshold` are delayed by `time_lock_duration` slots
- **Daily limits**: Wallet enforces a rolling daily spending cap (resets every ~216000 slots)
- **Session keys**: Scoped keys for dApp interactions without exposing the owner key
- **Social recovery**: Guardians can recover ownership if the owner loses access, subject to threshold + time-lock
- **Emergency pause**: Owner can freeze all wallet operations instantly

## Build

```bash
5ive build mercl/src/main.v
```
