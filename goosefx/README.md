# 5ive GooseFX Migration

GooseFX (SSL AMM + perpetuals + GOFX staking) rewritten in 5ive DSL. Three modules: Single-Sided Liquidity pools with oracle-based pricing, perpetual futures with funding rates, and GOFX governance staking.

## What GooseFX Does

GooseFX is a DeFi suite on Solana combining three products:
1. **SSL AMM**: LPs deposit only ONE token (not a pair). Protocol uses oracle price for swaps. Less impermanent loss than traditional AMMs.
2. **Perpetual futures**: Long/short with margin, funding rates, and liquidation.
3. **GOFX staking**: Stake GOFX tokens for protocol revenue sharing.

### Core Concepts

- **Single-Sided Liquidity**: Deposit one token, earn yield from both sides of trades. Oracle determines fair price.
- **Perp funding**: Periodic funding payments from longs to shorts (or vice versa) to keep mark price close to index.
- **Margin**: Perp positions require maintenance margin; liquidatable when margin drops below requirement.
- **Staking rewards**: MasterChef-style reward distribution proportional to staked amount and time.

## Instructions Implemented

### SSL Pool
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `create_ssl_pool` | Create single-token pool with oracle and fee |
| 2 | `deposit_ssl` | Deposit tokens, receive shares |
| 3 | `withdraw_ssl` | Burn shares, withdraw tokens |
| 4 | `ssl_swap` | Oracle-priced swap between two SSL pools |

### Perpetuals
| # | Instruction | Description |
|---|-------------|-------------|
| 5 | `create_perp_market` | Create perp market with oracle and funding config |
| 6 | `open_perp_position` | Open long/short with margin deposit |
| 7 | `close_perp_position` | Close position, settle PnL + funding |
| 8 | `place_perp_order` | Increase position size (weighted avg entry) |
| 9 | `cancel_perp_order` | Reduce position size |
| 10 | `settle_funding` | Calculate and apply funding rate |
| 11 | `liquidate_perp` | Liquidate undercollateralized position |
| 12 | `deposit_margin` | Add margin to position |
| 13 | `withdraw_margin` | Remove margin (maintenance check enforced) |

### GOFX Staking
| # | Instruction | Description |
|---|-------------|-------------|
| 14 | `create_staking_pool` | Create GOFX staking pool with reward rate |
| 15 | `stake_gofx` | Stake tokens, accrue pending rewards |
| 16 | `unstake_gofx` | Unstake tokens |
| 17 | `claim_staking_rewards` | Claim accumulated rewards |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 18 | `set_ssl_params` | Update SSL pool fee and oracle price |
| 19 | `set_authority` | Transfer authority |
| 20 | `pause_unpause` | Pause/unpause SSL pool |

## Accounts

- **SSLPool** -- token_mint, vault, oracle, total_deposited, virtual_price, fee_bps
- **SSLPosition** -- pool, owner, deposited, shares
- **PerpMarket** -- oracle, funding_rate, open_interest_long/short, cumulative_funding, maintenance_margin_bps, taker_fee_bps
- **PerpPosition** -- market, owner, size (i64), entry_price, margin, last_funding_index
- **StakingPool** -- gofx_mint, stake_vault, reward_vault, total_staked, reward_per_share
- **StakeRecord** -- pool, owner, staked_amount, reward_debt, pending_reward

## Key Math

- SSL swap: `amount_out = amount_after_fee * price_in / price_out` (oracle-based)
- Perp PnL (long): `pnl = size * (exit_price - entry_price)`
- Funding: imbalance-based rate applied to cumulative index
- Staking: MasterChef `reward_per_share += new_rewards * 1e9 / total_staked`
