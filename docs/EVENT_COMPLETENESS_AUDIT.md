# Event Completeness Audit

This document analyzes the current event coverage in the TOC-Core contracts and identifies gaps that could improve indexing capabilities.

## Current Event Coverage Summary

| Category | Events | Coverage |
|----------|--------|----------|
| Resolver Management | 2 | Complete |
| TruthKeeper Registry | 4 | Complete |
| TOC Lifecycle | 4 | Complete |
| Resolution | 3 | Complete |
| Pre-Resolution Disputes | 2 | Complete |
| Post-Resolution Disputes | 2 | Complete |
| TruthKeeper Dispute Flow | 4 | Complete |
| Bonds | 7 | **Complete** |
| Bond Configuration | 1 | **Complete** |
| Window Configuration | 1 | **Complete** |
| Enhanced Core Events | 4 | **Complete** |
| Fees | 9 | Complete |
| Price Resolver | 18 | Complete |
| Optimistic Resolver | 5 | Complete |
| SimpleTruthKeeper | 5 | Complete |

**Total Events: 71**

> **Note**: All events are now complete for full subgraph indexing:
> - **4 new events added**: `EscalationBondDeposited`, `EscalationBondReturned`, `AcceptableBondAdded`, `DefaultDisputeWindowChanged`
> - **4 events enhanced**: `TOCCreated` (+ creator, time windows), `TOCDisputed` (+ evidenceURI), `PostResolutionDisputeFiled` (+ evidenceURI, proposedResult), `TruthKeeperDecisionChallenged` (+ evidenceURI, proposedResult)
> - **No workarounds needed** - all critical data is available directly in events

---

## Recently Added Events

The following events were added to complete the event coverage:

### 1. EscalationBondDeposited ✅ IMPLEMENTED

```solidity
event EscalationBondDeposited(
    uint256 indexed tocId,
    address indexed challenger,
    address token,
    uint256 amount
);
```

**Emitted in**: `TruthEngine.sol:challengeTruthKeeperDecision()` after bond transfer

---

### 2. EscalationBondReturned ✅ IMPLEMENTED

```solidity
event EscalationBondReturned(
    uint256 indexed tocId,
    address indexed to,
    address token,
    uint256 amount
);
```

**Emitted in**: `TruthEngine.sol:resolveEscalation()` when returning escalation bonds

---

### 3. AcceptableBondAdded ✅ IMPLEMENTED

```solidity
event AcceptableBondAdded(
    string bondType,    // "RESOLUTION" | "DISPUTE" | "ESCALATION"
    address indexed token,
    uint256 minAmount
);
```

**Emitted in**:
- `TruthEngine.sol:addAcceptableResolutionBond()` with bondType="RESOLUTION"
- `TruthEngine.sol:addAcceptableDisputeBond()` with bondType="DISPUTE"
- `TruthEngine.sol:addAcceptableEscalationBond()` with bondType="ESCALATION"

---

### 4. DefaultDisputeWindowChanged ✅ IMPLEMENTED

```solidity
event DefaultDisputeWindowChanged(
    uint256 oldDuration,
    uint256 newDuration
);
```

**Emitted in**: `TruthEngine.sol:setDefaultDisputeWindow()`

---

## Optional Future Enhancements

### Generic State Change Event (OPTIONAL)

**Problem**: State changes must be inferred from multiple different events.

**Current Behavior**: Different events trigger state changes (TOCCreated, TOCApproved, TOCDisputed, etc.) and indexers must know which events cause which transitions.

**Possible Enhancement**: A unified state change event would simplify indexing logic:

```solidity
event TOCStateChanged(
    uint256 indexed tocId,
    TOCState indexed fromState,
    TOCState indexed toState,
    address triggeredBy
);
```

**Trade-off**: Additional gas cost for every state transition. Current approach is more gas-efficient.

---

### TOC Details in Creation Event (OPTIONAL)

**Problem**: `TOCCreated` doesn't include time windows or creator address.

**Current Behavior**: These must be fetched via `getTOC()` contract call.

**Trade-off**: Adding more fields would increase gas costs. Current design prioritizes gas efficiency.

---

## Enhanced Events

The following events were enhanced to include additional data:

### 1. TOCCreated - Now includes creator and time windows

```solidity
event TOCCreated(
    uint256 indexed tocId,
    address indexed resolver,
    address indexed creator,     // NEW: creator address
    ResolverTrust trust,
    uint32 templateId,
    AnswerType answerType,
    TOCState initialState,
    address truthKeeper,
    AccountabilityTier tier,
    uint32 disputeWindow,        // NEW: time windows
    uint32 truthKeeperWindow,
    uint32 escalationWindow,
    uint32 postResolutionWindow
);
```

### 2. TOCDisputed - Now includes evidence URI

```solidity
event TOCDisputed(
    uint256 indexed tocId,
    address indexed disputer,
    string reason,
    string evidenceURI           // NEW
);
```

### 3. PostResolutionDisputeFiled - Now includes evidence and proposed result

```solidity
event PostResolutionDisputeFiled(
    uint256 indexed tocId,
    address indexed disputer,
    string reason,
    string evidenceURI,          // NEW
    bytes proposedResult         // NEW
);
```

### 4. TruthKeeperDecisionChallenged - Now includes evidence and proposed result

```solidity
event TruthKeeperDecisionChallenged(
    uint256 indexed tocId,
    address indexed challenger,
    string reason,
    string evidenceURI,          // NEW
    bytes proposedResult         // NEW
);
```

---

## Events That Are Complete

### TruthEngine - Well Covered

- Resolver registration and trust changes
- TruthKeeper whitelisting and approval responses
- Full TOC lifecycle (create, approve, reject, transfer)
- Resolution proposal and finalization
- Dispute filing and resolution
- All fee collection and withdrawal events

### PythPriceResolverV2 - Excellent Coverage

- Template-specific creation events with all parameters
- Resolution outcome with price proof
- Reference price setting events

### OptimisticResolver - Complete

- Question creation with preview
- Resolution proposal with justification
- Full clarification workflow (request/accept/reject)

### SimpleTruthKeeper - Complete

- Resolver allowlist changes
- Window configuration changes
- Ownership and registry updates

---

## Data Now Fully Available in Events

All critical indexing data is now available directly in events - **no contract calls required** for subgraph indexing:

| Data | Event | Status |
|------|-------|--------|
| TOC creator | `TOCCreated` | ✅ Now in event |
| TOC time windows | `TOCCreated` | ✅ Now in event |
| Dispute evidence URI | `TOCDisputed`, `PostResolutionDisputeFiled` | ✅ Now in event |
| Dispute proposed result | `PostResolutionDisputeFiled` | ✅ Now in event |
| Escalation evidence URI | `TruthKeeperDecisionChallenged` | ✅ Now in event |
| Escalation proposed result | `TruthKeeperDecisionChallenged` | ✅ Now in event |
| Bond configurations | `AcceptableBondAdded` | ✅ Now in event |
| Escalation bonds | `EscalationBondDeposited`, `EscalationBondReturned` | ✅ Now in event |
| Window config changes | `DefaultDisputeWindowChanged` | ✅ Now in event |

### Optional Contract Calls

For additional data not critical for indexing:

| Data | Contract | Function |
|------|----------|----------|
| Resolution proposed result | TruthEngine | `getResolutionInfo(tocId)` |
| Resolver template fees lookup | TruthEngine | `getResolverFee(resolver, templateId)` |
| Question full payload | OptimisticResolver | `getTocDetails(tocId)` |
| Price condition payload | PythPriceResolverV2 | `getTocDetails(tocId)` |
| Computed deadlines | TruthEngine | `getTOC(tocId)` |

---

## Conclusion

The TOC-Core event system is now **fully complete** for subgraph indexing. All critical data is emitted in events, eliminating the need for contract call workarounds.

### Summary of Changes Made

| Category | Events Added/Enhanced |
|----------|----------------------|
| New events | `EscalationBondDeposited`, `EscalationBondReturned`, `AcceptableBondAdded`, `DefaultDisputeWindowChanged` |
| Enhanced events | `TOCCreated` (+ creator, time windows), `TOCDisputed` (+ evidenceURI), `PostResolutionDisputeFiled` (+ evidenceURI, proposedResult), `TruthKeeperDecisionChallenged` (+ evidenceURI, proposedResult) |

**Total events: 71** (previously 63)
