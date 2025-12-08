# Unified Bytes Result Design

**Date:** 2025-12-08
**Status:** Approved for Implementation

---

## Overview

Replace the triple-field answer type system (`booleanResult`, `numericResult`, `genericResult`) with a unified `bytes result` field. This simplifies storage, reduces contract size, and eliminates conditional branching throughout the codebase.

---

## Goals

1. **Reduce storage complexity** - 6 result mappings → 2
2. **Simplify codebase** - Remove conditional `if (answerType == BOOLEAN)` branches
3. **Gas optimization** - Fewer storage reads, simpler logic

---

## Design Decisions

| Aspect | Decision |
|--------|----------|
| Storage | Single `_results` mapping + `_hasCorrectedResult` flag |
| Encoding | ABI-encoded for bool/int256, raw bytes for generic |
| AnswerType | Keep enum, include in result structs for decoding context |
| Structs | Triple fields → single `bytes result` |
| IPopResolver | Returns `bytes memory result` |
| Typed getters | Remove, replace with `getResult()` + `getOriginalResult()` |
| Helper library | `POPResultCodec` for encode/decode convenience |

---

## Storage Changes

### Before (6 mappings)

```solidity
mapping(uint256 => bool) private _booleanResults;
mapping(uint256 => int256) private _numericResults;
mapping(uint256 => bytes) private _genericResults;
mapping(uint256 => bool) private _correctedBooleanResults;
mapping(uint256 => int256) private _correctedNumericResults;
mapping(uint256 => bytes) private _correctedGenericResults;
mapping(uint256 => bool) private _hasCorrectedResult;
```

### After (2 mappings)

```solidity
mapping(uint256 => bytes) private _results;
mapping(uint256 => bool) private _hasCorrectedResult;
```

### Encoding Convention

- **Boolean:** `abi.encode(bool)` → 32 bytes
- **Numeric:** `abi.encode(int256)` → 32 bytes
- **Generic:** stored as-is (already bytes)

### Result Storage Logic

- On resolution: `_results[popId] = abi.encode(value)` or raw bytes for generic
- On correction: overwrite `_results[popId]`, set `_hasCorrectedResult[popId] = true`
- Original result retrievable from `ResolutionInfo.proposedResult`

---

## Struct Changes

### POPResult

```solidity
// BEFORE
struct POPResult {
    AnswerType answerType;
    bool isResolved;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;
}

// AFTER
struct POPResult {
    AnswerType answerType;
    bool isResolved;
    bytes result;
}
```

### ResolutionInfo

```solidity
// BEFORE
struct ResolutionInfo {
    address proposer;
    address bondToken;
    uint256 bondAmount;
    bool proposedBooleanOutcome;
    int256 proposedNumericOutcome;
    bytes proposedGenericOutcome;
}

// AFTER
struct ResolutionInfo {
    address proposer;
    address bondToken;
    uint256 bondAmount;
    bytes proposedResult;
}
```

### DisputeInfo

```solidity
// BEFORE (relevant fields)
struct DisputeInfo {
    // ... other fields ...
    bool proposedBooleanResult;
    int256 proposedNumericResult;
    bytes proposedGenericResult;
}

// AFTER
struct DisputeInfo {
    // ... other fields ...
    bytes proposedResult;
}
```

### EscalationInfo

Same pattern as DisputeInfo - triple fields → `bytes proposedResult`

### ExtensiveResult

```solidity
// BEFORE
struct ExtensiveResult {
    AnswerType answerType;
    bool booleanResult;
    int256 numericResult;
    bytes genericResult;
    bool isFinalized;
    bool wasDisputed;
    bool wasCorrected;
    uint256 resolvedAt;
    AccountabilityTier tier;
    ResolverTrust resolverTrust;
}

// AFTER
struct ExtensiveResult {
    AnswerType answerType;
    bytes result;
    bool isFinalized;
    bool wasDisputed;
    bool wasCorrected;
    uint256 resolvedAt;
    AccountabilityTier tier;
    ResolverTrust resolverTrust;
}
```

### POPInfo

Same simplification - triple result fields → single `bytes result`, keep `hasCorrectedResult` flag.

---

## Interface Changes

### IPopResolver

```solidity
// BEFORE
function resolvePop(uint256 popId, address proposer, bytes calldata payload)
    external returns (bool boolResult, int256 numResult, bytes memory genResult);

// AFTER
function resolvePop(uint256 popId, address proposer, bytes calldata payload)
    external returns (bytes memory result);
```

### IPOPRegistry - Result Getters

```solidity
// REMOVE
function getBooleanResult(uint256 popId) external view returns (bool);
function getNumericResult(uint256 popId) external view returns (int256);
function getGenericResult(uint256 popId) external view returns (bytes memory);
function getCorrectedBooleanResult(uint256 popId) external view returns (bool);
function getCorrectedNumericResult(uint256 popId) external view returns (int256);
function getCorrectedGenericResult(uint256 popId) external view returns (bytes memory);

// ADD
function getResult(uint256 popId) external view returns (bytes memory result);
function getOriginalResult(uint256 popId) external view returns (bytes memory result);
```

### IPOPRegistry - Dispute Functions

```solidity
// BEFORE
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

// AFTER
function dispute(
    uint256 popId,
    address bondToken,
    uint256 bondAmount,
    string calldata reason,
    string calldata evidenceURI,
    bytes calldata proposedResult
) external payable;
```

Same simplification for:
- `challengeTruthKeeperDecision`
- `resolveDispute`
- `resolveEscalation`
- `resolveTruthKeeperDispute`

---

## Helper Library

New file: `contracts/libraries/POPResultCodec.sol`

```solidity
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @title POPResultCodec
/// @notice Encoding/decoding utilities for POP results
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

### Usage Examples

**Resolver returning a price:**
```solidity
import {POPResultCodec} from "../libraries/POPResultCodec.sol";

function resolvePop(uint256 popId, address, bytes calldata)
    external returns (bytes memory result)
{
    int256 price = _fetchPrice(popId);
    return POPResultCodec.encodeNumeric(price);
}
```

**Consumer reading a boolean result:**
```solidity
import {POPResultCodec} from "./libraries/POPResultCodec.sol";

bytes memory resultData = registry.getResult(popId);
bool outcome = POPResultCodec.decodeBoolean(resultData);
```

---

## Files to Modify

### Contracts

| File | Changes |
|------|---------|
| `contracts/libraries/POPResultCodec.sol` | NEW - Helper library |
| `contracts/Popregistry/POPTypes.sol` | Simplify structs |
| `contracts/Popregistry/IPopResolver.sol` | Update `resolvePop` return type |
| `contracts/Popregistry/IPOPRegistry.sol` | Update interface, remove typed getters |
| `contracts/Popregistry/POPRegistry.sol` | Simplify storage, remove conditionals |
| `contracts/resolvers/PythPriceResolver.sol` | Update to new interface |
| `contracts/test/MockResolver.sol` | Update to new interface |

### Tests

| File | Changes |
|------|---------|
| `contracts/test/POPRegistry.t.sol` | Update to use new getters and encoding |

---

## Implementation Order

1. Create `POPResultCodec` library
2. Update `POPTypes.sol` structs
3. Update `IPopResolver.sol` interface
4. Update `IPOPRegistry.sol` interface
5. Update `POPRegistry.sol` implementation
6. Update resolvers (`PythPriceResolver`, `MockResolver`)
7. Update tests
8. Verify contract size reduction with `forge build --sizes`

---

## Expected Benefits

- **Storage:** 6 mappings → 2 mappings
- **Contract size:** Significant reduction from eliminated conditionals
- **Code clarity:** Single code path for all answer types
- **Maintainability:** Adding new answer types requires no contract changes
