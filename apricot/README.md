# Apricot Finance -- 5ive DSL Migration

A faithful 5ive DSL migration of [Apricot Finance](https://apricot.one), a DeFi yield protocol with lending, cross-collateral, and automated risk management on Solana.

## What is Apricot Finance?

Apricot is a lending/yield protocol whose key innovation is **Apricot Assist** -- an auto-deleverage mechanism that protects users from liquidation by automatically selling collateral to repay borrows when health drops below a configurable threshold. It also offers X-Farm (cross-protocol yield farming with auto-compound) and flash liquidation.

## How this differs from 5ive-lending

| Feature | 5ive-lending | Apricot migration |
|---|---|---|
| Interest precision | u64 (RATE_SCALE=10^9) | WAD-lite (10^9 scaled) with two-slope kink |
| Interest rate model | Single-slope | Two-slope kink (min -> optimal -> max) |
| aToken exchange rate | 1:1 (no growth) | Grows as interest accrues |
| User structure | Single deposit + borrow value | 3 deposit + 3 borrow slots, assist config |
| Auto-deleverage | Not supported | Full Apricot Assist (enable/disable/threshold/execute) |
| Yield farming | Not supported | Farm + StakeRecord with rewards + auto-compound |
| Flash liquidation | Not supported | Flash loan + liquidation in one tx |
| Cross-collateral | Not supported | Collateral weight per reserve |
| Liquidation close factor | No limit | 50% max close factor |
| Oracle | Basic | Staleness-enforced (100-slot window) |
| Pause/unpause | Single toggle | Separate pause + unpause instructions |

## Account Structure

### Market
Top-level market account. Stores admin authority, oracle program reference, pause state, reserve count, and accumulated protocol fees.

### Reserve
One per supported token. Contains:
- **Vault references**: liquidity supply vault, collateral mint, fee receiver, oracle
- **State**: available liquidity, WAD-scaled borrowed amount, cumulative borrow rate, price, aToken supply, accumulated protocol fees
- **Config**: two-slope rate model params (min/optimal/max rates, optimal utilization), LTV, liquidation threshold + bonus, collateral weight, deposit/borrow limits

### UserAccount
Per-user position account with 3 deposit slots and 3 borrow slots, supporting multi-asset collateral and multi-asset borrowing. Includes Apricot Assist configuration:
- `assist_enabled` -- whether auto-deleverage is active
- `assist_threshold` -- health factor that triggers assist (scaled by 100, e.g. 110 = 1.1x)
- `assist_target_health` -- target health after assist (e.g. 150 = 1.5x)
- `assist_fee_bps` -- fee paid to the assist executor bot (in basis points)

### Farm
Yield farming pool for LP tokens. Tracks stake mint, reward mint, reward vault, total staked, reward rate per slot, and accumulated reward-per-token.

### StakeRecord
Per-user staking position in a farm. Tracks staked amount, reward debt, and pending rewards.

### PriceOracle
Simple oracle with price, decimals, authority, and last update slot. Staleness enforced at 100 slots.

## Instructions (23+)

### Lending (1-7)
1. `init_market` -- Create market with admin and oracle program
2. `init_reserve` -- Register token with interest params, oracle, collateral weight, caps
3. `deposit` -- Deposit tokens, receive aTokens at exchange rate
4. `withdraw` -- Burn aTokens, receive underlying (health check enforced)
5. `borrow` -- Borrow against collateral (LTV + borrow limit checks)
6. `repay` -- Repay borrowed tokens (clamped to outstanding)
7. `refresh_reserve` -- Accrue compound interest, update oracle price, update cumulative rate

### Apricot Assist -- Auto-Deleverage (8-12)
8. `enable_assist` -- Opt into auto-deleverage protection
9. `disable_assist` -- Opt out of auto-deleverage
10. `set_assist_threshold` -- Configure health threshold (1.1x-2.0x) and target health (above threshold, up to 5.0x)
11. `execute_assist` -- Permissionless crank: any bot can trigger when health < threshold. Sells collateral to repay borrow, pays executor a fee
12. `set_assist_fee` -- Set fee (in bps, max 5%) charged on assist execution

### X-Farm -- Cross-Protocol Yield (13-17)
13. `create_farm` -- Create yield farming pool with reward rate
14. `stake` -- Stake LP tokens to earn rewards (reward accounting updated)
15. `unstake` -- Unstake LP tokens (pending rewards accumulated)
16. `claim_rewards` -- Claim accumulated farming rewards
17. `compound` -- Auto-reinvest rewards back into staked position

### Liquidation (18-19)
18. `liquidate` -- Standard liquidation with bonus; 50% close factor, interest accrued first
19. `flash_liquidate` -- Flash borrow from reserve, liquidate, repay + fee in one tx

### Admin (20-23)
20. `set_oracle` / `init_oracle` -- Price feed management
21. `set_authority` -- Transfer market admin
22. `pause` / `unpause` -- Emergency controls
23. `collect_protocol_fees` -- Withdraw accumulated protocol fees from reserve

### Supporting Instructions
- `init_user_account` -- Create user position with zeroed slots and default assist config
- `refresh_user_account` -- Recalculate health from reserve prices (per-reserve, with collateral weight)
- `set_reserve_config` -- Update all reserve parameters

### Read-only Views
- `get_reserve_utilization` -- Current utilization rate
- `get_reserve_borrow_rate` -- Current annualized borrow rate
- `get_exchange_rate` -- aToken exchange rate (scaled by 10^9)
- `get_health_factor` -- Health factor (>100 = healthy, <100 = liquidatable)
- `get_total_liquidity` -- Total reserve liquidity (available + borrowed)
- `get_assist_status` -- Whether assist is enabled (1) or disabled (0)

## Key Math

### Two-Slope Interest Rate Model
```
if utilization <= optimal_utilization:
    rate = min_rate + utilization * (optimal_rate - min_rate) / optimal_util
else:
    rate = optimal_rate + (util - optimal) * (max_rate - optimal_rate) / (100 - optimal)
```

### aToken Exchange Rate
```
exchange_rate = total_liquidity / collateral_supply
deposit:  aTokens = amount * collateral_supply / total_liquidity
withdraw: liquidity = aTokens * total_liquidity / collateral_supply
```

The exchange rate increases over time as interest accrues, making aTokens worth more underlying tokens.

### Compound Interest
```
interest = borrowed_wad * borrow_rate * slots_elapsed / (SLOTS_PER_YEAR * 100)
new_borrowed_wad = borrowed_wad + interest
new_cumulative_rate = old_rate + old_rate * borrow_rate * slots / (SLOTS_PER_YEAR * 100)
```

### Apricot Assist
```
health_factor = (deposited_value * liquidation_threshold / 100) * 100 / borrowed_value

When health < assist_threshold:
  repay_amount = (target * borrowed - weighted_deposit * 100) / target
  collateral_sold = repay_amount converted at exchange rate
  executor_fee = repay_amount * assist_fee_bps / 10000
```

### Flash Liquidation Fee
```
fee = amount * 30 / 10000  (30 bps, minimum 1 token)
```

### Cross-Collateral Weight
Deposit values are weighted by the reserve's `collateral_weight` (0-100%). This enables cross-collateral positions where different assets contribute differently to borrowing power.

## Source

`src/main.v` -- Complete 5ive DSL migration (~900 lines)
