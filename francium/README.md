# 5ive-francium: Francium Protocol Migration

A complete 5ive DSL migration of Francium -- Solana's leveraged yield farming protocol that lets users borrow to amplify LP farming returns.

## What This Implements

Francium combines lending pools with leveraged farming positions. Lenders earn interest on deposited tokens, while farmers borrow those tokens at leverage (up to 6x) to amplify LP farming yields.

### Key Innovation -- Leveraged Yield Farming

Traditional yield farming caps returns at 1x exposure. Francium enables:
- Deposit collateral, borrow additional tokens from lending pools
- Enter LP positions with amplified capital (up to 6x leverage)
- Stake LP tokens for farm rewards that compound back into the position
- Health factor tracking with liquidation for undercollateralized positions
- Interest rate model determines borrow cost; spread goes to lenders

### Account Structure

| Account | Purpose | Space |
|---------|---------|-------|
| **LendingPool** | Per-token lending pool with supply/borrow indices, interest model | 512 |
| **LeveragedPosition** | Per-user position: collateral, borrows, LP tokens, health factor | 512 |
| **FarmStrategy** | LP pair config: mints, farm program, max leverage, liquidation params | 512 |

### Instructions (20 total)

**Lending Pool:**
1. `create_lending_pool` -- Initialize isolated lending pool with interest model
2. `supply` -- Lend tokens into pool, earn interest
3. `withdraw_supply` -- Withdraw lent tokens plus earned interest

**Farm Strategy:**
4. `create_farm_strategy` -- Define LP pair, farm program, leverage + liquidation config

**Leveraged Positions:**
5. `open_leveraged_position` -- Deposit collateral, borrow, enter LP, stake
6. `close_position` -- Unstake, remove LP, repay borrow, return remainder to user
7. `add_collateral` -- Top up collateral to improve health factor
8. `remove_collateral` -- Withdraw excess collateral (health check enforced)
9. `increase_leverage` -- Borrow more to amplify position
10. `decrease_leverage` -- Repay some borrow to reduce exposure
11. `harvest_and_compound` -- Permissionless crank: claim farm rewards, compound

**Liquidation:**
12. `liquidate_position` -- Liquidate if health factor < 1.0 (bonus to liquidator)
13. `emergency_close` -- Authority force-closes position regardless of state

**Admin Configuration:**
14. `set_interest_model` -- Change interest rate model (linear/kink/flat)
15. `set_max_leverage` -- Update maximum leverage for a strategy (1-6x)
16. `set_liquidation_bonus` -- Update liquidator incentive (1-15%)
17. `set_fees` -- Update liquidation threshold (50-95%)
18. `collect_protocol_fees` -- Withdraw accrued protocol interest
19. `set_authority` -- Transfer pool control
20. `pause` / `unpause` -- Halt or resume pool operations

## Health Factor Model

- `health_factor = (collateral * liq_threshold) / borrowed_amount`
- Scaled by 100: health >= 100 means safe (1.0x), health < 100 means liquidatable
- Liquidator repays debt and receives collateral + bonus (1-15%)
- Emergency close available to authority for stuck positions

## Original Protocol

- **Chain**: Solana
- **Category**: Leveraged Yield Farming / DeFi
- **Reference**: [francium.io](https://francium.io/)
