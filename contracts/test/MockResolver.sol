// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.29;

import "../Popregistry/IPopResolver.sol";
import "../Popregistry/POPTypes.sol";

/// @title MockResolver
/// @notice Mock resolver for testing the POPRegistry
/// @dev Supports configurable behavior for testing various scenarios
contract MockResolver is IPopResolver {
    // ============ Storage ============

    address public registry;

    // POP tracking
    mapping(uint256 => bool) private _managedPops;
    mapping(uint256 => uint32) private _popTemplates;
    mapping(uint256 => bytes) private _popPayloads;

    // Configurable behavior
    POPState public defaultInitialState = POPState.ACTIVE;
    bool public shouldRevertOnCreate;
    bool public shouldRevertOnResolve;

    // Resolution outcomes (can be set per POP or use defaults)
    bool public defaultBooleanResult = true;
    int256 public defaultNumericResult = 100;
    bytes public defaultGenericResult = "test";

    mapping(uint256 => bool) private _booleanResults;
    mapping(uint256 => int256) private _numericResults;
    mapping(uint256 => bytes) private _genericResults;
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

    function setDefaultInitialState(POPState state) external {
        defaultInitialState = state;
    }

    function setShouldRevertOnCreate(bool value) external {
        shouldRevertOnCreate = value;
    }

    function setShouldRevertOnResolve(bool value) external {
        shouldRevertOnResolve = value;
    }

    function setDefaultBooleanResult(bool value) external {
        defaultBooleanResult = value;
    }

    function setDefaultNumericResult(int256 value) external {
        defaultNumericResult = value;
    }

    function setDefaultGenericResult(bytes calldata value) external {
        defaultGenericResult = value;
    }

    function setPopBooleanResult(uint256 popId, bool value) external {
        _booleanResults[popId] = value;
        _hasCustomResult[popId] = true;
    }

    function setPopNumericResult(uint256 popId, int256 value) external {
        _numericResults[popId] = value;
        _hasCustomResult[popId] = true;
    }

    function setPopGenericResult(uint256 popId, bytes calldata value) external {
        _genericResults[popId] = value;
        _hasCustomResult[popId] = true;
    }

    function setTemplateCount(uint32 count) external {
        templateCount = count;
    }

    function setTemplateAnswerType(uint32 templateId, AnswerType answerType) external {
        _templateAnswerTypes[templateId] = answerType;
    }

    // ============ IPopResolver Implementation ============

    /// @inheritdoc IPopResolver
    function isPopManaged(uint256 popId) external view returns (bool) {
        return _managedPops[popId];
    }

    /// @inheritdoc IPopResolver
    function onPopCreated(
        uint256 popId,
        uint32 templateId,
        bytes calldata payload
    ) external onlyRegistry returns (POPState initialState) {
        if (shouldRevertOnCreate) {
            revert MockRevertOnCreate();
        }

        _managedPops[popId] = true;
        _popTemplates[popId] = templateId;
        _popPayloads[popId] = payload;

        return defaultInitialState;
    }

    /// @inheritdoc IPopResolver
    function resolvePop(
        uint256 popId,
        address, // caller
        bytes calldata // payload
    ) external onlyRegistry returns (bool booleanResult, int256 numericResult, bytes memory genericResult) {
        if (shouldRevertOnResolve) {
            revert MockRevertOnResolve();
        }

        if (_hasCustomResult[popId]) {
            return (_booleanResults[popId], _numericResults[popId], _genericResults[popId]);
        }

        return (defaultBooleanResult, defaultNumericResult, defaultGenericResult);
    }

    /// @inheritdoc IPopResolver
    function getPopDetails(uint256 popId) external view returns (uint32 templateId, bytes memory creationPayload) {
        return (_popTemplates[popId], _popPayloads[popId]);
    }

    /// @inheritdoc IPopResolver
    function getPopQuestion(uint256 popId) external view returns (string memory question) {
        uint32 templateId = _popTemplates[popId];
        return string(abi.encodePacked("Mock question for POP ", _uint256ToString(popId), " template ", _uint32ToString(templateId)));
    }

    /// @inheritdoc IPopResolver
    function getTemplateCount() external view returns (uint32 count) {
        return templateCount;
    }

    /// @inheritdoc IPopResolver
    function isValidTemplate(uint32 templateId) external view returns (bool) {
        return templateId < templateCount;
    }

    /// @inheritdoc IPopResolver
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
