# 5ive-wormhole

Wormhole Cross-Chain Bridge migrated to 5ive DSL.

## What This Is

A faithful migration of the [Wormhole](https://wormhole.com/) cross-chain bridge protocol to 5ive DSL. Wormhole is the #1 cross-chain messaging bridge on Solana, with $2B+ in bridged value. This migration covers the **Core Bridge** (message posting, guardian signature verification, VAA processing) and the **Token Bridge** (native token locking/unlocking, wrapped token minting/burning).

## Architecture

### Core Bridge

The core bridge handles cross-chain message passing through a guardian network:

- **BridgeConfig** -- Global bridge state: guardian set index, fee, sequence counter
- **GuardianSet** -- The set of 19 guardian keys that sign cross-chain messages
- **PostedMessage** -- An outbound cross-chain message with emitter, sequence, payload hash
- **SignatureSet** -- Tracks which guardians have verified a given VAA hash
- **ClaimRecord** -- Replay protection: each VAA can only be processed once

**Flow:**
1. `post_message` -- User emits a message, gets a sequence number
2. `init_signature_set` + `verify_signatures` -- Off-chain guardians sign; on-chain verification records each signature
3. `post_vaa` -- Once 13/19 (supermajority) guardians verify, the VAA is finalized and a claim record prevents replay

### Token Bridge

The token bridge extends the core bridge for cross-chain token transfers:

- **TokenBridgeConfig** -- Token bridge state, linked to core bridge
- **ChainRegistration** -- Registered foreign chain endpoints
- **WrappedMeta** -- Metadata for wrapped (non-native) tokens
- **TransferRecord** -- Record of a cross-chain transfer

**Native tokens (lock/unlock):**
- `transfer_native` -- Lock SPL tokens in custody vault, emit bridge message
- `complete_native` -- Verify VAA, unlock tokens from custody to recipient

**Wrapped tokens (burn/mint):**
- `transfer_wrapped` -- Burn wrapped tokens, emit bridge message
- `complete_wrapped` -- Verify VAA, mint wrapped tokens to recipient

### Guardian Set Rotation

- `set_guardian_set` -- Governance action to rotate guardian keys
- Old guardian set gets a 24-hour grace period before expiration
- New set must have a strictly higher index than the current set

## Instructions

| # | Instruction | Category | Description |
|---|-------------|----------|-------------|
| 1 | `initialize` | Core | Set up bridge config |
| 2 | `init_guardian_set` | Core | Initialize guardian key set |
| 3 | `post_message` | Core | Emit cross-chain message |
| 4 | `init_signature_set` | Core | Create signature tracking account |
| 5 | `verify_signatures` | Core | Verify a guardian's signature |
| 6 | `post_vaa` | Core | Finalize a verified VAA |
| 7 | `set_guardian_set` | Governance | Rotate guardian set |
| 8 | `set_bridge_fee` | Admin | Update message fee |
| 9 | `set_bridge_active` | Admin | Pause/unpause bridge |
| 10 | `transfer_bridge_authority` | Admin | Transfer bridge ownership |
| 11 | `initialize_token_bridge` | Token | Set up token bridge |
| 12 | `register_chain` | Token | Register foreign chain endpoint |
| 13 | `transfer_native` | Token | Lock native tokens for bridging |
| 14 | `complete_native` | Token | Unlock native tokens from VAA |
| 15 | `transfer_wrapped` | Token | Burn wrapped tokens for bridging |
| 16 | `complete_wrapped` | Token | Mint wrapped tokens from VAA |
| 17 | `create_wrapped` | Token | Register wrapped asset metadata |
| 18 | `set_token_bridge_active` | Admin | Pause/unpause token bridge |
| 19 | `transfer_token_bridge_authority` | Admin | Transfer token bridge ownership |

Plus read-only query functions for all major state fields.

## Key Design Decisions

**Guardian keys as pubkeys:** Wormhole guardians use secp256k1/Ethereum keys. In 5ive, we map these to `pubkey` (32 bytes) which can represent any key material. The `verify_ed25519_instruction()` builtin handles on-chain signature verification.

**Per-field guardian storage:** Since 5ive does not have dynamic arrays, the 19 guardian keys and per-guardian verification booleans are stored as individual fields (`key_0` through `key_18`, `verified_0` through `verified_18`). Helper functions abstract the index-based access.

**Decimal normalization:** Wormhole normalizes all token amounts to 8 decimals for cross-chain consistency. The `transfer_wrapped` and `complete_wrapped` instructions handle normalization/denormalization.

**Supermajority:** The threshold is `(n * 2 / 3) + 1`, matching Wormhole's requirement of 13/19 guardians for verification.

## Build

```bash
five build
```

## Test

```bash
five test
```

## Original Protocol

- Wormhole source: https://github.com/wormhole-foundation/wormhole
- Solana core bridge: `solana/bridge/program/`
- Solana token bridge: `solana/modules/token_bridge/program/`
- Original Rust SLoC: ~8,000
- 5ive DSL SLoC: ~600

## License

MIT
