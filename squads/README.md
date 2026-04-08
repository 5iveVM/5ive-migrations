# 5ive-squads: Squads Multisig Protocol Migration

A complete 5ive DSL migration of Squads -- Solana's multisig protocol for DAOs and teams with spending limits and time-locked transactions.

## What This Implements

Squads provides shared custody of on-chain assets through M-of-N multisig approval. Teams propose transactions, members vote, and execution happens after threshold + time-lock conditions are met. Spending limits enable fast-path transfers for operational efficiency.

### Key Innovation -- Team-First Multisig with Spending Limits

Unlike personal wallets (e.g., Mercl with owner + guardians), Squads is designed for teams:
- Up to 10 equal members with configurable M-of-N threshold
- Time-lock on execution prevents rushed approvals
- Spending limits allow per-token daily/weekly/monthly budgets without full approval
- PDA-controlled vaults for secure asset custody
- Transaction lifecycle: propose -> approve/reject -> execute/cancel
- Config authority enables operational changes without full proposals

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Multisig** | Core config: 10 member slots, threshold, time lock, config authority | 1024 |
| **Transaction** | Proposed action: instruction hash, votes (10 bool slots), status, time lock | 512 |
| **SpendingLimit** | Per-token periodic budget: amount, period, spent tracking | 256 |
| **Vault** | PDA-controlled token vault owned by the multisig | 256 |

### Instructions (18 total)

**Multisig Lifecycle:**
1. `create_multisig` -- Create multisig with initial members, threshold, time lock
2. `add_member` -- Add a new member (up to 10)
3. `remove_member` -- Remove member (threshold auto-adjusts if needed)
4. `change_threshold` -- Update approval threshold

**Transaction Proposals:**
5. `create_transaction` -- Propose an action (members only)
6. `approve_transaction` -- Member votes to approve (auto-transitions at threshold)
7. `reject_transaction` -- Member votes to reject (auto-rejects if threshold impossible)
8. `execute_transaction` -- Execute after threshold met + time lock elapsed
9. `cancel_transaction` -- Proposer or config authority cancels pending transaction

**Spending Limits (Fast-Path):**
10. `create_spending_limit` -- Per-token periodic budget (daily/weekly/monthly)
11. `execute_spending_limit_transfer` -- Transfer within budget, no approval needed

**Vaults:**
12. `create_vault` -- Create PDA-controlled vault for the multisig
13. `vault_deposit` -- Deposit tokens into vault (anyone can deposit)
14. `vault_withdraw` -- Withdraw tokens (requires executed multisig transaction)

**Configuration:**
15. `set_time_lock` -- Update time lock duration
16. `set_config_authority` -- Transfer config authority
17. `close_multisig` -- Permanently deactivate the multisig
18. `transfer_authority` -- Transfer top-level authority

## Transaction Status Model

| Status | Value | Meaning |
|--------|-------|---------|
| Pending | 0 | Awaiting votes |
| Approved | 1 | Threshold met, ready to execute after time lock |
| Rejected | 2 | Too many rejections, proposal cannot pass |
| Executed | 3 | Successfully executed |
| Cancelled | 4 | Cancelled by proposer or config authority |

## Spending Limit Periods

| Period | Value | Duration |
|--------|-------|----------|
| Daily | 0 | 86,400 seconds |
| Weekly | 1 | 604,800 seconds |
| Monthly | 2 | 2,592,000 seconds |

## Squads vs Mercl (Personal Wallet)

| Feature | Squads | Mercl |
|---------|--------|-------|
| Focus | DAO / Team | Personal |
| Members | Up to 10 equal | Owner + guardians |
| Approval | M-of-N threshold | Owner signs |
| Spending limits | Yes (operational) | No |
| Time lock | On transactions | On recovery |
| Recovery | N/A (threshold) | Social recovery |

## Original Protocol

- **Chain**: Solana
- **Category**: Multisig / DAO Tooling
- **Reference**: [squads.so](https://squads.so/)
