# Flexible Dispute Windows - Implementation Plan

## Overview

Extend the POP protocol to support user-specified dispute windows, enabling immediate resolution for time-sensitive use cases (binary options) while maintaining dispute protection as an option.

## Key Design Decisions

| Decision | Choice |
|----------|--------|
| Dispute windows | User-specified at POP creation (both pre and post) |
| System bounds | None - fully permissionless |
| Bond requirement | Required only if any dispute window > 0 |
| Post-resolution dispute | State stays RESOLVED, flag as contested, store corrected result |
| Audit trail | Full on-chain: disputer, time, reason, resolution, corrected result |
| Multiple disputes | One dispute total per POP (across both phases) |
| Result getters | Return corrected result if exists, otherwise original |
| Disputer proposed answer | Optional - disputer can propose, admin can accept or override |
| Missing corrected answer | If upheld but no correct answer provided → CANCEL_POP |
| Events | Key moments only: PostResolutionDisputeFiled, PostResolutionDisputeResolved |

## Modes Enabled by User Choices

| disputeWindow | postResolutionWindow | Mode | Use Case |
|---------------|---------------------|------|----------|
| 0 | 0 | Undisputable | Binary options, immediate finality |
| > 0 | 0 | Pre-resolution only | Current behavior |
| 0 | > 0 | Post-resolution only | Fast resolution + insurance |
| > 0 | > 0 | Both windows | Quick finalization + extended protection |

---

## Implementation Tasks

### Task 1: Update POPTypes.sol

**File:** `contracts/Popregistry/POPTypes.sol`

**Changes:**

1. Add `DisputePhase` enum:
```solidity
enum DisputePhase {
    NONE,
    PRE_RESOLUTION,
    POST_RESOLUTION
}
```

2. Update `POP` struct:
```solidity
struct POP {
    address resolver;
    POPState state;
    AnswerType answerType;
    uint256 resolutionTime;
    uint256 disputeWindow;           // User-specified pre-resolution duration
    uint256 postResolutionWindow;    // User-specified post-resolution duration
    uint256 disputeDeadline;         // Computed: end of pre-resolution window
    uint256 postDisputeDeadline;     // Computed: end of post-resolution window
}
```

3. Update `DisputeInfo` struct:
```solidity
struct DisputeInfo {
    DisputePhase phase;
    address disputer;
    address bondToken;
    uint256 bondAmount;
    string reason;
    uint256 filedAt;
    uint256 resolvedAt;
    bool resultCorrected;
    // Disputer's proposed correction (optional)
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;
}
```

4. Update `POPInfo` struct to include new fields for view functions.

---

### Task 2: Update IPOPRegistry.sol

**File:** `contracts/Popregistry/IPOPRegistry.sol`

**Changes:**

1. Update creation function signatures:
```solidity
function createPOPWithSystemResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 popId);

function createPOPWithPublicResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 popId);
```

2. Add new view functions:
```solidity
function isFullyFinalized(uint256 popId) external view returns (bool);
function isContested(uint256 popId) external view returns (bool);
function getCorrectedBooleanResult(uint256 popId) external view returns (bool);
function getCorrectedNumericResult(uint256 popId) external view returns (int256);
function getCorrectedGenericResult(uint256 popId) external view returns (bytes memory);
function hasCorrectedResult(uint256 popId) external view returns (bool);
```

3. Add events for post-resolution disputes:
```solidity
event PostResolutionDisputeFiled(uint256 indexed popId, address indexed disputer, string reason);
event PostResolutionDisputeResolved(uint256 indexed popId, bool resultCorrected);
```

---

### Task 3: Update POPRegistry.sol - Storage

**File:** `contracts/Popregistry/POPRegistry.sol`

**Add new storage:**

```solidity
// Corrected results (set when post-resolution dispute is upheld)
mapping(uint256 => bool) private _correctedBooleanResults;
mapping(uint256 => int256) private _correctedNumericResults;
mapping(uint256 => bytes) private _correctedGenericResults;
mapping(uint256 => bool) private _hasCorrectedResult;
```

---

### Task 4: Update POPRegistry.sol - Creation Logic

**File:** `contracts/Popregistry/POPRegistry.sol`

**Update `_createPOP` function:**

1. Accept new parameters: `disputeWindow`, `postResolutionWindow`
2. Store user-specified windows in POP struct
3. Validate bond requirement:
   - If `disputeWindow > 0 || postResolutionWindow > 0` → bond will be required at resolution
   - If both = 0 → bond optional

```solidity
function _createPOP(
    ResolverType resolverType,
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) internal returns (uint256 popId) {
    // ... existing validation ...

    popId = _nextPopId++;

    POPState initialState = IPopResolver(resolver).onPopCreated(popId, templateId, payload);

    _pops[popId] = POP({
        resolver: resolver,
        state: initialState,
        answerType: answerType,
        resolutionTime: 0,
        disputeWindow: disputeWindow,
        postResolutionWindow: postResolutionWindow,
        disputeDeadline: 0,
        postDisputeDeadline: 0
    });

    emit POPCreated(popId, resolverType, resolverId, resolver, templateId, answerType, initialState);
}
```

---

### Task 5: Update POPRegistry.sol - Resolution Logic

**File:** `contracts/Popregistry/POPRegistry.sol`

**Update `resolvePOP` function:**

1. Check bond requirement based on windows:
```solidity
bool requiresBond = pop.disputeWindow > 0 || pop.postResolutionWindow > 0;
if (requiresBond && !_isAcceptableResolutionBond(bondToken, bondAmount)) {
    revert InvalidBond(bondToken, bondAmount);
}
```

2. Set deadlines based on user-specified windows:
```solidity
pop.disputeDeadline = pop.disputeWindow > 0
    ? block.timestamp + pop.disputeWindow
    : 0;
```

3. If `disputeWindow == 0`, immediately transition to RESOLVED and set post-dispute deadline:
```solidity
if (pop.disputeWindow == 0) {
    pop.state = POPState.RESOLVED;
    pop.postDisputeDeadline = pop.postResolutionWindow > 0
        ? block.timestamp + pop.postResolutionWindow
        : 0;
    // Store result immediately
    _storeResult(popId, pop.answerType, boolResult, numResult, genResult);
} else {
    pop.state = POPState.RESOLVING;
}
```

---

### Task 6: Update POPRegistry.sol - Finalization Logic

**File:** `contracts/Popregistry/POPRegistry.sol`

**Update `finalizePOP` function:**

1. After finalizing, set post-dispute deadline:
```solidity
function finalizePOP(uint256 popId) external nonReentrant validPopId(popId) inState(popId, POPState.RESOLVING) {
    POP storage pop = _pops[popId];

    if (block.timestamp < pop.disputeDeadline) {
        revert DisputeWindowNotPassed(pop.disputeDeadline, block.timestamp);
    }

    // Check not already disputed
    if (_disputes[popId].disputer != address(0)) {
        revert AlreadyDisputed(popId);
    }

    pop.state = POPState.RESOLVED;

    // Set post-resolution dispute deadline
    pop.postDisputeDeadline = pop.postResolutionWindow > 0
        ? block.timestamp + pop.postResolutionWindow
        : 0;

    // Store result
    ResolutionInfo storage resolution = _resolutions[popId];
    _storeResult(popId, pop.answerType, resolution.proposedBooleanOutcome, resolution.proposedNumericOutcome, resolution.proposedGenericOutcome);

    // Return bond
    _transferBondOut(resolution.proposer, resolution.bondToken, resolution.bondAmount);

    emit POPFinalized(popId, pop.answerType);
}
```

---

### Task 7: Update POPRegistry.sol - Dispute Logic

**File:** `contracts/Popregistry/POPRegistry.sol`

**Update `dispute` function to handle both phases and optional proposed answer:**

```solidity
function dispute(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable nonReentrant validPopId(popId) {
    POP storage pop = _pops[popId];

    // Check not already disputed
    if (_disputes[popId].disputer != address(0)) {
        revert AlreadyDisputed(popId);
    }

    DisputePhase phase;

    if (pop.state == POPState.RESOLVING) {
        // Pre-resolution dispute
        if (block.timestamp >= pop.disputeDeadline) {
            revert DisputeWindowPassed(pop.disputeDeadline, block.timestamp);
        }
        phase = DisputePhase.PRE_RESOLUTION;
        pop.state = POPState.DISPUTED;

    } else if (pop.state == POPState.RESOLVED) {
        // Post-resolution dispute
        if (pop.postDisputeDeadline == 0) {
            revert DisputeWindowPassed(0, block.timestamp);
        }
        if (block.timestamp >= pop.postDisputeDeadline) {
            revert DisputeWindowPassed(pop.postDisputeDeadline, block.timestamp);
        }
        phase = DisputePhase.POST_RESOLUTION;
        // State stays RESOLVED

    } else {
        revert InvalidState(pop.state, POPState.RESOLVING);
    }

    // Validate and transfer bond
    if (!_isAcceptableDisputeBond(bondToken, bondAmount)) {
        revert InvalidBond(bondToken, bondAmount);
    }
    _transferBondIn(bondToken, bondAmount);

    // Store dispute info with proposed answer
    _disputes[popId] = DisputeInfo({
        phase: phase,
        disputer: msg.sender,
        bondToken: bondToken,
        bondAmount: bondAmount,
        reason: reason,
        filedAt: block.timestamp,
        resolvedAt: 0,
        resultCorrected: false,
        proposedBooleanResult: proposedBooleanResult,
        proposedNumericResult: proposedNumericResult,
        proposedGenericResult: proposedGenericResult
    });

    emit DisputeBondDeposited(popId, msg.sender, bondToken, bondAmount);

    if (phase == DisputePhase.PRE_RESOLUTION) {
        emit POPDisputed(popId, msg.sender, reason);
    } else {
        emit PostResolutionDisputeFiled(popId, msg.sender, reason);
    }
}
```

---

### Task 8: Update POPRegistry.sol - Dispute Resolution Logic

**File:** `contracts/Popregistry/POPRegistry.sol`

**Update `resolveDispute` function with optional corrected answer:**

```solidity
function resolveDispute(
    uint256 popId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external onlyOwner nonReentrant validPopId(popId) {
    DisputeInfo storage disputeInfo = _disputes[popId];

    if (disputeInfo.disputer == address(0)) {
        revert InvalidPopId(popId); // No dispute exists
    }
    if (disputeInfo.resolvedAt != 0) {
        revert AlreadyDisputed(popId); // Already resolved
    }

    POP storage pop = _pops[popId];
    ResolutionInfo storage resolutionInfo = _resolutions[popId];

    disputeInfo.resolvedAt = block.timestamp;

    if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
        disputeInfo.resultCorrected = true;

        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            // Pre-resolution: flip result and finalize
            pop.state = POPState.RESOLVED;

            if (pop.answerType == AnswerType.BOOLEAN) {
                _booleanResults[popId] = !resolutionInfo.proposedBooleanOutcome;
            }
            // Set post-dispute deadline
            pop.postDisputeDeadline = pop.postResolutionWindow > 0
                ? block.timestamp + pop.postResolutionWindow
                : 0;

        } else {
            // Post-resolution: store corrected result
            // Priority: admin's answer > disputer's proposed answer
            // If neither provided for non-boolean, cancel instead

            if (pop.answerType == AnswerType.BOOLEAN) {
                // For boolean: use admin's if provided, else use disputer's, else flip
                _correctedBooleanResults[popId] = correctedBooleanResult != false
                    ? correctedBooleanResult
                    : (disputeInfo.proposedBooleanResult != false
                        ? disputeInfo.proposedBooleanResult
                        : !_booleanResults[popId]);
                _hasCorrectedResult[popId] = true;
            } else if (pop.answerType == AnswerType.NUMERIC) {
                // Use admin's answer if non-zero, else disputer's
                int256 corrected = correctedNumericResult != 0
                    ? correctedNumericResult
                    : disputeInfo.proposedNumericResult;
                if (corrected == 0 && _numericResults[popId] == 0) {
                    // Ambiguous - no way to know if 0 is intentional
                    // For safety, require explicit answer or cancel
                }
                _correctedNumericResults[popId] = corrected;
                _hasCorrectedResult[popId] = true;
            } else if (pop.answerType == AnswerType.GENERIC) {
                bytes memory corrected = correctedGenericResult.length > 0
                    ? correctedGenericResult
                    : disputeInfo.proposedGenericResult;
                if (corrected.length == 0) {
                    // No corrected answer provided - should cancel
                    revert("No corrected answer provided");
                }
                _correctedGenericResults[popId] = corrected;
                _hasCorrectedResult[popId] = true;
            }
        }

        // Slash resolution bond, return dispute bond
        emit BondSlashed(popId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

    } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
        disputeInfo.resultCorrected = false;

        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            pop.state = POPState.RESOLVED;
            _storeResult(popId, pop.answerType, resolutionInfo.proposedBooleanOutcome, resolutionInfo.proposedNumericOutcome, resolutionInfo.proposedGenericOutcome);
            pop.postDisputeDeadline = pop.postResolutionWindow > 0
                ? block.timestamp + pop.postResolutionWindow
                : 0;
        }
        // Post-resolution: nothing changes, original result stands

        // Slash dispute bond, return resolution bond
        emit BondSlashed(popId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
        _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

    } else {
        // CANCEL_POP
        pop.state = POPState.CANCELLED;
        _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
        emit POPCancelled(popId, "Admin cancelled during dispute resolution");
    }

    emit DisputeResolved(popId, resolution, msg.sender);
}
```

---

### Task 9: Update POPRegistry.sol - View Functions

**File:** `contracts/Popregistry/POPRegistry.sol`

**Add new helper functions:**

```solidity
function isFullyFinalized(uint256 popId) external view validPopId(popId) returns (bool) {
    POP storage pop = _pops[popId];

    if (pop.state != POPState.RESOLVED) {
        return false;
    }

    // Check no pending dispute windows
    if (pop.postDisputeDeadline > 0 && block.timestamp < pop.postDisputeDeadline) {
        // Window still open, check if already disputed
        if (_disputes[popId].disputer == address(0)) {
            return false; // Can still be disputed
        }
        // Disputed but not yet resolved
        if (_disputes[popId].resolvedAt == 0) {
            return false;
        }
    }

    return true;
}

function isContested(uint256 popId) external view validPopId(popId) returns (bool) {
    DisputeInfo storage dispute = _disputes[popId];
    return dispute.phase == DisputePhase.POST_RESOLUTION && dispute.disputer != address(0);
}

function hasCorrectedResult(uint256 popId) external view validPopId(popId) returns (bool) {
    return _hasCorrectedResult[popId];
}

function getCorrectedBooleanResult(uint256 popId) external view validPopId(popId) returns (bool) {
    return _correctedBooleanResults[popId];
}

function getCorrectedNumericResult(uint256 popId) external view validPopId(popId) returns (int256) {
    return _correctedNumericResults[popId];
}

function getCorrectedGenericResult(uint256 popId) external view validPopId(popId) returns (bytes memory) {
    return _correctedGenericResults[popId];
}
```

**Update existing result getters to return corrected if exists:**

```solidity
function getBooleanResult(uint256 popId) external view validPopId(popId) returns (bool) {
    if (_hasCorrectedResult[popId]) {
        return _correctedBooleanResults[popId];
    }
    return _booleanResults[popId];
}

function getNumericResult(uint256 popId) external view validPopId(popId) returns (int256) {
    if (_hasCorrectedResult[popId]) {
        return _correctedNumericResults[popId];
    }
    return _numericResults[popId];
}

function getGenericResult(uint256 popId) external view validPopId(popId) returns (bytes memory) {
    if (_hasCorrectedResult[popId]) {
        return _correctedGenericResults[popId];
    }
    return _genericResults[popId];
}
```

---

### Task 10: Add Helper Function for Result Storage

**File:** `contracts/Popregistry/POPRegistry.sol`

```solidity
function _storeResult(
    uint256 popId,
    AnswerType answerType,
    bool boolResult,
    int256 numResult,
    bytes memory genResult
) internal {
    if (answerType == AnswerType.BOOLEAN) {
        _booleanResults[popId] = boolResult;
    } else if (answerType == AnswerType.NUMERIC) {
        _numericResults[popId] = numResult;
    } else if (answerType == AnswerType.GENERIC) {
        _genericResults[popId] = genResult;
    }
}
```

---

### Task 11: Update Tests

**File:** `contracts/test/POPRegistry.t.sol`

**Add new tests:**

1. `test_CreatePOPWithCustomDisputeWindows` - User specifies both windows
2. `test_CreateUndisputablePOP` - Both windows = 0, no bond required
3. `test_ImmediateResolution` - disputeWindow = 0, goes straight to RESOLVED
4. `test_PostResolutionDispute` - File dispute after RESOLVED
5. `test_PostResolutionDisputeUpheld` - Corrected result stored
6. `test_PostResolutionDisputeRejected` - Original result stands
7. `test_OneDisputeOnly` - Cannot dispute twice
8. `test_DisputeClosesAllWindows` - After dispute, no more disputes allowed
9. `test_GetBooleanResultReturnsCorrected` - Returns corrected if exists
10. `test_IsFullyFinalized` - Various scenarios
11. `test_IsContested` - Post-resolution dispute detection
12. `test_NoBondRequiredForUndisputable` - Bond optional when both windows = 0

**Update MockResolver** to handle new creation parameters if needed.

---

### Task 12: Update Documentation

**File:** `docs/POP_SYSTEM_DOCUMENTATION.md`

Add section on:
- Flexible dispute windows
- Three modes: undisputable, pre-resolution, post-resolution
- Post-resolution dispute flow
- Corrected results
- Helper functions for consumers

---

## Implementation Order

1. **POPTypes.sol** - Add new enum and update structs
2. **IPOPRegistry.sol** - Update interface with new signatures and functions
3. **POPRegistry.sol** - Storage additions
4. **POPRegistry.sol** - Creation logic
5. **POPRegistry.sol** - Resolution logic
6. **POPRegistry.sol** - Finalization logic
7. **POPRegistry.sol** - Dispute logic (both phases)
8. **POPRegistry.sol** - Dispute resolution logic
9. **POPRegistry.sol** - View functions
10. **Tests** - Comprehensive test coverage
11. **Documentation** - Update docs

---

## Resolved Questions

1. **Numeric/Generic corrected results**: ✅ Add parameters to `resolveDispute` - admin provides corrected value. Priority: admin's answer > disputer's proposed answer > cancel if neither.

2. **Events**: ✅ Key moments only - `PostResolutionDisputeFiled` and `PostResolutionDisputeResolved`.

3. **Gas optimization**: ✅ Separate mappings for corrected results confirmed.

4. **Disputer proposed answer**: ✅ Optional - disputer can propose, admin can accept or override.

5. **Missing corrected answer**: ✅ If upheld for numeric/generic but no answer provided → revert (admin should use CANCEL_POP instead).
