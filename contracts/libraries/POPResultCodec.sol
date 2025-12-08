// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

/// @title POPResultCodec
/// @notice Encoding/decoding utilities for POP results
/// @dev All results are ABI-encoded for consistency. Boolean and numeric use abi.encode,
///      generic results are stored as raw bytes.
library POPResultCodec {
    /// @notice Encode a boolean result
    /// @param value The boolean value to encode
    /// @return ABI-encoded bytes (32 bytes)
    function encodeBoolean(bool value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice Encode a numeric result
    /// @param value The int256 value to encode
    /// @return ABI-encoded bytes (32 bytes)
    function encodeNumeric(int256 value) internal pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice Decode a boolean result
    /// @param data The ABI-encoded bytes
    /// @return The decoded boolean value
    function decodeBoolean(bytes memory data) internal pure returns (bool) {
        return abi.decode(data, (bool));
    }

    /// @notice Decode a numeric result
    /// @param data The ABI-encoded bytes
    /// @return The decoded int256 value
    function decodeNumeric(bytes memory data) internal pure returns (int256) {
        return abi.decode(data, (int256));
    }
}
