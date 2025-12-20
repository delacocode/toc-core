// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import "../TOCRegistry/ITOCResolver.sol";
import "../TOCRegistry/ITOCRegistry.sol";
import "../TOCRegistry/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";

/// @title PythPriceResolverV2
/// @notice Professional-grade resolver for crypto price-based TOCs using Pyth oracle
/// @dev Implements 15 standardized templates for price conditions
contract PythPriceResolverV2 is ITOCResolver {
    // ============ Constants ============

    uint32 public constant TEMPLATE_NONE = 0;
    uint32 public constant TEMPLATE_SNAPSHOT = 1;
    uint32 public constant TEMPLATE_RANGE = 2;
    uint32 public constant TEMPLATE_REACHED_TARGET = 3;
    uint32 public constant TEMPLATE_TOUCHED_BOTH = 4;
    uint32 public constant TEMPLATE_STAYED = 5;
    uint32 public constant TEMPLATE_STAYED_IN_RANGE = 6;
    uint32 public constant TEMPLATE_BREAKOUT = 7;
    uint32 public constant TEMPLATE_PERCENTAGE_CHANGE = 8;
    uint32 public constant TEMPLATE_PERCENTAGE_EITHER = 9;
    uint32 public constant TEMPLATE_END_VS_START = 10;
    uint32 public constant TEMPLATE_ASSET_COMPARE = 11;
    uint32 public constant TEMPLATE_RATIO_THRESHOLD = 12;
    uint32 public constant TEMPLATE_SPREAD_THRESHOLD = 13;
    uint32 public constant TEMPLATE_FLIP = 14;
    uint32 public constant TEMPLATE_FIRST_TO_TARGET = 15;
    uint32 public constant TEMPLATE_COUNT = 16;

    /// @notice Maximum confidence as percentage of price (1% = 100 basis points)
    uint64 public constant MAX_CONFIDENCE_BPS = 100;

    /// @notice Tolerance for point-in-time resolution (1 second)
    uint256 public constant POINT_IN_TIME_TOLERANCE = 1;

    /// @notice Standard price decimals (8 decimals like Pyth USD pairs)
    int32 public constant PRICE_DECIMALS = 8;

    // ============ Immutables ============

    IPyth public immutable pyth;
    ITOCRegistry public immutable registry;

    // ============ Storage ============

    struct ReferencePrice {
        int64 price;
        uint256 timestamp;
        bool isSet;
    }

    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;
    mapping(uint256 => ReferencePrice) private _referencePrice;

    // ============ Events ============

    event SnapshotTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 threshold,
        bool isAbove,
        uint256 deadline
    );

    event RangeTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 lowerBound,
        int64 upperBound,
        bool isInside,
        uint256 deadline
    );

    event ReachedTargetTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 target,
        bool isAbove,
        uint256 deadline
    );

    event TouchedBothTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 targetA,
        int64 targetB,
        uint256 deadline
    );

    event StayedTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 startTime,
        uint256 deadline,
        int64 threshold,
        bool isAbove
    );

    event TOCResolved(
        uint256 indexed tocId,
        uint32 indexed templateId,
        bool outcome,
        int64 priceUsed,
        uint256 publishTime
    );

    event ReferencePriceSet(uint256 indexed tocId, int64 price, uint256 timestamp);

    // ============ Structs ============

    struct SnapshotPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 threshold;
        bool isAbove;
    }

    struct RangePayload {
        bytes32 priceId;
        uint256 deadline;
        int64 lowerBound;
        int64 upperBound;
        bool isInside;
    }

    struct ReachedTargetPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 target;
        bool isAbove;
    }

    struct TouchedBothPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 targetA;
        int64 targetB;
    }

    struct StayedPayload {
        bytes32 priceId;
        uint256 startTime;
        uint256 deadline;
        int64 threshold;
        bool isAbove;  // true = must stay above, false = must stay below
    }

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPriceId();
    error DeadlineInPast();
    error InvalidBounds();
    error InvalidPercentage();
    error SamePriceIds();
    error DeadlineNotReached(uint256 deadline, uint256 current);
    error PriceNotNearDeadline(uint256 publishTime, uint256 deadline);
    error PriceAfterDeadline(uint256 publishTime, uint256 deadline);
    error ConfidenceTooWide(uint64 confidence, int64 price);
    error TocNotManaged(uint256 tocId);
    error OnlyRegistry();
    error InvalidPayload();
    error InvalidProofArray();
    error ConditionNotMet();
    error ReferencePriceAlreadySet(uint256 tocId);
    error InvalidReferenceTimestamp(uint256 expected, uint256 actual);
    error InvalidTimeRange();

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
        registry = ITOCRegistry(_registry);
    }

    // ============ ITOCResolver Implementation (stubs) ============

    function isTocManaged(uint256 tocId) external view returns (bool) {
        return _tocTemplates[tocId] != TEMPLATE_NONE;
    }

    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (TOCState initialState) {
        if (templateId == TEMPLATE_NONE || templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        _tocTemplates[tocId] = templateId;
        _tocPayloads[tocId] = payload;

        // Validate and emit events based on template
        if (templateId == TEMPLATE_SNAPSHOT) {
            _validateAndEmitSnapshot(tocId, payload);
        } else if (templateId == TEMPLATE_RANGE) {
            _validateAndEmitRange(tocId, payload);
        } else if (templateId == TEMPLATE_REACHED_TARGET) {
            _validateAndEmitReachedTarget(tocId, payload);
        } else if (templateId == TEMPLATE_TOUCHED_BOTH) {
            _validateAndEmitTouchedBoth(tocId, payload);
        } else if (templateId == TEMPLATE_STAYED) {
            _validateAndEmitStayed(tocId, payload);
        }

        return TOCState.ACTIVE;
    }

    function resolveToc(
        uint256 tocId,
        address,
        bytes calldata pythUpdateData
    ) external onlyRegistry returns (bytes memory result) {
        uint32 templateId = _tocTemplates[tocId];
        if (templateId == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }

        bool outcome;
        if (templateId == TEMPLATE_SNAPSHOT) {
            outcome = _resolveSnapshot(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_RANGE) {
            outcome = _resolveRange(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_REACHED_TARGET) {
            outcome = _resolveReachedTarget(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_TOUCHED_BOTH) {
            outcome = _resolveTouchedBoth(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_STAYED) {
            outcome = _resolveStayed(tocId, pythUpdateData);
        } else {
            revert InvalidTemplate(templateId);
        }

        return TOCResultCodec.encodeBoolean(outcome);
    }

    function getTocDetails(
        uint256 tocId
    ) external view returns (uint32 templateId, bytes memory creationPayload) {
        return (_tocTemplates[tocId], _tocPayloads[tocId]);
    }

    function getTocQuestion(uint256 tocId) external view returns (string memory) {
        if (_tocTemplates[tocId] == TEMPLATE_NONE) {
            return "Unknown TOC";
        }
        return "Price question"; // Stub
    }

    function getTemplateCount() external pure returns (uint32) {
        return TEMPLATE_COUNT;
    }

    function isValidTemplate(uint32 templateId) external pure returns (bool) {
        return templateId > TEMPLATE_NONE && templateId < TEMPLATE_COUNT;
    }

    function getTemplateAnswerType(uint32) external pure returns (AnswerType) {
        return AnswerType.BOOLEAN;
    }

    // ============ Reference Price Functions ============

    /// @notice Set the reference price for a TOC
    /// @param tocId The TOC ID
    /// @param pythUpdateData Pyth proof for the reference price
    /// @dev Can only be called once per TOC, validates against referenceTimestamp in payload
    function setReferencePrice(uint256 tocId, bytes calldata pythUpdateData) external {
        uint32 templateId = _tocTemplates[tocId];
        if (templateId == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }

        // Check if reference price is already set
        if (_referencePrice[tocId].isSet) {
            revert ReferencePriceAlreadySet(tocId);
        }

        // Decode pythUpdateData
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // Update Pyth
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Get the priceId from the payload based on template
        bytes32 priceId;
        uint256 referenceTimestamp;

        // Extract priceId and referenceTimestamp from payload based on template
        // For templates 7-10, 14, the payload should include referenceTimestamp
        // For now, we'll extract from the common payload structures
        bytes memory payload = _tocPayloads[tocId];

        if (templateId == TEMPLATE_SNAPSHOT) {
            SnapshotPayload memory p = abi.decode(payload, (SnapshotPayload));
            priceId = p.priceId;
            referenceTimestamp = 0; // Snapshot doesn't have referenceTimestamp
        } else if (templateId == TEMPLATE_RANGE) {
            RangePayload memory p = abi.decode(payload, (RangePayload));
            priceId = p.priceId;
            referenceTimestamp = 0;
        } else if (templateId == TEMPLATE_REACHED_TARGET) {
            ReachedTargetPayload memory p = abi.decode(payload, (ReachedTargetPayload));
            priceId = p.priceId;
            referenceTimestamp = 0;
        } else if (templateId == TEMPLATE_TOUCHED_BOTH) {
            TouchedBothPayload memory p = abi.decode(payload, (TouchedBothPayload));
            priceId = p.priceId;
            referenceTimestamp = 0;
        } else {
            // For templates that use reference prices, try to decode referenceTimestamp
            // Assuming the payload has a referenceTimestamp field at a specific position
            // This is a simplified version - in production, each template would have its own struct
            assembly {
                // Load referenceTimestamp from offset in payload
                // This assumes referenceTimestamp is at a known position
                referenceTimestamp := mload(add(payload, 96)) // Adjust offset as needed
                priceId := mload(add(payload, 32))
            }
        }

        // Get price from Pyth
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600 // Allow fetching recent price
        );

        // Validate timestamp if referenceTimestamp is set
        if (referenceTimestamp != 0) {
            // Pyth proof must have publishTime within 1 second of referenceTimestamp
            if (priceData.publishTime < referenceTimestamp ||
                priceData.publishTime > referenceTimestamp + POINT_IN_TIME_TOLERANCE) {
                revert InvalidReferenceTimestamp(referenceTimestamp, priceData.publishTime);
            }
        }
        // If referenceTimestamp = 0, accept any recent Pyth proof

        // Validate confidence
        _checkConfidence(priceData.conf, priceData.price);

        // Normalize to 8 decimals
        int64 normalizedPrice = _normalizePrice(priceData.price, priceData.expo);

        // Store reference price
        _referencePrice[tocId] = ReferencePrice({
            price: normalizedPrice,
            timestamp: priceData.publishTime,
            isSet: true
        });

        emit ReferencePriceSet(tocId, normalizedPrice, priceData.publishTime);
    }

    // ============ Internal Functions ============

    function _validateAndEmitSnapshot(uint256 tocId, bytes calldata payload) internal {
        SnapshotPayload memory p = abi.decode(payload, (SnapshotPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit SnapshotTOCCreated(tocId, p.priceId, p.threshold, p.isAbove, p.deadline);
    }

    function _resolveSnapshot(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        SnapshotPayload memory p = abi.decode(_tocPayloads[tocId], (SnapshotPayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get and validate price
        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Check condition
        bool outcome;
        if (p.isAbove) {
            outcome = price > p.threshold;
        } else {
            outcome = price < p.threshold;
        }

        emit TOCResolved(tocId, TEMPLATE_SNAPSHOT, outcome, price, publishTime);
        return outcome;
    }

    function _getPriceAtDeadline(
        bytes32 priceId,
        uint256 deadline,
        bytes calldata pythUpdateData
    ) internal returns (int64 price, uint256 publishTime) {
        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // Update Pyth
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Get price
        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600 // Allow fetching recent price
        );

        // Validate timing - must be within 1 second of deadline
        if (priceData.publishTime < deadline || priceData.publishTime > deadline + POINT_IN_TIME_TOLERANCE) {
            revert PriceNotNearDeadline(priceData.publishTime, deadline);
        }

        // Validate confidence (must be < 1% of price)
        _checkConfidence(priceData.conf, priceData.price);

        // Normalize to 8 decimals
        price = _normalizePrice(priceData.price, priceData.expo);
        publishTime = priceData.publishTime;
    }

    function _checkConfidence(uint64 conf, int64 price) internal pure {
        // conf * 100 > |price| means conf > 1% of price
        int64 absPrice = price < 0 ? -price : price;
        if (conf * 100 > uint64(absPrice)) {
            revert ConfidenceTooWide(conf, price);
        }
    }

    function _normalizePrice(int64 price, int32 expo) internal pure returns (int64) {
        // Normalize to 8 decimals (PRICE_DECIMALS = 8, meaning 10^-8)
        // Pyth uses negative exponents, e.g., expo=-8 means price * 10^-8
        if (expo == -PRICE_DECIMALS) {
            // Already normalized (e.g., expo = -8 for USD pairs)
            return price;
        } else if (expo < -PRICE_DECIMALS) {
            // expo is more negative, need to divide
            // e.g., expo=-10, target=-8, so divide by 10^2
            int32 diff = -PRICE_DECIMALS - expo; // diff = -8 - (-10) = 2
            return price / int64(int256(10 ** uint32(diff)));
        } else {
            // expo is less negative (or positive), need to multiply
            // e.g., expo=-6, target=-8, so multiply by 10^2
            int32 diff = expo - (-PRICE_DECIMALS); // diff = -6 - (-8) = 2
            return price * int64(int256(10 ** uint32(diff)));
        }
    }

    function _validateAndEmitRange(uint256 tocId, bytes calldata payload) internal {
        RangePayload memory p = abi.decode(payload, (RangePayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();
        if (p.lowerBound >= p.upperBound) revert InvalidBounds();

        emit RangeTOCCreated(tocId, p.priceId, p.lowerBound, p.upperBound, p.isInside, p.deadline);
    }

    function _resolveRange(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        RangePayload memory p = abi.decode(_tocPayloads[tocId], (RangePayload));

        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        bool inRange = price >= p.lowerBound && price <= p.upperBound;
        bool outcome = p.isInside ? inRange : !inRange;

        emit TOCResolved(tocId, TEMPLATE_RANGE, outcome, price, publishTime);
        return outcome;
    }

    function _validateAndEmitReachedTarget(uint256 tocId, bytes calldata payload) internal {
        ReachedTargetPayload memory p = abi.decode(payload, (ReachedTargetPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit ReachedTargetTOCCreated(tocId, p.priceId, p.target, p.isAbove, p.deadline);
    }

    function _resolveReachedTarget(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        ReachedTargetPayload memory p = abi.decode(_tocPayloads[tocId], (ReachedTargetPayload));

        (int64 price, uint256 publishTime) = _getPriceBeforeDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Check if target was reached
        bool reached;
        if (p.isAbove) {
            reached = price >= p.target;
        } else {
            reached = price <= p.target;
        }

        // If reached, resolve YES
        if (reached) {
            emit TOCResolved(tocId, TEMPLATE_REACHED_TARGET, true, price, publishTime);
            return true;
        }

        // If not reached and deadline passed, resolve NO
        if (block.timestamp >= p.deadline) {
            emit TOCResolved(tocId, TEMPLATE_REACHED_TARGET, false, price, publishTime);
            return false;
        }

        // Not reached and deadline not passed - can't resolve yet
        revert DeadlineNotReached(p.deadline, block.timestamp);
    }

    function _getPriceBeforeDeadline(
        bytes32 priceId,
        uint256 deadline,
        bytes calldata pythUpdateData
    ) internal returns (int64 price, uint256 publishTime) {
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        PythStructs.Price memory priceData = pyth.getPriceNoOlderThan(
            priceId,
            3600
        );

        // For "before deadline" templates, publishTime must be <= deadline
        if (priceData.publishTime > deadline) {
            revert PriceAfterDeadline(priceData.publishTime, deadline);
        }

        _checkConfidence(priceData.conf, priceData.price);

        price = _normalizePrice(priceData.price, priceData.expo);
        publishTime = priceData.publishTime;
    }

    function _validateAndEmitTouchedBoth(uint256 tocId, bytes calldata payload) internal {
        TouchedBothPayload memory p = abi.decode(payload, (TouchedBothPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit TouchedBothTOCCreated(tocId, p.priceId, p.targetA, p.targetB, p.deadline);
    }

    function _resolveTouchedBoth(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        TouchedBothPayload memory p = abi.decode(_tocPayloads[tocId], (TouchedBothPayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Decode multiple price updates
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));
        if (updates.length == 0) {
            revert InvalidProofArray();
        }

        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Check if both targets were touched
        bool touchedA = false;
        bool touchedB = false;
        int64 lastPrice = 0;
        uint256 lastPublishTime = 0;

        for (uint256 i = 0; i < updates.length; i++) {
            // Decode the price feed from the update
            (PythStructs.PriceFeed memory priceFeed,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            // Verify this is the correct price ID
            if (priceFeed.id != p.priceId) {
                continue;
            }

            // Validate timing - publishTime must be <= deadline
            if (priceFeed.price.publishTime > p.deadline) {
                revert PriceAfterDeadline(priceFeed.price.publishTime, p.deadline);
            }

            // Validate confidence
            _checkConfidence(priceFeed.price.conf, priceFeed.price.price);

            // Normalize price
            int64 normalizedPrice = _normalizePrice(priceFeed.price.price, priceFeed.price.expo);

            // Check if this proof shows targetA was reached (>= targetA)
            if (normalizedPrice >= p.targetA) {
                touchedA = true;
            }

            // Check if this proof shows targetB was reached (<= targetB)
            if (normalizedPrice <= p.targetB) {
                touchedB = true;
            }

            // Track last price for event
            lastPrice = normalizedPrice;
            lastPublishTime = priceFeed.price.publishTime;
        }

        // Return true only if BOTH targets were touched
        bool outcome = touchedA && touchedB;

        emit TOCResolved(tocId, TEMPLATE_TOUCHED_BOTH, outcome, lastPrice, lastPublishTime);
        return outcome;
    }

    function _validateAndEmitStayed(uint256 tocId, bytes calldata payload) internal {
        StayedPayload memory p = abi.decode(payload, (StayedPayload));

        if (p.priceId == bytes32(0)) revert InvalidPriceId();
        if (p.startTime >= p.deadline) revert InvalidTimeRange();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit StayedTOCCreated(tocId, p.priceId, p.startTime, p.deadline, p.threshold, p.isAbove);
    }

    function _resolveStayed(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        StayedPayload memory p = abi.decode(_tocPayloads[tocId], (StayedPayload));

        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // OPTIMISTIC APPROACH:
        // If no proof provided (empty array) and deadline passed → resolve YES
        if (updates.length == 0) {
            // Must be at or after deadline to resolve YES without proof
            if (block.timestamp < p.deadline) {
                revert DeadlineNotReached(p.deadline, block.timestamp);
            }

            // No counter-proof submitted, resolve YES (price stayed within bounds)
            emit TOCResolved(tocId, TEMPLATE_STAYED, true, 0, p.deadline);
            return true;
        }

        // If proof provided → check if it shows a violation
        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Check all proofs for a violation
        for (uint256 i = 0; i < updates.length; i++) {
            // Decode the price feed from the update
            (PythStructs.PriceFeed memory priceFeed,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            // Verify this is the correct price ID
            if (priceFeed.id != p.priceId) {
                continue;
            }

            // Validate timing - publishTime must be within [startTime, deadline]
            if (priceFeed.price.publishTime < p.startTime || priceFeed.price.publishTime > p.deadline) {
                continue; // Skip proofs outside the time range
            }

            // Validate confidence
            _checkConfidence(priceFeed.price.conf, priceFeed.price.price);

            // Normalize price
            int64 normalizedPrice = _normalizePrice(priceFeed.price.price, priceFeed.price.expo);

            // Check if this proof shows a violation
            bool violated = false;
            if (p.isAbove) {
                // Must stay above threshold, violation if price <= threshold
                violated = normalizedPrice <= p.threshold;
            } else {
                // Must stay below threshold, violation if price >= threshold
                violated = normalizedPrice >= p.threshold;
            }

            if (violated) {
                // Found a counter-proof showing violation → resolve NO
                emit TOCResolved(tocId, TEMPLATE_STAYED, false, normalizedPrice, priceFeed.price.publishTime);
                return false;
            }
        }

        // All proofs checked, no violation found
        // But if proofs were provided, they should show a violation for NO
        // If we reach here, the proofs don't show a violation → resolve YES
        // Note: This allows someone to try to submit proofs that fail to show violation
        // In that case, we still resolve YES (price stayed)
        emit TOCResolved(tocId, TEMPLATE_STAYED, true, 0, p.deadline);
        return true;
    }

    // ============ Receive ============

    receive() external payable {}
}
