# SPL Core Programs — 5ive DSL Migration

Complete migration of the Solana Program Library (SPL) core programs to the 5ive DSL. This is a single-file implementation of the five foundational programs that every Solana application depends on.

## What This Is

The Solana Program Library is the **base layer** of the Solana ecosystem. Every token transfer, every DAO vote, every lending position, and every stake pool runs through these programs. This migration demonstrates that 5ive can replace Solana's own foundational infrastructure.

**39 on-chain instructions** across **5 core programs** in one file.

## Programs Included

### 1. SPL Token Program (11 instructions)

The standard fungible/non-fungible token program. Every token on Solana is an instance of this program.

| Instruction | Description |
|---|---|
| `initialize_mint` | Create a new token mint with decimals and authorities |
| `initialize_account` | Create a token account for a mint |
| `transfer` | Transfer tokens (owner or delegate) |
| `approve` | Approve a delegate to spend up to N tokens |
| `revoke` | Revoke delegate approval |
| `mint_to` | Mint new tokens (mint authority only) |
| `burn` | Burn tokens (owner or delegate) |
| `close_account` | Close account, reclaim SOL rent |
| `freeze_account` | Freeze a token account |
| `thaw_account` | Unfreeze a frozen account |
| `set_authority` | Change mint, freeze, owner, or close authority |

**Accounts:** `Mint`, `TokenAccount`

### 2. Associated Token Account (2 instructions)

Deterministic token account addresses using PDA derivation. Ensures every wallet has exactly one token account per mint.

| Instruction | Description |
|---|---|
| `create_associated_token_account` | Create ATA for wallet+mint via PDA |
| `recover_nested` | Recover tokens from a nested ATA |

**Uses:** `TokenAccount` (shared with Token Program)

### 3. SPL Token-Lending (8 instructions)

The original reference lending protocol. Solend, Port, and others forked from this.

| Instruction | Description |
|---|---|
| `init_lending_market` | Create lending market |
| `init_reserve` | Create reserve with interest rate config |
| `deposit_reserve_liquidity` | Deposit + receive cTokens |
| `redeem_reserve_collateral` | Burn cTokens + receive underlying |
| `borrow_obligation_liquidity` | Borrow against collateral |
| `repay_obligation_liquidity` | Repay borrowed tokens |
| `liquidate_obligation` | Liquidate unhealthy position |
| `flash_loan` | Borrow and repay in one tx |

**Accounts:** `LendingMarket`, `Reserve`, `Obligation`

### 4. SPL Governance (10 instructions)

On-chain DAO governance — the program behind Realms.

| Instruction | Description |
|---|---|
| `create_realm` | Create a governance realm |
| `deposit_governing_tokens` | Deposit tokens for voting power |
| `withdraw_governing_tokens` | Withdraw tokens |
| `create_proposal` | Create a governance proposal |
| `cast_vote` | Vote yes/no with token weight |
| `finalize_vote` | End voting, determine outcome |
| `execute_proposal` | Execute a passed proposal |
| `cancel_proposal` | Cancel (owner only, before voting ends) |
| `relinquish_vote` | Withdraw vote before voting ends |
| `set_governance_config` | Update governance parameters |

**Accounts:** `Realm`, `Proposal`, `VoteRecord`, `TokenOwnerRecord`

### 5. SPL Stake Pool (8 instructions)

Native SOL staking pool — pool tokens represent shares of staked SOL across validators.

| Instruction | Description |
|---|---|
| `initialize_stake_pool` | Create pool with fee config |
| `add_validator_to_pool` | Add validator to pool |
| `remove_validator_from_pool` | Remove validator |
| `deposit_stake` | Deposit SOL, receive pool tokens |
| `withdraw_stake` | Burn pool tokens, receive SOL |
| `update_validator_list_balance` | Epoch balance update + fee collection |
| `set_manager` | Transfer pool manager |
| `set_fee` | Update fee configuration |

**Accounts:** `StakePool`, `ValidatorStakeInfo`

## Architecture

All five programs live in a single 5ive file (`src/main.v`), sectioned with clear headers. Shared types (like `TokenAccount`) are reused across programs, mirroring how SPL programs interoperate on Solana.

Key patterns used:
- **CPI via `spl_token::SPLToken`** — Token transfers, mints, and burns use the standard 5ive CPI interface
- **PDA derivation via `derive_pda()`** — ATA addresses and validator stake info use deterministic PDAs
- **Clock intrinsics** — `get_clock().slot`, `get_clock().unix_timestamp`, `get_clock().epoch` for time-dependent logic
- **Two-slope interest rate model** — Lending uses a kink-based rate curve (internal helper functions)
- **Integer-only arithmetic** — All math uses u64/u128 with explicit scaling (WAD = 10^9)

## Comparison: Rust vs 5ive

| Metric | Solana Rust (SPL repo) | 5ive DSL |
|---|---|---|
| Files | ~200+ across 5 crates | 1 |
| Lines of code | ~15,000+ | ~850 |
| Build dependencies | 50+ crates | 1 (`@5ive/std`) |
| Account serialization | Manual Borsh | Declarative `account {}` |
| Error handling | Custom error enums | `require()` |
| CPI boilerplate | ~30 lines per call | 1 line per call |

## Build

```bash
five build
```

## Source

- Entry point: `src/main.v`
- Config: `five.toml`
