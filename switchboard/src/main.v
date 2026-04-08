// 5IVE Switchboard Protocol -- Decentralized Oracle Network Migration
//
// Switchboard is a permissionless oracle network on Solana. Data feeds (aggregators)
// are composed of jobs (HTTP fetch + JSON parse). Oracles stake tokens as bond,
// submit results each round, and the protocol computes the median. Bad data gets
// slashed; good data gets rewarded. Leases fund feeds with SOL for oracle payments.
//
// Design:
//   - OracleQueue: configurable group of oracles with reward/slashing params
//   - Oracle: node that stakes, heartbeats, and submits data
//   - Aggregator: data feed that requests rounds from assigned oracles
//   - Round: collects oracle submissions and finalizes via median
//   - Job: defines what data to fetch (hash of HTTP endpoint + parse path)
//   - Lease: escrow funding oracle payments for a specific aggregator
//   - Permission: explicit authorization for oracle-to-queue assignment
//   - All math integer-only; i64 for signed price data, u64 for confidence

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account OracleQueue {
    authority: pubkey;
    oracle_timeout: u64;       // slots before oracle considered dead
    reward_per_round: u64;     // lamports paid to each oracle per round
    min_stake: u64;            // minimum stake to join queue
    slashing_enabled: bool;
    num_oracles: u64;
}

account Oracle {
    queue: pubkey;
    authority: pubkey;
    stake_amount: u64;
    last_heartbeat: u64;       // slot of last heartbeat
    total_rewards: u64;
    is_active: bool;
}

account Aggregator {
    queue: pubkey;
    authority: pubkey;
    min_oracle_results: u64;   // minimum submissions to close a round
    batch_size: u64;           // oracles requested per round
    min_update_delay: u64;     // minimum slots between rounds
    variance_threshold: u64;   // max allowed deviation (scaled by 10000)
    current_round_id: u64;
    latest_result: i64;        // signed price result
    latest_confidence: u64;    // unsigned confidence interval
    latest_timestamp: u64;
    num_jobs: u64;
}

account Round {
    aggregator: pubkey;
    round_id: u64;
    num_submissions: u64;
    result_sum: i64;           // signed sum of all submissions
    result_count: u64;
    is_open: bool;
    opened_at: u64;
}

account Job {
    aggregator: pubkey;
    hash: pubkey;              // hash of the job definition (endpoint + parse path)
    is_active: bool;
}

account Lease {
    aggregator: pubkey;
    funder: pubkey;
    balance: u64;
    withdraw_authority: pubkey;
}

account Permission {
    granter: pubkey;           // queue authority
    grantee: pubkey;           // oracle pubkey
    permissions_bitmask: u64;  // bit 0 = heartbeat, bit 1 = submit, etc.
}

// ---------------------------------------------------------------------------
// Queue Management
// ---------------------------------------------------------------------------

// 1. create_queue -- initialize an oracle queue with configuration
pub create_queue(
    queue: OracleQueue @mut @init(payer=creator, space=256) @signer,
    creator: account @mut @signer,
    oracle_timeout: u64,
    reward_per_round: u64,
    min_stake: u64,
    slashing_enabled: bool
) {
    require(oracle_timeout > 0);
    require(reward_per_round > 0);

    queue.authority = creator.ctx.key;
    queue.oracle_timeout = oracle_timeout;
    queue.reward_per_round = reward_per_round;
    queue.min_stake = min_stake;
    queue.slashing_enabled = slashing_enabled;
    queue.num_oracles = 0;
}

// 16. set_queue_config -- update queue parameters
pub set_queue_config(
    queue: OracleQueue @mut,
    authority: account @signer,
    new_timeout: u64,
    new_reward: u64,
    new_min_stake: u64,
    new_slashing: bool
) {
    require(queue.authority == authority.ctx.key);
    require(new_timeout > 0);
    require(new_reward > 0);

    queue.oracle_timeout = new_timeout;
    queue.reward_per_round = new_reward;
    queue.min_stake = new_min_stake;
    queue.slashing_enabled = new_slashing;
}

// ---------------------------------------------------------------------------
// Oracle Lifecycle
// ---------------------------------------------------------------------------

// 2. create_oracle -- register an oracle node for a queue
pub create_oracle(
    oracle: Oracle @mut @init(payer=creator, space=256) @signer,
    queue: OracleQueue @mut,
    creator: account @mut @signer
) {
    oracle.queue = queue.ctx.key;
    oracle.authority = creator.ctx.key;
    oracle.stake_amount = 0;
    oracle.last_heartbeat = get_clock().slot;
    oracle.total_rewards = 0;
    oracle.is_active = false;  // must stake before becoming active

    queue.num_oracles = queue.num_oracles + 1;
}

// 3. oracle_heartbeat -- oracle proves it is alive
pub oracle_heartbeat(
    oracle: Oracle @mut,
    queue: OracleQueue,
    authority: account @signer
) {
    require(oracle.authority == authority.ctx.key);
    require(oracle.queue == queue.ctx.key);
    require(oracle.is_active);

    oracle.last_heartbeat = get_clock().slot;
}

// 19. stake_oracle -- oracle stakes tokens as economic bond
pub stake_oracle(
    oracle: Oracle @mut,
    queue: OracleQueue,
    staker_token: account @mut,
    oracle_stake_vault: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(oracle.authority == authority.ctx.key);
    require(oracle.queue == queue.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(staker_token, oracle_stake_vault, authority, amount);

    oracle.stake_amount = oracle.stake_amount + amount;

    // Activate oracle once minimum stake met
    if (oracle.stake_amount >= queue.min_stake) {
        oracle.is_active = true;
    }
}

// 20. unstake_oracle -- oracle withdraws stake (must be inactive)
pub unstake_oracle(
    oracle: Oracle @mut @signer,
    queue: OracleQueue,
    oracle_stake_vault: account @mut,
    staker_token: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(oracle.authority == authority.ctx.key);
    require(oracle.queue == queue.ctx.key);
    require(amount > 0);
    require(amount <= oracle.stake_amount);

    spl_token::SPLToken::transfer(oracle_stake_vault, staker_token, oracle, amount);

    oracle.stake_amount = oracle.stake_amount - amount;

    // Deactivate if below minimum
    if (oracle.stake_amount < queue.min_stake) {
        oracle.is_active = false;
    }
}

// 21. slash_oracle -- penalize oracle for submitting bad data
pub slash_oracle(
    oracle: Oracle @mut,
    queue: OracleQueue,
    authority: account @signer,
    slash_amount: u64
) {
    require(queue.authority == authority.ctx.key);
    require(queue.slashing_enabled);
    require(oracle.queue == queue.ctx.key);
    require(slash_amount > 0);
    require(slash_amount <= oracle.stake_amount);

    oracle.stake_amount = oracle.stake_amount - slash_amount;

    // Deactivate if below minimum
    if (oracle.stake_amount < queue.min_stake) {
        oracle.is_active = false;
    }
}

// 22. collect_oracle_rewards -- oracle withdraws accumulated rewards
pub collect_oracle_rewards(
    oracle: Oracle @mut @signer,
    reward_vault: account @mut,
    oracle_token: account @mut,
    authority: account @signer,
    token_program: account
) {
    require(oracle.authority == authority.ctx.key);
    require(oracle.total_rewards > 0);

    let rewards: u64 = oracle.total_rewards;
    oracle.total_rewards = 0;

    spl_token::SPLToken::transfer(reward_vault, oracle_token, oracle, rewards);
}

// ---------------------------------------------------------------------------
// Aggregator (Data Feed)
// ---------------------------------------------------------------------------

// 4. create_aggregator -- create a data feed definition
pub create_aggregator(
    aggregator: Aggregator @mut @init(payer=creator, space=512) @signer,
    queue: OracleQueue,
    creator: account @mut @signer,
    min_oracle_results: u64,
    batch_size: u64,
    min_update_delay: u64,
    variance_threshold: u64
) {
    require(min_oracle_results > 0);
    require(batch_size >= min_oracle_results);
    require(min_update_delay > 0);

    aggregator.queue = queue.ctx.key;
    aggregator.authority = creator.ctx.key;
    aggregator.min_oracle_results = min_oracle_results;
    aggregator.batch_size = batch_size;
    aggregator.min_update_delay = min_update_delay;
    aggregator.variance_threshold = variance_threshold;
    aggregator.current_round_id = 0;
    aggregator.latest_result = 0;
    aggregator.latest_confidence = 0;
    aggregator.latest_timestamp = 0;
    aggregator.num_jobs = 0;
}

// 9. set_aggregator_config -- update feed parameters
pub set_aggregator_config(
    aggregator: Aggregator @mut,
    authority: account @signer,
    new_min_oracles: u64,
    new_batch_size: u64,
    new_variance_threshold: u64,
    new_min_update_delay: u64
) {
    require(aggregator.authority == authority.ctx.key);
    require(new_min_oracles > 0);
    require(new_batch_size >= new_min_oracles);
    require(new_min_update_delay > 0);

    aggregator.min_oracle_results = new_min_oracles;
    aggregator.batch_size = new_batch_size;
    aggregator.variance_threshold = new_variance_threshold;
    aggregator.min_update_delay = new_min_update_delay;
}

// 12. set_aggregator_authority -- transfer feed ownership
pub set_aggregator_authority(
    aggregator: Aggregator @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(aggregator.authority == authority.ctx.key);
    aggregator.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Jobs
// ---------------------------------------------------------------------------

// 8. create_job -- define a data fetch job (HTTP endpoint + JSON parse path)
pub create_job(
    job: Job @mut @init(payer=creator, space=256) @signer,
    aggregator: Aggregator @mut,
    creator: account @mut @signer,
    hash: pubkey
) {
    require(aggregator.authority == creator.ctx.key);

    job.aggregator = aggregator.ctx.key;
    job.hash = hash;
    job.is_active = true;

    aggregator.num_jobs = aggregator.num_jobs + 1;
}

// 10. add_job_to_aggregator -- activate an existing job for a feed
pub add_job_to_aggregator(
    job: Job @mut,
    aggregator: Aggregator @mut,
    authority: account @signer
) {
    require(aggregator.authority == authority.ctx.key);
    require(job.aggregator == aggregator.ctx.key);
    require(!job.is_active);

    job.is_active = true;
    aggregator.num_jobs = aggregator.num_jobs + 1;
}

// 11. remove_job -- deactivate a job from a feed
pub remove_job(
    job: Job @mut,
    aggregator: Aggregator @mut,
    authority: account @signer
) {
    require(aggregator.authority == authority.ctx.key);
    require(job.aggregator == aggregator.ctx.key);
    require(job.is_active);
    require(aggregator.num_jobs > 0);

    job.is_active = false;
    aggregator.num_jobs = aggregator.num_jobs - 1;
}

// ---------------------------------------------------------------------------
// Rounds (Data Collection)
// ---------------------------------------------------------------------------

// 5. open_round -- request new data from oracles
pub open_round(
    round: Round @mut @init(payer=requester, space=256) @signer,
    aggregator: Aggregator @mut,
    requester: account @mut @signer
) {
    let now: u64 = get_clock().slot;

    // Enforce minimum delay between rounds
    if (aggregator.latest_timestamp > 0) {
        require(now - aggregator.latest_timestamp >= aggregator.min_update_delay);
    }

    // Must have at least one active job
    require(aggregator.num_jobs > 0);

    let new_round_id: u64 = aggregator.current_round_id + 1;

    round.aggregator = aggregator.ctx.key;
    round.round_id = new_round_id;
    round.num_submissions = 0;
    round.result_sum = 0;
    round.result_count = 0;
    round.is_open = true;
    round.opened_at = now;

    aggregator.current_round_id = new_round_id;
}

// 6. save_result -- oracle submits result for an open round
pub save_result(
    round: Round @mut,
    aggregator: Aggregator,
    oracle: Oracle @mut,
    queue: OracleQueue,
    authority: account @signer,
    result_value: i64
) {
    require(oracle.authority == authority.ctx.key);
    require(oracle.is_active);
    require(oracle.queue == queue.ctx.key);
    require(round.aggregator == aggregator.ctx.key);
    require(round.is_open);

    // Check oracle liveness
    let now: u64 = get_clock().slot;
    require(now - oracle.last_heartbeat <= queue.oracle_timeout);

    // Cannot exceed batch size
    require(round.num_submissions < aggregator.batch_size);

    // Accumulate result (median approximation: use mean for DSL simplicity)
    round.result_sum = round.result_sum + result_value;
    round.result_count = round.result_count + 1;
    round.num_submissions = round.num_submissions + 1;

    // Reward oracle
    oracle.total_rewards = oracle.total_rewards + queue.reward_per_round;
}

// 7. close_round -- finalize round: compute result from submissions
pub close_round(
    round: Round @mut,
    aggregator: Aggregator @mut,
    closer: account @signer
) {
    require(round.is_open);
    require(round.aggregator == aggregator.ctx.key);
    require(round.result_count >= aggregator.min_oracle_results);

    // Compute median approximation (mean of submissions)
    // True median requires sorting which is complex in on-chain integer math;
    // mean is a reasonable approximation when min_oracle_results is high enough
    let result: i64 = round.result_sum / round.result_count as i64;

    // Variance check: if previous result exists, ensure result within threshold
    if (aggregator.latest_result != 0) {
        let mut diff: i64 = result - aggregator.latest_result;
        if (diff < 0) {
            diff = 0 - diff;  // absolute value
        }
        // variance_threshold is scaled by 10000 (e.g. 100 = 1%)
        // Check: |diff| * 10000 / |latest_result| <= threshold
        let mut abs_latest: i64 = aggregator.latest_result;
        if (abs_latest < 0) {
            abs_latest = 0 - abs_latest;
        }
        if (abs_latest > 0) {
            let variance: u64 = (diff as u64 * 10000) / abs_latest as u64;
            require(variance <= aggregator.variance_threshold);
        }
    }

    let now: u64 = get_clock().slot;

    // Confidence = standard deviation approximation (range / submissions)
    // Simplified: use fixed confidence = result_count for DSL
    let confidence: u64 = round.result_count;

    aggregator.latest_result = result;
    aggregator.latest_confidence = confidence;
    aggregator.latest_timestamp = now;

    round.is_open = false;
}

// ---------------------------------------------------------------------------
// Leases (Feed Funding)
// ---------------------------------------------------------------------------

// 13. create_lease -- fund a feed with tokens for oracle payments
pub create_lease(
    lease: Lease @mut @init(payer=funder, space=256) @signer,
    aggregator: Aggregator,
    funder: account @mut @signer,
    funder_token: account @mut,
    lease_vault: account @mut,
    token_program: account,
    initial_balance: u64,
    withdraw_authority: pubkey
) {
    require(initial_balance > 0);

    spl_token::SPLToken::transfer(funder_token, lease_vault, funder, initial_balance);

    lease.aggregator = aggregator.ctx.key;
    lease.funder = funder.ctx.key;
    lease.balance = initial_balance;
    lease.withdraw_authority = withdraw_authority;
}

// 14. extend_lease -- add more funds to an existing lease
pub extend_lease(
    lease: Lease @mut,
    funder_token: account @mut,
    lease_vault: account @mut,
    funder: account @signer,
    token_program: account,
    amount: u64
) {
    require(amount > 0);

    spl_token::SPLToken::transfer(funder_token, lease_vault, funder, amount);
    lease.balance = lease.balance + amount;
}

// 15. withdraw_lease -- withdraw unused funds from a lease
pub withdraw_lease(
    lease: Lease @mut @signer,
    lease_vault: account @mut,
    recipient: account @mut,
    authority: account @signer,
    token_program: account,
    amount: u64
) {
    require(lease.withdraw_authority == authority.ctx.key);
    require(amount > 0);
    require(amount <= lease.balance);

    spl_token::SPLToken::transfer(lease_vault, recipient, lease, amount);
    lease.balance = lease.balance - amount;
}

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

// 17. create_permission -- authorize an oracle for a queue
pub create_permission(
    permission: Permission @mut @init(payer=granter, space=256) @signer,
    queue: OracleQueue,
    oracle: Oracle,
    granter: account @mut @signer,
    permissions_bitmask: u64
) {
    require(queue.authority == granter.ctx.key);
    require(oracle.queue == queue.ctx.key);

    permission.granter = granter.ctx.key;
    permission.grantee = oracle.ctx.key;
    permission.permissions_bitmask = permissions_bitmask;
}

// 18. set_permission -- update permission bitmask for an oracle
pub set_permission(
    permission: Permission @mut,
    queue: OracleQueue,
    authority: account @signer,
    new_bitmask: u64
) {
    require(queue.authority == authority.ctx.key);
    require(permission.granter == authority.ctx.key);

    permission.permissions_bitmask = new_bitmask;
}
