# Truth On Chain System Next Phase Design

**Date:** 2025-12-07
**Status:** Approved for Implementation

---

## Overview

This document captures design decisions for the next phase of Truth On Chain system development, focusing on resolver simplification, consumer integration, and deployment readiness.

---

## Goals

1. **Fix contract size** - TOCRegistry exceeds EIP-170 limit (27KB vs 24.5KB max)
2. **Simplify resolver system** - Remove unnecessary complexity
3. **Improve consumer experience** - Better getters with resolution context
4. **Prepare for deployment** - L2-first deployment scripts

---

## Design Decisions Summary

| Topic | Decision |
|-------|----------|
| Resolver identification | Direct address (remove numeric IDs) |
| Resolver registration | Permissionless, anyone can register a contract |
| Resolver trust levels | NONE, PERMISSIONLESS, VERIFIED, SYSTEM |
| Trust upgrades | Admin only |
| Consumer events | Emit events for subscriptions, no callbacks |
| Result getters | Add `ExtensiveResult` with context, keep simple getters |
| Batch queries | Defer to separate `TOCViewer` contract |
| Deployment target | L2s first (Arbitrum, Optimism, Base) |

---

## 1. Resolver Simplification

See: `2025-12-07-resolver-simplification-design.md` for full details.

### Summary

Replace dual System/Public resolver system with unified trust-level approach:

```solidity
enum ResolverTrust {
    NONE,           // Not registered
    PERMISSIONLESS, // Registered, no guarantees
    VERIFIED,       // Admin reviewed
    SYSTEM          // Full system backing
}

// Anyone can register (must be contract)
function registerResolver(address resolver) external;

// Admin sets trust level
function setResolverTrust(address resolver, ResolverTrust trust) external onlyOwner;

// Single creation function
function createTOC(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) external returns (uint256 tocId);
```

### Benefits

- Reduces contract size by ~3,000-5,000 bytes
- Simpler API (one `createTOC` function)
- Permissionless resolver registration
- Consumer chooses risk tolerance based on trust level

---

## 2. Resolver Interface Validation

The current `ITocResolver` interface supports all envisioned resolver types:

| Resolver Type | Supported | Notes |
|---------------|-----------|-------|
| Oracle-based (Chainlink, API3, Pyth) | ✅ | Different `resolveToc` implementations |
| Off-chain data (sports, weather) | ✅ | Trusted submitter provides data |
| On-chain state | ✅ | Resolver reads chain state directly |
| Multi-source consensus | ✅ | Resolver aggregates internally |
| Human judgment | ✅ | Resolver handles voting/judge logic |

**Decision:** No changes needed to `ITocResolver`. Resolvers are black boxes that handle their own complexity.

---

## 3. Consumer Integration

### ExtensiveResult Getter

Add rich result getter for consumers who need resolution context:

```solidity
struct ExtensiveResult {
    // The answer
    AnswerType answerType;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;

    // Resolution context
    bool isFinalized;           // State == RESOLVED
    bool wasDisputed;           // Had a dispute filed
    bool wasCorrected;          // Dispute upheld, result changed
    uint256 resolvedAt;         // Timestamp of resolution
    AccountabilityTier tier;    // SYSTEM/TK_GUARANTEED/PERMISSIONLESS
    ResolverTrust resolverTrust; // Trust level of resolver
}

/// @notice Get result with full resolution context
function getExtensiveResult(uint256 tocId) external view returns (ExtensiveResult memory);

/// @notice Get result only if fully finalized (reverts otherwise)
function getExtensiveResultStrict(uint256 tocId) external view returns (ExtensiveResult memory);
```

### Keep Simple Getters

Retain gas-efficient simple getters for consumers who just need the value:

```solidity
function getBooleanResult(uint256 tocId) external view returns (bool);
function getNumericResult(uint256 tocId) external view returns (int256);
function getGenericResult(uint256 tocId) external view returns (bytes memory);
```

### Events for Subscriptions

Consumers subscribe to existing events - no callbacks needed:

- `TOCCreated` - New TOC available
- `TOCResolutionProposed` - Resolution proposed, dispute window open
- `TOCFinalized` - No dispute, result final
- `TOCResolved` - Final resolution (after any disputes)
- `DisputeResolved` - Dispute outcome

**Decision:** No callbacks to avoid gas unpredictability and reentrancy complexity.

---

## 4. Batch Queries (Deferred)

Batch queries (`getResults(uint256[] tocIds)`) deferred to separate contract:

```solidity
// Future: contracts/viewers/TOCViewer.sol
contract TOCViewer {
    ITOCRegistry public immutable registry;

    function getResults(uint256[] calldata tocIds)
        external view returns (ExtensiveResult[] memory);

    function getTOCInfoBatch(uint256[] calldata tocIds)
        external view returns (TOCInfo[] memory);
}
```

**Rationale:** Keeps core registry lean. Multicall or off-chain indexing works for now.

---

## 5. Deployment Strategy

### Target Chains

L2s first for lower gas and faster iteration:
- Arbitrum One
- Optimism
- Base

### Deployment Scripts Needed

1. **Deploy Registry**
   - Deploy TOCRegistry
   - Configure acceptable bonds (resolution, dispute, escalation)
   - Whitelist initial TruthKeepers
   - Transfer ownership if needed

2. **Deploy Resolvers**
   - Deploy resolver contracts (e.g., PythPriceResolver)
   - Register with registry
   - Set trust level (SYSTEM for official resolvers)

3. **Verification**
   - Verify contracts on block explorer
   - Emit test transactions to confirm functionality

### Script Structure

```
scripts/
├── deploy/
│   ├── DeployRegistry.s.sol
│   ├── DeployPythResolver.s.sol
│   └── ConfigureRegistry.s.sol
├── config/
│   ├── arbitrum.json
│   ├── optimism.json
│   └── base.json
└── verify/
    └── VerifyContracts.s.sol
```

**Priority:** After contract changes stabilize.

---

## Implementation Order

### Phase 1: Contract Changes (Priority)

1. **Resolver simplification**
   - Remove ResolverType enum (replace with ResolverTrust)
   - Remove dual resolver storage and functions
   - Add permissionless `registerResolver()`
   - Add `setResolverTrust()` admin function
   - Consolidate to single `createTOC()` function
   - Update events
   - Update tests

2. **ExtensiveResult getter**
   - Add `ExtensiveResult` struct
   - Implement `getExtensiveResult()`
   - Implement `getExtensiveResultStrict()`
   - Update ITOCRegistry interface
   - Add tests

3. **Verify contract size**
   - Run `forge build --sizes`
   - Confirm under 24,576 bytes

### Phase 2: Deployment (After Phase 1)

4. **Deployment scripts**
   - Create Foundry deploy scripts
   - Create chain config files
   - Test on testnets

5. **Documentation updates**
   - Update TOC_SYSTEM_DOCUMENTATION.md
   - Add deployment guide

---

## Open Items (Future)

- **TruthKeeper minimum windows** - TKs declare minimum `truthKeeperWindow` they guarantee
- **TOCViewer contract** - Batch queries for consumers
- **Cross-chain deployment** - CREATE2 for consistent addresses
- **Governance** - Replace admin with governance contract

---

## Files to Modify

### Contracts

- `contracts/TOCregistry/TOCTypes.sol` - Add ResolverTrust, ExtensiveResult
- `contracts/TOCregistry/ITOCRegistry.sol` - Update interface
- `contracts/TOCregistry/TOCRegistry.sol` - Simplify resolver system, add getters
- `contracts/test/TOCRegistry.t.sol` - Update tests

### Documentation

- `docs/TOC_SYSTEM_DOCUMENTATION.md` - Reflect new design
- `docs/plans/` - This document and resolver simplification doc
