// 5IVE Star Atlas (SAGE) Migration
//
// On-chain game economy -- space exploration with fleet management, resource mining,
// crafting, marketplace, and staking. All items are SPL tokens.
//
// Key concept: time-based resource accrual. Fleet mining power determines yield rate.
// Fuel/food consumption over time. Voyages between starbases are time-gated.
//
// Fleet states: 0 = idle, 1 = mining, 2 = voyaging
//
// Instructions (22):
//   init_game, create_fleet, add_ship_to_fleet, remove_ship_from_fleet,
//   start_mining, stop_mining, claim_mining_rewards, start_voyage, complete_voyage,
//   refuel_fleet, repair_fleet, create_starbase, set_starbase_resources,
//   craft_item, list_on_marketplace, buy_from_marketplace, cancel_listing,
//   stake_atlas, unstake_atlas, claim_staking_rewards, set_authority, pause/unpause

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account GameConfig {
    authority: pubkey;
    atlas_mint: pubkey;
    polis_mint: pubkey;
    fuel_mint: pubkey;
    food_mint: pubkey;
    repair_mint: pubkey;
    num_starbases: u64;
    is_paused: bool;
}

account Fleet {
    owner: pubkey;
    game: pubkey;
    num_ships: u64;
    mining_power: u64;
    fuel_capacity: u64;
    current_fuel: u64;
    food_capacity: u64;
    current_food: u64;
    location: pubkey;
    state: u8;
    state_started_at: u64;
    destination: pubkey;
    total_repairs_needed: u64;
}

account Starbase {
    game: pubkey;
    name_hash: u64;
    resource_mint: pubkey;
    mining_rate: u64;
    position_x: i64;
    position_y: i64;
}

account Ship {
    fleet: pubkey;
    ship_type: u8;
    mining_bonus: u64;
    fuel_efficiency: u64;
    repair_cost: u64;
}

account MarketListing {
    game: pubkey;
    seller: pubkey;
    item_mint: pubkey;
    quantity: u64;
    price: u64;
    is_active: bool;
}

account StakeRecord {
    game: pubkey;
    owner: pubkey;
    staked_amount: u64;
    reward_debt: u64;
    pending_reward: u64;
    last_claim_slot: u64;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn calculate_distance(x1: i64, y1: i64, x2: i64, y2: i64) -> u64 {
    // Manhattan distance (integer-only, no sqrt needed)
    let mut dx: u64 = 0;
    if (x2 > x1) {
        dx = (x2 - x1) as u64;
    } else {
        dx = (x1 - x2) as u64;
    }

    let mut dy: u64 = 0;
    if (y2 > y1) {
        dy = (y2 - y1) as u64;
    } else {
        dy = (y1 - y2) as u64;
    }

    return dx + dy;
}

fn calculate_fuel_cost(distance: u64, num_ships: u64, fuel_efficiency: u64) -> u64 {
    // Fuel = distance * ships / efficiency (minimum 1)
    if (fuel_efficiency == 0) {
        return distance * num_ships;
    }
    let cost: u64 = (distance * num_ships) / fuel_efficiency;
    if (cost == 0) {
        return 1;
    }
    return cost;
}

fn calculate_food_cost(duration_slots: u64, num_ships: u64) -> u64 {
    // Food = 1 per ship per 100 slots
    let cost: u64 = (duration_slots * num_ships) / 100;
    if (cost == 0) {
        return 1;
    }
    return cost;
}

// ---------------------------------------------------------------------------
// Instructions -- Game init
// ---------------------------------------------------------------------------

pub init_game(
    game: GameConfig @mut @init(payer=authority, space=512),
    authority: account @signer,
    atlas_mint: pubkey,
    polis_mint: pubkey,
    fuel_mint: pubkey,
    food_mint: pubkey,
    repair_mint: pubkey
) {
    game.authority = authority.ctx.key;
    game.atlas_mint = atlas_mint;
    game.polis_mint = polis_mint;
    game.fuel_mint = fuel_mint;
    game.food_mint = food_mint;
    game.repair_mint = repair_mint;
    game.num_starbases = 0;
    game.is_paused = false;
}

// ---------------------------------------------------------------------------
// Instructions -- Fleet management
// ---------------------------------------------------------------------------

pub create_fleet(
    game: GameConfig,
    fleet: Fleet @mut @init(payer=owner, space=512),
    owner: account @signer,
    initial_location: pubkey
) {
    require(!game.is_paused);

    fleet.owner = owner.ctx.key;
    fleet.game = game.ctx.key;
    fleet.num_ships = 0;
    fleet.mining_power = 0;
    fleet.fuel_capacity = 0;
    fleet.current_fuel = 0;
    fleet.food_capacity = 0;
    fleet.current_food = 0;
    fleet.location = initial_location;
    fleet.state = 0;
    fleet.state_started_at = 0;
    fleet.destination = initial_location;
    fleet.total_repairs_needed = 0;
}

pub add_ship_to_fleet(
    game: GameConfig,
    fleet: Fleet @mut,
    ship: Ship @mut @init(payer=owner, space=256),
    owner: account @signer,
    ship_token_account: account @mut,
    fleet_ship_vault: account @mut,
    token_program: account,
    ship_type: u8,
    mining_bonus: u64,
    fuel_efficiency: u64,
    repair_cost: u64
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 0);

    // Transfer ship NFT/token to fleet
    spl_token::SPLToken::transfer(ship_token_account, fleet_ship_vault, owner, 1);

    ship.fleet = fleet.ctx.key;
    ship.ship_type = ship_type;
    ship.mining_bonus = mining_bonus;
    ship.fuel_efficiency = fuel_efficiency;
    ship.repair_cost = repair_cost;

    fleet.num_ships = fleet.num_ships + 1;
    fleet.mining_power = fleet.mining_power + mining_bonus;
    fleet.fuel_capacity = fleet.fuel_capacity + fuel_efficiency * 100;
    fleet.food_capacity = fleet.food_capacity + 100;
}

pub remove_ship_from_fleet(
    game: GameConfig,
    fleet: Fleet @mut @signer,
    ship: Ship @mut,
    owner: account @signer,
    fleet_ship_vault: account @mut,
    user_ship_account: account @mut,
    token_program: account
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 0);
    require(ship.fleet == fleet.ctx.key);
    require(fleet.num_ships > 0);

    spl_token::SPLToken::transfer(fleet_ship_vault, user_ship_account, fleet, 1);

    fleet.num_ships = fleet.num_ships - 1;
    if (fleet.mining_power >= ship.mining_bonus) {
        fleet.mining_power = fleet.mining_power - ship.mining_bonus;
    } else {
        fleet.mining_power = 0;
    }
    if (fleet.fuel_capacity >= ship.fuel_efficiency * 100) {
        fleet.fuel_capacity = fleet.fuel_capacity - ship.fuel_efficiency * 100;
    } else {
        fleet.fuel_capacity = 0;
    }
    if (fleet.food_capacity >= 100) {
        fleet.food_capacity = fleet.food_capacity - 100;
    } else {
        fleet.food_capacity = 0;
    }
}

// ---------------------------------------------------------------------------
// Instructions -- Mining
// ---------------------------------------------------------------------------

pub start_mining(
    game: GameConfig,
    fleet: Fleet @mut,
    starbase: Starbase,
    owner: account @signer
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 0);
    require(fleet.num_ships > 0);
    require(fleet.location == starbase.ctx.key);
    require(starbase.game == game.ctx.key);
    require(fleet.current_fuel > 0);
    require(fleet.current_food > 0);

    fleet.state = 1;
    fleet.state_started_at = get_clock().slot;
}

pub stop_mining(
    game: GameConfig,
    fleet: Fleet @mut,
    owner: account @signer
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 1);

    let now: u64 = get_clock().slot;
    let duration: u64 = now - fleet.state_started_at;

    // Consume food based on mining duration
    let food_cost: u64 = calculate_food_cost(duration, fleet.num_ships);
    if (fleet.current_food > food_cost) {
        fleet.current_food = fleet.current_food - food_cost;
    } else {
        fleet.current_food = 0;
    }

    // Mining causes wear -- track repair needs
    let wear: u64 = duration / 1000;
    fleet.total_repairs_needed = fleet.total_repairs_needed + wear;

    fleet.state = 0;
    fleet.state_started_at = 0;
}

pub claim_mining_rewards(
    game: GameConfig @signer,
    fleet: Fleet @mut,
    starbase: Starbase,
    owner: account @signer,
    resource_mint: account @mut,
    user_resource_account: account @mut,
    token_program: account
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 1);
    require(fleet.location == starbase.ctx.key);
    require(starbase.game == game.ctx.key);

    let now: u64 = get_clock().slot;
    let duration: u64 = now - fleet.state_started_at;

    // Reward = mining_power * mining_rate * duration / 1_000_000
    let reward: u64 = (fleet.mining_power * starbase.mining_rate * duration) / 1000000;
    require(reward > 0);

    // Mint resource tokens to player
    spl_token::SPLToken::mint_to(resource_mint, user_resource_account, game, reward);

    // Reset mining timer (rewards claimed up to now)
    fleet.state_started_at = now;
}

// ---------------------------------------------------------------------------
// Instructions -- Voyages (travel between starbases)
// ---------------------------------------------------------------------------

pub start_voyage(
    game: GameConfig,
    fleet: Fleet @mut,
    origin_starbase: Starbase,
    destination_starbase: Starbase,
    owner: account @signer
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 0);
    require(fleet.location == origin_starbase.ctx.key);
    require(origin_starbase.game == game.ctx.key);
    require(destination_starbase.game == game.ctx.key);

    // Calculate distance and fuel cost
    let distance: u64 = calculate_distance(
        origin_starbase.position_x,
        origin_starbase.position_y,
        destination_starbase.position_x,
        destination_starbase.position_y
    );
    require(distance > 0);

    let avg_efficiency: u64 = fleet.fuel_capacity / (fleet.num_ships * 100);
    let fuel_needed: u64 = calculate_fuel_cost(distance, fleet.num_ships, avg_efficiency);
    require(fleet.current_fuel >= fuel_needed);

    fleet.current_fuel = fleet.current_fuel - fuel_needed;
    fleet.state = 2;
    fleet.state_started_at = get_clock().slot;
    fleet.destination = destination_starbase.ctx.key;
}

pub complete_voyage(
    game: GameConfig,
    fleet: Fleet @mut,
    owner: account @signer
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 2);

    // Voyage takes time: minimum 100 slots per distance unit (simplified)
    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - fleet.state_started_at;
    // Minimum travel time check (simplified)
    require(elapsed >= 100);

    // Consume food during voyage
    let food_cost: u64 = calculate_food_cost(elapsed, fleet.num_ships);
    if (fleet.current_food > food_cost) {
        fleet.current_food = fleet.current_food - food_cost;
    } else {
        fleet.current_food = 0;
    }

    fleet.location = fleet.destination;
    fleet.state = 0;
    fleet.state_started_at = 0;
}

// ---------------------------------------------------------------------------
// Instructions -- Fleet maintenance
// ---------------------------------------------------------------------------

pub refuel_fleet(
    game: GameConfig,
    fleet: Fleet @mut,
    owner: account @signer,
    user_fuel_account: account @mut,
    game_fuel_vault: account @mut,
    token_program: account,
    fuel_amount: u64
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fuel_amount > 0);

    // Cannot exceed fuel capacity
    let new_fuel: u64 = fleet.current_fuel + fuel_amount;
    require(new_fuel <= fleet.fuel_capacity);

    // Burn fuel tokens (consumed)
    spl_token::SPLToken::burn(user_fuel_account, game_fuel_vault, owner, fuel_amount);

    fleet.current_fuel = new_fuel;
}

pub repair_fleet(
    game: GameConfig,
    fleet: Fleet @mut,
    owner: account @signer,
    user_repair_account: account @mut,
    game_repair_vault: account @mut,
    token_program: account,
    repair_amount: u64
) {
    require(!game.is_paused);
    require(fleet.game == game.ctx.key);
    require(fleet.owner == owner.ctx.key);
    require(fleet.state == 0);
    require(repair_amount > 0);
    require(repair_amount <= fleet.total_repairs_needed);

    // Burn repair kit tokens
    spl_token::SPLToken::burn(user_repair_account, game_repair_vault, owner, repair_amount);

    fleet.total_repairs_needed = fleet.total_repairs_needed - repair_amount;
}

// ---------------------------------------------------------------------------
// Instructions -- Starbase management (admin)
// ---------------------------------------------------------------------------

pub create_starbase(
    game: GameConfig @mut,
    starbase: Starbase @mut @init(payer=authority, space=384),
    authority: account @signer,
    name_hash: u64,
    resource_mint: pubkey,
    mining_rate: u64,
    position_x: i64,
    position_y: i64
) {
    require(game.authority == authority.ctx.key);
    require(mining_rate > 0);

    starbase.game = game.ctx.key;
    starbase.name_hash = name_hash;
    starbase.resource_mint = resource_mint;
    starbase.mining_rate = mining_rate;
    starbase.position_x = position_x;
    starbase.position_y = position_y;

    game.num_starbases = game.num_starbases + 1;
}

pub set_starbase_resources(
    game: GameConfig,
    starbase: Starbase @mut,
    authority: account @signer,
    resource_mint: pubkey,
    mining_rate: u64
) {
    require(game.authority == authority.ctx.key);
    require(starbase.game == game.ctx.key);
    require(mining_rate > 0);

    starbase.resource_mint = resource_mint;
    starbase.mining_rate = mining_rate;
}

// ---------------------------------------------------------------------------
// Instructions -- Crafting
// ---------------------------------------------------------------------------

pub craft_item(
    game: GameConfig @signer,
    owner: account @signer,
    input_resource_a: account @mut,
    input_resource_b: account @mut,
    input_mint_a: account @mut,
    input_mint_b: account @mut,
    output_mint: account @mut,
    user_output_account: account @mut,
    token_program: account,
    input_a_amount: u64,
    input_b_amount: u64,
    output_amount: u64
) {
    require(!game.is_paused);
    require(input_a_amount > 0);
    require(input_b_amount > 0);
    require(output_amount > 0);

    // Burn input resources
    spl_token::SPLToken::burn(input_resource_a, input_mint_a, owner, input_a_amount);
    spl_token::SPLToken::burn(input_resource_b, input_mint_b, owner, input_b_amount);

    // Mint output item
    spl_token::SPLToken::mint_to(output_mint, user_output_account, game, output_amount);
}

// ---------------------------------------------------------------------------
// Instructions -- Marketplace
// ---------------------------------------------------------------------------

pub list_on_marketplace(
    game: GameConfig,
    listing: MarketListing @mut @init(payer=seller, space=384),
    seller: account @signer,
    user_item_account: account @mut,
    escrow_vault: account @mut,
    token_program: account,
    item_mint: pubkey,
    quantity: u64,
    price: u64
) {
    require(!game.is_paused);
    require(quantity > 0);
    require(price > 0);

    // Transfer items to escrow
    spl_token::SPLToken::transfer(user_item_account, escrow_vault, seller, quantity);

    listing.game = game.ctx.key;
    listing.seller = seller.ctx.key;
    listing.item_mint = item_mint;
    listing.quantity = quantity;
    listing.price = price;
    listing.is_active = true;
}

pub buy_from_marketplace(
    game: GameConfig @signer,
    listing: MarketListing @mut,
    buyer: account @signer,
    buyer_payment: account @mut,
    seller_payment: account @mut,
    escrow_vault: account @mut,
    buyer_item_account: account @mut,
    token_program: account,
    quantity: u64
) {
    require(!game.is_paused);
    require(listing.game == game.ctx.key);
    require(listing.is_active);
    require(quantity > 0);
    require(quantity <= listing.quantity);

    let total_cost: u64 = quantity * listing.price;

    // Buyer pays seller
    spl_token::SPLToken::transfer(buyer_payment, seller_payment, buyer, total_cost);

    // Transfer items from escrow to buyer
    spl_token::SPLToken::transfer(escrow_vault, buyer_item_account, game, quantity);

    listing.quantity = listing.quantity - quantity;
    if (listing.quantity == 0) {
        listing.is_active = false;
    }
}

pub cancel_listing(
    game: GameConfig @signer,
    listing: MarketListing @mut,
    seller: account @signer,
    escrow_vault: account @mut,
    user_item_account: account @mut,
    token_program: account
) {
    require(listing.seller == seller.ctx.key);
    require(listing.game == game.ctx.key);
    require(listing.is_active);

    // Return items from escrow to seller
    spl_token::SPLToken::transfer(escrow_vault, user_item_account, game, listing.quantity);

    listing.is_active = false;
    listing.quantity = 0;
}

// ---------------------------------------------------------------------------
// Instructions -- ATLAS staking
// ---------------------------------------------------------------------------

pub stake_atlas(
    game: GameConfig,
    record: StakeRecord @mut @init(payer=owner, space=384),
    owner: account @signer,
    user_atlas_account: account @mut,
    stake_vault: account @mut,
    token_program: account,
    amount: u64
) {
    require(!game.is_paused);
    require(amount > 0);

    spl_token::SPLToken::transfer(user_atlas_account, stake_vault, owner, amount);

    record.game = game.ctx.key;
    record.owner = owner.ctx.key;
    record.staked_amount = record.staked_amount + amount;
    record.last_claim_slot = get_clock().slot;
}

pub unstake_atlas(
    game: GameConfig @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    stake_vault: account @mut,
    user_atlas_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(!game.is_paused);
    require(amount > 0);
    require(record.game == game.ctx.key);
    require(record.owner == owner.ctx.key);
    require(amount <= record.staked_amount);

    spl_token::SPLToken::transfer(stake_vault, user_atlas_account, game, amount);
    record.staked_amount = record.staked_amount - amount;
}

pub claim_staking_rewards(
    game: GameConfig @signer,
    record: StakeRecord @mut,
    owner: account @signer,
    reward_mint: account @mut,
    user_reward_account: account @mut,
    token_program: account
) {
    require(!game.is_paused);
    require(record.game == game.ctx.key);
    require(record.owner == owner.ctx.key);

    let now: u64 = get_clock().slot;
    let elapsed: u64 = now - record.last_claim_slot;
    require(elapsed > 0);

    // Reward = staked_amount * elapsed / 1_000_000 (POLIS governance tokens)
    let reward: u64 = (record.staked_amount * elapsed) / 1000000;
    require(reward > 0);

    spl_token::SPLToken::mint_to(reward_mint, user_reward_account, game, reward);

    record.pending_reward = 0;
    record.last_claim_slot = now;
}

// ---------------------------------------------------------------------------
// Instructions -- Admin
// ---------------------------------------------------------------------------

pub set_authority(
    game: GameConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(game.authority == authority.ctx.key);
    game.authority = new_authority;
}

pub pause_unpause(
    game: GameConfig @mut,
    authority: account @signer,
    paused: bool
) {
    require(game.authority == authority.ctx.key);
    game.is_paused = paused;
}
