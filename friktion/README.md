# 5ive Friktion Migration

Friktion (DeFi Options Vaults / structured products) rewritten in 5ive DSL. Auto-sells covered calls and cash-secured puts in epoch-based cycles. Premium collected from option buyers = yield for depositors.

## What Friktion Does

Friktion runs structured product vaults ("Volts") that automatically generate yield by selling options. Each vault operates in epochs (weekly/biweekly cycles). Users deposit underlying tokens, the vault mints and sells options to market makers, and at expiry the outcome determines profit or loss.

### Core Concepts

- **Epochs**: Vault lifecycle runs in cycles. Deposit -> options sold -> settle at expiry -> repeat
- **Strategy types**: Covered call (0), Cash-secured put (1), Basis yield (2), Protection (3)
- **Volt tokens**: Share tokens representing proportional ownership of vault deposits
- **Premium**: Payment from option buyers to the vault; this is the yield source
- **Strike selection**: Admin sets strike price within allowed offset from oracle price
- **Performance fee**: Protocol takes a percentage of positive PnL each epoch

## Instructions Implemented

### Vault Lifecycle
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_volt` | Create vault with strategy type, epoch length, fees |

### User Operations
| # | Instruction | Description |
|---|-------------|-------------|
| 2 | `deposit_to_volt` | Deposit underlying, receive volt tokens |
| 3 | `withdraw_from_volt` | Burn volt tokens, receive underlying |
| 4 | `claim_pending` | Confirm pending deposits/withdrawals after epoch boundary |

### Epoch Operations
| # | Instruction | Description |
|---|-------------|-------------|
| 5 | `start_epoch` | Begin new epoch: set strike price, mint options |
| 6 | `sell_options` | Auction options to market makers for premium |
| 7 | `settle_epoch` | Expire options: calculate PnL, distribute premium |

### Basis Yield Strategy
| # | Instruction | Description |
|---|-------------|-------------|
| 8 | `create_entropy_round` | Allocate funds to external yield protocol |
| 9 | `rebalance_entropy` | Apply realized yield from basis trade |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `set_volt_params` | Update min premium, max strike offset |
| 11 | `set_auction_params` | Update auction minimum premium |
| 12 | `set_performance_fee` | Update performance fee bps |
| 13 | `collect_fees` | Withdraw accumulated protocol fees |
| 14 | `emergency_withdraw` | Emergency withdrawal by authority |
| 15 | `set_authority` | Transfer vault authority |
| 16 | `pause` | Pause vault |
| 17 | `unpause` | Unpause vault |

## Accounts

- **Volt** -- authority, underlying/quote mints, volt_token_mint, vault, strategy_type (u8), epoch_length, current_epoch, strike_price, premium_collected, total_deposited/shares, performance_fee_bps, is_paused
- **Epoch** -- volt, epoch_number, start/end_time, strike_price, options_minted/sold, premium, settled, pnl (i64)
- **UserDeposit** -- volt, owner, shares, pending_deposit, pending_withdrawal, last_epoch

## Key Math

- Shares: `shares = amount * total_shares / total_deposited`
- Covered call loss: `loss = (settlement - strike) * options_sold / settlement` (when ITM)
- Cash-secured put loss: `loss = (strike - settlement) * options_sold / strike` (when ITM)
- Performance fee: `fee = positive_pnl * performance_fee_bps / 10000`
- Epoch PnL: `pnl = premium - exercise_loss`
