# 5ive-hubble: Hubble Protocol Migration

A complete 5ive DSL migration of Hubble Protocol -- a CDP (Collateralized Debt Position) stablecoin protocol where users deposit collateral and mint USDH.

## What This Implements

Hubble Protocol lets users lock collateral (SOL, mSOL, etc.) into Troves and mint USDH stablecoin against it. The protocol enforces a minimum collateral ratio, provides a Stability Pool for liquidation absorption, and supports redemptions that swap USDH for collateral at face value.

### Key Concepts

- **Troves (CDPs):** Each user's collateral + debt position. Must maintain > 110% collateral ratio.
- **Stability Pool:** USDH depositors absorb liquidated trove debt and earn seized collateral.
- **Redemptions:** Anyone can swap USDH for collateral at $1 face value from the lowest-CR troves, improving system health.
- **Borrowing fee:** Charged on USDH minting (added to trove debt, not deducted from mint).
- **Redemption fee:** Charged when redeeming USDH for collateral.

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Protocol** | Global config: USDH mint, stability pool, fees, total collateral/debt, pause | 512 |
| **Trove** | User CDP: collateral mint/vault, collateral amount, debt, cached CR | 512 |
| **StabilityDeposit** | User's stability pool position: USDH deposited, pending collateral gains | 256 |
| **OraclePrice** | Per-asset price feed with decimals and staleness | 256 |

### Instructions (20 total)

**Protocol Setup:**
1. `initialize` -- Create protocol state, USDH mint, stability pool config

**Trove Operations:**
2. `create_trove` -- Open a new collateral + debt position
3. `deposit_collateral` -- Add collateral to a trove (improves CR)
4. `withdraw_collateral` -- Remove collateral (health check enforced)
5. `borrow_usdh` -- Mint USDH against collateral (borrowing fee applied, CR checked)
6. `repay_usdh` -- Burn USDH to reduce trove debt
7. `close_trove` -- Repay all debt and withdraw all collateral

**Liquidation:**
8. `liquidate_trove` -- Liquidate under-collateralized trove (CR < minimum); stability pool absorbs debt, liquidator gets collateral + 10% bonus

**Stability Pool:**
9. `stability_pool_deposit` -- Deposit USDH to earn liquidation gains
10. `stability_pool_withdraw` -- Withdraw USDH from stability pool
11. `claim_liquidation_gains` -- Claim collateral earned from absorbed liquidations

**Redemptions:**
12. `redeem` -- Swap USDH for collateral at $1 face value (redemption fee applied)

**Oracle:**
13. `update_oracle` -- Push new price for an oracle feed

**Admin:**
14. `set_redemption_fee` -- Update redemption fee
15. `set_borrowing_fee` -- Update borrowing fee
16. `set_min_collateral_ratio` -- Update minimum CR (must be >= 100%)
17. `collect_borrowing_fees` -- Withdraw accumulated borrowing fees as USDH
18. `set_authority` -- Transfer protocol admin
19. `pause` -- Halt protocol operations
20. `unpause` -- Resume protocol operations

## Math

All arithmetic is integer-only. Key formulas:

- **Collateral ratio:** `CR_bps = collateral * oracle_price * 10000 / (debt * PRICE_SCALE)`
- **Borrowing fee:** `fee = usdh_amount * borrowing_fee_bps / 10000` (added to debt)
- **Redemption:** `collateral_out = (redeem_amount - fee) * PRICE_SCALE / oracle_price`
- **Liquidation bonus:** `seize = debt_value_in_collateral * 110 / 100` (10% bonus)
- **Liquidation threshold:** Trove is liquidatable when `CR < min_collateral_ratio_bps`
- **PRICE_SCALE = 1,000,000,000 (1e9)**

## Protocol Invariants

- Minimum collateral ratio >= 10000 bps (100%); default is 11000 bps (110%)
- Oracle staleness <= 100 slots for all price-sensitive operations
- Fees < 10000 bps (< 100%)
- Borrowing fees are added to trove debt (not deducted from minted USDH)
- Stability pool USDH is burned during liquidation absorption
- Redemptions pull from specific troves (lowest-CR first in practice)
- `protocol.total_debt` and `protocol.total_collateral` track system-wide sums
