# TruthKeeper Two-Round Dispute System Design

**Date:** 2025-12-06
**Status:** Approved for Implementation

---

## Overview

Extend the POP protocol with a two-round dispute mechanism inspired by Polymarket/UMA, using TruthKeepers for Round 1 adjudication and Admin/Community for Round 2 escalation.

---

## Design Decisions

| Decision | Choice |
|----------|--------|
| Dispute rounds | Two rounds: TruthKeeper → Admin/Community |
| TruthKeeper assignment | Per-POP from global registry |
| TruthKeeper guarantees | TK self-declares which resolvers they guarantee |
| System accountability | 3 tiers: SYSTEM, TK_GUARANTEED, PERMISSIONLESS |
| Tier storage | Immutable snapshot at POP creation |
| TK timeout behavior | Auto-escalate to Round 2 |
| Escalation bond | Separate configurable list (higher than Round 1) |
| Bond economics | Winner gets 50% of loser, contract gets 50% |
| TOO_EARLY outcome | Explicit resolution type, POP returns to ACTIVE |
| Evidence | Add `evidenceURI` field for IPFS/Arweave links |

---

## Future Considerations

**TruthKeeper Accountability (deferred):**
- TKs should be able to set minimum `truthKeeperWindow` they guarantee to meet
- If POP creator sets window below TK's minimum → reject or mark non-guaranteed
- Consider staking/slashing mechanism for missed guarantees

---

## State Flow

```
ACTIVE
   │
   ▼ resolvePOP() - Proposer posts bond
RESOLVING
   │
   ├── No dispute within disputeWindow
   │   └──────────────────────────────────────► RESOLVED
   │
   └── Dispute filed (Round 1 bond)
       │
       ▼
DISPUTED_ROUND_1
   │
   ├── TruthKeeper decides within truthKeeperWindow
   │   │
   │   ├── No challenge within escalationWindow
   │   │   └──────────────────────────────────► RESOLVED
   │   │
   │   └── Challenge filed (Escalation bond = higher)
   │       │
   │       ▼
   │   DISPUTED_ROUND_2
   │       │
   │       └── Admin/Community decides
   │           └──────────────────────────────► RESOLVED / ACTIVE (if TOO_EARLY)
   │
   └── TruthKeeper times out
       │
       ▼
   DISPUTED_ROUND_2 (auto-escalate)
       │
       └── Admin/Community decides
           └──────────────────────────────────► RESOLVED / ACTIVE (if TOO_EARLY)
```

---

## Accountability Tiers

```
┌─────────────────────────────────────────────────────────────────────┐
│ TIER 1: SYSTEM (Full Accountability)                                │
│ • Resolver is in _whitelistedResolvers                              │
│ • TruthKeeper is in _whitelistedTruthKeepers                        │
│ • System guarantees dispute handling                                │
├─────────────────────────────────────────────────────────────────────┤
│ TIER 2: TK_GUARANTEED (Partial Accountability)                      │
│ • TruthKeeper has marked resolver in their guaranteed list          │
│ • TK is accountable, system is not                                  │
├─────────────────────────────────────────────────────────────────────┤
│ TIER 3: PERMISSIONLESS (No Accountability)                          │
│ • Any resolver + Any TK combination                                 │
│ • Creator's risk                                                    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Bond Economics

### Round 1 Dispute (vs Proposer)

| Outcome | Proposer Bond | Disputer Bond |
|---------|---------------|---------------|
| UPHOLD_DISPUTE | 50% to disputer, 50% to contract | Returned |
| REJECT_DISPUTE | Returned | 50% to proposer, 50% to contract |
| CANCEL_POP | Returned | Returned |
| TOO_EARLY | 50% to disputer, 50% to contract | Returned |

### Round 2 Escalation (vs TK Decision)

| Outcome | Challenger Bond (2X) | Round 1 Winner Bond |
|---------|---------------------|---------------------|
| Challenger wins | Returned + 50% of opponent | 50% to challenger, 50% to contract |
| Challenger loses | 50% to opponent, 50% to contract | Returned |

---

## New Enums

```solidity
enum AccountabilityTier {
    NONE,
    PERMISSIONLESS,
    TK_GUARANTEED,
    SYSTEM
}

enum DisputeResolution {
    UPHOLD_DISPUTE,
    REJECT_DISPUTE,
    CANCEL_POP,
    TOO_EARLY
}

enum POPState {
    NONE,
    PENDING,
    REJECTED,
    ACTIVE,
    RESOLVING,
    DISPUTED_ROUND_1,
    DISPUTED_ROUND_2,
    RESOLVED,
    CANCELLED
}
```

---

## Updated Structs

### POP Struct

```solidity
struct POP {
    address resolver;
    POPState state;
    AnswerType answerType;
    uint256 resolutionTime;

    // Time windows (user-specified per-POP)
    uint256 disputeWindow;           // Time to dispute initial proposal
    uint256 truthKeeperWindow;       // Time for TK to decide Round 1
    uint256 escalationWindow;        // Time to challenge TK decision
    uint256 postResolutionWindow;    // Time to dispute after RESOLVED

    // Computed deadlines
    uint256 disputeDeadline;
    uint256 truthKeeperDeadline;     // NEW
    uint256 escalationDeadline;      // NEW
    uint256 postDisputeDeadline;

    // TruthKeeper
    address truthKeeper;
    AccountabilityTier tierAtCreation;
}
```

### DisputeInfo Struct

```solidity
struct DisputeInfo {
    DisputePhase phase;
    address disputer;
    address bondToken;
    uint256 bondAmount;
    string reason;
    string evidenceURI;              // NEW
    uint256 filedAt;
    uint256 resolvedAt;
    bool resultCorrected;

    // Disputer's proposed correction
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;

    // TruthKeeper decision (NEW)
    DisputeResolution tkDecision;
    uint256 tkDecidedAt;
}
```

### EscalationInfo Struct (NEW)

```solidity
struct EscalationInfo {
    address challenger;
    address bondToken;
    uint256 bondAmount;
    string reason;
    string evidenceURI;
    uint256 filedAt;
    uint256 resolvedAt;

    // Challenger's proposed correction
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;
}
```

---

## New Storage

```solidity
// TruthKeeper registry
EnumerableSet.AddressSet private _whitelistedTruthKeepers;
EnumerableSet.AddressSet private _whitelistedResolvers;
mapping(address => EnumerableSet.AddressSet) private _tkGuaranteedResolvers;

// Escalation bonds (Round 2)
BondRequirement[] private _acceptableEscalationBonds;

// Escalation info
mapping(uint256 => EscalationInfo) private _escalations;
```

---

## New Functions

### Admin Functions

```solidity
// TruthKeeper whitelist management
function addWhitelistedTruthKeeper(address tk) external onlyOwner;
function removeWhitelistedTruthKeeper(address tk) external onlyOwner;

// Resolver whitelist management
function addWhitelistedResolver(address resolver) external onlyOwner;
function removeWhitelistedResolver(address resolver) external onlyOwner;

// Escalation bond configuration
function addAcceptableEscalationBond(address token, uint256 minAmount) external onlyOwner;
```

### TruthKeeper Functions

```solidity
// TK self-declares guaranteed resolvers
function addGuaranteedResolver(address resolver) external;
function removeGuaranteedResolver(address resolver) external;

// TK resolves Round 1 dispute
function resolveTruthKeeperDispute(
    uint256 popId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external;
```

### Public Functions

```solidity
// Updated creation with TK and windows
function createPOPWithSystemResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 truthKeeperWindow,
    uint256 escalationWindow,
    uint256 postResolutionWindow,
    address truthKeeper
) external returns (uint256 popId);

// Updated dispute with evidence
function dispute(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable;

// Challenge TruthKeeper decision (Round 2)
function challengeTruthKeeperDecision(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable;

// Finalize after TK decision (if no challenge)
function finalizeAfterTruthKeeper(uint256 popId) external;

// Auto-escalate if TK times out
function escalateTruthKeeperTimeout(uint256 popId) external;
```

### View Functions

```solidity
function isWhitelistedTruthKeeper(address tk) external view returns (bool);
function isWhitelistedResolver(address resolver) external view returns (bool);
function getTruthKeeperGuaranteedResolvers(address tk) external view returns (address[] memory);
function getEscalationInfo(uint256 popId) external view returns (EscalationInfo memory);
function getAccountabilityTier(address resolver, address tk) external view returns (AccountabilityTier);
```

---

## New Events

```solidity
// TruthKeeper registry
event TruthKeeperWhitelisted(address indexed tk);
event TruthKeeperRemovedFromWhitelist(address indexed tk);
event ResolverWhitelisted(address indexed resolver);
event ResolverRemovedFromWhitelist(address indexed resolver);
event TruthKeeperGuaranteeAdded(address indexed tk, address indexed resolver);
event TruthKeeperGuaranteeRemoved(address indexed tk, address indexed resolver);

// Dispute flow
event TruthKeeperDisputeResolved(uint256 indexed popId, address indexed tk, DisputeResolution resolution);
event TruthKeeperDecisionChallenged(uint256 indexed popId, address indexed challenger, string reason);
event TruthKeeperTimedOut(uint256 indexed popId, address indexed tk);
event EscalationResolved(uint256 indexed popId, DisputeResolution resolution, address indexed admin);
```

---

## Implementation Order

1. **POPTypes.sol** - Add new enums, update structs
2. **IPOPRegistry.sol** - Add new function signatures and events
3. **POPRegistry.sol** - TruthKeeper registry storage and admin functions
4. **POPRegistry.sol** - Update POP creation with TK and tier
5. **POPRegistry.sol** - Update dispute() with evidenceURI
6. **POPRegistry.sol** - Add resolveTruthKeeperDispute() (TK only)
7. **POPRegistry.sol** - Add challengeTruthKeeperDecision() (Round 2)
8. **POPRegistry.sol** - Add escalateTruthKeeperTimeout()
9. **POPRegistry.sol** - Add finalizeAfterTruthKeeper()
10. **POPRegistry.sol** - Update resolveDispute() for Round 2 with TOO_EARLY
11. **POPRegistry.sol** - Update bond economics (50/50 split)
12. **POPRegistry.sol** - Add new view functions
13. **Tests** - Comprehensive test coverage
14. **Documentation** - Update POP_SYSTEM_DOCUMENTATION.md

---

## Test Scenarios

1. Happy path: Propose → No dispute → Resolved
2. Round 1 dispute → TK upholds → No challenge → Resolved
3. Round 1 dispute → TK rejects → No challenge → Resolved
4. Round 1 dispute → TK upholds → Challenge → Admin upholds challenger
5. Round 1 dispute → TK upholds → Challenge → Admin rejects challenger
6. Round 1 dispute → TK times out → Auto-escalate → Admin resolves
7. TOO_EARLY resolution → POP returns to ACTIVE
8. CANCEL_POP → All bonds returned
9. Tier calculation: SYSTEM, TK_GUARANTEED, PERMISSIONLESS
10. Bond economics: 50/50 splits in all scenarios
11. Escalation bond validation (higher than Round 1)
12. Post-resolution dispute still works after TK flow

---

## Comparison to Polymarket/UMA

| Feature | Polymarket/UMA | POP TruthKeeper System |
|---------|----------------|------------------------|
| Round 1 | Reset (no adjudication) | TruthKeeper adjudicates |
| Round 2 | UMA DVM token vote | Admin/Community |
| Escalation cost | ~$10k-$50k UMA stake | Configurable (e.g., $1500) |
| Resolution outcomes | Yes/No/Too Early/Unknown | UPHOLD/REJECT/CANCEL/TOO_EARLY |
| Accountability | Single tier (UMA-backed) | 3 tiers |
| Evidence | Discord off-chain | On-chain evidenceURI |
| Flexibility | Fixed 2-hour window | User-configurable per-POP |
