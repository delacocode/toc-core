// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "../Popregistry/IPopResolver.sol";
import "../Popregistry/IPOPRegistry.sol";
import "../Popregistry/POPTypes.sol";

/// @title PythPriceResolver
/// @notice Resolver for price-based POPs using Pyth oracle
/// @dev Implements 3 templates:
///   - Template 0: Snapshot Above/Below - Is price above/below threshold at deadline?
///   - Template 1: Price Range - Is price within range at deadline?
///   - Template 2: Reached By - Did price reach target at any point before deadline?
contract PythPriceResolver is IPopResolver {
    // ============ Constants ============

    uint32 public constant TEMPLATE_SNAPSHOT = 0;
    uint32 public constant TEMPLATE_RANGE = 1;
    uint32 public constant TEMPLATE_REACHED_BY = 2;
    uint32 public constant TEMPLATE_COUNT = 3;

    // ============ Immutables ============

    IPyth public immutable pyth;
    IPOPRegistry public immutable registry;

    // ============ Storage ============

    /// @notice Data for Template 0: Snapshot Above/Below
    struct SnapshotData {
        bytes32 priceId;
        int64 threshold;
        bool isAbove; // true = above, false = below
        uint256 deadline;
    }

    /// @notice Data for Template 1: Price Range
    struct RangeData {
        bytes32 priceId;
        int64 lowerBound;
        int64 upperBound;
        uint256 deadline;
    }

    /// @notice Data for Template 2: Reached By
    struct ReachedByData {
        bytes32 priceId;
        int64 targetPrice;
        bool isAbove; // true = must go above, false = must go below
        uint256 deadline;
        bool reached; // Track if target was ever reached
    }

    mapping(uint256 => uint32) private _popTemplates;
    mapping(uint256 => bytes) private _popPayloads;
    mapping(uint256 => SnapshotData) private _snapshotPops;
    mapping(uint256 => RangeData) private _rangePops;
    mapping(uint256 => ReachedByData) private _reachedByPops;

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPayload();
    error DeadlineNotReached(uint256 deadline, uint256 current);
    error DeadlinePassed(uint256 deadline, uint256 current);
    error PopNotManaged(uint256 popId);
    error OnlyRegistry();
    error InvalidPriceData();
    error PriceDataTooOld(uint256 publishTime, uint256 deadline);

    // ============ Modifiers ============

    modifier onlyRegistry() {
        if (msg.sender != address(registry)) {
            revert OnlyRegistry();
        }
        _;
    }

    // ============ Constructor ============

    constructor(address _pyth, address _registry) {
        pyth = IPyth(_pyth);
        registry = IPOPRegistry(_registry);
    }

    // ============ IPopResolver Implementation ============

    /// @inheritdoc IPopResolver
    function isPopManaged(uint256 popId) external view returns (bool) {
        return _popTemplates[popId] != 0 || _popPayloads[popId].length > 0;
    }

    /// @inheritdoc IPopResolver
    function onPopCreated(
        uint256 popId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (POPState initialState) {
        if (templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        _popTemplates[popId] = templateId;
        _popPayloads[popId] = payload;

        if (templateId == TEMPLATE_SNAPSHOT) {
            _decodeAndStoreSnapshot(popId, payload);
        } else if (templateId == TEMPLATE_RANGE) {
            _decodeAndStoreRange(popId, payload);
        } else {
            _decodeAndStoreReachedBy(popId, payload);
        }

        // All templates go directly to ACTIVE (no approval needed for price feeds)
        return POPState.ACTIVE;
    }

    /// @inheritdoc IPopResolver
    function resolvePop(
        uint256 popId,
        address, // caller not used for price resolution
        bytes calldata pythUpdateData
    ) external onlyRegistry returns (bool booleanResult, int256 numericResult, bytes memory genericResult) {
        uint32 templateId = _popTemplates[popId];

        bool outcome;
        if (templateId == TEMPLATE_SNAPSHOT) {
            outcome = _resolveSnapshot(popId, pythUpdateData);
        } else if (templateId == TEMPLATE_RANGE) {
            outcome = _resolveRange(popId, pythUpdateData);
        } else if (templateId == TEMPLATE_REACHED_BY) {
            outcome = _resolveReachedBy(popId, pythUpdateData);
        } else {
            revert PopNotManaged(popId);
        }

        // All Pyth templates return boolean results
        booleanResult = outcome;
        numericResult = 0;
        genericResult = "";
    }

    /// @inheritdoc IPopResolver
    function getPopDetails(
        uint256 popId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        return (_popTemplates[popId], _popPayloads[popId]);
    }

    /// @inheritdoc IPopResolver
    function getPopQuestion(
        uint256 popId
    ) external view returns (string memory question) {
        uint32 templateId = _popTemplates[popId];

        if (templateId == TEMPLATE_SNAPSHOT) {
            SnapshotData storage data = _snapshotPops[popId];
            string memory direction = data.isAbove ? "above" : "below";
            return string(
                abi.encodePacked(
                    "Will price be ",
                    direction,
                    " ",
                    _int64ToString(data.threshold),
                    " at timestamp ",
                    _uint256ToString(data.deadline),
                    "?"
                )
            );
        } else if (templateId == TEMPLATE_RANGE) {
            RangeData storage data = _rangePops[popId];
            return string(
                abi.encodePacked(
                    "Will price be between ",
                    _int64ToString(data.lowerBound),
                    " and ",
                    _int64ToString(data.upperBound),
                    " at timestamp ",
                    _uint256ToString(data.deadline),
                    "?"
                )
            );
        } else if (templateId == TEMPLATE_REACHED_BY) {
            ReachedByData storage data = _reachedByPops[popId];
            string memory direction = data.isAbove ? "above" : "below";
            return string(
                abi.encodePacked(
                    "Will price reach ",
                    direction,
                    " ",
                    _int64ToString(data.targetPrice),
                    " by timestamp ",
                    _uint256ToString(data.deadline),
                    "?"
                )
            );
        }

        return "Unknown POP";
    }

    /// @inheritdoc IPopResolver
    function getTemplateCount() external pure returns (uint32 count) {
        return TEMPLATE_COUNT;
    }

    /// @inheritdoc IPopResolver
    function isValidTemplate(uint32 templateId) external pure returns (bool) {
        return templateId < TEMPLATE_COUNT;
    }

    /// @inheritdoc IPopResolver
    function getTemplateAnswerType(uint32 templateId) external pure returns (AnswerType) {
        // All Pyth templates return boolean (price above/below threshold)
        return AnswerType.BOOLEAN;
    }

    // ============ View Functions ============

    /// @notice Get snapshot POP data
    function getSnapshotData(uint256 popId) external view returns (SnapshotData memory) {
        return _snapshotPops[popId];
    }

    /// @notice Get range POP data
    function getRangeData(uint256 popId) external view returns (RangeData memory) {
        return _rangePops[popId];
    }

    /// @notice Get reached-by POP data
    function getReachedByData(uint256 popId) external view returns (ReachedByData memory) {
        return _reachedByPops[popId];
    }

    // ============ Internal Functions ============

    function _decodeAndStoreSnapshot(uint256 popId, bytes calldata payload) internal {
        if (payload.length < 73) revert InvalidPayload(); // 32 + 8 + 1 + 32 = 73 bytes minimum

        (bytes32 priceId, int64 threshold, bool isAbove, uint256 deadline) = abi.decode(
            payload,
            (bytes32, int64, bool, uint256)
        );

        _snapshotPops[popId] = SnapshotData({
            priceId: priceId,
            threshold: threshold,
            isAbove: isAbove,
            deadline: deadline
        });
    }

    function _decodeAndStoreRange(uint256 popId, bytes calldata payload) internal {
        if (payload.length < 80) revert InvalidPayload(); // 32 + 8 + 8 + 32 = 80 bytes minimum

        (bytes32 priceId, int64 lowerBound, int64 upperBound, uint256 deadline) = abi.decode(
            payload,
            (bytes32, int64, int64, uint256)
        );

        _rangePops[popId] = RangeData({
            priceId: priceId,
            lowerBound: lowerBound,
            upperBound: upperBound,
            deadline: deadline
        });
    }

    function _decodeAndStoreReachedBy(uint256 popId, bytes calldata payload) internal {
        if (payload.length < 73) revert InvalidPayload(); // 32 + 8 + 1 + 32 = 73 bytes minimum

        (bytes32 priceId, int64 targetPrice, bool isAbove, uint256 deadline) = abi.decode(
            payload,
            (bytes32, int64, bool, uint256)
        );

        _reachedByPops[popId] = ReachedByData({
            priceId: priceId,
            targetPrice: targetPrice,
            isAbove: isAbove,
            deadline: deadline,
            reached: false
        });
    }

    function _resolveSnapshot(
        uint256 popId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        SnapshotData storage data = _snapshotPops[popId];

        // Deadline must have passed for snapshot
        if (block.timestamp < data.deadline) {
            revert DeadlineNotReached(data.deadline, block.timestamp);
        }

        // Get price from Pyth update
        int64 price = _getPriceFromUpdate(data.priceId, pythUpdateData, data.deadline);

        // Check condition
        if (data.isAbove) {
            return price > data.threshold;
        } else {
            return price < data.threshold;
        }
    }

    function _resolveRange(
        uint256 popId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        RangeData storage data = _rangePops[popId];

        // Deadline must have passed
        if (block.timestamp < data.deadline) {
            revert DeadlineNotReached(data.deadline, block.timestamp);
        }

        // Get price from Pyth update
        int64 price = _getPriceFromUpdate(data.priceId, pythUpdateData, data.deadline);

        // Check if within range
        return price >= data.lowerBound && price <= data.upperBound;
    }

    function _resolveReachedBy(
        uint256 popId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        ReachedByData storage data = _reachedByPops[popId];

        // Can be resolved anytime, but outcome depends on whether target was reached

        // Parse multiple price updates to check historical prices
        bytes[] memory updateDataArray = abi.decode(pythUpdateData, (bytes[]));

        // Update Pyth with all price data
        uint256 fee = pyth.getUpdateFee(updateDataArray);
        pyth.updatePriceFeeds{value: fee}(updateDataArray);

        // Check each update to see if target was reached
        for (uint256 i = 0; i < updateDataArray.length; i++) {
            PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
                data.priceId,
                uint256(data.deadline - block.timestamp + 3600) // Allow some age tolerance
            );

            int64 price = priceData.price;

            if (data.isAbove && price >= data.targetPrice) {
                data.reached = true;
                return true;
            } else if (!data.isAbove && price <= data.targetPrice) {
                data.reached = true;
                return true;
            }
        }

        // If deadline passed and target never reached, return false
        if (block.timestamp >= data.deadline) {
            return data.reached;
        }

        // If deadline not passed and target not reached in this update, revert
        // (can't resolve yet unless target is reached)
        revert DeadlineNotReached(data.deadline, block.timestamp);
    }

    function _getPriceFromUpdate(
        bytes32 priceId,
        bytes calldata pythUpdateData,
        uint256 deadline
    ) internal returns (int64) {
        // Decode as array of update data
        bytes[] memory updateDataArray = abi.decode(pythUpdateData, (bytes[]));

        // Update Pyth prices
        uint256 fee = pyth.getUpdateFee(updateDataArray);
        pyth.updatePriceFeeds{value: fee}(updateDataArray);

        // Get price - must be close to deadline time
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600 // 1 hour tolerance
        );

        // Verify price is from around deadline time (within 1 hour)
        if (priceData.publishTime < deadline - 3600 || priceData.publishTime > deadline + 3600) {
            revert PriceDataTooOld(priceData.publishTime, deadline);
        }

        return priceData.price;
    }

    // ============ String Helpers ============

    function _int64ToString(int64 value) internal pure returns (string memory) {
        if (value < 0) {
            return string(abi.encodePacked("-", _uint64ToString(uint64(-value))));
        }
        return _uint64ToString(uint64(value));
    }

    function _uint64ToString(uint64 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint64 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint64(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // ============ Receive ============

    /// @notice Allow receiving ETH for Pyth fee payments
    receive() external payable {}
}
