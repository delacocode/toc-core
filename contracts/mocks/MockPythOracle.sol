// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/// @title MockPythOracle
/// @notice Mock Pyth oracle for testnet deployment
/// @dev Accepts ABI-encoded price updates, charges 1 wei per update to match production flow
contract MockPythOracle {
    mapping(bytes32 => PythStructs.Price) private prices;

    error InsufficientFee();
    error PriceTooOld();

    /// @notice Update price feeds with encoded payloads
    /// @dev Each update: abi.encode(priceId, price, conf, expo, publishTime)
    /// @param updateData Array of ABI-encoded price updates
    function updatePriceFeeds(bytes[] calldata updateData) external payable {
        if (msg.value < updateData.length) revert InsufficientFee();

        for (uint i = 0; i < updateData.length; i++) {
            (
                bytes32 priceId,
                int64 price,
                uint64 conf,
                int32 expo,
                uint publishTime
            ) = abi.decode(updateData[i], (bytes32, int64, uint64, int32, uint));

            prices[priceId] = PythStructs.Price({
                price: price,
                conf: conf,
                expo: expo,
                publishTime: publishTime
            });
        }
    }

    /// @notice Get price without recency check
    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        return prices[id];
    }

    /// @notice Get price with age validation
    function getPriceNoOlderThan(bytes32 id, uint age) external view returns (PythStructs.Price memory) {
        if (block.timestamp - prices[id].publishTime > age) revert PriceTooOld();
        return prices[id];
    }

    /// @notice Calculate fee for updates (1 wei per update)
    function getUpdateFee(bytes[] calldata updateData) external pure returns (uint) {
        return updateData.length;
    }

    /// @notice Get valid time period (60 seconds for mock)
    function getValidTimePeriod() external pure returns (uint) {
        return 60;
    }
}
