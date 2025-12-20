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

    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;

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
        return TOCState.ACTIVE;
    }

    function resolveToc(
        uint256 tocId,
        address,
        bytes calldata
    ) external onlyRegistry returns (bytes memory result) {
        if (_tocTemplates[tocId] == TEMPLATE_NONE) {
            revert TocNotManaged(tocId);
        }
        // Stub - will be implemented per template
        return TOCResultCodec.encodeBoolean(false);
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

    // ============ Receive ============

    receive() external payable {}
}
