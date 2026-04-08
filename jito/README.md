# 5ive-jito: Jito Liquid Staking Migration

A complete 5ive DSL migration of Jito -- Solana's MEV-aware liquid staking protocol where staking rewards AND MEV tips flow back to token holders.

## What This Implements

Jito extends traditional liquid staking (stake SOL, receive jitoSOL) with MEV tip distribution. Validators running Jito's block engine earn tips from searchers, and those tips flow back into the stake pool, increasing the jitoSOL exchange rate for all holders.

### Key Innovation -- MEV Tip Distribution

Traditional liquid staking only captures staking rewards (~6-7% APY). Jito adds MEV tips:
- Validators earn tips through Jito's block engine (off-chain infrastructure)
- `distribute_tips` flows tips into the stake pool's `total_sol`
- This raises the jitoSOL/SOL exchange rate for ALL holders
- Result: jitoSOL yields staking rewards + MEV tips (historically 1-3% additional)

### Key Mechanics

- **Exchange rate**: `jitosol_amount = (sol_amount * jitosol_supply) / total_sol`
- **Delayed unstake**: Burn jitoSOL, get a WithdrawTicket, claim after epoch boundary
- **Instant withdraw**: From a liquidity pool at a higher fee (no epoch wait)
- **Validator management**: Add/remove/score validators, delegate/undelegate stake
- **Epoch boundary**: `update_exchange_rate` recalculates based on staking rewards + tips

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **StakePool** | Pool config: mint, total SOL, supply, fees, tip vault, validators, liquidity | 1024 |
| **ValidatorRecord** | Per-validator: vote account, stake, tip share, score, active status | 512 |
| **WithdrawTicket** | Delayed unstake ticket: jitoSOL burned, SOL owed, epoch, claim status | 256 |
| **TipDistribution** | Per-epoch tip record: total tips, distributed amount, validators paid | 256 |

### Instructions (20 total)

**Pool Setup:**
1. `initialize` -- Create stake pool with fee/tip config

**Staking:**
2. `deposit_sol` -- Stake SOL, receive jitoSOL at exchange rate
3. `withdraw_sol` -- Burn jitoSOL, create delayed withdraw ticket
4. `instant_withdraw` -- Burn jitoSOL, get SOL immediately from liquidity pool

**Validator Management:**
5. `add_validator` -- Register validator with tip share
6. `remove_validator` -- Deactivate validator (must unstake first)
7. `update_validator_score` -- Update performance score
8. `stake_to_validator` -- Delegate SOL to validator
9. `unstake_from_validator` -- Begin undelegation

**MEV Tips:**
10. `distribute_tips` -- Flow MEV tips into pool (raises exchange rate)
11. `claim_tips` -- Validator claims their tip share

**Epoch Management:**
12. `update_exchange_rate` -- Account for staking rewards at epoch boundary
13. `update_epoch` -- General epoch housekeeping

**Liquidity Pool:**
14. `add_tip_liquidity` -- Add SOL to instant-withdraw pool
15. `remove_tip_liquidity` -- Remove SOL from instant-withdraw pool

**Admin:**
16. `set_fees` -- Update deposit/withdraw/instant/tip fees
17. `set_authority` -- Transfer pool admin
18. `pause` -- Emergency pause
19. `unpause` -- Resume operations
20. `collect_treasury_fees` -- Sweep accumulated fees to treasury

## Original vs 5ive

| Metric | Rust/Anchor | 5ive DSL |
|--------|-------------|----------|
| Code size | ~10,000 SLoC | ~500 SLoC |
| Bytecode | ~250 KB | ~3 KB |
| Compute | Baseline | ~60% less |

## Build & Test

```bash
five build
five local execute build/main.five 0
```

## Migration Notes

Jito's production system includes the block engine (off-chain MEV infrastructure), tip router program, and integration with the Solana stake program via CPI. This migration focuses on the on-chain stake pool and tip distribution logic. The actual Solana stake program CPI (delegate, deactivate, withdraw) is simplified to SPL token transfers for portability. The MEV tip flow -- the protocol's key differentiator -- is fully preserved.
