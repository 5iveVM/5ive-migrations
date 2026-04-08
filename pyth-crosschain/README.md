# Pyth Crosschain Receiver -- 5ive DSL Migration

## Overview

This is a 5ive DSL migration of the **Pyth Crosschain Receiver**, the consumer-facing program that runs on **Solana mainnet** to receive and verify Wormhole-attested price updates originating from the Pyth Oracle on Pythnet.

This program is distinct from the Pyth Oracle itself (migrated in `../pyth/`). The oracle aggregates publisher prices on Pythnet; this receiver verifies those prices arrived intact via Wormhole and stores them for DeFi protocols to consume.

## Architecture

```
Pythnet Oracle
    |
    v
Wormhole Attester (creates signed VAAs)
    |
    v
Hermes (off-chain relay)
    |
    v
+----------------------------------+
| Pyth Crosschain Receiver (this)  |
| - Verifies guardian signatures   |
| - Validates data source          |
| - Writes PriceUpdateV2 / TWAP   |
+----------------------------------+
    |
    v
DeFi Protocols (Lending, AMMs, Perps)
```

## Accounts

| Account | Purpose | Size |
|---------|---------|------|
| `ReceiverConfig` | Admin, wormhole bridge address, fees, min signatures, active flag | 512 |
| `DataSource` | Authorized emitter chain + address for price data | 256 |
| `PriceUpdateV2` | Verified spot price + EMA with confidence, exponent, timestamps | 512 |
| `TwapUpdate` | Time-weighted average price with cumulative accumulators | 512 |
| `WormholeGuardianSet` | Read-only mirror of Wormhole guardian keys (up to 19) | CPI |
| `WormholeSignatureSet` | Read-only mirror of Wormhole verified signature bitmap | CPI |

## Instructions

### Initialization and Governance

| Instruction | Description |
|------------|-------------|
| `initialize` | Bootstrap receiver config with admin, wormhole address, fee, min signatures |
| `request_governance_authority_transfer` | Begin 2-step admin transfer |
| `cancel_governance_authority_transfer` | Cancel pending transfer |
| `accept_governance_authority_transfer` | New admin accepts transfer |

### Configuration (Admin Only)

| Instruction | Description |
|------------|-------------|
| `set_data_sources` | Register an authorized data source (emitter chain + address) |
| `revoke_data_source` | Remove an authorized data source |
| `set_fee` | Set per-update fee |
| `set_wormhole_address` | Update the Wormhole bridge address |
| `set_minimum_signatures` | Set minimum guardian signatures for full verification |
| `set_stale_grace_slots` | Configure staleness grace period for rent reclaim |
| `set_active` | Pause/unpause the receiver |

### Price Updates (Core)

| Instruction | Description |
|------------|-------------|
| `post_update_atomic` | Post new price with inline ed25519 verification (single tx) |
| `post_update` | Post new price using pre-verified Wormhole signature set |
| `update_price_feed` | Overwrite existing price (append-only, newer publish_time required) |
| `post_update_atomic_existing` | Atomic overwrite of existing price account |
| `post_twap_update` | Post a TWAP update with cumulative accumulators |
| `update_twap` | Overwrite existing TWAP (append-only, newer end_slot required) |

### Account Cleanup

| Instruction | Description |
|------------|-------------|
| `reclaim_rent` | Close stale PriceUpdateV2, reclaim rent (anyone can call) |
| `reclaim_twap_rent` | Close stale TwapUpdate, reclaim rent (anyone can call) |

### Consumer Queries

| Instruction | Description |
|------------|-------------|
| `get_price` | Read price with slot-based staleness check |
| `get_price_no_older_than` | Read price with timestamp-based staleness |
| `get_price_unsafe` | Read price without staleness check |
| `get_ema_price` | Read EMA price with slot-based staleness |
| `get_ema_price_no_older_than` | Read EMA price with timestamp-based staleness |
| `get_twap_price` | Read TWAP price with staleness check |
| `get_twap_price_unsafe` | Read TWAP without staleness check |

## Key Design Decisions

### Verification Levels

Two levels of verification exist:
- **Partial (0)**: Guardian signatures verified but below `min_signatures` threshold
- **Full (1)**: Meets or exceeds the `min_signatures` count

Both require Wormhole supermajority (2/3 + 1 of the guardian set). The `min_signatures` threshold is a *protocol-level* requirement on top of Wormhole's own threshold. DeFi protocols can choose to accept only full-verification prices.

### Append-Only Semantics

Price updates enforce strict temporal ordering: `publish_time` must be strictly greater than the stored value. This prevents stale-price attacks where an old (but validly signed) update overwrites a newer one.

### Two Update Paths

1. **Atomic**: Caller includes ed25519 precompile instructions in the same transaction. The receiver calls `verify_ed25519_instruction()` to confirm. More efficient (single tx).
2. **Two-step**: Caller first verifies signatures on the Wormhole bridge (creating a `SignatureSet`), then passes that verified set to the receiver. More flexible for batch operations.

### TWAP Computation

TWAP is computed from cumulative accumulators delivered in the VAA:
```
active_slots = end_slot - start_slot - num_down_slots
twap_price = cumulative_price / active_slots
twap_confidence = cumulative_confidence / active_slots
```

### Rent Reclaim

Anyone can reclaim rent from stale price/TWAP accounts after `stale_grace_slots` have passed since the last posting. This prevents permanent state bloat on Solana.

## Cross-Program References

This migration reads Wormhole accounts (`WormholeGuardianSet`, `WormholeSignatureSet`) as cross-program account types. It references the Wormhole bridge address stored in `ReceiverConfig.wormhole_bridge` to validate that signature sets belong to the correct bridge instance.

## Related Migrations

- `../pyth/` -- Pyth Oracle (Pythnet-side, publisher aggregation)
- `../wormhole/` -- Wormhole Core Bridge + Token Bridge
