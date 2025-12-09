# Truth on Chain (TOC) - Architecture Documentation

## Table of Contents

1. [Overview](#overview)
2. [Core Concepts](#core-concepts)
3. [System Architecture](#system-architecture)
4. [POP Lifecycle](#pop-lifecycle)
5. [Resolver System](#resolver-system)
6. [Dispute Resolution](#dispute-resolution)
7. [Accountability Model](#accountability-model)
8. [Bond Economics](#bond-economics)
9. [Result Storage](#result-storage)
10. [Design Decisions & Trade-offs](#design-decisions--trade-offs)

---

## Overview

Truth on Chain (TOC) is a modular infrastructure layer for creating, resolving, and disputing verifiable predictions on-chain. The system introduces a **Prediction Option Protocol (POP)** - a standardized unit of truth that can be created, resolved, disputed, and consumed by any protocol.

### Core Value Proposition

Traditional oracles answer: "What is the price of ETH?"

TOC answers: "What is the truth, who vouches for it, and how much financial security backs the claim?"

Every answer in TOC carries:
- The result itself (boolean, numeric, or arbitrary bytes)
- An accountability tier (SYSTEM, TK_GUARANTEED, or PERMISSIONLESS)
- A resolution history (original answer, disputes, corrections)
- Financial backing (bonds posted by proposers and disputants)

---

## Core Concepts

### POP (Prediction Option Protocol)

A POP is the fundamental unit in TOC. It represents a question that will be resolved to an answer.

**Anatomy of a POP:**
- **Resolver** → The contract responsible for determining the answer
- **Template** → A reusable question format defined by the resolver
- **Payload** → Question-specific parameters (e.g., asset, threshold, deadline)
- **TruthKeeper** → The domain expert assigned to adjudicate disputes
- **Time windows** → Configurable periods for disputes, escalation, and correction
- **Accountability tier** → Immutable snapshot of trust level at creation

### Resolvers

Resolvers are pluggable contracts that handle domain-specific resolution logic. The registry doesn't care how a resolver determines truth - it only cares that the resolver implements the standard interface.

Examples:
- **PythPriceResolver** → Pulls price data from Pyth oracles
- **OptimisticResolver** → Accepts human-submitted answers with dispute protection
- **Custom resolvers** → Any logic you need (API data, on-chain state, voting, etc.)

### TruthKeepers

TruthKeepers are whitelisted addresses with domain expertise. They:
- Get assigned to POPs at creation time
- Adjudicate Round 1 disputes
- Can declare which resolvers they guarantee (affecting accountability tier)
- Face timeout penalties if they fail to act

### Accountability Tiers

Every POP has an immutable accountability tier captured at creation:

| Tier | Derivation | Meaning |
|------|------------|---------|
| **SYSTEM** | SYSTEM resolver + whitelisted TruthKeeper | Maximum protocol backing |
| **TK_GUARANTEED** | TruthKeeper has guaranteed this resolver | TruthKeeper stakes reputation |
| **PERMISSIONLESS** | Everything else | Consumer assumes risk |

---

## System Architecture

### Component Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Consumer Protocols                      │
│         (Prediction Markets, Insurance, Derivatives)         │
└─────────────────────────────┬───────────────────────────────┘
                              │ getResult() / getExtensiveResult()
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                        POPRegistry                           │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Resolver  │  │     POP     │  │      Dispute        │  │
│  │  Management │  │  Lifecycle  │  │     Resolution      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │    Bond     │  │   Result    │  │    TruthKeeper      │  │
│  │   System    │  │   Storage   │  │     Management      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────┬───────────────────────────────┘
                              │ onPopCreated() / resolvePop()
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                         Resolvers                            │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐    │
│  │ PythPrice     │  │  Optimistic   │  │    Custom     │    │
│  │ Resolver      │  │   Resolver    │  │   Resolver    │    │
│  └───────────────┘  └───────────────┘  └───────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Key Storage Structures

```solidity
// Resolver trust levels
mapping(address => ResolverConfig) _resolverConfigs;

// All registered resolvers
EnumerableSet.AddressSet _registeredResolvers;

// POP state machines
mapping(uint256 => POP) _pops;

// Unified result storage (ABI-encoded bytes)
mapping(uint256 => bytes) _results;

// Round 1 dispute information
mapping(uint256 => DisputeInfo) _disputes;

// Round 2 escalation information
mapping(uint256 => EscalationInfo) _escalations;

// TruthKeeper guaranteed resolvers
mapping(address => EnumerableSet.AddressSet) _tkGuaranteedResolvers;
```

---

## POP Lifecycle

### State Machine

```
                    ┌──────────┐
                    │   NONE   │
                    └────┬─────┘
                         │ createPOP()
                         ▼
                    ┌──────────┐
          ┌─────────│ PENDING  │─────────┐
          │         └────┬─────┘         │
          │ reject()     │ activate()    │
          ▼              ▼               │
    ┌──────────┐   ┌──────────┐          │
    │ REJECTED │   │  ACTIVE  │          │
    └──────────┘   └────┬─────┘          │
                        │ resolvePOP()   │
                        ▼                │
                   ┌───────────┐         │
                   │ RESOLVING │         │
                   └─────┬─────┘         │
            ┌────────────┼────────────┐  │
            │ no dispute │ dispute()  │  │
            ▼            ▼            │  │
      ┌──────────┐ ┌─────────────────┐│  │
      │ RESOLVED │ │ DISPUTED_ROUND_1││  │
      └────┬─────┘ └────────┬────────┘│  │
           │                │         │  │
           │     ┌──────────┴─────┐   │  │
           │     │ TK decides OR  │   │  │
           │     │ escalation     │   │  │
           │     ▼                │   │  │
           │ ┌─────────────────┐  │   │  │
           │ │ DISPUTED_ROUND_2│  │   │  │
           │ └────────┬────────┘  │   │  │
           │          │ admin     │   │  │
           │          │ resolves  │   │  │
           │          ▼           │   │  │
           │    ┌──────────┐      │   │  │
           └───►│ RESOLVED │◄─────┘   │  │
                └────┬─────┘          │  │
                     │                │  │
                     ▼                │  │
                ┌──────────┐          │  │
                │CANCELLED │◄─────────┴──┘
                └──────────┘
```

### Lifecycle Phases

**1. Creation**
```solidity
function createPOP(
    address resolver,
    uint32 templateId,
    bytes calldata payload,
    address truthKeeper,
    uint32 disputeWindow,
    uint32 truthKeeperWindow,
    uint32 escalationWindow,
    uint32 postResolutionWindow
) external returns (uint256 popId);
```

- Resolver validates payload via `onPopCreated()`
- Resolver returns initial state (PENDING or ACTIVE)
- Accountability tier calculated and frozen
- Time windows stored for later use

**2. Resolution**
```solidity
function resolvePOP(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    bytes calldata payload
) external;
```

- Proposer stakes resolution bond
- Resolver executes `resolvePop()` and returns ABI-encoded result
- Dispute window opens
- State → RESOLVING

**3. Dispute (Optional)**
```solidity
function disputePOP(
    uint256 popId,
    address bondToken,
    uint256 bondAmount
) external;
```

- Disputer stakes higher bond than proposer
- State → DISPUTED_ROUND_1
- TruthKeeper has `truthKeeperWindow` to decide

**4. Finalization**
```solidity
function finalizePOP(uint256 popId) external;
```

- Called after dispute window expires (if no dispute)
- Or after dispute resolution completes
- State → RESOLVED

---

## Resolver System

### Interface

Every resolver must implement:

```solidity
interface IPopResolver {
    // Called when POP is created - validate and store question data
    function onPopCreated(
        uint256 popId,
        uint32 templateId,
        bytes calldata payload
    ) external returns (POPState initialState);

    // Called to resolve - return ABI-encoded result
    function resolvePop(
        uint256 popId,
        address caller,
        bytes calldata payload
    ) external returns (bytes memory result);

    // Human-readable question for UI/display
    function getPopQuestion(uint256 popId)
        external view returns (string memory);

    // Template metadata
    function getTemplateCount() external view returns (uint32);
    function isValidTemplate(uint32 templateId) external view returns (bool);
    function getTemplateAnswerType(uint32 templateId)
        external view returns (AnswerType);
}
```

### Answer Types

```solidity
enum AnswerType {
    NONE,      // Invalid/unset
    BOOLEAN,   // Yes/No - encoded as abi.encode(bool)
    NUMERIC,   // Integer - encoded as abi.encode(int256)
    GENERIC    // Arbitrary - raw bytes
}
```

### Resolver Trust Levels

```solidity
enum ResolverTrust {
    NONE,           // Not registered
    PERMISSIONLESS, // Registered, no vetting
    VERIFIED,       // Admin-reviewed
    SYSTEM          // Official ecosystem resolver
}
```

### Example: PythPriceResolver

Templates:
- **Template 0 (Snapshot)**: Is price above/below threshold at deadline?
- **Template 1 (Range)**: Is price within [min, max] at deadline?
- **Template 2 (Reached By)**: Did price reach target before deadline?

All return BOOLEAN results via `POPResultCodec.encodeBoolean()`.

### Example: OptimisticResolver

Templates:
- **Template 0 (Arbitrary)**: Free-form yes/no with description
- **Template 1 (Sports)**: Structured games (winner, spread, over-under)
- **Template 2 (Event)**: Did specific event occur?

Supports clarifications and question updates before resolution.

---

## Dispute Resolution

### Two-Round System

**Round 1: TruthKeeper Review**

```
Dispute filed → TruthKeeper assigned → Decision within window
                                              │
                    ┌─────────────────────────┼─────────────────────────┐
                    ▼                         ▼                         ▼
              UPHOLD_DISPUTE            REJECT_DISPUTE             CANCEL_POP
              (disputer wins)           (proposer wins)           (void, refund)
```

If TruthKeeper times out → auto-escalate to Round 2.

**Round 2: Admin Escalation**

Any party can challenge the Round 1 decision by posting an escalation bond (higher than Round 1 bond).

```
Escalation filed → Admin reviews → Final decision
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              UPHOLD_DISPUTE      REJECT_DISPUTE       CANCEL_POP
```

Admin decision is final.

### Decision Types

```solidity
enum DisputeResolution {
    UPHOLD_DISPUTE,   // Disputer was right, proposer wrong
    REJECT_DISPUTE,   // Proposer was right, disputer wrong
    CANCEL_POP,       // Question invalid, void everything
    TOO_EARLY         // Cannot decide yet
}
```

### Post-Resolution Disputes

Even after RESOLVED state, if `postResolutionWindow > 0`:
- Anyone can dispute the finalized result
- Same two-round process applies
- If upheld, result is corrected (original preserved in history)
- `_hasCorrectedResult` flag tracks corrections

---

## Accountability Model

### Tier Calculation

At POP creation, accountability tier is calculated and frozen:

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

### Why Immutable Snapshots?

The tier is captured at creation and never changes because:
- Consumers know accountability upfront before interacting
- Prevents retroactive trust downgrades
- Resolver upgrades don't affect existing POPs
- Clear audit trail for historical analysis

### Consumer Usage

```solidity
// Simple: just get the answer
bytes memory result = registry.getResult(popId);

// Comprehensive: get answer + context
ExtensiveResult memory extensive = registry.getExtensiveResult(popId);
// extensive.result - the answer
// extensive.finalized - is it final?
// extensive.tier - accountability level
// extensive.hasCorrectedResult - was it corrected?
```

---

## Bond Economics

### Purpose

Bonds create economic incentives for honest behavior:
- **Proposers** stake capital behind their answers
- **Disputers** stake capital to challenge
- **Losers** get slashed → discourages frivolous participation
- **Winners** get paid → rewards truth-seeking

### Bond Flow

**Resolution Bond (posted by proposer):**
| Outcome | Proposer's Bond |
|---------|-----------------|
| No dispute | Returned in full |
| Dispute rejected | Returned in full |
| Dispute upheld | 50% to disputer, 50% to protocol |
| POP cancelled | Returned in full |

**Dispute Bond (posted by disputer):**
| Outcome | Disputer's Bond |
|---------|-----------------|
| Dispute upheld | Returned in full |
| Dispute rejected | 50% to proposer, 50% to protocol |
| POP cancelled | Returned in full |

**Escalation Bond (Round 2):**
| Outcome | Challenger's Bond |
|---------|-------------------|
| Challenge succeeds | Returned + 50% of opponent's Round 1 winnings |
| Challenge fails | 50% to opponent, 50% to protocol |

### The 50/50 Split

Why split slashed bonds between winner and protocol?
- Winner incentive: rewards truth-seeking
- Protocol incentive: sustains the system, prevents collusion

---

## Result Storage

### Unified Bytes Approach

All results stored as ABI-encoded bytes:

```solidity
// Storage
mapping(uint256 => bytes) _results;

// Encoding
bool answer = true;
bytes memory encoded = abi.encode(answer);  // 32 bytes

int256 price = 47231;
bytes memory encoded = abi.encode(price);   // 32 bytes

bytes memory arbitrary = customData;        // variable length
```

### POPResultCodec Helper

```solidity
library POPResultCodec {
    function encodeBoolean(bool value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    function encodeNumeric(int256 value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    function decodeBoolean(bytes memory data) internal pure returns (bool) {
        return abi.decode(data, (bool));
    }

    function decodeNumeric(bytes memory data) internal pure returns (int256) {
        return abi.decode(data, (int256));
    }
}
```

### Why Unified Storage?

Previous approach: separate mappings for bool, int256, bytes results.

Problems:
- 6 storage mappings instead of 2
- Conditional branching in state machine
- New answer types required contract changes

Unified approach:
- Single `_results` mapping
- Answer type stored in POP metadata
- Decoder library handles type-specific extraction
- Future types need zero contract changes

---

## Design Decisions & Trade-offs

### 1. Address-Based Resolver IDs (vs. Numeric IDs)

**Decision:** Use resolver contract addresses directly instead of registry-assigned numeric IDs.

**Trade-offs:**
| Aspect | Address-Based | Numeric IDs |
|--------|---------------|-------------|
| Uniqueness | Globally unique | Registry-scoped |
| Lookup | Direct | Mapping indirection |
| Gas | Slightly higher calldata | Lower calldata |
| Intuition | More intuitive | Less intuitive |

**Rationale:** Simplicity and intuitiveness outweigh minor gas differences.

### 2. Permissionless Resolver Registration

**Decision:** Anyone can register a resolver. Trust level managed separately.

**Trade-offs:**
| Aspect | Permissionless | Gated |
|--------|----------------|-------|
| Innovation | Maximum | Limited |
| Security | Consumer must check trust | Registry vouches |
| Spam | Possible (mitigated by trust levels) | Prevented |

**Rationale:** Explicit trust levels let consumers decide. Don't gate innovation.

### 3. Per-POP Time Windows (vs. Global)

**Decision:** Each POP specifies its own dispute/escalation windows.

**Trade-offs:**
| Aspect | Per-POP | Global |
|--------|---------|--------|
| Flexibility | High | Low |
| Complexity | Higher | Lower |
| Gas | Slightly higher | Lower |

**Rationale:** Different use cases need different finality speeds. A sports bet can't wait weeks.

### 4. Two-Round Dispute (vs. Single Round)

**Decision:** TruthKeeper first, then admin escalation.

**Trade-offs:**
| Aspect | Two-Round | Single |
|--------|-----------|--------|
| Cost | Higher (two bonds) | Lower |
| Accuracy | Higher (two reviews) | Lower |
| Finality | Slower (potential escalation) | Faster |

**Rationale:** High-value decisions need escalation paths. TruthKeeper handles most cases efficiently.

### 5. Immutable Accountability Snapshots

**Decision:** Tier calculated at creation, never changes.

**Trade-offs:**
| Aspect | Immutable | Dynamic |
|--------|-----------|---------|
| Predictability | High | Low |
| Flexibility | Lower | Higher |
| Trust | Clear upfront | Can change |

**Rationale:** Consumers need to know what they're getting when they integrate.

### 6. Resolver as Black Box

**Decision:** Registry doesn't know or care how resolvers work internally.

**Trade-offs:**
| Aspect | Black Box | Opinionated |
|--------|-----------|-------------|
| Flexibility | Maximum | Limited |
| Safety | Resolver risk | Registry can validate |
| Innovation | Unconstrained | Constrained |

**Rationale:** Trust levels handle safety. Don't limit what resolvers can do.

---

## Appendix: Key Types Reference

```solidity
enum POPState {
    NONE, PENDING, REJECTED, ACTIVE, RESOLVING,
    DISPUTED_ROUND_1, DISPUTED_ROUND_2, RESOLVED, CANCELLED
}

enum AnswerType { NONE, BOOLEAN, NUMERIC, GENERIC }

enum ResolverTrust { NONE, PERMISSIONLESS, VERIFIED, SYSTEM }

enum AccountabilityTier { NONE, PERMISSIONLESS, TK_GUARANTEED, SYSTEM }

enum DisputeResolution { UPHOLD_DISPUTE, REJECT_DISPUTE, CANCEL_POP, TOO_EARLY }

struct POP {
    address resolver;
    address creator;
    address truthKeeper;
    uint32 templateId;
    AnswerType answerType;
    POPState state;
    AccountabilityTier tier;
    uint32 disputeWindow;
    uint32 truthKeeperWindow;
    uint32 escalationWindow;
    uint32 postResolutionWindow;
    uint64 createdAt;
    uint64 resolvedAt;
}

struct ExtensiveResult {
    bytes result;
    bool finalized;
    bool disputed;
    bool hasCorrectedResult;
    AccountabilityTier tier;
    ResolverTrust resolverTrust;
}
```
