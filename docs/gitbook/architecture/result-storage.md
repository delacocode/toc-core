# Result Storage

## Unified Bytes Approach

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

## POPResultCodec Helper

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

## Why Unified Storage?

Previous approach: separate mappings for bool, int256, bytes results.

**Problems:**
- 6 storage mappings instead of 2
- Conditional branching in state machine
- New answer types required contract changes

**Unified approach:**
- Single `_results` mapping
- Answer type stored in POP metadata
- Decoder library handles type-specific extraction
- Future types need zero contract changes
