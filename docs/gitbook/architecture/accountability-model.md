# Accountability Model

## Tier Calculation

At TOC creation, accountability tier is calculated and frozen:

```solidity
function _calculateAccountabilityTier(
    address resolver,
    address truthKeeper
) internal view returns (AccountabilityTier) {
    ResolverTrust trust = _resolverConfigs[resolver].trust;

    // SYSTEM: System resolver + whitelisted TruthKeeper
    if (trust == ResolverTrust.SYSTEM && _isWhitelistedTruthKeeper(truthKeeper)) {
        return AccountabilityTier.SYSTEM;
    }

    // TK_GUARANTEED: TruthKeeper has guaranteed this resolver
    if (_tkGuaranteedResolvers[truthKeeper].contains(resolver)) {
        return AccountabilityTier.TK_GUARANTEED;
    }

    // PERMISSIONLESS: Everything else
    return AccountabilityTier.PERMISSIONLESS;
}
```

## Why Immutable Snapshots?

The tier is captured at creation and never changes because:

- Consumers know accountability upfront before interacting
- Prevents retroactive trust downgrades
- Resolver upgrades don't affect existing TOCs
- Clear audit trail for historical analysis

## Consumer Usage

```solidity
// Simple: just get the answer
bytes memory result = registry.getResult(tocId);

// Comprehensive: get answer + context
ExtensiveResult memory extensive = registry.getExtensiveResult(tocId);
// extensive.result - the answer
// extensive.finalized - is it final?
// extensive.tier - accountability level
// extensive.hasCorrectedResult - was it corrected?
```
