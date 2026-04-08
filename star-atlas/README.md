# 5ive Star Atlas (SAGE) Migration

Star Atlas SAGE (on-chain space game economy) rewritten in 5ive DSL. Fleet management, time-based resource mining, interstellar voyages, crafting, marketplace, and ATLAS staking. All items are SPL tokens.

## What Star Atlas SAGE Does

Star Atlas is an on-chain space exploration game where players build fleets of ships, mine resources at starbases, travel between locations, craft equipment, and trade on a marketplace. The economy runs on two tokens: ATLAS (utility/currency) and POLIS (governance).

### Core Concepts

- **Time-based accrual**: Mining rewards accumulate based on fleet mining power * starbase mining rate * time elapsed
- **Fleet states**: Idle (0), Mining (1), Voyaging (2). State transitions are time-gated.
- **Fuel/food consumption**: Fleets consume fuel for voyages and food over time. Must be replenished.
- **Starbases**: Locations in 2D space with mineable resources. Distance = Manhattan distance.
- **All items are SPL tokens**: Ships, resources, fuel, food, repair kits -- all standard SPL tokens.

## Instructions Implemented

### Game Setup
| # | Instruction | Description |
|---|-------------|-------------|
| 1 | `init_game` | Create game config with resource mints |

### Fleet Management
| # | Instruction | Description |
|---|-------------|-------------|
| 2 | `create_fleet` | Create empty fleet at a location |
| 3 | `add_ship_to_fleet` | Add ship (with stats) to fleet |
| 4 | `remove_ship_from_fleet` | Remove ship from fleet (must be idle) |

### Mining
| # | Instruction | Description |
|---|-------------|-------------|
| 5 | `start_mining` | Begin mining at current starbase |
| 6 | `stop_mining` | Stop mining, consume food, accrue wear |
| 7 | `claim_mining_rewards` | Mint resource tokens based on power * rate * time |

### Voyages
| # | Instruction | Description |
|---|-------------|-------------|
| 8 | `start_voyage` | Travel to destination starbase (consumes fuel) |
| 9 | `complete_voyage` | Arrive at destination (time-gated, consumes food) |

### Fleet Maintenance
| # | Instruction | Description |
|---|-------------|-------------|
| 10 | `refuel_fleet` | Burn fuel tokens to replenish fleet fuel |
| 11 | `repair_fleet` | Burn repair kit tokens to fix wear damage |

### World Building (Admin)
| # | Instruction | Description |
|---|-------------|-------------|
| 12 | `create_starbase` | Create a starbase at (x, y) with resource + mining rate |
| 13 | `set_starbase_resources` | Update what resource a starbase mines |

### Crafting
| # | Instruction | Description |
|---|-------------|-------------|
| 14 | `craft_item` | Burn input resources, mint output item |

### Marketplace
| # | Instruction | Description |
|---|-------------|-------------|
| 15 | `list_on_marketplace` | List items for sale (escrowed) |
| 16 | `buy_from_marketplace` | Buy listed items, pay seller |
| 17 | `cancel_listing` | Cancel listing, return escrowed items |

### ATLAS Staking
| # | Instruction | Description |
|---|-------------|-------------|
| 18 | `stake_atlas` | Stake ATLAS tokens |
| 19 | `unstake_atlas` | Unstake ATLAS tokens |
| 20 | `claim_staking_rewards` | Claim POLIS governance token rewards |

### Admin
| # | Instruction | Description |
|---|-------------|-------------|
| 21 | `set_authority` | Transfer game authority |
| 22 | `pause_unpause` | Pause/unpause the game |

## Accounts

- **GameConfig** -- authority, atlas/polis/fuel/food/repair mints, num_starbases, is_paused
- **Fleet** -- owner, game, num_ships, mining_power, fuel/food capacity + current, location, state (u8), state_started_at, destination
- **Starbase** -- game, name_hash, resource_mint, mining_rate, position_x/y (i64)
- **Ship** -- fleet, ship_type (u8), mining_bonus, fuel_efficiency, repair_cost
- **MarketListing** -- game, seller, item_mint, quantity, price, is_active
- **StakeRecord** -- game, owner, staked_amount, reward_debt, pending_reward

## Key Math

- Mining reward: `reward = mining_power * mining_rate * duration / 1_000_000`
- Distance: Manhattan `|x1-x2| + |y1-y2|`
- Fuel cost: `fuel = distance * num_ships / fuel_efficiency`
- Food cost: `food = duration * num_ships / 100`
- Staking reward: `reward = staked_amount * elapsed / 1_000_000` (minted as POLIS)
