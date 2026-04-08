# 5ive Port Finance Migration

Port Finance (variable-rate lending with PORT staking incentives) rewritten in 5ive DSL. Aave-style lending with two-slope interest rates, flash loans, and PORT token mining rewards for borrowers.

## What Port Finance Does

Port is a lending protocol on Solana combining standard variable-rate lending with two unique features: flash loans (atomic borrow/repay in same transaction) and PORT token mining incentives that reward borrowing activity.

### Core Concepts

- **Two-slope interest**: Below optimal utilization uses slope_1 (gentle), above uses slope_2 (steep)
- **Flash loans**: Borrow and repay atomically within one transaction, paying a fee
- **PORT mining**: Borrowers earn PORT tokens proportional to borrow amount and time
- **Obligations**: Track deposits/borrows per user with 3 slots each + pending PORT rewards

## Instructions Implemented

### Market & Reserve Setup
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `init_market` | Create lending market |
| 2 | `init_reserve` | Create reserve with two-slope rates, flash loan fee, PORT mining rate |
| 3 | `init_obligation` | Create user obligation |

### Deposit / Redeem
| # | Instruction | Description |
|---|-------------|-------------|
| 4 | `deposit_reserve` | Supply liquidity, receive collateral tokens |
| 5 | `redeem_collateral` | Burn collateral, receive underlying |

### Obligation Management
| # | Instruction | Description |
|---|-------------|-------------|
| 6 | `deposit_collateral` | Move collateral into obligation for borrowing |
| 7 | `withdraw_collateral` | Remove collateral (health check enforced) |

### Lending
| # | Instruction | Description |
|---|-------------|-------------|
| 8 | `borrow` | Borrow against obligation collateral |
| 9 | `repay` | Repay outstanding borrow |
| 10 | `liquidate` | Liquidate underwater obligation |

### Flash Loans
| # | Instruction | Description |
|---|-------------|-------------|
| 11 | `flash_loan` | Atomic borrow + repay with fee |

### Interest & Oracle
| # | Instruction | Description |
|---|-------------|-------------|
| 12 | `refresh_reserve` | Accrue interest using two-slope model |
| 13 | `refresh_obligation` | Update obligation values with oracle price |

### PORT Rewards
| # | Instruction | Description |
|---|-------------|-------------|
| 14 | `claim_port_reward` | Claim accrued PORT mining rewards |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 15 | `set_reserve_config` | Update reserve parameters |
| 16 | `set_oracle` | Update oracle price feed |
| 17 | `collect_fees` | Withdraw protocol fees |
| 18 | `set_authority` | Transfer market authority |

## Accounts

- **Market** -- Global config with authority
- **Reserve** -- Per-token: two-slope rates (base + slope_1 + slope_2), flash loan fee, PORT mining rate
- **Obligation** -- Per-user: 3 deposit + 3 borrow slots, pending_port_reward, last_reward_slot
- **OraclePrice** -- Price feed with staleness tracking

## Key Math

- Two-slope rate: `rate = base + (util * slope_1 / optimal)` below kink, jumps to `base + slope_1 + (excess * slope_2 / remaining)` above
- Flash loan fee: `fee = amount * flash_loan_fee_bps / 10000`
- PORT reward: `reward = borrow_amount * mining_rate * slots_elapsed / 1e9`
