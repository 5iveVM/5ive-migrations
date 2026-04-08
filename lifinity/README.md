# 5ive-lifinity: Lifinity Protocol Migration

A complete 5ive DSL migration of Lifinity -- a Proactive Market Maker (PMM) that uses oracle prices to SET the swap price instead of discovering it from reserve ratios.

## What This Implements

Lifinity is fundamentally different from traditional AMMs (Raydium, Orca). Instead of letting the constant product formula determine price from reserves, Lifinity reads the price from an oracle and applies a configurable spread. This eliminates most impermanent loss for liquidity providers.

### Key Innovation -- Oracle-Driven Pricing

Traditional AMM: `price = reserve_b / reserve_a` (discovered from trades)
Lifinity PMM: `price = oracle_price +/- spread` (set by the oracle)

- **Price source:** Oracle feed, not reserve ratios
- **Spread:** Dynamic, widens during high volatility (high oracle confidence band)
- **Virtual reserves:** Computed FROM oracle price, not from actual token balances
- **Concentration:** Multiplies effective liquidity depth without more capital
- **Result:** LPs earn swap fees with minimal impermanent loss

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Pool** | Token pair, oracle, virtual/real reserves, spread config, concentration, fees | 1024 |
| **PriceOracle** | Oracle feed with confidence band and staleness | 256 |
| **NftPool** | Oracle-priced pool for NFT trading against floor price | 512 |
| **RewardDistributor** | Per-share reward accumulator for LP incentives | 256 |

### Instructions (18 total)

**Pool Lifecycle:**
1. `create_pool` -- Initialize PMM pool with oracle, spread, and concentration
2. `deposit` -- Add liquidity, receive LP tokens proportionally
3. `withdraw` -- Burn LP tokens, receive proportional reserves

**Oracle-Driven Swap:**
4. `swap` -- Execute swap at oracle price with dynamic spread and fee
5. `update_oracle_price` -- Permissionless: refresh cached oracle price
6. `rebalance` -- Permissionless crank: realign virtual reserves to oracle

**Configuration:**
7. `set_spread` -- Admin: configure min/max spread bounds
8. `set_concentration` -- Admin: update liquidity concentration factor
9. `set_fee_rate` -- Admin: update swap fee rate
10. `update_pool_config` -- Admin: batch-update all pool parameters

**Fee Collection:**
11. `collect_fees` -- Admin: withdraw accumulated swap fees

**NFT Trading:**
12. `create_nft_pool` -- Initialize oracle-priced NFT trading pool
13. `nft_swap` -- Buy/sell NFTs against oracle floor price with spread

**Admin:**
14. `set_authority` -- Transfer pool admin
15. `pause` -- Halt pool operations
16. `unpause` -- Resume pool operations

**Rewards:**
17. `claim_rewards` -- LP claims accumulated reward tokens
18. `distribute_rewards` -- Authority deposits rewards, updates per-share accumulator

## Math

All arithmetic is integer-only. Key formulas:

- **Effective buy price:** `oracle_price * (10000 + spread_bps) / 10000`
- **Effective sell price:** `oracle_price * (10000 - spread_bps) / 10000`
- **Virtual reserves:** `virtual_a = real_a * concentration / 100`, `virtual_b = virtual_a * oracle_price / PRICE_SCALE`
- **Dynamic spread:** `spread = min_spread + oracle_confidence_bps`, clamped to `max_spread`
- **Swap (A to B):** `amount_out = amount_after_fee * effective_price / PRICE_SCALE`
- **Swap (B to A):** `amount_out = amount_after_fee * PRICE_SCALE / effective_price`
- **Rewards per share:** `increase = amount * 1e9 / total_lp_supply`
- **PRICE_SCALE = 1,000,000,000 (1e9)**

## Protocol Invariants

- Oracle staleness <= 100 slots for all swaps and rebalances
- Spread bounds: `0 <= min_spread <= max_spread < 10000`
- Concentration must be > 0 (100 = 1x, 200 = 2x effective depth)
- Fee rate < 10000 bps (< 100%)
- Virtual reserves are always recomputed after any state mutation
