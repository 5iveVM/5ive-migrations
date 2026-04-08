# Tonic Lending Protocol - 5ive DSL Migration

Tonic is an isolated lending market protocol on Solana. Unlike shared-pool protocols (Solend, Aave), each Tonic market is a standalone pool for exactly one collateral token and one borrow token. This design isolates risk: a bad oracle or token crash in one market cannot affect any other.

## Architecture

### Isolated Market Model

Each `IsolatedMarket` operates independently with its own:
- Token pair (collateral mint + borrow mint)
- Vaults (collateral vault + borrow vault)
- Oracle price feed
- Risk parameters (LTV, liquidation threshold, liquidation bonus)
- Interest rate model (two-slope kink)
- Interest indices (borrow + supply, scaled 10^18)

Markets can be permissionlessly created by anyone via `create_market`.

### Account Structure

| Account | Purpose |
|---------|---------|
| `GlobalConfig` | Protocol-wide admin, fee params, pause state |
| `IsolatedMarket` | Per-market state: reserves, indices, risk params, interest model |
| `UserPosition` | Per-user-per-market: collateral, borrow shares, supply shares |
| `FlashLoanReceipt` | Ephemeral receipt for flash loan borrow/repay verification |
| `OraclePrice` | Cached price feed for health calculations |

### Interest Rate Model

Two-slope kink model (all values in bps where 10000 = 100%):

```
If utilization <= optimal:
  borrow_rate = base_rate + (utilization * slope1) / 10000

If utilization > optimal:
  borrow_rate = base_rate + slope1 + ((utilization - optimal) * slope2) / (10000 - optimal)

supply_rate = borrow_rate * utilization * (10000 - protocol_fee_bps) / (10000 * 10000)
```

Interest compounds per-slot via index accrual:
```
new_borrow_index = old_borrow_index * (10^18 + rate_per_slot * slots_elapsed) / 10^18
```

### Share-Based Accounting

Deposits and borrows are tracked as shares against growing indices:
- `deposit_shares = amount * 10^18 / supply_index`
- `withdraw_amount = shares * supply_index / 10^18`

This ensures interest accrues correctly without per-user updates.

## Instructions

### Market Management
| Instruction | Description |
|-------------|-------------|
| `init_global_config` | Initialize protocol-wide config (admin, fees, thresholds) |
| `set_global_config` | Update global fee/threshold parameters |
| `set_admin` | Transfer admin authority |
| `create_market` | Create a new isolated lending market |
| `update_market_config` | Update risk params and interest model for a market |
| `set_market_oracle` | Change the oracle for a market |
| `close_market` | Deprecate a market (no new deposits/borrows) |
| `pause_market` / `unpause_market` | Emergency controls |

### Supply Side
| Instruction | Description |
|-------------|-------------|
| `deposit_collateral` | Deposit collateral tokens into a market |
| `withdraw_collateral` | Withdraw collateral (health check enforced) |
| `deposit_borrow_token` | Lenders supply borrow-side tokens (earn interest) |
| `withdraw_borrow_token` | Lenders withdraw supplied tokens + accrued interest |

### Borrowing
| Instruction | Description |
|-------------|-------------|
| `borrow` | Borrow against deposited collateral (LTV + utilization checks) |
| `repay` | Repay borrowed tokens (partial or full, clamped to outstanding) |

### Interest & Oracle
| Instruction | Description |
|-------------|-------------|
| `accrue_interest` | Permissionless crank: update indices and rates for a market |
| `init_oracle` | Initialize oracle price account |
| `refresh_oracle` | Update cached oracle prices |

### Liquidation
| Instruction | Description |
|-------------|-------------|
| `liquidate` | Liquidate unhealthy position (max 50%, liquidator gets bonus) |
| `liquidate_with_protocol_fee` | Liquidation where protocol takes a cut of the bonus |

### Flash Loans
| Instruction | Description |
|-------------|-------------|
| `flash_borrow` | Borrow without collateral (must repay + fee in same slot) |
| `flash_repay` | Verify and complete flash loan repayment |

### Emergency
| Instruction | Description |
|-------------|-------------|
| `auto_deleverage` | Force-close positions when utilization exceeds emergency threshold |

### Admin
| Instruction | Description |
|-------------|-------------|
| `collect_protocol_fees` | Withdraw accumulated protocol fees (borrow + collateral side) |

### Read-Only Helpers
| Instruction | Description |
|-------------|-------------|
| `get_utilization` | Calculate utilization in bps |
| `get_borrow_rate` | Calculate borrow rate from model params |
| `get_supply_rate` | Calculate supply rate |
| `get_position_health` | Get health factor for a position (bps, >= 10000 = healthy) |
| `get_outstanding_borrow` | Get current borrow amount including accrued interest |
| `get_supply_value` | Get current supply value including accrued interest |

## Key Safety Properties

1. **Isolation**: Each market is independent. No cross-collateral risk.
2. **Oracle staleness**: All price-dependent operations enforce a 100-slot freshness window.
3. **Liquidation cap**: Max 50% of a position can be liquidated per transaction.
4. **Utilization cap**: Borrows are rejected if they would push utilization above `max_utilization`.
5. **Auto-deleverage**: Emergency circuit breaker when utilization exceeds the ADL threshold.
6. **Share accounting**: Interest accrues via index growth, eliminating per-user update requirements.
7. **Flash loan atomicity**: Receipts enforce same-slot repayment.

## Build

```bash
five build
```

## Source

- Entry point: `src/main.v`
- Config: `five.toml`
