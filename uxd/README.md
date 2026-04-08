# 5ive-uxd: UXD Protocol Migration

A complete 5ive DSL migration of UXD Protocol -- a delta-neutral stablecoin that maintains its $1 peg by hedging deposited collateral with short perpetual positions.

## What This Implements

UXD Protocol mints a stablecoin (UXD) backed by a delta-neutral strategy. When a user deposits SOL, the protocol opens an equal short perpetual position. Price movement on the collateral is exactly offset by PnL on the short, keeping UXD at $1 regardless of SOL price.

### Key Innovation -- Delta-Neutral Hedging

```
User deposits 1 SOL (worth $100)
  -> Protocol holds 1 SOL as collateral (+$100 exposure)
  -> Protocol opens 1 SOL short perp (-$100 exposure)
  -> Net exposure = $0 (delta-neutral)
  -> Mints 100 UXD

If SOL goes to $150:
  Collateral: +$50 gain
  Short perp: -$50 loss
  Net: $0 change -> UXD still worth $1

If SOL drops to $50:
  Collateral: -$50 loss
  Short perp: +$50 gain
  Net: $0 change -> UXD still worth $1
```

- **Funding payments** from short perps = yield for the protocol (shorts earn funding in bullish markets)
- **Idle stablecoins** are parked in Mercurial vaults for additional yield
- **Insurance fund** covers episodes of negative funding
- **Emergency close** available if perp market degrades

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **Controller** | Global config: UXD mint, insurance, supply cap, fees, Mercurial integration | 768 |
| **HedgePosition** | Per-position: collateral, short size, entry price, PnL, funding accrued | 512 |
| **OraclePrice** | Per-asset price feed with staleness enforcement | 256 |

### Instructions (18 total)

**Core Mint/Redeem:**
1. `initialize` -- Create controller, UXD mint, insurance fund config
2. `mint_uxd` -- Deposit collateral, open short hedge, mint UXD 1:1 (minus fee)
3. `redeem_uxd` -- Burn UXD, close proportional short, return collateral (minus fee)
4. `rebalance` -- Adjust hedge: mark-to-market PnL, update entry price

**Mercurial Integration (Idle Yield):**
5. `register_mercurial_vault` -- Connect a Mercurial vault for idle stablecoin yield
6. `deposit_to_mercurial` -- Park idle stables in Mercurial
7. `withdraw_from_mercurial` -- Pull stables back from Mercurial

**Configuration:**
8. `set_redeemable_global_supply_cap` -- Update max UXD supply
9. `set_minting_fee` -- Update minting fee
10. `set_redeeming_fee` -- Update redemption fee

**Interest and Insurance:**
11. `collect_interest` -- Consolidate perp funding + Mercurial yield into insurance
12. `fund_insurance` -- Deposit additional funds to insurance vault
13. `withdraw_insurance` -- Admin: withdraw from insurance fund

**Admin:**
14. `set_authority` -- Transfer controller admin
15. `pause` -- Halt minting and redeeming
16. `unpause` -- Resume operations
17. `update_controller` -- Batch-update controller configuration
18. `emergency_close_positions` -- Force-close all hedges, move collateral to insurance

## Math

All arithmetic is integer-only. Key formulas:

- **Collateral value:** `value = collateral_amount * oracle_price / PRICE_SCALE`
- **UXD to mint:** `uxd = collateral_value - (collateral_value * minting_fee_bps / 10000)`
- **Collateral to return:** `collateral = (uxd_redeemed - fee) * PRICE_SCALE / oracle_price`
- **Short PnL (price dropped):** `pnl = (entry_price - current_price) * short_size / PRICE_SCALE`
- **Short PnL (price rose):** `pnl = -(current_price - entry_price) * short_size / PRICE_SCALE`
- **PRICE_SCALE = 1,000,000,000 (1e9)**

## Protocol Invariants

- `total_uxd_minted <= redeemable_supply_cap` at all times
- Oracle staleness <= 100 slots for minting, redeeming, and rebalancing
- Fees < 10000 bps (< 100%)
- Insurance fund absorbs negative funding episodes
- Emergency close moves all collateral to insurance (UXD remains in circulation but is un-hedged)
- Hedge position PnL is marked to market on each rebalance
