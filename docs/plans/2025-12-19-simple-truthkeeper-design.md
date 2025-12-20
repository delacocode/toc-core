# SimpleTruthKeeper Design

## Overview

A minimal TruthKeeper (TK) contract for initial launch with resolver allowlist and configurable time window validation.

## Core Behavior

**Approval logic (returns APPROVE only if ALL conditions met):**
- Resolver is on allowlist
- disputeWindow >= minimum (per-resolver override OR global default)
- truthKeeperWindow >= minimum (per-resolver override OR global default)

**Otherwise:** Returns REJECT_SOFT (TOC created at RESOLVER tier, no TK guarantee)

## Storage

```solidity
address public owner;
address public registry;

// Global defaults
uint32 public defaultMinDisputeWindow;      // e.g., 1 hour
uint32 public defaultMinTruthKeeperWindow;  // e.g., 4 hours

// Resolver allowlist
mapping(address => bool) public allowedResolvers;

// Per-resolver time window overrides (0 = use global default)
mapping(address => uint32) public resolverMinDisputeWindow;
mapping(address => uint32) public resolverMinTruthKeeperWindow;
```

## Contract Structure

```
SimpleTruthKeeper
├── Constructor(registry, owner, defaultDisputeWindow, defaultTkWindow)
│
├── ITruthKeeper Implementation
│   ├── canAcceptToc() → view, calls _evaluate()
│   └── onTocAssigned() → onlyRegistry, calls _evaluate()
│
├── Internal
│   └── _evaluate() → checks allowlist + time windows
│
├── Owner Functions
│   ├── setDefaultMinWindows()
│   ├── setResolverAllowed()
│   ├── setResolverMinWindows()
│   ├── setResolversAllowed()  // batch
│   ├── transferOwnership()
│   └── setRegistry()
│
└── View Helpers
    ├── getEffectiveMinWindows(resolver) → returns actual minimums
    └── isResolverAllowed(resolver) → bool
```

## Events

- `ResolverAllowedChanged(address indexed resolver, bool allowed)`
- `DefaultMinWindowsChanged(uint32 disputeWindow, uint32 tkWindow)`
- `ResolverMinWindowsChanged(address indexed resolver, uint32 disputeWindow, uint32 tkWindow)`
- `OwnershipTransferred(address indexed oldOwner, address indexed newOwner)`

## Design Decisions

1. **Resolver-only allowlist** - Simpler than creator filtering, trust is at resolver level
2. **REJECT_SOFT for all rejections** - Permissive approach allows TOCs to exist at RESOLVER tier
3. **Per-resolver time overrides** - Flexibility for different resolver requirements
4. **Single owner model** - Simple for launch, can be set to multi-sig later
5. **Only disputeWindow + truthKeeperWindow** - These are the windows TK needs to operate safely
