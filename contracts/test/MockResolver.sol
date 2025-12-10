// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../TOCRegistry/ITOCResolver.sol";
import "../TOCRegistry/TOCTypes.sol";
import "../libraries/TOCResultCodec.sol";

/// @title MockResolver
/// @notice Mock resolver for testing the TOCRegistry
/// @dev Supports configurable behavior for testing various scenarios
contract MockResolver is ITOCResolver {
    // ============ Storage ============

    address public registry;

    // TOC tracking
    mapping(uint256 => bool) private _managedTocs;
    mapping(uint256 => uint32) private _tocTemplates;
    mapping(uint256 => bytes) private _tocPayloads;

    // Configurable behavior
    TOCState public defaultInitialState = TOCState.ACTIVE;
    bool public shouldRevertOnCreate;
    bool public shouldRevertOnResolve;

    // Resolution outcomes (can be set per TOC or use defaults)
    bytes public defaultResult;
    mapping(uint256 => bytes) private _results;
    mapping(uint256 => bool) private _hasCustomResult;

    // Template configuration
    uint32 public templateCount = 3;
    mapping(uint32 => AnswerType) private _templateAnswerTypes;

    // ============ Errors ============

    error OnlyRegistry();
    error MockRevertOnCreate();
    error MockRevertOnResolve();

    // ============ Constructor ============

    constructor(address _registry) {
        registry = _registry;
        // Default template answer types
        _templateAnswerTypes[0] = AnswerType.BOOLEAN;
        _templateAnswerTypes[1] = AnswerType.NUMERIC;
        _templateAnswerTypes[2] = AnswerType.GENERIC;
        // Default result (boolean true)
        defaultResult = TOCResultCodec.encodeBoolean(true);
    }

    // ============ Modifiers ============

    modifier onlyRegistry() {
        if (msg.sender != registry) {
            revert OnlyRegistry();
        }
        _;
    }

    // ============ Configuration Functions ============

    function setRegistry(address _registry) external {
        registry = _registry;
    }

    function setDefaultInitialState(TOCState state) external {
        defaultInitialState = state;
    }

    function setShouldRevertOnCreate(bool value) external {
        shouldRevertOnCreate = value;
    }

    function setShouldRevertOnResolve(bool value) external {
        shouldRevertOnResolve = value;
    }

    function setDefaultResult(bytes calldata value) external {
        defaultResult = value;
    }

    function setDefaultBooleanResult(bool value) external {
        defaultResult = TOCResultCodec.encodeBoolean(value);
    }

    function setDefaultNumericResult(int256 value) external {
        defaultResult = TOCResultCodec.encodeNumeric(value);
    }

    function setTocResult(uint256 tocId, bytes calldata value) external {
        _results[tocId] = value;
        _hasCustomResult[tocId] = true;
    }

    function setTocBooleanResult(uint256 tocId, bool value) external {
        _results[tocId] = TOCResultCodec.encodeBoolean(value);
        _hasCustomResult[tocId] = true;
    }

    function setTocNumericResult(uint256 tocId, int256 value) external {
        _results[tocId] = TOCResultCodec.encodeNumeric(value);
        _hasCustomResult[tocId] = true;
    }

    function setTemplateCount(uint32 count) external {
        templateCount = count;
    }

    function setTemplateAnswerType(uint32 templateId, AnswerType answerType) external {
        _templateAnswerTypes[templateId] = answerType;
    }

    // ============ ITOCResolver Implementation ============

    /// @inheritdoc ITOCResolver
    function isTocManaged(uint256 tocId) external view returns (bool) {
        return _managedTocs[tocId];
    }

    /// @inheritdoc ITOCResolver
    function onTocCreated(
        uint256 tocId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (TOCState initialState) {
        if (shouldRevertOnCreate) {
            revert MockRevertOnCreate();
        }

        _managedTocs[tocId] = true;
        _tocTemplates[tocId] = templateId;
        _tocPayloads[tocId] = payload;

        return defaultInitialState;
    }

    /// @inheritdoc ITOCResolver
    function resolveToc(
        uint256 tocId,
        address, // caller
        bytes calldata // payload
    ) external onlyRegistry returns (bytes memory result) {
        if (shouldRevertOnResolve) {
            revert MockRevertOnResolve();
        }

        if (_hasCustomResult[tocId]) {
            return _results[tocId];
        }

        return defaultResult;
    }

    /// @inheritdoc ITOCResolver
    function getTocDetails(uint256 tocId) external view returns (uint32 templateId, bytes memory creationPayload) {
        return (_tocTemplates[tocId], _tocPayloads[tocId]);
    }

    /// @inheritdoc ITOCResolver
    function getTocQuestion(uint256 tocId) external view returns (string memory question) {
        uint32 templateId = _tocTemplates[tocId];
        return string(abi.encodePacked("Mock question for TOC ", _uint256ToString(tocId), " template ", _uint32ToString(templateId)));
    }

    /// @inheritdoc ITOCResolver
    function getTemplateCount() external view returns (uint32 count) {
        return templateCount;
    }

    /// @inheritdoc ITOCResolver
    function isValidTemplate(uint32 templateId) external view returns (bool) {
        return templateId < templateCount;
    }

    /// @inheritdoc ITOCResolver
    function getTemplateAnswerType(uint32 templateId) external view returns (AnswerType answerType) {
        return _templateAnswerTypes[templateId];
    }

    // ============ String Helpers ============

    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
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

    function _uint32ToString(uint32 value) internal pure returns (string memory) {
        return _uint256ToString(uint256(value));
    }
}
