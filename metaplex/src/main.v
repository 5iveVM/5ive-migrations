// 5IVE Token Metadata Program — Metaplex Token Metadata migration
//
// Implements the Metaplex Token Metadata standard on 5iveVM:
//   - Metadata creation and update for any SPL token (NFTs, SFTs, pNFTs)
//   - Master edition tracking for 1/1 and limited edition NFTs
//   - Sequential numbered edition minting from master editions
//   - Creator verification (up to 5 creators, shares must sum to 100)
//   - Collection management with verified membership
//   - Authority transfer and permanent immutability via revocation
//   - Delegated freeze/thaw for programmable NFT custody
//   - NFT burn with metadata cleanup
//
// Token standards:
//   0 = NonFungible        (1/1 unique NFT)
//   1 = FungibleAsset      (fungible with metadata)
//   2 = Fungible           (standard fungible token)
//   3 = NonFungibleEdition (numbered print from a master)

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account Metadata {
    mint: pubkey;
    update_authority: pubkey;
    name: string<32>;
    symbol: string<10>;
    uri: string<200>;
    seller_fee_basis_points: u16;
    is_mutable: bool;
    primary_sale_happened: bool;
    token_standard: u8;

    // Collection linkage
    collection_key: pubkey;
    collection_verified: bool;

    // Creators (fixed 5 slots; unused slots hold pubkey(0) / share 0)
    num_creators: u8;
    creator_1: pubkey;
    creator_share_1: u8;
    creator_verified_1: bool;
    creator_2: pubkey;
    creator_share_2: u8;
    creator_verified_2: bool;
    creator_3: pubkey;
    creator_share_3: u8;
    creator_verified_3: bool;
    creator_4: pubkey;
    creator_share_4: u8;
    creator_verified_4: bool;
    creator_5: pubkey;
    creator_share_5: u8;
    creator_verified_5: bool;

    // Uses (optional utility tracking)
    uses_remaining: u64;
    uses_total: u64;
}

account MasterEdition {
    mint: pubkey;
    supply: u64;
    max_supply: u64;
}

account EditionRecord {
    parent_mint: pubkey;
    mint: pubkey;
    edition_number: u64;
}

account CollectionDetails {
    mint: pubkey;
    authority: pubkey;
    size: u64;
    num_verified: u64;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn validate_creator_shares(
    num: u8,
    s1: u8, s2: u8, s3: u8, s4: u8, s5: u8
) -> bool {
    let total: u64 = s1 as u64 + s2 as u64 + s3 as u64 + s4 as u64 + s5 as u64;
    if (num == 0) {
        return total == 0;
    }
    return total == 100;
}

fn validate_basis_points(bps: u16) -> bool {
    // Max 100% = 10000 basis points
    return bps as u64 <= 10000;
}

fn validate_token_standard(standard: u8) -> bool {
    return standard as u64 <= 3;
}

// ---------------------------------------------------------------------------
// 1. Create Metadata
// ---------------------------------------------------------------------------

pub create_metadata(
    metadata: Metadata @mut @init(payer=payer, space=1024),
    payer: account @mut @signer,
    mint_authority: account @signer,
    mint: spl_token::Mint @serializer("raw"),
    update_authority: pubkey,
    name: string<32>,
    symbol: string<10>,
    uri: string<200>,
    seller_fee_basis_points: u16,
    is_mutable: bool,
    token_standard: u8,
    collection_key: pubkey,
    num_creators: u8,
    creator_1: pubkey,
    creator_share_1: u8,
    creator_2: pubkey,
    creator_share_2: u8,
    creator_3: pubkey,
    creator_share_3: u8,
    creator_4: pubkey,
    creator_share_4: u8,
    creator_5: pubkey,
    creator_share_5: u8,
    uses_total: u64
) {
    // Validate the mint authority is the actual mint authority
    require(mint.mint_authority == mint_authority.ctx.key);

    // Validate token standard
    require(validate_token_standard(token_standard));

    // Validate royalty basis points
    require(validate_basis_points(seller_fee_basis_points));

    // Validate creator count
    require(num_creators as u64 <= 5);

    // Validate creator shares sum to 100 (or all zero if no creators)
    require(validate_creator_shares(
        num_creators,
        creator_share_1, creator_share_2, creator_share_3,
        creator_share_4, creator_share_5
    ));

    metadata.mint = mint.ctx.key;
    metadata.update_authority = update_authority;
    metadata.name = name;
    metadata.symbol = symbol;
    metadata.uri = uri;
    metadata.seller_fee_basis_points = seller_fee_basis_points;
    metadata.is_mutable = is_mutable;
    metadata.primary_sale_happened = false;
    metadata.token_standard = token_standard;

    metadata.collection_key = collection_key;
    metadata.collection_verified = false;

    metadata.num_creators = num_creators;
    metadata.creator_1 = creator_1;
    metadata.creator_share_1 = creator_share_1;
    metadata.creator_verified_1 = false;
    metadata.creator_2 = creator_2;
    metadata.creator_share_2 = creator_share_2;
    metadata.creator_verified_2 = false;
    metadata.creator_3 = creator_3;
    metadata.creator_share_3 = creator_share_3;
    metadata.creator_verified_3 = false;
    metadata.creator_4 = creator_4;
    metadata.creator_share_4 = creator_share_4;
    metadata.creator_verified_4 = false;
    metadata.creator_5 = creator_5;
    metadata.creator_share_5 = creator_share_5;
    metadata.creator_verified_5 = false;

    metadata.uses_remaining = uses_total;
    metadata.uses_total = uses_total;
}

// ---------------------------------------------------------------------------
// 2. Update Metadata
// ---------------------------------------------------------------------------

pub update_metadata(
    metadata: Metadata @mut,
    authority: account @signer,
    new_name: string<32>,
    new_symbol: string<10>,
    new_uri: string<200>,
    new_seller_fee_basis_points: u16,
    primary_sale_happened: bool
) {
    require(metadata.is_mutable);
    require(metadata.update_authority == authority.ctx.key);
    require(validate_basis_points(new_seller_fee_basis_points));

    metadata.name = new_name;
    metadata.symbol = new_symbol;
    metadata.uri = new_uri;
    metadata.seller_fee_basis_points = new_seller_fee_basis_points;

    // primary_sale_happened is a one-way flag: once true it cannot revert
    if (primary_sale_happened) {
        metadata.primary_sale_happened = true;
    }
}

// ---------------------------------------------------------------------------
// 3. Create Master Edition
// ---------------------------------------------------------------------------

pub create_master_edition(
    master_edition: MasterEdition @mut @init(payer=payer, space=256),
    payer: account @mut @signer,
    metadata: Metadata @mut,
    mint_authority: account @signer,
    mint: spl_token::Mint @serializer("raw"),
    max_supply: u64
) {
    require(metadata.mint == mint.ctx.key);
    require(mint.mint_authority == mint_authority.ctx.key);

    // Only NonFungible (0) tokens can have master editions
    require(metadata.token_standard == 0);

    master_edition.mint = mint.ctx.key;
    master_edition.supply = 0;
    master_edition.max_supply = max_supply;
}

// ---------------------------------------------------------------------------
// 4. Mint Edition (numbered print from a master)
// ---------------------------------------------------------------------------

pub mint_edition(
    edition: EditionRecord @mut @init(payer=payer, space=256),
    payer: account @mut @signer,
    master_edition: MasterEdition @mut,
    parent_metadata: Metadata,
    edition_mint: spl_token::Mint @serializer("raw"),
    edition_mint_authority: account @signer,
    edition_metadata: Metadata @mut @init(payer=payer, space=1024),
    update_authority: account @signer
) {
    // The update authority of the parent must sign
    require(parent_metadata.update_authority == update_authority.ctx.key);

    // Ensure master edition matches the parent metadata mint
    require(master_edition.mint == parent_metadata.mint);

    // Enforce max supply (0 means 1/1 unique — no editions allowed)
    require(master_edition.max_supply > 0);
    require(master_edition.supply < master_edition.max_supply);

    // Edition mint authority must match
    require(edition_mint.mint_authority == edition_mint_authority.ctx.key);

    // Increment supply and assign edition number
    master_edition.supply = master_edition.supply + 1;
    let edition_number: u64 = master_edition.supply;

    // Set up edition record
    edition.parent_mint = parent_metadata.mint;
    edition.mint = edition_mint.ctx.key;
    edition.edition_number = edition_number;

    // Copy parent metadata to edition metadata
    edition_metadata.mint = edition_mint.ctx.key;
    edition_metadata.update_authority = parent_metadata.update_authority;
    edition_metadata.name = parent_metadata.name;
    edition_metadata.symbol = parent_metadata.symbol;
    edition_metadata.uri = parent_metadata.uri;
    edition_metadata.seller_fee_basis_points = parent_metadata.seller_fee_basis_points;
    edition_metadata.is_mutable = false;
    edition_metadata.primary_sale_happened = false;
    edition_metadata.token_standard = 3;

    edition_metadata.collection_key = parent_metadata.collection_key;
    edition_metadata.collection_verified = false;

    edition_metadata.num_creators = parent_metadata.num_creators;
    edition_metadata.creator_1 = parent_metadata.creator_1;
    edition_metadata.creator_share_1 = parent_metadata.creator_share_1;
    edition_metadata.creator_verified_1 = parent_metadata.creator_verified_1;
    edition_metadata.creator_2 = parent_metadata.creator_2;
    edition_metadata.creator_share_2 = parent_metadata.creator_share_2;
    edition_metadata.creator_verified_2 = parent_metadata.creator_verified_2;
    edition_metadata.creator_3 = parent_metadata.creator_3;
    edition_metadata.creator_share_3 = parent_metadata.creator_share_3;
    edition_metadata.creator_verified_3 = parent_metadata.creator_verified_3;
    edition_metadata.creator_4 = parent_metadata.creator_4;
    edition_metadata.creator_share_4 = parent_metadata.creator_share_4;
    edition_metadata.creator_verified_4 = parent_metadata.creator_verified_4;
    edition_metadata.creator_5 = parent_metadata.creator_5;
    edition_metadata.creator_share_5 = parent_metadata.creator_share_5;
    edition_metadata.creator_verified_5 = parent_metadata.creator_verified_5;

    edition_metadata.uses_remaining = 0;
    edition_metadata.uses_total = 0;
}

// ---------------------------------------------------------------------------
// 5. Verify Creator
// ---------------------------------------------------------------------------

pub verify_creator(
    metadata: Metadata @mut,
    creator: account @signer,
    creator_slot: u8
) {
    // creator_slot: 1-5 indicating which creator slot to verify
    require(creator_slot as u64 >= 1);
    require(creator_slot as u64 <= 5);
    require(creator_slot as u64 <= metadata.num_creators as u64);

    if (creator_slot == 1) {
        require(metadata.creator_1 == creator.ctx.key);
        metadata.creator_verified_1 = true;
    }
    if (creator_slot == 2) {
        require(metadata.creator_2 == creator.ctx.key);
        metadata.creator_verified_2 = true;
    }
    if (creator_slot == 3) {
        require(metadata.creator_3 == creator.ctx.key);
        metadata.creator_verified_3 = true;
    }
    if (creator_slot == 4) {
        require(metadata.creator_4 == creator.ctx.key);
        metadata.creator_verified_4 = true;
    }
    if (creator_slot == 5) {
        require(metadata.creator_5 == creator.ctx.key);
        metadata.creator_verified_5 = true;
    }
}

// ---------------------------------------------------------------------------
// 6. Unverify Creator
// ---------------------------------------------------------------------------

pub unverify_creator(
    metadata: Metadata @mut,
    creator: account @signer,
    creator_slot: u8
) {
    require(creator_slot as u64 >= 1);
    require(creator_slot as u64 <= 5);
    require(creator_slot as u64 <= metadata.num_creators as u64);

    if (creator_slot == 1) {
        require(metadata.creator_1 == creator.ctx.key);
        metadata.creator_verified_1 = false;
    }
    if (creator_slot == 2) {
        require(metadata.creator_2 == creator.ctx.key);
        metadata.creator_verified_2 = false;
    }
    if (creator_slot == 3) {
        require(metadata.creator_3 == creator.ctx.key);
        metadata.creator_verified_3 = false;
    }
    if (creator_slot == 4) {
        require(metadata.creator_4 == creator.ctx.key);
        metadata.creator_verified_4 = false;
    }
    if (creator_slot == 5) {
        require(metadata.creator_5 == creator.ctx.key);
        metadata.creator_verified_5 = false;
    }
}

// ---------------------------------------------------------------------------
// 7. Create Collection
// ---------------------------------------------------------------------------

pub create_collection(
    collection: CollectionDetails @mut @init(payer=payer, space=256),
    payer: account @mut @signer,
    collection_metadata: Metadata,
    authority: account @signer,
    size: u64
) {
    // The collection NFT must already have metadata
    require(collection_metadata.update_authority == authority.ctx.key);

    // Only NonFungible tokens can be collections
    require(collection_metadata.token_standard == 0);

    collection.mint = collection_metadata.mint;
    collection.authority = authority.ctx.key;
    collection.size = size;
    collection.num_verified = 0;
}

// ---------------------------------------------------------------------------
// 8. Verify Collection
// ---------------------------------------------------------------------------

pub verify_collection(
    metadata: Metadata @mut,
    collection: CollectionDetails @mut,
    authority: account @signer
) {
    // Collection authority must sign
    require(collection.authority == authority.ctx.key);

    // The metadata must reference this collection
    require(metadata.collection_key == collection.mint);

    // Must not already be verified
    require(!metadata.collection_verified);

    metadata.collection_verified = true;
    collection.num_verified = collection.num_verified + 1;
}

// ---------------------------------------------------------------------------
// 9. Unverify Collection
// ---------------------------------------------------------------------------

pub unverify_collection(
    metadata: Metadata @mut,
    collection: CollectionDetails @mut,
    authority: account @signer
) {
    require(collection.authority == authority.ctx.key);
    require(metadata.collection_key == collection.mint);
    require(metadata.collection_verified);

    metadata.collection_verified = false;
    require(collection.num_verified > 0);
    collection.num_verified = collection.num_verified - 1;
}

// ---------------------------------------------------------------------------
// 10. Set Collection Size
// ---------------------------------------------------------------------------

pub set_collection_size(
    collection: CollectionDetails @mut,
    authority: account @signer,
    new_size: u64
) {
    require(collection.authority == authority.ctx.key);

    // New size cannot be smaller than already-verified count
    require(new_size >= collection.num_verified);

    collection.size = new_size;
}

// ---------------------------------------------------------------------------
// 11. Update Authority (transfer)
// ---------------------------------------------------------------------------

pub update_authority(
    metadata: Metadata @mut,
    current_authority: account @signer,
    new_authority: pubkey
) {
    require(metadata.is_mutable);
    require(metadata.update_authority == current_authority.ctx.key);

    metadata.update_authority = new_authority;
}

// ---------------------------------------------------------------------------
// 12. Revoke Authority (permanent immutability)
// ---------------------------------------------------------------------------

pub revoke_authority(
    metadata: Metadata @mut,
    authority: account @signer
) {
    require(metadata.is_mutable);
    require(metadata.update_authority == authority.ctx.key);

    // Irreversible: metadata can never be changed again
    metadata.is_mutable = false;
}

// ---------------------------------------------------------------------------
// 13. Freeze Delegated (programmable NFT custody)
// ---------------------------------------------------------------------------

pub freeze_delegated(
    metadata: Metadata,
    token_account: spl_token::TokenAccount @mut @serializer("raw"),
    delegate: account @signer,
    mint: spl_token::Mint @serializer("raw"),
    token_program: account
) {
    // Metadata must match the mint
    require(metadata.mint == mint.ctx.key);

    // The delegate must be the token account's delegate
    require(token_account.delegate == delegate.ctx.key);

    // Cannot freeze an already-frozen account
    require(!token_account.is_frozen);

    spl_token::SPLToken::freeze_account(mint, token_account, delegate);
}

// ---------------------------------------------------------------------------
// 14. Thaw Delegated
// ---------------------------------------------------------------------------

pub thaw_delegated(
    metadata: Metadata,
    token_account: spl_token::TokenAccount @mut @serializer("raw"),
    delegate: account @signer,
    mint: spl_token::Mint @serializer("raw"),
    token_program: account
) {
    require(metadata.mint == mint.ctx.key);
    require(token_account.delegate == delegate.ctx.key);

    // Must be frozen to thaw
    require(token_account.is_frozen);

    spl_token::SPLToken::thaw_account(mint, token_account, delegate);
}

// ---------------------------------------------------------------------------
// 15. Burn NFT
// ---------------------------------------------------------------------------

pub burn_nft(
    metadata: Metadata @mut,
    mint: spl_token::Mint @mut @serializer("raw"),
    token_account: spl_token::TokenAccount @mut @serializer("raw"),
    owner: account @signer,
    token_program: account,
    amount: u64
) {
    // Metadata must match the mint
    require(metadata.mint == mint.ctx.key);

    // Token account must hold this mint
    require(token_account.mint == mint.ctx.key);

    // Owner must be the token account authority
    require(token_account.authority == owner.ctx.key);

    // Cannot burn a frozen token
    require(!token_account.is_frozen);

    // Must burn at least 1
    require(amount > 0);
    require(token_account.amount >= amount);

    // Burn the tokens via SPL Token CPI
    spl_token::SPLToken::burn(token_account, mint, owner, amount);

    // Mark metadata as having undergone primary sale (burned = sold/used)
    metadata.primary_sale_happened = true;
}

// ---------------------------------------------------------------------------
// Authority helpers — update collection authority
// ---------------------------------------------------------------------------

pub update_collection_authority(
    collection: CollectionDetails @mut,
    current_authority: account @signer,
    new_authority: pubkey
) {
    require(collection.authority == current_authority.ctx.key);
    collection.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Update creators (update authority can reassign creator slots)
// ---------------------------------------------------------------------------

pub update_creators(
    metadata: Metadata @mut,
    authority: account @signer,
    num_creators: u8,
    creator_1: pubkey,
    creator_share_1: u8,
    creator_2: pubkey,
    creator_share_2: u8,
    creator_3: pubkey,
    creator_share_3: u8,
    creator_4: pubkey,
    creator_share_4: u8,
    creator_5: pubkey,
    creator_share_5: u8
) {
    require(metadata.is_mutable);
    require(metadata.update_authority == authority.ctx.key);
    require(num_creators as u64 <= 5);
    require(validate_creator_shares(
        num_creators,
        creator_share_1, creator_share_2, creator_share_3,
        creator_share_4, creator_share_5
    ));

    metadata.num_creators = num_creators;
    metadata.creator_1 = creator_1;
    metadata.creator_share_1 = creator_share_1;
    metadata.creator_verified_1 = false;
    metadata.creator_2 = creator_2;
    metadata.creator_share_2 = creator_share_2;
    metadata.creator_verified_2 = false;
    metadata.creator_3 = creator_3;
    metadata.creator_share_3 = creator_share_3;
    metadata.creator_verified_3 = false;
    metadata.creator_4 = creator_4;
    metadata.creator_share_4 = creator_share_4;
    metadata.creator_verified_4 = false;
    metadata.creator_5 = creator_5;
    metadata.creator_share_5 = creator_share_5;
    metadata.creator_verified_5 = false;
}

// ---------------------------------------------------------------------------
// Mark primary sale
// ---------------------------------------------------------------------------

pub mark_primary_sale(
    metadata: Metadata @mut,
    owner: account @signer,
    token_account: spl_token::TokenAccount @serializer("raw")
) {
    // Only the current token holder can mark primary sale
    require(token_account.mint == metadata.mint);
    require(token_account.authority == owner.ctx.key);
    require(token_account.amount > 0);
    require(!metadata.primary_sale_happened);

    metadata.primary_sale_happened = true;
}

// ---------------------------------------------------------------------------
// Use (consume a use from the uses allocation)
// ---------------------------------------------------------------------------

pub consume_use(
    metadata: Metadata @mut,
    owner: account @signer,
    token_account: spl_token::TokenAccount @serializer("raw"),
    num_uses: u64
) {
    require(token_account.mint == metadata.mint);
    require(token_account.authority == owner.ctx.key);
    require(token_account.amount > 0);
    require(num_uses > 0);
    require(metadata.uses_remaining >= num_uses);

    metadata.uses_remaining = metadata.uses_remaining - num_uses;
}

// ---------------------------------------------------------------------------
// Read-only views
// ---------------------------------------------------------------------------

pub get_metadata_mint(metadata: Metadata) -> pubkey {
    return metadata.mint;
}

pub get_metadata_name(metadata: Metadata) -> string<32> {
    return metadata.name;
}

pub get_metadata_uri(metadata: Metadata) -> string<200> {
    return metadata.uri;
}

pub get_seller_fee(metadata: Metadata) -> u16 {
    return metadata.seller_fee_basis_points;
}

pub get_token_standard(metadata: Metadata) -> u8 {
    return metadata.token_standard;
}

pub get_edition_supply(master_edition: MasterEdition) -> u64 {
    return master_edition.supply;
}

pub get_edition_max_supply(master_edition: MasterEdition) -> u64 {
    return master_edition.max_supply;
}

pub get_collection_size(collection: CollectionDetails) -> u64 {
    return collection.size;
}

pub get_collection_verified_count(collection: CollectionDetails) -> u64 {
    return collection.num_verified;
}

pub get_uses_remaining(metadata: Metadata) -> u64 {
    return metadata.uses_remaining;
}
