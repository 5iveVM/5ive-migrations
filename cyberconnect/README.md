# CyberConnect Social Graph Protocol -- 5ive DSL Migration

Decentralized social graph protocol migrated to the 5ive DSL. Stores social relationships (follows, subscriptions, content) on-chain, making them portable across applications.

## Architecture

### Accounts (9 total)

| Account | Purpose | Key fields |
|---|---|---|
| **ProtocolConfig** | Global protocol state and fee configuration | authority, protocol_fee_bps, fee_collector, totals |
| **Profile** | On-chain identity with metadata pointers | owner, handle_hash, follower/following counts, is_private |
| **Connection** | Follow/pending/block relationship between two profiles | follower_profile, following_profile, connection_type (0/1/2) |
| **Content** | On-chain content reference (post, comment, share) | author_profile, content_hash, content_type (0/1/2), parent_content |
| **Like** | Single like on a content item | content, liker_profile |
| **SubscriptionTier** | Creator-defined paid tier | price, payment_mint, duration_seconds, perks_hash |
| **Subscription** | Active subscription linking subscriber to tier | tier, subscriber_profile, expires_at, auto_renew |
| **Organization** | Group profile with role-based membership | owner, name_hash, member_count |
| **OrgMember** | Membership record within an organization | org, member_profile, role (0=member, 1=mod, 2=admin) |

### PDA Scheme

PDAs enforce on-chain uniqueness constraints:

- `("profile", handle_hash)` -- one profile per handle
- `("connection", follower, following)` -- one connection per pair
- `("content", author, content_hash)` -- content deduplication
- `("like", content, liker)` -- one like per profile per content
- `("sub_tier", creator, tier_index)` -- subscription tier per creator
- `("subscription", tier, subscriber)` -- one subscription per tier per user
- `("org", name_hash)` -- one org per name
- `("org_member", org, member)` -- one membership per org per profile

## Instructions (31 total)

### Protocol Admin (4)
- `init_protocol` -- Initialize the protocol config with authority and fee settings
- `set_protocol_fee` -- Update the protocol fee basis points
- `collect_protocol_fees` -- Withdraw accumulated protocol fees
- `set_protocol_authority` -- Transfer protocol authority to a new wallet

### Profile (6)
- `create_profile` -- Create an on-chain profile (handle enforced unique via PDA)
- `update_profile` -- Update metadata URI and avatar hash
- `set_profile_metadata_uri` -- Update only the off-chain metadata pointer
- `set_profile_private` -- Toggle private mode (requires follow approval)
- `transfer_profile` -- Transfer profile ownership to another wallet
- `delete_profile` -- Soft-delete (deactivate) a profile

### Connections / Social Graph (6)
- `follow` -- Create a follow connection (auto-pending for private profiles)
- `accept_follow_request` -- Accept a pending follow on a private profile
- `reject_follow_request` -- Reject a pending follow request
- `unfollow` -- Remove an active follow connection
- `block` -- Block a profile (connection_type = 2)
- `unblock` -- Remove a block

### Content (6)
- `create_post` -- Publish a content reference (type 0)
- `create_comment` -- Comment on existing content (type 1, references parent)
- `create_share` -- Share/repost content (type 2, references original)
- `delete_content` -- Soft-delete own content
- `like_content` -- Like a content item (one per profile, PDA enforced)
- `unlike_content` -- Remove a like

### Subscriptions / Creator Economy (5)
- `create_subscription_tier` -- Creator defines a paid tier (price, duration, perks)
- `update_subscription_tier` -- Update tier pricing and perks
- `subscribe` -- Pay to subscribe (SPL token transfer, protocol fee deducted)
- `renew_subscription` -- Extend an active subscription (extends from expiry or now)
- `cancel_subscription` -- Disable auto-renewal
- `collect_subscription_revenue` -- Creator withdraws accumulated payments

### Organizations (5)
- `create_org` -- Create an organization profile (name uniqueness via PDA)
- `add_org_member` -- Add a member with role assignment
- `remove_org_member` -- Remove a member (cannot remove owner)
- `update_org_member_role` -- Change a member's role
- `transfer_org_ownership` -- Transfer org to a new owner

### Read-only Helpers (9)
Getter functions for profile stats, content engagement, tier metrics, org size, subscription status, and protocol totals.

## Payment Flow (Subscriptions)

```
Subscriber --[price - fee]--> Creator Token Account
Subscriber --[fee]----------> Protocol Fee Collector
```

The protocol fee is calculated as `(price * protocol_fee_bps) / 10000`. Renewals extend from the current expiry date (not from now) if the subscription has not yet expired.

## Connection Types

| Value | Meaning |
|---|---|
| 0 | Active follow |
| 1 | Pending follow request (private profiles) |
| 2 | Blocked |

## Content Types

| Value | Meaning |
|---|---|
| 0 | Post |
| 1 | Comment (has parent_content) |
| 2 | Share/repost (has parent_content) |

## File Structure

```
cyberconnect/
  five.toml
  README.md
  src/
    main.v        # Complete 5ive DSL migration
```
