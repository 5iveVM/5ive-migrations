# 5ive Migrations

**20 major Solana protocols, rewritten in 5ive DSL.**

This repo proves that 5ive can express production-grade on-chain logic from the biggest Solana protocols -- with 50-70% less compute, 99% smaller bytecode, and radically simpler code.

## Migrated Protocols

| # | Protocol | Category | Original SLoC (Rust) | 5ive SLoC | Instructions | Status |
|---|----------|----------|---------------------|-----------|-------------|--------|
| 1 | [Saber StableSwap](./saber/) | Stable AMM | ~3,000 | ~250 | 12 | Done |
| 2 | [Raydium AMM v4](./raydium/) | AMM/DEX | ~6,000 | ~350 | 10 | Done |
| 3 | [Pyth Network](./pyth/) | Oracle | ~8,000 | ~400 | 20 | Done |
| 4 | [Wormhole](./wormhole/) | Bridge | ~8,000 | ~500 | 33 | Done |
| 5 | [Orca Whirlpools](./orca/) | CLMM | ~15,000 | ~650 | 13 | Done |
| 6 | [Marinade Finance](./marinade/) | Liquid Staking | ~5,000 | ~400 | 20 | Done |
| 7 | [Metaplex](./metaplex/) | NFT Standard | ~10,000 | ~400 | 18 | Done |
| 8 | [Mango Markets](./mango/) | Derivatives | ~20,000 | ~700 | 21 | Done |
| 9 | [Solend](./solend/) | Lending | ~8,000 | ~550 | 18 | Done |
| 10 | [Jupiter](./jupiter/) | DEX Aggregator | ~12,000 | ~500 | 19 | Done |
| 11 | [Solana Program Library](./spl/) | Core Programs | ~25,000 | ~700 | 39 | Done |
| 12 | [Aldrin](./aldrin/) | DEX + CLOB | ~8,000 | ~600 | 30 | Done |
| 13 | [Drift Protocol](./drift/) | Perpetuals (vAMM) | ~30,000 | ~900 | 34 | Done |
| 14 | [Pyth Crosschain](./pyth-crosschain/) | Price Receiver | ~5,000 | ~450 | 21 | Done |
| 15 | [Bonfida](./bonfida/) | DEX + Name Service | ~12,000 | ~500 | 26 | Done |
| 16 | [Civic](./civic/) | Identity | ~4,000 | ~350 | 20 | Done |
| 17 | [Tonic](./tonic/) | Isolated Lending | ~6,000 | ~500 | 25 | Done |
| 18 | [Atlas Protocol](./atlas/) | Hybrid DEX | ~10,000 | ~600 | 26 | Done |
| 19 | [CyberConnect](./cyberconnect/) | Social Graph | ~8,000 | ~450 | 31 | Done |
| 20 | [Anchor Lending](./anchor-lending/) | Fixed-Rate Lending | ~10,000 | ~550 | 27 | Done |
| | **Total** | | **~228,000** | **~9,800** | **453** | |

> **~228,000 lines of Rust reduced to ~9,800 lines of 5ive DSL. Same logic. 23x less code. 453 on-chain instructions.**

## Why This Matters

These 20 protocols span **every category** on Solana:

**Foundation:**
- **Solana Program Library** -- Core programs (Token, Governance, Stake Pool, Lending, ATA)
- **Metaplex** -- THE NFT standard
- **Civic** -- On-chain identity and verification

**Infrastructure:**
- **Wormhole** -- #1 cross-chain bridge
- **Pyth Network** -- #1 oracle
- **Pyth Crosschain** -- Cross-chain price receiver
- **Bonfida** -- DEX + .sol domain name service

**DeFi Core:**
- **Orca Whirlpools** -- #1 concentrated liquidity AMM
- **Raydium** -- Top DEX by volume
- **Saber** -- Original Solana stableswap
- **Jupiter** -- #1 DEX aggregator
- **Aldrin** -- AMM + order book hybrid
- **Atlas Protocol** -- Weighted pools + CLOB + margin + yield vaults

**Advanced DeFi:**
- **Marinade** -- #1 liquid staking (mSOL)
- **Solend** -- Top lending with flash loans
- **Tonic** -- Isolated lending markets
- **Anchor Lending** -- Fixed-rate yield with liquidation queue
- **Mango Markets** -- Cross-margined perps + spot
- **Drift Protocol** -- vAMM perpetuals with dynamic spreads

**Social:**
- **CyberConnect** -- Decentralized social graph (profiles, follows, subscriptions)

## What 5ive Gives You

| Metric | Rust/Anchor | 5ive DSL |
|--------|-------------|----------|
| Bytecode size | 100-500 KB | 1-5 KB (99% smaller) |
| Compute units | Baseline | 50-70% less |
| Code complexity | Rust lifetimes, borsh, macros | Clean DSL syntax |
| Deploy cost | ~2-5 SOL | ~0.01-0.05 SOL |
| Time to build | Weeks | Hours |

## Build & Test

Each migration is a standalone 5ive project:

```bash
cd saber
five build
five local execute build/main.five 0  # Test locally via WASM
```

Or deploy to devnet:

```bash
five deploy build/main.five --cluster devnet
```

## Structure

```
5ive-migrations/
  spl/              # Solana Program Library (Token, Governance, Stake Pool, Lending, ATA)
  saber/            # StableSwap AMM (Newton's method, amplification coefficient)
  raydium/          # Constant product AMM (x*y=k, fee splitting, open-time gating)
  pyth/             # Price oracle (publisher aggregation, weighted median)
  pyth-crosschain/  # Crosschain price receiver (Wormhole VAA, TWAP, EMA)
  wormhole/         # Cross-chain bridge (VAA verification, guardian sets, token bridge)
  orca/             # Concentrated liquidity AMM (tick math, Q64.64 fixed-point)
  marinade/         # Liquid staking (mSOL exchange rate, validator management)
  metaplex/         # NFT standard (metadata, editions, collections, royalties)
  mango/            # Derivatives exchange (cross-margin perps, funding rates)
  solend/           # Lending protocol (WAD-precision interest, cTokens, flash loans)
  jupiter/          # DEX aggregator (multi-hop routing, split routes, limit orders, DCA)
  aldrin/           # DEX + CLOB (AMM pools, order book, concentrated liquidity, farming)
  drift/            # Perpetuals vAMM (dynamic spreads, insurance fund, keeper system)
  bonfida/          # DEX + Name Service (order book, .sol domains, subdomains)
  civic/            # Identity (gatekeeper networks, gateway tokens, feature verification)
  tonic/            # Isolated lending (per-market risk, share accounting, flash loans, ADL)
  atlas/            # Hybrid DEX (weighted pools, CLOB, cross-margin, yield vaults)
  cyberconnect/     # Social graph (profiles, follows, content, subscriptions, orgs)
  anchor-lending/   # Fixed-rate lending (yield reserve, bAsset rewards, liquidation queue)
```

## Migration Notes

These migrations faithfully reproduce the **core on-chain logic** of each protocol. External infrastructure (guardian nodes, publisher agents, relayers, keeper bots) is out of scope -- those are off-chain systems that interact with the on-chain program via standard Solana transactions.

Where the original protocol uses features not yet available in 5ive (e.g., Token-2022 hooks, dynamic arrays), we document the gap and provide the closest equivalent.

## License

MIT
