# 5ive-clockwork: Clockwork Protocol Migration

A complete 5ive DSL migration of Clockwork -- on-chain automation engine for Solana (cron jobs for the blockchain).

## What This Implements

Clockwork enables recurring on-chain transactions by letting users schedule threads that keepers execute at specified intervals. Threads hold SOL to pay for execution gas and keeper fees. The protocol supports cron-based schedules, slot triggers, epoch triggers, and webhook callbacks.

### Key Innovation -- On-Chain Cron

Unlike off-chain automation (bots, scripts), Clockwork threads are fully on-chain:
- Threads define a target program + instruction data + trigger schedule
- Keepers compete to execute due threads and earn per-execution fees
- Thread balance is decremented each execution; refills via `fund_thread`
- Trigger types: cron expressions (hashed on-chain), slot-based, epoch-based, and webhook

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Thread** | Scheduled automation: trigger, target, balance, execution state | 512 |
| **Webhook** | HTTP callback trigger configuration for webhook-type threads | 256 |
| **ProtocolConfig** | Global config: base fee, total counters, pause state | 512 |

### Instructions (16 total)

**Thread Lifecycle:**
1. `create_thread` -- Schedule a recurring on-chain action with trigger type and target program
2. `delete_thread` -- Remove a thread (authority only)
3. `pause_thread` -- Pause a running thread
4. `resume_thread` -- Resume a paused thread
5. `update_thread` -- Change schedule, target, instruction data, or fee
6. `fund_thread` -- Deposit SOL to pay for future executions
7. `withdraw_from_thread` -- Withdraw excess SOL (must leave at least one execution funded)

**Execution:**
8. `execute_thread` -- Keeper executes a due thread, earns fee (protocol takes base_fee)

**Webhooks:**
9. `create_webhook` -- Create HTTP callback trigger for webhook-type threads
10. `update_webhook` -- Update webhook URL or method

**Cron:**
11. `create_cron_trigger` -- Set cron-based schedule with first execution time

**Authority:**
12. `set_thread_authority` -- Transfer thread ownership

**Admin:**
13. `set_fee_rate` -- Update per-execution protocol fee
14. `collect_fees` -- Collect accumulated protocol fees
15. `set_authority` -- Transfer protocol admin
16. `pause_protocol` / `unpause_protocol` -- Emergency controls

## Key Design Decisions

### Keeper Economics

Keepers are permissionless -- anyone can execute due threads:
- Thread creator sets `fee_per_execution` (must be >= protocol `base_fee`)
- On execution: protocol takes `base_fee`, keeper earns the remainder
- Higher keeper fees incentivize faster execution during congestion
- Threads must maintain a balance >= one fee to be executable

### Trigger Types

| Type | Value | Description |
|------|-------|-------------|
| Cron | 0 | Time-based schedule (cron expression hashed on-chain) |
| Slot | 1 | Execute at specific Solana slot numbers |
| Epoch | 2 | Execute at epoch boundaries |
| Webhook | 3 | Triggered by HTTP callback from off-chain |

### Cron Schedule Storage

Cron expressions are hashed and stored as `cron_schedule_hash` (pubkey). The full expression lives off-chain. The `next_execution` timestamp is computed off-chain from the cron expression and committed on-chain. Keepers verify the timestamp matches the cron schedule.

### Safety

- Threads can only be deleted/updated by their authority
- Withdrawal requires at least one execution fee to remain funded
- Protocol pause halts all new thread creation and execution
- Thread pause is independent of protocol pause

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
clockwork/
  src/
    main.v           -- Complete Clockwork migration
```

## Source Protocol

- [Clockwork](https://github.com/clockwork-xyz/clockwork) -- Rust/Anchor
- This migration faithfully represents the thread scheduling, keeper execution, and fee economics
