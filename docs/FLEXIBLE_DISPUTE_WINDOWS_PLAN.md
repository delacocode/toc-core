# Flexible Dispute Windows - Implementation Plan

## Overview

Extend the TOC protocol to support user-specified dispute windows, enabling immediate resolution for time-sensitive use cases (binary options) while maintaining dispute protection as an option.

## Key Design Decisions

| Decision | Choice |
|----------|--------|
| Dispute windows | User-specified at TOC creation (both pre and post) |
| System bounds | None - fully permissionless |
| Bond requirement | Required only if any dispute window > 0 |
| Post-resolution dispute | State stays RESOLVED, flag as contested, store corrected result |
| Audit trail | Full on-chain: disputer, time, reason, resolution, corrected result |
| Multiple disputes | One dispute total per TOC (across both phases) |
| Result getters | Return corrected result if exists, otherwise original |
| Disputer proposed answer | Optional - disputer can propose, admin can accept or override |
| Missing corrected answer | If upheld but no correct answer provided → CANCEL_TOC |
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

### Task 1: Update TOCTypes.sol

**File:** `contracts/TOCRegistry/TOCTypes.sol`

**Changes:**

1. Add `DisputePhase` enum:
```solidity
enum DisputePhase {
    NONE,
    PRE_RESOLUTION,
    POST_RESOLUTION
}
```

2. Update `TOC` struct:
```solidity
struct TOC {
    address resolver;
    TOCState state;
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

4. Update `TOCInfo` struct to include new fields for view functions.

---

### Task 2: Update ITOCRegistry.sol

**File:** `contracts/TOCRegistry/ITOCRegistry.sol`

**Changes:**

1. Update creation function signatures:
```solidity
function createTOCWithSystemResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 tocId);

function createTOCWithPublicResolver(
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) external returns (uint256 tocId);
```

2. Add new view functions:
```solidity
function isFullyFinalized(uint256 tocId) external view returns (bool);
function isContested(uint256 tocId) external view returns (bool);
function getCorrectedBooleanResult(uint256 tocId) external view returns (bool);
function getCorrectedNumericResult(uint256 tocId) external view returns (int256);
function getCorrectedGenericResult(uint256 tocId) external view returns (bytes memory);
function hasCorrectedResult(uint256 tocId) external view returns (bool);
```

3. Add events for post-resolution disputes:
```solidity
event PostResolutionDisputeFiled(uint256 indexed tocId, address indexed disputer, string reason);
event PostResolutionDisputeResolved(uint256 indexed tocId, bool resultCorrected);
```

---

### Task 3: Update TOCRegistry.sol - Storage

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Add new storage:**

```solidity
// Corrected results (set when post-resolution dispute is upheld)
mapping(uint256 => bool) private _correctedBooleanResults;
mapping(uint256 => int256) private _correctedNumericResults;
mapping(uint256 => bytes) private _correctedGenericResults;
mapping(uint256 => bool) private _hasCorrectedResult;
```

---

### Task 4: Update TOCRegistry.sol - Creation Logic

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update `_createTOC` function:**

1. Accept new parameters: `disputeWindow`, `postResolutionWindow`
2. Store user-specified windows in POP struct
3. Validate bond requirement:
   - If `disputeWindow > 0 || postResolutionWindow > 0` → bond will be required at resolution
   - If both = 0 → bond optional

```solidity
function _createTOC(
    ResolverType resolverType,
    uint256 resolverId,
    uint32 templateId,
    bytes calldata payload,
    uint256 disputeWindow,
    uint256 postResolutionWindow
) internal returns (uint256 tocId) {
    // ... existing validation ...

    tocId = _nextTocId++;

    TOCState initialState = ITOCResolver(resolver).onTocCreated(tocId, templateId, payload);

    _tocs[tocId] = TOC({
        resolver: resolver,
        state: initialState,
        answerType: answerType,
        resolutionTime: 0,
        disputeWindow: disputeWindow,
        postResolutionWindow: postResolutionWindow,
        disputeDeadline: 0,
        postDisputeDeadline: 0
    });

    emit TOCCreated(tocId, resolverType, resolverId, resolver, templateId, answerType, initialState);
}
```

---

### Task 5: Update TOCRegistry.sol - Resolution Logic

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update `resolveTOC` function:**

1. Check bond requirement based on windows:
```solidity
bool requiresBond = toc.disputeWindow > 0 || toc.postResolutionWindow > 0;
if (requiresBond && !_isAcceptableResolutionBond(bondToken, bondAmount)) {
    revert InvalidBond(bondToken, bondAmount);
}
```

2. Set deadlines based on user-specified windows:
```solidity
toc.disputeDeadline = toc.disputeWindow > 0
    ? block.timestamp + toc.disputeWindow
    : 0;
```

3. If `disputeWindow == 0`, immediately transition to RESOLVED and set post-dispute deadline:
```solidity
if (toc.disputeWindow == 0) {
    toc.state = TOCState.RESOLVED;
    toc.postDisputeDeadline = toc.postResolutionWindow > 0
        ? block.timestamp + toc.postResolutionWindow
        : 0;
    // Store result immediately
    _storeResult(tocId, toc.answerType, boolResult, numResult, genResult);
} else {
    toc.state = TOCState.RESOLVING;
}
```

---

### Task 6: Update TOCRegistry.sol - Finalization Logic

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update `finalizeTOC` function:**

1. After finalizing, set post-dispute deadline:
```solidity
function finalizeTOC(uint256 tocId) external nonReentrant validTocId(tocId) inState(tocId, TOCState.RESOLVING) {
    TOC storage toc = _tocs[tocId];

    if (block.timestamp < toc.disputeDeadline) {
        revert DisputeWindowNotPassed(toc.disputeDeadline, block.timestamp);
    }

    // Check not already disputed
    if (_disputes[tocId].disputer != address(0)) {
        revert AlreadyDisputed(tocId);
    }

    toc.state = TOCState.RESOLVED;

    // Set post-resolution dispute deadline
    toc.postDisputeDeadline = toc.postResolutionWindow > 0
        ? block.timestamp + toc.postResolutionWindow
        : 0;

    // Store result
    ResolutionInfo storage resolution = _resolutions[tocId];
    _storeResult(tocId, toc.answerType, resolution.proposedBooleanOutcome, resolution.proposedNumericOutcome, resolution.proposedGenericOutcome);

    // Return bond
    _transferBondOut(resolution.proposer, resolution.bondToken, resolution.bondAmount);

    emit TOCFinalized(tocId, toc.answerType);
}
```

---

### Task 7: Update TOCRegistry.sol - Dispute Logic

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update `dispute` function to handle both phases and optional proposed answer:**

```solidity
function dispute(
    uint256 tocId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    bool proposedBooleanResult,
    int256 proposedNumericResult,
    bytes calldata proposedGenericResult
) external payable nonReentrant validTocId(tocId) {
    TOC storage toc = _tocs[tocId];

    // Check not already disputed
    if (_disputes[tocId].disputer != address(0)) {
        revert AlreadyDisputed(tocId);
    }

    DisputePhase phase;

    if (toc.state == TOCState.RESOLVING) {
        // Pre-resolution dispute
        if (block.timestamp >= toc.disputeDeadline) {
            revert DisputeWindowPassed(toc.disputeDeadline, block.timestamp);
        }
        phase = DisputePhase.PRE_RESOLUTION;
        toc.state = TOCState.DISPUTED;

    } else if (toc.state == TOCState.RESOLVED) {
        // Post-resolution dispute
        if (toc.postDisputeDeadline == 0) {
            revert DisputeWindowPassed(0, block.timestamp);
        }
        if (block.timestamp >= toc.postDisputeDeadline) {
            revert DisputeWindowPassed(toc.postDisputeDeadline, block.timestamp);
        }
        phase = DisputePhase.POST_RESOLUTION;
        // State stays RESOLVED

    } else {
        revert InvalidState(toc.state, TOCState.RESOLVING);
    }

    // Validate and transfer bond
    if (!_isAcceptableDisputeBond(bondToken, bondAmount)) {
        revert InvalidBond(bondToken, bondAmount);
    }
    _transferBondIn(bondToken, bondAmount);

    // Store dispute info with proposed answer
    _disputes[tocId] = DisputeInfo({
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

    emit DisputeBondDeposited(tocId, msg.sender, bondToken, bondAmount);

    if (phase == DisputePhase.PRE_RESOLUTION) {
        emit TOCDisputed(tocId, msg.sender, reason);
    } else {
        emit PostResolutionDisputeFiled(tocId, msg.sender, reason);
    }
}
```

---

### Task 8: Update TOCRegistry.sol - Dispute Resolution Logic

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Update `resolveDispute` function with optional corrected answer:**

```solidity
function resolveDispute(
    uint256 tocId,
    DisputeResolution resolution,
    bool correctedBooleanResult,
    int256 correctedNumericResult,
    bytes calldata correctedGenericResult
) external onlyOwner nonReentrant validTocId(tocId) {
    DisputeInfo storage disputeInfo = _disputes[tocId];

    if (disputeInfo.disputer == address(0)) {
        revert InvalidTocId(tocId); // No dispute exists
    }
    if (disputeInfo.resolvedAt != 0) {
        revert AlreadyDisputed(tocId); // Already resolved
    }

    TOC storage toc = _tocs[tocId];
    ResolutionInfo storage resolutionInfo = _resolutions[tocId];

    disputeInfo.resolvedAt = block.timestamp;

    if (resolution == DisputeResolution.UPHOLD_DISPUTE) {
        disputeInfo.resultCorrected = true;

        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            // Pre-resolution: flip result and finalize
            toc.state = TOCState.RESOLVED;

            if (toc.answerType == AnswerType.BOOLEAN) {
                _booleanResults[tocId] = !resolutionInfo.proposedBooleanOutcome;
            }
            // Set post-dispute deadline
            toc.postDisputeDeadline = toc.postResolutionWindow > 0
                ? block.timestamp + toc.postResolutionWindow
                : 0;

        } else {
            // Post-resolution: store corrected result
            // Priority: admin's answer > disputer's proposed answer
            // If neither provided for non-boolean, cancel instead

            if (toc.answerType == AnswerType.BOOLEAN) {
                // For boolean: use admin's if provided, else use disputer's, else flip
                _correctedBooleanResults[tocId] = correctedBooleanResult != false
                    ? correctedBooleanResult
                    : (disputeInfo.proposedBooleanResult != false
                        ? disputeInfo.proposedBooleanResult
                        : !_booleanResults[tocId]);
                _hasCorrectedResult[tocId] = true;
            } else if (toc.answerType == AnswerType.NUMERIC) {
                // Use admin's answer if non-zero, else disputer's
                int256 corrected = correctedNumericResult != 0
                    ? correctedNumericResult
                    : disputeInfo.proposedNumericResult;
                if (corrected == 0 && _numericResults[tocId] == 0) {
                    // Ambiguous - no way to know if 0 is intentional
                    // For safety, require explicit answer or cancel
                }
                _correctedNumericResults[tocId] = corrected;
                _hasCorrectedResult[tocId] = true;
            } else if (toc.answerType == AnswerType.GENERIC) {
                bytes memory corrected = correctedGenericResult.length > 0
                    ? correctedGenericResult
                    : disputeInfo.proposedGenericResult;
                if (corrected.length == 0) {
                    // No corrected answer provided - should cancel
                    revert("No corrected answer provided");
                }
                _correctedGenericResults[tocId] = corrected;
                _hasCorrectedResult[tocId] = true;
            }
        }

        // Slash resolution bond, return dispute bond
        emit BondSlashed(tocId, resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);

    } else if (resolution == DisputeResolution.REJECT_DISPUTE) {
        disputeInfo.resultCorrected = false;

        if (disputeInfo.phase == DisputePhase.PRE_RESOLUTION) {
            toc.state = TOCState.RESOLVED;
            _storeResult(tocId, toc.answerType, resolutionInfo.proposedBooleanOutcome, resolutionInfo.proposedNumericOutcome, resolutionInfo.proposedGenericOutcome);
            toc.postDisputeDeadline = toc.postResolutionWindow > 0
                ? block.timestamp + toc.postResolutionWindow
                : 0;
        }
        // Post-resolution: nothing changes, original result stands

        // Slash dispute bond, return resolution bond
        emit BondSlashed(tocId, disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
        _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);

    } else {
        // CANCEL_TOC
        toc.state = TOCState.CANCELLED;
        _transferBondOut(resolutionInfo.proposer, resolutionInfo.bondToken, resolutionInfo.bondAmount);
        _transferBondOut(disputeInfo.disputer, disputeInfo.bondToken, disputeInfo.bondAmount);
        emit TOCCancelled(tocId, "Admin cancelled during dispute resolution");
    }

    emit DisputeResolved(tocId, resolution, msg.sender);
}
```

---

### Task 9: Update TOCRegistry.sol - View Functions

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

**Add new helper functions:**

```solidity
function isFullyFinalized(uint256 tocId) external view validTocId(tocId) returns (bool) {
    TOC storage toc = _tocs[tocId];

    if (toc.state != TOCState.RESOLVED) {
        return false;
    }

    // Check no pending dispute windows
    if (toc.postDisputeDeadline > 0 && block.timestamp < toc.postDisputeDeadline) {
        // Window still open, check if already disputed
        if (_disputes[tocId].disputer == address(0)) {
            return false; // Can still be disputed
        }
        // Disputed but not yet resolved
        if (_disputes[tocId].resolvedAt == 0) {
            return false;
        }
    }

    return true;
}

function isContested(uint256 tocId) external view validTocId(tocId) returns (bool) {
    DisputeInfo storage dispute = _disputes[tocId];
    return dispute.phase == DisputePhase.POST_RESOLUTION && dispute.disputer != address(0);
}

function hasCorrectedResult(uint256 tocId) external view validTocId(tocId) returns (bool) {
    return _hasCorrectedResult[tocId];
}

function getCorrectedBooleanResult(uint256 tocId) external view validTocId(tocId) returns (bool) {
    return _correctedBooleanResults[tocId];
}

function getCorrectedNumericResult(uint256 tocId) external view validTocId(tocId) returns (int256) {
    return _correctedNumericResults[tocId];
}

function getCorrectedGenericResult(uint256 tocId) external view validTocId(tocId) returns (bytes memory) {
    return _correctedGenericResults[tocId];
}
```

**Update existing result getters to return corrected if exists:**

```solidity
function getBooleanResult(uint256 tocId) external view validTocId(tocId) returns (bool) {
    if (_hasCorrectedResult[tocId]) {
        return _correctedBooleanResults[tocId];
    }
    return _booleanResults[tocId];
}

function getNumericResult(uint256 tocId) external view validTocId(tocId) returns (int256) {
    if (_hasCorrectedResult[tocId]) {
        return _correctedNumericResults[tocId];
    }
    return _numericResults[tocId];
}

function getGenericResult(uint256 tocId) external view validTocId(tocId) returns (bytes memory) {
    if (_hasCorrectedResult[tocId]) {
        return _correctedGenericResults[tocId];
    }
    return _genericResults[tocId];
}
```

---

### Task 10: Add Helper Function for Result Storage

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

```solidity
function _storeResult(
    uint256 tocId,
    AnswerType answerType,
    bool boolResult,
    int256 numResult,
    bytes memory genResult
) internal {
    if (answerType == AnswerType.BOOLEAN) {
        _booleanResults[tocId] = boolResult;
    } else if (answerType == AnswerType.NUMERIC) {
        _numericResults[tocId] = numResult;
    } else if (answerType == AnswerType.GENERIC) {
        _genericResults[tocId] = genResult;
    }
}
```

---

### Task 11: Update Tests

**File:** `contracts/test/TOCRegistry.t.sol`

**Add new tests:**

1. `test_CreateTOCWithCustomDisputeWindows` - User specifies both windows
2. `test_CreateUndisputableTOC` - Both windows = 0, no bond required
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

**File:** `docs/TOC_SYSTEM_DOCUMENTATION.md`

Add section on:
- Flexible dispute windows
- Three modes: undisputable, pre-resolution, post-resolution
- Post-resolution dispute flow
- Corrected results
- Helper functions for consumers

---

## Implementation Order

1. **TOCTypes.sol** - Add new enum and update structs
2. **ITOCRegistry.sol** - Update interface with new signatures and functions
3. **TOCRegistry.sol** - Storage additions
4. **TOCRegistry.sol** - Creation logic
5. **TOCRegistry.sol** - Resolution logic
6. **TOCRegistry.sol** - Finalization logic
7. **TOCRegistry.sol** - Dispute logic (both phases)
8. **TOCRegistry.sol** - Dispute resolution logic
9. **TOCRegistry.sol** - View functions
10. **Tests** - Comprehensive test coverage
11. **Documentation** - Update docs

---

## Resolved Questions

1. **Numeric/Generic corrected results**: ✅ Add parameters to `resolveDispute` - admin provides corrected value. Priority: admin's answer > disputer's proposed answer > cancel if neither.

2. **Events**: ✅ Key moments only - `PostResolutionDisputeFiled` and `PostResolutionDisputeResolved`.

3. **Gas optimization**: ✅ Separate mappings for corrected results confirmed.

4. **Disputer proposed answer**: ✅ Optional - disputer can propose, admin can accept or override.

5. **Missing corrected answer**: ✅ If upheld for numeric/generic but no answer provided → revert (admin should use CANCEL_TOC instead).
