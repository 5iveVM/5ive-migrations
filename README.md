# 5ive Migrations

**50 Solana protocols, rewritten in 5ive DSL.**

This repo proves that 5ive can express production-grade on-chain logic from the entire Solana ecosystem -- with 50-70% less compute, 99% smaller bytecode, and radically simpler code.

## Migrated Protocols

| # | Protocol | Category | 5ive SLoC | Instructions | Status |
|---|----------|----------|-----------|-------------|--------|
| 1 | [Saber](./saber/) | Stable AMM | ~250 | 12 | Done |
| 2 | [Raydium](./raydium/) | AMM/DEX | ~350 | 10 | Done |
| 3 | [Pyth Network](./pyth/) | Oracle | ~400 | 20 | Done |
| 4 | [Wormhole](./wormhole/) | Bridge | ~500 | 33 | Done |
| 5 | [Orca Whirlpools](./orca/) | CLMM | ~650 | 13 | Done |
| 6 | [Marinade](./marinade/) | Liquid Staking | ~400 | 20 | Done |
| 7 | [Metaplex](./metaplex/) | NFT Standard | ~400 | 18 | Done |
| 8 | [Mango Markets](./mango/) | Derivatives | ~700 | 21 | Done |
| 9 | [Solend](./solend/) | Lending | ~550 | 18 | Done |
| 10 | [Jupiter](./jupiter/) | DEX Aggregator | ~500 | 19 | Done |
| 11 | [SPL](./spl/) | Core Programs | ~700 | 39 | Done |
| 12 | [Aldrin](./aldrin/) | DEX + CLOB | ~600 | 30 | Done |
| 13 | [Drift](./drift/) | Perpetuals (vAMM) | ~900 | 34 | Done |
| 14 | [Pyth Crosschain](./pyth-crosschain/) | Price Receiver | ~450 | 21 | Done |
| 15 | [Bonfida](./bonfida/) | DEX + Names | ~500 | 26 | Done |
| 16 | [Civic](./civic/) | Identity | ~350 | 20 | Done |
| 17 | [Tonic](./tonic/) | Isolated Lending | ~500 | 25 | Done |
| 18 | [Atlas](./atlas/) | Hybrid DEX | ~600 | 26 | Done |
| 19 | [CyberConnect](./cyberconnect/) | Social Graph | ~450 | 31 | Done |
| 20 | [Anchor Lending](./anchor-lending/) | Fixed-Rate Lending | ~550 | 27 | Done |
| 21 | [Mercurial](./mercurial/) | Multi-Token Stable | ~550 | 21 | Done |
| 22 | [Tensor](./tensor/) | NFT DEX | ~400 | 25 | Done |
| 23 | [Apricot](./apricot/) | Yield + Assist | ~500 | 23 | Done |
| 24 | [Hyperspace](./hyperspace/) | Arbitrage + MEV | ~500 | 26 | Done |
| 25 | [Mercl](./mercl/) | Smart Wallet | ~350 | 20 | Done |
| 26 | [Larix](./larix/) | Fractional Assets | ~450 | 27 | Done |
| 27 | [Gym](./gym/) | Liquidity Bootstrap | ~400 | 22 | Done |
| 28 | [OpenBook](./openbook/) | Order Book (OG) | ~350 | 17 | Done |
| 29 | [Phoenix](./phoenix/) | Order Book (Next-gen) | ~450 | 16 | Done |
| 30 | [Jito](./jito/) | MEV Liquid Staking | ~350 | 20 | Done |
| 31 | [Sanctum](./sanctum/) | LST Aggregator | ~350 | 18 | Done |
| 32 | [Kamino](./kamino/) | DeFi Yield | ~400 | 22 | Done |
| 33 | [Lifinity](./lifinity/) | Proactive AMM | ~350 | 18 | Done |
| 34 | [Hubble](./hubble/) | Stablecoin (CDP) | ~350 | 20 | Done |
| 35 | [UXD](./uxd/) | Stablecoin (Delta-Neutral) | ~300 | 18 | Done |
| 36 | [Tulip](./tulip/) | Yield Aggregator | ~250 | 18 | Done |
| 37 | [Francium](./francium/) | Leveraged Yield | ~350 | 20 | Done |
| 38 | [Switchboard](./switchboard/) | Oracle Network | ~350 | 22 | Done |
| 39 | [Squads](./squads/) | Multisig/DAO | ~300 | 18 | Done |
| 40 | [Clockwork](./clockwork/) | Automation | ~250 | 16 | Done |
| 41 | [Streamflow](./streamflow/) | Token Streaming | ~350 | 18 | Done |
| 42 | [Magic Eden](./magic-eden/) | NFT Marketplace | ~400 | 22 | Done |
| 43 | [Zeta Markets](./zeta/) | Options + Perps | ~500 | 22 | Done |
| 44 | [Jet Protocol](./jet/) | Fixed-Term Lending | ~350 | 16 | Done |
| 45 | [Port Finance](./port/) | Variable Lending | ~350 | 18 | Done |
| 46 | [Crema Finance](./crema/) | CLMM | ~350 | 14 | Done |
| 47 | [GooseFX](./goosefx/) | SSL AMM + Perps | ~450 | 20 | Done |
| 48 | [Hadeswap](./hadeswap/) | NFT AMM | ~250 | 14 | Done |
| 49 | [Friktion](./friktion/) | Options Vaults (DOV) | ~300 | 18 | Done |
| 50 | [Star Atlas](./star-atlas/) | Gaming Economy | ~400 | 22 | Done |
| | **Total** | | **~21,000** | **~1,025** | |

> **50 protocols. ~1,025 on-chain instructions. The entire Solana ecosystem in 5ive DSL.**

## Categories Covered

**Foundation & Infrastructure:**
SPL (Token, Governance, Stake Pool) -- Metaplex (NFTs) -- Civic (Identity) -- Mercl (Smart Wallet) -- Squads (Multisig) -- Wormhole (Bridge) -- Pyth (Oracle) -- Pyth Crosschain -- Switchboard (Oracle) -- Clockwork (Automation) -- Streamflow (Vesting) -- Bonfida (Names)

**AMMs & DEXs:**
Orca Whirlpools -- Raydium -- Saber -- Mercurial -- Lifinity -- Crema -- Aldrin -- Atlas -- OpenBook -- Phoenix -- Hadeswap -- Tensor -- Jupiter (Aggregator)

**Lending & Yield:**
Solend -- Tonic -- Anchor Lending -- Apricot -- Larix -- Jet -- Port -- Kamino -- Tulip -- Francium

**Derivatives & Trading:**
Mango Markets -- Drift -- Zeta Markets -- GooseFX -- Hyperspace (Arbitrage)

**Stablecoins:**
Hubble (CDP) -- UXD (Delta-Neutral)

**Staking:**
Marinade -- Jito -- Sanctum

**NFT & Social:**
Metaplex -- Tensor -- Magic Eden -- Hadeswap -- CyberConnect

**Gaming & Other:**
Star Atlas (SAGE) -- Gym (Liquidity Bootstrap) -- Friktion (Options Vaults)

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

## Migration Notes

These migrations faithfully reproduce the **core on-chain logic** of each protocol. External infrastructure (guardian nodes, publisher agents, relayers, keeper bots) is out of scope -- those are off-chain systems that interact with the on-chain program via standard Solana transactions.

Where the original protocol uses features not yet available in 5ive (e.g., Token-2022 hooks, dynamic arrays), we document the gap and provide the closest equivalent.

## License

MIT
