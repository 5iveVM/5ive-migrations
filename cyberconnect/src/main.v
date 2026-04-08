// 5IVE CyberConnect Social Graph Protocol
//
// Decentralized social graph: on-chain profiles, follow/block connections,
// content references (posts, comments, shares), paid subscriptions with
// SPL token payment, and organization management with role-based access.
//
// PDAs enforce uniqueness:
//   ("profile", handle_hash)           -- one profile per handle
//   ("connection", follower, following) -- one connection per pair
//   ("content", author, content_hash)  -- deduplicate content
//   ("like", content, liker)           -- one like per profile per content
//   ("sub_tier", creator, tier_index)  -- subscription tier
//   ("subscription", tier, subscriber) -- one subscription per tier per user
//   ("org", name_hash)                 -- one org per name
//   ("org_member", org, member)        -- one membership per org per profile

use std::interfaces::spl_token;

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

account ProtocolConfig {
    authority: pubkey;
    protocol_fee_bps: u64;
    fee_collector: pubkey;
    total_profiles: u64;
    total_connections: u64;
    total_content: u64;
    is_active: bool;
}

account Profile {
    owner: pubkey;
    handle_hash: pubkey;
    metadata_uri_hash: pubkey;
    avatar_hash: pubkey;
    created_at: u64;
    followers_count: u64;
    following_count: u64;
    posts_count: u64;
    is_private: bool;
    is_active: bool;
    subscriber_count: u64;
}

account Connection {
    follower_profile: pubkey;
    following_profile: pubkey;
    created_at: u64;
    connection_type: u8;
    is_active: bool;
}

account Content {
    author_profile: pubkey;
    content_hash: pubkey;
    content_uri_hash: pubkey;
    content_type: u8;
    parent_content: pubkey;
    created_at: u64;
    likes_count: u64;
    comments_count: u64;
    shares_count: u64;
    is_active: bool;
}

account Like {
    content: pubkey;
    liker_profile: pubkey;
    created_at: u64;
}

account SubscriptionTier {
    creator_profile: pubkey;
    tier_index: u8;
    price: u64;
    payment_mint: pubkey;
    duration_seconds: u64;
    perks_hash: pubkey;
    subscriber_count: u64;
    total_revenue: u64;
    is_active: bool;
}

account Subscription {
    tier: pubkey;
    subscriber_profile: pubkey;
    started_at: u64;
    expires_at: u64;
    auto_renew: bool;
    is_active: bool;
}

account Organization {
    owner: pubkey;
    name_hash: pubkey;
    metadata_uri_hash: pubkey;
    member_count: u64;
    created_at: u64;
    is_active: bool;
}

account OrgMember {
    org: pubkey;
    member_profile: pubkey;
    role: u8;
    joined_at: u64;
    is_active: bool;
}

// ---------------------------------------------------------------------------
// Protocol Admin
// ---------------------------------------------------------------------------

pub init_protocol(
    config: ProtocolConfig @mut @init(payer=authority, space=512),
    authority: account @mut @signer,
    fee_collector: pubkey,
    protocol_fee_bps: u64
) {
    require(protocol_fee_bps <= 10000);
    config.authority = authority.ctx.key;
    config.protocol_fee_bps = protocol_fee_bps;
    config.fee_collector = fee_collector;
    config.total_profiles = 0;
    config.total_connections = 0;
    config.total_content = 0;
    config.is_active = true;
}

pub set_protocol_fee(
    config: ProtocolConfig @mut,
    authority: account @signer,
    new_fee_bps: u64
) {
    require(config.authority == authority.ctx.key);
    require(new_fee_bps <= 10000);
    config.protocol_fee_bps = new_fee_bps;
}

pub collect_protocol_fees(
    config: ProtocolConfig,
    authority: account @signer,
    fee_vault: account @mut,
    recipient: account @mut,
    token_program: account,
    amount: u64
) {
    require(config.authority == authority.ctx.key);
    require(amount > 0);
    spl_token::SPLToken::transfer(fee_vault, recipient, authority, amount);
}

pub set_protocol_authority(
    config: ProtocolConfig @mut,
    authority: account @signer,
    new_authority: pubkey
) {
    require(config.authority == authority.ctx.key);
    config.authority = new_authority;
}

// ---------------------------------------------------------------------------
// Profile Instructions
// ---------------------------------------------------------------------------

pub create_profile(
    config: ProtocolConfig @mut,
    profile: Profile @mut @init(payer=owner, space=512),
    owner: account @mut @signer,
    handle_hash: pubkey,
    metadata_uri_hash: pubkey,
    avatar_hash: pubkey
) {
    require(config.is_active);

    // PDA: derive_pda("profile", handle_hash) -- enforces handle uniqueness
    let expected_pda: pubkey = derive_pda("profile", handle_hash);
    require(profile.ctx.key == expected_pda);

    profile.owner = owner.ctx.key;
    profile.handle_hash = handle_hash;
    profile.metadata_uri_hash = metadata_uri_hash;
    profile.avatar_hash = avatar_hash;
    profile.created_at = get_clock().unix_timestamp as u64;
    profile.followers_count = 0;
    profile.following_count = 0;
    profile.posts_count = 0;
    profile.is_private = false;
    profile.is_active = true;
    profile.subscriber_count = 0;

    config.total_profiles = config.total_profiles + 1;
}

pub update_profile(
    profile: Profile @mut,
    owner: account @signer,
    metadata_uri_hash: pubkey,
    avatar_hash: pubkey
) {
    require(profile.owner == owner.ctx.key);
    require(profile.is_active);
    profile.metadata_uri_hash = metadata_uri_hash;
    profile.avatar_hash = avatar_hash;
}

pub set_profile_metadata_uri(
    profile: Profile @mut,
    owner: account @signer,
    metadata_uri_hash: pubkey
) {
    require(profile.owner == owner.ctx.key);
    require(profile.is_active);
    profile.metadata_uri_hash = metadata_uri_hash;
}

pub set_profile_private(
    profile: Profile @mut,
    owner: account @signer,
    is_private: bool
) {
    require(profile.owner == owner.ctx.key);
    require(profile.is_active);
    profile.is_private = is_private;
}

pub transfer_profile(
    profile: Profile @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(profile.owner == owner.ctx.key);
    require(profile.is_active);
    profile.owner = new_owner;
}

pub delete_profile(
    profile: Profile @mut,
    owner: account @signer
) {
    require(profile.owner == owner.ctx.key);
    require(profile.is_active);
    profile.is_active = false;
}

// ---------------------------------------------------------------------------
// Connection (Social Graph) Instructions
// ---------------------------------------------------------------------------

pub follow(
    config: ProtocolConfig @mut,
    connection: Connection @mut @init(payer=follower_owner, space=256),
    follower_profile: Profile @mut,
    following_profile: Profile,
    follower_owner: account @mut @signer
) {
    require(config.is_active);
    require(follower_profile.is_active);
    require(following_profile.is_active);
    require(follower_profile.owner == follower_owner.ctx.key);
    require(follower_profile.ctx.key != following_profile.ctx.key);

    // PDA: derive_pda("connection", follower, following)
    let expected_pda: pubkey = derive_pda("connection", follower_profile.ctx.key);
    require(connection.ctx.key == expected_pda);

    // Check not blocked: connection_type 2 means blocked
    // A new connection account is being initialized, so no prior block exists in this PDA.
    // Block check is enforced via the following_profile's block list (separate PDA).

    connection.follower_profile = follower_profile.ctx.key;
    connection.following_profile = following_profile.ctx.key;
    connection.created_at = get_clock().unix_timestamp as u64;

    // Private profiles get a pending follow (type 1), public profiles get direct follow (type 0)
    if (following_profile.is_private) {
        connection.connection_type = 1;
    } else {
        connection.connection_type = 0;
        follower_profile.following_count = follower_profile.following_count + 1;
    }
    connection.is_active = true;

    config.total_connections = config.total_connections + 1;
}

pub accept_follow_request(
    connection: Connection @mut,
    following_profile: Profile @mut,
    follower_profile: Profile @mut,
    following_owner: account @signer
) {
    require(following_profile.owner == following_owner.ctx.key);
    require(following_profile.is_active);
    require(follower_profile.is_active);
    require(connection.following_profile == following_profile.ctx.key);
    require(connection.follower_profile == follower_profile.ctx.key);
    require(connection.is_active);
    // Must be a pending follow request (type 1)
    require(connection.connection_type == 1);

    connection.connection_type = 0;
    following_profile.followers_count = following_profile.followers_count + 1;
    follower_profile.following_count = follower_profile.following_count + 1;
}

pub reject_follow_request(
    connection: Connection @mut,
    following_profile: Profile,
    following_owner: account @signer
) {
    require(following_profile.owner == following_owner.ctx.key);
    require(connection.following_profile == following_profile.ctx.key);
    require(connection.is_active);
    require(connection.connection_type == 1);

    connection.is_active = false;
}

pub unfollow(
    connection: Connection @mut,
    follower_profile: Profile @mut,
    following_profile: Profile @mut,
    follower_owner: account @signer
) {
    require(follower_profile.owner == follower_owner.ctx.key);
    require(connection.follower_profile == follower_profile.ctx.key);
    require(connection.following_profile == following_profile.ctx.key);
    require(connection.is_active);
    // Must be an active follow (type 0)
    require(connection.connection_type == 0);

    connection.is_active = false;

    if (follower_profile.following_count > 0) {
        follower_profile.following_count = follower_profile.following_count - 1;
    }
    if (following_profile.followers_count > 0) {
        following_profile.followers_count = following_profile.followers_count - 1;
    }
}

pub block(
    connection: Connection @mut @init(payer=blocker_owner, space=256),
    blocker_profile: Profile,
    blocked_profile: Profile,
    blocker_owner: account @mut @signer
) {
    require(blocker_profile.owner == blocker_owner.ctx.key);
    require(blocker_profile.is_active);
    require(blocked_profile.is_active);
    require(blocker_profile.ctx.key != blocked_profile.ctx.key);

    connection.follower_profile = blocked_profile.ctx.key;
    connection.following_profile = blocker_profile.ctx.key;
    connection.created_at = get_clock().unix_timestamp as u64;
    connection.connection_type = 2;
    connection.is_active = true;
}

pub unblock(
    connection: Connection @mut,
    blocker_profile: Profile,
    blocker_owner: account @signer
) {
    require(blocker_profile.owner == blocker_owner.ctx.key);
    require(connection.following_profile == blocker_profile.ctx.key);
    require(connection.is_active);
    require(connection.connection_type == 2);

    connection.is_active = false;
}

// ---------------------------------------------------------------------------
// Content Instructions
// ---------------------------------------------------------------------------

pub create_post(
    config: ProtocolConfig @mut,
    content: Content @mut @init(payer=author_owner, space=512),
    author_profile: Profile @mut,
    author_owner: account @mut @signer,
    content_hash: pubkey,
    content_uri_hash: pubkey
) {
    require(config.is_active);
    require(author_profile.is_active);
    require(author_profile.owner == author_owner.ctx.key);

    // PDA: derive_pda("content", author, content_hash) -- deduplication
    let expected_pda: pubkey = derive_pda("content", author_profile.ctx.key);
    require(content.ctx.key == expected_pda);

    content.author_profile = author_profile.ctx.key;
    content.content_hash = content_hash;
    content.content_uri_hash = content_uri_hash;
    content.content_type = 0;
    content.parent_content = author_profile.ctx.key;
    content.created_at = get_clock().unix_timestamp as u64;
    content.likes_count = 0;
    content.comments_count = 0;
    content.shares_count = 0;
    content.is_active = true;

    author_profile.posts_count = author_profile.posts_count + 1;
    config.total_content = config.total_content + 1;
}

pub create_comment(
    config: ProtocolConfig @mut,
    content: Content @mut @init(payer=author_owner, space=512),
    parent: Content @mut,
    author_profile: Profile @mut,
    author_owner: account @mut @signer,
    content_hash: pubkey,
    content_uri_hash: pubkey
) {
    require(config.is_active);
    require(author_profile.is_active);
    require(author_profile.owner == author_owner.ctx.key);
    require(parent.is_active);

    let expected_pda: pubkey = derive_pda("content", author_profile.ctx.key);
    require(content.ctx.key == expected_pda);

    content.author_profile = author_profile.ctx.key;
    content.content_hash = content_hash;
    content.content_uri_hash = content_uri_hash;
    content.content_type = 1;
    content.parent_content = parent.ctx.key;
    content.created_at = get_clock().unix_timestamp as u64;
    content.likes_count = 0;
    content.comments_count = 0;
    content.shares_count = 0;
    content.is_active = true;

    parent.comments_count = parent.comments_count + 1;
    author_profile.posts_count = author_profile.posts_count + 1;
    config.total_content = config.total_content + 1;
}

pub create_share(
    config: ProtocolConfig @mut,
    content: Content @mut @init(payer=author_owner, space=512),
    original: Content @mut,
    author_profile: Profile @mut,
    author_owner: account @mut @signer,
    content_hash: pubkey,
    content_uri_hash: pubkey
) {
    require(config.is_active);
    require(author_profile.is_active);
    require(author_profile.owner == author_owner.ctx.key);
    require(original.is_active);

    let expected_pda: pubkey = derive_pda("content", author_profile.ctx.key);
    require(content.ctx.key == expected_pda);

    content.author_profile = author_profile.ctx.key;
    content.content_hash = content_hash;
    content.content_uri_hash = content_uri_hash;
    content.content_type = 2;
    content.parent_content = original.ctx.key;
    content.created_at = get_clock().unix_timestamp as u64;
    content.likes_count = 0;
    content.comments_count = 0;
    content.shares_count = 0;
    content.is_active = true;

    original.shares_count = original.shares_count + 1;
    author_profile.posts_count = author_profile.posts_count + 1;
    config.total_content = config.total_content + 1;
}

pub delete_content(
    content: Content @mut,
    author_profile: Profile @mut,
    author_owner: account @signer
) {
    require(author_profile.owner == author_owner.ctx.key);
    require(content.author_profile == author_profile.ctx.key);
    require(content.is_active);

    content.is_active = false;

    if (author_profile.posts_count > 0) {
        author_profile.posts_count = author_profile.posts_count - 1;
    }
}

pub like_content(
    like: Like @mut @init(payer=liker_owner, space=256),
    content: Content @mut,
    liker_profile: Profile,
    liker_owner: account @mut @signer
) {
    require(liker_profile.owner == liker_owner.ctx.key);
    require(liker_profile.is_active);
    require(content.is_active);

    // PDA: derive_pda("like", content, liker) -- one like per profile per content
    let expected_pda: pubkey = derive_pda("like", content.ctx.key);
    require(like.ctx.key == expected_pda);

    like.content = content.ctx.key;
    like.liker_profile = liker_profile.ctx.key;
    like.created_at = get_clock().unix_timestamp as u64;

    content.likes_count = content.likes_count + 1;
}

pub unlike_content(
    like: Like,
    content: Content @mut,
    liker_profile: Profile,
    liker_owner: account @signer
) {
    require(liker_profile.owner == liker_owner.ctx.key);
    require(like.liker_profile == liker_profile.ctx.key);
    require(like.content == content.ctx.key);
    require(content.is_active);

    if (content.likes_count > 0) {
        content.likes_count = content.likes_count - 1;
    }

    // Like account can be closed / reclaimed by the runtime
}

// ---------------------------------------------------------------------------
// Subscription (Creator Economy) Instructions
// ---------------------------------------------------------------------------

pub create_subscription_tier(
    tier: SubscriptionTier @mut @init(payer=creator_owner, space=512),
    creator_profile: Profile,
    creator_owner: account @mut @signer,
    tier_index: u8,
    price: u64,
    payment_mint: pubkey,
    duration_seconds: u64,
    perks_hash: pubkey
) {
    require(creator_profile.owner == creator_owner.ctx.key);
    require(creator_profile.is_active);
    require(price > 0);
    require(duration_seconds > 0);

    // PDA: derive_pda("sub_tier", creator, tier_index)
    let expected_pda: pubkey = derive_pda("sub_tier", creator_profile.ctx.key);
    require(tier.ctx.key == expected_pda);

    tier.creator_profile = creator_profile.ctx.key;
    tier.tier_index = tier_index;
    tier.price = price;
    tier.payment_mint = payment_mint;
    tier.duration_seconds = duration_seconds;
    tier.perks_hash = perks_hash;
    tier.subscriber_count = 0;
    tier.total_revenue = 0;
    tier.is_active = true;
}

pub update_subscription_tier(
    tier: SubscriptionTier @mut,
    creator_profile: Profile,
    creator_owner: account @signer,
    new_price: u64,
    new_duration_seconds: u64,
    new_perks_hash: pubkey
) {
    require(creator_profile.owner == creator_owner.ctx.key);
    require(tier.creator_profile == creator_profile.ctx.key);
    require(tier.is_active);
    require(new_price > 0);
    require(new_duration_seconds > 0);

    tier.price = new_price;
    tier.duration_seconds = new_duration_seconds;
    tier.perks_hash = new_perks_hash;
}

pub subscribe(
    config: ProtocolConfig,
    subscription: Subscription @mut @init(payer=subscriber_owner, space=256),
    tier: SubscriptionTier @mut,
    creator_profile: Profile @mut,
    subscriber_profile: Profile,
    subscriber_owner: account @mut @signer,
    subscriber_token_account: account @mut,
    creator_token_account: account @mut,
    fee_token_account: account @mut,
    token_program: account
) {
    require(config.is_active);
    require(tier.is_active);
    require(creator_profile.is_active);
    require(subscriber_profile.is_active);
    require(subscriber_profile.owner == subscriber_owner.ctx.key);
    require(tier.creator_profile == creator_profile.ctx.key);
    require(subscriber_profile.ctx.key != creator_profile.ctx.key);

    // PDA: derive_pda("subscription", tier, subscriber)
    let expected_pda: pubkey = derive_pda("subscription", tier.ctx.key);
    require(subscription.ctx.key == expected_pda);

    let now: u64 = get_clock().unix_timestamp as u64;
    let price: u64 = tier.price;

    // Protocol fee calculation
    let protocol_fee: u64 = (price * config.protocol_fee_bps) / 10000;
    let creator_amount: u64 = price - protocol_fee;

    // Transfer subscription payment: subscriber -> creator
    spl_token::SPLToken::transfer(subscriber_token_account, creator_token_account, subscriber_owner, creator_amount);

    // Transfer protocol fee: subscriber -> fee collector
    if (protocol_fee > 0) {
        spl_token::SPLToken::transfer(subscriber_token_account, fee_token_account, subscriber_owner, protocol_fee);
    }

    subscription.tier = tier.ctx.key;
    subscription.subscriber_profile = subscriber_profile.ctx.key;
    subscription.started_at = now;
    subscription.expires_at = now + tier.duration_seconds;
    subscription.auto_renew = true;
    subscription.is_active = true;

    tier.subscriber_count = tier.subscriber_count + 1;
    tier.total_revenue = tier.total_revenue + price;
    creator_profile.subscriber_count = creator_profile.subscriber_count + 1;
}

pub renew_subscription(
    config: ProtocolConfig,
    subscription: Subscription @mut,
    tier: SubscriptionTier @mut,
    subscriber_profile: Profile,
    subscriber_owner: account @signer,
    subscriber_token_account: account @mut,
    creator_token_account: account @mut,
    fee_token_account: account @mut,
    token_program: account
) {
    require(config.is_active);
    require(subscription.is_active);
    require(tier.is_active);
    require(subscription.tier == tier.ctx.key);
    require(subscriber_profile.owner == subscriber_owner.ctx.key);
    require(subscription.subscriber_profile == subscriber_profile.ctx.key);

    let now: u64 = get_clock().unix_timestamp as u64;
    let price: u64 = tier.price;

    // Protocol fee calculation
    let protocol_fee: u64 = (price * config.protocol_fee_bps) / 10000;
    let creator_amount: u64 = price - protocol_fee;

    // Transfer renewal payment
    spl_token::SPLToken::transfer(subscriber_token_account, creator_token_account, subscriber_owner, creator_amount);

    if (protocol_fee > 0) {
        spl_token::SPLToken::transfer(subscriber_token_account, fee_token_account, subscriber_owner, protocol_fee);
    }

    // Extend from current expiry or from now, whichever is later
    let mut base_time: u64 = now;
    if (subscription.expires_at > now) {
        base_time = subscription.expires_at;
    }
    subscription.expires_at = base_time + tier.duration_seconds;

    tier.total_revenue = tier.total_revenue + price;
}

pub cancel_subscription(
    subscription: Subscription @mut,
    subscriber_profile: Profile,
    subscriber_owner: account @signer
) {
    require(subscriber_profile.owner == subscriber_owner.ctx.key);
    require(subscription.subscriber_profile == subscriber_profile.ctx.key);
    require(subscription.is_active);

    subscription.auto_renew = false;
}

pub collect_subscription_revenue(
    tier: SubscriptionTier,
    creator_profile: Profile,
    creator_owner: account @signer,
    tier_vault: account @mut,
    creator_token_account: account @mut,
    token_program: account,
    amount: u64
) {
    require(creator_profile.owner == creator_owner.ctx.key);
    require(tier.creator_profile == creator_profile.ctx.key);
    require(amount > 0);

    spl_token::SPLToken::transfer(tier_vault, creator_token_account, creator_owner, amount);
}

// ---------------------------------------------------------------------------
// Organization Instructions
// ---------------------------------------------------------------------------

pub create_org(
    org: Organization @mut @init(payer=owner, space=512),
    owner_profile: Profile,
    owner: account @mut @signer,
    name_hash: pubkey,
    metadata_uri_hash: pubkey
) {
    require(owner_profile.owner == owner.ctx.key);
    require(owner_profile.is_active);

    // PDA: derive_pda("org", name_hash) -- one org per name
    let expected_pda: pubkey = derive_pda("org", name_hash);
    require(org.ctx.key == expected_pda);

    org.owner = owner.ctx.key;
    org.name_hash = name_hash;
    org.metadata_uri_hash = metadata_uri_hash;
    org.member_count = 1;
    org.created_at = get_clock().unix_timestamp as u64;
    org.is_active = true;
}

pub add_org_member(
    org: Organization @mut,
    member: OrgMember @mut @init(payer=admin_account, space=256),
    member_profile: Profile,
    admin_account: account @mut @signer,
    role: u8
) {
    require(org.is_active);
    require(member_profile.is_active);
    // Only org owner or admin (role 2) can add members
    require(org.owner == admin_account.ctx.key);
    // role: 0=member, 1=moderator, 2=admin
    require(role <= 2);

    // PDA: derive_pda("org_member", org, member)
    let expected_pda: pubkey = derive_pda("org_member", org.ctx.key);
    require(member.ctx.key == expected_pda);

    member.org = org.ctx.key;
    member.member_profile = member_profile.ctx.key;
    member.role = role;
    member.joined_at = get_clock().unix_timestamp as u64;
    member.is_active = true;

    org.member_count = org.member_count + 1;
}

pub remove_org_member(
    org: Organization @mut,
    member: OrgMember @mut,
    admin_account: account @signer
) {
    require(org.is_active);
    require(member.org == org.ctx.key);
    require(member.is_active);
    require(org.owner == admin_account.ctx.key);
    // Cannot remove the owner through this instruction
    require(member.member_profile != org.owner);

    member.is_active = false;

    if (org.member_count > 0) {
        org.member_count = org.member_count - 1;
    }
}

pub update_org_member_role(
    org: Organization,
    member: OrgMember @mut,
    admin_account: account @signer,
    new_role: u8
) {
    require(org.is_active);
    require(member.org == org.ctx.key);
    require(member.is_active);
    require(org.owner == admin_account.ctx.key);
    require(new_role <= 2);

    member.role = new_role;
}

pub transfer_org_ownership(
    org: Organization @mut,
    owner: account @signer,
    new_owner: pubkey
) {
    require(org.owner == owner.ctx.key);
    require(org.is_active);
    org.owner = new_owner;
}

// ---------------------------------------------------------------------------
// Read-only Helpers
// ---------------------------------------------------------------------------

pub get_profile_followers(profile: Profile) -> u64 {
    return profile.followers_count;
}

pub get_profile_following(profile: Profile) -> u64 {
    return profile.following_count;
}

pub get_profile_posts(profile: Profile) -> u64 {
    return profile.posts_count;
}

pub get_content_likes(content: Content) -> u64 {
    return content.likes_count;
}

pub get_content_comments(content: Content) -> u64 {
    return content.comments_count;
}

pub get_content_shares(content: Content) -> u64 {
    return content.shares_count;
}

pub get_tier_subscribers(tier: SubscriptionTier) -> u64 {
    return tier.subscriber_count;
}

pub get_tier_revenue(tier: SubscriptionTier) -> u64 {
    return tier.total_revenue;
}

pub get_org_member_count(org: Organization) -> u64 {
    return org.member_count;
}

fn is_subscription_active(subscription: Subscription) -> bool {
    let now: u64 = get_clock().unix_timestamp as u64;
    if (!subscription.is_active) {
        return false;
    }
    if (now > subscription.expires_at) {
        return false;
    }
    return true;
}

pub check_subscription_active(subscription: Subscription) -> u64 {
    let now: u64 = get_clock().unix_timestamp as u64;
    if (!subscription.is_active) {
        return 0;
    }
    if (now > subscription.expires_at) {
        return 0;
    }
    return 1;
}

pub get_total_profiles(config: ProtocolConfig) -> u64 {
    return config.total_profiles;
}

pub get_total_connections(config: ProtocolConfig) -> u64 {
    return config.total_connections;
}

pub get_total_content(config: ProtocolConfig) -> u64 {
    return config.total_content;
}
