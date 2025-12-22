# Security Fixes Plan

**Date:** 2025-12-22
**Status:** Approved
**Estimated Effort:** 2-3 days

---

## Overview

Four code changes identified during production readiness review. All are straightforward fixes with low risk.

---

## Issue 1: Add Maximum Window Validation

**Problem:** No upper bound on time windows allows unreasonable values.

**Solution:** Add hardcoded constants based on resolver trust level.

### Changes

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

1. Add constants after line 25:
```solidity
uint256 public constant MAX_WINDOW_RESOLVER = 1 days;
uint256 public constant MAX_WINDOW_TRUSTED = 30 days;
```

2. Add error after line 87:
```solidity
error WindowTooLong(uint256 provided, uint256 maximum);
```

3. In `createTOC()`, after line 324 (after trust check), add:
```solidity
uint256 maxWindow = (trust == ResolverTrust.RESOLVER)
    ? MAX_WINDOW_RESOLVER
    : MAX_WINDOW_TRUSTED;

if (disputeWindow > maxWindow) revert WindowTooLong(disputeWindow, maxWindow);
if (truthKeeperWindow > maxWindow) revert WindowTooLong(truthKeeperWindow, maxWindow);
if (escalationWindow > maxWindow) revert WindowTooLong(escalationWindow, maxWindow);
if (postResolutionWindow > maxWindow) revert WindowTooLong(postResolutionWindow, maxWindow);
```

### Tests
- Test RESOLVER trust with 1 day window (should pass)
- Test RESOLVER trust with 2 day window (should revert)
- Test VERIFIED trust with 30 day window (should pass)
- Test VERIFIED trust with 31 day window (should revert)

---

## Issue 2: Replace tx.origin with Passed Creator

**Problem:** `OptimisticResolver` uses `tx.origin` which is vulnerable to phishing attacks.

**Solution:** Update interface to pass creator explicitly from Registry.

### Changes

**File:** `contracts/TOCRegistry/ITOCResolver.sol`

1. Update `onTocCreated` signature (line 25-29):
```solidity
function onTocCreated(
    uint256 tocId,
    uint32 templateId,
    bytes calldata payload,
    address creator
) external returns (TOCState initialState);
```

**File:** `contracts/TOCRegistry/TOCRegistry.sol`

2. Update call in `createTOC()` (line 383):
```solidity
toc.state = ITOCResolver(resolver).onTocCreated(tocId, templateId, payload, msg.sender);
```

**File:** `contracts/resolvers/OptimisticResolver.sol`

3. Update function signature (line 158-162):
```solidity
function onTocCreated(
    uint256 tocId,
    uint32 templateId,
    bytes calldata payload,
    address creator
) external onlyRegistry returns (TOCState initialState) {
```

4. Replace `tx.origin` with `creator` (line 172 and 178):
```solidity
_questions[tocId] = QuestionData({
    templateId: templateId,
    creator: creator,  // Changed from tx.origin
    createdAt: block.timestamp,
    payload: payload
});

emit QuestionCreated(tocId, templateId, creator, questionPreview);  // Changed from tx.origin
```

**File:** `contracts/resolvers/PythPriceResolverV2.sol`

5. Update function signature (line 392-396):
```solidity
function onTocCreated(
    uint256 tocId,
    uint32 templateId,
    bytes calldata payload,
    address /* creator */
) external onlyRegistry returns (TOCState initialState) {
```

### Tests
- Test that creator is correctly stored when calling through a contract
- Test that creator matches the actual caller, not tx.origin

---

## Issue 3: Fix Broken Tests

**Problem:** Tests use `templateId: 0` but valid templates start at 1.

**Solution:** Update all test cases to use correct template ID.

### Changes

**File:** `test/TOCRegistry.ts`

1. Change all occurrences of `templateId: 0` to `templateId: 1`

Affected lines (approximate):
- Line 238: `0, // templateId` → `1, // templateId (TEMPLATE_ARBITRARY)`
- Line 289: same change
- Line 346: same change
- Line 409: same change

### Verification
- Run `npx hardhat test`
- All TOCRegistry tests should pass

---

## Issue 4: Add Resolution Event in OptimisticResolver

**Problem:** Justification provided during resolution is not stored or emitted.

**Solution:** Add event to capture resolution details for audit trail.

### Changes

**File:** `contracts/resolvers/OptimisticResolver.sol`

1. Add event after line 108:
```solidity
event ResolutionProposed(
    uint256 indexed tocId,
    address indexed proposer,
    bool answer,
    string justification
);
```

2. Update `resolveToc()` to accept and emit proposer (line 185-200):
```solidity
function resolveToc(
    uint256 tocId,
    address caller,
    bytes calldata answerPayload
) external onlyRegistry returns (bytes memory result) {
    QuestionData storage q = _questions[tocId];
    if (q.createdAt == 0) {
        revert TocNotManaged(tocId);
    }

    AnswerPayload memory answer = abi.decode(answerPayload, (AnswerPayload));

    emit ResolutionProposed(tocId, caller, answer.answer, answer.justification);

    return TOCResultCodec.encodeBoolean(answer.answer);
}
```

### Tests
- Test that ResolutionProposed event is emitted with correct data
- Test that justification is queryable from event logs

---

## Implementation Order

1. **Issue 2 first** - Interface change affects multiple files
2. **Issue 1 second** - Standalone change in TOCRegistry
3. **Issue 4 third** - Standalone change in OptimisticResolver
4. **Issue 3 last** - Fix tests after all contract changes

---

## Verification Checklist

- [ ] All contracts compile without errors
- [ ] Compiler warning in OptimisticResolver is resolved
- [ ] All tests pass
- [ ] Contract size still under 24KB limit
- [ ] Manual test on local hardhat network

---

## Not Addressed (Intentional)

| Issue | Reason |
|-------|--------|
| Unbounded bond arrays | Owner-controlled, < 10 items expected |
| Treasury validation | Owner sets at deployment |
| Emergency pause | Use resolver removal instead, no contract space |
| Owner centralization | Intentional, governance contract planned |
| Large PythPriceResolverV2 | Works, refactor later if needed |
