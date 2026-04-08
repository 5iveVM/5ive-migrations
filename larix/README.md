# Larix Lending + Fractional Protocol

A 5ive DSL migration of the Larix lending protocol -- lending with LARIX mining incentives and NFT fractionalization support, including fractional tokens as lending collateral.

## Overview

Larix combines a utilization-based lending market (inspired by Solend/Aave v2) with NFT fractionalization. Users earn LARIX token rewards proportional to their deposits, and fractional NFT tokens can be used as collateral for borrowing.

## Architecture

### Accounts

| Account | Description |
|---------|-------------|
| **Market** | Top-level lending market: admin, oracle ref, pause state |
| **Reserve** | Per-token reserve: liquidity, collateral, interest config, mining rate, accumulated rewards |
| **UserAccount** | Per-user obligation: deposited value, borrowed value, mining reward tracking |
| **PriceOracle** | Price feed: price, decimals, staleness tracking |
| **FractionVault** | NFT vault: locked NFT, fraction mint, auction state, bids |
| **Bid** | Auction bid: vault ref, bidder, amount |

### Auction State Codes

- `0` -- No auction
- `1` -- Active auction
- `2` -- Settled

## Instructions (22)

### Lending Core
1. `init_market` -- Initialize a new lending market
2. `init_reserve` -- Initialize a reserve for a token within a market
3. `deposit` -- Deposit liquidity, receive cTokens
4. `withdraw` -- Burn cTokens, withdraw liquidity (with health check)
5. `borrow` -- Borrow against collateral (LTV enforced)
6. `repay` -- Repay borrowed liquidity
7. `liquidate` -- Liquidate undercollateralized positions (with bonus)
8. `refresh_reserve` -- Accrue interest and mining rewards

### Mining Rewards
9. `claim_mining_reward` -- Claim accumulated LARIX token rewards
10. `set_mining_rate` -- Admin sets reward emission rate per reserve

### NFT Fractionalization
11. `create_fraction_vault` -- Lock NFT, mint fractional tokens
12. `redeem_fractions` -- Burn all fractions to unlock the NFT
13. `start_auction` -- Initiate a buyout auction for a fractioned NFT
14. `place_bid` -- Place a bid on an active auction
15. `buyout_vault` -- Direct buyout of a fractioned NFT
16. `settle_auction` -- Settle auction after it ends
17. `claim_auction_proceeds` -- Fraction holder claims proportional share of proceeds

### Fractional Collateral
18. `deposit_fractions_as_collateral` -- Use fractional tokens as lending collateral
19. `withdraw_fraction_collateral` -- Remove fractional collateral (with health check)

### Admin
20. `set_oracle` / `update_oracle` -- Configure and update price oracle
21. `set_authority` -- Transfer market admin
22. `set_paused` -- Pause or unpause the market

## Interest Rate Model

Uses a two-slope kink model:
- Below optimal utilization: rate increases linearly from `min_borrow_rate`
- Above optimal utilization: rate accelerates toward `max_borrow_rate` and beyond
- Protocol takes a `reserve_factor` cut of interest for fees

## Mining Model

- Each reserve has a `mining_rate` (LARIX tokens per slot)
- Rewards accumulate proportionally to collateral supply share
- Users must claim rewards explicitly via `claim_mining_reward`
- Mining rate can be adjusted by admin without losing accrued rewards

## Build

```bash
5ive build larix/src/main.v
```
