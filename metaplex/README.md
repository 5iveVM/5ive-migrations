# Metaplex Token Metadata — 5ive DSL Migration

A complete migration of the [Metaplex Token Metadata](https://github.com/metaplex-foundation/mpl-token-metadata) program to the 5ive DSL for 5iveVM.

## What This Is

Metaplex Token Metadata is THE NFT standard on Solana. It attaches rich metadata (name, symbol, URI, creators, royalties) to any SPL token — powering NFTs, semi-fungible tokens, and programmable NFTs across the ecosystem.

This migration faithfully reproduces the program's core instruction set and account model in idiomatic 5ive DSL.

## Accounts

| Account | Purpose | Space |
|---|---|---|
| `Metadata` | Name, symbol, URI, creators, royalties, collection link, uses | 1024 |
| `MasterEdition` | Tracks supply for master/limited edition NFTs | 256 |
| `EditionRecord` | Maps a numbered edition to its parent master | 256 |
| `CollectionDetails` | Collection authority, expected size, verified count | 256 |

## Instructions

### Core Metadata
| Instruction | Description |
|---|---|
| `create_metadata` | Attach metadata to a mint (name, symbol, URI, creators, royalties) |
| `update_metadata` | Update mutable metadata fields |
| `update_creators` | Reassign creator slots and shares (resets verification) |
| `mark_primary_sale` | Token holder marks primary sale as happened |

### Editions
| Instruction | Description |
|---|---|
| `create_master_edition` | Designate a NonFungible token as a master edition |
| `mint_edition` | Mint a sequential numbered edition from a master |

### Creator Verification
| Instruction | Description |
|---|---|
| `verify_creator` | Creator signs to prove legitimacy (slot 1-5) |
| `unverify_creator` | Creator removes their verification |

### Collections
| Instruction | Description |
|---|---|
| `create_collection` | Initialize collection details for a collection NFT |
| `verify_collection` | Collection authority verifies an NFT's membership |
| `unverify_collection` | Remove collection verification |
| `set_collection_size` | Update expected collection size |
| `update_collection_authority` | Transfer collection authority |

### Authority and Permissions
| Instruction | Description |
|---|---|
| `update_authority` | Transfer update authority to a new key |
| `revoke_authority` | Permanently make metadata immutable (irreversible) |

### Token Operations
| Instruction | Description |
|---|---|
| `freeze_delegated` | Delegate freezes a token account (pNFT custody) |
| `thaw_delegated` | Delegate thaws a frozen token account |
| `burn_nft` | Burn tokens via SPL Token CPI |
| `consume_use` | Consume uses from a token's use allocation |

### Read-Only Views
`get_metadata_mint`, `get_metadata_name`, `get_metadata_uri`, `get_seller_fee`, `get_token_standard`, `get_edition_supply`, `get_edition_max_supply`, `get_collection_size`, `get_collection_verified_count`, `get_uses_remaining`

## Token Standards

| Value | Standard | Description |
|---|---|---|
| 0 | NonFungible | Unique 1/1 NFT |
| 1 | FungibleAsset | Fungible token with metadata |
| 2 | Fungible | Standard fungible token |
| 3 | NonFungibleEdition | Numbered print from a master |

## Design Decisions

**Fixed creator slots** — Since 5ive DSL does not support dynamic arrays, creators are modeled as 5 fixed slots (`creator_1` through `creator_5`) with per-slot `share` and `verified` fields. Unused slots hold `pubkey(0)` with share `0`.

**Share validation** — Creator shares must always sum to exactly 100 (or all be zero when `num_creators` is 0).

**Edition immutability** — Editions minted from a master automatically have `is_mutable = false` and `token_standard = 3 (NonFungibleEdition)`. They inherit the parent's metadata at mint time.

**One-way flags** — `primary_sale_happened` can only go from `false` to `true`. `is_mutable` can only go from `true` to `false` via `revoke_authority`.

**Creator re-verification** — When creators are updated via `update_creators`, all verification flags reset to `false`. Each creator must re-sign to verify.

**SPL Token CPI** — Freeze, thaw, and burn operations delegate to `spl_token::SPLToken` via the standard 5ive CPI interface (`use std::interfaces::spl_token`).

## File Structure

```
metaplex/
  src/
    main.v    -- Complete token metadata program
  README.md   -- This file
```
