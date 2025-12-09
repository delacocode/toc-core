# Two-Round Dispute Mechanism

## Overview

TOC implements a two-round dispute system that balances efficiency with accuracy. Most disputes are resolved quickly by domain-expert TruthKeepers (Round 1), while a safety-valve escalation path ensures no single party has unchecked authority (Round 2).

**Core principle:** Liars get slashed. Truth wins and gets paid.

---

## State Flow

```
                                    ┌─────────────────────────────────────────┐
                                    │                                         │
                                    ▼                                         │
┌──────────┐   resolve   ┌───────────┐   dispute   ┌─────────────────┐       │
│  ACTIVE  │────────────►│ RESOLVING │────────────►│ DISPUTED_ROUND_1│       │
└──────────┘             └───────────┘             └────────┬────────┘       │
                               │                            │                │
                               │ no dispute                 │                │
                               │ + window passes            │                │
                               ▼                            │                │
                         ┌──────────┐                       │                │
                         │ RESOLVED │◄──────────────────────┤                │
                         └────┬─────┘                       │                │
                              │                             │                │
                              │ post-resolution             │ challenge OR   │
                              │ dispute                     │ TK timeout     │
                              │                             ▼                │
                              │                    ┌─────────────────┐       │
                              │                    │ DISPUTED_ROUND_2│       │
                              │                    └────────┬────────┘       │
                              │                             │                │
                              │                             │ admin resolves │
                              │                             │                │
                              ▼                             ▼                │
                         ┌──────────┐              ┌───────────┐             │
                         │CANCELLED │◄─────────────│  (final)  │─────────────┘
                         └──────────┘              └───────────┘
```

---

## Round 1: TruthKeeper Review

Round 1 is the fast path. A domain-expert TruthKeeper reviews the dispute and makes a decision. Most disputes end here.

### Step 1: Dispute Filed

**Function:** `dispute(popId, bondToken, bondAmount, reason, evidenceURI, proposedResult)`

**Who can call:** Anyone

**Requirements:**
- POP is in `RESOLVING` state (pre-resolution dispute) or `RESOLVED` state (post-resolution dispute)
- Within the dispute window
- Valid dispute bond posted

**What happens:**
1. Dispute bond transferred to registry
2. `DisputeInfo` stored with:
   - Disputer address
   - Bond details
   - Reason and evidence URI
   - Disputer's proposed correct result
3. State changes to `DISPUTED_ROUND_1`
4. TruthKeeper deadline set: `now + truthKeeperWindow`

```solidity
// Example: File a dispute
registry.dispute{value: 0.05 ether}(
    popId,
    address(0),           // ETH bond
    0.05 ether,          // bond amount
    "Result is incorrect, actual outcome was NO",
    "ipfs://QmEvidence...",
    abi.encode(false)    // proposed correct result
);
```

### Step 2: TruthKeeper Decides

**Function:** `resolveTruthKeeperDispute(popId, resolution, correctedResult)`

**Who can call:** Only the assigned TruthKeeper for this POP

**Requirements:**
- POP is in `DISPUTED_ROUND_1` state
- TK hasn't already decided
- Within TruthKeeper window

**Decision options:**
| Resolution | Meaning |
|------------|---------|
| `UPHOLD_DISPUTE` | Disputer is right, proposer was wrong |
| `REJECT_DISPUTE` | Proposer is right, disputer was wrong |
| `CANCEL_POP` | Question is invalid, void everything |
| `TOO_EARLY` | Cannot determine yet, return to ACTIVE |

**What happens:**
1. Decision recorded (but not yet applied)
2. Escalation deadline set: `now + escalationWindow`
3. Parties have time to challenge before decision is finalized

```solidity
// Example: TruthKeeper upholds the dispute
registry.resolveTruthKeeperDispute(
    popId,
    DisputeResolution.UPHOLD_DISPUTE,
    abi.encode(false)  // corrected result
);
```

### Step 3a: No Challenge - Finalize

**Function:** `finalizeAfterTruthKeeper(popId)`

**Who can call:** Anyone

**Requirements:**
- POP is in `DISPUTED_ROUND_1` state
- TruthKeeper has decided
- Escalation window has passed
- No escalation filed

**What happens:**
1. TK's decision is applied
2. Bonds distributed according to outcome
3. State changes to `RESOLVED` or `CANCELLED`

```solidity
// Example: Finalize after escalation window passes
registry.finalizeAfterTruthKeeper(popId);
```

### Step 3b: TruthKeeper Timeout - Auto Escalate

**Function:** `escalateTruthKeeperTimeout(popId)`

**Who can call:** Anyone

**Requirements:**
- POP is in `DISPUTED_ROUND_1` state
- TruthKeeper has NOT decided
- TruthKeeper window has passed

**What happens:**
1. State changes to `DISPUTED_ROUND_2`
2. Admin must now resolve

```solidity
// Example: TK didn't respond in time
registry.escalateTruthKeeperTimeout(popId);
```

---

## Round 2: Admin Escalation

Round 2 is the appeals court. It handles cases where:
1. Someone disagrees with the TruthKeeper's decision
2. The TruthKeeper failed to respond in time

### Step 4: Challenge TK Decision

**Function:** `challengeTruthKeeperDecision(popId, bondToken, bondAmount, reason, evidenceURI, proposedResult)`

**Who can call:** Anyone (typically the losing party from Round 1)

**Requirements:**
- POP is in `DISPUTED_ROUND_1` state
- TruthKeeper has decided
- Within escalation window
- Valid escalation bond posted (higher than dispute bond)

**What happens:**
1. Escalation bond transferred to registry
2. `EscalationInfo` stored with challenger details
3. State changes to `DISPUTED_ROUND_2`

```solidity
// Example: Challenge TK's decision
registry.challengeTruthKeeperDecision{value: 0.15 ether}(
    popId,
    address(0),           // ETH bond
    0.15 ether,          // escalation bond (higher than dispute)
    "TK decision was incorrect, here's why...",
    "ipfs://QmMoreEvidence...",
    abi.encode(true)     // challenger's proposed result
);
```

### Step 5: Admin Resolves

**Function:** `resolveEscalation(popId, resolution, correctedResult)`

**Who can call:** Only admin (contract owner)

**Requirements:**
- POP is in `DISPUTED_ROUND_2` state

**Decision options:** Same as TruthKeeper (UPHOLD, REJECT, CANCEL, TOO_EARLY)

**What happens:**
1. Final decision applied
2. All bonds distributed according to outcome
3. State changes to `RESOLVED` or `CANCELLED`

```solidity
// Example: Admin upholds the original dispute (challenger wins)
registry.resolveEscalation(
    popId,
    DisputeResolution.UPHOLD_DISPUTE,
    abi.encode(false)  // final corrected result
);
```

---

## Bond Economics

Bonds create skin in the game. You can't dispute frivolously because you'll lose money if you're wrong.

### Bond Requirements

| Bond Type | Purpose | Typical Minimum |
|-----------|---------|-----------------|
| Resolution Bond | Posted by proposer when resolving | Higher (more at stake) |
| Dispute Bond | Posted by disputer to challenge | Medium |
| Escalation Bond | Posted to challenge TK decision | Highest (discourages frivolous appeals) |

### Round 1 Outcomes (TK decides, no escalation)

**UPHOLD_DISPUTE** - Disputer was right:
| Party | Their Bond | Outcome |
|-------|------------|---------|
| Proposer | Resolution bond | 50% to disputer, 50% to protocol |
| Disputer | Dispute bond | Returned in full |

**REJECT_DISPUTE** - Proposer was right:
| Party | Their Bond | Outcome |
|-------|------------|---------|
| Proposer | Resolution bond | Returned in full |
| Disputer | Dispute bond | 50% to proposer, 50% to protocol |

**CANCEL_POP** - Question invalid:
| Party | Their Bond | Outcome |
|-------|------------|---------|
| Proposer | Resolution bond | Returned in full |
| Disputer | Dispute bond | Returned in full |

### Round 2 Outcomes (After escalation)

**UPHOLD_DISPUTE** - Challenger wins (disputer was right all along):
| Party | Their Bond | Outcome |
|-------|------------|---------|
| Proposer | Resolution bond | 50% to disputer, 50% to protocol |
| Disputer | Dispute bond | Returned in full |
| Challenger | Escalation bond | Returned in full |

**REJECT_DISPUTE** - TK was right (challenger loses):
| Party | Their Bond | Outcome |
|-------|------------|---------|
| Proposer | Resolution bond | Returned in full |
| Disputer | Dispute bond | 50% to proposer, 50% to protocol |
| Challenger | Escalation bond | 50% to disputer, 50% to protocol |

**CANCEL_POP** - Question invalid:
| Party | Their Bond | Outcome |
|-------|------------|---------|
| All parties | All bonds | Returned in full |

### Why 50/50 Split?

When a bond is slashed:
- **50% to winner:** Rewards truth-seeking behavior
- **50% to protocol:** Sustains the system, prevents collusion

---

## Time Windows

Each POP has configurable time windows set at creation:

| Window | Field | Purpose |
|--------|-------|---------|
| Dispute Window | `disputeWindow` | Time to file initial dispute after resolution proposed |
| TruthKeeper Window | `truthKeeperWindow` | Time for TK to decide Round 1 |
| Escalation Window | `escalationWindow` | Time to challenge TK decision |
| Post-Resolution Window | `postResolutionWindow` | Time to dispute after RESOLVED |

### Deadlines (Computed)

| Deadline | Computed | Stored In |
|----------|----------|-----------|
| `disputeDeadline` | `resolutionTime + disputeWindow` | `POP.disputeDeadline` |
| `truthKeeperDeadline` | `disputeTime + truthKeeperWindow` | `POP.truthKeeperDeadline` |
| `escalationDeadline` | `tkDecisionTime + escalationWindow` | `POP.escalationDeadline` |
| `postDisputeDeadline` | `finalizeTime + postResolutionWindow` | `POP.postDisputeDeadline` |

### Example Timeline

```
Day 0: POP resolved, disputeWindow = 24h, tkWindow = 24h, escalationWindow = 48h
       └── disputeDeadline = Day 1

Day 0.5: Dispute filed
         └── truthKeeperDeadline = Day 1.5

Day 1: TK decides UPHOLD_DISPUTE
       └── escalationDeadline = Day 3

Day 2: Proposer challenges TK decision
       └── State = DISPUTED_ROUND_2

Day 4: Admin resolves → REJECT_DISPUTE (TK was right)
       └── State = RESOLVED, challenger loses bond
```

---

## Post-Resolution Disputes

Even after a POP reaches `RESOLVED` state, it can still be disputed if `postResolutionWindow > 0`.

**Why?** Some outcomes might only become verifiably wrong after the fact.

**How it works:**
1. POP is in `RESOLVED` state
2. Within `postDisputeDeadline`
3. Anyone calls `dispute()` with evidence
4. Same two-round process applies
5. If upheld, result is corrected (`_hasCorrectedResult` flag set)

**Note:** Original result is preserved in `ResolutionInfo` for audit trail.

---

## Contract Functions Summary

### Disputer Actions
| Function | Purpose |
|----------|---------|
| `dispute()` | File initial dispute (Round 1) |
| `challengeTruthKeeperDecision()` | Challenge TK decision (→ Round 2) |

### TruthKeeper Actions
| Function | Purpose |
|----------|---------|
| `resolveTruthKeeperDispute()` | Decide Round 1 dispute |

### Admin Actions
| Function | Purpose |
|----------|---------|
| `resolveEscalation()` | Decide Round 2 dispute |
| `resolveDispute()` | Decide post-resolution disputes (admin path) |

### Anyone Can Call
| Function | Purpose |
|----------|---------|
| `finalizeAfterTruthKeeper()` | Finalize after escalation window passes |
| `escalateTruthKeeperTimeout()` | Auto-escalate if TK times out |
| `finalizePOP()` | Finalize after dispute window passes (no dispute) |

---

## Storage Structures

### DisputeInfo
```solidity
struct DisputeInfo {
    DisputePhase phase;        // PRE_RESOLUTION or POST_RESOLUTION
    address disputer;          // Who filed the dispute
    address bondToken;         // Token used for bond
    uint256 bondAmount;        // Amount bonded
    string reason;             // Why disputing
    string evidenceURI;        // IPFS/Arweave link
    uint256 filedAt;           // When dispute was filed
    uint256 resolvedAt;        // When dispute was resolved
    bool resultCorrected;      // Was the result changed?
    bytes proposedResult;      // Disputer's proposed correct answer
    DisputeResolution tkDecision;  // TK's Round 1 decision
    uint256 tkDecidedAt;       // When TK decided
}
```

### EscalationInfo
```solidity
struct EscalationInfo {
    address challenger;        // Who challenged TK decision
    address bondToken;         // Token used for escalation bond
    uint256 bondAmount;        // Amount bonded
    string reason;             // Why challenging
    string evidenceURI;        // IPFS/Arweave link
    uint256 filedAt;           // When challenge was filed
    uint256 resolvedAt;        // When admin resolved
    bytes proposedResult;      // Challenger's proposed result
}
```

---

## Security Considerations

1. **Bond sizing:** Higher bonds for higher stakes decisions
2. **Time windows:** Balance between speed and safety
3. **TK selection:** Choose TruthKeepers with domain expertise
4. **Escalation cost:** Higher escalation bond discourages frivolous appeals
5. **Admin trust:** Round 2 relies on admin; consider multisig or DAO governance

---

## Integration Guide

### For Consumers (Reading Results)

```solidity
// Check if safe to use result
ExtensiveResult memory result = registry.getExtensiveResult(popId);

if (!result.isFinalized) {
    // Still in dispute or window open - don't rely on result yet
    revert("Result not final");
}

if (result.wasCorrected) {
    // Result was disputed and changed - might want to log this
}

// Use the result
bool answer = POPResultCodec.decodeBoolean(result.result);
```

### For Disputers

```solidity
// 1. Check if disputable
POP memory pop = registry.getPOP(popId);
require(pop.state == POPState.RESOLVING, "Not disputable");
require(block.timestamp < pop.disputeDeadline, "Window passed");

// 2. File dispute with evidence
registry.dispute{value: MIN_DISPUTE_BOND}(
    popId,
    address(0),
    MIN_DISPUTE_BOND,
    "Actual outcome was different",
    "ipfs://QmEvidence",
    abi.encode(correctAnswer)
);
```

### For TruthKeepers

```solidity
// 1. Monitor for disputes assigned to you
// (Listen for POPDisputed events where pop.truthKeeper == you)

// 2. Review evidence and decide
registry.resolveTruthKeeperDispute(
    popId,
    DisputeResolution.UPHOLD_DISPUTE,  // or REJECT_DISPUTE, CANCEL_POP, TOO_EARLY
    abi.encode(correctAnswer)
);
```
