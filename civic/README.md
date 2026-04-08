# Civic Gateway / Identity Protocol -- 5ive DSL Migration

A complete migration of Civic's on-chain identity verification protocol to the 5ive DSL. Civic provides privacy-preserving identity through a Gatekeeper Network model: gatekeepers verify users off-chain, then issue on-chain gateway tokens that prove identity without revealing personal data.

## Architecture

```
GatekeeperNetwork (authority, config, fees)
    |
    +-- Gatekeeper (authorized verifier, staked bond)
    |       |
    |       +-- GatewayToken (PDA: "gateway_token" + network + owner)
    |               state: active | revoked | frozen | expired
    |               features: KYC | age_18+ | uniqueness | country
    |
    +-- VerificationResult (ephemeral, returned by verify functions)
```

## Accounts

| Account | Size | Description |
|---------|------|-------------|
| `GatekeeperNetwork` | 512 bytes | Network configuration, authority, fees, expiry rules, features mask |
| `Gatekeeper` | 256 bytes | Authorized verifier within a network, tracks issuance stats and stake |
| `GatewayToken` | 256 bytes | PDA-derived proof of verification for a wallet within a network |
| `VerificationResult` | 128 bytes | Ephemeral account for verification query results |

## Instructions (20 total)

### Network Management (8)

| Instruction | Signer | Description |
|-------------|--------|-------------|
| `create_network` | Authority | Create a new gatekeeper network with name, fees, expiry, features |
| `update_network` | Authority | Update network parameters (expiry, fees, metadata, features) |
| `close_network` | Authority | Permanently deactivate a network |
| `set_network_authority` | Authority | Transfer network ownership |
| `pause_network` | Authority | Emergency pause -- blocks all token operations |
| `unpause_network` | Authority | Restore paused network |
| `set_expiry_config` | Authority | Update default and max expiry durations |
| `set_token_fee` / `set_network_fee` | Authority | Configure fee schedules |

### Gatekeeper Management (4)

| Instruction | Signer | Description |
|-------------|--------|-------------|
| `add_gatekeeper` | Network Authority | Authorize a new gatekeeper for the network |
| `remove_gatekeeper` | Network Authority | Revoke gatekeeper authorization |
| `stake_gatekeeper` | Gatekeeper | Deposit bond tokens (slashable on misbehavior) |
| `unstake_gatekeeper` | Gatekeeper | Withdraw staked bond |

### Gateway Token Operations (5)

| Instruction | Signer | Description |
|-------------|--------|-------------|
| `issue_token` | Gatekeeper | Issue a gateway token to a verified wallet (PDA derived) |
| `refresh_token` | Gatekeeper | Extend token expiry after re-verification |
| `revoke_token` | Gatekeeper or Authority | Permanently revoke a gateway token |
| `freeze_token` | Gatekeeper or Authority | Temporarily freeze (investigation) |
| `unfreeze_token` | Gatekeeper or Authority | Restore a frozen token |
| `burn_token` | Token Owner | User-initiated permanent destruction |

### Verification (2)

| Instruction | Description |
|-------------|-------------|
| `verify_token` | Check if wallet has valid, non-expired, non-frozen token for a network |
| `verify_token_with_features` | Verify with bitwise feature flag check (KYC, age, uniqueness, etc.) |

### Fee Management (1)

| Instruction | Description |
|-------------|-------------|
| `collect_fees` | Gatekeeper withdraws accumulated issuance fees |

## Key Design Details

### Token States

- **0 (active)** -- Valid, passes verification
- **1 (revoked)** -- Permanently invalidated by gatekeeper/authority/owner
- **2 (frozen)** -- Temporarily suspended, can be unfrozen
- **3 (expired)** -- Past `expires_at` timestamp, can be refreshed

### Features Bitfield

Bit positions encode verification capabilities:

| Bit | Feature |
|-----|---------|
| 0 | KYC (Know Your Customer) |
| 1 | Age 18+ verification |
| 2 | Uniqueness (one-person-one-token) |
| 3 | Country check |

Verification uses bitwise AND: `(token.features & required_features) == required_features`

### PDA Derivation

Gateway tokens use deterministic addresses: `derive_pda("gateway_token", network_key, owner_key)`

This ensures one token per wallet per network and allows off-chain address computation.

### Fee Model

Two-tier fee structure on token issuance:
- **Token fee** -- Paid by user to the gatekeeper (incentivizes verification work)
- **Network fee** -- Paid by user to the network fee collector (protocol revenue)

### Authorization Model

- **Network authority** can: manage network config, add/remove gatekeepers, revoke/freeze tokens
- **Gatekeeper** can: issue/refresh/revoke/freeze tokens within their network
- **Token owner** can: burn their own token

## Build

```bash
five build
five deploy --cluster devnet
```

## Source Protocol

Civic Identity Gateway: https://www.civic.com/

Solana program: `gatem74V238djXdzWnJf94Wo1DcnuGkfijbf3AuBhfs`
