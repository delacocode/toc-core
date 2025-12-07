# Resolver Simplification Design

**Date:** 2025-12-07
**Status:** Approved for Implementation

---

## Problem

1. **Contract size exceeded** - POPRegistry is 27,178 bytes, 2,602 bytes over the 24,576 EIP-170 limit
2. **Duplicate code paths** - Separate System/Public resolver logic doubles storage and functions
3. **Unnecessary complexity** - Numeric resolver IDs add indirection when addresses work directly

---

## Solution

Unify resolver management into a single trust-level system with address-based lookups.

---

## Design Decisions

| Decision | Choice |
|----------|--------|
| Resolver identification | Direct address (no numeric IDs) |
| Registration | Permissionless, anyone can register a contract |
| Initial trust level | PERMISSIONLESS on registration |
| Trust upgrades | Admin only via `setResolverTrust()` |
| Deprecation | Set trust to NONE (or add DEPRECATED level) |

---

## New Enum

```solidity
enum ResolverTrust {
    NONE,           // Not registered (default for unmapped addresses)
    PERMISSIONLESS, // Registered, no system guarantees
    VERIFIED,       // Admin reviewed, some assurance
    SYSTEM          // Full system backing
}
```

Replaces: `ResolverType { NONE, SYSTEM, PUBLIC, DEPRECATED }`

---

## Storage Changes

### Remove

```solidity
// Remove these
EnumerableSet.AddressSet private _systemResolvers;
EnumerableSet.AddressSet private _publicResolvers;
mapping(address => uint256) private _systemResolverIds;
mapping(address => uint256) private _publicResolverIds;
mapping(uint256 => address) private _systemResolverAddresses;
mapping(uint256 => address) private _publicResolverAddresses;
mapping(address => SystemResolverConfig) private _systemResolverConfigs;
mapping(address => PublicResolverConfig) private _publicResolverConfigs;
uint256 private _nextSystemResolverId;
uint256 private _nextPublicResolverId;
```

### Add

```solidity
// Simple trust mapping
mapping(address => ResolverTrust) private _resolverTrust;

// Optional: track all registered resolvers for enumeration
EnumerableSet.AddressSet private _registeredResolvers;
```

---

## Function Changes

### Remove

```solidity
// Remove dual functions
function registerResolver(ResolverType resolverType, address resolver) external onlyOwner;
function createPOPWithSystemResolver(...) external returns (uint256);
function createPOPWithPublicResolver(...) external returns (uint256);
function getResolverId(ResolverType, address) external view returns (uint256);
function getResolverAddress(ResolverType, uint256) external view returns (address);
function getResolverCount(ResolverType) external view returns (uint256);
function deprecateResolver(ResolverType, address) external onlyOwner;
function restoreResolver(address, ResolverType) external onlyOwner;
function updateSystemResolverConfig(...) external onlyOwner;
function updatePublicResolverConfig(...) external onlyOwner;
function getSystemResolverConfig(...) external view;
function getPublicResolverConfig(...) external view;
```

### Add

```solidity
/// @notice Register a resolver (permissionless, must be contract)
/// @param resolver The resolver contract address
function registerResolver(address resolver) external {
    require(resolver.code.length > 0, "Must be contract");
    require(_resolverTrust[resolver] == ResolverTrust.NONE, "Already registered");

    _resolverTrust[resolver] = ResolverTrust.PERMISSIONLESS;
    _registeredResolvers.add(resolver);

    emit ResolverRegistered(resolver, ResolverTrust.PERMISSIONLESS, msg.sender);
}

/// @notice Set resolver trust level (admin only)
/// @param resolver The resolver address
/// @param trust The new trust level
function setResolverTrust(address resolver, ResolverTrust trust) external onlyOwner {
    require(_resolverTrust[resolver] != ResolverTrust.NONE, "Not registered");

    ResolverTrust oldTrust = _resolverTrust[resolver];
    _resolverTrust[resolver] = trust;

    emit ResolverTrustChanged(resolver, oldTrust, trust);
}

/// @notice Create a POP with any registered resolver
/// @param resolver The resolver contract address
/// @param templateId Template within the resolver
/// @param payload Creation parameters
/// @param disputeWindow Time for pre-resolution disputes
/// @param truthKeeperWindow Time for TK to decide
/// @param escalationWindow Time to challenge TK decision
/// @param postResolutionWindow Time for post-resolution disputes
/// @param truthKeeper Assigned TruthKeeper address
function createPOP(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) external returns (uint256 popId);

/// @notice Get resolver trust level
function getResolverTrust(address resolver) external view returns (ResolverTrust);

/// @notice Check if resolver is registered (trust > NONE)
function isRegisteredResolver(address resolver) external view returns (bool);

/// @notice Get all registered resolvers
function getRegisteredResolvers() external view returns (address[] memory);

/// @notice Get count of registered resolvers
function getResolverCount() external view returns (uint256);
```

---

## Event Changes

### Remove

```solidity
event ResolverRegistered(address resolver, ResolverType resolverType, uint256 resolverId);
event ResolverDeprecated(address resolver, ResolverType resolverType);
event ResolverRestored(address resolver, ResolverType fromType, ResolverType newType);
```

### Add

```solidity
event ResolverRegistered(address indexed resolver, ResolverTrust trust, address indexed registeredBy);
event ResolverTrustChanged(address indexed resolver, ResolverTrust oldTrust, ResolverTrust newTrust);
```

---

## POPCreated Event Update

```solidity
// Before
event POPCreated(
    uint256 popId,
    ResolverType resolverType,
    uint256 resolverId,
    address resolver,
    ...
);

// After
event POPCreated(
    uint256 indexed popId,
    address indexed resolver,
    ResolverTrust trust,
    uint32 templateId,
    AnswerType answerType,
    POPState initialState,
    address indexed truthKeeper,
    AccountabilityTier tier
);
```

---

## POPInfo Struct Update

```solidity
struct POPInfo {
    // ... existing fields ...

    // Replace these:
    // ResolverType resolverType;
    // uint256 resolverId;

    // With:
    ResolverTrust resolverTrust;

    // ... rest of fields ...
}
```

---

## Accountability Tier Calculation Update

Current logic uses `_whitelistedResolvers`. Update to use trust level:

```solidity
function _calculateAccountabilityTier(
    address resolver,
    address truthKeeper
) internal view returns (AccountabilityTier) {
    bool isSystemResolver = _resolverTrust[resolver] == ResolverTrust.SYSTEM;
    bool isWhitelistedTK = _whitelistedTruthKeepers.contains(truthKeeper);

    if (isSystemResolver && isWhitelistedTK) {
        return AccountabilityTier.SYSTEM;
    }

    if (_tkGuaranteedResolvers[truthKeeper].contains(resolver)) {
        return AccountabilityTier.TK_GUARANTEED;
    }

    return AccountabilityTier.PERMISSIONLESS;
}
```

---

## Migration Notes

If upgrading existing deployment:
1. Map existing SYSTEM resolvers to `ResolverTrust.SYSTEM`
2. Map existing PUBLIC resolvers to `ResolverTrust.VERIFIED` or `PERMISSIONLESS`
3. Existing POPs continue to work (they store resolver address, not ID)

---

## Expected Size Reduction

Removing:
- 2 EnumerableSets (~500 bytes each)
- 6 mappings for ID lookups
- Duplicate registration logic
- Duplicate config structs
- Dual createPOP functions

Estimated savings: **3,000-5,000 bytes** (should bring POPRegistry under limit)

---

## Benefits

1. **Smaller contract** - Under EIP-170 limit
2. **Simpler API** - One `createPOP()`, direct addresses
3. **Permissionless** - Anyone can register resolvers
4. **Flexible trust** - Admin can upgrade/downgrade anytime
5. **Consumer choice** - Check trust level, decide risk tolerance
6. **Cleaner events** - No resolver IDs to track
