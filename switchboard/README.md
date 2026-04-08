# 5ive-switchboard: Switchboard Oracle Network Migration

A complete 5ive DSL migration of Switchboard -- Solana's decentralized oracle network with permissionless data feeds and economic security via staking.

## What This Implements

Switchboard is a decentralized oracle protocol where data feeds are composed of jobs (HTTP fetch + JSON parse), served by staked oracle nodes. The protocol uses economic incentives (staking, slashing, rewards) to ensure data accuracy.

### Key Innovation -- Permissionless Oracle Network

Unlike centralized oracles, Switchboard is fully permissionless:
- Anyone can create data feeds (aggregators) with custom job definitions
- Oracle nodes stake tokens as economic bond against bad data
- Rounds collect multiple oracle submissions; result is median/mean
- Variance threshold prevents anomalous data from being accepted
- Leases fund feeds with SOL; oracles are paid per round
- Permission system controls which oracles serve which queues
- Slashing penalizes oracles that submit outlier data

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **OracleQueue** | Oracle group config: timeout, rewards, min stake, slashing | 256 |
| **Oracle** | Node registration: stake, heartbeat, rewards, active status | 256 |
| **Aggregator** | Data feed: min oracles, batch size, update delay, latest result (i64) | 512 |
| **Round** | Per-round submission collector: sum (i64), count, open/closed | 256 |
| **Job** | Data fetch definition: hash of endpoint + parse path | 256 |
| **Lease** | Escrow funding oracle payments for a specific feed | 256 |
| **Permission** | Authorization bitmask for oracle-to-queue assignment | 256 |

### Instructions (22 total)

**Queue Management:**
1. `create_queue` -- Initialize oracle queue with timeout, reward, stake, slashing config
16. `set_queue_config` -- Update queue parameters

**Oracle Lifecycle:**
2. `create_oracle` -- Register oracle node for a queue
3. `oracle_heartbeat` -- Oracle proves liveness
19. `stake_oracle` -- Oracle stakes tokens as economic bond
20. `unstake_oracle` -- Oracle withdraws stake (deactivates if below minimum)
21. `slash_oracle` -- Penalize oracle for submitting bad data
22. `collect_oracle_rewards` -- Oracle withdraws accumulated rewards

**Aggregator (Data Feed):**
4. `create_aggregator` -- Create data feed with min oracles, batch size, delay, variance
9. `set_aggregator_config` -- Update feed parameters
12. `set_aggregator_authority` -- Transfer feed ownership

**Jobs:**
8. `create_job` -- Define data fetch job (hash of HTTP endpoint + parse path)
10. `add_job_to_aggregator` -- Activate an existing job for a feed
11. `remove_job` -- Deactivate a job from a feed

**Rounds (Data Collection):**
5. `open_round` -- Request new data from oracles (enforces min update delay)
6. `save_result` -- Oracle submits signed result (i64) for an open round
7. `close_round` -- Finalize round: compute result, apply variance check

**Leases (Feed Funding):**
13. `create_lease` -- Fund a feed with tokens for oracle payments
14. `extend_lease` -- Add more funds to existing lease
15. `withdraw_lease` -- Withdraw unused funds from lease

**Permissions:**
17. `create_permission` -- Authorize oracle for a queue (bitmask)
18. `set_permission` -- Update permission bitmask

## Data Flow

1. Feed creator creates aggregator + jobs + lease
2. Oracle nodes register, stake, and heartbeat
3. Anyone calls `open_round` to request fresh data
4. Oracles fetch job data, call `save_result` with signed i64 values
5. After min_oracle_results submissions, anyone calls `close_round`
6. Protocol computes mean, checks variance, updates `latest_result`
7. Oracles accumulate rewards; bad actors get slashed

## Original Protocol

- **Chain**: Solana
- **Category**: Oracle Network / Infrastructure
- **Reference**: [switchboard.xyz](https://switchboard.xyz/)
