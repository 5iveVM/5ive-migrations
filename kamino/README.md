# 5ive-kamino: Kamino Finance Migration

A complete 5ive DSL migration of Kamino Finance -- auto-compounding concentrated liquidity vaults with an integrated lending protocol.

## What This Implements

Kamino Finance wraps concentrated liquidity market maker (CLMM) positions into automated vaults. Users deposit tokens, receive kTokens representing their share, and the protocol automatically rebalances positions and compounds fees. The lending side follows the Aave v2 / Solend reserve model with cTokens, utilization-based interest, and oracle-validated liquidations.

### Key Innovation -- Auto-Compounding CLMM Vaults

Unlike passive LP positions that go out of range:
- Strategies define a concentrated position with `position_range_lower` / `position_range_upper`
- When price drifts beyond `drift_threshold`, a permissionless `rebalance` crank re-centers the position
- Accumulated CLMM fees are reinvested via the `compound` crank (minus performance fee)
- kToken shares appreciate as compounded fees grow the vault TVL

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Strategy** | Vault config: CLMM pool, position range, rebalance params, fee config, TVL tracking | 1024 |
| **KToken** | kToken mint metadata; mirrors total_shares for cross-validation | 256 |
| **LendingMarket** | Top-level lending market config (admin, pause) | 512 |
| **Reserve** | Per-token lending reserve with utilization-based interest, risk params, supply cap | 768 |
| **Obligation** | User's cross-collateral borrow position | 256 |
| **PriceOracle** | Oracle feed with staleness enforcement (100-slot window) | 256 |

### Instructions (22 total)

**Vault Operations:**
1. `create_strategy` -- Initialize a CLMM vault with rebalance and fee parameters
2. `deposit` -- Deposit token A/B, receive kTokens proportional to TVL
3. `withdraw` -- Burn kTokens, receive proportional token A/B
4. `rebalance` -- Permissionless crank: re-center position when price drifts
5. `compound` -- Permissionless crank: reinvest CLMM fees (minus performance fee)

**Vault Admin:**
6. `set_strategy_params` -- Update rebalance width and drift threshold
7. `set_strategy_fee` -- Update performance fee (max 50%)
8. `collect_performance_fee` -- Withdraw accumulated performance fees
9. `set_authority` -- Transfer strategy admin
10. `pause` -- Halt vault operations
11. `unpause` -- Resume vault operations

**Lending Market:**
12. `create_lending_market` -- Initialize lending market
13. `init_reserve` -- Register a token reserve with interest and risk config
14. `deposit_lending` -- Supply liquidity, receive cTokens
15. `withdraw_lending` -- Redeem cTokens with health check
16. `borrow` -- Borrow against collateral (LTV-limited)
17. `repay` -- Repay borrowed liquidity (clamped to outstanding debt)
18. `liquidate` -- Liquidate under-collateralized obligation with bonus
19. `refresh_reserve` -- Update reserve timestamp for interest accrual
20. `flash_borrow` -- Borrow within a single transaction (no collateral)
21. `flash_repay` -- Repay flash loan plus fee
22. `set_lending_config` -- Admin: update reserve parameters

## Math

- **Share calculation:** `shares = deposit_value * total_shares / total_value` (proportional)
- **Performance fee:** `fee = compounded_fees * performance_fee_bps / 10000`
- **Interest rate:** Kink model -- linear below optimal utilization, steep above
- **Liquidation:** Seize `repay_amount * (100 + liquidation_bonus) / 100` in collateral
- **All arithmetic is integer-only; no floating point**

## Protocol Invariants

- `ktoken.supply == strategy.total_shares` at all times
- Oracle staleness <= 100 slots for all price-sensitive operations
- Performance fee capped at 5000 bps (50%)
- Reserve factor capped at 50%; LTV must be in (0, 100)
- Flash loans must be repaid within the same transaction
