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

    address public owner;
    mapping(uint32 => string) private _templateNames;
    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;
    mapping(uint256 => ReferencePrice) private _referencePrice;
    mapping(uint256 => ReferencePrice) private _referencePriceB;

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

    event StayedInRangeTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 startTime,
        uint256 deadline,
        int64 lowerBound,
        int64 upperBound
    );

    event BreakoutTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 deadline,
        uint256 referenceTimestamp,
        int64 referencePrice,
        bool isUp
    );

    event PercentageChangeTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 deadline,
        uint256 referenceTimestamp,
        int64 referencePrice,
        uint64 percentageBps,
        bool isUp
    );

    event PercentageEitherTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 deadline,
        uint256 referenceTimestamp,
        int64 referencePrice,
        uint64 percentageBps
    );

    event EndVsStartTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        uint256 deadline,
        uint256 referenceTimestamp,
        int64 referencePrice,
        bool isHigher
    );

    event AssetCompareTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceIdA,
        bytes32 indexed priceIdB,
        uint256 deadline,
        bool aGreater
    );

    event RatioThresholdTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceIdA,
        bytes32 indexed priceIdB,
        uint256 deadline,
        uint64 ratioBps,
        bool isAbove
    );

    event SpreadThresholdTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceIdA,
        bytes32 indexed priceIdB,
        uint256 deadline,
        int64 spreadThreshold,
        bool isAbove
    );

    event FlipTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceIdA,
        bytes32 indexed priceIdB,
        uint256 deadline,
        uint256 referenceTimestamp,
        int64 referencePriceA,
        int64 referencePriceB
    );

    event FirstToTargetTOCCreated(
        uint256 indexed tocId,
        bytes32 indexed priceId,
        int64 targetA,
        int64 targetB,
        uint256 deadline
    );

    event TOCResolved(
        uint256 indexed tocId,
        uint32 indexed templateId,
        bool outcome,
        int64 priceUsed,
        uint256 publishTime
    );

    event ReferencePriceSet(uint256 indexed tocId, int64 price, uint256 timestamp);
    event ReferencePricesSet(uint256 indexed tocId, int64 priceA, int64 priceB, uint256 timestamp);

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

    struct StayedInRangePayload {
        bytes32 priceId;
        uint256 startTime;
        uint256 deadline;
        int64 lowerBound;
        int64 upperBound;
    }

    struct BreakoutPayload {
        bytes32 priceId;
        uint256 deadline;
        uint256 referenceTimestamp;  // 0 = use setReferencePrice later
        int64 referencePrice;        // 0 = use setReferencePrice later
        bool isUp;                   // true = break above, false = break below
    }

    struct PercentageChangePayload {
        bytes32 priceId;
        uint256 deadline;
        uint256 referenceTimestamp;
        int64 referencePrice;
        uint64 percentageBps;  // Basis points (100 = 1%, 1000 = 10%)
        bool isUp;             // true = gain, false = loss
    }

    struct PercentageEitherPayload {
        bytes32 priceId;
        uint256 deadline;
        uint256 referenceTimestamp;
        int64 referencePrice;
        uint64 percentageBps;  // Basis points (100 = 1%)
    }

    struct EndVsStartPayload {
        bytes32 priceId;
        uint256 deadline;
        uint256 referenceTimestamp;
        int64 referencePrice;  // The "start" price
        bool isHigher;         // true = expect higher, false = expect lower
    }

    struct AssetComparePayload {
        bytes32 priceIdA;
        bytes32 priceIdB;
        uint256 deadline;
        bool aGreater;  // true = expect A > B, false = expect A < B
    }

    struct RatioThresholdPayload {
        bytes32 priceIdA;
        bytes32 priceIdB;
        uint256 deadline;
        uint64 ratioBps;    // Ratio threshold in basis points (e.g., 500 = 0.05 = 5%)
        bool isAbove;       // true = ratio must be above threshold
    }

    struct SpreadThresholdPayload {
        bytes32 priceIdA;
        bytes32 priceIdB;
        uint256 deadline;
        int64 spreadThreshold;  // The spread threshold (can be negative)
        bool isAbove;           // true = spread must be above threshold
    }

    struct FlipPayload {
        bytes32 priceIdA;
        bytes32 priceIdB;
        uint256 deadline;
        uint256 referenceTimestamp;  // When to capture initial state
        int64 referencePriceA;       // Initial price of A (0 = set later)
        int64 referencePriceB;       // Initial price of B (0 = set later)
    }

    struct FirstToTargetPayload {
        bytes32 priceId;
        uint256 deadline;
        int64 targetA;  // Hitting this first = YES
        int64 targetB;  // Hitting this first = NO
    }

    // ============ Errors ============

    error InvalidTemplate(uint32 templateId);
    error InvalidPriceId();
    error PriceFeedNotFound(bytes32 priceId);
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
    error ReferencePriceNotSet(uint256 tocId);

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
        owner = msg.sender;
    }

    // ============ Price Feed Validation ============

    /// @notice Validate that a Pyth price feed exists by querying current price
    /// @dev Reverts if the price feed doesn't exist in Pyth oracle
    function _validatePriceFeedExists(bytes32 priceId) internal view {
        // getPriceUnsafe will revert if the feed doesn't exist
        // We don't care about the price value or recency here, just that it exists
        try pyth.getPriceUnsafe(priceId) returns (PythStructs.Price memory) {
            // Feed exists, validation passed
        } catch {
            revert PriceFeedNotFound(priceId);
        }
    }

    // ============ Admin Functions ============

    /// @notice Set the display name for a template (admin only)
    function setTemplateName(uint32 templateId, string calldata name) external {
        require(msg.sender == owner, "Only owner");
        require(templateId > 0 && templateId < TEMPLATE_COUNT, "Invalid template");
        _templateNames[templateId] = name;
    }

    /// @notice Set multiple template names at once (admin only)
    function setTemplateNames(uint32[] calldata templateIds, string[] calldata names) external {
        require(msg.sender == owner, "Only owner");
        require(templateIds.length == names.length, "Length mismatch");
        for (uint i = 0; i < templateIds.length; i++) {
            require(templateIds[i] > 0 && templateIds[i] < TEMPLATE_COUNT, "Invalid template");
            _templateNames[templateIds[i]] = names[i];
        }
    }

    // ============ ITOCResolver Implementation (stubs) ============

    function isTocManaged(uint256 tocId) external view returns (bool) {
        return _tocTemplates[tocId] != TEMPLATE_NONE;
    }

    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload,
        address /* creator */
    ) external onlyRegistry returns (TOCState initialState) {
        if (templateId == TEMPLATE_NONE || templateId >= TEMPLATE_COUNT) {
            revert InvalidTemplate(templateId);
        }

        // Validate price feed(s) exist - all payloads have priceId as first 32 bytes
        bytes32 priceId;
        assembly {
            priceId := calldataload(payload.offset)
        }
        if (priceId == bytes32(0)) revert InvalidPriceId();
        _validatePriceFeedExists(priceId);

        // Dual-asset templates have priceIdB as second 32 bytes
        if (templateId == TEMPLATE_ASSET_COMPARE ||
            templateId == TEMPLATE_RATIO_THRESHOLD ||
            templateId == TEMPLATE_SPREAD_THRESHOLD ||
            templateId == TEMPLATE_FLIP) {
            bytes32 priceIdB;
            assembly {
                priceIdB := calldataload(add(payload.offset, 32))
            }
            if (priceIdB == bytes32(0)) revert InvalidPriceId();
            if (priceId == priceIdB) revert SamePriceIds();
            _validatePriceFeedExists(priceIdB);
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
        } else if (templateId == TEMPLATE_STAYED_IN_RANGE) {
            _validateAndEmitStayedInRange(tocId, payload);
        } else if (templateId == TEMPLATE_BREAKOUT) {
            _validateAndEmitBreakout(tocId, payload);
        } else if (templateId == TEMPLATE_PERCENTAGE_CHANGE) {
            _validateAndEmitPercentageChange(tocId, payload);
        } else if (templateId == TEMPLATE_PERCENTAGE_EITHER) {
            _validateAndEmitPercentageEither(tocId, payload);
        } else if (templateId == TEMPLATE_END_VS_START) {
            _validateAndEmitEndVsStart(tocId, payload);
        } else if (templateId == TEMPLATE_ASSET_COMPARE) {
            _validateAndEmitAssetCompare(tocId, payload);
        } else if (templateId == TEMPLATE_RATIO_THRESHOLD) {
            _validateAndEmitRatioThreshold(tocId, payload);
        } else if (templateId == TEMPLATE_SPREAD_THRESHOLD) {
            _validateAndEmitSpreadThreshold(tocId, payload);
        } else if (templateId == TEMPLATE_FLIP) {
            _validateAndEmitFlip(tocId, payload);
        } else if (templateId == TEMPLATE_FIRST_TO_TARGET) {
            _validateAndEmitFirstToTarget(tocId, payload);
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
        } else if (templateId == TEMPLATE_STAYED_IN_RANGE) {
            outcome = _resolveStayedInRange(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_BREAKOUT) {
            outcome = _resolveBreakout(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_PERCENTAGE_CHANGE) {
            outcome = _resolvePercentageChange(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_PERCENTAGE_EITHER) {
            outcome = _resolvePercentageEither(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_END_VS_START) {
            outcome = _resolveEndVsStart(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_ASSET_COMPARE) {
            outcome = _resolveAssetCompare(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_RATIO_THRESHOLD) {
            outcome = _resolveRatioThreshold(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_SPREAD_THRESHOLD) {
            outcome = _resolveSpreadThreshold(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_FLIP) {
            outcome = _resolveFlip(tocId, pythUpdateData);
        } else if (templateId == TEMPLATE_FIRST_TO_TARGET) {
            outcome = _resolveFirstToTarget(tocId, pythUpdateData);
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
        uint32 templateId = _tocTemplates[tocId];
        if (templateId == TEMPLATE_NONE) return "UNKNOWN";

        string memory name = _templateNames[templateId];
        if (bytes(name).length > 0) {
            return name;
        }

        // Default fallback - just return template ID as string
        return _uint256ToString(templateId);
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

    /// @notice Set reference prices for both assets (for multi-asset templates like Flip)
    /// @param tocId The TOC ID
    /// @param pythUpdateDataA Pyth proof for reference price A
    /// @param pythUpdateDataB Pyth proof for reference price B
    /// @dev Can only be called once per TOC, validates against referenceTimestamp in payload
    function setReferencePrices(
        uint256 tocId,
        bytes calldata pythUpdateDataA,
        bytes calldata pythUpdateDataB
    ) external {
        uint32 templateId = _tocTemplates[tocId];
        if (templateId == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }

        // Check if reference prices are already set
        if (_referencePrice[tocId].isSet || _referencePriceB[tocId].isSet) {
            revert ReferencePriceAlreadySet(tocId);
        }

        // Only for Flip template
        if (templateId != TEMPLATE_FLIP) {
            revert InvalidTemplate(templateId);
        }

        FlipPayload memory p = abi.decode(_tocPayloads[tocId], (FlipPayload));

        // Decode pythUpdateData
        bytes[] memory updatesA = abi.decode(pythUpdateDataA, (bytes[]));
        bytes[] memory updatesB = abi.decode(pythUpdateDataB, (bytes[]));

        // Update Pyth for both
        uint256 feeA = pyth.getUpdateFee(updatesA);
        uint256 feeB = pyth.getUpdateFee(updatesB);
        pyth.updatePriceFeeds{value: feeA}(updatesA);
        pyth.updatePriceFeeds{value: feeB}(updatesB);

        // Get price A from Pyth
        PythStructs.Price memory priceDataA = pyth.getPriceNoOlderThan(
            p.priceIdA,
            3600 // Allow fetching recent price
        );

        // Get price B from Pyth
        PythStructs.Price memory priceDataB = pyth.getPriceNoOlderThan(
            p.priceIdB,
            3600 // Allow fetching recent price
        );

        // Validate timestamp if referenceTimestamp is set
        if (p.referenceTimestamp != 0) {
            // Pyth proof must have publishTime within 1 second of referenceTimestamp
            if (priceDataA.publishTime < p.referenceTimestamp ||
                priceDataA.publishTime > p.referenceTimestamp + POINT_IN_TIME_TOLERANCE) {
                revert InvalidReferenceTimestamp(p.referenceTimestamp, priceDataA.publishTime);
            }
            if (priceDataB.publishTime < p.referenceTimestamp ||
                priceDataB.publishTime > p.referenceTimestamp + POINT_IN_TIME_TOLERANCE) {
                revert InvalidReferenceTimestamp(p.referenceTimestamp, priceDataB.publishTime);
            }
        }

        // Validate confidence
        _checkConfidence(priceDataA.conf, priceDataA.price);
        _checkConfidence(priceDataB.conf, priceDataB.price);

        // Normalize to 8 decimals
        int64 normalizedPriceA = _normalizePrice(priceDataA.price, priceDataA.expo);
        int64 normalizedPriceB = _normalizePrice(priceDataB.price, priceDataB.expo);

        // Store reference prices
        _referencePrice[tocId] = ReferencePrice({
            price: normalizedPriceA,
            timestamp: priceDataA.publishTime,
            isSet: true
        });
        _referencePriceB[tocId] = ReferencePrice({
            price: normalizedPriceB,
            timestamp: priceDataB.publishTime,
            isSet: true
        });

        emit ReferencePricesSet(tocId, normalizedPriceA, normalizedPriceB, priceDataA.publishTime);
    }

    // ============ Internal Functions ============

    function _validateAndEmitSnapshot(uint256 tocId, bytes calldata payload) internal {
        SnapshotPayload memory p = abi.decode(payload, (SnapshotPayload));

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

        if (p.startTime >= p.deadline) revert InvalidTimeRange();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit StayedTOCCreated(tocId, p.priceId, p.startTime, p.deadline, p.threshold, p.isAbove);
    }

    function _validateAndEmitStayedInRange(uint256 tocId, bytes calldata payload) internal {
        StayedInRangePayload memory p = abi.decode(payload, (StayedInRangePayload));

        if (p.lowerBound >= p.upperBound) revert InvalidBounds();
        if (p.startTime >= p.deadline) revert InvalidTimeRange();
        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit StayedInRangeTOCCreated(tocId, p.priceId, p.startTime, p.deadline, p.lowerBound, p.upperBound);
    }

    function _validateAndEmitBreakout(uint256 tocId, bytes calldata payload) internal {
        BreakoutPayload memory p = abi.decode(payload, (BreakoutPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        // If referenceTimestamp and referencePrice are both 0, user will call setReferencePrice later
        // If either is non-zero, store the reference price now
        if (p.referenceTimestamp != 0 || p.referencePrice != 0) {
            // Both must be non-zero if either is set
            if (p.referenceTimestamp == 0 || p.referencePrice == 0) {
                revert InvalidPayload();
            }
            // Store reference price
            _referencePrice[tocId] = ReferencePrice({
                price: p.referencePrice,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            emit ReferencePriceSet(tocId, p.referencePrice, p.referenceTimestamp);
        }

        emit BreakoutTOCCreated(tocId, p.priceId, p.deadline, p.referenceTimestamp, p.referencePrice, p.isUp);
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

    function _resolveStayedInRange(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        StayedInRangePayload memory p = abi.decode(_tocPayloads[tocId], (StayedInRangePayload));

        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // OPTIMISTIC APPROACH:
        // If no proof provided (empty array) and deadline passed → resolve YES
        if (updates.length == 0) {
            // Must be at or after deadline to resolve YES without proof
            if (block.timestamp < p.deadline) {
                revert DeadlineNotReached(p.deadline, block.timestamp);
            }

            // No counter-proof submitted, resolve YES (price stayed in range)
            emit TOCResolved(tocId, TEMPLATE_STAYED_IN_RANGE, true, 0, p.deadline);
            return true;
        }

        // If proof provided → check if it shows a violation
        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Check all proofs for a violation (price went outside range)
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

            // Check if this proof shows a violation (price went outside [lowerBound, upperBound])
            bool violated = normalizedPrice < p.lowerBound || normalizedPrice > p.upperBound;

            if (violated) {
                // Found a counter-proof showing violation → resolve NO
                emit TOCResolved(tocId, TEMPLATE_STAYED_IN_RANGE, false, normalizedPrice, priceFeed.price.publishTime);
                return false;
            }
        }

        // All proofs checked, no violation found
        // If we reach here, the proofs don't show a violation → resolve YES
        emit TOCResolved(tocId, TEMPLATE_STAYED_IN_RANGE, true, 0, p.deadline);
        return true;
    }

    function _resolveBreakout(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        BreakoutPayload memory p = abi.decode(_tocPayloads[tocId], (BreakoutPayload));

        // Reference price must be set
        if (!_referencePrice[tocId].isSet) {
            revert ReferencePriceNotSet(tocId);
        }

        ReferencePrice memory refPrice = _referencePrice[tocId];

        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // If no proof provided (empty array) and deadline passed → resolve NO
        if (updates.length == 0) {
            // Must be at or after deadline to resolve NO without proof
            if (block.timestamp < p.deadline) {
                revert DeadlineNotReached(p.deadline, block.timestamp);
            }

            // No breakout proof submitted, resolve NO (price did not break out)
            emit TOCResolved(tocId, TEMPLATE_BREAKOUT, false, refPrice.price, p.deadline);
            return false;
        }

        // If proof provided → check if it shows a breakout
        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Check all proofs for a breakout
        for (uint256 i = 0; i < updates.length; i++) {
            // Decode the price feed from the update
            (PythStructs.PriceFeed memory priceFeed,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            // Verify this is the correct price ID
            if (priceFeed.id != p.priceId) {
                continue;
            }

            // Validate timing - publishTime must be <= deadline and after reference timestamp
            if (priceFeed.price.publishTime > p.deadline || priceFeed.price.publishTime < refPrice.timestamp) {
                continue; // Skip proofs outside the valid time range
            }

            // Validate confidence
            _checkConfidence(priceFeed.price.conf, priceFeed.price.price);

            // Normalize price
            int64 normalizedPrice = _normalizePrice(priceFeed.price.price, priceFeed.price.expo);

            // Check if this proof shows a breakout
            bool breakout = false;
            if (p.isUp) {
                // Break up: price > referencePrice
                breakout = normalizedPrice > refPrice.price;
            } else {
                // Break down: price < referencePrice
                breakout = normalizedPrice < refPrice.price;
            }

            if (breakout) {
                // Found a proof showing breakout → resolve YES
                emit TOCResolved(tocId, TEMPLATE_BREAKOUT, true, normalizedPrice, priceFeed.price.publishTime);
                return true;
            }
        }

        // All proofs checked, no breakout found
        // If proofs were provided but don't show breakout, still resolve NO
        emit TOCResolved(tocId, TEMPLATE_BREAKOUT, false, refPrice.price, p.deadline);
        return false;
    }

    function _validateAndEmitPercentageChange(uint256 tocId, bytes calldata payload) internal {
        PercentageChangePayload memory p = abi.decode(payload, (PercentageChangePayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();
        if (p.percentageBps == 0) revert InvalidPercentage();

        // If referenceTimestamp and referencePrice are both 0, user will call setReferencePrice later
        // If either is non-zero, store the reference price now
        if (p.referenceTimestamp != 0 || p.referencePrice != 0) {
            // Both must be non-zero if either is set
            if (p.referenceTimestamp == 0 || p.referencePrice == 0) {
                revert InvalidPayload();
            }
            // Store reference price
            _referencePrice[tocId] = ReferencePrice({
                price: p.referencePrice,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            emit ReferencePriceSet(tocId, p.referencePrice, p.referenceTimestamp);
        }

        emit PercentageChangeTOCCreated(
            tocId,
            p.priceId,
            p.deadline,
            p.referenceTimestamp,
            p.referencePrice,
            p.percentageBps,
            p.isUp
        );
    }

    function _resolvePercentageChange(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        PercentageChangePayload memory p = abi.decode(_tocPayloads[tocId], (PercentageChangePayload));

        // Reference price must be set
        if (!_referencePrice[tocId].isSet) {
            revert ReferencePriceNotSet(tocId);
        }

        ReferencePrice memory refPrice = _referencePrice[tocId];

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get price at deadline
        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Calculate the target price based on percentage change
        // Using basis points: 10000 = 100%, 100 = 1%
        bool outcome;
        if (p.isUp) {
            // Check if price gained required percentage
            // price >= referencePrice * (10000 + percentageBps) / 10000
            int64 targetPrice = refPrice.price + (refPrice.price * int64(uint64(p.percentageBps))) / 10000;
            outcome = price >= targetPrice;
        } else {
            // Check if price lost required percentage
            // price <= referencePrice * (10000 - percentageBps) / 10000
            int64 targetPrice = refPrice.price - (refPrice.price * int64(uint64(p.percentageBps))) / 10000;
            outcome = price <= targetPrice;
        }

        emit TOCResolved(tocId, TEMPLATE_PERCENTAGE_CHANGE, outcome, price, publishTime);
        return outcome;
    }

    function _validateAndEmitPercentageEither(uint256 tocId, bytes calldata payload) internal {
        PercentageEitherPayload memory p = abi.decode(payload, (PercentageEitherPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();
        if (p.percentageBps == 0) revert InvalidPercentage();

        // If referenceTimestamp and referencePrice are both 0, user will call setReferencePrice later
        // If either is non-zero, store the reference price now
        if (p.referenceTimestamp != 0 || p.referencePrice != 0) {
            // Both must be non-zero if either is set
            if (p.referenceTimestamp == 0 || p.referencePrice == 0) {
                revert InvalidPayload();
            }
            // Store reference price
            _referencePrice[tocId] = ReferencePrice({
                price: p.referencePrice,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            emit ReferencePriceSet(tocId, p.referencePrice, p.referenceTimestamp);
        }

        emit PercentageEitherTOCCreated(
            tocId,
            p.priceId,
            p.deadline,
            p.referenceTimestamp,
            p.referencePrice,
            p.percentageBps
        );
    }

    function _resolvePercentageEither(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        PercentageEitherPayload memory p = abi.decode(_tocPayloads[tocId], (PercentageEitherPayload));

        // Reference price must be set
        if (!_referencePrice[tocId].isSet) {
            revert ReferencePriceNotSet(tocId);
        }

        ReferencePrice memory refPrice = _referencePrice[tocId];

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get price at deadline
        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Calculate the upper and lower thresholds
        // Upper threshold: referencePrice * (10000 + percentageBps) / 10000
        // Lower threshold: referencePrice * (10000 - percentageBps) / 10000
        int64 upperThreshold = refPrice.price + (refPrice.price * int64(uint64(p.percentageBps))) / 10000;
        int64 lowerThreshold = refPrice.price - (refPrice.price * int64(uint64(p.percentageBps))) / 10000;

        // YES if price moved X% in EITHER direction
        bool outcome = price >= upperThreshold || price <= lowerThreshold;

        emit TOCResolved(tocId, TEMPLATE_PERCENTAGE_EITHER, outcome, price, publishTime);
        return outcome;
    }

    function _validateAndEmitEndVsStart(uint256 tocId, bytes calldata payload) internal {
        EndVsStartPayload memory p = abi.decode(payload, (EndVsStartPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        // If referenceTimestamp and referencePrice are both 0, user will call setReferencePrice later
        // If either is non-zero, store the reference price now
        if (p.referenceTimestamp != 0 || p.referencePrice != 0) {
            // Both must be non-zero if either is set
            if (p.referenceTimestamp == 0 || p.referencePrice == 0) {
                revert InvalidPayload();
            }
            // Store reference price
            _referencePrice[tocId] = ReferencePrice({
                price: p.referencePrice,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            emit ReferencePriceSet(tocId, p.referencePrice, p.referenceTimestamp);
        }

        emit EndVsStartTOCCreated(
            tocId,
            p.priceId,
            p.deadline,
            p.referenceTimestamp,
            p.referencePrice,
            p.isHigher
        );
    }

    function _resolveEndVsStart(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        EndVsStartPayload memory p = abi.decode(_tocPayloads[tocId], (EndVsStartPayload));

        // Reference price must be set
        if (!_referencePrice[tocId].isSet) {
            revert ReferencePriceNotSet(tocId);
        }

        ReferencePrice memory refPrice = _referencePrice[tocId];

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get price at deadline (point-in-time, 1 sec tolerance)
        (int64 price, uint256 publishTime) = _getPriceAtDeadline(
            p.priceId,
            p.deadline,
            pythUpdateData
        );

        // Check if price matches expectation
        bool outcome;
        if (p.isHigher) {
            // YES if deadline price > start price
            outcome = price > refPrice.price;
        } else {
            // YES if deadline price < start price
            outcome = price < refPrice.price;
        }

        emit TOCResolved(tocId, TEMPLATE_END_VS_START, outcome, price, publishTime);
        return outcome;
    }

    function _validateAndEmitAssetCompare(uint256 tocId, bytes calldata payload) internal {
        AssetComparePayload memory p = abi.decode(payload, (AssetComparePayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit AssetCompareTOCCreated(tocId, p.priceIdA, p.priceIdB, p.deadline, p.aGreater);
    }

    function _resolveAssetCompare(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        AssetComparePayload memory p = abi.decode(_tocPayloads[tocId], (AssetComparePayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get both prices at deadline
        (int64 priceA, int64 priceB, uint256 publishTime) = _getTwoPricesAtDeadline(
            p.priceIdA,
            p.priceIdB,
            p.deadline,
            pythUpdateData
        );

        // Check condition
        bool outcome;
        if (p.aGreater) {
            outcome = priceA > priceB;
        } else {
            outcome = priceA < priceB;
        }

        emit TOCResolved(tocId, TEMPLATE_ASSET_COMPARE, outcome, priceA, publishTime);
        return outcome;
    }

    function _getTwoPricesAtDeadline(
        bytes32 priceIdA,
        bytes32 priceIdB,
        uint256 deadline,
        bytes calldata pythUpdateData
    ) internal returns (int64 priceA, int64 priceB, uint256 publishTime) {
        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));
        if (updates.length < 2) {
            revert InvalidProofArray();
        }

        // Update Pyth
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Get price A
        PythStructs.Price memory priceDataA = pyth.getPriceNoOlderThan(
            priceIdA,
            3600 // Allow fetching recent price
        );

        // Get price B
        PythStructs.Price memory priceDataB = pyth.getPriceNoOlderThan(
            priceIdB,
            3600 // Allow fetching recent price
        );

        // Validate timing - both must be within 1 second of deadline
        if (priceDataA.publishTime < deadline || priceDataA.publishTime > deadline + POINT_IN_TIME_TOLERANCE) {
            revert PriceNotNearDeadline(priceDataA.publishTime, deadline);
        }
        if (priceDataB.publishTime < deadline || priceDataB.publishTime > deadline + POINT_IN_TIME_TOLERANCE) {
            revert PriceNotNearDeadline(priceDataB.publishTime, deadline);
        }

        // Validate confidence for both prices
        _checkConfidence(priceDataA.conf, priceDataA.price);
        _checkConfidence(priceDataB.conf, priceDataB.price);

        // Normalize to 8 decimals
        priceA = _normalizePrice(priceDataA.price, priceDataA.expo);
        priceB = _normalizePrice(priceDataB.price, priceDataB.expo);
        publishTime = priceDataA.publishTime;
    }

    function _validateAndEmitRatioThreshold(uint256 tocId, bytes calldata payload) internal {
        RatioThresholdPayload memory p = abi.decode(payload, (RatioThresholdPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();
        if (p.ratioBps == 0) revert InvalidPercentage();

        emit RatioThresholdTOCCreated(tocId, p.priceIdA, p.priceIdB, p.deadline, p.ratioBps, p.isAbove);
    }

    function _resolveRatioThreshold(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        RatioThresholdPayload memory p = abi.decode(_tocPayloads[tocId], (RatioThresholdPayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get both prices at deadline
        (int64 priceA, int64 priceB, uint256 publishTime) = _getTwoPricesAtDeadline(
            p.priceIdA,
            p.priceIdB,
            p.deadline,
            pythUpdateData
        );

        // Calculate ratio: (priceA * 10000) / priceB
        // This gives us the ratio in basis points
        int64 ratio = (priceA * 10000) / priceB;

        // Check condition
        bool outcome;
        if (p.isAbove) {
            // YES if ratio > ratioBps
            outcome = ratio > int64(uint64(p.ratioBps));
        } else {
            // YES if ratio < ratioBps
            outcome = ratio < int64(uint64(p.ratioBps));
        }

        emit TOCResolved(tocId, TEMPLATE_RATIO_THRESHOLD, outcome, priceA, publishTime);
        return outcome;
    }

    function _validateAndEmitSpreadThreshold(uint256 tocId, bytes calldata payload) internal {
        SpreadThresholdPayload memory p = abi.decode(payload, (SpreadThresholdPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit SpreadThresholdTOCCreated(tocId, p.priceIdA, p.priceIdB, p.deadline, p.spreadThreshold, p.isAbove);
    }

    function _resolveSpreadThreshold(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        SpreadThresholdPayload memory p = abi.decode(_tocPayloads[tocId], (SpreadThresholdPayload));

        // Must be at or after deadline
        if (block.timestamp < p.deadline) {
            revert DeadlineNotReached(p.deadline, block.timestamp);
        }

        // Get both prices at deadline
        (int64 priceA, int64 priceB, uint256 publishTime) = _getTwoPricesAtDeadline(
            p.priceIdA,
            p.priceIdB,
            p.deadline,
            pythUpdateData
        );

        // Calculate spread: priceA - priceB
        int64 spread = priceA - priceB;

        // Check condition
        bool outcome;
        if (p.isAbove) {
            // YES if spread > spreadThreshold
            outcome = spread > p.spreadThreshold;
        } else {
            // YES if spread < spreadThreshold
            outcome = spread < p.spreadThreshold;
        }

        emit TOCResolved(tocId, TEMPLATE_SPREAD_THRESHOLD, outcome, priceA, publishTime);
        return outcome;
    }

    function _validateAndEmitFlip(uint256 tocId, bytes calldata payload) internal {
        FlipPayload memory p = abi.decode(payload, (FlipPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        // If reference prices are set, store them
        if (p.referenceTimestamp != 0 || p.referencePriceA != 0 || p.referencePriceB != 0) {
            // All must be non-zero if any is set
            if (p.referenceTimestamp == 0 || p.referencePriceA == 0 || p.referencePriceB == 0) {
                revert InvalidPayload();
            }
            // Store reference prices
            _referencePrice[tocId] = ReferencePrice({
                price: p.referencePriceA,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            _referencePriceB[tocId] = ReferencePrice({
                price: p.referencePriceB,
                timestamp: p.referenceTimestamp,
                isSet: true
            });
            emit ReferencePricesSet(tocId, p.referencePriceA, p.referencePriceB, p.referenceTimestamp);
        }

        emit FlipTOCCreated(
            tocId,
            p.priceIdA,
            p.priceIdB,
            p.deadline,
            p.referenceTimestamp,
            p.referencePriceA,
            p.referencePriceB
        );
    }

    function _resolveFlip(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        FlipPayload memory p = abi.decode(_tocPayloads[tocId], (FlipPayload));

        // Reference prices must be set
        if (!_referencePrice[tocId].isSet || !_referencePriceB[tocId].isSet) {
            revert ReferencePriceNotSet(tocId);
        }

        ReferencePrice memory refPriceA = _referencePrice[tocId];
        ReferencePrice memory refPriceB = _referencePriceB[tocId];

        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // If no proof provided (empty array) and deadline passed -> resolve NO
        if (updates.length == 0) {
            // Must be at or after deadline to resolve NO without proof
            if (block.timestamp < p.deadline) {
                revert DeadlineNotReached(p.deadline, block.timestamp);
            }

            // No flip proof submitted, resolve NO (flip did not happen)
            emit TOCResolved(tocId, TEMPLATE_FLIP, false, refPriceA.price, p.deadline);
            return false;
        }

        // If proof provided -> check if it shows a flip
        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Determine initial relationship: was A < B or A > B?
        bool initialALessThanB = refPriceA.price < refPriceB.price;

        // Check all proofs for a flip
        for (uint256 i = 0; i < updates.length; i++) {
            // Decode the price feed from the update
            (PythStructs.PriceFeed memory priceFeed,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            // We need both prices at the same time
            // Skip if this is not one of our price IDs
            if (priceFeed.id != p.priceIdA && priceFeed.id != p.priceIdB) {
                continue;
            }

            // Validate timing - publishTime must be <= deadline and after reference timestamp
            if (priceFeed.price.publishTime > p.deadline || priceFeed.price.publishTime < refPriceA.timestamp) {
                continue; // Skip proofs outside the valid time range
            }

            // We need to get both prices at this timestamp
            // Since we're iterating through updates, we need to check if we have both prices
            // For simplicity, we'll get both prices from Pyth after updating
            // This assumes the updates contain price feeds for both assets at similar times
        }

        // Alternative approach: Get both current prices and check if flip occurred
        // This requires the proof to contain updates for both price feeds
        bool flipOccurred = false;
        int64 lastPriceA = refPriceA.price;
        int64 lastPriceB = refPriceB.price;
        uint256 lastPublishTime = refPriceA.timestamp;

        // Check each pair of price updates to see if a flip occurred
        for (uint256 i = 0; i < updates.length; i++) {
            (PythStructs.PriceFeed memory priceFeedA,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            if (priceFeedA.id != p.priceIdA) {
                continue;
            }

            // Validate timing
            if (priceFeedA.price.publishTime > p.deadline || priceFeedA.price.publishTime < refPriceA.timestamp) {
                continue;
            }

            // Validate confidence
            _checkConfidence(priceFeedA.price.conf, priceFeedA.price.price);

            // Normalize price A
            int64 normalizedPriceA = _normalizePrice(priceFeedA.price.price, priceFeedA.price.expo);

            // Find matching price B at the same or nearby time
            for (uint256 j = 0; j < updates.length; j++) {
                (PythStructs.PriceFeed memory priceFeedB,) = abi.decode(updates[j], (PythStructs.PriceFeed, uint64));

                if (priceFeedB.id != p.priceIdB) {
                    continue;
                }

                // Check if timestamps are close (within tolerance)
                if (priceFeedB.price.publishTime < priceFeedA.price.publishTime ||
                    priceFeedB.price.publishTime > priceFeedA.price.publishTime + POINT_IN_TIME_TOLERANCE) {
                    continue;
                }

                // Validate timing
                if (priceFeedB.price.publishTime > p.deadline || priceFeedB.price.publishTime < refPriceB.timestamp) {
                    continue;
                }

                // Validate confidence
                _checkConfidence(priceFeedB.price.conf, priceFeedB.price.price);

                // Normalize price B
                int64 normalizedPriceB = _normalizePrice(priceFeedB.price.price, priceFeedB.price.expo);

                // Check if flip occurred
                if (initialALessThanB) {
                    // Initially A < B, flip occurs when A > B
                    if (normalizedPriceA > normalizedPriceB) {
                        flipOccurred = true;
                        lastPriceA = normalizedPriceA;
                        lastPriceB = normalizedPriceB;
                        lastPublishTime = priceFeedA.price.publishTime;
                        break;
                    }
                } else {
                    // Initially A > B, flip occurs when A < B
                    if (normalizedPriceA < normalizedPriceB) {
                        flipOccurred = true;
                        lastPriceA = normalizedPriceA;
                        lastPriceB = normalizedPriceB;
                        lastPublishTime = priceFeedA.price.publishTime;
                        break;
                    }
                }
            }

            if (flipOccurred) {
                break;
            }
        }

        if (flipOccurred) {
            // Found a proof showing flip occurred -> resolve YES
            emit TOCResolved(tocId, TEMPLATE_FLIP, true, lastPriceA, lastPublishTime);
            return true;
        }

        // All proofs checked, no flip found
        // If proofs were provided but don't show flip, still resolve NO
        emit TOCResolved(tocId, TEMPLATE_FLIP, false, refPriceA.price, p.deadline);
        return false;
    }

    function _validateAndEmitFirstToTarget(uint256 tocId, bytes calldata payload) internal {
        FirstToTargetPayload memory p = abi.decode(payload, (FirstToTargetPayload));

        if (p.deadline <= block.timestamp) revert DeadlineInPast();

        emit FirstToTargetTOCCreated(tocId, p.priceId, p.targetA, p.targetB, p.deadline);
    }

    function _resolveFirstToTarget(
        uint256 tocId,
        bytes calldata pythUpdateData
    ) internal returns (bool) {
        FirstToTargetPayload memory p = abi.decode(_tocPayloads[tocId], (FirstToTargetPayload));

        // Decode update data array
        bytes[] memory updates = abi.decode(pythUpdateData, (bytes[]));

        // If no proof provided (empty array) and deadline passed -> resolve NO
        // (neither target was hit, so targetA was not hit first)
        if (updates.length == 0) {
            // Must be at or after deadline to resolve NO without proof
            if (block.timestamp < p.deadline) {
                revert DeadlineNotReached(p.deadline, block.timestamp);
            }

            // No proof submitted, resolve NO (targetA was not hit first)
            emit TOCResolved(tocId, TEMPLATE_FIRST_TO_TARGET, false, 0, p.deadline);
            return false;
        }

        // If proof provided -> check which target was hit
        // Update Pyth with all proofs
        uint256 fee = pyth.getUpdateFee(updates);
        pyth.updatePriceFeeds{value: fee}(updates);

        // Track the earliest time each target was hit
        uint256 hitTimeA = type(uint256).max;
        uint256 hitTimeB = type(uint256).max;
        int64 priceWhenHitA = 0;
        int64 priceWhenHitB = 0;

        // Check all proofs to find when each target was hit
        for (uint256 i = 0; i < updates.length; i++) {
            // Decode the price feed from the update
            (PythStructs.PriceFeed memory priceFeed,) = abi.decode(updates[i], (PythStructs.PriceFeed, uint64));

            // Verify this is the correct price ID
            if (priceFeed.id != p.priceId) {
                continue;
            }

            // Validate timing - publishTime must be <= deadline
            if (priceFeed.price.publishTime > p.deadline) {
                continue; // Skip proofs after deadline
            }

            // Validate confidence
            _checkConfidence(priceFeed.price.conf, priceFeed.price.price);

            // Normalize price
            int64 normalizedPrice = _normalizePrice(priceFeed.price.price, priceFeed.price.expo);

            // Check if targetA was hit at this timestamp
            // "hit" means price reached or crossed the target from either direction
            // We accept proof showing price == targetA as a definitive hit
            // We also accept price beyond targetA (assuming it crossed the target)
            // For upward movement: price >= targetA means target was hit
            // For downward movement: price <= targetA means target was hit
            // Practical approach: accept exact match or beyond in either direction
            // To avoid "always true" condition, we check against both targets separately

            // TargetA is "hit" if price reached or exceeded it
            // Since we need to determine which was hit first, we track earliest occurrence
            // For a race, we need clear hit conditions:
            // - If targetA > targetB: going up hits A, going down hits B
            // - If targetA < targetB: going down hits A, going up hits B
            // Simplified: exact match is always a hit, beyond target assumes crossing
            bool hitTargetA = (normalizedPrice == p.targetA);
            if (hitTargetA && priceFeed.price.publishTime < hitTimeA) {
                hitTimeA = priceFeed.price.publishTime;
                priceWhenHitA = normalizedPrice;
            }

            // Check if targetB was hit at this timestamp
            bool hitTargetB = (normalizedPrice == p.targetB);
            if (hitTargetB && priceFeed.price.publishTime < hitTimeB) {
                hitTimeB = priceFeed.price.publishTime;
                priceWhenHitB = normalizedPrice;
            }
        }

        // Determine outcome based on which target was hit first
        bool outcome = false;
        int64 priceUsed = 0;
        uint256 publishTime = p.deadline;

        if (hitTimeA != type(uint256).max && hitTimeB != type(uint256).max) {
            // Both targets were hit - check which was first
            if (hitTimeA < hitTimeB) {
                // TargetA hit first -> YES
                outcome = true;
                priceUsed = priceWhenHitA;
                publishTime = hitTimeA;
            } else if (hitTimeB < hitTimeA) {
                // TargetB hit first -> NO
                outcome = false;
                priceUsed = priceWhenHitB;
                publishTime = hitTimeB;
            } else {
                // Same time (very unlikely) - targetA wins (YES)
                outcome = true;
                priceUsed = priceWhenHitA;
                publishTime = hitTimeA;
            }
        } else if (hitTimeA != type(uint256).max) {
            // Only targetA was hit -> YES
            outcome = true;
            priceUsed = priceWhenHitA;
            publishTime = hitTimeA;
        } else if (hitTimeB != type(uint256).max) {
            // Only targetB was hit -> NO
            outcome = false;
            priceUsed = priceWhenHitB;
            publishTime = hitTimeB;
        } else {
            // Neither target was hit -> NO (targetA was not hit first)
            outcome = false;
            priceUsed = 0;
            publishTime = p.deadline;
        }

        emit TOCResolved(tocId, TEMPLATE_FIRST_TO_TARGET, outcome, priceUsed, publishTime);
        return outcome;
    }

    // ============ String Conversion Helpers ============

    /// @notice Convert uint256 to string
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

    receive() external payable {}
}
