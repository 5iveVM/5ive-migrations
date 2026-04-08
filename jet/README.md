# 5ive Jet Protocol Migration

Jet Protocol (fixed-rate lending with bond-like term structure) rewritten in 5ive DSL. Key differentiator from Solend/Port: fixed-term deposits earn a guaranteed rate for 7, 30, or 90 day lock periods, using orderbook-style rate discovery.

## What Jet Protocol Does

Jet is a lending protocol on Solana with two modes: variable-rate lending (like Solend) and fixed-term deposits (unique to Jet). Fixed-term deposits lock tokens for a set period at a guaranteed interest rate, functioning like on-chain bonds.

### Core Concepts

- **Variable lending**: Standard supply/borrow with utilization-based interest rates
- **Fixed-term deposits**: Lock tokens for 7/30/90 days at guaranteed rate (bps per annum)
- **Obligations**: Track user collateral deposits and outstanding borrows (3 slots each)
- **Liquidation**: Underwater obligations can be liquidated with a bonus incentive

## Instructions Implemented

### Market & Reserve Setup
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `init_market` | Create lending market with authority |
| 2 | `init_reserve` | Create reserve for a token with interest rate config + fixed-term rates |
| 3 | `init_obligation` | Create user obligation to track deposits/borrows |

### Lending Operations
| # | Instruction | Description |
|---|-------------|-------------|
| 4 | `deposit` | Supply liquidity, receive collateral tokens |
| 5 | `withdraw` | Burn collateral, redeem underlying (health check enforced) |
| 6 | `borrow` | Borrow against collateral (LTV enforced) |
| 7 | `repay` | Repay borrowed amount (clamped to outstanding) |
| 8 | `liquidate` | Liquidate underwater obligation (bonus to liquidator) |

### Interest & Oracle
| # | Instruction | Description |
|---|-------------|-------------|
| 9 | `refresh_reserve` | Accrue interest: utilization-based rate, protocol fee split |

### Fixed-Term Deposits (Key Feature)
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `create_fixed_term_deposit` | Lock tokens for 7/30/90 days at guaranteed rate |
| 11 | `redeem_fixed_term` | Unlock principal + interest at maturity |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 12 | `set_reserve_config` | Update LTV, reserve factor, supply cap, fixed rates |
| 13 | `set_oracle` | Set oracle address and price for a reserve |
| 14 | `collect_fees` | Withdraw accumulated protocol fees |
| 15 | `set_authority` | Transfer market authority |
| 16 | `pause_unpause` | Pause/unpause the market |

## Accounts

- **Market** -- Global config with authority and pause state
- **Reserve** -- Per-token: liquidity, interest params, fixed-term rates (7d/30d/90d bps), oracle
- **Obligation** -- Per-user: 3 deposit + 3 borrow slots, value tracking
- **FixedTermDeposit** -- Bond: reserve, owner, amount, rate_bps, maturity_timestamp, is_redeemed

## Key Math

- Interest accrual: utilization-based kink model (same as Solend)
- Fixed-term yield: `interest = amount * rate_bps / 10000` for the term period
- Liquidation: `collateral_seized = repay * (100 + bonus) / 100`
